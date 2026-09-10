const std = @import("std");
const toml = @import("toml");
const clipboard = @import("clipboard/clipboard.zig");
const preview = @import("extensions/preview.zig");
const save = @import("screenshot/save.zig");
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;

pub const default_lines: u16 = 8;
pub const default_reply_height: c_int = 300;
pub const default_max_tokens: i64 = 4096;
pub const default_picks: i64 = 5;
const log = std.log.scoped(.config);

pub const Config = struct {
    terminal: Terminal = .{},
    index: Index = .{},
    extensions: Extensions = .{},
    sources: Sources = .{},
    bookmarks: Bookmarks = .{},
    disk: Disk = .{},
    clipboard: Clipboard = .{},
    screenshot: Screenshot = .{},
    llm: Llm = .{},
    list: List = .{},
    recommendations: Recommendations = .{},
    keys: Keys = .{},

    pub const Keys = struct {
        manual: []const u8 = "Alt+F{n}",
        context: []const u8 = "Alt",
        windows: []const u8 = "Ctrl+t",
        search: []const u8 = "Ctrl+f",
        history: []const u8 = "Ctrl+h",
        llm: []const u8 = "Ctrl+l",
        reset: []const u8 = "Ctrl+n",
        disk: []const u8 = "Ctrl+d",
        whats: []const u8 = "Ctrl+w",
    };

    pub const Llm = struct {
        height: i64 = default_reply_height,
        gemini: []const Service = &.{},
        openai: []const Service = &.{},
        anthropic: []const Service = &.{},

        pub const Kind = enum { gemini, openai, anthropic };

        pub const Service = struct {
            name: []const u8 = "",
            model: []const u8 = "",
            base_url: []const u8 = "",
            api_key_env: []const u8 = "",
            max_tokens: i64 = default_max_tokens,
        };

        pub fn rows(self: Llm) c_int {
            const wanted = std.math.cast(c_int, self.height) orelse return default_reply_height;
            return @max(wanted, 1);
        }

        pub fn configured(self: Llm) usize {
            return self.gemini.len + self.openai.len + self.anthropic.len;
        }

        pub fn entries(self: Llm, kind: Kind) []const Service {
            return switch (kind) {
                .gemini => self.gemini,
                .openai => self.openai,
                .anthropic => self.anthropic,
            };
        }
    };

    pub const Screenshot = struct {
        enable: bool = true,
        directory: []const u8 = "",
        filename: []const u8 = save.default_filename,
        clipboard: []const u8 = "none",
        cursor: bool = false,

        pub const Destination = enum { none, image, path };

        pub fn destination(self: Screenshot) Destination {
            return std.meta.stringToEnum(Destination, self.clipboard) orelse {
                log.warn("[screenshot] clipboard = \"{s}\" is not none, image or path", .{
                    self.clipboard,
                });
                return .none;
            };
        }
    };

    pub const Clipboard = struct {
        enable: bool = true,
        max_items: i64 = defaults.max_items,
        max_age_days: i64 = defaults.max_age_days,
        max_size_bytes: i64 = @intCast(defaults.max_size_bytes),
        min_length: i64 = @intCast(defaults.min_length),

        const defaults: clipboard.Limits = .{};

        pub fn limits(self: Clipboard) clipboard.Limits {
            return .{
                .max_items = @max(self.max_items, 0),
                .max_age_days = @max(self.max_age_days, 0),
                .max_size_bytes = positive(self.max_size_bytes, defaults.max_size_bytes),
                .min_length = std.math.cast(usize, self.min_length) orelse defaults.min_length,
            };
        }

        fn positive(value: i64, fallback: usize) usize {
            if (value <= 0) return fallback;
            return std.math.cast(usize, value) orelse fallback;
        }
    };

    pub const List = struct {
        lines: i64 = default_lines,

        pub fn rows(self: List) u16 {
            const wanted = std.math.cast(u16, self.lines) orelse return default_lines;
            return @max(wanted, 1);
        }
    };

    pub const Recommendations = struct {
        max_per_subroutine: i64 = default_picks,

        pub fn limit(self: Recommendations) usize {
            if (self.max_per_subroutine >= 1) {
                return std.math.cast(usize, self.max_per_subroutine) orelse std.math.maxInt(usize);
            }

            log.warn("[recommendations] max_per_subroutine = {d} is not 1 or more, so {d} is used", .{
                self.max_per_subroutine,
                default_picks,
            });
            return @intCast(default_picks);
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

    pub const Disk = struct {
        locations: []const Location = &.{},

        pub const Location = struct {
            id: []const u8 = "",
            path: []const u8 = "",
            max_age_minutes: ?i64 = null,
            only: []const []const u8 = &.{},
            exclude: []const []const u8 = &.{},
            hidden: bool = false,
        };
    };

    pub const Extensions = struct {
        man: Entry = .{},
        preview: Preview = .{},

        pub const Entry = struct {
            enable: bool = true,
        };

        pub const Preview = struct {
            enable: bool = true,
            height: i64 = preview.default_height,
            max_bytes: i64 = preview.default_max_bytes,

            pub fn rows(self: Preview) c_int {
                const wanted = std.math.cast(c_int, self.height) orelse
                    return @intCast(preview.default_height);
                return @max(wanted, 1);
            }

            pub fn limit(self: Preview) usize {
                if (self.max_bytes <= 0) return @intCast(preview.default_max_bytes);
                return std.math.cast(usize, self.max_bytes) orelse
                    @intCast(preview.default_max_bytes);
            }
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
    gpa: Allocator,
    value: Config,
    parsed: ?toml.Parsed(Config) = null,
    changed_at: ?i64 = null,
    order: []const Config.Llm.Kind = &.{},
    path: ?[]const u8 = null,
    read: bool = false,

    pub fn deinit(self: Loaded) void {
        if (self.parsed) |parsed| parsed.deinit();
        self.gpa.free(self.order);
        if (self.path) |owned| self.gpa.free(owned);
    }

    pub fn describe(self: Loaded) []const u8 {
        const found = self.path orelse return "no config file could be located";
        return found;
    }
};

pub fn llmOrder(
    gpa: Allocator,
    source: []const u8,
) Allocator.Error![]const Config.Llm.Kind {
    var found: std.ArrayList(Config.Llm.Kind) = .empty;
    errdefer found.deinit(gpa);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, text, "[[")) continue;

        const head = text[2 .. std.mem.indexOfScalar(u8, text, ']') orelse continue];
        const name = std.mem.trim(u8, head, " \t");
        if (!std.mem.startsWith(u8, name, "llm.")) continue;

        const kind = std.meta.stringToEnum(Config.Llm.Kind, name["llm.".len..]) orelse continue;
        try found.append(gpa, kind);
    }

    return found.toOwnedSlice(gpa);
}

pub fn load(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map) Loaded {
    const bare: Loaded = .{ .gpa = gpa, .value = .{} };

    const found = path(gpa, environ) catch return bare;
    const file_path = found orelse return bare;

    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            log.debug("there is no {s}, so the built-in defaults are used", .{file_path});
            return .{ .gpa = gpa, .value = .{}, .path = file_path };
        },
        else => {
            log.warn("cannot read {s}: {t}", .{ file_path, err });
            return .{ .gpa = gpa, .value = .{}, .path = file_path };
        },
    };
    defer gpa.free(source);

    var loaded = parse(gpa, source, file_path);
    loaded.changed_at = writtenAt(io, file_path);
    loaded.order = llmOrder(gpa, source) catch &.{};
    loaded.path = file_path;
    loaded.read = true;
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
        return .{ .gpa = gpa, .value = .{} };
    };
    return .{ .gpa = gpa, .value = parsed.value, .parsed = parsed };
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
    return xdg.path(gpa, environ, .config, &.{ "sysdeck", "config.toml" });
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

