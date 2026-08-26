const std = @import("std");
const c = @import("../c.zig");
const launch = @import("../launch.zig");
const list = @import("../list.zig");
const rank = @import("../rank.zig");
const source = @import("../source.zig");
const store_mod = @import("../store.zig");
const subroutines = @import("../subroutines.zig");
const adapters = @import("bookmarks/adapter.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.bookmarks);

pub const chromium = @import("bookmarks/adapters/chromium.zig");
pub const firefox = @import("bookmarks/adapters/firefox.zig");
pub const markdown = @import("bookmarks/adapters/markdown.zig");

pub const Adapter = adapters.Adapter;
pub const Link = adapters.Link;

pub const table = "bookmarks";

const max_rows = 200;

const skipped_schemes = [_][]const u8{
    "javascript",
    "about",
    "chrome",
    "chrome-extension",
    "chrome-search",
    "chrome-untrusted",
    "edge",
    "brave",
    "vivaldi",
    "opera",
    "moz-extension",
    "place",
};

const icon_names = [_][:0]const u8{
    "text-html",
    "internet-web-browser",
    "applications-internet",
    "web-browser",
};

pub const Index = struct {
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    members: []const Adapter,
    due: []bool,
    source: source.Source,
    icon: [:0]const u8,
    path: ?[:0]const u8 = null,
    published: source.Published = .{},
    stamp: i64 = 0,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = &vtable };
    }
};

const vtable: subroutines.Subroutine.VTable = .{
    .run = &run,
    .choose = &choose,
    .release = &release,
    .stale = &stale,
    .refresh = &refresh,
    .retire = &retire,
};

pub fn open(
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    members: []const Adapter,
    store: ?*store_mod.Store,
    stamp: i64,
    settings_at: ?i64,
    published: source.Published,
) Allocator.Error!Index {
    const due = try gpa.alloc(bool, members.len);
    errdefer gpa.free(due);
    @memset(due, true);

    var self: Index = .{
        .gpa = gpa,
        .environ = environ,
        .members = members,
        .due = due,
        .source = .{ .gpa = gpa, .name = table, .current = .init(try source.empty(gpa)) },
        .icon = bookmarkIcon(),
        .published = published,
        .stamp = stamp,
    };

    const found = store orelse {
        self.source.needs_refresh = members.len > 0;
        return self;
    };

    found.ensure(table) catch |err| {
        source.report(table, "prepare", err);
        self.source.needs_refresh = members.len > 0;
        return self;
    };

    self.path = found.path;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    for (members, due) |member, *wanted| {
        const name = try store_mod.qualify(arena.allocator(), table, member.name);
        const indexed = found.updatedAt(name);

        wanted.* = store_mod.stale(indexed, stamp, member.max_age_minutes) or
            reconfigured(indexed, settings_at);
    }
    self.source.needs_refresh = pending(due);

    const records = found.load(arena.allocator(), table) catch |err| {
        source.report(table, "load", err);
        return self;
    };

    const kept = try known(arena.allocator(), members, records);
    if (kept.len < records.len) self.source.needs_refresh = true;
    if (kept.len == 0) return self;

    self.source.publish(try source.build(gpa, kept, &iconOf, &self));
    return self;
}

fn refresh(context: *anyopaque) void {
    const self: *Index = @ptrCast(@alignCast(context));

    log.debug("refreshing the index", .{});

    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();

    const records = rebuild(arena.allocator(), self) catch |err| {
        return source.report(table, "rebuild", err);
    };

    const next = source.build(self.gpa, records, &iconOf, self) catch |err| {
        return source.report(table, "publish", err);
    };
    self.source.publish(next);
    log.debug("published {d} entries", .{next.entries.len});
    self.published.call();
}

fn rebuild(arena: Allocator, self: *Index) ![]store_mod.Record {
    const file = self.path orelse return gather(arena, self.members);

    const conn = try store_mod.connect(file);
    defer conn.close();

    try store_mod.create(self.gpa, conn, table);
    try store_mod.keepAdapters(self.gpa, conn, table, try names(arena, self.members));

    for (self.members, self.due) |member, due| {
        if (!due) continue;

        const records = try recordsOf(arena, member);
        try store_mod.replace(
            self.gpa,
            conn,
            table,
            .{ .adapter = member.name },
            records,
            self.stamp,
        );
    }

    return store_mod.read(arena, conn, table);
}

fn gather(arena: Allocator, members: []const Adapter) Allocator.Error![]store_mod.Record {
    var records: std.ArrayList(store_mod.Record) = .empty;
    for (members) |member| try records.appendSlice(arena, try recordsOf(arena, member));
    return records.toOwnedSlice(arena);
}

