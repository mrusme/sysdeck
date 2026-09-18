const std = @import("std");
const toml = @import("toml");
const clipboard = @import("clipboard/clipboard.zig");
const modes = @import("modes.zig");
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
        network: []const u8 = "Ctrl+k",
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
        apps: Indexed = .{},
        bins: Indexed = .{},
        bookmarks: Bookmarks = .{},
        clipboard: Clipboard = .{},
        disk: Disk = .{},
        llm: Llm = .{},
        nm: Source = .{},
        processes: Source = .{},
        screenshot: Screenshot = .{},
        snippets: Snippets = .{},
        ssh: Source = .{},
        sway: Source = .{},
        whats: Source = .{},

        pub fn on(enable: ?bool) bool {
            return enable orelse true;
        }

        pub fn enableOf(self: Sources, name: []const u8) ?bool {
            inline for (std.meta.fields(Sources)) |field| {
                if (std.mem.eql(u8, field.name, name)) return @field(self, field.name).enable;
            }
            return null;
        }

        pub const Source = struct {
            enable: ?bool = null,
        };

        pub const Indexed = struct {
            enable: ?bool = null,
            max_age_minutes: ?i64 = null,
        };

        pub const Bookmarks = struct {
            enable: ?bool = null,
            markdown: Adapter = .{},
            chromium: Adapter = .{},
            firefox: Adapter = .{},

            pub const Adapter = struct {
                max_age_minutes: ?i64 = null,
                files: []const []const u8 = &.{},
            };
        };

        pub const Clipboard = struct {
            enable: ?bool = null,
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

        pub const Disk = struct {
            enable: ?bool = null,
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

        pub const Llm = struct {
            enable: ?bool = null,
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
            enable: ?bool = null,
            directory: []const u8 = "",
            filename: []const u8 = save.default_filename,
            clipboard: []const u8 = "none",
            cursor: bool = false,

            pub const Destination = enum { none, image, path };

            pub fn destination(self: Screenshot) Destination {
                return std.meta.stringToEnum(Destination, self.clipboard) orelse {
                    log.warn(
                        "[sources.screenshot] clipboard = \"{s}\" is not none, image or path",
                        .{self.clipboard},
                    );
                    return .none;
                };
            }
        };

        pub const Snippets = struct {
            enable: ?bool = null,
            emoji: bool = true,
            entries: []const Snippet = &.{},

            pub const Snippet = struct {
                snippet: []const u8 = "",
                keywords: []const []const u8 = &.{},
            };
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
    order: []const Config.Sources.Llm.Kind = &.{},
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

const llm_prefix = "sources.llm.";

pub fn llmOrder(
    gpa: Allocator,
    source: []const u8,
) Allocator.Error![]const Config.Sources.Llm.Kind {
    const Kind = Config.Sources.Llm.Kind;

    var found: std.ArrayList(Kind) = .empty;
    errdefer found.deinit(gpa);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, text, "[[")) continue;

        const head = text[2 .. std.mem.indexOfScalar(u8, text, ']') orelse continue];
        const name = std.mem.trim(u8, head, " \t");
        if (!std.mem.startsWith(u8, name, llm_prefix)) continue;

        const kind = std.meta.stringToEnum(Kind, name[llm_prefix.len..]) orelse continue;
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

const testing = std.testing;

test "an empty file leaves the defaults alone" {
    const loaded = parse(testing.allocator, "", "test.toml");
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 0), loaded.value.terminal.command.len);
}

test "a configured terminal command is read" {
    const source =
        \\[terminal]
        \\command = ["ghostty", "-e"]
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 2), loaded.value.terminal.command.len);
    try testing.expectEqualStrings("ghostty", loaded.value.terminal.command[0]);
    try testing.expectEqualStrings("-e", loaded.value.terminal.command[1]);
}

test "the index age defaults and each indexed source can override it" {
    const source =
        \\[index]
        \\max_age_minutes = 30
        \\
        \\[sources.apps]
        \\max_age_minutes = 240
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const index = loaded.value.index;
    const sources = loaded.value.sources;
    try testing.expectEqual(@as(i64, 30), index.max_age_minutes);
    try testing.expectEqual(@as(i64, 240), index.age(sources.apps.max_age_minutes));
    try testing.expectEqual(@as(i64, 30), index.age(sources.bins.max_age_minutes));
}

