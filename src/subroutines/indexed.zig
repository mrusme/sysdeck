const std = @import("std");
const model = @import("../model.zig");
const media = @import("core").media;
const rank = @import("core").rank;
const source_mod = @import("source.zig");
const counts_mod = @import("core").counts;
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tally = @import("core").counts;

const Allocator = std.mem.Allocator;

pub const Narrow = *const fn (
    gpa: Allocator,
    of: *source_mod.Snapshot,
    weights: []const rank.Weight,
    matches: []const rank.Match,
) Allocator.Error![]rank.Match;

pub const Media = struct {
    context: ?*anyopaque,
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
    counts: counts_mod.Counts,
    path: ?[:0]const u8 = null,
    published: ?source_mod.Published = null,
    stamp: i64 = 0,
    loading: bool = false,

    pub fn init(
        gpa: Allocator,
        io: std.Io,
        table: []const u8,
        stamp: i64,
        published: ?source_mod.Published,
    ) Allocator.Error!Indexed {
        return .{
            .gpa = gpa,
            .table = table,
            .counts = .{ .gpa = gpa, .io = io, .source = table },
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
        self.counts.store = found;

        found.ensure(self.table) catch |err| {
            source_mod.report(self.table, "prepare", err);
            self.source.needs_refresh = true;
            return null;
        };

        self.path = found.path;
        self.loading = true;
        return found;
    }

    pub fn stored(self: *Indexed, arena: Allocator) ?[]store_mod.Record {
        if (!self.loading) return null;
        self.loading = false;

        const file = self.path orelse return null;
        const conn = store_mod.connect(file, .{}) catch |err| {
            source_mod.report(self.table, "load", err);
            return null;
        };
        defer conn.close();

        self.counts.load(conn);
        return store_mod.read(arena, conn, self.table) catch |err| {
            source_mod.report(self.table, "load", err);
            return null;
        };
    }

    pub fn adopt(
        self: *Indexed,
        records: []const store_mod.Record,
        iconOf: source_mod.IconOf,
        context: ?*anyopaque,
    ) Allocator.Error!void {
        try self.source.publish(try source_mod.build(self.gpa, records, iconOf, context));
    }

    pub fn show(
        self: *Indexed,
        records: []const store_mod.Record,
        iconOf: source_mod.IconOf,
        context: ?*anyopaque,
    ) void {
        _ = self.publishOf(records, iconOf, context);
    }

    pub fn republish(
        self: *Indexed,
        records: []const store_mod.Record,
        iconOf: source_mod.IconOf,
        context: ?*anyopaque,
    ) void {
        const next = self.publishOf(records, iconOf, context) orelse return;

        self.counts.keep(next.ids) catch |err| {
            source_mod.report(self.table, "prune the counters of", err);
        };
    }

    fn publishOf(
        self: *Indexed,
        records: []const store_mod.Record,
        iconOf: source_mod.IconOf,
        context: ?*anyopaque,
    ) ?*source_mod.Snapshot {
        const next = source_mod.build(self.gpa, records, iconOf, context) catch |err| {
            source_mod.report(self.table, "publish", err);
            return null;
        };
        self.source.publish(next) catch |err| {
            source_mod.report(self.table, "publish", err);
            return null;
        };

        if (self.published) |found| found.call(.{});
        return next;
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
        const weights = try scratch.alloc(rank.Weight, of.entries.len);
        self.counts.fill(of.ids, weights);

        const matches = try rank.rank(scratch, of.haystacks, weights, query);
        if (matches.len == 0) return .nothing;

        const kept = if (options.narrow) |only| try only(scratch, of, weights, matches) else matches;
        const shown = kept[0..@min(kept.len, options.max_rows)];
        try self.noteShown(scratch, of, shown);

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
        const weights = try scratch.alloc(rank.Weight, of.entries.len);
        self.counts.fill(of.ids, weights);

        if (options.pool) |pool| try pool(scratch, of, weights);

        const found = try rank.picks(scratch, weights, options.limit);
        if (found.len == 0) return .nothing;

        return .{ .hits = try hitsOf(scratch, of, found, options.media) };
    }

    fn noteShown(
        self: *Indexed,
        arena: Allocator,
        of: *source_mod.Snapshot,
        matches: []const rank.Match,
    ) Allocator.Error!void {
        const ids = try arena.alloc(u64, matches.len);
        for (matches, ids) |match, *slot| slot.* = of.ids[match.index];

        self.counts.noteAll(ids, .{ .shown = 1 });
    }

    pub fn noteChosen(self: *Indexed, id: u64) void {
        self.counts.note(id, .{ .chosen = 1 });
    }

    pub fn counters(self: *Indexed, id: u64) ?rank.Weight {
        _ = self.entryAt(id) orelse return null;
        return self.counts.weight(id);
    }

    pub fn forget(self: *Indexed, id: u64) void {
        self.counts.forget(&.{id});
    }

    pub fn entryAt(self: *Indexed, id: u64) ?source_mod.Entry {
        const of = self.source.snapshot();
        return of.entries[of.find(id) orelse return null];
    }

    pub fn stale(self: *Indexed) bool {
        return self.loading or self.source.needs_refresh;
    }

    pub fn retire(self: *Indexed) void {
        self.counts.flush();
        self.counts.deinit();
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
        const id = of.ids[match.index];
        hit.* = .{
            .row = .{
                .id = id,
                .icon = entry.icon,
                .title = entry.title,
                .detail = entry.detail,
                .program = entry.program,
                .media = handleOf(wanted, entry, id),
            },
            .score = match.score,
        };
    }
    return built;
}

fn handleOf(wanted: ?Media, entry: source_mod.Entry, id: u64) ?media.Handle {
    const found = wanted orelse return null;
    if (entry.mime.len == 0) return null;

    return .{
        .mime = entry.mime,
        .size = entry.size,
        .id = id,
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

    var self = try Indexed.init(testing.allocator, testing.io, "apps", 0, null);
    defer self.retire();

    const empty = try self.hits(owner, "", .{ .max_rows = 10 });
    try testing.expectEqual(subroutines.Output.nothing, empty);

    const typed = try self.hits(owner, "zig", .{ .max_rows = 10 });
    try testing.expectEqual(subroutines.Output.nothing, typed);
}

test "ranked hits carry the entry fields and are capped" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, testing.io, "apps", 0, null);
    defer self.retire();

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "First", .icon = "", .haystack = "Alpha" },
        .{ .key = "b", .title = "Alpine", .detail = "Second", .icon = "", .haystack = "Alpine" },
        .{ .key = "c", .title = "Beta", .detail = "Third", .icon = "", .haystack = "Beta" },
    };
    try self.adopt(&records, &noIcon, null);

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

    var self = try Indexed.init(testing.allocator, testing.io, "apps", 0, null);
    defer self.retire();

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
    };
    try self.adopt(&records, &noIcon, null);

    _ = try self.hits(owner, "alpha", .{ .max_rows = 10 });

    try testing.expectEqual(
        @as(u32, 1),
        self.counts.weight(counts_mod.idOf("", "a")).shown,
    );
}

