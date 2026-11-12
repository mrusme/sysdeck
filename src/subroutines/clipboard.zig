const std = @import("std");
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const clipboard = @import("../clipboard/clipboard.zig");
const clock = @import("core").clock;
const copy = @import("../system/copy.zig");
const model = @import("../model.zig");
const media = @import("core").media;
const rank = @import("core").rank;
const counts_mod = @import("core").counts;
const subroutines = @import("../subroutines.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.clipboard);

pub const table = clipboard.table;

const title_chars = 64;

const history_rows = 100;
const max_rows = 200;
const no_limit = -1;
const text_supertype: [*:0]const u8 = "text/plain";
const fallback_icon: [:0]const u8 = "edit-paste";
const delete_icon: [:0]const u8 = "edit-delete-symbolic";

const Action = enum(u64) { delete = 1 };
const day_format: [*:0]const u8 = "%Y-%m-%d";
const time_format: [*:0]const u8 = "%H:%M";
const stamp_format: [*:0]const u8 = "%Y-%m-%d %H:%M";
const day_length = "2026-08-26".len;

pub const Index = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    limits: clipboard.Limits,
    store: ?clipboard.Store = null,
    path: ?[:0]u8 = null,
    counts: counts_mod.Counts,
    settled: ?subroutines.Settled = null,

    guard: std.Io.Mutex = .init,
    work: std.Io.Group = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Search),
            .verb = "Copy",
        };
    }

    pub fn history(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(History),
            .verb = "Copy",
        };
    }

    pub fn stop(self: *Index) void {
        self.stopping.store(true, .release);
    }

    pub fn retire(self: *Index) void {
        self.stop();
        self.work.await(self.io) catch |err| switch (err) {
            error.Canceled => {},
        };

        self.counts.flush();
        self.counts.deinit();
        if (self.store) |*found| found.close();
        self.store = null;
        if (self.path) |found| self.gpa.free(found);
        self.path = null;
    }

    fn hits(
        self: *Index,
        owner: *subroutines.Owner,
        query: []const u8,
        limit: i64,
        weighted: bool,
    ) subroutines.Error!subroutines.Output {
        const store = if (self.store) |*found| found else return .nothing;

        self.guard.lockUncancelable(self.io);
        defer self.guard.unlock(self.io);

        const scratch = owner.allocator();
        const entries = store.recent(scratch, limit) catch |err| {
            log.warn("cannot read the history: {t}", .{err});
            return .nothing;
        };
        if (entries.len == 0) return .nothing;

        const haystacks = try scratch.alloc([]const u8, entries.len);
        const weights = if (weighted) try scratch.alloc(rank.Weight, entries.len) else null;

        for (entries, 0..) |entry, at| {
            haystacks[at] = entry.preview;
            if (weights) |found| found[at] = self.weightOf(entry);
        }

        const matches = try rank.rank(scratch, haystacks, weights, query);
        if (matches.len == 0) return .nothing;

        const shown = matches[0..@min(matches.len, max_rows)];
        for (shown) |match| self.note(entries[match.index], .{ .shown = 1 });

        return .{ .hits = try self.hitsOf(owner, entries, shown) };
    }

    fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        const store = if (self.store) |*found| found else return .nothing;

        self.guard.lockUncancelable(self.io);
        defer self.guard.unlock(self.io);

        const scratch = owner.allocator();
        const entries = store.recent(scratch, self.searchLimit()) catch |err| {
            log.warn("cannot read the history: {t}", .{err});
            return .nothing;
        };

        const weights = try scratch.alloc(rank.Weight, entries.len);
        for (entries, weights) |entry, *weight| weight.* = self.weightOf(entry);

        const matches = try rank.picks(scratch, weights, limit);
        if (matches.len == 0) return .nothing;

        return .{ .hits = try self.hitsOf(owner, entries, matches) };
    }

    fn hitsOf(
        self: *Index,
        owner: *subroutines.Owner,
        entries: []const clipboard.Entry,
        matches: []const rank.Match,
    ) Allocator.Error![]subroutines.Hit {
        const scratch = owner.allocator();
        const stamp: Stamp = .of(scratch, clock.now(self.io));

        const built = try scratch.alloc(subroutines.Hit, matches.len);
        for (matches, built) |match, *hit| {
            const entry = entries[match.index];
            hit.* = .{
                .row = .{
                    .id = @bitCast(entry.id),
                    .icon = iconOf(owner, entry.icon),
                    .title = try titleOf(scratch, entry),
                    .detail = try detailOf(scratch, stamp, entry),
                    .media = .{
                        .mime = entry.mime,
                        .size = sizeOf(entry.bytes),
                        .id = @bitCast(entry.id),
                        .context = self,
                        .load = &loadMedia,
                    },
                },
                .score = match.score,
            };
        }

        return built;
    }

    fn content(self: *Index, arena: Allocator, id: i64) ?clipboard.Content {
        const store = if (self.store) |*found| found else return null;

        self.guard.lockUncancelable(self.io);
        defer self.guard.unlock(self.io);

        return store.contentOf(arena, id) catch |err| {
            log.warn("cannot read entry {d}: {t}", .{ id, err });
            return null;
        };
    }

    fn take(self: *Index, gpa: Allocator, id: u64) ?clipboard.Content {
        const store = if (self.store) |*found| found else return null;
        const row: i64 = @bitCast(id);

        self.guard.lockUncancelable(self.io);
        defer self.guard.unlock(self.io);

        const found = store.contentOf(gpa, row) catch |err| {
            log.warn("cannot read entry {d}: {t}", .{ row, err });
            return null;
        };
        const taken = found orelse return null;

        self.counts.note(counts_mod.id(&clipboard.digestOf(taken.bytes)), .{ .chosen = 1 });
        return taken;
    }

    fn counted(self: *Index, id: u64) ?u64 {
        const store = if (self.store) |*found| found else return null;
        const row: i64 = @bitCast(id);

        self.guard.lockUncancelable(self.io);
        defer self.guard.unlock(self.io);

        const digest = store.digestAt(row) catch |err| {
            log.warn("cannot read entry {d}: {t}", .{ row, err });
            return null;
        } orelse return null;
        return counts_mod.id(&digest);
    }

    fn remove(self: *Index, id: u64) subroutines.Outcome {
        _ = self.counted(id) orelse return .keep;
        const file = self.path orelse return .keep;
        const row: i64 = @bitCast(id);

        self.work.concurrent(self.io, erase, .{ self, file, row }) catch |err| {
            log.warn("cannot delete entry {d}: {t}", .{ row, err });
            return .keep;
        };
        return .busy;
    }

    fn erase(self: *Index, file: [:0]const u8, row: i64) void {
        defer if (!self.stopping.load(.acquire)) {
            if (self.settled) |found| found.call(.{.refresh});
        };

        var store = clipboard.Store.openAt(self.gpa, file) catch |err| {
            return log.warn("cannot open {s}: {t}, so entry {d} is kept", .{ file, err, row });
        };
        defer store.close();

        const digest = store.delete(row) catch |err| {
            return log.warn("cannot delete entry {d}: {t}", .{ row, err });
        } orelse return;
        self.counts.scrub(&.{counts_mod.id(&digest)});
    }

    fn weightOf(self: *Index, entry: clipboard.Entry) rank.Weight {
        return self.counts.weight(counts_mod.id(&entry.digest));
    }

    fn note(self: *Index, entry: clipboard.Entry, by: rank.Weight) void {
        self.counts.note(counts_mod.id(&entry.digest), by);
    }

    fn searchLimit(self: *Index) i64 {
        if (self.limits.max_items > 0) return self.limits.max_items;
        return no_limit;
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("clipboard")) return null;

    const gpa = context.gpa;
    var self: Index = .{
        .gpa = gpa,
        .io = context.io,
        .environ = context.environ,
        .limits = context.resolved.clipboard,
        .counts = .open(gpa, context.io, table, context.store),
        .settled = context.settled,
    };
    errdefer self.counts.deinit();

    const path = (try clipboard.defaultPath(gpa, context.environ)) orelse {
        log.warn("neither XDG_DATA_HOME nor HOME is set, so there is no history", .{});
        return self;
    };
    defer gpa.free(path);

    const file = try gpa.dupeSentinel(u8, path, 0);
    self.store = clipboard.Store.open(gpa, context.io, path) catch |err| {
        gpa.free(file);
        log.warn("cannot open {s}: {t}, so there is no history", .{ path, err });
        return self;
    };
    self.path = file;
    return self;
}

