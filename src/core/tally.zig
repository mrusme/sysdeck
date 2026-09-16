const std = @import("std");
const zqlite = @import("zqlite");
const rank = @import("rank.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;

pub const Weights = std.AutoHashMapUnmanaged(u64, rank.Weight);

pub const Count = struct {
    id: u64,
    shown: u32 = 0,
    chosen: u32 = 0,
};

const schema =
    \\CREATE TABLE IF NOT EXISTS "{s}"(
    \\  id     INTEGER PRIMARY KEY,
    \\  shown  INTEGER NOT NULL DEFAULT 0,
    \\  chosen INTEGER NOT NULL DEFAULT 0);
;

const present_schema = "CREATE TEMP TABLE present(id INTEGER PRIMARY KEY)";
const present_insert = "INSERT OR IGNORE INTO temp.present(id) VALUES(?1)";
const present_drop = "DROP TABLE temp.present";

pub fn id(key: []const u8) u64 {
    return std.hash.XxHash3.hash(0, key);
}

pub fn ensure(gpa: Allocator, conn: zqlite.Conn, table: []const u8) !void {
    const sql = try std.fmt.allocPrintSentinel(gpa, schema, .{table}, 0);
    defer gpa.free(sql);
    try conn.execNoArgs(sql.ptr);
}

pub fn mirror(gpa: Allocator, conn: zqlite.Conn, table: []const u8, ids: []const u64) !void {
    const prune = try std.fmt.allocPrintSentinel(
        gpa,
        "DELETE FROM \"{s}\" WHERE id NOT IN (SELECT id FROM temp.present)",
        .{table},
        0,
    );
    defer gpa.free(prune);

    const fill = try std.fmt.allocPrintSentinel(
        gpa,
        "INSERT OR IGNORE INTO \"{s}\"(id) SELECT id FROM temp.present",
        .{table},
        0,
    );
    defer gpa.free(fill);

    try conn.transaction();
    errdefer conn.rollback();

    try conn.execNoArgs(present_schema);
    {
        const stmt = try conn.prepare(present_insert);
        defer stmt.deinit();

        for (ids) |one| {
            try stmt.bind(.{stored(one)});
            try stmt.stepToCompletion();
            try stmt.reset();
        }
    }

    try conn.execNoArgs(prune.ptr);
    try conn.execNoArgs(fill.ptr);
    try conn.execNoArgs(present_drop);
    try conn.commit();
}

pub fn load(arena: Allocator, conn: zqlite.Conn, table: []const u8) !Weights {
    const sql = try std.fmt.allocPrint(arena, "SELECT id, shown, chosen FROM \"{s}\"", .{table});

    var found: Weights = .empty;

    var rows = try conn.rows(sql, .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        try found.put(arena, @bitCast(row.int(0)), .{
            .shown = count(row.int(1)),
            .chosen = count(row.int(2)),
        });
    }
    if (rows.err) |err| return err;

    return found;
}

pub fn flush(gpa: Allocator, conn: zqlite.Conn, table: []const u8, counts: []const Count) !void {
    if (counts.len == 0) return;

    const sql = try std.fmt.allocPrint(
        gpa,
        "UPDATE \"{s}\" SET shown = shown + ?2, chosen = chosen + ?3 WHERE id = ?1",
        .{table},
    );
    defer gpa.free(sql);

    try conn.transaction();
    errdefer conn.rollback();

    const stmt = try conn.prepare(sql);
    defer stmt.deinit();

    for (counts) |one| {
        if (one.shown == 0 and one.chosen == 0) continue;

        try stmt.bind(.{ stored(one.id), @as(i64, one.shown), @as(i64, one.chosen) });
        try stmt.stepToCompletion();
        try stmt.reset();
    }

    try conn.commit();
}

fn stored(value: u64) i64 {
    return @bitCast(value);
}

fn count(value: i64) u32 {
    return std.math.cast(u32, value) orelse 0;
}

const testing = std.testing;
const table_name = "ssh";

fn openMemory() !zqlite.Conn {
    const conn = try store_mod.connect(":memory:", .{});
    errdefer conn.close();
    try ensure(testing.allocator, conn, table_name);
    return conn;
}

fn rowCount(conn: zqlite.Conn) !i64 {
    const row = (try conn.row("SELECT COUNT(*) FROM ssh", .{})).?;
    defer row.deinit();
    return row.int(0);
}

test "an id is the same in every build" {
    try testing.expectEqual(@as(u64, 0x8a953ede9a88a9f5), id("gitlab.com"));
}

test "a table that is not there is created and reads back empty" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try ensure(testing.allocator, conn, table_name);
    try testing.expectEqual(@as(usize, 0), (try load(arena.allocator(), conn, table_name)).count());
}

