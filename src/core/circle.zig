const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Pixels = struct {
    bytes: []const u8,
    width: usize,
    height: usize,
    stride: usize,
    channels: usize,
};

pub fn cut(gpa: Allocator, pixels: Pixels) Allocator.Error![]u8 {
    std.debug.assert(pixels.channels == 3 or pixels.channels == 4);

    const out = try gpa.alloc(u8, pixels.width * pixels.height * 4);

    const across: f32 = @floatFromInt(pixels.width);
    const down: f32 = @floatFromInt(pixels.height);
    const radius = @min(across, down) / 2;

    for (0..pixels.height) |y| {
        const row = pixels.bytes[y * pixels.stride ..];
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - down / 2;

        for (0..pixels.width) |x| {
            const source = row[x * pixels.channels ..][0..pixels.channels];
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - across / 2;

            const coverage = std.math.clamp(radius - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
            const own: f32 = if (pixels.channels == 4) @floatFromInt(source[3]) else 255;
            const alpha = own * coverage;

            const target = out[(y * pixels.width + x) * 4 ..][0..4];
            for (target[0..3], source[0..3]) |*channel, value| {
                channel.* = @intFromFloat(@round(@as(f32, @floatFromInt(value)) * alpha / 255));
            }
            target[3] = @intFromFloat(@round(alpha));
        }
    }
    return out;
}

const testing = std.testing;

fn filled(gpa: Allocator, width: usize, height: usize, stride: usize, pixel: []const u8) ![]u8 {
    const bytes = try gpa.alloc(u8, stride * height);
    @memset(bytes, 0xab);
    for (0..height) |y| {
        for (0..width) |x| @memcpy(bytes[y * stride + x * pixel.len ..][0..pixel.len], pixel);
    }
    return bytes;
}

fn at(out: []const u8, width: usize, x: usize, y: usize) [4]u8 {
    return out[(y * width + x) * 4 ..][0..4].*;
}

test "the corners of a square are cut away and its middle stays opaque" {
    const white = try filled(testing.allocator, 8, 8, 24, &.{ 255, 255, 255 });
    defer testing.allocator.free(white);

    const out = try cut(testing.allocator, .{ .bytes = white, .width = 8, .height = 8, .stride = 24, .channels = 3 });
    defer testing.allocator.free(out);

    for ([_][2]usize{ .{ 0, 0 }, .{ 7, 0 }, .{ 0, 7 }, .{ 7, 7 } }) |corner| {
        try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, at(out, 8, corner[0], corner[1]));
    }
    for ([_][2]usize{ .{ 3, 3 }, .{ 4, 4 }, .{ 1, 3 }, .{ 3, 6 } }) |inside| {
        try testing.expectEqual(255, at(out, 8, inside[0], inside[1])[3]);
    }
}

test "the edge of the circle is partly covered" {
    const white = try filled(testing.allocator, 8, 8, 24, &.{ 255, 255, 255 });
    defer testing.allocator.free(white);

    const out = try cut(testing.allocator, .{ .bytes = white, .width = 8, .height = 8, .stride = 24, .channels = 3 });
    defer testing.allocator.free(out);

    const edge = at(out, 8, 0, 2);
    try testing.expect(edge[3] > 0 and edge[3] < 255);
    try testing.expectEqual(edge, at(out, 8, 7, 5));
    try testing.expectEqual(edge, at(out, 8, 2, 0));
}

test "colors are premultiplied by the coverage and their own alpha" {
    const half = try filled(testing.allocator, 8, 8, 32, &.{ 200, 100, 50, 128 });
    defer testing.allocator.free(half);

    const out = try cut(testing.allocator, .{ .bytes = half, .width = 8, .height = 8, .stride = 32, .channels = 4 });
    defer testing.allocator.free(out);

    try testing.expectEqual([4]u8{ 100, 50, 25, 128 }, at(out, 8, 4, 4));

    const edge = at(out, 8, 0, 2);
    try testing.expect(edge[3] > 0 and edge[3] < 128);
    try testing.expect(edge[0] > 0 and edge[0] <= edge[3]);
}

test "a stride wider than a row is honored" {
    const bytes = try filled(testing.allocator, 4, 4, 16, &.{ 10, 20, 30 });
    defer testing.allocator.free(bytes);

    const out = try cut(testing.allocator, .{ .bytes = bytes, .width = 4, .height = 4, .stride = 16, .channels = 3 });
    defer testing.allocator.free(out);

    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, at(out, 4, 1, 1));
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, at(out, 4, 2, 2));
}
