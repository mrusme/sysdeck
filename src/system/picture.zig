const std = @import("std");
const c = @import("../gtk/c.zig");
const circle = @import("core").circle;
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const pixbuf = @import("../gtk/pixbuf.zig");

const Allocator = std.mem.Allocator;

pub const Size = struct { width: c_int, height: c_int };

pub const Picture = struct {
    pixbuf: *c.GdkPixbuf,
    width: c_int,
    height: c_int,

    pub fn deinit(self: Picture) void {
        glib.g_object_unref(self.pixbuf);
    }
};

pub const Problem = struct {
    err: ?*c.GError,

    pub fn format(self: Problem, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(c.errorMessage(self.err));
    }

    pub fn deinit(self: Problem) void {
        if (self.err) |detail| glib.g_error_free(detail);
    }
};

pub const Decoded = union(enum) {
    picture: Picture,
    failed: Problem,
};

pub fn decode(bytes: []const u8, limit: Size) Decoded {
    const upright = switch (load(bytes)) {
        .picture => |found| found,
        .failed => |problem| return .{ .failed = problem },
    };
    defer upright.deinit();

    return .{ .picture = .{
        .pixbuf = scaled(upright.pixbuf, limit),
        .width = upright.width,
        .height = upright.height,
    } };
}

pub fn square(bytes: []const u8, side: c_int) Decoded {
    const upright = switch (load(bytes)) {
        .picture => |found| found,
        .failed => |problem| return .{ .failed = problem },
    };
    defer upright.deinit();

    const edge = @min(upright.width, upright.height);
    const middle = pixbuf.gdk_pixbuf_new_subpixbuf(
        upright.pixbuf,
        @divTrunc(upright.width - edge, 2),
        @divTrunc(upright.height - edge, 2),
        edge,
        edge,
    ) orelse return .{ .failed = .{ .err = null } };
    defer glib.g_object_unref(middle);

    return .{ .picture = .{
        .pixbuf = scaled(middle, .{ .width = side, .height = side }),
        .width = upright.width,
        .height = upright.height,
    } };
}

pub fn round(gpa: Allocator, source: *c.GdkPixbuf) Allocator.Error!*c.GdkTexture {
    const width = pixbuf.gdk_pixbuf_get_width(source);
    const height = pixbuf.gdk_pixbuf_get_height(source);
    const stride = pixbuf.gdk_pixbuf_get_rowstride(source);
    const channels = pixbuf.gdk_pixbuf_get_n_channels(source);
    const length: usize = @intCast(stride * (height - 1) + width * channels);

    const cut = try circle.cut(gpa, .{
        .bytes = pixbuf.gdk_pixbuf_read_pixels(source)[0..length],
        .width = @intCast(width),
        .height = @intCast(height),
        .stride = @intCast(stride),
        .channels = @intCast(channels),
    });
    defer gpa.free(cut);

    const shared = glib.g_bytes_new(cut.ptr, cut.len);
    defer glib.g_bytes_unref(shared);

    return gdk.gdk_memory_texture_new(width, height, .r8g8b8a8_premultiplied, shared, @intCast(width * 4));
}

fn load(bytes: []const u8) Decoded {
    const holder = glib.g_bytes_new(bytes.ptr, bytes.len);
    defer glib.g_bytes_unref(holder);

    const stream = gio.g_memory_input_stream_new_from_bytes(holder);
    defer glib.g_object_unref(stream);

    var err: ?*c.GError = null;
    const loaded = pixbuf.gdk_pixbuf_new_from_stream(c.cast(c.GInputStream, stream), null, &err) orelse {
        return .{ .failed = .{ .err = err } };
    };
    defer glib.g_object_unref(loaded);

    const upright = pixbuf.gdk_pixbuf_apply_embedded_orientation(loaded) orelse {
        return .{ .failed = .{ .err = null } };
    };

    return .{ .picture = .{
        .pixbuf = upright,
        .width = pixbuf.gdk_pixbuf_get_width(upright),
        .height = pixbuf.gdk_pixbuf_get_height(upright),
    } };
}

