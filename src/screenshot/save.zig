const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const image = @import("image.zig");
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.screenshot);

pub const default_filename = "screenshot_%Y-%m-%d-%H%M%S.png";

const max_variants = 999;

pub fn folderOf(
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    configured: []const u8,
) Allocator.Error![]const u8 {
    const home = environ.get("HOME") orelse "";
    if (configured.len > 0) return xdg.expand(arena, home, configured);

    const pictures = glib.g_get_user_special_dir(.pictures) orelse
        return if (home.len > 0) home else ".";
    return arena.dupe(u8, std.mem.span(pictures));
}

pub fn nameOf(arena: Allocator, template: []const u8) Allocator.Error![]const u8 {
    const wanted = if (template.len > 0) template else default_filename;

    const owned = try arena.dupeSentinel(u8, wanted, 0);
    const now = glib.g_date_time_new_now_local() orelse return arena.dupe(u8, wanted);
    defer glib.g_date_time_unref(now);

    const formatted = glib.g_date_time_format(now, owned.ptr) orelse {
        log.warn("cannot read \"{s}\" as a date format", .{wanted});
        return fallback(arena, now);
    };
    defer glib.g_free(formatted);

    const text = std.mem.span(formatted);
    if (text.len == 0) return fallback(arena, now);
    return arena.dupe(u8, text);
}

fn fallback(arena: Allocator, now: *c.GDateTime) Allocator.Error![]const u8 {
    const formatted = glib.g_date_time_format(now, default_filename) orelse
        return arena.dupe(u8, "screenshot.png");
    defer glib.g_free(formatted);

    return arena.dupe(u8, std.mem.span(formatted));
}

pub fn variant(arena: Allocator, name: []const u8, index: usize) Allocator.Error![]const u8 {
    if (index <= 1) return arena.dupe(u8, name);

    const dot = std.mem.findScalarLast(u8, name, '.') orelse name.len;
    return arena.print("{s}-{d}{s}", .{ name[0..dot], index, name[dot..] });
}

pub fn store(
    arena: Allocator,
    io: std.Io,
    folder: []const u8,
    name: []const u8,
    bytes: []const u8,
) ?[]const u8 {
    const wanted = std.Io.Dir.path.join(arena, &.{ folder, name }) catch return null;

    const parent = std.Io.Dir.path.dirname(wanted) orelse folder;
    Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("cannot make {s}: {t}", .{ parent, err });
            return null;
        },
    };

    var index: usize = 1;
    while (index <= max_variants) : (index += 1) {
        const attempt = variant(arena, wanted, index) catch return null;

        var file = Dir.cwd().createFile(io, attempt, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => {
                log.warn("cannot write {s}: {t}", .{ attempt, err });
                return null;
            },
        };
        defer file.close(io);

        file.writeStreamingAll(io, bytes) catch |err| {
            log.warn("cannot write {s}: {t}", .{ attempt, err });
            return null;
        };
        return attempt;
    }

    log.warn("{s} already has {d} screenshots of that name", .{ folder, max_variants });
    return null;
}

const testing = std.testing;

test "the first attempt keeps the name it was given" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    try testing.expectEqualStrings("shot.png", try variant(gpa, "shot.png", 0));
    try testing.expectEqualStrings("shot.png", try variant(gpa, "shot.png", 1));
}

test "a later attempt is numbered before the extension" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    try testing.expectEqualStrings("shot-2.png", try variant(gpa, "shot.png", 2));
    try testing.expectEqualStrings("shot-17.png", try variant(gpa, "shot.png", 17));
    try testing.expectEqualStrings(
        "/home/m/Pictures/screenshot_2026-09-01-140233-3.png",
        try variant(gpa, "/home/m/Pictures/screenshot_2026-09-01-140233.png", 3),
    );
}

test "a name without an extension is numbered at the end" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("shot-2", try variant(arena.allocator(), "shot", 2));
}

test "only the last dot counts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "2026.09.01-2.png",
        try variant(arena.allocator(), "2026.09.01.png", 2),
    );
}

test "a template is filled in and an empty one falls back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    const plain = try nameOf(gpa, "shot.png");
    try testing.expectEqualStrings("shot.png", plain);

    const dated = try nameOf(gpa, "screenshot_%Y.png");
    try testing.expectEqual(@as(usize, "screenshot_2026.png".len), dated.len);
    try testing.expect(std.mem.startsWith(u8, dated, "screenshot_2"));
    try testing.expect(std.mem.endsWith(u8, dated, ".png"));

    const empty = try nameOf(gpa, "");
    try testing.expect(std.mem.startsWith(u8, empty, "screenshot_2"));
    try testing.expect(std.mem.endsWith(u8, empty, ".png"));
}

test "a configured folder is expanded and an empty one has a default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/tester");

    try testing.expectEqualStrings(
        "/home/tester/shots",
        try folderOf(gpa, &environ, "~/shots"),
    );
    try testing.expectEqualStrings("/srv/shots", try folderOf(gpa, &environ, "/srv/shots"));
    try testing.expect((try folderOf(gpa, &environ, "")).len > 0);
}
