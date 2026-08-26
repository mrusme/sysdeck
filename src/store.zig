const std = @import("std");
const zqlite = @import("zqlite");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.store);

const busy_timeout_ms = 2000;

// Bumped whenever a column changes, a version that does not match is dropped
// and indexed again.
const schema_version: i64 = 5;

const schema =
    \\CREATE TABLE IF NOT EXISTS sources(
    \\  name TEXT PRIMARY KEY,
    \\  updated_at INTEGER NOT NULL);
;

const table_schema =
    \\CREATE TABLE IF NOT EXISTS "{s}"(
    \\  adapter TEXT NOT NULL DEFAULT '',
    \\  key TEXT NOT NULL,
    \\  title TEXT NOT NULL,
    \\  detail TEXT NOT NULL,
    \\  icon TEXT NOT NULL,
    \\  haystack TEXT NOT NULL,
    \\  program TEXT NOT NULL DEFAULT '',
    \\  folder TEXT NOT NULL DEFAULT '',
    \\  tags TEXT NOT NULL DEFAULT '',
    \\  seen INTEGER NOT NULL,
    \\  shown INTEGER NOT NULL DEFAULT 0,
    \\  chosen INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY(adapter, key));
;

pub const Record = struct {
    adapter: []const u8 = "",
    key: []const u8,
    title: []const u8,
    detail: []const u8,
    icon: []const u8,
    haystack: []const u8,
    program: []const u8 = "",
    folder: []const u8 = "",
    tags: []const u8 = "",
    shown: u32 = 0,
    chosen: u32 = 0,
};

pub const Scope = union(enum) {
    all,
    adapter: []const u8,
};

pub const Delta = struct {
    adapter: []const u8,
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
        try self.conn.exec(
            "DELETE FROM sources WHERE name = ?1 OR name LIKE ?1 || '.%'",
            .{table},
        );
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
        return read(arena, self.conn, table);
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

pub fn read(arena: Allocator, conn: zqlite.Conn, table: []const u8) ![]Record {
    var sql: [256]u8 = undefined;
    const query = try std.fmt.bufPrint(
        &sql,
        "SELECT adapter, key, title, detail, icon, haystack, program, folder, tags, " ++
            "shown, chosen FROM \"{s}\"",
        .{table},
    );

    var records: std.ArrayList(Record) = .empty;

    var rows = try conn.rows(query, .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        try records.append(arena, .{
            .adapter = try arena.dupe(u8, row.text(0)),
            .key = try arena.dupe(u8, row.text(1)),
            .title = try arena.dupe(u8, row.text(2)),
            .detail = try arena.dupe(u8, row.text(3)),
            .icon = try arena.dupe(u8, row.text(4)),
            .haystack = try arena.dupe(u8, row.text(5)),
            .program = try arena.dupe(u8, row.text(6)),
            .folder = try arena.dupe(u8, row.text(7)),
            .tags = try arena.dupe(u8, row.text(8)),
            .shown = count(row.int(9)),
            .chosen = count(row.int(10)),
        });
    }
    if (rows.err) |err| return err;

    return records.toOwnedSlice(arena);
}

pub fn replace(
    gpa: Allocator,
    conn: zqlite.Conn,
    table: []const u8,
    scope: Scope,
    records: []const Record,
    seen: i64,
) !void {
    const upsert = try std.fmt.allocPrint(gpa,
        \\INSERT INTO "{s}"(adapter, key, title, detail, icon, haystack, program, folder,
        \\  tags, seen)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
        \\ON CONFLICT(adapter, key) DO UPDATE SET title=excluded.title,
        \\  detail=excluded.detail, icon=excluded.icon, haystack=excluded.haystack,
        \\  program=excluded.program, folder=excluded.folder, tags=excluded.tags,
        \\  seen=excluded.seen
    , .{table});
    defer gpa.free(upsert);

    try conn.transaction();
    errdefer conn.rollback();

    const stmt = try conn.prepare(upsert);
    defer stmt.deinit();

    for (records) |record| {
        try stmt.bind(.{
            record.adapter,
            record.key,
            record.title,
            record.detail,
            record.icon,
            record.haystack,
            record.program,
            record.folder,
            record.tags,
            seen,
        });
        try stmt.stepToCompletion();
        try stmt.reset();
    }

    try prune(gpa, conn, table, scope, seen);
    try mark(gpa, conn, table, scope, seen);
    try conn.commit();
}

pub fn keepAdapters(
    gpa: Allocator,
    conn: zqlite.Conn,
    table: []const u8,
    adapters: []const []const u8,
) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    for (try present(arena.allocator(), conn, table)) |name| {
        if (contains(adapters, name)) continue;
        try forget(gpa, conn, table, name);
    }
}

pub fn qualify(gpa: Allocator, table: []const u8, adapter: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ table, adapter });
}

