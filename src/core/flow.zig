const std = @import("std");

pub const Spot = struct {
    x: i32,
    width: i32,
    line: u32,
};

pub const Cursor = struct {
    available: i32,
    spacing: i32,
    end: i32 = 0,
    line: u32 = 0,
    filled: bool = false,

    pub fn put(self: *Cursor, natural: i32) Spot {
        const width = @max(0, @min(natural, self.available));

        var x: i32 = 0;
        if (self.filled) {
            x = self.end + self.spacing;
            if (x + width > self.available) {
                x = 0;
                self.line += 1;
            }
        }

        self.end = x + width;
        self.filled = true;
        return .{ .x = x, .width = width, .line = self.line };
    }
};

const testing = std.testing;

fn expectSpot(x: i32, width: i32, line: u32, found: Spot) !void {
    try testing.expectEqual(Spot{ .x = x, .width = width, .line = line }, found);
}

test "children that fit share one line, spaced apart" {
    var cursor: Cursor = .{ .available = 200, .spacing = 4 };

    try expectSpot(0, 60, 0, cursor.put(60));
    try expectSpot(64, 50, 0, cursor.put(50));
    try expectSpot(118, 50, 0, cursor.put(50));
}

test "a child that ends at the edge stays on the line" {
    var cursor: Cursor = .{ .available = 114, .spacing = 4 };

    try expectSpot(0, 60, 0, cursor.put(60));
    try expectSpot(64, 50, 0, cursor.put(50));
}

test "a child one pixel over starts the next line at the left edge" {
    var cursor: Cursor = .{ .available = 113, .spacing = 4 };

    try expectSpot(0, 60, 0, cursor.put(60));
    try expectSpot(0, 50, 1, cursor.put(50));
    try expectSpot(54, 50, 1, cursor.put(50));
    try expectSpot(0, 50, 2, cursor.put(50));
}

test "a child wider than the line is cut to it and never wraps an empty line" {
    var cursor: Cursor = .{ .available = 100, .spacing = 4 };

    try expectSpot(0, 100, 0, cursor.put(300));
    try expectSpot(0, 40, 1, cursor.put(40));
    try expectSpot(0, 100, 2, cursor.put(101));
    try expectSpot(0, 100, 3, cursor.put(100));
}

test "the spacing is not counted before the first child of a line" {
    var cursor: Cursor = .{ .available = 100, .spacing = 30 };

    try expectSpot(0, 100, 0, cursor.put(100));
    try expectSpot(0, 70, 1, cursor.put(70));
    try expectSpot(0, 1, 2, cursor.put(1));
    try expectSpot(31, 69, 2, cursor.put(69));
}
