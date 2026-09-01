const std = @import("std");
const fuzzy = @import("fuzzy.zig");

const Allocator = std.mem.Allocator;

pub const chosen_weight: fuzzy.Score = 12;
pub const shown_weight: fuzzy.Score = 2;

pub const Weight = struct {
    shown: u32 = 0,
    chosen: u32 = 0,

    pub fn bonus(self: Weight) fuzzy.Score {
        return chosen_weight * scaled(self.chosen) + shown_weight * scaled(self.shown);
    }

    fn scaled(count: u32) fuzzy.Score {
        return @intCast(std.math.log2_int(u32, count + 1));
    }
};

pub const Match = struct {
    index: usize,
    score: fuzzy.Score,

    pub fn before(_: void, left: Match, right: Match) bool {
        if (left.score != right.score) return left.score > right.score;
        return left.index < right.index;
    }
};

pub fn rank(
    gpa: Allocator,
    haystacks: []const []const u8,
    weights: ?[]const Weight,
    query: []const u8,
) Allocator.Error![]Match {
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(gpa);

    for (haystacks, 0..) |haystack, index| {
        const value = fuzzy.score(query, haystack) orelse continue;
        const bonus = if (weights) |found| found[index].bonus() else 0;
        try matches.append(gpa, .{ .index = index, .score = value + bonus });
    }

    std.mem.sort(Match, matches.items, {}, Match.before);
    return matches.toOwnedSlice(gpa);
}

fn indexes(gpa: Allocator, matches: []const Match) Allocator.Error![]usize {
    const order = try gpa.alloc(usize, matches.len);
    for (matches, 0..) |match, at| order[at] = match.index;
    return order;
}

const testing = std.testing;

fn ranked(haystacks: []const []const u8, query: []const u8) ![]usize {
    const matches = try rank(testing.allocator, haystacks, null, query);
    defer testing.allocator.free(matches);
    return try indexes(testing.allocator, matches);
}

test "an empty query keeps everything in the order it was given" {
    const haystacks = [_][]const u8{ "second", "first", "third" };

    const order = try ranked(&haystacks, "");
    defer testing.allocator.free(order);

    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, order);
}

test "entries that do not match are left out" {
    const haystacks = [_][]const u8{ "zig release notes", "rust release notes", "zig build system" };

    const order = try ranked(&haystacks, "zig");
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 2), order.len);
    try testing.expect(std.mem.indexOfScalar(usize, order, 1) == null);
}

test "the better match ranks first" {
    const haystacks = [_][]const u8{ "a note about zigzag lines", "zig 0.16 released" };

    const order = try ranked(&haystacks, "zig");
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 1), order[0]);
}

test "equal scores keep the original order" {
    const haystacks = [_][]const u8{ "link one", "link two", "link six" };

    const order = try ranked(&haystacks, "link");
    defer testing.allocator.free(order);

    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, order);
}

test "a query matching nothing ranks nothing" {
    const haystacks = [_][]const u8{"only this"};

    const order = try ranked(&haystacks, "absent");
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 0), order.len);
}

test "nothing to rank ranks nothing" {
    const order = try ranked(&.{}, "query");
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 0), order.len);
}

test "a better match carries a higher score" {
    const haystacks = [_][]const u8{ "a note about zigzag lines", "zig 0.16 released" };

    const matches = try rank(testing.allocator, &haystacks, null, "zig");
    defer testing.allocator.free(matches);

    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expect(matches[0].score > matches[1].score);
}

test "a chosen entry outranks an equal match with no history" {
    const haystacks = [_][]const u8{ "link one", "link two" };
    const weights = [_]Weight{ .{}, .{ .chosen = 7 } };

    const matches = try rank(testing.allocator, &haystacks, &weights, "link");
    defer testing.allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches[0].index);
}

test "a light history does not overturn a clear difference in match quality" {
    const haystacks = [_][]const u8{ "zig 0.16 released", "amazing original garden" };
    const weights = [_]Weight{ .{}, .{ .chosen = 1 } };

    const matches = try rank(testing.allocator, &haystacks, &weights, "zig");
    defer testing.allocator.free(matches);

    try testing.expectEqual(@as(usize, 0), matches[0].index);
}

test "a heavy history does overturn it" {
    const haystacks = [_][]const u8{ "zig 0.16 released", "amazing original garden" };
    const weights = [_]Weight{ .{}, .{ .chosen = 7 } };

    const matches = try rank(testing.allocator, &haystacks, &weights, "zig");
    defer testing.allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches[0].index);
}

test "a weight cannot rescue something the query does not match at all" {
    const haystacks = [_][]const u8{ "zig 0.16 released", "nothing here" };
    const weights = [_]Weight{ .{}, .{ .chosen = 1000, .shown = 1000 } };

    const matches = try rank(testing.allocator, &haystacks, &weights, "zig");
    defer testing.allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(usize, 0), matches[0].index);
}

test "chosen outweighs shown at the same count" {
    const picked: Weight = .{ .chosen = 15 };
    const listed: Weight = .{ .shown = 15 };

    try testing.expect(picked.bonus() > listed.bonus());
    try testing.expectEqual(@as(fuzzy.Score, 0), (Weight{}).bonus());
}

test "the bonus grows logarithmically" {
    try testing.expectEqual(chosen_weight * 1, (Weight{ .chosen = 1 }).bonus());
    try testing.expectEqual(chosen_weight * 3, (Weight{ .chosen = 7 }).bonus());
    try testing.expectEqual(chosen_weight * 6, (Weight{ .chosen = 63 }).bonus());
}