fn scaled(source: *c.GdkPixbuf, limit: Size) *c.GdkPixbuf {
    const width = pixbuf.gdk_pixbuf_get_width(source);
    const height = pixbuf.gdk_pixbuf_get_height(source);
    const wanted = within(.{ .width = width, .height = height }, limit);
    if (wanted.width == width and wanted.height == height) {
        return @ptrCast(glib.g_object_ref(source).?);
    }

    const smaller = pixbuf.gdk_pixbuf_scale_simple(source, wanted.width, wanted.height, .bilinear);
    return smaller orelse @ptrCast(glib.g_object_ref(source).?);
}

pub fn within(size: Size, limit: Size) Size {
    if (size.width <= 0 or size.height <= 0) return size;
    if (size.width <= limit.width and size.height <= limit.height) return size;

    const by_width = @as(i64, limit.width) * size.height;
    const by_height = @as(i64, limit.height) * size.width;

    if (by_width < by_height) {
        return .{
            .width = limit.width,
            .height = @intCast(@max(@divTrunc(by_width, size.width), 1)),
        };
    }
    return .{
        .width = @intCast(@max(@divTrunc(by_height, size.height), 1)),
        .height = limit.height,
    };
}

const testing = std.testing;

const pane: Size = .{ .width = 620, .height = 200 };

fn fitted(width: c_int, height: c_int) Size {
    return within(.{ .width = width, .height = height }, pane);
}

test "an image inside the limit is left at its size" {
    try testing.expectEqual(Size{ .width = 8, .height = 8 }, fitted(8, 8));
    try testing.expectEqual(Size{ .width = 620, .height = 200 }, fitted(620, 200));
    try testing.expectEqual(Size{ .width = 400, .height = 199 }, fitted(400, 199));
}

test "whichever edge is tighter is the one that bounds the picture" {
    try testing.expectEqual(Size{ .width = 355, .height = 200 }, fitted(1920, 1080));
    try testing.expectEqual(Size{ .width = 112, .height = 200 }, fitted(1080, 1920));
    try testing.expectEqual(Size{ .width = 266, .height = 200 }, fitted(400, 300));
    try testing.expectEqual(Size{ .width = 620, .height = 1 }, fitted(20000, 20));
}

test "the aspect ratio survives the scaling" {
    const found = fitted(4000, 3000);
    try testing.expectEqual(@as(c_int, 266), found.width);
    try testing.expectEqual(@as(c_int, 200), found.height);

    const wide = fitted(1920, 1080);
    const before = @as(f64, 1920) / @as(f64, 1080);
    const after = @as(f64, @floatFromInt(wide.width)) / @as(f64, @floatFromInt(wide.height));
    try testing.expect(@abs(before - after) < 0.01);
}

test "nothing is scaled to nothing, and a broken size is left alone" {
    try testing.expect(fitted(30000, 3).height >= 1);
    try testing.expect(fitted(3, 30000).width >= 1);
    try testing.expectEqual(Size{ .width = 0, .height = 0 }, fitted(0, 0));
    try testing.expectEqual(Size{ .width = -1, .height = 5 }, fitted(-1, 5));
}

fn encoded(width: c_int, height: c_int) ![]u8 {
    const pixels = try testing.allocator.alloc(u8, @intCast(width * height * 3));
    defer testing.allocator.free(pixels);
    @memset(pixels, 0x80);
    return pngOf(pixels, width, height);
}

fn halves(width: c_int, height: c_int) ![]u8 {
    const across: usize = @intCast(width);
    const pixels = try testing.allocator.alloc(u8, across * @as(usize, @intCast(height)) * 3);
    defer testing.allocator.free(pixels);

    for (0..pixels.len / 3) |at| {
        const left = at % across < across / 2;
        pixels[at * 3 ..][0..3].* = if (left) .{ 255, 0, 0 } else .{ 0, 0, 255 };
    }
    return pngOf(pixels, width, height);
}

fn pixelOf(found: *c.GdkPixbuf, x: c_int, y: c_int) [3]u8 {
    const stride = pixbuf.gdk_pixbuf_get_rowstride(found);
    const channels = pixbuf.gdk_pixbuf_get_n_channels(found);
    const at: usize = @intCast(y * stride + x * channels);
    return pixbuf.gdk_pixbuf_read_pixels(found)[at..][0..3].*;
}

