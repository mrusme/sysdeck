const std = @import("std");
const c = @import("../../gtk/c.zig");
const config_mod = @import("../../config.zig");
const glib = @import("../../gtk/glib.zig");
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const log = std.log.scoped(.disk);

pub const directory_mime = "inode/directory";

const specials = [_]struct { name: []const u8, kind: c.GUserDirectory }{
    .{ .name = "XDG_DESKTOP_DIR", .kind = .desktop },
    .{ .name = "XDG_DOCUMENTS_DIR", .kind = .documents },
    .{ .name = "XDG_DOWNLOAD_DIR", .kind = .download },
    .{ .name = "XDG_MUSIC_DIR", .kind = .music },
    .{ .name = "XDG_PICTURES_DIR", .kind = .pictures },
    .{ .name = "XDG_PUBLICSHARE_DIR", .kind = .public_share },
    .{ .name = "XDG_TEMPLATES_DIR", .kind = .templates },
    .{ .name = "XDG_VIDEOS_DIR", .kind = .videos },
};

pub const Location = struct {
    id: []const u8,
    root: []const u8,
    only: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    hidden: bool = false,
    max_age_minutes: i64 = 60,

    pub fn wants(self: Location, mime: []const u8) bool {
        if (self.only.len == 0) return true;
        for (self.only) |pattern| {
            if (typed(pattern, mime)) return true;
        }
        return false;
    }

    pub fn excluded(self: Location, relative: []const u8, basename: []const u8) bool {
        for (self.exclude) |pattern| {
            if (glob(pattern, relative) or glob(pattern, basename)) return true;
        }
        return false;
    }

    pub fn fingerprint(self: Location, arena: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(arena);

        try out.appendSlice(arena, self.root);
        try out.appendSlice(arena, "\nonly=");
        try join(arena, &out, self.only);
        try out.appendSlice(arena, "\nexclude=");
        try join(arena, &out, self.exclude);
        try out.appendSlice(arena, "\nhidden=");
        try out.appendSlice(arena, if (self.hidden) "true" else "false");

        return out.toOwnedSlice(arena);
    }
};

pub fn resolve(
    arena: Allocator,
    environ: *const Map,
    wanted: config_mod.Config.Sources.Disk.Location,
    max_age_minutes: i64,
) Allocator.Error!?Location {
    if (wanted.id.len == 0) {
        log.warn("a [sources.disk] location without an id is left out", .{});
        return null;
    }
    if (wanted.path.len == 0) {
        log.warn("the [sources.disk] location \"{s}\" has no path, so it is left out", .{
            wanted.id,
        });
        return null;
    }

    const root = (try expand(arena, environ, wanted.path)) orelse {
        log.warn(
            "the [sources.disk] location \"{s}\" reads \"{s}\", which cannot be resolved, " ++
                "so it is left out",
            .{ wanted.id, wanted.path },
        );
        return null;
    };

    if (!std.Io.Dir.path.isAbsolute(root)) {
        log.warn(
            "the [sources.disk] location \"{s}\" reads \"{s}\", which is not an absolute path, " ++
                "so it is left out",
            .{ wanted.id, root },
        );
        return null;
    }

    return .{
        .id = wanted.id,
        .root = trimmed(root),
        .only = wanted.only,
        .exclude = wanted.exclude,
        .hidden = wanted.hidden,
        .max_age_minutes = max_age_minutes,
    };
}

pub fn expand(
    arena: Allocator,
    environ: *const Map,
    wanted: []const u8,
) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    var at: usize = 0;
    while (at < wanted.len) {
        if (wanted[at] != '$') {
            try out.append(arena, wanted[at]);
            at += 1;
            continue;
        }

        const name = nameAt(wanted, at) orelse {
            try out.append(arena, wanted[at]);
            at += 1;
            continue;
        };

        const value = valueOf(environ, name.text) orelse return null;
        try out.appendSlice(arena, value);
        at = name.end;
    }

    const text = try out.toOwnedSlice(arena);
    const home = environ.get("HOME") orelse "";
    return try xdg.expand(arena, home, text);
}

