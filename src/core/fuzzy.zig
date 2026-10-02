const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Score = i32;

const match_bonus: Score = 16;
const consecutive_bonus: Score = 8;
const boundary_bonus: Score = 12;
const max_gap_penalty: Score = 20;
const max_start_penalty: Score = 20;

const boundary_before = " \t/-_.:?&=#,;+~@";

pub fn score(query: []const u8, haystack: []const u8) ?Score {
    var total: Score = 0;
    var terms = std.mem.tokenizeAny(u8, query, " \t");
    while (terms.next()) |term| {
        total += scoreTerm(term, haystack) orelse return null;
    }
    return total;
}

pub fn scoreFields(query: []const u8, fields: []const []const u8) ?Score {
    var total: Score = 0;
    var terms = std.mem.tokenizeAny(u8, query, " \t");
    while (terms.next()) |term| {
        var best: ?Score = null;
        for (fields) |field| {
            const value = scoreTerm(term, field) orelse continue;
            if (best == null or value > best.?) best = value;
        }
        total += best orelse return null;
    }
    return total;
}

pub fn queryOf(gpa: Allocator, text: []const u8) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var words = std.mem.tokenizeAny(u8, text, &std.ascii.whitespace);
    while (words.next()) |word| {
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, word);
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

fn scoreTerm(term: []const u8, haystack: []const u8) ?Score {
    if (term.len == 0) return 0;

    var best: ?Score = null;
    var start: usize = 0;
    while (indexOfIgnoreCase(haystack, term[0], start)) |at| : (start = at + 1) {
        const value = scoreFrom(term, haystack, at) orelse break;
        if (best == null or value > best.?) best = value;
    }
    return best;
}

fn scoreFrom(term: []const u8, haystack: []const u8, start: usize) ?Score {
    var total: Score = match_bonus;
    if (isBoundary(haystack, start)) total += boundary_bonus;

    var gaps: usize = 0;
    var previous = start;
    var from = start + 1;

    for (term[1..]) |wanted| {
        const at = indexOfIgnoreCase(haystack, wanted, from) orelse return null;
        if (at == previous + 1) {
            total += consecutive_bonus;
        } else {
            gaps += at - previous - 1;
        }

        total += match_bonus;
        if (isBoundary(haystack, at)) total += boundary_bonus;

        previous = at;
        from = at + 1;
    }

    total -= @min(std.math.lossyCast(Score, gaps), max_gap_penalty);
    total -= @min(std.math.lossyCast(Score, start), max_start_penalty);
    return total;
}

fn indexOfIgnoreCase(haystack: []const u8, wanted: u8, from: usize) ?usize {
    const folded = std.ascii.toLower(wanted);
    var at = from;
    while (at < haystack.len) : (at += 1) {
        if (std.ascii.toLower(haystack[at]) == folded) return at;
    }
    return null;
}

fn isBoundary(haystack: []const u8, at: usize) bool {
    if (at == 0) return true;

    const before = haystack[at - 1];
    if (std.mem.indexOfScalar(u8, boundary_before, before) != null) return true;
    return std.ascii.isLower(before) and std.ascii.isUpper(haystack[at]);
}

const testing = std.testing;

test "an empty query keeps everything at the same score" {
    try testing.expectEqual(@as(?Score, 0), score("", "anything at all"));
    try testing.expectEqual(@as(?Score, 0), score("   ", "anything at all"));
    try testing.expectEqual(score("", "one"), score("", "another"));
}

test "a query that is not a subsequence does not match" {
    try testing.expect(score("zig", "the ziglang site") != null);
    try testing.expect(score("gzi", "the ziglang site") == null);
    try testing.expect(score("zigg", "zig") == null);
}

test "matching ignores case in both directions" {
    try testing.expect(score("ZIG", "ziglang") != null);
    try testing.expect(score("zig", "ZIGLANG") != null);
}

test "a prefix beats the same letters later in the text" {
    const prefix = score("news", "news for nerds").?;
    const later = score("news", "hacker news").?;
    try testing.expect(prefix > later);
}

test "a word start beats the middle of a word" {
    const boundary = score("s", "release schedule").?;
    const middle = score("s", "releases").?;
    try testing.expect(boundary > middle);
}

test "consecutive letters beat scattered ones" {
    const together = score("abc", "abcdef").?;
    const apart = score("abc", "axbxcx").?;
    try testing.expect(together > apart);
}

test "every space separated term has to match" {
    try testing.expect(score("zig build", "src/build.zig") != null);
    try testing.expect(score("build zig", "src/build.zig") != null);
    try testing.expect(score("zig missing", "src/build.zig") == null);
}

test "a path separator counts as a word boundary" {
    const after_slash = score("m", "src/main.zig").?;
    const inside = score("m", "documents").?;
    try testing.expect(after_slash > inside);
}

test "each word may match a different field" {
    const fields = [_][]const u8{ "raised hand", "five", "high" };
    try testing.expect(scoreFields("high five", &fields) != null);
    try testing.expect(score("high five", "raised hand") == null);
}

test "a word matching no field rejects the entry" {
    const fields = [_][]const u8{ "raised hand", "five" };
    try testing.expect(scoreFields("high five", &fields) == null);
}

test "the best field is the one that counts" {
    const fields = [_][]const u8{ "a note about zigzag lines", "zig" };
    try testing.expectEqual(score("zig", "zig"), scoreFields("zig", &fields));
}

test "no fields match nothing, and no words match everything" {
    try testing.expect(scoreFields("zig", &.{}) == null);
    try testing.expectEqual(@as(?Score, 0), scoreFields("  ", &.{"anything"}));
}

test "text of several lines becomes one line with a single space between words" {
    const gpa = testing.allocator;

    const joined = try queryOf(gpa, "  line one\n\tline  two\r\n third \n");
    defer gpa.free(joined);
    try testing.expectEqualStrings("line one line two third", joined);
}

test "blank text becomes an empty query" {
    const gpa = testing.allocator;

    const blank = try queryOf(gpa, " \n\t\r ");
    defer gpa.free(blank);
    try testing.expectEqualStrings("", blank);
}
