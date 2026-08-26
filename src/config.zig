const std = @import("std");
const toml = @import("toml");

const Allocator = std.mem.Allocator;

pub const default_lines: u16 = 8;
const log = std.log.scoped(.config);

pub const Config = struct {
    terminal: Terminal = .{},
    index: Index = .{},
    extensions: Extensions = .{},
    sources: Sources = .{},
    bookmarks: Bookmarks = .{},
    list: List = .{},
    keys: Keys = .{},

    pub const Keys = struct {
        manual: []const u8 = "Alt+F{n}",
        context: []const u8 = "Alt",
        windows: []const u8 = "Ctrl+t",
        search: []const u8 = "Ctrl+f",
    };

    pub const List = struct {
        lines: i64 = default_lines,

        pub fn rows(self: List) u16 {
            const wanted = std.math.cast(u16, self.lines) orelse return default_lines;
            return @max(wanted, 1);
        }
    };

    pub const Sources = struct {
        sway: Source = .{},

        pub const Source = struct {
            enable: ?bool = null,
        };
    };

    pub const Bookmarks = struct {
        markdown: Adapter = .{},
        chromium: Adapter = .{},
        firefox: Adapter = .{},

        pub const Adapter = struct {
            max_age_minutes: ?i64 = null,
            files: []const []const u8 = &.{},
        };
    };

    pub const Extensions = struct {
        man: Entry = .{},

        pub const Entry = struct {
            enable: bool = true,
        };
    };

    pub const Terminal = struct {
        command: []const []const u8 = &.{},
    };

    pub const Index = struct {
        max_age_minutes: i64 = 60,
        apps: Source = .{},
        bins: Source = .{},

        pub const Source = struct {
            max_age_minutes: ?i64 = null,
        };

        pub fn maxAge(self: Index, source: Source) i64 {
            return self.age(source.max_age_minutes);
        }

        pub fn age(self: Index, override: ?i64) i64 {
            return override orelse self.max_age_minutes;
        }
    };
};

pub const Loaded = struct {
    value: Config,
    parsed: ?toml.Parsed(Config) = null,
    changed_at: ?i64 = null,

    pub fn deinit(self: Loaded) void {
        if (self.parsed) |parsed| parsed.deinit();
    }
};

pub fn load(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map) Loaded {
    const found = path(gpa, environ) catch return .{ .value = .{} };
    const file_path = found orelse return .{ .value = .{} };
    defer gpa.free(file_path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{ .value = .{} },
        else => {
            log.warn("cannot read {s}: {t}", .{ file_path, err });
            return .{ .value = .{} };
        },
    };
    defer gpa.free(source);

    var loaded = parse(gpa, source, file_path);
    loaded.changed_at = writtenAt(io, file_path);
    return loaded;
}

fn writtenAt(io: std.Io, file_path: []const u8) ?i64 {
    const info = std.Io.Dir.cwd().statFile(io, file_path, .{}) catch return null;
    return info.mtime.toSeconds();
}

fn parse(gpa: Allocator, source: []const u8, file_path: []const u8) Loaded {
    var parser: toml.Parser(Config) = .init(gpa);
    defer parser.deinit();

    const parsed = parser.parseString(source) catch |err| {
        report(&parser, file_path, err);
        return .{ .value = .{} };
    };
    return .{ .value = parsed.value, .parsed = parsed };
}

fn report(parser: *const toml.Parser(Config), file_path: []const u8, err: anyerror) void {
    const info = parser.error_info orelse {
        log.warn("cannot parse {s}: {t}, using the built-in defaults", .{ file_path, err });
        return;
    };
    switch (info) {
        .parse => |position| log.warn(
            "cannot parse {s} at line {d} column {d}: {t}, using the built-in defaults",
            .{ file_path, position.line, position.pos, err },
        ),
        .struct_mapping => |field_path| log.warn(
            "cannot read {f} in {s}: {t}, using the built-in defaults",
            .{ FieldPath{ .parts = field_path }, file_path, err },
        ),
    }
}

const FieldPath = struct {
    parts: []const []const u8,

    pub fn format(self: FieldPath, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.parts, 0..) |part, index| {
            if (index > 0) try writer.writeByte('.');
            try writer.writeAll(part);
        }
    }
};

fn path(gpa: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    if (environ.get("XDG_CONFIG_HOME")) |dir| {
        if (dir.len > 0) return try std.fs.path.join(gpa, &.{ dir, "sysdeck", "config.toml" });
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) return try std.fs.path.join(gpa, &.{ home, ".config", "sysdeck", "config.toml" });
    }
    return null;
}

test "an empty file leaves the defaults alone" {
    const loaded = parse(std.testing.allocator, "", "test.toml");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.value.terminal.command.len);
}

test "a configured terminal command is read" {
    const source =
        \\[terminal]
        \\command = ["ghostty", "-e"]
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 2), loaded.value.terminal.command.len);
    try std.testing.expectEqualStrings("ghostty", loaded.value.terminal.command[0]);
    try std.testing.expectEqualStrings("-e", loaded.value.terminal.command[1]);
}

test "the index age defaults and can be overridden per subroutine" {
    const source =
        \\[index]
        \\max_age_minutes = 30
        \\
        \\[index.apps]
        \\max_age_minutes = 240
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const index = loaded.value.index;
    try std.testing.expectEqual(@as(i64, 30), index.max_age_minutes);
    try std.testing.expectEqual(@as(i64, 240), index.maxAge(index.apps));
    try std.testing.expectEqual(@as(i64, 30), index.maxAge(index.bins));
}

test "an absent index section leaves the built-in age" {
    const loaded = parse(std.testing.allocator, "", "test.toml");
    defer loaded.deinit();

    const index = loaded.value.index;
    try std.testing.expectEqual(@as(i64, 60), index.max_age_minutes);
    try std.testing.expectEqual(@as(i64, 60), index.maxAge(index.apps));
}

