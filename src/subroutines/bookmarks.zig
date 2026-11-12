const std = @import("std");
const counts_mod = @import("core").counts;
const indexed = @import("indexed.zig");
const launch = @import("../system/launch.zig");
const model = @import("../model.zig");
const rank = @import("core").rank;
const source = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const adapters = @import("bookmarks/adapter.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.bookmarks);

pub const chromium = @import("bookmarks/adapters/chromium.zig");
pub const firefox = @import("bookmarks/adapters/firefox.zig");
pub const markdown = @import("bookmarks/adapters/markdown.zig");

pub const Adapter = adapters.Adapter;
pub const Link = adapters.Link;

pub const table = tables.bookmarks;

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
    indexed: indexed.Indexed,
    environ: *const std.process.Environ.Map,
    members: []const Adapter,
    due: []bool,
    icon: [:0]const u8,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Index),
            .verb = "Open",
        };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.indexed.hits(owner, text, .{ .max_rows = max_rows, .narrow = &distinct });
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.indexed.picks(owner, .{ .limit = limit, .pool = &pooled });
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        const of = self.indexed.source.snapshot();
        const at = of.find(id) orelse return null;

        var total: rank.Weight = .{};
        for (of.entries, of.ids) |entry, other| {
            if (!std.mem.eql(u8, entry.key, of.entries[at].key)) continue;
            const weight = self.indexed.counts.weight(other);
            total.shown +|= weight.shown;
            total.chosen +|= weight.chosen;
        }
        return total;
    }

    pub fn forget(self: *Index, id: u64) void {
        const of = self.indexed.source.snapshot();
        const at = of.find(id) orelse return;

        var same: std.ArrayList(u64) = .empty;
        defer same.deinit(self.indexed.gpa);

        for (of.entries, of.ids) |entry, other| {
            if (!std.mem.eql(u8, entry.key, of.entries[at].key)) continue;
            same.append(self.indexed.gpa, other) catch |err| {
                return log.warn("cannot forget {s}: {t}", .{ entry.key, err });
            };
        }
        self.indexed.counts.forget(same.items);
    }

    pub fn stale(self: *Index) bool {
        return self.indexed.stale();
    }

    pub fn retire(self: *Index) void {
        self.indexed.retire();
        self.indexed.gpa.free(self.due);
    }

    pub fn refresh(self: *Index) void {
        var arena: std.heap.ArenaAllocator = .init(self.indexed.gpa);
        defer arena.deinit();

        if (self.indexed.stored(arena.allocator())) |records| self.adoptStored(arena.allocator(), records);
        if (!self.indexed.source.needs_refresh) return;

        log.debug("refreshing the index", .{});
        const records = rebuild(arena.allocator(), self) catch |err| {
            return source.report(table, "rebuild", err);
        };

        self.indexed.republish(records, &iconOf, self);
    }

    fn adoptStored(self: *Index, arena: Allocator, records: []const store_mod.Record) void {
        const kept = known(arena, self.members, records) catch |err| {
            return source.report(table, "load", err);
        };
        if (kept.len < records.len) self.indexed.source.needs_refresh = true;
        if (kept.len == 0) return;

        self.indexed.show(kept, &iconOf, self);
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        return chosen(self, gpa, id);
    }
};

pub fn open(context: subroutines.Context, members: []const Adapter) Allocator.Error!?Index {
    if (!context.wanted("bookmarks")) return null;

    const gpa = context.gpa;
    const stamp = context.stamp;
    const settings_at = context.settings_at;

    const due = try gpa.alloc(bool, members.len);
    errdefer gpa.free(due);
    @memset(due, true);

    var self: Index = .{
        .indexed = try .init(gpa, context.io, table, stamp, context.published),
        .environ = context.environ,
        .members = members,
        .due = due,
        .icon = subroutines.themedIcon(&icon_names),
    };
    errdefer self.indexed.retire();

    const found = self.indexed.prepare(context.store) orelse {
        self.indexed.source.needs_refresh = members.len > 0;
        return self;
    };

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    for (members, due) |member, *wanted| {
        const name = try store_mod.qualify(arena.allocator(), table, member.name);
        const at = found.updatedAt(name);

        wanted.* = store_mod.stale(at, stamp, member.max_age_minutes) or
            reconfigured(at, settings_at);
    }
    self.indexed.source.needs_refresh = std.mem.findScalar(bool, due, true) != null;
    return self;
}