fn prune(
    gpa: Allocator,
    conn: zqlite.Conn,
    table: []const u8,
    scope: Scope,
    seen: i64,
) !void {
    switch (scope) {
        .all => {
            const sql = try std.fmt.allocPrint(
                gpa,
                "DELETE FROM \"{s}\" WHERE seen <> ?1",
                .{table},
            );
            defer gpa.free(sql);
            try conn.exec(sql, .{seen});
        },
        .adapter => |name| {
            const sql = try std.fmt.allocPrint(
                gpa,
                "DELETE FROM \"{s}\" WHERE adapter = ?2 AND seen <> ?1",
                .{table},
            );
            defer gpa.free(sql);
            try conn.exec(sql, .{ seen, name });
        },
    }
}

fn mark(gpa: Allocator, conn: zqlite.Conn, table: []const u8, scope: Scope, seen: i64) !void {
    const sql = "INSERT INTO sources(name, updated_at) VALUES(?1,?2) " ++
        "ON CONFLICT(name) DO UPDATE SET updated_at=excluded.updated_at";

    const adapter = switch (scope) {
        .all => return conn.exec(sql, .{ table, seen }),
        .adapter => |name| name,
    };

    const qualified = try qualify(gpa, table, adapter);
    defer gpa.free(qualified);

    try conn.exec(sql, .{ qualified, seen });
}

fn present(arena: Allocator, conn: zqlite.Conn, table: []const u8) ![]const []const u8 {
    var sql: [128]u8 = undefined;
    const query = try std.fmt.bufPrint(&sql, "SELECT DISTINCT adapter FROM \"{s}\"", .{table});

    var names: std.ArrayList([]const u8) = .empty;

    var rows = try conn.rows(query, .{});
    defer rows.deinit();

    while (rows.next()) |row| try names.append(arena, try arena.dupe(u8, row.text(0)));
    if (rows.err) |err| return err;

    return names.toOwnedSlice(arena);
}

fn forget(gpa: Allocator, conn: zqlite.Conn, table: []const u8, adapter: []const u8) !void {
    const sql = try std.fmt.allocPrint(gpa, "DELETE FROM \"{s}\" WHERE adapter = ?1", .{table});
    defer gpa.free(sql);

    const qualified = try qualify(gpa, table, adapter);
    defer gpa.free(qualified);

    try conn.transaction();
    errdefer conn.rollback();

    try conn.exec(sql, .{adapter});
    try conn.exec("DELETE FROM sources WHERE name = ?1", .{qualified});
    try conn.commit();
}

