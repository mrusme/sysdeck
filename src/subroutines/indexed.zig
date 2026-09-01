const std = @import("std");
const list = @import("../ui/list.zig");
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
        max_rows: usize,
        narrow: ?Narrow,
    ) subroutines.Error!subroutines.Output {
        const query = std.mem.trim(u8, text, " \t");
        if (query.len == 0) return .nothing;

        const of = self.source.snapshot();
        if (of.entries.len == 0) return .nothing;

        const weights = try of.weights(gpa);
        defer gpa.free(weights);

        const matches = try rank.rank(gpa, of.haystacks, weights, query);
        defer gpa.free(matches);
        if (matches.len == 0) return .nothing;

        const kept = if (narrow) |only| try only(gpa, of, weights, matches) else matches;
        defer if (narrow != null) gpa.free(kept);

        of.noteShown(kept);

        const shown = kept[0..@min(kept.len, max_rows)];
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

    try testing.expectEqual(subroutines.Output.nothing, try self.hits(testing.allocator, "", 10, null));
    try testing.expectEqual(subroutines.Output.nothing, try self.hits(testing.allocator, "zig", 10, null));
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

    const found = try self.hits(testing.allocator, "al", 10, null);
    defer self.release(testing.allocator, found);

    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("Alpha", found.hits[0].row.title);
    try testing.expectEqualStrings("First", found.hits[0].row.detail);

    const capped = try self.hits(testing.allocator, "al", 1, null);
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

    const found = try self.hits(testing.allocator, "alpha", 10, null);
    self.release(testing.allocator, found);

    const weights = try self.source.snapshot().weights(testing.allocator);
    defer testing.allocator.free(weights);
    try testing.expectEqual(@as(u32, 1), weights[0].shown);
}

fn noIcon(_: *anyopaque, _: Allocator, _: store_mod.Record) list.Icon {
    return .none;
}