fn rebuild(arena: Allocator, self: *Index) ![]store_mod.Record {
    const gpa = self.indexed.gpa;
    const file = self.indexed.path orelse return gather(arena, self.members);

    const conn = try store_mod.connect(file, .{});
    defer conn.close();

    try store_mod.create(gpa, conn, table);
    try store_mod.keepAdapters(gpa, conn, table, try names(arena, self.members));

    for (self.members, self.due) |member, due| {
        if (!due) continue;

        const collected = try member.collect(arena);
        if (!collected.complete) {
            log.warn(
                "the {s} bookmarks indexed before are kept, since a file could not be read",
                .{member.name},
            );
            continue;
        }

        try store_mod.replace(
            gpa,
            conn,
            table,
            .{ .adapter = member.name },
            try recordsOf(arena, member.name, collected.links),
            self.indexed.stamp,
        );
    }

    return store_mod.read(arena, conn, table);
}

fn gather(arena: Allocator, members: []const Adapter) Allocator.Error![]store_mod.Record {
    var records: std.ArrayList(store_mod.Record) = .empty;

    for (members) |member| {
        const collected = try member.collect(arena);
        try records.appendSlice(arena, try recordsOf(arena, member.name, collected.links));
    }

    return records.toOwnedSlice(arena);
}

fn recordsOf(
    arena: Allocator,
    adapter: []const u8,
    links: []const Link,
) Allocator.Error![]store_mod.Record {
    var records: std.ArrayList(store_mod.Record) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (links) |link| {
        if (!openable(link.url)) continue;

        const found = try seen.getOrPut(arena, link.url);
        if (found.found_existing) continue;

        try records.append(arena, .{
            .adapter = adapter,
            .key = link.url,
            .title = if (link.name.len > 0) link.name else link.url,
            .detail = link.url,
            .icon = "",
            .folder = link.folder,
            .tags = link.tags,
            .haystack = try haystackOf(arena, link),
        });
    }

    log.debug("{s} collected {d} links", .{ adapter, records.items.len });
    return records.toOwnedSlice(arena);
}