test "an absent index section leaves the built-in age" {
    const loaded = parse(testing.allocator, "", "test.toml");
    defer loaded.deinit();

    const index = loaded.value.index;
    try testing.expectEqual(@as(i64, 60), index.max_age_minutes);
    try testing.expectEqual(@as(i64, 60), index.age(loaded.value.sources.apps.max_age_minutes));
}

test "every source is unset unless the file turns it on or off" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);

    inline for (std.meta.fields(Config.Sources)) |field| {
        try testing.expectEqual(@as(?bool, null), @field(bare.value.sources, field.name).enable);
        try source.print(testing.allocator, "[sources.{s}]\nenable = false\n\n", .{field.name});
    }

    const off = parse(testing.allocator, source.items, "test.toml");
    defer off.deinit();

    inline for (std.meta.fields(Config.Sources)) |field| {
        try testing.expectEqual(@as(?bool, false), @field(off.value.sources, field.name).enable);
    }

    const on = parse(testing.allocator, "[sources.whats]\nenable = true", "test.toml");
    defer on.deinit();
    try testing.expectEqual(@as(?bool, true), on.value.sources.whats.enable);
}

test "a source is on unless it is turned off" {
    try testing.expect(Config.Sources.on(null));
    try testing.expect(Config.Sources.on(true));
    try testing.expect(!Config.Sources.on(false));
}

test "extensions are on unless turned off" {
    const on = parse(testing.allocator, "", "test.toml");
    defer on.deinit();
    try testing.expect(on.value.extensions.man.enable);

    const source =
        \\[extensions.man]
        \\enable = false
    ;
    const off = parse(testing.allocator, source, "test.toml");
    defer off.deinit();
    try testing.expect(!off.value.extensions.man.enable);
}

test "the list size defaults to eight and can be set" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();
    try testing.expectEqual(@as(u16, 8), bare.value.list.rows());

    const source =
        \\[list]
        \\lines = 20
    ;
    const set = parse(testing.allocator, source, "test.toml");
    defer set.deinit();
    try testing.expectEqual(@as(u16, 20), set.value.list.rows());
}

test "a nonsensical list size falls back rather than breaking the window" {
    for ([_][]const u8{ "[list]\nlines = 0", "[list]\nlines = -4", "[list]\nlines = 999999" }) |source| {
        const loaded = parse(testing.allocator, source, "test.toml");
        defer loaded.deinit();
        try testing.expect(loaded.value.list.rows() >= 1);
    }
}

test "the recommendations take five per subroutine unless set" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();
    try testing.expectEqual(@as(usize, 5), bare.value.recommendations.limit());

    const source =
        \\[recommendations]
        \\max_per_subroutine = 12
    ;
    const set = parse(testing.allocator, source, "test.toml");
    defer set.deinit();
    try testing.expectEqual(@as(usize, 12), set.value.recommendations.limit());
}

test "a recommendation count below one falls back to five" {
    for ([_][]const u8{
        "[recommendations]\nmax_per_subroutine = 0",
        "[recommendations]\nmax_per_subroutine = -3",
    }) |source| {
        const loaded = parse(testing.allocator, source, "test.toml");
        defer loaded.deinit();
        try testing.expectEqual(@as(usize, 5), loaded.value.recommendations.limit());
    }
}

test "the preview pane defaults and can be set" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();

    const off_the_shelf = bare.value.extensions.preview;
    try testing.expect(off_the_shelf.enable);
    try testing.expectEqual(@as(c_int, 200), off_the_shelf.rows());
    try testing.expectEqual(@as(usize, 10 << 20), off_the_shelf.limit());

    const source =
        \\[extensions.preview]
        \\enable = false
        \\height = 320
        \\max_bytes = 2097152
    ;

    const set = parse(testing.allocator, source, "test.toml");
    defer set.deinit();

    const wanted = set.value.extensions.preview;
    try testing.expect(!wanted.enable);
    try testing.expectEqual(@as(c_int, 320), wanted.rows());
    try testing.expectEqual(@as(usize, 2 << 20), wanted.limit());
}

