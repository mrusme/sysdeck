const std = @import("std");
const c = @import("../../gtk/c.zig");
const glib = @import("../../gtk/glib.zig");
const media = @import("core").media;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.preview);

const GExiv2Metadata = opaque {};
const GExiv2Orientation = c_int;
const GExiv2LogLevel = c_int;

const log_mute: GExiv2LogLevel = 4;

extern fn gexiv2_initialize() c.gboolean;
extern fn gexiv2_log_set_level(level: GExiv2LogLevel) void;
extern fn gexiv2_metadata_new() ?*GExiv2Metadata;
extern fn gexiv2_metadata_open_buf(
    self: *GExiv2Metadata,
    data: [*]const u8,
    n_data: c_long,
    err: ?*?*c.GError,
) c.gboolean;
extern fn gexiv2_metadata_has_exif(self: *GExiv2Metadata) c.gboolean;
extern fn gexiv2_metadata_get_pixel_width(self: *GExiv2Metadata) c_int;
extern fn gexiv2_metadata_get_pixel_height(self: *GExiv2Metadata) c_int;
extern fn gexiv2_metadata_try_get_orientation(
    self: *GExiv2Metadata,
    err: ?*?*c.GError,
) GExiv2Orientation;
extern fn gexiv2_metadata_try_get_tag_interpreted_string(
    self: *GExiv2Metadata,
    tag: [*:0]const u8,
    err: ?*?*c.GError,
) ?[*:0]u8;
extern fn gexiv2_metadata_try_get_gps_info(
    self: *GExiv2Metadata,
    longitude: *f64,
    latitude: *f64,
    altitude: *f64,
    err: ?*?*c.GError,
) c.gboolean;

const tags = [_][:0]const u8{
    "Exif.Image.Make",
    "Exif.Image.Model",
    "Exif.Photo.LensModel",
    "Exif.Photo.DateTimeOriginal",
    "Exif.Photo.ExposureTime",
    "Exif.Photo.FNumber",
    "Exif.Photo.ISOSpeedRatings",
    "Exif.Photo.FocalLength",
};

pub const max_fields = tags.len + 1;

pub const Reading = struct {
    width: u32 = 0,
    height: u32 = 0,
    fields: []const []const u8 = &.{},
    place: ?media.Place = null,
};

pub fn start() void {
    if (gexiv2_initialize() == c.FALSE) {
        log.warn("gexiv2 did not initialize, so no metadata will be read", .{});
        return;
    }
    gexiv2_log_set_level(log_mute);
}

pub fn read(arena: Allocator, bytes: []const u8) Allocator.Error!Reading {
    const self = gexiv2_metadata_new() orelse return .{};
    defer glib.g_object_unref(self);

    var err: ?*c.GError = null;
    if (gexiv2_metadata_open_buf(self, bytes.ptr, @intCast(bytes.len), &err) == c.FALSE) {
        if (err) |detail| glib.g_error_free(detail);
        return .{};
    }

    const sideways = orientation(self);
    const width = count(gexiv2_metadata_get_pixel_width(self));
    const height = count(gexiv2_metadata_get_pixel_height(self));

    var found: std.ArrayList([]const u8) = .empty;
    var place: ?media.Place = null;
    if (gexiv2_metadata_has_exif(self) != c.FALSE) {
        for (tags) |tag| {
            const value = interpreted(arena, self, tag) catch continue orelse continue;
            try found.append(arena, value);
        }
        place = located(self);
    }

    return .{
        .width = if (sideways) height else width,
        .height = if (sideways) width else height,
        .fields = try found.toOwnedSlice(arena),
        .place = place,
    };
}

fn orientation(self: *GExiv2Metadata) bool {
    var err: ?*c.GError = null;
    const found = gexiv2_metadata_try_get_orientation(self, &err);
    if (err) |detail| {
        glib.g_error_free(detail);
        return false;
    }
    return found >= 5 and found <= 8;
}

