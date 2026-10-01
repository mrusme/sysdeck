const std = @import("std");

pub const Mode = enum {
    search,
    history,
    llm,
    disk,
    whats,
    nm,
    windows,

    pub fn label(self: Mode) [:0]const u8 {
        return table.get(self).label;
    }

    pub fn prompt(self: Mode) ?[:0]const u8 {
        return table.get(self).prompt;
    }

    pub fn missing(self: Mode) []const u8 {
        return table.get(self).missing;
    }

    pub fn source(self: Mode) ?[]const u8 {
        return table.get(self).source;
    }
};

const Entry = struct {
    label: [:0]const u8,
    prompt: ?[:0]const u8 = null,
    missing: []const u8 = "",
    source: ?[]const u8 = null,
};

const table: std.EnumArray(Mode, Entry) = .init(.{
    .search = .{ .label = "Search" },
    .history = .{
        .label = "History",
        .missing = "there is no clipboard history to show",
        .source = "clipboard",
    },
    .llm = .{
        .label = "LLM",
        .prompt = "Ask",
        .missing = "there is no LLM to ask",
        .source = "llm",
    },
    .disk = .{
        .label = "Disk",
        .prompt = "Browse",
        .missing = "there is no disk location to browse",
        .source = "disk",
    },
    .whats = .{
        .label = "Whats",
        .prompt = "Whats ...",
        .missing = "there is nothing to calculate or convert",
        .source = "whats",
    },
    .nm = .{
        .label = "Network",
        .prompt = "Network",
        .missing = "there is no network to manage",
        .source = "nm",
    },
    .windows = .{
        .label = "Windows",
        .prompt = "Focus",
        .missing = "there are no Sway windows to focus",
        .source = "sway",
    },
});

const testing = std.testing;

test "the search keeps the placeholder it was given" {
    try testing.expectEqual(@as(?[:0]const u8, null), Mode.search.prompt());
    try testing.expectEqualStrings("", Mode.search.missing());
    try testing.expectEqual(@as(?[]const u8, null), Mode.search.source());
}

test "every other mode explains itself and names a source" {
    for (std.enums.values(Mode)) |wanted| {
        if (wanted == .search) continue;

        try testing.expect(wanted.missing().len > 0);
        try testing.expect(wanted.source() != null);
    }
}

test "every mode has the label the README uses" {
    for (std.enums.values(Mode)) |wanted| try testing.expect(wanted.label().len > 0);

    try testing.expectEqualStrings("Search", Mode.search.label());
    try testing.expectEqualStrings("Windows", Mode.windows.label());
    try testing.expectEqualStrings("History", Mode.history.label());
    try testing.expectEqualStrings("Disk", Mode.disk.label());
    try testing.expectEqualStrings("Network", Mode.nm.label());
    try testing.expectEqualStrings("LLM", Mode.llm.label());
    try testing.expectEqualStrings("Whats", Mode.whats.label());
}

test "the history keeps the placeholder it was given, the rest replace it" {
    try testing.expectEqual(@as(?[:0]const u8, null), Mode.history.prompt());

    try testing.expectEqualStrings("Ask", Mode.llm.prompt().?);
    try testing.expectEqualStrings("Browse", Mode.disk.prompt().?);
    try testing.expectEqualStrings("Whats ...", Mode.whats.prompt().?);
    try testing.expectEqualStrings("Network", Mode.nm.prompt().?);
    try testing.expectEqualStrings("Focus", Mode.windows.prompt().?);
}
