const std = @import("std");
const zqlite = @import("zqlite");
const store_mod = @import("core").store;
const tables = @import("core").tables;

const Allocator = std.mem.Allocator;

pub const table = tables.nm;

const schema =
    \\CREATE TABLE IF NOT EXISTS nm(
    \\  type    TEXT    NOT NULL,
    \\  key     TEXT    NOT NULL,
    \\  subtype TEXT    NOT NULL DEFAULT '',
    \\  shown   INTEGER NOT NULL DEFAULT 0,
    \\  chosen  INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY(type, key));
;

const load_sql = "SELECT type, key, subtype, shown, chosen FROM nm";

const upsert_sql =
    \\INSERT INTO nm(type, key, subtype, shown, chosen) VALUES(?1,?2,?3,?4,?5)
    \\ON CONFLICT(type, key) DO UPDATE SET
    \\  subtype = excluded.subtype,
    \\  shown = shown + excluded.shown,
    \\  chosen = chosen + excluded.chosen
;

pub const Kind = enum { device, connection };

pub const Count = struct {
    kind: Kind,
    key: []const u8,
    subtype: []const u8 = "",
    shown: u32 = 0,
    chosen: u32 = 0,

    pub fn moved(self: Count) bool {
        return self.shown > 0 or self.chosen > 0;
    }
};

pub fn ensure(conn: zqlite.Conn) !void {
    try conn.execNoArgs(schema);
}

pub fn load(arena: Allocator, conn: zqlite.Conn) ![]Count {
    var counts: std.ArrayList(Count) = .empty;

    var rows = try conn.rows(load_sql, .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        const kind = std.meta.stringToEnum(Kind, row.text(0)) orelse continue;
        try counts.append(arena, .{
            .kind = kind,
            .key = try arena.dupe(u8, row.text(1)),
            .subtype = try arena.dupe(u8, row.text(2)),
            .shown = count(row.int(3)),
            .chosen = count(row.int(4)),
        });
    }
    if (rows.err) |err| return err;

    return counts.toOwnedSlice(arena);
}

pub fn flush(conn: zqlite.Conn, counts: []const Count) !void {
    try conn.transaction();
    errdefer conn.rollback();

    const stmt = try conn.prepare(upsert_sql);
    defer stmt.deinit();

    for (counts) |one| {
        if (!one.moved()) continue;

        try stmt.bind(.{
            @tagName(one.kind),
            one.key,
            one.subtype,
            @as(i64, one.shown),
            @as(i64, one.chosen),
        });
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
    try ensure(conn);
    return conn;
}

fn loaded(arena: Allocator, conn: zqlite.Conn) ![]Count {
    const found = try load(arena, conn);
    std.mem.sort(Count, found, {}, byKey);
    return found;
}

fn byKey(_: void, left: Count, right: Count) bool {
    if (left.kind != right.kind) return @intFromEnum(left.kind) < @intFromEnum(right.kind);
    return std.mem.order(u8, left.key, right.key) == .lt;
}

test "a table that is not there is created and reads back empty" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try ensure(conn);
    try testing.expectEqual(@as(usize, 0), (try load(arena.allocator(), conn)).len);
}

test "an upsert inserts a row that was not there" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try flush(conn, &.{.{
        .kind = .connection,
        .key = "8520c266-7cab-4ddb-978e-1839977eef96",
        .subtype = "wifi",
        .shown = 3,
        .chosen = 1,
    }});

    const found = try loaded(arena.allocator(), conn);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(Kind.connection, found[0].kind);
    try testing.expectEqualStrings("8520c266-7cab-4ddb-978e-1839977eef96", found[0].key);
    try testing.expectEqualStrings("wifi", found[0].subtype);
    try testing.expectEqual(@as(u32, 3), found[0].shown);
    try testing.expectEqual(@as(u32, 1), found[0].chosen);
}

test "a second upsert adds to the counts rather than replacing them" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const one: Count = .{
        .kind = .device,
        .key = "wlp0s20f3",
        .subtype = "wifi",
        .shown = 2,
        .chosen = 1,
    };
    try flush(conn, &.{one});
    try flush(conn, &.{one});
    try flush(conn, &.{one});

    const found = try loaded(arena.allocator(), conn);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 6), found[0].shown);
    try testing.expectEqual(@as(u32, 3), found[0].chosen);
}

