const std = @import("std");

const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;

pub const Kind = enum { data, config, cache };

const Base = struct {
    variable: []const u8,
    below_home: []const []const u8,
};

fn baseOf(kind: Kind) Base {
    return switch (kind) {
        .data => .{ .variable = "XDG_DATA_HOME", .below_home = &.{ ".local", "share" } },
        .config => .{ .variable = "XDG_CONFIG_HOME", .below_home = &.{".config"} },
        .cache => .{ .variable = "XDG_CACHE_HOME", .below_home = &.{".cache"} },
    };
}

pub fn path(
    gpa: Allocator,
    environ: *const Map,
    kind: Kind,
    parts: []const []const u8,
) Allocator.Error!?[]u8 {
    const base = baseOf(kind);

    var joined: std.ArrayList([]const u8) = .empty;
    defer joined.deinit(gpa);

    if (environ.get(base.variable)) |dir| {
        if (dir.len > 0) try joined.append(gpa, dir);
    }

    if (joined.items.len == 0) {
        const home = environ.get("HOME") orelse return null;
        if (home.len == 0) return null;

        try joined.append(gpa, home);
        try joined.appendSlice(gpa, base.below_home);
    }

    try joined.appendSlice(gpa, parts);
    return try std.fs.path.join(gpa, joined.items);
}

pub fn expand(arena: Allocator, home: []const u8, wanted: []const u8) Allocator.Error![]const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, wanted, "~")) return wanted;
    if (wanted.len == 1) return home;
    if (wanted[1] != '/') return wanted;

    return std.fs.path.join(arena, &.{ home, wanted[2..] });
}

const testing = std.testing;

fn mapOf(pairs: []const [2][]const u8) !Map {
    var map: Map = .init(testing.allocator);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

fn pathOf(pairs: []const [2][]const u8, kind: Kind, parts: []const []const u8) !?[]u8 {
    var map = try mapOf(pairs);
    defer map.deinit();
    return path(testing.allocator, &map, kind, parts);
}

test "the variable is used when it names a directory" {
    const found = (try pathOf(
        &.{.{ "XDG_DATA_HOME", "/srv/share" }},
        .data,
        &.{ "sysdeck", "sysdeck.db" },
    )).?;
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("/srv/share/sysdeck/sysdeck.db", found);
}

test "each kind falls back below the home directory" {
    const home = [_][2][]const u8{.{ "HOME", "/home/tester" }};

    const data = (try pathOf(&home, .data, &.{ "sysdeck", "clipboard.db" })).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("/home/tester/.local/share/sysdeck/clipboard.db", data);

    const config = (try pathOf(&home, .config, &.{ "sysdeck", "config.toml" })).?;
    defer testing.allocator.free(config);
    try testing.expectEqualStrings("/home/tester/.config/sysdeck/config.toml", config);

    const cache = (try pathOf(&home, .cache, &.{"rates.json"})).?;
    defer testing.allocator.free(cache);
    try testing.expectEqualStrings("/home/tester/.cache/rates.json", cache);
}

test "an empty variable falls back rather than producing a relative path" {
    const found = (try pathOf(
        &.{ .{ "XDG_CONFIG_HOME", "" }, .{ "HOME", "/home/tester" } },
        .config,
        &.{"sysdeck"},
    )).?;
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("/home/tester/.config/sysdeck", found);
}

test "nothing to go on gives nothing" {
    try testing.expectEqual(@as(?[]u8, null), try pathOf(&.{}, .data, &.{"sysdeck"}));
    try testing.expectEqual(
        @as(?[]u8, null),
        try pathOf(&.{.{ "HOME", "" }}, .cache, &.{"sysdeck"}),
    );
}

test "a home relative path is expanded and the rest is left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const home = "/home/tester";

    try testing.expectEqualStrings("/home/tester/notes.md", try expand(gpa, home, "~/notes.md"));
    try testing.expectEqualStrings("/home/tester", try expand(gpa, home, "~"));
    try testing.expectEqualStrings("/srv/notes.md", try expand(gpa, home, "/srv/notes.md"));
    try testing.expectEqualStrings("~other/notes.md", try expand(gpa, home, "~other/notes.md"));
    try testing.expectEqualStrings("~/notes.md", try expand(gpa, "", "~/notes.md"));
}