const Name = struct {
    text: []const u8,
    end: usize,
};

fn nameAt(wanted: []const u8, at: usize) ?Name {
    if (at + 1 >= wanted.len) return null;

    if (wanted[at + 1] == '{') {
        const close = std.mem.findScalarPos(u8, wanted, at + 2, '}') orelse return null;
        if (close == at + 2) return null;
        return .{ .text = wanted[at + 2 .. close], .end = close + 1 };
    }

    var end = at + 1;
    while (end < wanted.len and isNameByte(wanted[end])) end += 1;
    if (end == at + 1) return null;

    return .{ .text = wanted[at + 1 .. end], .end = end };
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn valueOf(environ: *const Map, name: []const u8) ?[]const u8 {
    if (environ.get(name)) |found| {
        if (found.len > 0) return found;
    }

    for (specials) |special| {
        if (!std.mem.eql(u8, special.name, name)) continue;

        const found = glib.g_get_user_special_dir(special.kind) orelse return null;
        return std.mem.span(found);
    }
    return null;
}

fn trimmed(path: []const u8) []const u8 {
    const cut = std.mem.trimEnd(u8, path, "/");
    return if (cut.len > 0) cut else path;
}

fn typed(pattern: []const u8, mime: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.endsWith(u8, pattern, "/*")) {
        return std.mem.startsWith(u8, mime, pattern[0 .. pattern.len - 1]);
    }
    return std.mem.eql(u8, pattern, mime);
}

pub fn glob(pattern: []const u8, text: []const u8) bool {
    var wanted: usize = 0;
    var at: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;

    while (at < text.len) {
        if (wanted < pattern.len and pattern[wanted] == '*') {
            star = wanted;
            mark = at;
            wanted += 1;
            continue;
        }

        if (wanted < pattern.len and (pattern[wanted] == text[at] or
            (pattern[wanted] == '?' and text[at] != std.Io.Dir.path.sep)))
        {
            wanted += 1;
            at += 1;
            continue;
        }

        const seen = star orelse return false;
        if (text[mark] == std.Io.Dir.path.sep) return false;

        mark += 1;
        at = mark;
        wanted = seen + 1;
    }

    while (wanted < pattern.len and pattern[wanted] == '*') wanted += 1;
    return wanted == pattern.len;
}

fn join(
    arena: Allocator,
    out: *std.ArrayList(u8),
    parts: []const []const u8,
) Allocator.Error!void {
    for (parts, 0..) |part, at| {
        if (at > 0) try out.append(arena, ',');
        try out.appendSlice(arena, part);
    }
}

const testing = std.testing;

fn mapOf(pairs: []const [2][]const u8) !Map {
    var map: Map = .init(testing.allocator);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

fn expanded(
    arena: Allocator,
    pairs: []const [2][]const u8,
    wanted: []const u8,
) !?[]const u8 {
    var map = try mapOf(pairs);
    defer map.deinit();
    return expand(arena, &map, wanted);
}

test "a home relative path and a variable are both expanded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();
    const environ = [_][2][]const u8{
        .{ "HOME", "/home/tester" },
        .{ "MEDIA", "/mnt/media" },
    };

    try testing.expectEqualStrings(
        "/home/tester/documents",
        (try expanded(scratch, &environ, "~/documents")).?,
    );
    try testing.expectEqualStrings(
        "/mnt/media/photos",
        (try expanded(scratch, &environ, "$MEDIA/photos")).?,
    );
    try testing.expectEqualStrings(
        "/mnt/media/photos",
        (try expanded(scratch, &environ, "${MEDIA}/photos")).?,
    );
    try testing.expectEqualStrings(
        "/srv/data",
        (try expanded(scratch, &environ, "/srv/data")).?,
    );
}

