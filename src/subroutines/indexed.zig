const std = @import("std");
const list = @import("../ui/list.zig");
const media = @import("core").media;
const rank = @import("core").rank;
const source_mod = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");

const Allocator = std.mem.Allocator;

pub const Narrow = *const fn (
    gpa: Allocator,
    of: *source_mod.Snapshot,
    weights: []const rank.Weight,
    matches: []const rank.Match,
) Allocator.Error![]rank.Match;

pub const Media = struct {
    context: *anyopaque,
    load: media.Loader,
};

pub const Options = struct {
    max_rows: usize,
    narrow: ?Narrow = null,
    idle: enum { nothing, ranked } = .nothing,
    media: ?Media = null,
};

pub const Indexed = struct {
    gpa: Allocator,
    table: []const u8,
    source: source_mod.Source,
    path: ?[:0]const u8 = null,
    published: source_mod.Published = .{},
    stamp: i64 = 0,

    pub fn init(
        gpa: Allocator,
        table: []const u8,
        stamp: i64,
        published: source_mod.Published,
    ) Allocator.Error!Indexed {
        return .{
            .gpa = gpa,
            .table = table,
            .source = .{
                .gpa = gpa,
                .name = table,
                .current = .init(try source_mod.empty(gpa)),
            },
            .published = published,
            .stamp = stamp,
        };
    }

    pub fn prepare(self: *Indexed, store: ?*store_mod.Store) ?*store_mod.Store {
        const found = store orelse {
            self.source.needs_refresh = true;
            return null;
        };

        found.ensure(self.table) catch |err| {
            source_mod.report(self.table, "prepare", err);
            self.source.needs_refresh = true;
            return null;
        };

        self.path = found.path;
        return found;
    }

    pub fn stored(
        self: *Indexed,
        store: *store_mod.Store,
        arena: Allocator,
    ) ?[]store_mod.Record {
        return store.load(arena, self.table) catch |err| {
            source_mod.report(self.table, "load", err);
            return null;
        };
    }

    pub fn adopt(
        self: *Indexed,
        records: []const store_mod.Record,
        iconOf: source_mod.IconOf,
        context: *anyopaque,
    ) Allocator.Error!void {
        self.source.publish(try source_mod.build(self.gpa, records, iconOf, context));
    }

    pub fn republish(
        self: *Indexed,
        records: []const store_mod.Record,
        iconOf: source_mod.IconOf,
        context: *anyopaque,
    ) void {
        const next = source_mod.build(self.gpa, records, iconOf, context) catch |err| {
            return source_mod.report(self.table, "publish", err);
        };

        self.source.publish(next);
        self.published.call();
    }

    pub fn write(self: *Indexed, records: []const store_mod.Record) void {
        const file = self.path orelse return;
        persist(self.gpa, file, self.table, records, self.stamp) catch |err| {
            source_mod.report(self.table, "write", err);
        };
    }

    pub fn hits(
        self: *Indexed,
        gpa: Allocator,
        text: []const u8,
        options: Options,
    ) subroutines.Error!subroutines.Output {
        const query = std.mem.trim(u8, text, " \t");
        if (query.len == 0 and options.idle == .nothing) return .nothing;

        const of = self.source.snapshot();
        if (of.entries.len == 0) return .nothing;

        const weights = try of.weights(gpa);
        defer gpa.free(weights);

        const matches = try rank.rank(gpa, of.haystacks, weights, query);
        defer gpa.free(matches);
        if (matches.len == 0) return .nothing;

        const kept = if (options.narrow) |only| try only(gpa, of, weights, matches) else matches;
        defer if (options.narrow != null) gpa.free(kept);

        of.noteShown(kept);

        const shown = kept[0..@min(kept.len, options.max_rows)];
        const built = try gpa.alloc(subroutines.Hit, shown.len);
        for (shown, 0..) |match, at| {
            const entry = of.entries[match.index];
            built[at] = .{
                .row = .{
                    .id = match.index,
                    .icon = entry.icon,
                    .title = entry.title,
                    .detail = entry.detail,
                    .program = entry.program,
                    .media = handleOf(options.media, entry, match.index),
                },
                .score = match.score,
            };
        }

        return .{ .hits = built };
    }

    pub fn entryAt(self: *Indexed, id: u64) ?source_mod.Entry {
        const of = self.source.snapshot();
        const at: usize = @intCast(id);
        if (at >= of.entries.len) return null;
        return of.entries[at];
    }

    pub fn stale(self: *Indexed) bool {
        return self.source.needs_refresh;
    }

    pub fn retire(self: *Indexed, store: ?*store_mod.Store) void {
        if (store) |found| self.source.flush(found);
        self.source.deinit();
    }

    pub fn release(_: *Indexed, gpa: Allocator, output: subroutines.Output) void {
        switch (output) {
            .nothing, .marks, .answer => {},
            .hits => |found| gpa.free(found),
        }
    }
};