fn openable(url: []const u8) bool {
    const colon = std.mem.findScalar(u8, url, ':') orelse return false;
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

fn reconfigured(updated_at: ?i64, settings_at: ?i64) bool {
    const written = settings_at orelse return false;
    const at = updated_at orelse return true;
    return at < written;
}

fn iconOf(context: ?*anyopaque, _: *source.Snapshot, _: store_mod.Record) model.Icon {
    const self: *Index = @ptrCast(@alignCast(context orelse return .none));
    return .{ .name = self.icon };
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

const Place = struct {
    best: usize,
    total: rank.Weight,
};

fn pooled(
    gpa: Allocator,
    of: *source.Snapshot,
    weights: []rank.Weight,
) Allocator.Error!void {
    var places: std.StringHashMapUnmanaged(Place) = .empty;
    defer places.deinit(gpa);

    for (of.entries, weights, 0..) |entry, weight, at| {
        const found = try places.getOrPut(gpa, entry.key);
        if (!found.found_existing) {
            found.value_ptr.* = .{ .best = at, .total = weight };
            continue;
        }

        const place = found.value_ptr;
        place.total.shown +|= weight.shown;
        place.total.chosen +|= weight.chosen;
        if (better(weight, weights[place.best])) place.best = at;
    }

    for (of.entries, weights, 0..) |entry, *weight, at| {
        const place = places.get(entry.key).?;
        weight.* = if (place.best == at) place.total else .{};
    }
}

fn chosen(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
    const of = self.indexed.source.snapshot();
    const index = of.find(id) orelse return .keep;

    const entry = of.entries[index];
    if (!launch.uri(gpa, self.environ, entry.key)) return .keep;

    self.indexed.noteChosen(id);
    return .close;
}

test {
    _ = adapters;
    _ = chromium;
    _ = firefox;
    _ = markdown;
}

const testing = std.testing;
const config_mod = @import("../config.zig");

const Fixed = struct {
    links: []const Link,
    complete: bool = true,

    fn adapter(self: *Fixed, name: []const u8) Adapter {
        return .{
            .name = name,
            .max_age_minutes = 60,
            .context = self,
            .vtable = &fixed,
        };
    }

    fn collect(context: *anyopaque, _: Allocator) Allocator.Error!adapters.Collected {
        const self: *Fixed = @ptrCast(@alignCast(context));
        return .{ .links = self.links, .complete = self.complete };
    }
};

const fixed: Adapter.VTable = .{ .collect = &Fixed.collect };

fn plainIcon(_: ?*anyopaque, _: *source.Snapshot, _: store_mod.Record) model.Icon {
    return .none;
}

test "the first of two links to the same url wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const records = try recordsOf(arena.allocator(), "markdown", &.{
        .{ .url = "https://ziglang.org", .name = "Zig" },
        .{ .url = "https://sqlite.org", .name = "SQLite" },
        .{ .url = "https://ziglang.org", .name = "The Zig language" },
    });

    try testing.expectEqual(2, records.len);
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

    try testing.expectEqual(2, records.len);
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
    try testing.expectEqual(1, kept.len);
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

    const of = try source.build(gpa, &duplicates, &plainIcon, null);
    defer of.destroy(gpa);

    const weights = try gpa.alloc(rank.Weight, of.entries.len);
    defer gpa.free(weights);
    @memset(weights, .{});
    weights[1] = .{ .chosen = 9 };

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

    const of = try source.build(gpa, &bare, &plainIcon, null);
    defer of.destroy(gpa);

    var records: [2]store_mod.Record = .{ duplicates[0], duplicates[0] };
    records[1].adapter = "chromium";
    records[1].title = "Ziglang";

    const both = try source.build(gpa, &records, &plainIcon, null);
    defer both.destroy(gpa);

    const weights = try gpa.alloc(rank.Weight, both.entries.len);
    defer gpa.free(weights);
    @memset(weights, .{});

    const kept = try distinct(gpa, both, weights, &.{
        .{ .index = 1, .score = 90 },
        .{ .index = 0, .score = 70 },
    });
    defer gpa.free(kept);

    try testing.expectEqual(1, kept.len);
    try testing.expectEqual(1, kept[0].index);
    try testing.expectEqual(90, kept[0].score);
}

test "the picks of one url are added up across adapters and listed once" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try indexed.Indexed.init(testing.allocator, testing.io, table, 0, null);
    defer self.retire();

    const records = duplicates;
    try self.adopt(&records, &plainIcon, null);
    for (records) |record| {
        self.counts.note(counts_mod.idOf(record.adapter, record.key), .{ .chosen = 1 });
    }

    const found = try self.picks(owner, .{ .limit = 5, .pool = &pooled });

    try testing.expectEqual(1, found.hits.len);
    try testing.expectEqualStrings("Zig", found.hits[0].row.title);
    try testing.expectEqual(2, found.hits[0].score);
}

test "the row chosen most often stands for its url" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    const records = [_]store_mod.Record{
        duplicates[0],
        duplicates[1],
        .{
            .adapter = "firefox",
            .key = "https://ziglang.org",
            .title = "Zig language",
            .detail = "https://ziglang.org",
            .icon = "",
            .haystack = "Zig language https://ziglang.org",
        },
        duplicates[2],
    };

    var self = try indexed.Indexed.init(testing.allocator, testing.io, table, 0, null);
    defer self.retire();
    try self.adopt(&records, &plainIcon, null);
    self.counts.note(counts_mod.idOf("chromium", "https://ziglang.org"), .{ .chosen = 9 });
    self.counts.note(counts_mod.idOf("firefox", "https://ziglang.org"), .{ .chosen = 12 });

    const found = try self.picks(owner, .{ .limit = 5, .pool = &pooled });

    try testing.expectEqual(1, found.hits.len);
    try testing.expectEqualStrings("Zig language", found.hits[0].row.title);
    try testing.expectEqual(counts_mod.idOf("firefox", "https://ziglang.org"), found.hits[0].row.id);
    try testing.expectEqual(21, found.hits[0].score);
}

test "a link no browser can open from the outside is left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const records = try recordsOf(arena.allocator(), "chromium", &.{
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
    });
    try testing.expectEqual(0, records.len);
}