test "a nonsensical preview size falls back rather than breaking the window" {
    for ([_][]const u8{
        "[extensions.preview]\nheight = 0",
        "[extensions.preview]\nheight = -40",
        "[extensions.preview]\nmax_bytes = -1",
        "[extensions.preview]\nmax_bytes = 0",
    }) |source| {
        const loaded = parse(testing.allocator, source, "test.toml");
        defer loaded.deinit();

        const found = loaded.value.extensions.preview;
        try testing.expect(found.rows() >= 1);
        try testing.expect(found.limit() > 0);
    }
}

test "the clipboard limits default and can be set" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();

    const built = bare.value.sources.clipboard.limits();
    try testing.expectEqual(@as(i64, 750), built.max_items);
    try testing.expectEqual(@as(i64, 30), built.max_age_days);
    try testing.expectEqual(@as(usize, 5 << 20), built.max_size_bytes);
    try testing.expectEqual(@as(usize, 0), built.min_length);

    const source =
        \\[sources.clipboard]
        \\max_items = 200
        \\max_age_days = 7
        \\max_size_bytes = 1048576
        \\min_length = 3
    ;

    const set = parse(testing.allocator, source, "test.toml");
    defer set.deinit();

    const wanted = set.value.sources.clipboard.limits();
    try testing.expectEqual(@as(i64, 200), wanted.max_items);
    try testing.expectEqual(@as(i64, 7), wanted.max_age_days);
    try testing.expectEqual(@as(usize, 1 << 20), wanted.max_size_bytes);
    try testing.expectEqual(@as(usize, 3), wanted.min_length);
}

test "a zero turns a clipboard trim off, and a bad size falls back" {
    const source =
        \\[sources.clipboard]
        \\max_items = 0
        \\max_age_days = -4
        \\max_size_bytes = -1
        \\min_length = -9
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const built = loaded.value.sources.clipboard.limits();
    try testing.expectEqual(@as(i64, 0), built.max_items);
    try testing.expectEqual(@as(i64, 0), built.max_age_days);
    try testing.expectEqual(@as(usize, 5 << 20), built.max_size_bytes);
    try testing.expectEqual(@as(usize, 0), built.min_length);
}

test "a section under its old name is not read" {
    const source =
        \\[clipboard]
        \\max_items = 7
        \\
        \\[[snippets]]
        \\snippet = "old"
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    try testing.expectEqual(@as(i64, 750), loaded.value.sources.clipboard.limits().max_items);
    try testing.expectEqual(@as(usize, 0), loaded.value.sources.snippets.entries.len);
}

test "the key bindings default and can be set" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();
    try testing.expectEqualStrings("Alt+F{n}", bare.value.keys.manual);
    try testing.expectEqualStrings("Alt", bare.value.keys.context);
    try testing.expectEqualStrings("Ctrl+t", bare.value.keys.windows);
    try testing.expectEqualStrings("Ctrl+f", bare.value.keys.search);
    try testing.expectEqualStrings("Ctrl+h", bare.value.keys.history);
    try testing.expectEqualStrings("Ctrl+w", bare.value.keys.whats);
    try testing.expectEqualStrings("Ctrl+k", bare.value.keys.network);

    const source =
        \\[keys]
        \\manual = "Ctrl+F{n}"
        \\context = "Super"
    ;

    const set = parse(testing.allocator, source, "test.toml");
    defer set.deinit();
    try testing.expectEqualStrings("Ctrl+F{n}", set.value.keys.manual);
    try testing.expectEqualStrings("Super", set.value.keys.context);
    try testing.expectEqualStrings("Ctrl+f", set.value.keys.search);
}

