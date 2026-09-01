const std = @import("std");
const zqlite = @import("zqlite");
const adapters = @import("../adapter.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.bookmarks);

pub const name = "firefox";

const busy_timeout_ms = 2000;

const query =
    \\WITH RECURSIVE folders(id, path) AS (
    \\  SELECT id, ''
    \\    FROM moz_bookmarks
    \\   WHERE guid IN ('menu________', 'toolbar_____', 'unfiled_____', 'mobile______')
    \\   UNION ALL
    \\  SELECT b.id, CASE WHEN f.path = '' THEN COALESCE(b.title, '')
    \\                    ELSE f.path || '/' || COALESCE(b.title, '') END
    \\    FROM moz_bookmarks b JOIN folders f ON f.id = b.parent
    \\   WHERE b.type = 2
    \\),
    \\labels(place, tags) AS (
    \\  SELECT b.fk, group_concat(t.title, ',' ORDER BY t.title)
    \\    FROM moz_bookmarks b JOIN moz_bookmarks t ON t.id = b.parent
    \\   WHERE b.type = 1
    \\     AND t.parent = (SELECT id FROM moz_bookmarks WHERE guid = 'tags________')
    \\   GROUP BY b.fk
    \\)
    \\SELECT COALESCE(b.title, ''), p.url, f.path, COALESCE(l.tags, '')
    \\  FROM moz_bookmarks b
    \\  JOIN folders f ON f.id = b.parent
    \\  JOIN moz_places p ON p.id = b.fk
    \\  LEFT JOIN labels l ON l.place = b.fk
    \\ WHERE b.type = 1
    \\ ORDER BY f.path, b.position, b.id
;

pub const Adapter = struct {
    io: std.Io,
    home: []const u8,
    files: []const []const u8,
    max_age_minutes: i64,

    pub fn adapter(self: *Adapter) adapters.Adapter {
        return .{
            .name = name,
            .max_age_minutes = self.max_age_minutes,
            .context = self,
            .vtable = adapters.vtableOf(Adapter),
        };
    }

    pub fn collect(self: *Adapter, arena: Allocator) Allocator.Error![]const adapters.Link {
        var links: std.ArrayList(adapters.Link) = .empty;

        for (self.files) |file| {
            const path = try arena.dupeZ(u8, try adapters.expand(arena, self.home, file));

            _ = Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    log.debug("{s} is not there", .{path});
                    continue;
                },
                else => {
                    log.warn("cannot look at {s}: {t}", .{ path, err });
                    continue;
                },
            };

            gather(arena, path, &links) catch |err| switch (err) {
                error.OutOfMemory => |leftover| return leftover,
                else => log.warn("cannot read the bookmarks in {s}: {t}", .{ path, err }),
            };
        }

        return links.toOwnedSlice(arena);
    }
};

fn gather(arena: Allocator, path: [:0]const u8, out: *std.ArrayList(adapters.Link)) !void {
    const conn = try open(path);
    defer conn.close();

    try read(arena, conn, out);
}

fn open(path: [:0]const u8) !zqlite.Conn {
    const conn = try zqlite.open(path, zqlite.OpenFlags.ReadOnly);
    errdefer conn.close();

    try conn.busyTimeout(busy_timeout_ms);
    return conn;
}

pub fn read(arena: Allocator, conn: zqlite.Conn, out: *std.ArrayList(adapters.Link)) !void {
    var rows = try conn.rows(query, .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        try out.append(arena, .{
            .name = try arena.dupe(u8, row.text(0)),
            .url = try arena.dupe(u8, row.text(1)),
            .folder = try arena.dupe(u8, row.text(2)),
            .tags = try arena.dupe(u8, row.text(3)),
        });
    }
    if (rows.err) |err| return err;
}

const testing = std.testing;

const places_schema =
    \\CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR);
    \\CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER,
    \\  parent INTEGER, position INTEGER, title LONGVARCHAR, guid TEXT);
;