const Search = struct {
    pub const Context = Index;

    pub const choose = shared.choose;
    pub const counters = shared.counters;
    pub const forget = shared.forget;
    pub const actions = shared.actions;
    pub const perform = shared.perform;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        const query = std.mem.trim(u8, text, " \t");
        if (query.len == 0) return .nothing;

        return self.hits(owner, query, self.searchLimit(), true);
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.picks(owner, limit);
    }
};

const History = struct {
    pub const Context = Index;

    pub const choose = shared.choose;
    pub const counters = shared.counters;
    pub const forget = shared.forget;
    pub const actions = shared.actions;
    pub const perform = shared.perform;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.hits(owner, std.mem.trim(u8, text, " \t"), history_rows, false);
    }
};

fn loadMedia(context: ?*anyopaque, arena: Allocator, id: u64) ?media.Payload {
    const self: *Index = @ptrCast(@alignCast(context orelse return null));
    const found = self.content(arena, @bitCast(id)) orelse return null;
    return .{ .bytes = found.bytes };
}

fn sizeOf(value: i64) u64 {
    return std.math.cast(u64, value) orelse 0;
}

const shared = struct {
    pub fn actions(
        self: *Index,
        arena: Allocator,
        id: u64,
    ) subroutines.Error![]const subroutines.Action {
        _ = self.counted(id) orelse return &.{};

        const found = try arena.alloc(subroutines.Action, 1);
        found[0] = .{
            .id = @backingInt(Action.delete),
            .title = "Delete",
            .detail = "Removes it from the history for good",
            .icon = .{ .name = delete_icon },
        };
        return found;
    }

    pub fn perform(self: *Index, _: Allocator, id: u64, action: u64) subroutines.Outcome {
        return switch (std.enums.fromInt(Action, action) orelse return .keep) {
            .delete => self.remove(id),
        };
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.counts.weight(self.counted(id) orelse return null);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.counts.forget(&.{self.counted(id) orelse return});
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const content = self.take(arena.allocator(), id) orelse return .keep;

        const copied = copy.put(arena.allocator(), self.environ, .{
            .mime = content.mime,
            .bytes = content.bytes,
        });

        return if (copied) .close else .keep;
    }
};

