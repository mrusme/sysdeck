const std = @import("std");
const zqlite = @import("zqlite");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.store);

const busy_timeout_ms = 2000;

// Bumped whenever a column changes, a version that does not match is dropped
// and indexed again.
const schema_version: i64 = 2;

const schema =
    \\CREATE TABLE IF NOT EXISTS sources(
    \\  name TEXT PRIMARY KEY,
    \\  updated_at INTEGER NOT NULL);
;

const table_schema =
    \\CREATE TABLE IF NOT EXISTS "{s}"(
    \\  key TEXT PRIMARY KEY,
    \\  title TEXT NOT NULL,
    \\  detail TEXT NOT NULL,
    \\  icon TEXT NOT NULL,
    \\  haystack TEXT NOT NULL,
    \\  program TEXT NOT NULL DEFAULT '',
    \\  seen INTEGER NOT NULL,
    \\  shown INTEGER NOT NULL DEFAULT 0,
    \\  chosen INTEGER NOT NULL DEFAULT 0);
;

pub const Record = struct {
    key: []const u8,
    title: []const u8,
    detail: []const u8,
    icon: []const u8,
    haystack: []const u8,
    program: []const u8 = "",
    shown: u32 = 0,
    chosen: u32 = 0,
};

pub const Delta = struct {
    key: []const u8,
    shown: u32,
    chosen: u32,
};

pub const Store = struct {
    gpa: Allocator,
    path: [:0]const u8,
    conn: zqlite.Conn,
    outdated: bool = false,

    pub fn open(gpa: Allocator, io: std.Io, path: []const u8) !*Store {
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const owned = try gpa.dupeZ(u8, path);
        errdefer gpa.free(owned);

        const conn = try connect(owned);
        errdefer conn.close();

        try conn.execNoArgs(schema);

        const self = try gpa.create(Store);
        self.* = .{ .gpa = gpa, .path = owned, .conn = conn, .outdated = try outdated(conn) };
        return self;
    }

    pub fn close(self: *Store) void {
        self.conn.close();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    pub fn ensure(self: *Store, table: []const u8) !void {
        if (self.outdated) try self.discard(table);
        try create(self.gpa, self.conn, table);
    }

    fn discard(self: *Store, table: []const u8) !void {
        const sql = try std.fmt.allocPrintSentinel(
            self.gpa,
            "DROP TABLE IF EXISTS \"{s}\"",
            .{table},
            0,
        );
        defer self.gpa.free(sql);

        try self.conn.execNoArgs(sql.ptr);
        try self.conn.exec("DELETE FROM sources WHERE name = ?1", .{table});
    }

    pub fn updatedAt(self: *Store, table: []const u8) ?i64 {
        const found = self.conn.row(
            "SELECT updated_at FROM sources WHERE name = ?1",
            .{table},
        ) catch |err| {
            self.report("read the timestamp of", table, err);
            return null;
        };
        const row = found orelse return null;
        defer row.deinit();
        return row.int(0);
    }

    pub fn load(self: *Store, arena: Allocator, table: []const u8) ![]Record {
        var sql: [256]u8 = undefined;
        const query = try std.fmt.bufPrint(
            &sql,
            "SELECT key, title, detail, icon, haystack, program, shown, chosen FROM \"{s}\"",
            .{table},
        );

        var records: std.ArrayList(Record) = .empty;

        var rows = try self.conn.rows(query, .{});
        defer rows.deinit();

        while (rows.next()) |row| {
            try records.append(arena, .{
                .key = try arena.dupe(u8, row.text(0)),
                .title = try arena.dupe(u8, row.text(1)),
                .detail = try arena.dupe(u8, row.text(2)),
                .icon = try arena.dupe(u8, row.text(3)),
                .haystack = try arena.dupe(u8, row.text(4)),
                .program = try arena.dupe(u8, row.text(5)),
                .shown = count(row.int(6)),
                .chosen = count(row.int(7)),
            });
        }
        if (rows.err) |err| return err;

        return records.toOwnedSlice(arena);
    }

    pub fn flush(self: *Store, table: []const u8, deltas: []const Delta) void {
        if (deltas.len == 0) return;
        write(self.gpa, self.conn, table, deltas) catch |err| {
            self.report("record the counters of", table, err);
        };
    }

    fn report(self: *Store, action: []const u8, table: []const u8, err: anyerror) void {
        log.warn("cannot {s} {s}: {t}: {s}", .{ action, table, err, self.conn.lastError() });
    }
};

pub fn connect(path: [:0]const u8) !zqlite.Conn {
    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    errdefer conn.close();

    try conn.busyTimeout(busy_timeout_ms);
    return conn;
}

pub fn create(gpa: Allocator, conn: zqlite.Conn, table: []const u8) !void {
    const sql = try std.fmt.allocPrintSentinel(gpa, table_schema, .{table}, 0);
    defer gpa.free(sql);
    try conn.execNoArgs(sql.ptr);
}

pub fn replace(
    gpa: Allocator,
    conn: zqlite.Conn,
    table: []const u8,
    records: []const Record,
    seen: i64,
) !void {
    const upsert = try std.fmt.allocPrint(gpa,
        \\INSERT INTO "{s}"(key, title, detail, icon, haystack, program, seen)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7)
        \\ON CONFLICT(key) DO UPDATE SET title=excluded.title, detail=excluded.detail,
        \\  icon=excluded.icon, haystack=excluded.haystack, program=excluded.program,
        \\  seen=excluded.seen
    , .{table});
    defer gpa.free(upsert);

    const prune = try std.fmt.allocPrint(gpa, "DELETE FROM \"{s}\" WHERE seen <> ?1", .{table});
    defer gpa.free(prune);

    const mark = "INSERT INTO sources(name, updated_at) VALUES(?1,?2) " ++
        "ON CONFLICT(name) DO UPDATE SET updated_at=excluded.updated_at";

    try conn.transaction();
    errdefer conn.rollback();

    const stmt = try conn.prepare(upsert);
    defer stmt.deinit();

    for (records) |record| {
        try stmt.bind(.{
            record.key,
            record.title,
            record.detail,
            record.icon,
            record.haystack,
            record.program,
            seen,
        });
        try stmt.stepToCompletion();
        try stmt.reset();
    }

    try conn.exec(prune, .{seen});
    try conn.exec(mark, .{ table, seen });
    try conn.commit();
}