test "an adapter starts with no files at all" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();

    const bookmarks = bare.value.sources.bookmarks;
    try testing.expectEqual(@as(usize, 0), bookmarks.markdown.files.len);
    try testing.expectEqual(@as(usize, 0), bookmarks.chromium.files.len);
    try testing.expectEqual(@as(usize, 0), bookmarks.firefox.files.len);
    try testing.expectEqual(
        @as(i64, 60),
        bare.value.index.age(bookmarks.markdown.max_age_minutes),
    );
}

test "the markdown adapter reads its files and its own age" {
    const source =
        \\[index]
        \\max_age_minutes = 30
        \\
        \\[sources.bookmarks]
        \\enable = true
        \\
        \\[sources.bookmarks.markdown]
        \\max_age_minutes = 180
        \\files = ["~/notes/links.md", "/srv/wiki/bookmarks.md"]
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const bookmarks = loaded.value.sources.bookmarks;
    try testing.expectEqual(@as(?bool, true), bookmarks.enable);
    try testing.expectEqual(@as(usize, 2), bookmarks.markdown.files.len);
    try testing.expectEqualStrings("~/notes/links.md", bookmarks.markdown.files[0]);
    try testing.expectEqualStrings("/srv/wiki/bookmarks.md", bookmarks.markdown.files[1]);
    try testing.expectEqual(
        @as(i64, 180),
        loaded.value.index.age(bookmarks.markdown.max_age_minutes),
    );
}

test "the chromium adapter reads its files and its own age" {
    const source =
        \\[sources.bookmarks.chromium]
        \\max_age_minutes = 15
        \\files = ["~/.config/chromium/Default/Bookmarks"]
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const set = loaded.value.sources.bookmarks.chromium;
    try testing.expectEqual(@as(usize, 1), set.files.len);
    try testing.expectEqualStrings("~/.config/chromium/Default/Bookmarks", set.files[0]);
    try testing.expectEqual(@as(i64, 15), loaded.value.index.age(set.max_age_minutes));
    try testing.expectEqual(@as(usize, 0), loaded.value.sources.bookmarks.markdown.files.len);
}

test "a setting the version no longer knows is left alone" {
    const source =
        \\[sources.bookmarks.firefox]
        \\enable = false
        \\files = ["~/.mozilla/firefox/abc.default-release/places.sqlite"]
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const set = loaded.value.sources.bookmarks.firefox;
    try testing.expectEqual(@as(usize, 1), set.files.len);
    try testing.expectEqualStrings(
        "~/.mozilla/firefox/abc.default-release/places.sqlite",
        set.files[0],
    );
    try testing.expectEqual(@as(i64, 60), loaded.value.index.age(set.max_age_minutes));
}

test "no disk section leaves no locations" {
    const loaded = parse(testing.allocator, "", "test.toml");
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 0), loaded.value.sources.disk.locations.len);
    try testing.expectEqualStrings("Ctrl+d", loaded.value.keys.disk);
}

test "the disk locations are read as inline tables" {
    const source =
        \\[index]
        \\max_age_minutes = 30
        \\
        \\[sources.disk]
        \\locations = [
        \\  { id = "documents", path = "~/documents", max_age_minutes = 20 },
        \\  { id = "shots", path = "$XDG_PICTURES_DIR/screenshots", only = ["image/*"] },
        \\]
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const index = loaded.value.index;
    const locations = loaded.value.sources.disk.locations;
    try testing.expectEqual(@as(usize, 2), locations.len);

    try testing.expectEqualStrings("documents", locations[0].id);
    try testing.expectEqualStrings("~/documents", locations[0].path);
    try testing.expectEqual(@as(i64, 20), index.age(locations[0].max_age_minutes));
    try testing.expectEqual(@as(usize, 0), locations[0].only.len);
    try testing.expectEqual(@as(usize, 0), locations[0].exclude.len);
    try testing.expect(!locations[0].hidden);

    try testing.expectEqualStrings("$XDG_PICTURES_DIR/screenshots", locations[1].path);
    try testing.expectEqual(@as(usize, 1), locations[1].only.len);
    try testing.expectEqualStrings("image/*", locations[1].only[0]);
    try testing.expectEqual(@as(i64, 30), index.age(locations[1].max_age_minutes));
}

