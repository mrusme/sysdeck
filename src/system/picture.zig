const std = @import("std");
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const pixbuf = @import("../gtk/pixbuf.zig");

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
    defer glib.g_object_unref(upright);

    return .{ .picture = .{
        .pixbuf = scaled(upright, limit),
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
    const reason = try std.fmt.bufPrint(&buffer, "{f}", .{problem});
    try testing.expect(reason.len > 0);
    try testing.expect(problem.err != null);
}
