const std = @import("std");
const builtin = @import("builtin");
const box = @import("box.zig");
const c = @import("../gtk/c.zig");
const cairo = @import("../gtk/cairo.zig");
const capture = @import("capture.zig");
const glib = @import("../gtk/glib.zig");
const pixbuf = @import("../gtk/pixbuf.zig");
const wl = @import("../wayland/c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.screenshot);

const native = builtin.target.cpu.arch.endian();
const quarter_turn = std.math.pi / 2.0;
const max_edge = 1 << 16;

pub const Kind = enum {
    png,
    jpeg,

    pub fn of(name: []const u8) Kind {
        const dot = std.mem.findScalarLast(u8, name, '.') orelse return .png;
        const suffix = name[dot + 1 ..];

        if (std.ascii.eqlIgnoreCase(suffix, "jpg")) return .jpeg;
        if (std.ascii.eqlIgnoreCase(suffix, "jpeg")) return .jpeg;
        return .png;
    }

    fn label(self: Kind) [:0]const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpeg",
        };
    }

    pub fn mime(self: Kind) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
        };
    }
};

pub const Layout = struct {
    format: c.cairo_format_t,
    swapped: bool,
};

pub fn layoutOf(format: wl.Format) ?Layout {
    return switch (format) {
        .argb8888 => .{ .format = .argb32, .swapped = false },
        .xrgb8888 => .{ .format = .rgb24, .swapped = false },
        .abgr8888 => .{ .format = .argb32, .swapped = true },
        .xbgr8888 => .{ .format = .rgb24, .swapped = true },
        else => null,
    };
}

fn swapChannels(pixels: []u8, width: u32, height: u32, stride: u32) void {
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const line = pixels[row * stride ..][0 .. width * 4];

        var at: usize = 0;
        while (at < line.len) : (at += 4) {
            const cell = line[at..][0..4];
            const value = std.mem.readInt(u32, cell, native);
            const turned = (value & 0xFF00FF00) |
                ((value & 0x00FF0000) >> 16) |
                ((value & 0x000000FF) << 16);
            std.mem.writeInt(u32, cell, turned, native);
        }
    }
}

fn packRgb(source: []const u8, width: u32, height: u32, stride: u32, out: []u8) void {
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const line = source[row * stride ..][0 .. width * 4];
        const target = out[row * width * 3 ..][0 .. width * 3];

        var at: u32 = 0;
        while (at < width) : (at += 1) {
            const value = std.mem.readInt(u32, line[at * 4 ..][0..4], native);
            target[at * 3 + 0] = @truncate(value >> 16);
            target[at * 3 + 1] = @truncate(value >> 8);
            target[at * 3 + 2] = @truncate(value);
        }
    }
}

fn scaleOf(screen: capture.Screen, frame: capture.Frame) f64 {
    const raw: f64 = @floatFromInt(if (screen.transform.turned()) frame.height else frame.width);
    const logical: f64 = @floatFromInt(@max(screen.logical.width, 1));

    if (raw <= 0) return 1;
    return raw / logical;
}

pub const Piece = struct {
    screen: capture.Screen,
    frame: capture.Frame,
};

pub fn compose(wanted: box.Box, pieces: []const Piece) ?*c.cairo_surface_t {
    var scale: f64 = 1;
    for (pieces) |piece| scale = @max(scale, scaleOf(piece.screen, piece.frame));

    const width = pixelsAcross(wanted.width, scale) orelse return null;
    const height = pixelsAcross(wanted.height, scale) orelse return null;

    const target = cairo.cairo_image_surface_create(.rgb24, width, height);
    if (cairo.cairo_surface_status(target) != c.cairo_status_success) {
        log.warn("cannot make a {d}x{d} image", .{ width, height });
        cairo.cairo_surface_destroy(target);
        return null;
    }

    const cr = cairo.cairo_create(target);
    defer cairo.cairo_destroy(cr);

    var painted = false;
    for (pieces) |piece| {
        if (place(cr, wanted, scale, piece)) painted = true;
    }

    if (!painted) {
        cairo.cairo_surface_destroy(target);
        return null;
    }

    cairo.cairo_surface_flush(target);
    return target;
}