fn recordsOf(arena: Allocator, member: Adapter) Allocator.Error![]store_mod.Record {
    const links = try member.collect(arena);

    var records: std.ArrayList(store_mod.Record) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (links) |link| {
        if (!openable(link.url)) continue;

        const found = try seen.getOrPut(arena, link.url);
        if (found.found_existing) continue;

        try records.append(arena, .{
            .adapter = member.name,
            .key = link.url,
            .title = if (link.name.len > 0) link.name else link.url,
            .detail = link.url,
            .icon = "",
            .folder = link.folder,
            .tags = link.tags,
            .haystack = try haystackOf(arena, link),
        });
    }

    log.debug("{s} collected {d} links", .{ member.name, records.items.len });
    return records.toOwnedSlice(arena);
}

fn openable(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (colon == 0 or colon + 1 >= url.len) return false;
    if (!std.ascii.isAlphabetic(url[0])) return false;

    for (url[1..colon]) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char != '+' and char != '-' and char != '.') return false;
    }

    for (skipped_schemes) |scheme| {
        if (std.ascii.eqlIgnoreCase(scheme, url[0..colon])) return false;
    }
    return true;
}

fn haystackOf(arena: Allocator, link: Link) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    for ([_][]const u8{ link.name, link.url, link.folder, link.tags }) |part| {
        if (part.len == 0) continue;
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, part);
    }

    return out.toOwnedSlice(arena);
}

fn names(arena: Allocator, members: []const Adapter) Allocator.Error![]const []const u8 {
    const found = try arena.alloc([]const u8, members.len);
    for (members, 0..) |member, at| found[at] = member.name;
    return found;
}

fn known(
    arena: Allocator,
    members: []const Adapter,
    records: []const store_mod.Record,
) Allocator.Error![]store_mod.Record {
    var kept: std.ArrayList(store_mod.Record) = .empty;

    for (records) |record| {
        for (members) |member| {
            if (!std.mem.eql(u8, member.name, record.adapter)) continue;
            try kept.append(arena, record);
            break;
        }
    }

    return kept.toOwnedSlice(arena);
}

fn reconfigured(indexed: ?i64, settings_at: ?i64) bool {
    const written = settings_at orelse return false;
    const at = indexed orelse return true;
    return at < written;
}

fn pending(due: []const bool) bool {
    for (due) |wanted| {
        if (wanted) return true;
    }
    return false;
}