test "a mirror adds the ids that are new with nothing counted" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try mirror(testing.allocator, conn, table_name, &.{ id("gitlab.com"), id("web") });

    const found = try load(arena.allocator(), conn, table_name);
    try testing.expectEqual(@as(usize, 2), found.count());
    try testing.expectEqual(rank.Weight{}, found.get(id("web")).?);
}

test "a mirror removes the ids that are gone and keeps the counts of the rest" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = testing.allocator;
    try mirror(gpa, conn, table_name, &.{ id("gitlab.com"), id("web"), id("db") });
    try flush(gpa, conn, table_name, &.{
        .{ .id = id("gitlab.com"), .shown = 4, .chosen = 2 },
        .{ .id = id("web"), .chosen = 7 },
    });

    try mirror(gpa, conn, table_name, &.{ id("gitlab.com"), id("db") });

    const found = try load(arena.allocator(), conn, table_name);
    try testing.expectEqual(@as(usize, 2), found.count());
    try testing.expectEqual(@as(?rank.Weight, null), found.get(id("web")));
    try testing.expectEqual(rank.Weight{ .shown = 4, .chosen = 2 }, found.get(id("gitlab.com")).?);
}

test "a mirror of nothing empties the table" {
    const conn = try openMemory();
    defer conn.close();

    try mirror(testing.allocator, conn, table_name, &.{ id("web"), id("db") });
    try mirror(testing.allocator, conn, table_name, &.{});

    try testing.expectEqual(@as(i64, 0), try rowCount(conn));
}

test "a mirror can run twice on one connection" {
    const conn = try openMemory();
    defer conn.close();

    try mirror(testing.allocator, conn, table_name, &.{id("web")});
    try mirror(testing.allocator, conn, table_name, &.{ id("web"), id("db") });

    try testing.expectEqual(@as(i64, 2), try rowCount(conn));
}

test "a flush adds to the counts rather than replacing them" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = testing.allocator;
    const one: Count = .{ .id = id("web"), .shown = 2, .chosen = 1 };

    try mirror(gpa, conn, table_name, &.{id("web")});
    try flush(gpa, conn, table_name, &.{one});
    try flush(gpa, conn, table_name, &.{one});

    const found = try load(arena.allocator(), conn, table_name);
    try testing.expectEqual(rank.Weight{ .shown = 4, .chosen = 2 }, found.get(id("web")).?);
}

test "a flush for an id the mirror removed writes no row" {
    const conn = try openMemory();
    defer conn.close();

    const gpa = testing.allocator;
    try mirror(gpa, conn, table_name, &.{id("web")});
    try flush(gpa, conn, table_name, &.{.{ .id = id("gone"), .shown = 3, .chosen = 3 }});

    try testing.expectEqual(@as(i64, 1), try rowCount(conn));
}

test "an id past the signed range reads back as the same id" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const high: u64 = std.math.maxInt(u64) - 5;
    try mirror(testing.allocator, conn, table_name, &.{high});
    try flush(testing.allocator, conn, table_name, &.{.{ .id = high, .chosen = 1 }});

    const found = try load(arena.allocator(), conn, table_name);
    try testing.expectEqual(@as(u32, 1), found.get(high).?.chosen);
}

test "the counts survive a schema version bump that drops the indexes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/sysdeck.db", .{tmp.sub_path});

    const gpa = testing.allocator;
    const store = try store_mod.Store.open(gpa, testing.io, path);
    defer store.close();

    try ensure(gpa, store.conn, table_name);
    try mirror(gpa, store.conn, table_name, &.{id("keep")});
    try flush(gpa, store.conn, table_name, &.{.{ .id = id("keep"), .chosen = 9 }});

    store.outdated = true;
    try store.ensure("apps");

    const found = try load(arena.allocator(), store.conn, table_name);
    try testing.expectEqual(@as(u32, 9), found.get(id("keep")).?.chosen);
}
