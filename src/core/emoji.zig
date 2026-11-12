const std = @import("std");

pub const table = @embedFile("emoji.tsv");

const Fields = std.mem.SplitIterator(u8, .scalar);

pub const Row = struct {
    snippet: []const u8,
    name: []const u8,
    rest: []const u8,
    tones: []const u8,

    pub fn keywords(self: Row) Fields {
        return std.mem.splitScalar(u8, self.rest, '\t');
    }

    pub fn variants(self: Row) Variants {
        return .{ .lines = std.mem.splitScalar(u8, self.tones, '\n') };
    }
};

pub const Variant = struct {
    snippet: []const u8,
    label: []const u8,
    name: []const u8,
    rest: []const u8,

    pub fn keywords(self: Variant) Fields {
        return std.mem.splitScalar(u8, self.rest, '\t');
    }
};

pub const Variants = struct {
    lines: Fields,

    pub fn next(self: *Variants) ?Variant {
        while (self.lines.next()) |line| {
            if (line.len == 0) continue;

            var fields = std.mem.splitScalar(u8, line[1..], '\t');
            const snippet = fields.next() orelse continue;
            const label = fields.next() orelse continue;
            const name = fields.next() orelse continue;
            return .{ .snippet = snippet, .label = label, .name = name, .rest = fields.rest() };
        }
        return null;
    }
};

pub const Rows = struct {
    lines: Fields,

    pub fn next(self: *Rows) ?Row {
        while (self.lines.next()) |line| {
            if (line.len == 0 or line[0] == '\t') continue;

            var fields = std.mem.splitScalar(u8, line, '\t');
            const snippet = fields.next() orelse continue;
            const name = fields.next() orelse continue;

            const start = self.lines.index orelse table.len;
            var end = start;
            while (self.lines.peek()) |following| {
                if (following.len == 0 or following[0] != '\t') break;
                _ = self.lines.next();
                end = self.lines.index orelse table.len;
            }

            return .{
                .snippet = snippet,
                .name = name,
                .rest = fields.rest(),
                .tones = table[start..end],
            };
        }
        return null;
    }
};

pub fn rows() Rows {
    return .{ .lines = std.mem.splitScalar(u8, table, '\n') };
}

const testing = std.testing;

fn find(snippet: []const u8) ?Row {
    var all = rows();
    while (all.next()) |row| {
        if (std.mem.eql(u8, row.snippet, snippet)) return row;
    }
    return null;
}

fn has(words: Fields, wanted: []const u8) bool {
    var iterator = words;
    while (iterator.next()) |word| {
        if (std.mem.eql(u8, word, wanted)) return true;
    }
    return false;
}

fn count(row: Row) usize {
    var total: usize = 0;
    var all = row.variants();
    while (all.next()) |_| total += 1;
    return total;
}

test "every base emoji is a row with its skin tones, and no line of the notice is" {
    var bases: usize = 0;
    var variants: usize = 0;

    var all = rows();
    while (all.next()) |row| {
        bases += 1;
        try testing.expect(row.snippet.len > 0);
        try testing.expect(row.name.len > 0);

        var tones = row.variants();
        while (tones.next()) |variant| {
            variants += 1;
            try testing.expect(std.mem.endsWith(u8, variant.label, "skin tone"));
            try testing.expect(std.mem.find(u8, variant.name, ": ") != null);
        }
    }

    try testing.expectEqual(1914, bases);
    try testing.expectEqual(2030, variants);
    try testing.expect(std.mem.startsWith(u8, table, "UNICODE LICENSE V3\n"));
}

test "a base emoji lists its skin tones from light to dark" {
    const raising = find("🙌").?;
    try testing.expectEqualStrings("raising hands", raising.name);
    try testing.expect(has(raising.keywords(), "praise"));
    try testing.expect(!has(raising.keywords(), "raising hands"));
    try testing.expectEqual(5, count(raising));

    const labels = [_][]const u8{
        "light skin tone",
        "medium-light skin tone",
        "medium skin tone",
        "medium-dark skin tone",
        "dark skin tone",
    };
    var tones = raising.variants();
    for (labels) |label| try testing.expectEqualStrings(label, tones.next().?.label);

    var again = raising.variants();
    _ = again.next();
    _ = again.next();
    const medium = again.next().?;
    try testing.expectEqualStrings("🙌🏽", medium.snippet);
    try testing.expectEqualStrings("raising hands: medium skin tone", medium.name);
    try testing.expect(has(medium.keywords(), "medium skin tone"));
}

test "an emoji of two people lists every pair of skin tones" {
    const handshake = find("🤝").?;
    try testing.expectEqual(25, count(handshake));

    var found = false;
    var tones = handshake.variants();
    while (tones.next()) |variant| {
        if (!std.mem.eql(u8, variant.snippet, "🫱🏻‍🫲🏼")) continue;
        try testing.expectEqualStrings("light skin tone, medium-light skin tone", variant.label);
        found = true;
    }
    try testing.expect(found);

    try testing.expectEqual(25, count(find("💏").?));
}

test "a row whose emoji starts with a number sign is read" {
    const keycap = find("#️⃣").?;
    try testing.expectEqualStrings("keycap: #", keycap.name);
    try testing.expectEqual(0, count(keycap));
}
