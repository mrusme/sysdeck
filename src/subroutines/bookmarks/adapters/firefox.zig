const std = @import("std");
const xdg = @import("core").xdg;
const zqlite = @import("zqlite");
const adapters = @import("../adapter.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.bookmarks);

pub const name = "firefox";

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

    pub fn collect(self: *Adapter, arena: Allocator) Allocator.Error!adapters.Collected {
        var links: std.ArrayList(adapters.Link) = .empty;
        var complete = true;

        for (self.files) |file| {
            const path = try xdg.expand(arena, self.home, file);

            _ = Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    log.debug("{s} is not there", .{path});
                    continue;
                },
                else => {
                    log.warn("cannot look at {s}: {t}", .{ path, err });
                    complete = false;
                    continue;
                },
            };

            gather(arena, path, &links) catch |err| switch (err) {
                error.OutOfMemory => |leftover| return leftover,
                else => {
                    log.warn("cannot read the bookmarks in {s}: {t}", .{ path, err });
                    complete = false;
                },
            };
        }

        return .{ .links = try links.toOwnedSlice(arena), .complete = complete };
    }
};

fn gather(arena: Allocator, path: []const u8, out: *std.ArrayList(adapters.Link)) !void {
    const flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.Uri;
    const conn = try zqlite.open(try uriOf(arena, path), flags);
    defer conn.close();

    try read(arena, conn, out);
}

fn uriOf(arena: Allocator, path: []const u8) Allocator.Error![:0]const u8 {
    var uri: std.ArrayList(u8) = .empty;
    try uri.appendSlice(arena, if (std.mem.startsWith(u8, path, "/")) "file://" else "file:");

    for (path) |char| switch (char) {
        '%' => try uri.appendSlice(arena, "%25"),
        '?' => try uri.appendSlice(arena, "%3F"),
        '#' => try uri.appendSlice(arena, "%23"),
        else => try uri.append(arena, char),
    };

    try uri.appendSlice(arena, "?immutable=1&mode=ro");
    return uri.toOwnedSliceSentinel(arena, 0);
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

fn openFixture(path: [:0]const u8) !zqlite.Conn {
    const conn = try zqlite.open(path, zqlite.OpenFlags.Create);
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
    const conn = try openFixture(":memory:");
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

const Profile = struct {
    tmp: testing.TmpDir,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    arena: std.heap.ArenaAllocator,

    fn init(self: *Profile) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator) };
        errdefer self.deinit();

        self.root = self.buffer[0..try self.tmp.dir.realPath(testing.io, &self.buffer)];
    }

    fn deinit(self: *Profile) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn pathOf(self: *Profile, file: []const u8) ![:0]const u8 {
        return std.Io.Dir.path.joinZ(self.arena.allocator(), &.{ self.root, file });
    }

    fn collect(self: *Profile, files: []const []const u8) !adapters.Collected {
        var adapter: Adapter = .{
            .io = testing.io,
            .home = "",
            .files = files,
            .max_age_minutes = 60,
        };
        return adapter.collect(self.arena.allocator());
    }
};

test "a places file that its browser holds locked is read" {
    var profile: Profile = undefined;
    try profile.init();
    defer profile.deinit();

    const path = try profile.pathOf("places.sqlite");
    const browser = try openFixture(path);
    defer browser.close();
    try browser.execNoArgs("BEGIN EXCLUSIVE");

    const collected = try profile.collect(&.{path});

    try testing.expect(collected.complete);
    try testing.expectEqual(5, collected.links.len);
}

test "a places file in a folder named with the characters of a uri is read" {
    var profile: Profile = undefined;
    try profile.init();
    defer profile.deinit();

    try profile.tmp.dir.createDir(testing.io, "50%25 off?#1", .default_dir);

    const path = try profile.pathOf("50%25 off?#1/places.sqlite");
    const browser = try openFixture(path);
    browser.close();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = buffer[0..try std.Io.Dir.cwd().realPath(testing.io, &buffer)];

    const arena = profile.arena.allocator();
    const doubled = try std.mem.concat(arena, u8, &.{ "/", path });
    const relative = try std.Io.Dir.path.relativeAllocPosix(arena, cwd, cwd, path);
    const collected = try profile.collect(&.{ path, doubled, relative });

    try testing.expect(collected.complete);
    try testing.expectEqual(15, collected.links.len);
}

test "a places file that is not there is skipped, and one that cannot be read is reported" {
    var profile: Profile = undefined;
    try profile.init();
    defer profile.deinit();

    try testing.expect((try profile.collect(&.{try profile.pathOf("gone.sqlite")})).complete);

    try profile.tmp.dir.symLink(testing.io, "loop.sqlite", "loop.sqlite", .{});
    try testing.expect(!(try profile.collect(&.{try profile.pathOf("loop.sqlite")})).complete);

    try profile.tmp.dir.writeFile(testing.io, .{
        .sub_path = "places.sqlite",
        .data = "not a database",
    });
    const collected = try profile.collect(&.{try profile.pathOf("places.sqlite")});

    try testing.expect(!collected.complete);
    try testing.expectEqual(0, collected.links.len);
}