fn place(cr: *c.cairo_t, wanted: box.Box, scale: f64, piece: Piece) bool {
    const frame = piece.frame;
    const screen = piece.screen;

    const layout = layoutOf(frame.format) orelse {
        log.warn("this compositor uses a pixel format sysdeck cannot read: 0x{x}", .{
            @backingInt(frame.format),
        });
        return false;
    };

    if (layout.swapped) swapChannels(frame.pixels, frame.width, frame.height, frame.stride);

    const source = cairo.cairo_image_surface_create_for_data(
        frame.pixels.ptr,
        layout.format,
        @intCast(frame.width),
        @intCast(frame.height),
        @intCast(frame.stride),
    );
    defer cairo.cairo_surface_destroy(source);

    if (cairo.cairo_surface_status(source) != c.cairo_status_success) {
        log.warn("cannot read a {d}x{d} frame", .{ frame.width, frame.height });
        return false;
    }

    const buffer_width: f64 = @floatFromInt(frame.width);
    const buffer_height: f64 = @floatFromInt(frame.height);

    const turned_width = if (screen.transform.turned()) buffer_height else buffer_width;
    const turned_height = if (screen.transform.turned()) buffer_width else buffer_height;

    const across: f64 = @floatFromInt(screen.logical.width);
    const down: f64 = @floatFromInt(screen.logical.height);
    const left: f64 = @floatFromInt(screen.logical.x - wanted.x);
    const top: f64 = @floatFromInt(screen.logical.y - wanted.y);

    cairo.cairo_save(cr);
    defer cairo.cairo_restore(cr);

    cairo.cairo_rectangle(cr, left * scale, top * scale, across * scale, down * scale);
    cairo.cairo_clip(cr);

    cairo.cairo_scale(cr, scale, scale);
    cairo.cairo_translate(cr, left, top);
    cairo.cairo_translate(cr, across / 2, down / 2);
    if (screen.transform.flipped_over()) cairo.cairo_scale(cr, -1, 1);
    cairo.cairo_rotate(cr, quarter_turn * @as(f64, @floatFromInt(screen.transform.quarters())));
    cairo.cairo_scale(
        cr,
        across / turned_width,
        down / turned_height * (if (frame.inverted) @as(f64, -1) else 1),
    );
    cairo.cairo_translate(cr, -buffer_width / 2, -buffer_height / 2);

    cairo.cairo_set_source_surface(cr, source, 0, 0);
    cairo.cairo_pattern_set_filter(cairo.cairo_get_source(cr), .good);
    cairo.cairo_paint(cr);
    return true;
}

fn pixelsAcross(logical: i32, scale: f64) ?c_int {
    if (logical <= 0) return null;

    const wanted = @round(@as(f64, @floatFromInt(logical)) * scale);
    if (wanted < 1 or wanted > max_edge) return null;
    return @intFromFloat(wanted);
}

pub fn encode(gpa: Allocator, surface: *c.cairo_surface_t, kind: Kind) ?[]u8 {
    const across: u32 = @intCast(cairo.cairo_image_surface_get_width(surface));
    const down: u32 = @intCast(cairo.cairo_image_surface_get_height(surface));
    const stride: u32 = @intCast(cairo.cairo_image_surface_get_stride(surface));
    const pixels = cairo.cairo_image_surface_get_data(surface) orelse return null;

    const rgb = gpa.alloc(u8, @as(usize, across) * @as(usize, down) * 3) catch {
        log.warn("out of memory while packing a {d}x{d} image", .{ across, down });
        return null;
    };
    defer gpa.free(rgb);

    packRgb(pixels[0 .. @as(usize, stride) * down], across, down, stride, rgb);

    const picture = pixbuf.gdk_pixbuf_new_from_data(
        rgb.ptr,
        .rgb,
        c.FALSE,
        8,
        @intCast(across),
        @intCast(down),
        @intCast(across * 3),
        null,
        null,
    ) orelse return null;
    defer glib.g_object_unref(picture);

    var written: ?[*]u8 = null;
    var length: usize = 0;
    var err: ?*c.GError = null;

    const saved = pixbuf.gdk_pixbuf_save_to_bufferv(
        picture,
        &written,
        &length,
        kind.label().ptr,
        null,
        null,
        &err,
    ) != c.FALSE;

    if (!saved) {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot encode the screenshot as {s}", .{kind.label()});
        return null;
    }

    const bytes = written orelse return null;
    defer glib.g_free(bytes);

    return gpa.dupe(u8, bytes[0..length]) catch null;
}