fn handleOf(wanted: ?Media, entry: source_mod.Entry, index: usize) ?media.Handle {
    const found = wanted orelse return null;
    if (entry.mime.len == 0) return null;

    return .{
        .mime = entry.mime,
        .size = entry.size,
        .id = index,
        .context = found.context,
        .load = found.load,
    };
}

fn persist(
    gpa: Allocator,
    file: [:0]const u8,
    table: []const u8,
    records: []const store_mod.Record,
    stamp: i64,
) !void {
    const conn = try store_mod.connect(file, .{});
    defer conn.close();

    try store_mod.create(gpa, conn, table);
    try store_mod.replace(gpa, conn, table, .all, records, stamp);
}

const testing = std.testing;

test "an empty query and an empty index produce nothing" {
    var self = try Indexed.init(testing.allocator, "apps", 0, .{});
    defer self.retire(null);

    const empty = try self.hits(testing.allocator, "", .{ .max_rows = 10 });
    try testing.expectEqual(subroutines.Output.nothing, empty);

    const typed = try self.hits(testing.allocator, "zig", .{ .max_rows = 10 });
    try testing.expectEqual(subroutines.Output.nothing, typed);
}

test "ranked hits carry the entry fields and are capped" {
    var self = try Indexed.init(testing.allocator, "apps", 0, .{});
    defer self.retire(null);

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "First", .icon = "", .haystack = "Alpha" },
        .{ .key = "b", .title = "Alpine", .detail = "Second", .icon = "", .haystack = "Alpine" },
        .{ .key = "c", .title = "Beta", .detail = "Third", .icon = "", .haystack = "Beta" },
    };
    try self.adopt(&records, &noIcon, undefined);

    const found = try self.hits(testing.allocator, "al", .{ .max_rows = 10 });
    defer self.release(testing.allocator, found);

    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("Alpha", found.hits[0].row.title);
    try testing.expectEqualStrings("First", found.hits[0].row.detail);

    const capped = try self.hits(testing.allocator, "al", .{ .max_rows = 1 });
    defer self.release(testing.allocator, capped);
    try testing.expectEqual(@as(usize, 1), capped.hits.len);
}

test "showing a hit is counted against the entry" {
    var self = try Indexed.init(testing.allocator, "apps", 0, .{});
    defer self.retire(null);

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
    };
    try self.adopt(&records, &noIcon, undefined);

    const found = try self.hits(testing.allocator, "alpha", .{ .max_rows = 10 });
    self.release(testing.allocator, found);

    const weights = try self.source.snapshot().weights(testing.allocator);
    defer testing.allocator.free(weights);
    try testing.expectEqual(@as(u32, 1), weights[0].shown);
}

test "an idle index can list itself, ordered by what was chosen" {
    var self = try Indexed.init(testing.allocator, "disk", 0, .{});
    defer self.retire(null);

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
        .{
            .key = "b",
            .title = "Beta",
            .detail = "",
            .icon = "",
            .haystack = "Beta",
            .chosen = 4,
        },
    };
    try self.adopt(&records, &noIcon, undefined);

    const found = try self.hits(testing.allocator, "  ", .{ .max_rows = 10, .idle = .ranked });
    defer self.release(testing.allocator, found);

    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("Beta", found.hits[0].row.title);
    try testing.expectEqualStrings("Alpha", found.hits[1].row.title);

    const quiet = try self.hits(testing.allocator, "", .{ .max_rows = 10 });
    try testing.expectEqual(subroutines.Output.nothing, quiet);
}

test "a media handle is attached to the rows that carry a type" {
    var self = try Indexed.init(testing.allocator, "disk", 0, .{});
    defer self.retire(null);

    const records = [_]store_mod.Record{
        .{
            .key = "/home/tester/notes.txt",
            .title = "notes.txt",
            .detail = "/home/tester/notes.txt",
            .icon = "",
            .haystack = "notes.txt",
            .mime = "text/plain",
            .size = 812,
        },
        .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "notes" },
    };
    try self.adopt(&records, &noIcon, undefined);

    const wanted: Media = .{ .context = undefined, .load = &noPayload };
    const found = try self.hits(testing.allocator, "notes", .{
        .max_rows = 10,
        .media = wanted,
    });
    defer self.release(testing.allocator, found);

    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("text/plain", found.hits[0].row.media.?.mime);
    try testing.expectEqual(@as(u64, 812), found.hits[0].row.media.?.size);
    try testing.expectEqual(@as(?media.Handle, null), found.hits[1].row.media);

    const bare = try self.hits(testing.allocator, "notes", .{ .max_rows = 10 });
    defer self.release(testing.allocator, bare);
    try testing.expectEqual(@as(?media.Handle, null), bare.hits[0].row.media);
}

fn noIcon(_: *anyopaque, _: Allocator, _: store_mod.Record) list.Icon {
    return .none;
}

fn noPayload(_: *anyopaque, _: Allocator, _: u64) ?media.Payload {
    return null;
}
