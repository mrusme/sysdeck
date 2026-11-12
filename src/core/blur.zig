const std = @import("std");

const Allocator = std.mem.Allocator;

pub const box_width = 13;
pub const passes = 3;

const reach = box_width / 2;

const Rgb = @Vector(3, f32);

pub const Frame = struct {
    pixels: []const u8,
    width: usize,
    height: usize,
    stride: usize,
    swapped: bool = false,
    inverted: bool = false,
    quarters: u2 = 0,
    flipped: bool = false,
};

pub const Image = struct {
    width: usize,
    height: usize,
    values: []f32,

    pub fn deinit(self: Image, gpa: Allocator) void {
        gpa.free(self.values);
    }
};

const Axis = struct {
    length: usize,
    blocks: usize,
    run: usize,
    descending: bool,

    fn of(length: usize, step: usize, descending: bool) Axis {
        return .{
            .length = length,
            .blocks = @max(length / step, 1),
            .run = @min(step, length),
            .descending = descending,
        };
    }

    fn start(self: Axis, block: usize) usize {
        return if (self.descending) self.length - (block + 1) * self.run else block * self.run;
    }

    fn blockOf(self: Axis, at: usize) ?usize {
        const position = if (self.descending) self.length - 1 - at else at;
        const found = position / self.run;
        return if (found < self.blocks) found else null;
    }
};

pub fn shrink(gpa: Allocator, frame: Frame, factor: usize) Allocator.Error!Image {
    const step = @max(factor, 1);
    const turned = frame.quarters % 2 == 1;

    const columns: Axis = .of(frame.width, step, switch (frame.quarters) {
        0 => frame.flipped,
        1 => false,
        2 => !frame.flipped,
        3 => true,
    });
    const rows: Axis = .of(frame.height, step, frame.inverted != switch (frame.quarters) {
        0 => false,
        1 => !frame.flipped,
        2 => true,
        3 => frame.flipped,
    });

    const across = if (turned) rows.blocks else columns.blocks;
    const down = if (turned) columns.blocks else rows.blocks;
    const values = try gpa.alloc(f32, across * down * 3);
    @memset(values, 0);

    const column_step = if (turned) across * 3 else 3;
    const row_step = if (turned) 3 else across * 3;
    const red_shift: u5 = if (frame.swapped) 0 else 16;
    const blue_shift: u5 = if (frame.swapped) 16 else 0;

    for (0..frame.height) |at| {
        const block_row = rows.blockOf(at) orelse continue;
        const line: []align(1) const u32 = std.mem.bytesAsSlice(
            u32,
            frame.pixels[at * frame.stride ..][0 .. frame.width * 4],
        );

        for (0..columns.blocks) |block_column| {
            var red: u32 = 0;
            var green: u32 = 0;
            var blue: u32 = 0;
            for (line[columns.start(block_column)..][0..columns.run]) |value| {
                red += (value >> red_shift) & 0xff;
                green += (value >> 8) & 0xff;
                blue += (value >> blue_shift) & 0xff;
            }

            const target = values[block_row * row_step + block_column * column_step ..][0..3];
            target[0] += @floatFromInt(red);
            target[1] += @floatFromInt(green);
            target[2] += @floatFromInt(blue);
        }
    }

    const count: f32 = @floatFromInt(columns.run * rows.run);
    for (values) |*value| value.* /= count;
    return .{ .width = across, .height = down, .values = values };
}

pub fn blur(gpa: Allocator, image: Image) Allocator.Error!void {
    if (image.width == 0 or image.height == 0) return;

    const row_len = image.width * 3;
    const padded = try gpa.alloc(f32, row_len + box_width * 3);
    defer gpa.free(padded);
    const running = try gpa.alloc(f32, row_len);
    defer gpa.free(running);
    const spare = try gpa.alloc(f32, image.values.len);
    defer gpa.free(spare);

    var source = image.values;
    var target = spare;
    for (0..passes) |_| {
        for (0..image.height) |row| horizontal(source[row * row_len ..][0..row_len], padded);
        vertical(source, target, running, row_len, image.height);
        std.mem.swap([]f32, &source, &target);
    }
    if (source.ptr != image.values.ptr) @memcpy(image.values, source);
}

fn horizontal(line: []f32, padded: []f32) void {
    const last = line.len / 3 - 1;
    for (0..padded.len / 3) |at| {
        const from = @min(at -| reach, last);
        padded[at * 3 ..][0..3].* = line[from * 3 ..][0..3].*;
    }

    var sum: Rgb = @splat(0);
    for (0..box_width) |at| sum += pixel(padded, at);

    for (0..last + 1) |at| {
        line[at * 3 ..][0..3].* = sum / @as(Rgb, @splat(box_width));
        sum += pixel(padded, at + box_width) - pixel(padded, at);
    }
}

fn pixel(values: []const f32, at: usize) Rgb {
    return values[at * 3 ..][0..3].*;
}

fn vertical(source: []const f32, target: []f32, running: []f32, row_len: usize, height: usize) void {
    const last = height - 1;

    @memset(running, 0);
    for (0..box_width) |at| {
        const from = @min(at -| reach, last);
        for (running, source[from * row_len ..][0..row_len]) |*sum, value| sum.* += value;
    }

    for (0..height) |row| {
        const entering = source[@min(row + reach + 1, last) * row_len ..][0..row_len];
        const leaving = source[(row -| reach) * row_len ..][0..row_len];
        const out = target[row * row_len ..][0..row_len];

        for (out, running, entering, leaving) |*value, *sum, in, gone| {
            value.* = sum.* / box_width;
            sum.* += in - gone;
        }
    }
}