test "a variable in the middle of a path is expanded where it stands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const environ = [_][2][]const u8{ .{ "HOME", "/home/tester" }, .{ "USER", "tester" } };

    try testing.expectEqualStrings(
        "/srv/tester/files",
        (try expanded(arena.allocator(), &environ, "/srv/$USER/files")).?,
    );
    try testing.expectEqualStrings(
        "/srv/tester-backup",
        (try expanded(arena.allocator(), &environ, "/srv/${USER}-backup")).?,
    );
}

test "a variable that resolves to nothing gives nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const environ = [_][2][]const u8{ .{ "HOME", "/home/tester" }, .{ "EMPTY", "" } };

    try testing.expectEqual(
        @as(?[]const u8, null),
        try expanded(arena.allocator(), &environ, "$NOTHING/files"),
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        try expanded(arena.allocator(), &environ, "$EMPTY/files"),
    );
}

test "a lone dollar is a character like any other" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const environ = [_][2][]const u8{.{ "HOME", "/home/tester" }};

    try testing.expectEqualStrings(
        "/srv/$/files",
        (try expanded(arena.allocator(), &environ, "/srv/$/files")).?,
    );
    try testing.expectEqualStrings(
        "/srv/cost$",
        (try expanded(arena.allocator(), &environ, "/srv/cost$")).?,
    );
}

test "an xdg directory falls back to the one the desktop keeps" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const environ = [_][2][]const u8{.{ "HOME", "/home/tester" }};
    const found = try expanded(arena.allocator(), &environ, "$XDG_PICTURES_DIR/shots");

    const special = glib.g_get_user_special_dir(.pictures);
    if (special == null) return testing.expectEqual(@as(?[]const u8, null), found);

    const wanted = try std.Io.Dir.path.join(arena.allocator(), &.{ std.mem.span(special.?), "shots" });
    try testing.expectEqualStrings(wanted, found.?);
}

test "the environment wins over the desktop directory" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const environ = [_][2][]const u8{
        .{ "HOME", "/home/tester" },
        .{ "XDG_PICTURES_DIR", "/mnt/photos" },
    };

    try testing.expectEqualStrings(
        "/mnt/photos/shots",
        (try expanded(arena.allocator(), &environ, "$XDG_PICTURES_DIR/shots")).?,
    );
}

fn resolved(
    arena: Allocator,
    wanted: config_mod.Config.Sources.Disk.Location,
) !?Location {
    var map = try mapOf(&.{.{ "HOME", "/home/tester" }});
    defer map.deinit();
    return resolve(arena, &map, wanted, 60);
}

test "a location is resolved from what the config holds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = (try resolved(arena.allocator(), .{
        .id = "documents",
        .path = "~/documents/",
        .only = &.{"application/pdf"},
        .exclude = &.{"drafts"},
        .hidden = true,
    })).?;

    try testing.expectEqualStrings("documents", found.id);
    try testing.expectEqualStrings("/home/tester/documents", found.root);
    try testing.expect(found.hidden);
    try testing.expectEqual(@as(i64, 60), found.max_age_minutes);
}

test "a location without an id, a path or an absolute path is left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();

    try testing.expectEqual(
        @as(?Location, null),
        try resolved(scratch, .{ .id = "", .path = "~/documents" }),
    );
    try testing.expectEqual(
        @as(?Location, null),
        try resolved(scratch, .{ .id = "documents", .path = "" }),
    );
    try testing.expectEqual(
        @as(?Location, null),
        try resolved(scratch, .{ .id = "documents", .path = "documents/notes" }),
    );
    try testing.expectEqual(
        @as(?Location, null),
        try resolved(scratch, .{ .id = "documents", .path = "$NOTHING/notes" }),
    );
}

test "an empty only list takes everything" {
    const self: Location = .{ .id = "documents", .root = "/home/tester" };

    try testing.expect(self.wants("text/plain"));
    try testing.expect(self.wants(directory_mime));
    try testing.expect(self.wants(""));
}