test "of 300 matches only the listed rows are counted as shown" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, testing.io, "disk", 0, null);
    defer self.retire();

    const scratch = owner.allocator();
    const records = try scratch.alloc(store_mod.Record, 300);
    for (records, 0..) |*record, at| {
        const key = try scratch.print("note {d}", .{at});
        record.* = .{ .key = key, .title = key, .detail = "", .icon = "", .haystack = key };
    }
    try self.adopt(records, &noIcon, null);

    const found = try self.hits(owner, "note", .{ .max_rows = 200 });
    try testing.expectEqual(200, found.hits.len);

    var shown: usize = 0;
    for (records) |record| shown += self.counts.weight(counts_mod.idOf("", record.key)).shown;
    try testing.expectEqual(200, shown);

    for (found.hits) |hit| try testing.expectEqual(1, self.counts.weight(hit.row.id).shown);
}

test "a refresh drops the counters of the entries that are gone, also from the table" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&buffer, ".zig-cache/tmp/{s}/sysdeck.db", .{tmp.sub_path});

    const store = try store_mod.Store.open(testing.allocator, testing.io, path);
    defer store.close();

    const alpha = counts_mod.idOf("", "a");
    const beta = counts_mod.idOf("", "b");

    {
        var self = try Indexed.init(testing.allocator, testing.io, "apps", 0, null);
        defer self.retire();

        try testing.expect(self.prepare(store) != null);

        const before = [_]store_mod.Record{
            .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
            .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "Beta" },
        };
        try self.adopt(&before, &noIcon, null);

        self.noteChosen(alpha);
        self.noteChosen(beta);
        self.counts.flush();
        self.noteChosen(alpha);

        self.republish(before[1..], &noIcon, null);
        try testing.expectEqual(rank.Weight{}, self.counts.weight(alpha));
        try testing.expectEqual(rank.Weight{ .chosen = 1 }, self.counts.weight(beta));
    }

    var stored: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer stored.deinit(testing.allocator);

    try counts_mod.read(testing.allocator, store.conn, "apps", &stored);
    try testing.expectEqual(1, stored.count());
    try testing.expectEqual(rank.Weight{ .chosen = 1 }, stored.get(beta).?);
}