fn bookmarkIcon() [:0]const u8 {
    const display = c.gdk_display_get_default() orelse return icon_names[0];
    const theme = c.gtk_icon_theme_get_for_display(display);

    for (icon_names) |name| {
        if (c.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    }
    return icon_names[0];
}

fn iconOf(context: *anyopaque, _: Allocator, _: store_mod.Record) list.Icon {
    const self: *Index = @ptrCast(@alignCast(context));
    return .{ .name = self.icon };
}

fn run(context: *anyopaque, gpa: Allocator, text: []const u8) subroutines.Error!subroutines.Output {
    const self: *Index = @ptrCast(@alignCast(context));

    const query = std.mem.trim(u8, text, " \t");
    if (query.len == 0) return .nothing;

    const of = self.source.snapshot();
    if (of.entries.len == 0) return .nothing;

    const weights = try of.weights(gpa);
    defer gpa.free(weights);

    const matches = try rank.rank(gpa, of.haystacks, weights, query);
    defer gpa.free(matches);
    if (matches.len == 0) return .nothing;

    const kept = try distinct(gpa, of, weights, matches);
    defer gpa.free(kept);

    of.noteShown(kept);

    const shown = kept[0..@min(kept.len, max_rows)];
    const hits = try gpa.alloc(subroutines.Hit, shown.len);
    for (shown, 0..) |match, at| {
        const entry = of.entries[match.index];
        hits[at] = .{
            .row = .{
                .id = match.index,
                .icon = entry.icon,
                .title = entry.title,
                .detail = entry.detail,
                .program = entry.program,
            },
            .score = match.score,
        };
    }

    return .{ .hits = hits };
}

fn distinct(
    gpa: Allocator,
    of: *source.Snapshot,
    weights: []const rank.Weight,
    matches: []const rank.Match,
) Allocator.Error![]rank.Match {
    var kept: std.ArrayList(rank.Match) = .empty;
    errdefer kept.deinit(gpa);

    var places: std.StringHashMapUnmanaged(usize) = .empty;
    defer places.deinit(gpa);

    for (matches) |match| {
        const found = try places.getOrPut(gpa, of.entries[match.index].key);
        if (!found.found_existing) {
            found.value_ptr.* = kept.items.len;
            try kept.append(gpa, match);
            continue;
        }

        const standing = &kept.items[found.value_ptr.*];
        if (better(weights[match.index], weights[standing.index])) standing.index = match.index;
    }

    return kept.toOwnedSlice(gpa);
}

fn better(candidate: rank.Weight, standing: rank.Weight) bool {
    if (candidate.chosen != standing.chosen) return candidate.chosen > standing.chosen;
    return candidate.shown > standing.shown;
}

fn choose(context: *anyopaque, gpa: Allocator, id: u64) subroutines.Outcome {
    const self: *Index = @ptrCast(@alignCast(context));

    const of = self.source.snapshot();
    const index: usize = @intCast(id);
    if (index >= of.entries.len) return .keep;

    const entry = of.entries[index];
    if (!launch.uri(gpa, self.environ, entry.key)) return .keep;

    of.noteChosen(index);
    return .close;
}

fn release(_: *anyopaque, gpa: Allocator, output: subroutines.Output) void {
    switch (output) {
        .nothing, .marks, .answer => {},
        .hits => |hits| gpa.free(hits),
    }
}

fn stale(context: *anyopaque) bool {
    const self: *Index = @ptrCast(@alignCast(context));
    return self.source.needs_refresh;
}

fn retire(context: *anyopaque, store: ?*store_mod.Store) void {
    const self: *Index = @ptrCast(@alignCast(context));
    if (store) |found| self.source.flush(found);
    self.source.deinit();
    self.gpa.free(self.due);
}

test {
    _ = adapters;
    _ = chromium;
    _ = firefox;
    _ = markdown;
}

const testing = std.testing;

const Fixed = struct {
    links: []const Link,

    fn adapter(self: *Fixed, name: []const u8) Adapter {
        return .{
            .name = name,
            .max_age_minutes = 60,
            .context = self,
            .vtable = &fixed,
        };
    }

    fn collect(context: *anyopaque, _: Allocator) Allocator.Error![]const Link {
        const self: *Fixed = @ptrCast(@alignCast(context));
        return self.links;
    }
};

const fixed: Adapter.VTable = .{ .collect = &Fixed.collect };

fn plainIcon(_: *anyopaque, _: Allocator, _: store_mod.Record) list.Icon {
    return .none;
}

test "the first of two links to the same url wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var notes: Fixed = .{ .links = &.{
        .{ .url = "https://ziglang.org", .name = "Zig" },
        .{ .url = "https://sqlite.org", .name = "SQLite" },
        .{ .url = "https://ziglang.org", .name = "The Zig language" },
    } };

    const records = try recordsOf(arena.allocator(), notes.adapter("markdown"));

    try testing.expectEqual(@as(usize, 2), records.len);
    try testing.expectEqualStrings("Zig", records[0].title);
    try testing.expectEqualStrings("https://ziglang.org", records[0].key);
    try testing.expectEqualStrings("https://ziglang.org", records[0].detail);
    try testing.expectEqualStrings("markdown", records[0].adapter);
    try testing.expectEqualStrings("Zig https://ziglang.org", records[0].haystack);
    try testing.expectEqualStrings("SQLite", records[1].title);
}

test "the same url from two adapters stays two records" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var notes: Fixed = .{ .links = &.{.{ .url = "https://ziglang.org", .name = "Zig" }} };
    var history: Fixed = .{ .links = &.{.{ .url = "https://ziglang.org", .name = "Ziglang" }} };

    const records = try gather(arena.allocator(), &.{
        notes.adapter("markdown"),
        history.adapter("chromium"),
    });

    try testing.expectEqual(@as(usize, 2), records.len);
    try testing.expectEqualStrings("markdown", records[0].adapter);
    try testing.expectEqualStrings("chromium", records[1].adapter);
}

test "rows of an adapter that is no longer configured are left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var notes: Fixed = .{ .links = &.{.{ .url = "https://ziglang.org", .name = "Zig" }} };
    var history: Fixed = .{ .links = &.{.{ .url = "https://sqlite.org", .name = "SQLite" }} };

    const records = try gather(arena.allocator(), &.{
        notes.adapter("markdown"),
        history.adapter("chromium"),
    });

    const kept = try known(arena.allocator(), &.{notes.adapter("markdown")}, records);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("markdown", kept[0].adapter);
}

const duplicates = [_]store_mod.Record{
    .{
        .adapter = "markdown",
        .key = "https://ziglang.org",
        .title = "Zig",
        .detail = "https://ziglang.org",
        .icon = "",
        .haystack = "Zig https://ziglang.org",
    },
    .{
        .adapter = "chromium",
        .key = "https://ziglang.org",
        .title = "Ziglang",
        .detail = "https://ziglang.org",
        .icon = "",
        .haystack = "Ziglang https://ziglang.org",
        .chosen = 9,
    },
    .{
        .adapter = "chromium",
        .key = "https://sqlite.org",
        .title = "SQLite",
        .detail = "https://sqlite.org",
        .icon = "",
        .haystack = "SQLite https://sqlite.org",
    },
};