test "a file, a mail and a plain page are all bookmarks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const records = try recordsOf(arena.allocator(), "chromium", &.{
        .{ .url = "file:///home/tester/notes.pdf", .name = "Notes" },
        .{ .url = "mailto:someone@example.com", .name = "Mail" },
        .{ .url = "https://ziglang.org", .name = "Zig" },
    });
    try testing.expectEqual(3, records.len);
}

test "a link without a name is titled with its url" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const records = try recordsOf(arena.allocator(), "chromium", &.{
        .{ .url = "https://example.com/x", .name = "" },
    });

    try testing.expectEqual(1, records.len);
    try testing.expectEqualStrings("https://example.com/x", records[0].title);
    try testing.expectEqualStrings("https://example.com/x", records[0].haystack);
}

test "the folder and the tags are kept and searched" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const records = try recordsOf(arena.allocator(), "firefox", &.{
        .{
            .url = "https://ziglang.org",
            .name = "Zig",
            .folder = "Dev/Languages",
            .tags = "lang,zig",
        },
        .{ .url = "https://sqlite.org", .name = "SQLite" },
    });

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

test "a bookmark's counters are those of its url in every adapter, and so is forgetting" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self: Index = .{
        .indexed = try indexed.Indexed.init(testing.allocator, testing.io, table, 0, null),
        .environ = &environ,
        .members = &.{},
        .due = &.{},
        .icon = "",
    };
    defer self.indexed.retire();

    const records = duplicates;
    try self.indexed.adopt(&records, &plainIcon, null);

    const from_markdown = counts_mod.idOf("markdown", "https://ziglang.org");
    const from_chromium = counts_mod.idOf("chromium", "https://ziglang.org");
    const other = counts_mod.idOf("chromium", "https://sqlite.org");
    self.indexed.counts.note(from_markdown, .{ .shown = 4, .chosen = 1 });
    self.indexed.counts.note(from_chromium, .{ .shown = 1, .chosen = 2 });
    self.indexed.counts.note(other, .{ .chosen = 3 });

    try testing.expectEqual(rank.Weight{ .shown = 5, .chosen = 3 }, self.counters(from_chromium).?);
    try testing.expectEqual(rank.Weight{ .shown = 5, .chosen = 3 }, self.counters(from_markdown).?);

    self.forget(from_chromium);
    try testing.expectEqual(rank.Weight{}, self.indexed.counts.weight(from_markdown));
    try testing.expectEqual(rank.Weight{}, self.indexed.counts.weight(from_chromium));
    try testing.expectEqual(rank.Weight{ .chosen = 3 }, self.counters(other).?);
}

test "without a store, an adapter's links are used even when one of its files was not read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var notes: Fixed = .{
        .links = &.{.{ .url = "https://ziglang.org", .name = "Zig" }},
        .complete = false,
    };

    const records = try gather(arena.allocator(), &.{notes.adapter("markdown")});
    try testing.expectEqual(1, records.len);
}

const Shelf = struct {
    tmp: testing.TmpDir,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    arena: std.heap.ArenaAllocator,
    environ: std.process.Environ.Map,
    store: ?*store_mod.Store = null,

    fn init(self: *Shelf) !void {
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .arena = .init(testing.allocator),
            .environ = .init(testing.allocator),
        };
        errdefer self.deinit();

        self.root = self.buffer[0..try self.tmp.dir.realPath(testing.io, &self.buffer)];
        self.store = try store_mod.Store.open(
            testing.allocator,
            testing.io,
            try self.pathOf("sysdeck.db"),
        );
    }

    fn deinit(self: *Shelf) void {
        if (self.store) |found| found.close();
        self.environ.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn pathOf(self: *Shelf, name: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena.allocator(), &.{ self.root, name });
    }

    fn write(self: *Shelf, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }

    fn indexOf(self: *Shelf, members: []const Adapter, due: []bool) !Index {
        var index: Index = .{
            .indexed = try indexed.Indexed.init(testing.allocator, testing.io, table, 0, null),
            .environ = &self.environ,
            .members = members,
            .due = due,
            .icon = "",
        };
        index.indexed.path = self.store.?.path;
        index.indexed.source.needs_refresh = std.mem.findScalar(bool, due, true) != null;
        return index;
    }

    fn stampOf(self: *Shelf, adapter: []const u8) !?i64 {
        return self.store.?.updatedAt(try store_mod.qualify(self.arena.allocator(), table, adapter));
    }
};