fn interpreted(
    arena: Allocator,
    self: *GExiv2Metadata,
    tag: [:0]const u8,
) Allocator.Error!?[]const u8 {
    var err: ?*c.GError = null;
    const value = gexiv2_metadata_try_get_tag_interpreted_string(self, tag.ptr, &err);
    if (err) |detail| {
        glib.g_error_free(detail);
        return null;
    }

    const text = value orelse return null;
    defer glib.g_free(text);

    const trimmed = std.mem.trim(u8, std.mem.span(text), " \t");
    if (trimmed.len == 0) return null;
    return try arena.dupe(u8, trimmed);
}

fn located(self: *GExiv2Metadata) ?media.Place {
    var longitude: f64 = 0;
    var latitude: f64 = 0;
    var altitude: f64 = 0;

    var err: ?*c.GError = null;
    const ok = gexiv2_metadata_try_get_gps_info(self, &longitude, &latitude, &altitude, &err);
    if (err) |detail| glib.g_error_free(detail);
    if (ok == c.FALSE) return null;
    if (longitude == 0 and latitude == 0) return null;
    if (!inRange(latitude, 90) or !inRange(longitude, 180)) return null;

    return .{ .latitude = latitude, .longitude = longitude };
}

fn inRange(value: f64, limit: f64) bool {
    return std.math.isFinite(value) and value >= -limit and value <= limit;
}

fn count(value: c_int) u32 {
    return std.math.cast(u32, value) orelse 0;
}

const testing = std.testing;

fn reading(arena: Allocator, bytes: []const u8) !Reading {
    start();
    return read(arena, bytes);
}

test "an image with no metadata at all reads as nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try reading(arena.allocator(), "not an image at all");
    try testing.expectEqual(@as(u32, 0), found.width);
    try testing.expectEqual(@as(u32, 0), found.height);
    try testing.expectEqual(@as(usize, 0), found.fields.len);
}

test "an empty buffer is refused without reading it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try reading(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), found.fields.len);
}

const png = @embedFile("testdata/plain.png");
const photo = @embedFile("testdata/photo.jpg");
const turned = @embedFile("testdata/turned.jpg");
const located_jpg = @embedFile("testdata/located.jpg");

test "a plain image gives its size and no fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try reading(arena.allocator(), png);
    try testing.expectEqual(@as(u32, 400), found.width);
    try testing.expectEqual(@as(u32, 300), found.height);
    try testing.expectEqual(@as(usize, 0), found.fields.len);
}

test "a photograph gives back the camera it came from" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try reading(arena.allocator(), photo);
    try testing.expect(found.fields.len >= 2);
    try testing.expectEqualStrings("FUJIFILM", found.fields[0]);
    try testing.expectEqualStrings("X100V", found.fields[1]);
}

test "a photograph that knows where it was taken gives the coordinates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try reading(arena.allocator(), located_jpg);
    const place = found.place.?;

    try testing.expectApproxEqAbs(@as(f64, 52.5163), place.latitude, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 13.3777), place.longitude, 0.0001);
    try testing.expectEqualStrings("Canon", found.fields[0]);
}

test "a photograph that does not know is left without a place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(@as(?media.Place, null), (try reading(arena.allocator(), photo)).place);
    try testing.expectEqual(@as(?media.Place, null), (try reading(arena.allocator(), png)).place);
}

test "a coordinate off the globe is refused" {
    try testing.expect(!inRange(91, 90));
    try testing.expect(!inRange(-91, 90));
    try testing.expect(!inRange(181, 180));
    try testing.expect(!inRange(std.math.nan(f64), 90));
    try testing.expect(!inRange(std.math.inf(f64), 90));

    try testing.expect(inRange(0, 90));
    try testing.expect(inRange(-90, 90));
    try testing.expect(inRange(52.5163, 90));
}

test "a quarter turn swaps the size a viewer sees" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try reading(arena.allocator(), turned);
    try testing.expectEqual(@as(u32, 100), found.width);
    try testing.expectEqual(@as(u32, 200), found.height);
}