test "a disk location is read as a table of its own too" {
    const source =
        \\[[sources.disk.locations]]
        \\id = "code"
        \\path = "~/projects"
        \\exclude = ["node_modules", "*.o"]
        \\hidden = true
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const locations = loaded.value.sources.disk.locations;
    try testing.expectEqual(@as(usize, 1), locations.len);
    try testing.expectEqualStrings("code", locations[0].id);
    try testing.expectEqual(@as(usize, 2), locations[0].exclude.len);
    try testing.expectEqualStrings("node_modules", locations[0].exclude[0]);
    try testing.expectEqualStrings("*.o", locations[0].exclude[1]);
    try testing.expect(locations[0].hidden);
    try testing.expectEqual(@as(i64, 60), loaded.value.index.age(locations[0].max_age_minutes));
}

test "a location without an id or a path reads as empty rather than breaking the file" {
    const source =
        \\[list]
        \\lines = 12
        \\
        \\[sources.disk]
        \\locations = [{ path = "~/documents" }, { id = "downloads" }]
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const locations = loaded.value.sources.disk.locations;
    try testing.expectEqual(@as(u16, 12), loaded.value.list.rows());
    try testing.expectEqual(@as(usize, 2), locations.len);
    try testing.expectEqualStrings("", locations[0].id);
    try testing.expectEqualStrings("", locations[1].path);
}

test "a broken file falls back to the defaults" {
    const loaded = parse(testing.allocator, "[terminal\ncommand =", "test.toml");
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 0), loaded.value.terminal.command.len);
}

test "the screenshot section defaults to saving only" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();

    const found = bare.value.sources.screenshot;
    try testing.expect(!found.cursor);
    try testing.expectEqualStrings("", found.directory);
    try testing.expectEqualStrings("screenshot_%Y-%m-%d-%H%M%S.png", found.filename);
    try testing.expectEqual(Config.Sources.Screenshot.Destination.none, found.destination());
}

test "the screenshot section is read" {
    const source =
        \\[sources.screenshot]
        \\enable = false
        \\directory = "~/cloud/photos/screenshots"
        \\filename = "shot-%Y%m%d.jpg"
        \\clipboard = "image"
        \\cursor = true
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const found = loaded.value.sources.screenshot;
    try testing.expectEqual(@as(?bool, false), found.enable);
    try testing.expect(found.cursor);
    try testing.expectEqualStrings("~/cloud/photos/screenshots", found.directory);
    try testing.expectEqualStrings("shot-%Y%m%d.jpg", found.filename);
    try testing.expectEqual(Config.Sources.Screenshot.Destination.image, found.destination());
}

test "the clipboard destination takes the path or nothing" {
    const Destination = Config.Sources.Screenshot.Destination;

    const path_source = "[sources.screenshot]\nclipboard = \"path\"";
    const wanted = parse(testing.allocator, path_source, "test.toml");
    defer wanted.deinit();
    try testing.expectEqual(Destination.path, wanted.value.sources.screenshot.destination());

    const both_source = "[sources.screenshot]\nclipboard = \"both\"";
    const wrong = parse(testing.allocator, both_source, "test.toml");
    defer wrong.deinit();
    try testing.expectEqual(Destination.none, wrong.value.sources.screenshot.destination());
}

test "the llm section reads its height and its providers" {
    const source =
        \\[sources.llm]
        \\height = 500
        \\
        \\[[sources.llm.openai]]
        \\name = "local"
        \\model = "Qwen/Qwen3-4B-GGUF:Q4_K_M"
    ;

    const loaded = parse(testing.allocator, source, "test.toml");
    defer loaded.deinit();

    const llm = loaded.value.sources.llm;
    try testing.expectEqual(@as(c_int, 500), llm.rows());
    try testing.expectEqual(@as(usize, 1), llm.configured());
    try testing.expectEqualStrings("local", llm.openai[0].name);
}