test "the recommendations take five per subroutine unless set" {
    const bare = parse(std.testing.allocator, "", "test.toml");
    defer bare.deinit();
    try std.testing.expectEqual(@as(usize, 5), bare.value.recommendations.limit());

    const source =
        \\[recommendations]
        \\max_per_subroutine = 12
    ;
    const set = parse(std.testing.allocator, source, "test.toml");
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 12), set.value.recommendations.limit());
}

test "a recommendation count below one falls back to five" {
    for ([_][]const u8{
        "[recommendations]\nmax_per_subroutine = 0",
        "[recommendations]\nmax_per_subroutine = -3",
    }) |source| {
        const loaded = parse(std.testing.allocator, source, "test.toml");
        defer loaded.deinit();
        try std.testing.expectEqual(@as(usize, 5), loaded.value.recommendations.limit());
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

test "the preview pane defaults and can be set" {
    const bare = parse(std.testing.allocator, "", "test.toml");
    defer bare.deinit();

    const off_the_shelf = bare.value.extensions.preview;
    try std.testing.expect(off_the_shelf.enable);
    try std.testing.expectEqual(@as(c_int, 200), off_the_shelf.rows());
    try std.testing.expectEqual(@as(usize, 10 << 20), off_the_shelf.limit());

    const source =
        \\[extensions.preview]
        \\enable = false
        \\height = 320
        \\max_bytes = 2097152
    ;

    const set = parse(std.testing.allocator, source, "test.toml");
    defer set.deinit();

    const wanted = set.value.extensions.preview;
    try std.testing.expect(!wanted.enable);
    try std.testing.expectEqual(@as(c_int, 320), wanted.rows());
    try std.testing.expectEqual(@as(usize, 2 << 20), wanted.limit());
}

test "a nonsensical preview size falls back rather than breaking the window" {
    for ([_][]const u8{
        "[extensions.preview]\nheight = 0",
        "[extensions.preview]\nheight = -40",
        "[extensions.preview]\nmax_bytes = -1",
        "[extensions.preview]\nmax_bytes = 0",
    }) |source| {
        const loaded = parse(std.testing.allocator, source, "test.toml");
        defer loaded.deinit();

        const found = loaded.value.extensions.preview;
        try std.testing.expect(found.rows() >= 1);
        try std.testing.expect(found.limit() > 0);
    }
}

test "the clipboard limits default and can be set" {
    const bare = parse(std.testing.allocator, "", "test.toml");
    defer bare.deinit();

    const built = bare.value.clipboard.limits();
    try std.testing.expect(bare.value.clipboard.enable);
    try std.testing.expectEqual(@as(i64, 750), built.max_items);
    try std.testing.expectEqual(@as(i64, 30), built.max_age_days);
    try std.testing.expectEqual(@as(usize, 5 << 20), built.max_size_bytes);
    try std.testing.expectEqual(@as(usize, 0), built.min_length);

    const source =
        \\[clipboard]
        \\enable = false
        \\max_items = 200
        \\max_age_days = 7
        \\max_size_bytes = 1048576
        \\min_length = 3
    ;

    const set = parse(std.testing.allocator, source, "test.toml");
    defer set.deinit();

    const wanted = set.value.clipboard.limits();
    try std.testing.expect(!set.value.clipboard.enable);
    try std.testing.expectEqual(@as(i64, 200), wanted.max_items);
    try std.testing.expectEqual(@as(i64, 7), wanted.max_age_days);
    try std.testing.expectEqual(@as(usize, 1 << 20), wanted.max_size_bytes);
    try std.testing.expectEqual(@as(usize, 3), wanted.min_length);
}

test "a zero turns a clipboard trim off, and a bad size falls back" {
    const source =
        \\[clipboard]
        \\max_items = 0
        \\max_age_days = -4
        \\max_size_bytes = -1
        \\min_length = -9
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const built = loaded.value.clipboard.limits();
    try std.testing.expectEqual(@as(i64, 0), built.max_items);
    try std.testing.expectEqual(@as(i64, 0), built.max_age_days);
    try std.testing.expectEqual(@as(usize, 5 << 20), built.max_size_bytes);
    try std.testing.expectEqual(@as(usize, 0), built.min_length);
}

test "the key bindings default and can be set" {
    const bare = parse(std.testing.allocator, "", "test.toml");
    defer bare.deinit();
    try std.testing.expectEqualStrings("Alt+F{n}", bare.value.keys.manual);
    try std.testing.expectEqualStrings("Alt", bare.value.keys.context);
    try std.testing.expectEqualStrings("Ctrl+t", bare.value.keys.windows);
    try std.testing.expectEqualStrings("Ctrl+f", bare.value.keys.search);
    try std.testing.expectEqualStrings("Ctrl+h", bare.value.keys.history);
    try std.testing.expectEqualStrings("Ctrl+w", bare.value.keys.whats);

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

test "no disk section leaves no locations" {
    const loaded = parse(std.testing.allocator, "", "test.toml");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.value.disk.locations.len);
    try std.testing.expectEqualStrings("Ctrl+d", loaded.value.keys.disk);
}

test "the disk locations are read as inline tables" {
    const source =
        \\[index]
        \\max_age_minutes = 30
        \\
        \\[disk]
        \\locations = [
        \\  { id = "documents", path = "~/documents", max_age_minutes = 20 },
        \\  { id = "shots", path = "$XDG_PICTURES_DIR/screenshots", only = ["image/*"] },
        \\]
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const locations = loaded.value.disk.locations;
    try std.testing.expectEqual(@as(usize, 2), locations.len);

    try std.testing.expectEqualStrings("documents", locations[0].id);
    try std.testing.expectEqualStrings("~/documents", locations[0].path);
    try std.testing.expectEqual(@as(i64, 20), loaded.value.index.age(locations[0].max_age_minutes));
    try std.testing.expectEqual(@as(usize, 0), locations[0].only.len);
    try std.testing.expectEqual(@as(usize, 0), locations[0].exclude.len);
    try std.testing.expect(!locations[0].hidden);

    try std.testing.expectEqualStrings("$XDG_PICTURES_DIR/screenshots", locations[1].path);
    try std.testing.expectEqual(@as(usize, 1), locations[1].only.len);
    try std.testing.expectEqualStrings("image/*", locations[1].only[0]);
    try std.testing.expectEqual(@as(i64, 30), loaded.value.index.age(locations[1].max_age_minutes));
}

test "a disk location is read as a table of its own too" {
    const source =
        \\[[disk.locations]]
        \\id = "code"
        \\path = "~/projects"
        \\exclude = ["node_modules", "*.o"]
        \\hidden = true
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const locations = loaded.value.disk.locations;
    try std.testing.expectEqual(@as(usize, 1), locations.len);
    try std.testing.expectEqualStrings("code", locations[0].id);
    try std.testing.expectEqual(@as(usize, 2), locations[0].exclude.len);
    try std.testing.expectEqualStrings("node_modules", locations[0].exclude[0]);
    try std.testing.expectEqualStrings("*.o", locations[0].exclude[1]);
    try std.testing.expect(locations[0].hidden);
    try std.testing.expectEqual(@as(i64, 60), loaded.value.index.age(locations[0].max_age_minutes));
}

test "a location without an id or a path reads as empty rather than breaking the file" {
    const source =
        \\[list]
        \\lines = 12
        \\
        \\[disk]
        \\locations = [{ path = "~/documents" }, { id = "downloads" }]
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u16, 12), loaded.value.list.rows());
    try std.testing.expectEqual(@as(usize, 2), loaded.value.disk.locations.len);
    try std.testing.expectEqualStrings("", loaded.value.disk.locations[0].id);
    try std.testing.expectEqualStrings("", loaded.value.disk.locations[1].path);
}