fn iconOf(owner: *subroutines.Owner, stored: []const u8) model.Icon {
    if (stored.len == 0) return .{ .name = fallback_icon };

    const text = owner.allocator().dupeSentinel(u8, stored, 0) catch return .{ .name = fallback_icon };
    const icon = gio.g_icon_new_for_string(text.ptr, null) orelse return .{ .name = fallback_icon };
    return owner.keep(icon);
}

fn titleOf(arena: Allocator, entry: clipboard.Entry) Allocator.Error![:0]const u8 {
    const mime = try arena.dupeSentinel(u8, entry.mime, 0);
    if (entry.preview.len > 0 and gio.g_content_type_is_a(mime.ptr, text_supertype) != c.FALSE) {
        return shortened(arena, entry.preview);
    }

    const label = gio.g_content_type_get_description(mime.ptr) orelse {
        return arena.dupeSentinel(u8, entry.mime, 0);
    };
    defer glib.g_free(label);

    return arena.dupeSentinel(u8, std.mem.span(label), 0);
}

fn shortened(gpa: Allocator, text: []const u8) Allocator.Error![:0]const u8 {
    var seen: usize = 0;
    var at: usize = 0;

    while (at < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
        if (at + length > text.len) break;
        if (seen == title_chars) return gpa.printSentinel("{s}...", .{text[0..at]}, 0);

        seen += 1;
        at += length;
    }

    return gpa.dupeSentinel(u8, text, 0);
}