const Publishes = struct {
    seen: usize = 0,

    fn onPublished(self: *Publishes) void {
        self.seen += 1;
    }
};

test "a query before the load finds nothing, and the load publishes the stored rows and counters once" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&buffer, ".zig-cache/tmp/{s}/sysdeck.db", .{tmp.sub_path});

    const store = try store_mod.Store.open(testing.allocator, testing.io, path);
    defer store.close();

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
        .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "Beta" },
    };
    try store.ensure("apps");
    try store_mod.replace(testing.allocator, store.conn, "apps", .all, &records, 100);

    var stored_counts: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer stored_counts.deinit(testing.allocator);
    try stored_counts.put(testing.allocator, counts_mod.idOf("", "b"), .{ .chosen = 3 });
    try stored_counts.put(testing.allocator, counts_mod.idOf("", "gone"), .{ .chosen = 5 });
    try counts_mod.write(testing.allocator, store.conn, "apps", stored_counts);

    var publishes: Publishes = .{};
    var self = try Indexed.init(testing.allocator, testing.io, "apps", 0, .of(Publishes, Publishes.onPublished, &publishes));
    defer self.retire();

    try testing.expect(self.prepare(store) != null);
    try testing.expect(self.stale());
    try testing.expectEqual(subroutines.Output.nothing, try self.hits(owner, "alpha", .{ .max_rows = 10 }));
    try testing.expectEqual(rank.Weight{}, self.counts.weight(counts_mod.idOf("", "b")));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for (0..2) |_| {
        if (self.stored(arena.allocator())) |found| self.show(found, &noIcon, null);
    }

    try testing.expectEqual(1, publishes.seen);
    try testing.expect(!self.stale());
    try testing.expectEqual(1, (try self.hits(owner, "alpha", .{ .max_rows = 10 })).hits.len);
    try testing.expectEqual(rank.Weight{ .chosen = 3 }, self.counts.weight(counts_mod.idOf("", "b")));

    var after: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer after.deinit(testing.allocator);
    try counts_mod.read(testing.allocator, store.conn, "apps", &after);
    try testing.expectEqual(rank.Weight{ .chosen = 5 }, after.get(counts_mod.idOf("", "gone")).?);
}

test "an entry's counters are read by its id and forgotten" {
    var self = try Indexed.init(testing.allocator, testing.io, "apps", 0, null);
    defer self.retire();

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
        .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "Beta" },
    };
    try self.adopt(&records, &noIcon, null);

    const alpha = counts_mod.idOf("", "a");
    self.noteChosen(alpha);
    self.counts.note(alpha, .{ .shown = 4 });
    self.noteChosen(counts_mod.idOf("", "b"));

    try testing.expectEqual(rank.Weight{ .shown = 4, .chosen = 1 }, self.counters(alpha).?);
    try testing.expectEqual(@as(?rank.Weight, null), self.counters(counts_mod.idOf("", "gone")));

    self.forget(alpha);
    try testing.expectEqual(rank.Weight{}, self.counters(alpha).?);
    try testing.expectEqual(rank.Weight{ .chosen = 1 }, self.counters(counts_mod.idOf("", "b")).?);
}

test "an idle index can list itself, ordered by what was chosen" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, testing.io, "disk", 0, null);
    defer self.retire();

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
        .{
            .key = "b",
            .title = "Beta",
            .detail = "",
            .icon = "",
            .haystack = "Beta",
        },
    };
    try self.adopt(&records, &noIcon, null);
    self.counts.note(counts_mod.idOf("", "b"), .{ .chosen = 4 });

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

    var self = try Indexed.init(testing.allocator, testing.io, "disk", 0, null);
    defer self.retire();

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
    try self.adopt(&records, &noIcon, null);

    const wanted: Media = .{ .context = null, .load = &noPayload };
    const found = try self.hits(owner, "notes", .{
        .max_rows = 10,
        .media = wanted,
    });

    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("text/plain", found.hits[0].row.media.?.mime);
    try testing.expectEqual(@as(u64, 812), found.hits[0].row.media.?.size);
    try testing.expectEqual(found.hits[0].row.id, found.hits[0].row.media.?.id);
    try testing.expectEqual(@as(?media.Handle, null), found.hits[1].row.media);

    const bare = try self.hits(owner, "notes", .{ .max_rows = 10 });
    try testing.expectEqual(@as(?media.Handle, null), bare.hits[0].row.media);
}