test "a broken file falls back to the defaults" {
    const loaded = parse(std.testing.allocator, "[terminal\ncommand =", "test.toml");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.value.terminal.command.len);
}

test "the screenshot section defaults to saving only" {
    const bare = parse(std.testing.allocator, "", "test.toml");
    defer bare.deinit();

    const found = bare.value.screenshot;
    try std.testing.expect(found.enable);
    try std.testing.expect(!found.cursor);
    try std.testing.expectEqualStrings("", found.directory);
    try std.testing.expectEqualStrings("screenshot_%Y-%m-%d-%H%M%S.png", found.filename);
    try std.testing.expectEqual(Config.Screenshot.Destination.none, found.destination());
}

test "the screenshot section is read" {
    const source =
        \\[screenshot]
        \\enable = false
        \\directory = "~/cloud/photos/screenshots"
        \\filename = "shot-%Y%m%d.jpg"
        \\clipboard = "image"
        \\cursor = true
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const found = loaded.value.screenshot;
    try std.testing.expect(!found.enable);
    try std.testing.expect(found.cursor);
    try std.testing.expectEqualStrings("~/cloud/photos/screenshots", found.directory);
    try std.testing.expectEqualStrings("shot-%Y%m%d.jpg", found.filename);
    try std.testing.expectEqual(Config.Screenshot.Destination.image, found.destination());
}