fn detailOf(
    arena: Allocator,
    stamp: Stamp,
    entry: clipboard.Entry,
) Allocator.Error![:0]const u8 {
    const when = stamp.describe(arena, entry.updated_at);
    if (entry.copied <= 1) return arena.dupeSentinel(u8, when, 0);

    return arena.printSentinel(
        "{s} \u{00b7} copied {d} times",
        .{ when, entry.copied },
        0,
    );
}

pub const Stamp = struct {
    at: i64,
    today: [day_length]u8 = @splat(0),
    yesterday: [day_length]u8 = @splat(0),

    fn of(arena: Allocator, at: i64) Stamp {
        var self: Stamp = .{ .at = at };

        const local = glib.g_date_time_new_from_unix_local(@divFloor(at, std.time.ms_per_s)) orelse {
            return self;
        };
        defer glib.g_date_time_unref(local);

        copyDay(&self.today, formatted(arena, local, day_format));

        const before = glib.g_date_time_add_days(local, -1) orelse return self;
        defer glib.g_date_time_unref(before);

        copyDay(&self.yesterday, formatted(arena, before, day_format));
        return self;
    }

    fn describe(self: Stamp, arena: Allocator, updated_at: i64) []const u8 {
        const elapsed = @max(self.at - updated_at, 0);

        if (elapsed < std.time.ms_per_min) return "just now";
        if (elapsed < std.time.ms_per_hour) return plural(arena, "minute", elapsed / std.time.ms_per_min);
        if (elapsed < std.time.ms_per_day) return plural(arena, "hour", elapsed / std.time.ms_per_hour);

        const local = glib.g_date_time_new_from_unix_local(@divFloor(updated_at, std.time.ms_per_s)) orelse {
            return plural(arena, "day", elapsed / std.time.ms_per_day);
        };
        defer glib.g_date_time_unref(local);

        const day = formatted(arena, local, day_format);
        if (std.mem.eql(u8, day, &self.yesterday)) {
            const time = formatted(arena, local, time_format);
            return arena.print("yesterday {s}", .{time}) catch time;
        }

        if (elapsed < std.time.ms_per_week) {
            return plural(arena, "day", elapsed / std.time.ms_per_day);
        }
        return formatted(arena, local, stamp_format);
    }
};

fn copyDay(out: *[day_length]u8, text: []const u8) void {
    if (text.len != out.len) return;
    @memcpy(out, text);
}

fn formatted(arena: Allocator, local: *c.GDateTime, format: [*:0]const u8) []const u8 {
    const text = glib.g_date_time_format(local, format) orelse return "";
    defer glib.g_free(text);
    return arena.dupe(u8, std.mem.span(text)) catch "";
}

fn plural(arena: Allocator, unit: []const u8, count: i64) []const u8 {
    const suffix: []const u8 = if (count == 1) "" else "s";
    return arena.print("{d} {s}{s} ago", .{ count, unit, suffix }) catch unit;
}

const testing = std.testing;
const tmpPath = @import("core").xdg.tmpPath;
const config_mod = @import("../config.zig");
const store_mod = @import("core").store;

fn stampAt(arena: Allocator, at: i64) Stamp {
    return .of(arena, at);
}

fn described(at: i64, updated_at: i64) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const stamp = stampAt(arena.allocator(), at);
    return testing.allocator.dupe(u8, stamp.describe(arena.allocator(), updated_at));
}

fn expectDescribed(wanted: []const u8, at: i64, updated_at: i64) !void {
    const found = try described(at, updated_at);
    defer testing.allocator.free(found);
    try testing.expectEqualStrings(wanted, found);
}

