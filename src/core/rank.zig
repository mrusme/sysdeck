const std = @import("std");
const fold = @import("fold.zig");
const fuzzy = @import("fuzzy.zig");

const Allocator = std.mem.Allocator;

pub const chosen_weight: fuzzy.Score = 12;
pub const shown_weight: fuzzy.Score = 2;
pub const min_chosen: u32 = 2;

pub const Weight = struct {
    shown: u32 = 0,
    chosen: u32 = 0,

    pub fn bonus(self: Weight) fuzzy.Score {
        return chosen_weight * scaled(self.chosen) + shown_weight * scaled(self.shown);
    }

    fn scaled(count: u32) fuzzy.Score {
        return @intCast(std.math.log2_int(u32, count +| 1));
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
    const wanted = try fold.query(gpa, query);
    defer gpa.free(wanted);

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(gpa);

    for (haystacks, 0..) |haystack, index| {
        _ = scratch.reset(.retain_capacity);
        const folded = try fold.fold(scratch.allocator(), haystack);
        const value = fuzzy.scoreFolded(wanted, folded) orelse continue;
        try matches.append(gpa, .{ .index = index, .score = value + bonusOf(weights, index) });
    }

    std.mem.sort(Match, matches.items, {}, Match.before);
    return matches.toOwnedSlice(gpa);
}

pub fn rankFolded(
    gpa: Allocator,
    haystacks: []const fold.Folded,
    weights: ?[]const Weight,
    query: []const u8,
) Allocator.Error![]Match {
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(gpa);

    for (haystacks, 0..) |haystack, index| {
        const value = fuzzy.scoreFolded(query, haystack) orelse continue;
        try matches.append(gpa, .{ .index = index, .score = value + bonusOf(weights, index) });
    }

    std.mem.sort(Match, matches.items, {}, Match.before);
    return matches.toOwnedSlice(gpa);
}

pub fn rankFields(
    gpa: Allocator,
    fields: []const []const []const u8,
    weights: ?[]const Weight,
    query: []const u8,
) Allocator.Error![]Match {
    const wanted = try fold.query(gpa, query);
    defer gpa.free(wanted);

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(gpa);

    for (fields, 0..) |one, index| {
        _ = scratch.reset(.retain_capacity);
        const folded = try scratch.allocator().alloc(fold.Folded, one.len);
        for (one, folded) |field, *slot| slot.* = try fold.fold(scratch.allocator(), field);

        const value = fuzzy.scoreFoldedFields(wanted, folded) orelse continue;
        try matches.append(gpa, .{ .index = index, .score = value + bonusOf(weights, index) });
    }

    std.mem.sort(Match, matches.items, {}, Match.before);
    return matches.toOwnedSlice(gpa);
}

pub fn rankFieldsFolded(
    gpa: Allocator,
    fields: []const []const fold.Folded,
    weights: ?[]const Weight,
    query: []const u8,
) Allocator.Error![]Match {
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(gpa);

    for (fields, 0..) |one, index| {
        const value = fuzzy.scoreFoldedFields(query, one) orelse continue;
        try matches.append(gpa, .{ .index = index, .score = value + bonusOf(weights, index) });
    }

    std.mem.sort(Match, matches.items, {}, Match.before);
    return matches.toOwnedSlice(gpa);
}

fn bonusOf(weights: ?[]const Weight, index: usize) fuzzy.Score {
    const found = weights orelse return 0;
    return found[index].bonus();
}

pub fn picks(
    gpa: Allocator,
    weights: []const Weight,
    limit: usize,
) Allocator.Error![]Match {
    var found: std.ArrayList(Match) = .empty;
    errdefer found.deinit(gpa);

    for (weights, 0..) |weight, index| {
        if (weight.chosen < min_chosen) continue;
        try found.append(gpa, .{ .index = index, .score = counted(weight.chosen) });
    }

    std.mem.sort(Match, found.items, weights, moreChosen);
    found.shrinkRetainingCapacity(@min(found.items.len, limit));
    return found.toOwnedSlice(gpa);
}

pub fn byChosen(gpa: Allocator, weights: []const Weight) Allocator.Error![]Match {
    const found = try gpa.alloc(Match, weights.len);
    for (weights, found, 0..) |weight, *slot, index| {
        slot.* = .{ .index = index, .score = counted(weight.chosen) };
    }

    std.mem.sort(Match, found, {}, Match.before);
    return found;
}

fn moreChosen(weights: []const Weight, left: Match, right: Match) bool {
    const one = weights[left.index];
    const other = weights[right.index];

    if (one.chosen != other.chosen) return one.chosen > other.chosen;
    if (one.shown != other.shown) return one.shown > other.shown;
    return left.index < right.index;
}

fn counted(chosen: u32) fuzzy.Score {
    return std.math.cast(fuzzy.Score, chosen) orelse std.math.maxInt(fuzzy.Score);
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
    try testing.expect(std.mem.findScalar(usize, order, 1) == null);
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

test "a counter that has saturated still gives a bonus" {
    const most: Weight = .{ .shown = std.math.maxInt(u32), .chosen = std.math.maxInt(u32) };
    try testing.expectEqual(chosen_weight * 31 + shown_weight * 31, most.bonus());
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

fn recommended(weights: []const Weight, limit: usize) ![]usize {
    const matches = try picks(testing.allocator, weights, limit);
    defer testing.allocator.free(matches);
    return try indexes(testing.allocator, matches);
}

test "an entry is a pick once it was chosen twice" {
    const weights = [_]Weight{ .{ .chosen = 1 }, .{ .chosen = 2 }, .{ .shown = 40 }, .{ .chosen = 5 } };

    const order = try recommended(&weights, 10);
    defer testing.allocator.free(order);

    try testing.expectEqualSlices(usize, &.{ 3, 1 }, order);
}

test "picks are ordered by how often they were chosen, then shown" {
    const weights = [_]Weight{
        .{ .chosen = 3, .shown = 1 },
        .{ .chosen = 3, .shown = 9 },
        .{ .chosen = 7 },
        .{ .chosen = 3, .shown = 9 },
    };

    const order = try recommended(&weights, 10);
    defer testing.allocator.free(order);

    try testing.expectEqualSlices(usize, &.{ 2, 1, 3, 0 }, order);
}

test "the limit keeps the most chosen picks" {
    const weights = [_]Weight{ .{ .chosen = 2 }, .{ .chosen = 9 }, .{ .chosen = 4 } };

    const cut = try recommended(&weights, 2);
    defer testing.allocator.free(cut);
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, cut);

    const whole = try recommended(&weights, 10);
    defer testing.allocator.free(whole);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, whole);
}

test "a pick is scored with its count" {
    const weights = [_]Weight{ .{ .chosen = 4 }, .{ .chosen = std.math.maxInt(u32) } };

    const matches = try picks(testing.allocator, &weights, 10);
    defer testing.allocator.free(matches);

    try testing.expectEqual(std.math.maxInt(fuzzy.Score), matches[0].score);
    try testing.expectEqual(@as(fuzzy.Score, 4), matches[1].score);
}

test "nothing chosen twice gives no picks" {
    const none = try recommended(&.{}, 10);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    const once = try recommended(&.{ .{ .chosen = 1 }, .{ .shown = 100 } }, 10);
    defer testing.allocator.free(once);
    try testing.expectEqual(@as(usize, 0), once.len);
}

test "every entry is listed, the most chosen first and in the given order among equals" {
    const weights = [_]Weight{
        .{ .shown = 9 },
        .{ .chosen = 1 },
        .{},
        .{ .chosen = 4 },
        .{ .chosen = 1, .shown = 30 },
    };

    const matches = try byChosen(testing.allocator, &weights);
    defer testing.allocator.free(matches);
    const order = try indexes(testing.allocator, matches);
    defer testing.allocator.free(order);

    try testing.expectEqualSlices(usize, &.{ 3, 1, 4, 0, 2 }, order);
    try testing.expectEqual(@as(fuzzy.Score, 4), matches[0].score);

    const none = try byChosen(testing.allocator, &.{});
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "an entry is ranked by its best fields" {
    const hand = [_][]const u8{ "raised hand", "five", "high" };
    const monkey = [_][]const u8{ "see-no-evil monkey", "hide" };
    const fields = [_][]const []const u8{ &monkey, &hand };

    const found = try rankFields(testing.allocator, &fields, null, "high five");
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(usize, 1), found[0].index);
}

test "a weight lifts an entry ranked by its fields" {
    const first = [_][]const u8{"fire"};
    const second = [_][]const u8{"fire"};
    const fields = [_][]const []const u8{ &first, &second };
    const weights = [_]Weight{ .{}, .{ .chosen = 7 } };

    const found = try rankFields(testing.allocator, &fields, &weights, "fire");
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(usize, 1), found[0].index);
}