fn listed(index: *Index, stamp: i64) usize {
    index.indexed.stamp = stamp;
    index.refresh();
    return index.indexed.source.snapshot().entries.len;
}

test "a bookmarks file that cannot be read keeps its rows and the stamp of the read before" {
    var shelf: Shelf = undefined;
    try shelf.init();
    defer shelf.deinit();

    try shelf.write("links.md", "[Zig](https://ziglang.org) and [SQLite](https://sqlite.org)\n");

    const files = [_][]const u8{try shelf.pathOf("links.md")};
    var notes: markdown.Adapter = .{
        .io = testing.io,
        .home = "",
        .files = &files,
        .max_age_minutes = 60,
    };
    const members = [_]Adapter{notes.adapter()};
    var due = [_]bool{true};

    var index = try shelf.indexOf(&members, &due);
    defer index.indexed.retire();

    try testing.expectEqual(2, listed(&index, 1000));

    try shelf.tmp.dir.deleteFile(testing.io, "links.md");
    try shelf.tmp.dir.createDir(testing.io, "links.md", .default_dir);

    try testing.expectEqual(2, listed(&index, 2000));
    try testing.expectEqual(1000, try shelf.stampOf(markdown.name));
}

test "a bookmarks file of garbage keeps the rows read before" {
    var shelf: Shelf = undefined;
    try shelf.init();
    defer shelf.deinit();

    try shelf.write("Bookmarks",
        \\{"roots": {"other": {"children": [
        \\  {"type": "url", "name": "Zig", "url": "https://ziglang.org"}
        \\]}}}
    );

    const files = [_][]const u8{try shelf.pathOf("Bookmarks")};
    var browser: chromium.Adapter = .{
        .io = testing.io,
        .home = "",
        .files = &files,
        .max_age_minutes = 60,
    };
    const members = [_]Adapter{browser.adapter()};
    var due = [_]bool{true};

    var index = try shelf.indexOf(&members, &due);
    defer index.indexed.retire();

    try testing.expectEqual(1, listed(&index, 1000));

    try shelf.write("Bookmarks", "{\"roots\": {\"other\": {\"chil");

    try testing.expectEqual(1, listed(&index, 2000));
    try testing.expectEqual(1000, try shelf.stampOf(chromium.name));
}

test "a bookmarks file that is gone takes its rows with it" {
    var shelf: Shelf = undefined;
    try shelf.init();
    defer shelf.deinit();

    try shelf.write("links.md", "[Zig](https://ziglang.org)\n");

    const files = [_][]const u8{try shelf.pathOf("links.md")};
    var notes: markdown.Adapter = .{
        .io = testing.io,
        .home = "",
        .files = &files,
        .max_age_minutes = 60,
    };
    const members = [_]Adapter{notes.adapter()};
    var due = [_]bool{true};

    var index = try shelf.indexOf(&members, &due);
    defer index.indexed.retire();

    try testing.expectEqual(1, listed(&index, 1000));

    try shelf.tmp.dir.deleteFile(testing.io, "links.md");

    try testing.expectEqual(0, listed(&index, 2000));
    try testing.expectEqual(2000, try shelf.stampOf(markdown.name));
}

test "opening marks the bookmarks due until each adapter was read within its age" {
    var shelf: Shelf = undefined;
    try shelf.init();
    defer shelf.deinit();

    try shelf.write("links.md", "[Zig](https://ziglang.org)\n");

    const files = [_][]const u8{try shelf.pathOf("links.md")};
    var notes: markdown.Adapter = .{
        .io = testing.io,
        .home = "",
        .files = &files,
        .max_age_minutes = 60,
    };
    const members = [_]Adapter{notes.adapter()};
    const settings: config_mod.Config = .{};
    const context: subroutines.Context = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .environ = &shelf.environ,
        .settings = &settings,
        .store = shelf.store,
        .stamp = 1000,
    };

    var first = (try open(context, &members)).?;
    try testing.expect(first.indexed.source.needs_refresh);
    first.refresh();
    first.retire();

    var later = context;
    later.stamp = 2000;
    var second = (try open(later, &members)).?;
    defer second.retire();
    try testing.expect(!second.indexed.source.needs_refresh);
}