const noon = 1787_000_000_000;

test "a fresh entry reads as just now" {
    try expectDescribed("just now", noon, noon);
    try expectDescribed("just now", noon, noon - std.time.ms_per_s * 59);
}

test "an entry in the last hour reads in minutes" {
    try expectDescribed("1 minute ago", noon, noon - std.time.ms_per_min);
    try expectDescribed("5 minutes ago", noon, noon - 5 * std.time.ms_per_min);
    try expectDescribed("59 minutes ago", noon, noon - 59 * std.time.ms_per_min);
}

test "an entry in the last day reads in hours" {
    try expectDescribed("1 hour ago", noon, noon - std.time.ms_per_hour);
    try expectDescribed("3 hours ago", noon, noon - 3 * std.time.ms_per_hour);
    try expectDescribed("23 hours ago", noon, noon - 23 * std.time.ms_per_hour);
}

test "an entry within the week reads in days" {
    const found = try described(noon, noon - 4 * std.time.ms_per_day);
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("4 days ago", found);
}

test "the day before reads as yesterday and a clock time" {
    const found = try described(noon, noon - std.time.ms_per_day);
    defer testing.allocator.free(found);

    try testing.expect(std.mem.startsWith(u8, found, "yesterday "));
    try testing.expectEqual("yesterday 00:00".len, found.len);
}

test "an old entry reads as a date and a clock time" {
    const found = try described(noon, noon - 30 * std.time.ms_per_day);
    defer testing.allocator.free(found);

    try testing.expectEqual("2026-08-26 14:02".len, found.len);
    try testing.expectEqual('-', found[4]);
    try testing.expectEqual(':', found[13]);
}

test "a clock that runs backwards still reads as just now" {
    try expectDescribed("just now", noon, noon + std.time.ms_per_hour);
}

test "the unit is singular at one and plural everywhere else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("1 hour ago", plural(arena.allocator(), "hour", 1));
    try testing.expectEqualStrings("2 hours ago", plural(arena.allocator(), "hour", 2));
    try testing.expectEqualStrings("0 days ago", plural(arena.allocator(), "day", 0));
}

fn cut(text: []const u8) ![:0]const u8 {
    return shortened(testing.allocator, text);
}

test "a short entry is titled with every character of it" {
    const found = try cut("the quick brown fox");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("the quick brown fox", found);
}

test "an entry of exactly the limit is left whole" {
    const exact: [title_chars]u8 = @splat('a');

    const found = try cut(&exact);
    defer testing.allocator.free(found);

    try testing.expectEqualStrings(&exact, found);
}

test "a longer entry is cut and told about with an ellipsis" {
    const long: [title_chars + 40]u8 = @splat('b');

    const found = try cut(&long);
    defer testing.allocator.free(found);

    try testing.expectEqual(title_chars + 3, found.len);
    try testing.expect(std.mem.endsWith(u8, found, "..."));
    try testing.expectEqualStrings(long[0..title_chars], found[0..title_chars]);
}

test "the cut counts characters, not bytes" {
    const wide: [title_chars + 10][2]u8 = @splat("\u{00e4}".*);

    const found = try cut(std.mem.sliceAsBytes(&wide));
    defer testing.allocator.free(found);

    try testing.expect(std.unicode.utf8ValidateSlice(found));
    try testing.expectEqual(title_chars, try std.unicode.utf8CountCodepoints(found[0 .. found.len - 3]));
}

test "nothing at all is still nothing" {
    const found = try cut("");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("", found);
}

fn title(arena: Allocator, entry: clipboard.Entry) ![:0]const u8 {
    return titleOf(arena, entry);
}

const blank: clipboard.Entry = .{
    .id = 1,
    .digest = @splat(0),
    .mime = "",
    .icon = "",
    .preview = "",
    .bytes = 0,
    .created_at = 0,
    .updated_at = 0,
    .copied = 1,
};

