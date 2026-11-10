const std = @import("std");
const zqlite = @import("zqlite");
const rank = @import("rank.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.counts);

pub const table = "counts";

pub const schema =
    \\CREATE TABLE IF NOT EXISTS counts(
    \\  source TEXT    NOT NULL,
    \\  id     INTEGER NOT NULL,
    \\  shown  INTEGER NOT NULL DEFAULT 0,
    \\  chosen INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY(source, id));
;

const load_sql = "SELECT id, shown, chosen FROM counts WHERE source = ?1";

const flush_sql =
    \\INSERT INTO counts(source, id, shown, chosen) VALUES(?1,?2,?3,?4)
    \\ON CONFLICT(source, id) DO UPDATE SET shown = shown + excluded.shown,
    \\  chosen = chosen + excluded.chosen
;

const erase_sql = "DELETE FROM counts WHERE source = ?1 AND id = ?2";
const secure_sql = "PRAGMA secure_delete";
const checkpoint_sql = "PRAGMA wal_checkpoint(TRUNCATE)";

const Removal = enum { plain, secure };

pub fn id(key: []const u8) u64 {
    return std.hash.XxHash3.hash(0, key);
}

pub fn idOf(adapter: []const u8, key: []const u8) u64 {
    if (adapter.len == 0) return id(key);

    var hasher: std.hash.XxHash3 = .init(0);
    hasher.update(adapter);
    hasher.update(&[_]u8{0});
    hasher.update(key);
    return hasher.final();
}

pub const Counts = struct {
    gpa: Allocator,
    io: std.Io,
    source: []const u8,
    store: ?*store_mod.Store = null,
    mutex: std.Io.Mutex = .init,
    loaded: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty,
    added: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty,

    pub fn open(
        gpa: Allocator,
        io: std.Io,
        source: []const u8,
        store: ?*store_mod.Store,
    ) Counts {
        var self: Counts = .{ .gpa = gpa, .io = io, .source = source, .store = store };

        const found = store orelse return self;
        read(gpa, found.conn, source, &self.loaded) catch |err| {
            log.warn("cannot read the {s} counters: {t}", .{ source, err });
        };
        return self;
    }

    pub fn deinit(self: *Counts) void {
        self.loaded.deinit(self.gpa);
        self.added.deinit(self.gpa);
    }

    pub fn weight(self: *Counts, wanted: u64) rank.Weight {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.total(wanted);
    }

    pub fn fill(self: *Counts, ids: []const u64, out: []rank.Weight) void {
        std.debug.assert(ids.len == out.len);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (ids, out) |wanted, *slot| slot.* = self.total(wanted);
    }

    pub fn note(self: *Counts, wanted: u64, by: rank.Weight) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.bump(wanted, by);
    }

    pub fn noteAll(self: *Counts, ids: []const u64, by: rank.Weight) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (ids) |wanted| self.bump(wanted, by);
    }

    pub fn forget(self: *Counts, ids: []const u64) void {
        self.drop(ids, .plain);
    }

    pub fn scrub(self: *Counts, ids: []const u64) void {
        self.drop(ids, .secure);
    }

    fn drop(self: *Counts, ids: []const u64, removal: Removal) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (ids) |wanted| {
            _ = self.loaded.remove(wanted);
            _ = self.added.remove(wanted);
        }

        const found = self.store orelse return;
        const removed = switch (removal) {
            .plain => erase(found.conn, self.source, ids),
            .secure => eraseSecurely(found.conn, self.source, ids),
        };
        removed catch |err| log.warn("cannot forget the {s} counters: {t}", .{ self.source, err });
    }

    pub fn flush(self: *Counts, store: ?*store_mod.Store) void {
        const found = store orelse return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.added.count() == 0) return;

        write(self.gpa, found.conn, self.source, self.added) catch |err| {
            log.warn("cannot record the {s} counters: {t}", .{ self.source, err });
        };
    }

    fn total(self: *Counts, wanted: u64) rank.Weight {
        const base = self.loaded.get(wanted) orelse rank.Weight{};
        const extra = self.added.get(wanted) orelse rank.Weight{};
        return .{
            .shown = base.shown +| extra.shown,
            .chosen = base.chosen +| extra.chosen,
        };
    }

    fn bump(self: *Counts, wanted: u64, by: rank.Weight) void {
        const slot = self.added.getOrPut(self.gpa, wanted) catch return;
        if (!slot.found_existing) slot.value_ptr.* = .{};

        slot.value_ptr.shown +|= by.shown;
        slot.value_ptr.chosen +|= by.chosen;
    }
};

