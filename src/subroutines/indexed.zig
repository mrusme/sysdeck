const std = @import("std");
const model = @import("../model.zig");
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

pub const Pool = *const fn (
    gpa: Allocator,
    of: *source_mod.Snapshot,
    weights: []rank.Weight,
) Allocator.Error!void;

pub const Picking = struct {
    limit: usize,
    pool: ?Pool = null,
    media: ?Media = null,
};

pub const Indexed = struct {
    gpa: Allocator,
    table: []const u8,
    source: source_mod.Source,
    path: ?[:0]const u8 = null,
    published: ?source_mod.Published = null,
    stamp: i64 = 0,

    pub fn init(
        gpa: Allocator,
        table: []const u8,
        stamp: i64,
        published: ?source_mod.Published,
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
        if (self.published) |found| found.call(.{});
    }

    pub fn write(
        self: *Indexed,
        arena: Allocator,
        records: []const store_mod.Record,
    ) []const store_mod.Record {
        const file = self.path orelse return records;
        return persist(self.gpa, arena, file, self.table, records, self.stamp) catch |err| {
            source_mod.report(self.table, "write", err);
            return records;
        };
    }

    pub fn hits(
        self: *Indexed,
        owner: *subroutines.Owner,
        text: []const u8,
        options: Options,
    ) subroutines.Error!subroutines.Output {
        const query = std.mem.trim(u8, text, " \t");
        if (query.len == 0 and options.idle == .nothing) return .nothing;

        const of = self.source.snapshot();
        if (of.entries.len == 0) return .nothing;

        const scratch = owner.allocator();
        const weights = try of.weights(scratch);
        const matches = try rank.rank(scratch, of.haystacks, weights, query);
        if (matches.len == 0) return .nothing;

        const kept = if (options.narrow) |only| try only(scratch, of, weights, matches) else matches;
        of.noteShown(kept);

        const shown = kept[0..@min(kept.len, options.max_rows)];
        return .{ .hits = try hitsOf(scratch, of, shown, options.media) };
    }

    pub fn picks(
        self: *Indexed,
        owner: *subroutines.Owner,
        options: Picking,
    ) subroutines.Error!subroutines.Output {
        const of = self.source.snapshot();
        if (of.entries.len == 0) return .nothing;

        const scratch = owner.allocator();
        const weights = try of.weights(scratch);
        if (options.pool) |pool| try pool(scratch, of, weights);

        const found = try rank.picks(scratch, weights, options.limit);
        if (found.len == 0) return .nothing;

        return .{ .hits = try hitsOf(scratch, of, found, options.media) };
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
};

fn hitsOf(
    arena: Allocator,
    of: *source_mod.Snapshot,
    matches: []const rank.Match,
    wanted: ?Media,
) Allocator.Error![]subroutines.Hit {
    const built = try arena.alloc(subroutines.Hit, matches.len);
    for (matches, built) |match, *hit| {
        const entry = of.entries[match.index];
        hit.* = .{
            .row = .{
                .id = match.index,
                .icon = entry.icon,
                .title = entry.title,
                .detail = entry.detail,
                .program = entry.program,
                .media = handleOf(wanted, entry, match.index),
            },
            .score = match.score,
        };
    }
    return built;
}

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
    arena: Allocator,
    file: [:0]const u8,
    table: []const u8,
    records: []const store_mod.Record,
    stamp: i64,
) ![]store_mod.Record {
    const conn = try store_mod.connect(file, .{});
    defer conn.close();

    try store_mod.create(gpa, conn, table);
    try store_mod.replace(gpa, conn, table, .all, records, stamp);
    return store_mod.read(arena, conn, table);
}

const testing = std.testing;

test "an empty query and an empty index produce nothing" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, "apps", 0, null);
    defer self.retire(null);

    const empty = try self.hits(owner, "", .{ .max_rows = 10 });
    try testing.expectEqual(subroutines.Output.nothing, empty);

    const typed = try self.hits(owner, "zig", .{ .max_rows = 10 });
    try testing.expectEqual(subroutines.Output.nothing, typed);
}

test "ranked hits carry the entry fields and are capped" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, "apps", 0, null);
    defer self.retire(null);

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "First", .icon = "", .haystack = "Alpha" },
        .{ .key = "b", .title = "Alpine", .detail = "Second", .icon = "", .haystack = "Alpine" },
        .{ .key = "c", .title = "Beta", .detail = "Third", .icon = "", .haystack = "Beta" },
    };
    try self.adopt(&records, &noIcon, undefined);

    const found = try self.hits(owner, "al", .{ .max_rows = 10 });

    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("Alpha", found.hits[0].row.title);
    try testing.expectEqualStrings("First", found.hits[0].row.detail);

    const capped = try self.hits(owner, "al", .{ .max_rows = 1 });
    try testing.expectEqual(@as(usize, 1), capped.hits.len);
}