test "the subtype is refreshed when a row is written again" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try flush(conn, &.{.{ .kind = .device, .key = "eth0", .subtype = "ethernet", .shown = 1 }});
    try flush(conn, &.{.{ .kind = .device, .key = "eth0", .subtype = "veth", .shown = 1 }});

    const found = try loaded(arena.allocator(), conn);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("veth", found[0].subtype);
    try testing.expectEqual(@as(u32, 2), found[0].shown);
}

test "a device and a connection sharing a key are two rows" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try flush(conn, &.{
        .{ .kind = .device, .key = "virbr0", .subtype = "bridge", .shown = 1 },
        .{ .kind = .connection, .key = "virbr0", .subtype = "bridge", .chosen = 5 },
    });

    const found = try loaded(arena.allocator(), conn);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(Kind.device, found[0].kind);
    try testing.expectEqual(@as(u32, 1), found[0].shown);
    try testing.expectEqual(Kind.connection, found[1].kind);
    try testing.expectEqual(@as(u32, 5), found[1].chosen);
}

test "a row NetworkManager no longer reports is left alone" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try flush(conn, &.{
        .{ .kind = .connection, .key = "gone", .subtype = "wifi", .chosen = 4 },
        .{ .kind = .connection, .key = "here", .subtype = "wifi", .chosen = 1 },
    });
    try flush(conn, &.{.{ .kind = .connection, .key = "here", .subtype = "wifi", .chosen = 1 }});

    const found = try loaded(arena.allocator(), conn);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("gone", found[0].key);
    try testing.expectEqual(@as(u32, 4), found[0].chosen);
    try testing.expectEqual(@as(u32, 2), found[1].chosen);
}

test "an entry that moved neither counter is not written" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try flush(conn, &.{
        .{ .kind = .device, .key = "quiet", .subtype = "ethernet" },
        .{ .kind = .device, .key = "busy", .subtype = "ethernet", .shown = 1 },
    });

    const found = try loaded(arena.allocator(), conn);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("busy", found[0].key);
}

test "flushing nothing leaves the table alone" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try flush(conn, &.{.{ .kind = .device, .key = "eth0", .subtype = "ethernet", .shown = 7 }});
    try flush(conn, &.{});

    const found = try loaded(arena.allocator(), conn);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 7), found[0].shown);
}

test "a row whose type nobody recognizes is skipped" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try conn.exec(
        "INSERT INTO nm(type, key, subtype, shown, chosen) VALUES(?1,?2,?3,?4,?5)",
        .{ "wormhole", "x", "y", @as(i64, 1), @as(i64, 1) },
    );
    try flush(conn, &.{.{ .kind = .device, .key = "eth0", .subtype = "ethernet", .shown = 1 }});

    const found = try loaded(arena.allocator(), conn);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("eth0", found[0].key);
}

test "the counts survive a schema version bump that drops the indexes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/sysdeck.db", .{tmp.sub_path});

    const store = try store_mod.Store.open(testing.allocator, testing.io, path);
    defer store.close();

    try ensure(store.conn);
    try flush(store.conn, &.{
        .{ .kind = .connection, .key = "keep", .subtype = "wireguard", .chosen = 9 },
    });

    try store.ensure("apps");
    try store_mod.replace(testing.allocator, store.conn, "apps", .all, &.{
        .{ .key = "a", .title = "Alpha", .detail = "", .icon = "", .haystack = "Alpha" },
    }, 100);

    try testing.expectEqual(@as(usize, 1), (try store.load(arena.allocator(), "apps")).len);

    store.outdated = true;
    try store.ensure("apps");

    try testing.expectEqual(@as(usize, 0), (try store.load(arena.allocator(), "apps")).len);

    const found = try loaded(arena.allocator(), store.conn);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("keep", found[0].key);
    try testing.expectEqual(@as(u32, 9), found[0].chosen);
}