test "the llm table order is read from the file" {
    const Kind = Config.Sources.Llm.Kind;
    const source =
        \\[sources.llm]
        \\
        \\[[sources.llm.openai]]
        \\name = "local"
        \\
        \\[[sources.llm.anthropic]]
        \\name = "sonnet"
        \\
        \\  [[sources.llm.openai]]
        \\name = "cloud"
        \\
        \\[[sources.llm.gemini]]
        \\name = "flash"
    ;

    const order = try llmOrder(testing.allocator, source);
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 4), order.len);
    try testing.expectEqual(Kind.openai, order[0]);
    try testing.expectEqual(Kind.anthropic, order[1]);
    try testing.expectEqual(Kind.openai, order[2]);
    try testing.expectEqual(Kind.gemini, order[3]);
}

test "a commented, unrelated or old table is not counted as an llm entry" {
    const source =
        \\# [[sources.llm.gemini]]
        \\[[sources.bookmarks.markdown]]
        \\[[sources.llm.nonsense]]
        \\[[llm.anthropic]]
        \\[[sources.llm.openai]]
        \\name = "local"
    ;

    const order = try llmOrder(testing.allocator, source);
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 1), order.len);
    try testing.expectEqual(Config.Sources.Llm.Kind.openai, order[0]);
}

test "a file with no llm tables has no order" {
    const order = try llmOrder(testing.allocator, "[list]\nlines = 8\n");
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 0), order.len);
}

test "the snippets source is on with every emoji unless turned off" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();
    try testing.expect(bare.value.sources.snippets.emoji);
    try testing.expectEqual(@as(usize, 0), bare.value.sources.snippets.entries.len);

    const off = parse(testing.allocator,
        \\[sources.snippets]
        \\emoji = false
    , "test.toml");
    defer off.deinit();
    try testing.expect(!off.value.sources.snippets.emoji);
}

test "snippets are read as tables of their own" {
    const loaded = parse(testing.allocator,
        \\[sources.snippets]
        \\emoji = true
        \\
        \\[[sources.snippets.entries]]
        \\snippet = "Kind regards,\nThe team"
        \\keywords = ["regards", "signature"]
        \\
        \\[[sources.snippets.entries]]
        \\snippet = '¯\_(ツ)_/¯'
        \\keywords = ["shrug"]
    , "test.toml");
    defer loaded.deinit();

    const entries = loaded.value.sources.snippets.entries;
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("Kind regards,\nThe team", entries[0].snippet);
    try testing.expectEqual(@as(usize, 2), entries[0].keywords.len);
    try testing.expectEqualStrings("signature", entries[0].keywords[1]);
    try testing.expectEqualStrings("¯\\_(ツ)_/¯", entries[1].snippet);
}

test "snippets are read as an inline array, and a missing field reads as empty" {
    const loaded = parse(testing.allocator,
        \\[sources.snippets]
        \\entries = [
        \\  { snippet = "🙌", keywords = ["high ten"] },
        \\  { keywords = ["nothing"] },
        \\]
    , "test.toml");
    defer loaded.deinit();

    const entries = loaded.value.sources.snippets.entries;
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("🙌", entries[0].snippet);
    try testing.expectEqualStrings("", entries[1].snippet);
}

test "a source is found by the name a mode gives" {
    const loaded = parse(testing.allocator,
        \\[sources.clipboard]
        \\enable = false
        \\
        \\[sources.sway]
        \\enable = true
    , "test.toml");
    defer loaded.deinit();

    const sources = loaded.value.sources;
    try testing.expectEqual(@as(?bool, false), sources.enableOf("clipboard"));
    try testing.expectEqual(@as(?bool, true), sources.enableOf("sway"));
    try testing.expectEqual(@as(?bool, null), sources.enableOf("whats"));
    try testing.expectEqual(@as(?bool, null), sources.enableOf("nonsense"));
}

test "every mode names a source the config knows" {
    const bare = parse(testing.allocator, "", "test.toml");
    defer bare.deinit();

    for (std.enums.values(modes.Mode)) |wanted| {
        const name = wanted.source() orelse continue;

        var found = false;
        inline for (std.meta.fields(Config.Sources)) |field| {
            if (std.mem.eql(u8, field.name, name)) found = true;
        }
        try testing.expect(found);
    }
}