const places_rows =
    \\INSERT INTO moz_places(id, url) VALUES
    \\  (10, 'https://ziglang.org'),
    \\  (11, 'https://sqlite.org'),
    \\  (12, 'https://example.com/unnamed'),
    \\  (13, 'https://gtk.org'),
    \\  (14, 'place:type=6&sort=14');
    \\
    \\INSERT INTO moz_bookmarks(id, type, fk, parent, position, title, guid) VALUES
    \\  (1, 2, NULL, 0, 0, NULL, 'root________'),
    \\  (2, 2, NULL, 1, 0, 'menu', 'menu________'),
    \\  (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____'),
    \\  (4, 2, NULL, 1, 2, 'tags', 'tags________'),
    \\  (5, 2, NULL, 1, 3, 'unfiled', 'unfiled_____'),
    \\  (6, 2, NULL, 1, 4, 'mobile', 'mobile______'),
    \\  (20, 1, 10, 3, 0, 'Zig', 'aaaaaaaaaaaa'),
    \\  (21, 3, NULL, 3, 1, NULL, 'bbbbbbbbbbbb'),
    \\  (22, 2, NULL, 3, 2, 'Dev', 'cccccccccccc'),
    \\  (23, 1, 11, 22, 0, 'SQLite', 'dddddddddddd'),
    \\  (24, 2, NULL, 22, 1, 'Languages', 'eeeeeeeeeeee'),
    \\  (25, 1, 12, 24, 0, NULL, 'ffffffffffff'),
    \\  (26, 2, NULL, 22, 2, 'Empty', 'gggggggggggg'),
    \\  (27, 1, 14, 5, 0, 'Most Visited', 'hhhhhhhhhhhh'),
    \\  (28, 1, 13, 6, 0, 'GTK', 'iiiiiiiiiiii'),
    \\  (40, 2, NULL, 4, 0, 'zig', 'jjjjjjjjjjjj'),
    \\  (41, 2, NULL, 4, 1, 'read later', 'kkkkkkkkkkkk'),
    \\  (42, 1, 10, 40, 0, NULL, 'llllllllllll'),
    \\  (43, 1, 10, 41, 0, NULL, 'mmmmmmmmmmmm'),
    \\  (44, 1, 11, 41, 1, NULL, 'nnnnnnnnnnnn');
;

fn openFixture() !zqlite.Conn {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create);
    errdefer conn.close();

    try conn.execNoArgs(places_schema);
    try conn.execNoArgs(places_rows);
    return conn;
}

fn expectLinks(conn: zqlite.Conn, expected: []const adapters.Link) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var found: std.ArrayList(adapters.Link) = .empty;
    try read(arena.allocator(), conn, &found);

    try testing.expectEqual(expected.len, found.items.len);
    for (expected, found.items) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.url, got.url);
        try testing.expectEqualStrings(want.folder, got.folder);
        try testing.expectEqualStrings(want.tags, got.tags);
    }
}

test "every bookmark under the four roots is found with its folder and its tags" {
    const conn = try openFixture();
    defer conn.close();

    try expectLinks(conn, &.{
        .{ .name = "Zig", .url = "https://ziglang.org", .folder = "", .tags = "read later,zig" },
        .{ .name = "Most Visited", .url = "place:type=6&sort=14", .folder = "", .tags = "" },
        .{ .name = "GTK", .url = "https://gtk.org", .folder = "", .tags = "" },
        .{ .name = "SQLite", .url = "https://sqlite.org", .folder = "Dev", .tags = "read later" },
        .{
            .name = "",
            .url = "https://example.com/unnamed",
            .folder = "Dev/Languages",
            .tags = "",
        },
    });
}

test "a database without bookmarks gives nothing" {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create);
    defer conn.close();

    try conn.execNoArgs(places_schema);
    try expectLinks(conn, &.{});
}

test "a database that is not a places file is refused" {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create);
    defer conn.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var found: std.ArrayList(adapters.Link) = .empty;
    try testing.expectError(error.Error, read(arena.allocator(), conn, &found));
}