test "a letter finds its capital beyond ASCII, and a query without accents ignores them" {
    const haystacks = [_][]const u8{ "Über uns", "École", "Яндекс", "Uber", "Ecole", "Łódź", "Tiếng Việt" };

    for (
        [_][]const u8{ "ü", "é", "я", "u", "uber", "ecole", "école", "lodz", "ŁÓDŹ", "tieng viet", "việt" },
        [_][]const usize{ &.{0}, &.{1}, &.{2}, &.{ 0, 3 }, &.{ 0, 3 }, &.{ 1, 4 }, &.{1}, &.{5}, &.{5}, &.{6}, &.{6} },
    ) |query, wanted| {
        const order = try ranked(&haystacks, query);
        defer testing.allocator.free(order);
        try testing.expectEqualSlices(usize, wanted, order);
    }
}

test "folded haystacks rank the way the raw ones do" {
    const haystacks = [_][]const u8{ "a note about zigzag lines", "zig 0.16 released", "ZigLang Build", "src/build.zig" };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const folded = try arena.allocator().alloc(fold.Folded, haystacks.len);
    for (haystacks, folded) |haystack, *slot| slot.* = try fold.fold(arena.allocator(), haystack);

    for ([_][]const u8{ "zig", "ZB", "build zig", "lang" }) |query| {
        const raw = try rank(testing.allocator, &haystacks, null, query);
        defer testing.allocator.free(raw);

        const prepared = try rankFolded(testing.allocator, folded, null, try fold.query(arena.allocator(), query));
        defer testing.allocator.free(prepared);

        try testing.expectEqualSlices(Match, raw, prepared);
    }
}