fn contains(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

fn write(gpa: Allocator, conn: zqlite.Conn, table: []const u8, deltas: []const Delta) !void {
    const sql = try std.fmt.allocPrint(
        gpa,
        "UPDATE \"{s}\" SET shown = shown + ?3, chosen = chosen + ?4 " ++
            "WHERE adapter = ?1 AND key = ?2",
        .{table},
    );
    defer gpa.free(sql);

    try conn.transaction();
    errdefer conn.rollback();

    const stmt = try conn.prepare(sql);
    defer stmt.deinit();

    for (deltas) |delta| {
        try stmt.bind(.{
            delta.adapter,
            delta.key,
            @as(i64, delta.shown),
            @as(i64, delta.chosen),
        });
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

    try replace(testing.allocator, conn, "apps", .all, &sample, 100);
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

    try replace(testing.allocator, conn, "apps", .all, &sample, 100);

    const changed = [_]Record{
        .{ .key = "a.desktop", .title = "Alpha 2", .detail = "First", .icon = "alpha", .haystack = "Alpha 2 First" },
        sample[1],
    };
    try replace(testing.allocator, conn, "apps", .all, &changed, 200);

    const found = try readBack(conn, arena.allocator());
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("Alpha 2", found[0].title);
}

test "a row that is gone is pruned" {
    const conn = try openMemory();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try replace(testing.allocator, conn, "apps", .all, &sample, 100);
    try replace(testing.allocator, conn, "apps", .all, sample[0..1], 200);

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

    try replace(testing.allocator, conn, "apps", .all, &sample, 100);
    self.flush("apps", &.{.{ .adapter = "", .key = "a.desktop", .shown = 3, .chosen = 1 }});
    self.flush("apps", &.{.{ .adapter = "", .key = "a.desktop", .shown = 2, .chosen = 1 }});
    try replace(testing.allocator, conn, "apps", .all, &sample, 200);

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

    try replace(testing.allocator, conn, "apps", .all, &sample, 1234);
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

const links = [_]Record{
    .{
        .adapter = "markdown",
        .key = "https://ziglang.org",
        .title = "Zig",
        .detail = "https://ziglang.org",
        .icon = "",
        .haystack = "Zig",
    },
    .{
        .adapter = "chromium",
        .key = "https://ziglang.org",
        .title = "Ziglang",
        .detail = "https://ziglang.org",
        .icon = "",
        .haystack = "Ziglang",
    },
    .{
        .adapter = "chromium",
        .key = "https://sqlite.org",
        .title = "SQLite",
        .detail = "https://sqlite.org",
        .icon = "",
        .haystack = "SQLite",
    },
};

fn openBookmarks() !zqlite.Conn {
    const conn = try connect(":memory:");
    try conn.execNoArgs(schema);
    try create(testing.allocator, conn, "bookmarks");

    const gpa = testing.allocator;
    try replace(gpa, conn, "bookmarks", .{ .adapter = "markdown" }, links[0..1], 100);
    try replace(gpa, conn, "bookmarks", .{ .adapter = "chromium" }, links[1..], 100);
    return conn;
}

fn bookmarksOf(conn: zqlite.Conn, arena: Allocator) ![]Record {
    return read(arena, conn, "bookmarks");
}

test "the same key from two adapters is two rows" {
    const conn = try openBookmarks();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try bookmarksOf(conn, arena.allocator());
    try testing.expectEqual(@as(usize, 3), found.len);

    var markdown: usize = 0;
    for (found) |record| {
        if (std.mem.eql(u8, record.adapter, "markdown")) markdown += 1;
    }
    try testing.expectEqual(@as(usize, 1), markdown);
}

test "the tags of a row are kept" {
    const conn = try openBookmarks();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const tagged = [_]Record{.{
        .adapter = "firefox",
        .key = "https://ziglang.org",
        .title = "Zig",
        .detail = "https://ziglang.org",
        .icon = "",
        .haystack = "Zig https://ziglang.org lang,zig",
        .tags = "lang,zig",
    }};
    try replace(testing.allocator, conn, "bookmarks", .{ .adapter = "firefox" }, &tagged, 200);

    for (try bookmarksOf(conn, arena.allocator())) |record| {
        const wanted = if (std.mem.eql(u8, record.adapter, "firefox")) "lang,zig" else "";
        try testing.expectEqualStrings(wanted, record.tags);
    }
}

test "the folder of a row is kept" {
    const conn = try openBookmarks();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const filed = [_]Record{.{
        .adapter = "chromium",
        .key = "https://ziglang.org",
        .title = "Zig",
        .detail = "https://ziglang.org",
        .icon = "",
        .haystack = "Zig https://ziglang.org Dev/Languages",
        .folder = "Dev/Languages",
    }};
    try replace(testing.allocator, conn, "bookmarks", .{ .adapter = "chromium" }, &filed, 200);

    for (try bookmarksOf(conn, arena.allocator())) |record| {
        const wanted = if (std.mem.eql(u8, record.adapter, "chromium")) "Dev/Languages" else "";
        try testing.expectEqualStrings(wanted, record.folder);
    }
}

test "a scoped write leaves the rows of the other adapters alone" {
    const conn = try openBookmarks();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try replace(testing.allocator, conn, "bookmarks", .{ .adapter = "markdown" }, &.{}, 200);

    const found = try bookmarksOf(conn, arena.allocator());
    try testing.expectEqual(@as(usize, 2), found.len);
    for (found) |record| try testing.expectEqualStrings("chromium", record.adapter);
}

test "each adapter keeps a timestamp of its own" {
    const conn = try openBookmarks();
    defer conn.close();

    var self: Store = .{ .gpa = testing.allocator, .path = "", .conn = conn };

    const name = try qualify(testing.allocator, "bookmarks", "markdown");
    defer testing.allocator.free(name);

    try replace(testing.allocator, conn, "bookmarks", .{ .adapter = "markdown" }, links[0..1], 500);

    try testing.expectEqual(@as(?i64, 500), self.updatedAt(name));
    try testing.expectEqual(@as(?i64, 100), self.updatedAt("bookmarks.chromium"));
    try testing.expectEqual(@as(?i64, null), self.updatedAt("bookmarks"));
}

test "a counter lands on the row of its own adapter" {
    const conn = try openBookmarks();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var self: Store = .{ .gpa = testing.allocator, .path = "", .conn = conn };
    self.flush("bookmarks", &.{
        .{ .adapter = "markdown", .key = "https://ziglang.org", .shown = 2, .chosen = 1 },
    });

    for (try bookmarksOf(conn, arena.allocator())) |record| {
        const wanted: u32 = if (std.mem.eql(u8, record.adapter, "markdown")) 2 else 0;
        try testing.expectEqual(wanted, record.shown);
    }
}

test "an adapter that is no longer configured is forgotten" {
    const conn = try openBookmarks();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var self: Store = .{ .gpa = testing.allocator, .path = "", .conn = conn };
    try keepAdapters(testing.allocator, conn, "bookmarks", &.{"markdown"});

    const found = try bookmarksOf(conn, arena.allocator());
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("markdown", found[0].adapter);
    try testing.expectEqual(@as(?i64, null), self.updatedAt("bookmarks.chromium"));
    try testing.expectEqual(@as(?i64, 100), self.updatedAt("bookmarks.markdown"));
}

test "nothing configured leaves no rows behind" {
    const conn = try openBookmarks();
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try keepAdapters(testing.allocator, conn, "bookmarks", &.{});

    const found = try bookmarksOf(conn, arena.allocator());
    try testing.expectEqual(@as(usize, 0), found.len);
}

test "an age of zero always refreshes" {
    try testing.expect(stale(1000, 1000, 0));
    try testing.expect(stale(1000, 1000, -5));
}