test "the picks are the entries chosen twice, most chosen first" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, testing.io, "apps", 0, null);
    defer self.retire();

    const empty = try self.picks(owner, .{ .limit = 5 });
    try testing.expectEqual(subroutines.Output.nothing, empty);

    const records = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
        .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "Beta" },
        .{ .key = "c", .title = "Gamma", .detail = "", .icon = "", .haystack = "Gamma" },
        .{ .key = "d", .title = "Delta", .detail = "", .icon = "", .haystack = "Delta" },
    };
    try self.adopt(&records, &noIcon, null);

    for ([_][]const u8{ "a", "b", "c", "d" }, [_]u32{ 1, 2, 6, 3 }) |key, chosen| {
        self.counts.note(counts_mod.idOf("", key), .{ .chosen = chosen });
    }

    const found = try self.picks(owner, .{ .limit = 5 });

    try testing.expectEqual(@as(usize, 3), found.hits.len);
    try testing.expectEqualStrings("Gamma", found.hits[0].row.title);
    try testing.expectEqualStrings("Delta", found.hits[1].row.title);
    try testing.expectEqualStrings("Beta", found.hits[2].row.title);
    try testing.expectEqual(@as(i32, 6), found.hits[0].score);
    try testing.expectEqual(tally.idOf("", "c"), found.hits[0].row.id);

    const capped = try self.picks(owner, .{ .limit = 2 });
    try testing.expectEqual(@as(usize, 2), capped.hits.len);
    try testing.expectEqualStrings("Delta", capped.hits[1].row.title);
}

test "picking neither counts as shown nor drops the media handle" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, testing.io, "disk", 0, null);
    defer self.retire();

    const records = [_]store_mod.Record{.{
        .key = "/home/tester/notes.txt",
        .title = "notes.txt",
        .detail = "/home/tester/notes.txt",
        .icon = "",
        .haystack = "notes.txt",
        .mime = "text/plain",
        .size = 812,
    }};
    try self.adopt(&records, &noIcon, null);
    self.counts.note(counts_mod.idOf("", "/home/tester/notes.txt"), .{ .chosen = 2 });

    const wanted: Media = .{ .context = null, .load = &noPayload };
    const found = try self.picks(owner, .{ .limit = 5, .media = wanted });

    try testing.expectEqualStrings("text/plain", found.hits[0].row.media.?.mime);

    try testing.expectEqual(
        @as(u32, 0),
        self.counts.weight(counts_mod.idOf("", "/home/tester/notes.txt")).shown,
    );
}

fn noIcon(_: ?*anyopaque, _: *source_mod.Snapshot, _: store_mod.Record) model.Icon {
    return .none;
}

fn noPayload(_: ?*anyopaque, _: Allocator, _: u64) ?media.Payload {
    return null;
}

test "an id still names its own entry after a refresh reordered the index" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, testing.io, "apps", 0, null);
    defer self.retire();

    const before = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
        .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "Beta" },
    };
    try self.adopt(&before, &noIcon, null);

    const found = try self.hits(owner, "beta", .{ .max_rows = 10 });
    const id = found.hits[0].row.id;
    try testing.expectEqualStrings("Beta", found.hits[0].row.title);

    const after = [_]store_mod.Record{
        .{ .key = "c", .title = "Gamma", .detail = "", .icon = "", .haystack = "Gamma" },
        .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "Beta" },
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
    };
    try self.adopt(&after, &noIcon, null);

    try testing.expectEqualStrings("Beta", self.entryAt(id).?.title);
}

test "an id whose entry the refresh removed names nothing" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = try Indexed.init(testing.allocator, testing.io, "apps", 0, null);
    defer self.retire();

    const before = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
        .{ .key = "b", .title = "Beta", .detail = "", .icon = "", .haystack = "Beta" },
    };
    try self.adopt(&before, &noIcon, null);

    const found = try self.hits(owner, "beta", .{ .max_rows = 10 });
    const id = found.hits[0].row.id;

    const after = [_]store_mod.Record{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
    };
    try self.adopt(&after, &noIcon, null);

    try testing.expectEqual(@as(?source_mod.Entry, null), self.entryAt(id));
}