test "extensions are on unless turned off" {
    const on = parse(std.testing.allocator, "", "test.toml");
    defer on.deinit();
    try std.testing.expect(on.value.extensions.man.enable);

    const source =
        \\[extensions.man]
        \\enable = false
    ;
    const off = parse(std.testing.allocator, source, "test.toml");
    defer off.deinit();
    try std.testing.expect(!off.value.extensions.man.enable);
}

test "the list size defaults to eight and can be set" {
    const bare = parse(std.testing.allocator, "", "test.toml");
    defer bare.deinit();
    try std.testing.expectEqual(@as(u16, 8), bare.value.list.rows());

    const source =
        \\[list]
        \\lines = 20
    ;
    const set = parse(std.testing.allocator, source, "test.toml");
    defer set.deinit();
    try std.testing.expectEqual(@as(u16, 20), set.value.list.rows());
}

test "a nonsensical list size falls back rather than breaking the window" {
    for ([_][]const u8{ "[list]\nlines = 0", "[list]\nlines = -4", "[list]\nlines = 999999" }) |source| {
        const loaded = parse(std.testing.allocator, source, "test.toml");
        defer loaded.deinit();
        try std.testing.expect(loaded.value.list.rows() >= 1);
    }
}

test "a source is off, on or left to the environment" {
    const bare = parse(std.testing.allocator, "", "test.toml");
    defer bare.deinit();
    try std.testing.expectEqual(@as(?bool, null), bare.value.sources.sway.enable);

    const on = parse(std.testing.allocator, "[sources.sway]\nenable = true", "test.toml");
    defer on.deinit();
    try std.testing.expectEqual(@as(?bool, true), on.value.sources.sway.enable);

    const off = parse(std.testing.allocator, "[sources.sway]\nenable = false", "test.toml");
    defer off.deinit();
    try std.testing.expectEqual(@as(?bool, false), off.value.sources.sway.enable);
}

test "the key bindings default and can be set" {
    const bare = parse(std.testing.allocator, "", "test.toml");
    defer bare.deinit();
    try std.testing.expectEqualStrings("Alt+F{n}", bare.value.keys.manual);
    try std.testing.expectEqualStrings("Alt", bare.value.keys.context);
    try std.testing.expectEqualStrings("Ctrl+t", bare.value.keys.windows);
    try std.testing.expectEqualStrings("Ctrl+f", bare.value.keys.search);

    const source =
        \\[keys]
        \\manual = "Ctrl+F{n}"
        \\context = "Super"
    ;

    const set = parse(std.testing.allocator, source, "test.toml");
    defer set.deinit();
    try std.testing.expectEqualStrings("Ctrl+F{n}", set.value.keys.manual);
    try std.testing.expectEqualStrings("Super", set.value.keys.context);
    try std.testing.expectEqualStrings("Ctrl+f", set.value.keys.search);
}

test "an adapter starts with no files at all" {
    const bare = parse(std.testing.allocator, "", "test.toml");
    defer bare.deinit();

    const bookmarks = bare.value.bookmarks;
    try std.testing.expectEqual(@as(usize, 0), bookmarks.markdown.files.len);
    try std.testing.expectEqual(@as(usize, 0), bookmarks.chromium.files.len);
    try std.testing.expectEqual(@as(usize, 0), bookmarks.firefox.files.len);
    try std.testing.expectEqual(
        @as(i64, 60),
        bare.value.index.age(bookmarks.markdown.max_age_minutes),
    );
}

test "the markdown adapter reads its files and its own age" {
    const source =
        \\[index]
        \\max_age_minutes = 30
        \\
        \\[bookmarks.markdown]
        \\max_age_minutes = 180
        \\files = ["~/notes/links.md", "/srv/wiki/bookmarks.md"]
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const markdown = loaded.value.bookmarks.markdown;
    try std.testing.expectEqual(@as(usize, 2), markdown.files.len);
    try std.testing.expectEqualStrings("~/notes/links.md", markdown.files[0]);
    try std.testing.expectEqualStrings("/srv/wiki/bookmarks.md", markdown.files[1]);
    try std.testing.expectEqual(@as(i64, 180), loaded.value.index.age(markdown.max_age_minutes));
}

test "the chromium adapter reads its files and its own age" {
    const source =
        \\[bookmarks.chromium]
        \\max_age_minutes = 15
        \\files = ["~/.config/chromium/Default/Bookmarks"]
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const set = loaded.value.bookmarks.chromium;
    try std.testing.expectEqual(@as(usize, 1), set.files.len);
    try std.testing.expectEqualStrings("~/.config/chromium/Default/Bookmarks", set.files[0]);
    try std.testing.expectEqual(@as(i64, 15), loaded.value.index.age(set.max_age_minutes));
    try std.testing.expectEqual(@as(usize, 0), loaded.value.bookmarks.markdown.files.len);
}

test "a setting the version no longer knows is left alone" {
    const source =
        \\[bookmarks.firefox]
        \\enable = false
        \\files = ["~/.mozilla/firefox/abc.default-release/places.sqlite"]
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const set = loaded.value.bookmarks.firefox;
    try std.testing.expectEqual(@as(usize, 1), set.files.len);
    try std.testing.expectEqualStrings(
        "~/.mozilla/firefox/abc.default-release/places.sqlite",
        set.files[0],
    );
    try std.testing.expectEqual(@as(i64, 60), loaded.value.index.age(set.max_age_minutes));
}

test "a broken file falls back to the defaults" {
    const loaded = parse(std.testing.allocator, "[terminal\ncommand =", "test.toml");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.value.terminal.command.len);
}