fn write(gpa: Allocator, conn: zqlite.Conn, table: []const u8, deltas: []const Delta) !void {
    const sql = try std.fmt.allocPrint(
        gpa,
        "UPDATE \"{s}\" SET shown = shown + ?2, chosen = chosen + ?3 WHERE key = ?1",
        .{table},
    );
    defer gpa.free(sql);

    try conn.transaction();
    errdefer conn.rollback();

    const stmt = try conn.prepare(sql);
    defer stmt.deinit();

    for (deltas) |delta| {
        try stmt.bind(.{ delta.key, @as(i64, delta.shown), @as(i64, delta.chosen) });
        try stmt.stepToCompletion();
        try stmt.reset();
    }

    try conn.commit();
}

fn outdated(conn: zqlite.Conn) !bool {
    const found = try conn.row("PRAGMA user_version", .{});
    const stored = if (found) |value| block: {
        defer value.deinit();
        break :block value.int(0);
    } else 0;

    if (stored == schema_version) return false;

    var sql: [64]u8 = undefined;
    const set = try std.fmt.bufPrintZ(&sql, "PRAGMA user_version = {d}", .{schema_version});
    try conn.execNoArgs(set.ptr);
    return true;
}

pub fn now(io: std.Io) i64 {
    const micros = std.Io.Clock.real.now(io).toMicroseconds();
    return @intCast(@divFloor(micros, std.time.us_per_s));
}

pub fn stale(updated_at: ?i64, at: i64, max_age_minutes: i64) bool {
    if (max_age_minutes <= 0) return true;
    const stamp = updated_at orelse return true;
    return at - stamp >= max_age_minutes * std.time.s_per_min;
}

fn count(value: i64) u32 {
    return std.math.cast(u32, value) orelse 0;
}