pub fn pack(image: Image, out: []u8) void {
    for (out, image.values) |*byte, value| byte.* = @intFromFloat(std.math.clamp(@round(value), 0, 255));
}

const testing = std.testing;

fn filled(pixels: []u32, value: u32) []const u8 {
    @memset(pixels, value);
    return std.mem.sliceAsBytes(pixels);
}

test "a flat image stays flat through the shrink and the blur" {
    var pixels: [32 * 24]u32 = undefined;
    const frame: Frame = .{
        .pixels = filled(&pixels, 0x00406080),
        .width = 32,
        .height = 24,
        .stride = 32 * 4,
    };

    const image = try shrink(testing.allocator, frame, 4);
    defer image.deinit(testing.allocator);
    try testing.expectEqual(8, image.width);
    try testing.expectEqual(6, image.height);

    try blur(testing.allocator, image);

    var packed_bytes: [8 * 6 * 3]u8 = undefined;
    pack(image, &packed_bytes);
    var at: usize = 0;
    while (at < packed_bytes.len) : (at += 3) {
        try testing.expectEqualSlices(u8, &.{ 0x40, 0x60, 0x80 }, packed_bytes[at..][0..3]);
    }
}

test "a shrink averages each block" {
    var pixels: [4 * 2]u32 = .{
        0x00ff0000, 0x00000000, 0x00ff00ff, 0x00ff00ff,
        0x00000000, 0x00ff0000, 0x00000000, 0x00000000,
    };
    const frame: Frame = .{ .pixels = std.mem.sliceAsBytes(&pixels), .width = 4, .height = 2, .stride = 16 };

    const image = try shrink(testing.allocator, frame, 2);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(2, image.width);
    try testing.expectEqual(1, image.height);
    try testing.expectEqualSlices(f32, &.{ 127.5, 0, 0, 127.5, 0, 127.5 }, image.values);
}

test "a swapped frame has red in the low byte" {
    var pixels: [1]u32 = .{0x00112233};
    const frame: Frame = .{
        .pixels = std.mem.sliceAsBytes(&pixels),
        .width = 1,
        .height = 1,
        .stride = 4,
        .swapped = true,
    };

    const image = try shrink(testing.allocator, frame, 4);
    defer image.deinit(testing.allocator);

    try testing.expectEqualSlices(f32, &.{ 0x33, 0x22, 0x11 }, image.values);
}

test "a single bright pixel keeps its sum and spreads symmetrically" {
    const side = 64;
    const values = try testing.allocator.alloc(f32, side * side * 3);
    const image: Image = .{ .width = side, .height = side, .values = values };
    defer image.deinit(testing.allocator);
    @memset(values, 0);

    const center = side / 2;
    values[(center * side + center) * 3] = 255;

    try blur(testing.allocator, image);

    const red = struct {
        fn at(all: []const f32, x: usize, y: usize) f32 {
            return all[(y * side + x) * 3];
        }
    }.at;

    var sum: f32 = 0;
    for (0..side) |y| {
        for (0..side) |x| sum += red(values, x, y);
    }
    try testing.expectApproxEqAbs(255, sum, 0.01);

    const spread = passes * reach;
    for (1..spread + 1) |distance| {
        const right = red(values, center + distance, center);
        try testing.expectApproxEqAbs(right, red(values, center - distance, center), 1e-5);
        try testing.expectApproxEqAbs(right, red(values, center, center + distance), 1e-5);
        try testing.expectApproxEqAbs(right, red(values, center, center - distance), 1e-5);
        try testing.expect(right > 0);
    }
    try testing.expectApproxEqAbs(0, red(values, center + spread + 1, center), 1e-4);
    try testing.expectEqual(0, values[(center * side + center) * 3 + 1]);
}

fn exactly(gpa: Allocator, image: Image) Allocator.Error![]f64 {
    const values = try gpa.alloc(f64, image.values.len);
    errdefer gpa.free(values);
    for (values, image.values) |*out, value| out.* = value;

    const line = try gpa.alloc(f64, @max(image.width, image.height));
    defer gpa.free(line);

    for (0..passes) |_| {
        for (0..image.height) |y| {
            for (0..3) |channel| average(values, line[0..image.width], y * image.width * 3 + channel, 3);
        }
        for (0..image.width) |x| {
            for (0..3) |channel| average(values, line[0..image.height], x * 3 + channel, image.width * 3);
        }
    }
    return values;
}

fn average(values: []f64, line: []f64, first: usize, stride: usize) void {
    const last: isize = @intCast(line.len - 1);
    for (line, 0..) |*out, at| {
        var sum: f64 = 0;
        for (0..box_width) |offset| {
            const index = std.math.clamp(@as(isize, @intCast(at + offset)) - reach, 0, last);
            sum += values[first + @as(usize, @intCast(index)) * stride];
        }
        out.* = sum / box_width;
    }
    for (line, 0..) |value, at| values[first + at * stride] = value;
}

test "the blur gives what a plain box filter with repeated edges gives" {
    var random: std.Random.DefaultPrng = .init(0x5d3c);
    const sizes = [_][2]usize{ .{ 1, 1 }, .{ 1, 9 }, .{ 9, 1 }, .{ 7, 5 }, .{ 31, 17 }, .{ 64, 3 } };

    for (sizes) |size| {
        const values = try testing.allocator.alloc(f32, size[0] * size[1] * 3);
        const image: Image = .{ .width = size[0], .height = size[1], .values = values };
        defer image.deinit(testing.allocator);
        for (values) |*value| value.* = random.random().float(f32) * 255;

        const wanted = try exactly(testing.allocator, image);
        defer testing.allocator.free(wanted);

        try blur(testing.allocator, image);
        for (values, wanted) |value, exact| try testing.expectApproxEqAbs(exact, value, 1e-3);
    }
}