test "showing a hit is counted against the entry" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, "apps", 0, null);
    defer self.retire(null);

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
    };
    try self.adopt(&records, &noIcon, undefined);

    _ = try self.hits(owner, "alpha", .{ .max_rows = 10 });

    const weights = try self.source.snapshot().weights(testing.allocator);
    defer testing.allocator.free(weights);
    try testing.expectEqual(@as(u32, 1), weights[0].shown);
}

test "an idle index can list itself, ordered by what was chosen" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, "disk", 0, null);
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

    const found = try self.hits(owner, "  ", .{ .max_rows = 10, .idle = .ranked });

    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("Beta", found.hits[0].row.title);
    try testing.expectEqualStrings("Alpha", found.hits[1].row.title);

    const quiet = try self.hits(owner, "", .{ .max_rows = 10 });
    try testing.expectEqual(subroutines.Output.nothing, quiet);
}

test "a media handle is attached to the rows that carry a type" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, "disk", 0, null);
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
    const found = try self.hits(owner, "notes", .{
        .max_rows = 10,
        .media = wanted,
    });

    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("text/plain", found.hits[0].row.media.?.mime);
    try testing.expectEqual(@as(u64, 812), found.hits[0].row.media.?.size);
    try testing.expectEqual(@as(?media.Handle, null), found.hits[1].row.media);

    const bare = try self.hits(owner, "notes", .{ .max_rows = 10 });
    try testing.expectEqual(@as(?media.Handle, null), bare.hits[0].row.media);
}

test "the picks are the entries chosen twice, most chosen first" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, "apps", 0, null);
    defer self.retire(null);

    const empty = try self.picks(owner, .{ .limit = 5 });
    try testing.expectEqual(subroutines.Output.nothing, empty);

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha", .chosen = 1 },
        .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "Beta", .chosen = 2 },
        .{ .key = "c", .title = "Gamma", .detail = "", .icon = "", .haystack = "Gamma", .chosen = 6 },
        .{ .key = "d", .title = "Delta", .detail = "", .icon = "", .haystack = "Delta", .chosen = 3 },
    };
    try self.adopt(&records, &noIcon, undefined);

    const found = try self.picks(owner, .{ .limit = 5 });

    try testing.expectEqual(@as(usize, 3), found.hits.len);
    try testing.expectEqualStrings("Gamma", found.hits[0].row.title);
    try testing.expectEqualStrings("Delta", found.hits[1].row.title);
    try testing.expectEqualStrings("Beta", found.hits[2].row.title);
    try testing.expectEqual(@as(i32, 6), found.hits[0].score);
    try testing.expectEqual(@as(u64, 2), found.hits[0].row.id);

    const capped = try self.picks(owner, .{ .limit = 2 });
    try testing.expectEqual(@as(usize, 2), capped.hits.len);
    try testing.expectEqualStrings("Delta", capped.hits[1].row.title);
}

test "picking neither counts as shown nor drops the media handle" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, "disk", 0, null);
    defer self.retire(null);

    const records = [_]store_mod.Record{.{
        .key = "/home/tester/notes.txt",
        .title = "notes.txt",
        .detail = "/home/tester/notes.txt",
        .icon = "",
        .haystack = "notes.txt",
        .mime = "text/plain",
        .size = 812,
        .chosen = 2,
    }};
    try self.adopt(&records, &noIcon, undefined);

    const wanted: Media = .{ .context = undefined, .load = &noPayload };
    const found = try self.picks(owner, .{ .limit = 5, .media = wanted });

    try testing.expectEqualStrings("text/plain", found.hits[0].row.media.?.mime);

    const weights = try self.source.snapshot().weights(testing.allocator);
    defer testing.allocator.free(weights);
    try testing.expectEqual(@as(u32, 0), weights[0].shown);
}

test "a rewrite publishes the counts the database kept" {
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/sysdeck.db", .{tmp.sub_path});

    const store = try store_mod.Store.open(gpa, testing.io, path);
    defer store.close();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var self = try Indexed.init(gpa, "apps", 100, null);
    defer self.retire(null);
    self.path = store.path;

    const scanned = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
        .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "Beta" },
    };
    _ = self.write(arena.allocator(), &scanned);

    store.flush("apps", &.{.{ .adapter = "", .key = "b", .shown = 1, .chosen = 3 }});

    self.republish(self.write(arena.allocator(), &scanned), &noIcon, undefined);

    const of = self.source.snapshot();
    try testing.expectEqual(@as(usize, 2), of.entries.len);

    const weights = try of.weights(gpa);
    defer gpa.free(weights);

    for (of.entries, weights) |entry, weight| {
        const picked = std.mem.eql(u8, entry.key, "b");
        try testing.expectEqual(@as(u32, if (picked) 3 else 0), weight.chosen);
        try testing.expectEqual(@as(u32, if (picked) 1 else 0), weight.shown);
    }
}

fn noIcon(_: *anyopaque, _: Allocator, _: store_mod.Record) model.Icon {
    return .none;
}

fn noPayload(_: *anyopaque, _: Allocator, _: u64) ?media.Payload {
    return null;
}