test "a text entry is titled with what was copied" {
    var entry = blank;
    entry.mime = "text/plain";
    entry.preview = "the quick brown fox";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try title(arena.allocator(), entry);

    try testing.expectEqualStrings("the quick brown fox", found);
}

test "a binary entry is titled with what kind of thing it is" {
    var entry = blank;
    entry.mime = "image/png";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try title(arena.allocator(), entry);

    try testing.expectEqualStrings("PNG image", found);
}

test "an audio entry says so too" {
    var entry = blank;
    entry.mime = "audio/mpeg";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try title(arena.allocator(), entry);

    try testing.expectEqualStrings("MP3 audio", found);
}

test "a type nothing knows falls back to the type itself" {
    var entry = blank;
    entry.mime = "application/x-nothing-knows-this";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try title(arena.allocator(), entry);

    try testing.expect(found.len > 0);
}

test "the entries picked twice are recommended, the newer first on a tie" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self: Index = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .environ = &environ,
        .limits = .{},
        .counts = .{ .gpa = testing.allocator, .io = testing.io, .source = table },
        .store = try clipboard.Store.openAt(testing.allocator, ":memory:"),
    };
    defer self.retire();

    for ([_][]const u8{ "once", "older", "newer", "most" }, 0..) |body, at| {
        try self.store.?.put(.{
            .digest = clipboard.digestOf(body),
            .mime = "text/plain",
            .icon = "",
            .preview = body,
            .content = body,
            .at = @intCast(1000 + at),
        });
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const stored = try self.store.?.recent(arena.allocator(), 10);
    for (stored, [_]u32{ 5, 2, 2, 1 }) |entry, chosen| {
        self.note(entry, .{ .chosen = chosen });
    }

    const found = try Search.picks(&self, owner, 5);

    try testing.expectEqual(3, found.hits.len);
    try testing.expectEqualStrings("most", found.hits[0].row.title);
    try testing.expectEqualStrings("newer", found.hits[1].row.title);
    try testing.expectEqualStrings("older", found.hits[2].row.title);
    try testing.expectEqual(5, found.hits[0].score);

    self.note(stored[3], .{ .chosen = 1 });

    const counted = try Search.picks(&self, owner, 5);

    try testing.expectEqual(4, counted.hits.len);
    try testing.expectEqualStrings("once", counted.hits[3].row.title);
}

test "an entry's counters follow its content, and forgetting them keeps how often it was copied" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self: Index = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .environ = &environ,
        .limits = .{},
        .counts = .{ .gpa = testing.allocator, .io = testing.io, .source = table },
        .store = try clipboard.Store.openAt(testing.allocator, ":memory:"),
    };
    defer self.retire();

    for ([_][]const u8{ "kept", "twice", "twice" }, 0..) |body, at| {
        try self.store.?.put(.{
            .digest = clipboard.digestOf(body),
            .mime = "text/plain",
            .icon = "",
            .preview = body,
            .content = body,
            .at = @intCast(1000 + at),
        });
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const stored = try self.store.?.recent(arena.allocator(), 10);
    const twice = stored[0];
    const kept = stored[1];
    try testing.expectEqual(2, twice.copied);

    const row: u64 = @bitCast(twice.id);
    self.note(twice, .{ .shown = 3, .chosen = 2 });
    self.note(kept, .{ .chosen = 1 });

    try testing.expectEqual(rank.Weight{ .shown = 3, .chosen = 2 }, shared.counters(&self, row).?);
    try testing.expectEqual(null, shared.counters(&self, 999));

    shared.forget(&self, row);
    try testing.expectEqual(rank.Weight{}, shared.counters(&self, row).?);
    try testing.expectEqual(rank.Weight{ .chosen = 1 }, self.weightOf(kept));

    const again = try self.store.?.recent(arena.allocator(), 10);
    try testing.expectEqual(2, again[0].copied);
}

const Settles = struct {
    seen: usize = 0,
    next: ?subroutines.Next = null,

    fn onSettled(self: *Settles, next: subroutines.Next) void {
        self.seen += 1;
        self.next = next;
    }
};

