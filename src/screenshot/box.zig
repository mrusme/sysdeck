const std = @import("std");

pub const Box = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn empty(self: Box) bool {
        return self.width <= 0 or self.height <= 0;
    }

    fn area(self: Box) i64 {
        if (self.empty()) return 0;
        return @as(i64, self.width) * @as(i64, self.height);
    }

    fn holds(self: Box, x: i32, y: i32) bool {
        return self.x <= x and x < self.x + self.width and
            self.y <= y and y < self.y + self.height;
    }

    pub fn meets(self: Box, other: Box) bool {
        return self.clip(other) != null;
    }

    fn clip(self: Box, other: Box) ?Box {
        if (self.empty() or other.empty()) return null;

        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);
        const right = @min(self.x + self.width, other.x + other.width);
        const bottom = @min(self.y + self.height, other.y + other.height);

        const found: Box = .{
            .x = left,
            .y = top,
            .width = right - left,
            .height = bottom - top,
        };
        return if (found.empty()) null else found;
    }
};

pub fn spanning(anchor_x: i32, anchor_y: i32, x: i32, y: i32) Box {
    return .{
        .x = @min(anchor_x, x),
        .y = @min(anchor_y, y),
        .width = @intCast(@abs(x - anchor_x) + 1),
        .height = @intCast(@abs(y - anchor_y) + 1),
    };
}

pub fn smallest(boxes: []const Box, x: i32, y: i32) ?usize {
    var found: ?usize = null;

    for (boxes, 0..) |candidate, at| {
        if (!candidate.holds(x, y)) continue;
        if (found) |previous| {
            if (boxes[previous].area() <= candidate.area()) continue;
        }
        found = at;
    }
    return found;
}

fn extents(boxes: []const Box) ?Box {
    var found: ?Box = null;

    for (boxes) |candidate| {
        if (candidate.empty()) continue;

        const grown = found orelse {
            found = candidate;
            continue;
        };

        const left = @min(grown.x, candidate.x);
        const top = @min(grown.y, candidate.y);
        const right = @max(grown.x + grown.width, candidate.x + candidate.width);
        const bottom = @max(grown.y + grown.height, candidate.y + candidate.height);

        found = .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }
    return found;
}

const testing = std.testing;

test "a box knows what it contains" {
    const box: Box = .{ .x = 10, .y = 20, .width = 100, .height = 50 };

    try testing.expect(box.holds(10, 20));
    try testing.expect(box.holds(109, 69));
    try testing.expect(!box.holds(110, 69));
    try testing.expect(!box.holds(109, 70));
    try testing.expect(!box.holds(9, 20));
}

test "an empty box holds nothing and has no area" {
    const flat: Box = .{ .x = 0, .y = 0, .width = 0, .height = 10 };

    try testing.expect(flat.empty());
    try testing.expectEqual(0, flat.area());
    try testing.expect(!flat.holds(0, 0));
    try testing.expectEqual(null, flat.clip(.{ .x = 0, .y = 0, .width = 5, .height = 5 }));
}

test "two boxes are clipped to what they share" {
    const left: Box = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const right: Box = .{ .x = 50, .y = 50, .width = 100, .height = 100 };

    const shared = left.clip(right).?;
    try testing.expectEqual(50, shared.x);
    try testing.expectEqual(50, shared.y);
    try testing.expectEqual(50, shared.width);
    try testing.expectEqual(50, shared.height);

    try testing.expect(left.meets(right));
    try testing.expect(!left.meets(.{ .x = 100, .y = 0, .width = 10, .height = 10 }));
}

test "a drag spans both ends whichever way it goes" {
    const forward = spanning(10, 10, 19, 29);
    try testing.expectEqual(10, forward.x);
    try testing.expectEqual(10, forward.y);
    try testing.expectEqual(10, forward.width);
    try testing.expectEqual(20, forward.height);

    const backward = spanning(19, 29, 10, 10);
    try testing.expectEqual(forward, backward);

    const sideways = spanning(19, 10, 10, 29);
    try testing.expectEqual(10, sideways.x);
    try testing.expectEqual(10, sideways.y);
    try testing.expectEqual(10, sideways.width);
    try testing.expectEqual(20, sideways.height);
}

test "a drag that does not move is one pixel" {
    const still = spanning(7, 8, 7, 8);
    try testing.expectEqual(7, still.x);
    try testing.expectEqual(8, still.y);
    try testing.expectEqual(1, still.width);
    try testing.expectEqual(1, still.height);
}

test "a drag across negative coordinates keeps its size" {
    const across = spanning(-5, -5, 4, 4);
    try testing.expectEqual(-5, across.x);
    try testing.expectEqual(10, across.width);
}

const nested = [_]Box{
    .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
    .{ .x = 100, .y = 100, .width = 800, .height = 600 },
    .{ .x = 200, .y = 200, .width = 400, .height = 300 },
};

test "the smallest box containing the point wins" {
    try testing.expectEqual(2, smallest(&nested, 300, 300));
    try testing.expectEqual(1, smallest(&nested, 700, 300));
    try testing.expectEqual(0, smallest(&nested, 1500, 900));
    try testing.expectEqual(null, smallest(&nested, 2000, 900));
}

test "no boxes means no choice" {
    try testing.expectEqual(null, smallest(&.{}, 0, 0));
}

test "the extents cover every box" {
    const spread = [_]Box{
        .{ .x = 0, .y = 0, .width = 1280, .height = 800 },
        .{ .x = 1280, .y = -200, .width = 800, .height = 600 },
    };

    const found = extents(&spread).?;
    try testing.expectEqual(0, found.x);
    try testing.expectEqual(-200, found.y);
    try testing.expectEqual(2080, found.width);
    try testing.expectEqual(1000, found.height);

    try testing.expectEqual(null, extents(&.{}));
}