pub fn read(
    gpa: Allocator,
    conn: zqlite.Conn,
    source: []const u8,
    into: *std.AutoHashMapUnmanaged(u64, rank.Weight),
) !void {
    var rows = try conn.rows(load_sql, .{source});
    defer rows.deinit();

    while (rows.next()) |row| {
        try into.put(gpa, @bitCast(row.int(0)), .{
            .shown = count(row.int(1)),
            .chosen = count(row.int(2)),
        });
    }
    if (rows.err) |err| return err;
}

pub fn write(
    gpa: Allocator,
    conn: zqlite.Conn,
    source: []const u8,
    added: std.AutoHashMapUnmanaged(u64, rank.Weight),
) !void {
    _ = gpa;

    try conn.transaction();
    errdefer conn.rollback();

    const stmt = try conn.prepare(flush_sql);
    defer stmt.deinit();

    var entries = added.iterator();
    while (entries.next()) |entry| {
        const weight = entry.value_ptr.*;
        if (weight.shown == 0 and weight.chosen == 0) continue;

        try stmt.bind(.{
            source,
            @as(i64, @bitCast(entry.key_ptr.*)),
            @as(i64, weight.shown),
            @as(i64, weight.chosen),
        });
        try stmt.stepToCompletion();
        try stmt.reset();
    }

    try conn.commit();
}

pub fn keep(gpa: Allocator, conn: zqlite.Conn, source: []const u8, ids: []const u64) !void {
    var wanted: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer wanted.deinit(gpa);

    for (ids) |one| try wanted.put(gpa, one, {});

    var gone: std.ArrayList(u64) = .empty;
    defer gone.deinit(gpa);

    var held: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer held.deinit(gpa);

    try read(gpa, conn, source, &held);

    var entries = held.iterator();
    while (entries.next()) |entry| {
        if (wanted.contains(entry.key_ptr.*)) continue;
        try gone.append(gpa, entry.key_ptr.*);
    }
    if (gone.items.len == 0) return;

    try erase(conn, source, gone.items);
}

pub fn eraseSecurely(conn: zqlite.Conn, source: []const u8, ids: []const u64) !void {
    const before = try secureSetting(conn);
    try conn.execNoArgs(secure_sql ++ " = ON");
    defer restoreSecure(conn, before);

    try erase(conn, source, ids);

    const found = try conn.row(checkpoint_sql, .{}) orelse return;
    defer found.deinit();
    if (found.int(0) != 0) {
        log.warn("another connection reads the counters, so their log was not emptied", .{});
    }
}

fn secureSetting(conn: zqlite.Conn) !bool {
    const found = try conn.row(secure_sql, .{}) orelse return false;
    defer found.deinit();
    return found.int(0) != 0;
}

fn restoreSecure(conn: zqlite.Conn, before: bool) void {
    const sql = if (before) secure_sql ++ " = ON" else secure_sql ++ " = OFF";
    conn.execNoArgs(sql) catch |err| log.warn("cannot restore secure_delete: {t}", .{err});
}

pub fn erase(conn: zqlite.Conn, source: []const u8, ids: []const u64) !void {
    try conn.transaction();
    errdefer conn.rollback();

    const stmt = try conn.prepare(erase_sql);
    defer stmt.deinit();

    for (ids) |one| {
        try stmt.bind(.{ source, @as(i64, @bitCast(one)) });
        try stmt.stepToCompletion();
        try stmt.reset();
    }

    try conn.commit();
}

fn count(value: i64) u32 {
    return std.math.cast(u32, value) orelse 0;
}

const testing = std.testing;

fn openMemory() !zqlite.Conn {
    const conn = try store_mod.connect(":memory:", .{});
    errdefer conn.close();

    try conn.execNoArgs(schema);
    return conn;
}