const testing = std.testing;

test "the file type follows the extension" {
    try testing.expectEqual(Kind.png, Kind.of("shot.png"));
    try testing.expectEqual(Kind.png, Kind.of("shot.PNG"));
    try testing.expectEqual(Kind.jpeg, Kind.of("shot.jpg"));
    try testing.expectEqual(Kind.jpeg, Kind.of("shot.JPEG"));
    try testing.expectEqual(Kind.png, Kind.of("shot.webp"));
    try testing.expectEqual(Kind.png, Kind.of("shot"));
    try testing.expectEqual(Kind.png, Kind.of("2026-09-01.14.02.png"));
    try testing.expectEqualStrings("image/jpeg", Kind.jpeg.mime());
}

test "every format the compositors offer maps to cairo" {
    try testing.expectEqual(c.cairo_format_t.argb32, layoutOf(.argb8888).?.format);
    try testing.expect(!layoutOf(.argb8888).?.swapped);

    try testing.expectEqual(c.cairo_format_t.rgb24, layoutOf(.xrgb8888).?.format);
    try testing.expect(!layoutOf(.xrgb8888).?.swapped);

    try testing.expectEqual(c.cairo_format_t.rgb24, layoutOf(.xbgr8888).?.format);
    try testing.expect(layoutOf(.xbgr8888).?.swapped);

    try testing.expectEqual(c.cairo_format_t.argb32, layoutOf(.abgr8888).?.format);
    try testing.expect(layoutOf(.abgr8888).?.swapped);

    try testing.expectEqual(null, layoutOf(@fromBackingInt(0x36314752)));
}

test "swapping red and blue leaves green and the fourth byte alone" {
    var pixels: [4]u32 = .{ 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00 };
    const bytes = std.mem.sliceAsBytes(pixels[0..]);

    swapChannels(bytes, 2, 2, 8);

    try testing.expectEqual(0x11443322, pixels[0]);
    try testing.expectEqual(0x55887766, pixels[1]);
    try testing.expectEqual(0x99CCBBAA, pixels[2]);
    try testing.expectEqual(0xDD00FFEE, pixels[3]);
}

test "the padding at the end of a row is left untouched" {
    var pixels: [4]u32 = .{ 0x11223344, 0xAAAAAAAA, 0x55667788, 0xBBBBBBBB };
    const bytes = std.mem.sliceAsBytes(pixels[0..]);

    swapChannels(bytes, 1, 2, 8);

    try testing.expectEqual(0x11443322, pixels[0]);
    try testing.expectEqual(0xAAAAAAAA, pixels[1]);
    try testing.expectEqual(0x55887766, pixels[2]);
    try testing.expectEqual(0xBBBBBBBB, pixels[3]);
}

test "packing turns cairo pixels into three byte rgb" {
    var pixels: [6]u32 = .{
        0xFF0A141E, 0xFF28323C, 0,
        0xFF465A6E, 0xFF64788C, 0,
    };
    const bytes = std.mem.sliceAsBytes(pixels[0..]);

    var out: [12]u8 = undefined;
    packRgb(bytes, 2, 2, 12, &out);

    try testing.expectEqualSlices(u8, &.{ 0x0A, 0x14, 0x1E, 0x28, 0x32, 0x3C }, out[0..6]);
    try testing.expectEqualSlices(u8, &.{ 0x46, 0x5A, 0x6E, 0x64, 0x78, 0x8C }, out[6..12]);
}

test "the scale follows the buffer against the logical size" {
    const flat: capture.Screen = .{
        .monitor = undefined,
        .output = undefined,
        .logical = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .transform = .normal,
    };
    const dense: capture.Frame = .{
        .format = .xrgb8888,
        .width = 3840,
        .height = 2160,
        .stride = 3840 * 4,
        .inverted = false,
        .pixels = &.{},
    };

    try testing.expectEqual(2, scaleOf(flat, dense));

    var turned = flat;
    turned.transform = .rotate_90;
    turned.logical = .{ .x = 0, .y = 0, .width = 2160, .height = 3840 };
    try testing.expectEqual(1, scaleOf(turned, dense));
}