test "the clipboard destination takes the path or nothing" {
    const wanted = parse(std.testing.allocator, "[screenshot]\nclipboard = \"path\"", "test.toml");
    defer wanted.deinit();
    try std.testing.expectEqual(
        Config.Screenshot.Destination.path,
        wanted.value.screenshot.destination(),
    );

    const wrong = parse(std.testing.allocator, "[screenshot]\nclipboard = \"both\"", "test.toml");
    defer wrong.deinit();
    try std.testing.expectEqual(
        Config.Screenshot.Destination.none,
        wrong.value.screenshot.destination(),
    );
}

test "the llm table order is read from the file" {
    const source =
        \\[llm]
        \\
        \\[[llm.openai]]
        \\name = "local"
        \\
        \\[[llm.anthropic]]
        \\name = "sonnet"
        \\
        \\  [[llm.openai]]
        \\name = "cloud"
        \\
        \\[[llm.gemini]]
        \\name = "flash"
    ;

    const order = try llmOrder(std.testing.allocator, source);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 4), order.len);
    try std.testing.expectEqual(Config.Llm.Kind.openai, order[0]);
    try std.testing.expectEqual(Config.Llm.Kind.anthropic, order[1]);
    try std.testing.expectEqual(Config.Llm.Kind.openai, order[2]);
    try std.testing.expectEqual(Config.Llm.Kind.gemini, order[3]);
}

test "a commented or unrelated table is not counted as an llm entry" {
    const source =
        \\# [[llm.gemini]]
        \\[[bookmarks.markdown]]
        \\[[llm.nonsense]]
        \\[[llm.openai]]
        \\name = "local"
    ;

    const order = try llmOrder(std.testing.allocator, source);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 1), order.len);
    try std.testing.expectEqual(Config.Llm.Kind.openai, order[0]);
}

test "a file with no llm tables has no order" {
    const order = try llmOrder(std.testing.allocator, "[list]\nlines = 8\n");
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 0), order.len);
}