test idOf {
    try testing.expectEqual(id("firefox.desktop"), idOf("", "firefox.desktop"));

    try testing.expect(idOf("markdown", "a") != idOf("chromium", "a"));
    try testing.expect(idOf("markdown", "a") != idOf("markdown", "b"));
    try testing.expectEqual(idOf("markdown", "a"), idOf("markdown", "a"));
    try testing.expect(idOf("ab", "c") != idOf("a", "bc"));
}

test "counts start empty and add up" {
    var self: Counts = .{ .gpa = testing.allocator, .io = testing.io, .source = "apps" };
    defer self.deinit();

    try testing.expectEqual(rank.Weight{}, self.weight(id("a")));

    self.note(id("a"), .{ .shown = 1 });
    self.note(id("a"), .{ .shown = 1, .chosen = 1 });

    try testing.expectEqual(rank.Weight{ .shown = 2, .chosen = 1 }, self.weight(id("a")));
    try testing.expectEqual(rank.Weight{}, self.weight(id("b")));
}

test "a fill answers for a whole slice at once" {
    var self: Counts = .{ .gpa = testing.allocator, .io = testing.io, .source = "apps" };
    defer self.deinit();

    self.noteAll(&.{ id("a"), id("b") }, .{ .shown = 1 });
    self.note(id("b"), .{ .chosen = 3 });

    const ids = [_]u64{ id("a"), id("b"), id("c") };
    var out: [3]rank.Weight = undefined;
    self.fill(&ids, &out);

    try testing.expectEqual(rank.Weight{ .shown = 1 }, out[0]);
    try testing.expectEqual(rank.Weight{ .shown = 1, .chosen = 3 }, out[1]);
    try testing.expectEqual(rank.Weight{}, out[2]);
}

test "what one run counted is added to what the database held" {
    const conn = try openMemory();
    defer conn.close();

    const gpa = testing.allocator;

    {
        var self: Counts = .{ .gpa = gpa, .io = testing.io, .source = "apps" };
        defer self.deinit();

        self.note(id("a"), .{ .shown = 2, .chosen = 1 });
        try write(gpa, conn, "apps", self.added);
    }

    var again: Counts = .{ .gpa = gpa, .io = testing.io, .source = "apps" };
    defer again.deinit();

    try read(gpa, conn, "apps", &again.loaded);
    try testing.expectEqual(rank.Weight{ .shown = 2, .chosen = 1 }, again.weight(id("a")));

    again.note(id("a"), .{ .chosen = 1 });
    try testing.expectEqual(rank.Weight{ .shown = 2, .chosen = 2 }, again.weight(id("a")));

    try write(gpa, conn, "apps", again.added);

    var third: Counts = .{ .gpa = gpa, .io = testing.io, .source = "apps" };
    defer third.deinit();

    try read(gpa, conn, "apps", &third.loaded);
    try testing.expectEqual(rank.Weight{ .shown = 2, .chosen = 2 }, third.weight(id("a")));
}

test "one source cannot read another source's counters" {
    const conn = try openMemory();
    defer conn.close();

    const gpa = testing.allocator;

    var apps: Counts = .{ .gpa = gpa, .io = testing.io, .source = "apps" };
    defer apps.deinit();
    apps.note(id("shared"), .{ .chosen = 5 });
    try write(gpa, conn, "apps", apps.added);

    var bins: Counts = .{ .gpa = gpa, .io = testing.io, .source = "bins" };
    defer bins.deinit();
    try read(gpa, conn, "bins", &bins.loaded);

    try testing.expectEqual(rank.Weight{}, bins.weight(id("shared")));
}

test "the ids that are gone are dropped and the rest are kept" {
    const conn = try openMemory();
    defer conn.close();

    const gpa = testing.allocator;

    var self: Counts = .{ .gpa = gpa, .io = testing.io, .source = "ssh" };
    defer self.deinit();

    self.note(id("web"), .{ .chosen = 1 });
    self.note(id("db"), .{ .chosen = 2 });
    try write(gpa, conn, "ssh", self.added);

    try keep(gpa, conn, "ssh", &.{id("db")});

    var found: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer found.deinit(gpa);

    try read(gpa, conn, "ssh", &found);
    try testing.expectEqual(@as(usize, 1), found.count());
    try testing.expectEqual(@as(?rank.Weight, null), found.get(id("web")));
}