test "deleting an entry runs on a worker, removes it and its counter, keeps the others, and refreshes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var history_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const history_path = try tmpPath(&tmp, &history_buffer, "clipboard.db");
    var counts_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const counts_path = try tmpPath(&tmp, &counts_buffer, "sysdeck.db");

    const kept_counts = try store_mod.Store.open(testing.allocator, testing.io, counts_path);
    defer kept_counts.close();

    var settles: Settles = .{};
    var self: Index = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .environ = &environ,
        .limits = .{},
        .counts = .{ .gpa = testing.allocator, .io = testing.io, .source = table, .store = kept_counts },
        .store = try clipboard.Store.openAt(testing.allocator, history_path),
        .path = try testing.allocator.dupeSentinel(u8, history_path, 0),
        .settled = .of(Settles, Settles.onSettled, &settles),
    };
    defer self.retire();

    for ([_][]const u8{ "kept", "hunter2" }, 0..) |body, at| {
        try self.store.?.put(.{
            .digest = clipboard.digestOf(body),
            .mime = "text/plain",
            .icon = "",
            .preview = body,
            .content = body,
            .at = @intCast(1000 + at),
        });
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const stored = try self.store.?.recent(arena.allocator(), 10);
    const secret = stored[0];
    const kept = stored[1];
    const row: u64 = @bitCast(secret.id);
    self.note(secret, .{ .chosen = 2 });
    self.note(kept, .{ .chosen = 1 });
    self.counts.flush();

    const offered = try shared.actions(&self, arena.allocator(), row);
    try testing.expectEqual(1, offered.len);
    try testing.expectEqualStrings("Delete", offered[0].title);
    try testing.expectEqual(0, (try shared.actions(&self, arena.allocator(), 999)).len);

    const delete = offered[0].id;
    try testing.expectEqual(subroutines.Outcome.busy, shared.perform(&self, testing.allocator, row, delete));
    try self.work.await(testing.io);

    try testing.expectEqual(1, settles.seen);
    try testing.expectEqual(subroutines.Next.refresh, settles.next.?);

    const left = try self.store.?.recent(arena.allocator(), 10);
    try testing.expectEqual(1, left.len);
    try testing.expectEqualStrings("kept", left[0].preview);
    try testing.expectEqual(rank.Weight{}, self.weightOf(secret));
    try testing.expectEqual(rank.Weight{ .chosen = 1 }, self.weightOf(kept));

    var counters: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer counters.deinit(testing.allocator);
    try counts_mod.read(testing.allocator, kept_counts.conn, table, &counters);
    try testing.expectEqual(1, counters.count());
    try testing.expectEqual(rank.Weight{ .chosen = 1 }, counters.get(counts_mod.id(&kept.digest)).?);

    try testing.expectEqual(subroutines.Outcome.keep, shared.perform(&self, testing.allocator, row, delete));
    try testing.expectEqual(1, settles.seen);
}

test "an entry with no icon still gets one" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("edit-paste", iconOf(owner, "").name);
    try testing.expect(iconOf(owner, ". GThemedIcon image-png image-x-generic") == .gicon);
}

test "opening reads the counters the store already holds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = try store_mod.Store.open(testing.allocator, testing.io, try tmpPath(&tmp, &buffer, "sysdeck.db"));
    defer store.close();

    var held: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer held.deinit(testing.allocator);
    try held.put(testing.allocator, 42, .{ .shown = 3, .chosen = 2 });
    try counts_mod.write(store.conn, table, held);

    var data: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_DATA_HOME", try tmpPath(&tmp, &data, "data"));

    const settings: config_mod.Config = .{};
    var index = (try open(.{
        .gpa = testing.allocator,
        .io = testing.io,
        .environ = &environ,
        .settings = &settings,
        .store = store,
    })).?;
    defer index.retire();

    try testing.expectEqual(2, index.counts.weight(42).chosen);
}