fn expectDistinct(
    matches: []const rank.Match,
    expected: []const rank.Match,
) !void {
    const gpa = testing.allocator;

    const of = try source.build(gpa, &duplicates, &plainIcon, undefined);
    defer of.destroy(gpa);

    const weights = try of.weights(gpa);
    defer gpa.free(weights);

    const kept = try distinct(gpa, of, weights, matches);
    defer gpa.free(kept);

    try testing.expectEqual(expected.len, kept.len);
    for (expected, kept) |want, got| {
        try testing.expectEqual(want.index, got.index);
        try testing.expectEqual(want.score, got.score);
    }
}

test "one url is one row, and the row that was opened more often wins it" {
    try expectDistinct(
        &.{
            .{ .index = 0, .score = 100 },
            .{ .index = 2, .score = 80 },
            .{ .index = 1, .score = 60 },
        },
        &.{ .{ .index = 1, .score = 100 }, .{ .index = 2, .score = 80 } },
    );
}

test "the match that ranked first wins when the counts are the same" {
    const bare = [_]store_mod.Record{ duplicates[0], duplicates[2] };
    const gpa = testing.allocator;

    const of = try source.build(gpa, &bare, &plainIcon, undefined);
    defer of.destroy(gpa);

    var records: [2]store_mod.Record = .{ duplicates[0], duplicates[0] };
    records[1].adapter = "chromium";
    records[1].title = "Ziglang";

    const both = try source.build(gpa, &records, &plainIcon, undefined);
    defer both.destroy(gpa);

    const weights = try both.weights(gpa);
    defer gpa.free(weights);

    const kept = try distinct(gpa, both, weights, &.{
        .{ .index = 1, .score = 90 },
        .{ .index = 0, .score = 70 },
    });
    defer gpa.free(kept);

    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqual(@as(usize, 1), kept[0].index);
    try testing.expectEqual(@as(i32, 90), kept[0].score);
}

test "a link no browser can open from the outside is left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var browser: Fixed = .{ .links = &.{
        .{ .url = "javascript:(function(){window.print()})()", .name = "Print" },
        .{ .url = "chrome://bookmarks", .name = "Bookmarks" },
        .{ .url = "chrome-extension://abcdef/options.html", .name = "Options" },
        .{ .url = "moz-extension://abcdef/options.html", .name = "Options" },
        .{ .url = "place:type=6&sort=14&maxResults=10", .name = "Most Visited" },
        .{ .url = "about:blank", .name = "Nothing" },
        .{ .url = "./chapter.md", .name = "Chapter" },
        .{ .url = "#top", .name = "Top" },
        .{ .url = "//example.com", .name = "Server" },
        .{ .url = "", .name = "Empty" },
        .{ .url = "https:", .name = "Bare" },
    } };

    const records = try recordsOf(arena.allocator(), browser.adapter("chromium"));
    try testing.expectEqual(@as(usize, 0), records.len);
}

test "a file, a mail and a plain page are all bookmarks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var browser: Fixed = .{ .links = &.{
        .{ .url = "file:///home/tester/notes.pdf", .name = "Notes" },
        .{ .url = "mailto:someone@example.com", .name = "Mail" },
        .{ .url = "https://ziglang.org", .name = "Zig" },
    } };

    const records = try recordsOf(arena.allocator(), browser.adapter("chromium"));
    try testing.expectEqual(@as(usize, 3), records.len);
}

test "a link without a name is titled with its url" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var browser: Fixed = .{ .links = &.{.{ .url = "https://example.com/x", .name = "" }} };

    const records = try recordsOf(arena.allocator(), browser.adapter("chromium"));

    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expectEqualStrings("https://example.com/x", records[0].title);
    try testing.expectEqualStrings("https://example.com/x", records[0].haystack);
}

test "the folder and the tags are kept and searched" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var browser: Fixed = .{ .links = &.{
        .{
            .url = "https://ziglang.org",
            .name = "Zig",
            .folder = "Dev/Languages",
            .tags = "lang,zig",
        },
        .{ .url = "https://sqlite.org", .name = "SQLite" },
    } };

    const records = try recordsOf(arena.allocator(), browser.adapter("firefox"));

    try testing.expectEqualStrings("Dev/Languages", records[0].folder);
    try testing.expectEqualStrings("lang,zig", records[0].tags);
    try testing.expectEqualStrings(
        "Zig https://ziglang.org Dev/Languages lang,zig",
        records[0].haystack,
    );
    try testing.expectEqualStrings("SQLite https://sqlite.org", records[1].haystack);
}

test "an index older than the settings that describe it is rebuilt" {
    try testing.expect(reconfigured(1000, 2000));
    try testing.expect(reconfigured(null, 2000));

    try testing.expect(!reconfigured(2000, 2000));
    try testing.expect(!reconfigured(3000, 2000));
    try testing.expect(!reconfigured(1000, null));
    try testing.expect(!reconfigured(null, null));
}