test "a forgotten id reads as zero, leaves the database, and a flush does not bring it back" {
    const conn = try openMemory();
    defer conn.close();

    const gpa = testing.allocator;
    var store: store_mod.Store = .{ .gpa = gpa, .path = ":memory:", .conn = conn };

    {
        var first: Counts = .{ .gpa = gpa, .io = testing.io, .source = "apps" };
        defer first.deinit();
        first.note(id("a"), .{ .shown = 5, .chosen = 3 });
        first.note(id("b"), .{ .shown = 1, .chosen = 1 });
        try write(gpa, conn, "apps", first.added);
    }

    var self: Counts = .open(gpa, testing.io, "apps", &store);
    defer self.deinit();

    self.note(id("a"), .{ .shown = 1 });
    self.forget(&.{id("a")});
    try testing.expectEqual(rank.Weight{}, self.weight(id("a")));
    try testing.expectEqual(rank.Weight{ .shown = 1, .chosen = 1 }, self.weight(id("b")));

    var stored: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer stored.deinit(gpa);
    try read(gpa, conn, "apps", &stored);
    try testing.expectEqual(@as(?rank.Weight, null), stored.get(id("a")));

    self.note(id("a"), .{ .chosen = 1 });
    self.flush(&store);

    var again: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer again.deinit(gpa);
    try read(gpa, conn, "apps", &again);
    try testing.expectEqual(rank.Weight{ .chosen = 1 }, again.get(id("a")).?);
    try testing.expectEqual(rank.Weight{ .shown = 1, .chosen = 1 }, again.get(id("b")).?);
}

test "forgetting leaves the other sources alone" {
    const conn = try openMemory();
    defer conn.close();

    const gpa = testing.allocator;
    var added: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer added.deinit(gpa);
    try added.put(gpa, id("a"), .{ .chosen = 2 });
    try write(gpa, conn, "apps", added);
    try write(gpa, conn, "bins", added);

    try erase(conn, "apps", &.{id("a")});

    var bins: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer bins.deinit(gpa);
    try read(gpa, conn, "bins", &bins);
    try testing.expectEqual(rank.Weight{ .chosen = 2 }, bins.get(id("a")).?);
}

fn occurrences(dir: std.Io.Dir, name: []const u8, wanted: []const u8) !usize {
    const bytes = dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer testing.allocator.free(bytes);
    return std.mem.count(u8, bytes, wanted);
}

test "scrubbing zeroes the counter in the file and leaves the connection's setting as it was" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&buffer, ".zig-cache/tmp/{s}/sysdeck.db", .{tmp.sub_path}, 0);

    const gpa = testing.allocator;
    const conn = try store_mod.connect(path, .{});
    defer conn.close();
    try conn.execNoArgs(schema);
    try conn.execNoArgs(secure_sql ++ " = OFF");

    var store: store_mod.Store = .{ .gpa = gpa, .path = path, .conn = conn };
    var self: Counts = .{ .gpa = gpa, .io = testing.io, .source = "clipboard", .store = &store };
    defer self.deinit();

    const secret = id("hunter2");
    self.note(secret, .{ .shown = 3, .chosen = 2 });
    self.note(id("kept"), .{ .chosen = 1 });
    self.flush(&store);
    try conn.execNoArgs(checkpoint_sql);

    const stored: i64 = @bitCast(secret);
    const pattern = std.mem.toBytes(std.mem.nativeToBig(i64, stored));
    try testing.expect(try occurrences(tmp.dir, "sysdeck.db", &pattern) > 0);

    self.scrub(&.{secret});

    try testing.expectEqual(rank.Weight{}, self.weight(secret));
    try testing.expectEqual(@as(usize, 0), try occurrences(tmp.dir, "sysdeck.db", &pattern));
    try testing.expectEqual(@as(usize, 0), try occurrences(tmp.dir, "sysdeck.db-wal", &pattern));
    try testing.expect(!try secureSetting(conn));

    var left: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
    defer left.deinit(gpa);
    try read(gpa, conn, "clipboard", &left);
    try testing.expectEqual(rank.Weight{ .chosen = 1 }, left.get(id("kept")).?);
}