pub fn defaultPath(gpa: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    if (environ.get("XDG_DATA_HOME")) |dir| {
        if (dir.len > 0) return try std.fs.path.join(gpa, &.{ dir, "sysdeck", "sysdeck.db" });
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) {
            return try std.fs.path.join(gpa, &.{ home, ".local", "share", "sysdeck", "sysdeck.db" });
        }
    }
    return null;
}

const testing = std.testing;

fn openMemory() !zqlite.Conn {
    const conn = try connect(":memory:");
    try conn.execNoArgs(schema);
    try create(testing.allocator, conn, "apps");
    return conn;
}

fn readBack(conn: zqlite.Conn, arena: Allocator) ![]Record {
    var self: Store = .{ .gpa = testing.allocator, .path = "", .conn = conn };
    return self.load(arena, "apps");
}

const sample = [_]Record{
    .{ .key = "a.desktop", .title = "Alpha", .detail = "First", .icon = "alpha", .haystack = "Alpha First" },
    .{ .key = "b.desktop", .title = "Beta", .detail = "Second", .icon = "beta", .haystack = "Beta Second" },
};

test "records come back the way they went in" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try replace(testing.allocator, conn, "apps", &sample, 100);
    const found = try readBack(conn, arena.allocator());

    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("a.desktop", found[0].key);
    try testing.expectEqualStrings("Alpha", found[0].title);
    try testing.expectEqualStrings("First", found[0].detail);
    try testing.expectEqualStrings("alpha", found[0].icon);
    try testing.expectEqualStrings("Alpha First", found[0].haystack);
    try testing.expectEqual(@as(u32, 0), found[0].shown);
}

test "a second write updates rows without duplicating them" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try replace(testing.allocator, conn, "apps", &sample, 100);

    const changed = [_]Record{
        .{ .key = "a.desktop", .title = "Alpha 2", .detail = "First", .icon = "alpha", .haystack = "Alpha 2 First" },
        sample[1],
    };
    try replace(testing.allocator, conn, "apps", &changed, 200);

    const found = try readBack(conn, arena.allocator());
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("Alpha 2", found[0].title);
}

test "a row that is gone is pruned" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try replace(testing.allocator, conn, "apps", &sample, 100);
    try replace(testing.allocator, conn, "apps", sample[0..1], 200);

    const found = try readBack(conn, arena.allocator());
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("a.desktop", found[0].key);
}

test "counters survive a rewrite and add rather than replace" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var self: Store = .{ .gpa = testing.allocator, .path = "", .conn = conn };

    try replace(testing.allocator, conn, "apps", &sample, 100);
    self.flush("apps", &.{.{ .key = "a.desktop", .shown = 3, .chosen = 1 }});
    self.flush("apps", &.{.{ .key = "a.desktop", .shown = 2, .chosen = 1 }});
    try replace(testing.allocator, conn, "apps", &sample, 200);

    const found = try self.load(arena.allocator(), "apps");
    try testing.expectEqual(@as(u32, 5), found[0].shown);
    try testing.expectEqual(@as(u32, 2), found[0].chosen);
    try testing.expectEqual(@as(u32, 0), found[1].shown);
}

test "the timestamp is recorded and read back" {
    const conn = try openMemory();
    defer conn.close();

    var self: Store = .{ .gpa = testing.allocator, .path = "", .conn = conn };
    try testing.expectEqual(@as(?i64, null), self.updatedAt("apps"));

    try replace(testing.allocator, conn, "apps", &sample, 1234);
    try testing.expectEqual(@as(?i64, 1234), self.updatedAt("apps"));
}

test "staleness turns over exactly at the age" {
    const minute = std.time.s_per_min;

    try testing.expect(stale(null, 1000, 60));
    try testing.expect(!stale(1000, 1000, 60));
    try testing.expect(!stale(1000, 1000 + 59 * minute, 60));
    try testing.expect(stale(1000, 1000 + 60 * minute, 60));
    try testing.expect(stale(1000, 1000 + 61 * minute, 60));
}

test "an age of zero always refreshes" {
    try testing.expect(stale(1000, 1000, 0));
    try testing.expect(stale(1000, 1000, -5));
}