test "only takes an exact type and a wildcard" {
    const exact: Location = .{
        .id = "photos",
        .root = "/home/tester",
        .only = &.{ "image/jpeg", "image/png" },
    };

    try testing.expect(exact.wants("image/jpeg"));
    try testing.expect(exact.wants("image/png"));
    try testing.expect(!exact.wants("image/gif"));
    try testing.expect(!exact.wants(directory_mime));

    const wide: Location = .{
        .id = "photos",
        .root = "/home/tester",
        .only = &.{ "image/*", directory_mime },
    };

    try testing.expect(wide.wants("image/gif"));
    try testing.expect(wide.wants("image/svg+xml"));
    try testing.expect(wide.wants(directory_mime));
    try testing.expect(!wide.wants("video/mp4"));
    try testing.expect(!wide.wants("text/image"));
}

test "folders alone are indexed when that is the only type" {
    const self: Location = .{
        .id = "trees",
        .root = "/home/tester",
        .only = &.{directory_mime},
    };

    try testing.expect(self.wants(directory_mime));
    try testing.expect(!self.wants("text/plain"));
}

test "a bare name is excluded at any depth and a subpath only where it is" {
    const self: Location = .{
        .id = "code",
        .root = "/home/tester/projects",
        .exclude = &.{ "node_modules", "build/tmp" },
    };

    try testing.expect(self.excluded("node_modules", "node_modules"));
    try testing.expect(self.excluded("app/node_modules", "node_modules"));
    try testing.expect(self.excluded("build/tmp", "tmp"));

    try testing.expect(!self.excluded("app/build/tmp", "tmp"));
    try testing.expect(!self.excluded("app/src", "src"));
    try testing.expect(!self.excluded("node_modules_old", "node_modules_old"));
}

test "a glob excludes by suffix and by a single character" {
    const self: Location = .{
        .id = "code",
        .root = "/home/tester/projects",
        .exclude = &.{ "*.o", "cache?" },
    };

    try testing.expect(self.excluded("app/main.o", "main.o"));
    try testing.expect(self.excluded("main.o", "main.o"));
    try testing.expect(self.excluded("cache1", "cache1"));

    try testing.expect(!self.excluded("app/main.zig", "main.zig"));
    try testing.expect(!self.excluded("cache", "cache"));
    try testing.expect(!self.excluded("cache12", "cache12"));
}

test "a star does not cross a separator" {
    try testing.expect(glob("*", "notes"));
    try testing.expect(!glob("*", "app/notes"));
    try testing.expect(glob("*/node_modules", "app/node_modules"));
    try testing.expect(!glob("*/node_modules", "app/lib/node_modules"));
    try testing.expect(glob("app/*/tmp", "app/build/tmp"));
    try testing.expect(glob("a*c", "abc"));
    try testing.expect(glob("a*c", "ac"));
    try testing.expect(!glob("a*c", "abd"));
    try testing.expect(glob("", ""));
    try testing.expect(!glob("", "a"));
    try testing.expect(glob("**", "notes"));
}

test "a fingerprint changes with every part of the location" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();
    const self: Location = .{
        .id = "photos",
        .root = "/home/tester/photos",
        .only = &.{ "image/jpeg", "image/png" },
        .exclude = &.{"raw"},
    };

    const base = try self.fingerprint(scratch);
    try testing.expectEqualStrings(base, try self.fingerprint(scratch));

    var narrowed = self;
    narrowed.only = &.{"image/jpeg"};
    try testing.expect(!std.mem.eql(u8, base, try narrowed.fingerprint(scratch)));

    var moved = self;
    moved.root = "/mnt/photos";
    try testing.expect(!std.mem.eql(u8, base, try moved.fingerprint(scratch)));

    var pruned = self;
    pruned.exclude = &.{};
    try testing.expect(!std.mem.eql(u8, base, try pruned.fingerprint(scratch)));

    var shown = self;
    shown.hidden = true;
    try testing.expect(!std.mem.eql(u8, base, try shown.fingerprint(scratch)));

    var aged = self;
    aged.max_age_minutes = 5;
    try testing.expectEqualStrings(base, try aged.fingerprint(scratch));
}