fn pngOf(pixels: []const u8, width: c_int, height: c_int) ![]u8 {
    const made = pixbuf.gdk_pixbuf_new_from_data(
        pixels.ptr,
        .rgb,
        c.FALSE,
        8,
        width,
        height,
        width * 3,
        null,
        null,
    ).?;
    defer glib.g_object_unref(made);

    var written: ?[*]u8 = null;
    var length: usize = 0;
    const saved = pixbuf.gdk_pixbuf_save_to_bufferv(made, &written, &length, "png", null, null, null);
    try testing.expect(saved != c.FALSE);
    defer glib.g_free(written);

    return testing.allocator.dupe(u8, written.?[0..length]);
}

test "a decoded picture is scaled within the limit and keeps its own size" {
    const png = try encoded(400, 100);
    defer testing.allocator.free(png);

    const found = decode(png, .{ .width = 200, .height = 200 }).picture;
    defer found.deinit();

    try testing.expectEqual(@as(c_int, 400), found.width);
    try testing.expectEqual(@as(c_int, 100), found.height);
    try testing.expectEqual(@as(c_int, 200), pixbuf.gdk_pixbuf_get_width(found.pixbuf));
    try testing.expectEqual(@as(c_int, 50), pixbuf.gdk_pixbuf_get_height(found.pixbuf));
}

test "bytes that are no picture fail with a reason" {
    const problem = decode("<!DOCTYPE html>", .{ .width = 64, .height = 64 }).failed;
    defer problem.deinit();

    var buffer: [256]u8 = undefined;
    const reason = try std.mem.print(&buffer, "{f}", .{problem});
    try testing.expect(reason.len > 0);
    try testing.expect(problem.err != null);
}

test "a square is cut from the middle of a picture and scaled within the side" {
    const png = try halves(200, 100);
    defer testing.allocator.free(png);

    const found = square(png, 64).picture;
    defer found.deinit();

    try testing.expectEqual(@as(c_int, 200), found.width);
    try testing.expectEqual(@as(c_int, 100), found.height);
    try testing.expectEqual(@as(c_int, 64), pixbuf.gdk_pixbuf_get_width(found.pixbuf));
    try testing.expectEqual(@as(c_int, 64), pixbuf.gdk_pixbuf_get_height(found.pixbuf));
    try testing.expectEqual([3]u8{ 255, 0, 0 }, pixelOf(found.pixbuf, 4, 32));
    try testing.expectEqual([3]u8{ 0, 0, 255 }, pixelOf(found.pixbuf, 59, 32));
}

test "a picture smaller than the side is cropped but not enlarged" {
    const png = try halves(40, 20);
    defer testing.allocator.free(png);

    const found = square(png, 64).picture;
    defer found.deinit();

    try testing.expectEqual(@as(c_int, 20), pixbuf.gdk_pixbuf_get_width(found.pixbuf));
    try testing.expectEqual(@as(c_int, 20), pixbuf.gdk_pixbuf_get_height(found.pixbuf));
    try testing.expectEqual([3]u8{ 255, 0, 0 }, pixelOf(found.pixbuf, 0, 10));
    try testing.expectEqual([3]u8{ 0, 0, 255 }, pixelOf(found.pixbuf, 19, 10));
}

test "a round texture keeps the size of its square and loses its corners" {
    const png = try halves(200, 100);
    defer testing.allocator.free(png);

    const found = square(png, 64).picture;
    defer found.deinit();

    const texture = try round(testing.allocator, found.pixbuf);
    defer glib.g_object_unref(texture);

    try testing.expectEqual(@as(c_int, 64), gdk.gdk_texture_get_width(texture));
    try testing.expectEqual(@as(c_int, 64), gdk.gdk_texture_get_height(texture));

    var downloaded: [64 * 64 * 4]u8 = undefined;
    gdk.gdk_texture_download(texture, &downloaded, 64 * 4);
    try testing.expectEqual(@as(u8, 0), downloaded[3]);
    try testing.expectEqual(@as(u8, 0), downloaded[(64 * 64 - 1) * 4 + 3]);
    try testing.expectEqual(@as(u8, 255), downloaded[(32 * 64 + 32) * 4 + 3]);
}
