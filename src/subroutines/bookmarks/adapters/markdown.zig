const std = @import("std");
const xdg = @import("core").xdg;
const adapters = @import("../adapter.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.bookmarks);

pub const name = "markdown";

const max_file_bytes = 4 << 20;
const max_indent = 3;
const min_fence = 3;

const Definitions = std.StringHashMapUnmanaged([]const u8);

pub const Adapter = struct {
    io: std.Io,
    home: []const u8,
    files: []const []const u8,
    max_age_minutes: i64,

    pub fn adapter(self: *Adapter) adapters.Adapter {
        return .{
            .name = name,
            .max_age_minutes = self.max_age_minutes,
            .context = self,
            .vtable = adapters.vtableOf(Adapter),
        };
    }

    pub fn collect(self: *Adapter, arena: Allocator) Allocator.Error!adapters.Collected {
        var links: std.ArrayList(adapters.Link) = .empty;
        var complete = true;

        for (self.files) |file| {
            const path = try xdg.expand(arena, self.home, file);

            const text = Dir.cwd().readFileAlloc(
                self.io,
                path,
                arena,
                .limited(max_file_bytes),
            ) catch |err| {
                log.warn("cannot read {s}: {t}", .{ path, err });
                if (err != error.FileNotFound) complete = false;
                continue;
            };

            try parse(arena, text, &links);
        }

        return .{ .links = try links.toOwnedSlice(arena), .complete = complete };
    }
};

fn parse(
    arena: Allocator,
    text: []const u8,
    out: *std.ArrayList(adapters.Link),
) Allocator.Error!void {
    const prose = try arena.dupe(u8, text);
    blankFences(prose);

    var labels: Definitions = .empty;
    try define(arena, prose, &labels);

    try scan(arena, prose, labels, out);
}

const Fence = struct {
    marker: u8,
    count: usize,
    bare: bool,

    fn of(line: []const u8) ?Fence {
        const body = std.mem.trimStart(u8, line, " ");
        if (line.len - body.len > max_indent or body.len == 0) return null;

        const marker = body[0];
        if (marker != '`' and marker != '~') return null;

        const count = run(body, 0, marker);
        if (count < min_fence) return null;

        const info = body[count..];
        if (marker == '`' and std.mem.findScalar(u8, info, '`') != null) return null;

        return .{
            .marker = marker,
            .count = count,
            .bare = std.mem.trim(u8, info, &std.ascii.whitespace).len == 0,
        };
    }

    fn closes(self: Fence, line: []const u8) bool {
        const found = of(line) orelse return false;
        return found.bare and found.marker == self.marker and found.count >= self.count;
    }
};

fn blankFences(text: []u8) void {
    var open: ?Fence = null;
    var at: usize = 0;

    while (at < text.len) {
        const stop = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
        const line = text[at..stop];

        if (open) |fence| {
            if (fence.closes(line)) open = null;
            @memset(line, ' ');
        } else if (Fence.of(line)) |fence| {
            open = fence;
            @memset(line, ' ');
        }

        at = stop + 1;
    }
}

fn define(arena: Allocator, text: []u8, into: *Definitions) Allocator.Error!void {
    var at: usize = 0;

    while (at < text.len) {
        const stop = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
        const line = text[at..stop];
        at = stop + 1;

        const found = definitionOf(std.mem.trimEnd(u8, line, "\r")) orelse continue;

        const key = try label(arena, found.label);
        if (key.len > 0 and !into.contains(key)) {
            try into.put(arena, key, try unescape(arena, found.url));
        }

        @memset(line, ' ');
    }
}

const Definition = struct {
    label: []const u8,
    url: []const u8,
};

const Destination = struct {
    end: usize,
    url: []const u8,
};

fn definitionOf(line: []const u8) ?Definition {
    const body = std.mem.trimStart(u8, line, " ");
    if (line.len - body.len > max_indent) return null;
    if (body.len == 0 or body[0] != '[') return null;

    const close = bracketEnd(body, 0) orelse return null;
    if (close + 1 >= body.len or body[close + 1] != ':') return null;

    const rest = std.mem.trimStart(u8, body[close + 2 ..], " \t");
    if (rest.len == 0) return null;

    const found = plainDestination(rest) orelse return null;
    const after = std.mem.trimStart(u8, rest[found.end..], " \t");
    if (after.len > 0 and after[0] != '"' and after[0] != '\'' and after[0] != '(') return null;

    return .{ .label = body[1..close], .url = found.url };
}

fn plainDestination(text: []const u8) ?Destination {
    if (text[0] == '<') {
        const close = std.mem.findScalarPos(u8, text, 1, '>') orelse return null;
        return .{ .end = close + 1, .url = text[1..close] };
    }

    var at: usize = 0;
    while (at < text.len and !std.ascii.isWhitespace(text[at])) : (at += 1) {
        if (text[at] == '\\') at += 1;
    }

    const end = @min(at, text.len);
    return .{ .end = end, .url = text[0..end] };
}

fn scan(
    arena: Allocator,
    text: []const u8,
    labels: Definitions,
    out: *std.ArrayList(adapters.Link),
) Allocator.Error!void {
    var at: usize = 0;
    while (at < text.len) {
        switch (text[at]) {
            '\\' => at += 2,
            '`' => at = spanEnd(text, at),
            '!' => at = if (at + 1 < text.len and text[at + 1] == '[')
                (bracketEnd(text, at + 1) orelse at + 1) + 1
            else
                at + 1,
            '[' => {
                const found = (try linkAt(arena, text, at, labels)) orelse {
                    at += 1;
                    continue;
                };
                at = found.end;

                try out.append(arena, .{ .url = found.url, .name = found.name });
            },
            else => at += 1,
        }
    }
}

const Match = struct {
    end: usize,
    name: []const u8,
    url: []const u8,
};

fn linkAt(
    arena: Allocator,
    text: []const u8,
    open: usize,
    labels: Definitions,
) Allocator.Error!?Match {
    const close = bracketEnd(text, open) orelse return null;
    const inner = text[open + 1 .. close];
    const after = close + 1;

    if (after < text.len and text[after] == '(') {
        const found = inlineDestination(text, after) orelse return null;
        return .{
            .end = found.end,
            .name = try flatten(arena, inner),
            .url = try unescape(arena, found.url),
        };
    }

    if (after < text.len and text[after] == '[') {
        const end = bracketEnd(text, after) orelse return null;
        const raw = text[after + 1 .. end];
        const wanted = if (raw.len == 0) inner else raw;
        const url = (try lookup(arena, labels, wanted)) orelse return null;
        return .{ .end = end + 1, .name = try flatten(arena, inner), .url = url };
    }

    const url = (try lookup(arena, labels, inner)) orelse return null;
    return .{ .end = after, .name = try flatten(arena, inner), .url = url };
}

fn lookup(arena: Allocator, labels: Definitions, raw: []const u8) Allocator.Error!?[]const u8 {
    const key = try label(arena, raw);
    if (key.len == 0) return null;
    return labels.get(key);
}

fn inlineDestination(text: []const u8, open: usize) ?Destination {
    var at = skipSpace(text, open + 1);
    var url: []const u8 = "";

    if (at < text.len and text[at] == '<') {
        const close = std.mem.findScalarPos(u8, text, at + 1, '>') orelse return null;
        if (std.mem.findScalar(u8, text[at + 1 .. close], '\n') != null) return null;
        url = text[at + 1 .. close];
        at = close + 1;
    } else {
        const start = at;
        var depth: usize = 0;
        while (at < text.len) : (at += 1) {
            const char = text[at];
            if (char == '\\') {
                at += 1;
                continue;
            }
            if (std.ascii.isWhitespace(char)) break;
            if (char == '(') depth += 1;
            if (char == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        url = text[start..@min(at, text.len)];
    }

    at = skipSpace(text, at);
    if (at < text.len and (text[at] == '"' or text[at] == '\'' or text[at] == '(')) {
        const closer: u8 = if (text[at] == '(') ')' else text[at];
        const end = findUnescaped(text, at + 1, closer) orelse return null;
        at = skipSpace(text, end + 1);
    }

    if (at >= text.len or text[at] != ')') return null;
    return .{ .end = at + 1, .url = url };
}

fn skipSpace(text: []const u8, from: usize) usize {
    var at = from;
    while (at < text.len and std.ascii.isWhitespace(text[at])) at += 1;
    return at;
}

fn findUnescaped(text: []const u8, from: usize, wanted: u8) ?usize {
    var at = from;
    while (at < text.len) : (at += 1) {
        if (text[at] == '\\') {
            at += 1;
            continue;
        }
        if (text[at] == wanted) return at;
    }
    return null;
}

fn bracketEnd(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var at = open;

    while (at < text.len) : (at += 1) {
        switch (text[at]) {
            '\\' => at += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return at;
            },
            else => {},
        }
    }
    return null;
}

fn run(text: []const u8, from: usize, marker: u8) usize {
    var at = from;
    while (at < text.len and text[at] == marker) at += 1;
    return at - from;
}

fn spanEnd(text: []const u8, open: usize) usize {
    const length = run(text, open, '`');

    var at = open + length;
    while (at < text.len) {
        if (text[at] != '`') {
            at += 1;
            continue;
        }

        const found = run(text, at, '`');
        if (found == length) return at + found;
        at += found;
    }
    return open + length;
}

fn label(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var spaced = false;

    for (raw) |char| {
        if (std.ascii.isWhitespace(char)) {
            spaced = out.items.len > 0;
            continue;
        }
        if (spaced) try out.append(arena, ' ');
        spaced = false;
        try out.append(arena, std.ascii.toLower(char));
    }

    return out.toOwnedSlice(arena);
}

fn unescape(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var at: usize = 0;
    while (at < raw.len) : (at += 1) {
        if (raw[at] == '\\' and at + 1 < raw.len and punctuation(raw[at + 1])) at += 1;
        try out.append(arena, raw[at]);
    }

    return out.toOwnedSlice(arena);
}

fn flatten(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var plain: std.ArrayList(u8) = .empty;

    var at: usize = 0;
    while (at < raw.len) {
        if (raw[at] == '\\' and at + 1 < raw.len and punctuation(raw[at + 1])) {
            try plain.append(arena, raw[at + 1]);
            at += 2;
            continue;
        }
        if (raw[at] == '!' and at + 1 < raw.len and raw[at + 1] == '[') {
            if (bracketEnd(raw, at + 1)) |close| {
                try plain.appendSlice(arena, raw[at + 2 .. close]);
                at = skipTarget(raw, close + 1);
                continue;
            }
        }
        if (raw[at] == '`') {
            const length = run(raw, at, '`');
            const end = spanEnd(raw, at);
            if (end > at + length) {
                try plain.appendSlice(arena, raw[at + length .. end - length]);
                at = end;
                continue;
            }
        }
        try plain.append(arena, raw[at]);
        at += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    var spaced = false;

    for (plain.items) |char| {
        if (std.ascii.isWhitespace(char)) {
            spaced = out.items.len > 0;
            continue;
        }
        if (spaced) try out.append(arena, ' ');
        spaced = false;
        try out.append(arena, char);
    }

    return out.toOwnedSlice(arena);
}

fn skipTarget(raw: []const u8, from: usize) usize {
    if (from >= raw.len) return from;

    if (raw[from] == '(') {
        const found = inlineDestination(raw, from) orelse return from;
        return found.end;
    }
    if (raw[from] == '[') return (bracketEnd(raw, from) orelse from) + 1;

    return from;
}

fn punctuation(char: u8) bool {
    return std.ascii.isPrint(char) and !std.ascii.isAlphanumeric(char) and char != ' ';
}

const testing = std.testing;

fn expectLinks(text: []const u8, expected: []const adapters.Link) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var found: std.ArrayList(adapters.Link) = .empty;
    try parse(arena.allocator(), text, &found);

    try testing.expectEqual(expected.len, found.items.len);
    for (expected, found.items) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.url, got.url);
    }
}

test "an inline link gives up its name and its url" {
    try expectLinks(
        "See [Zig](https://ziglang.org) for the language.",
        &.{.{ .name = "Zig", .url = "https://ziglang.org" }},
    );
}

test "a title after the destination is left out" {
    try expectLinks(
        \\[Zig](https://ziglang.org "The Zig homepage")
        \\[SQLite](https://sqlite.org 'small, fast')
    , &.{
        .{ .name = "Zig", .url = "https://ziglang.org" },
        .{ .name = "SQLite", .url = "https://sqlite.org" },
    });
}

test "a destination in angle brackets may hold spaces" {
    try expectLinks(
        "[Notes](<https://example.com/my notes>)",
        &.{.{ .name = "Notes", .url = "https://example.com/my notes" }},
    );
}

test "parentheses in a destination are balanced rather than ending it" {
    try expectLinks(
        "[Zig](https://en.wikipedia.org/wiki/Zig_(programming_language))",
        &.{.{ .name = "Zig", .url = "https://en.wikipedia.org/wiki/Zig_(programming_language)" }},
    );
}

test "brackets nest inside the name" {
    try expectLinks(
        "[the [zig] language](https://ziglang.org)",
        &.{.{ .name = "the [zig] language", .url = "https://ziglang.org" }},
    );
}

test "a name spanning two lines is joined by a single space" {
    try expectLinks(
        \\[the zig
        \\   language](https://ziglang.org)
    , &.{.{ .name = "the zig language", .url = "https://ziglang.org" }});
}

test "an image is not a bookmark" {
    try expectLinks("![a screenshot](https://example.com/shot.png)", &.{});
    try expectLinks(
        "[![badge](https://img.example.com/b.svg)](https://ziglang.org)",
        &.{.{ .name = "badge", .url = "https://ziglang.org" }},
    );
}

test "a reference link is resolved through its definition" {
    try expectLinks(
        \\[Zig][zig] and [SQLite][] and [zqlite]
        \\
        \\[zig]: https://ziglang.org
        \\[sqlite]: https://sqlite.org "The database"
        \\[zqlite]: <https://github.com/karlseguin/zqlite.zig>
    , &.{
        .{ .name = "Zig", .url = "https://ziglang.org" },
        .{ .name = "SQLite", .url = "https://sqlite.org" },
        .{ .name = "zqlite", .url = "https://github.com/karlseguin/zqlite.zig" },
    });
}

test "a label matches whatever its case and spacing" {
    try expectLinks(
        \\[Zig][The  Zig
        \\Language]
        \\
        \\   [the zig language]: https://ziglang.org
    , &.{.{ .name = "Zig", .url = "https://ziglang.org" }});
}

test "a reference without a definition is not a bookmark" {
    try expectLinks("[Zig][missing] and [also missing]", &.{});
}

test "the first definition of a label wins" {
    try expectLinks(
        \\[Zig][zig]
        \\
        \\[zig]: https://ziglang.org
        \\[zig]: https://example.com
    , &.{.{ .name = "Zig", .url = "https://ziglang.org" }});
}

test "a fenced block holds neither links nor definitions" {
    try expectLinks(
        \\```markdown
        \\[Fake](https://example.com)
        \\[fake]: https://example.com
        \\```
        \\
        \\~~~
        \\[Also fake](https://example.com)
        \\~~~
        \\
        \\[Zig](https://ziglang.org) and [Fake][fake]
    , &.{.{ .name = "Zig", .url = "https://ziglang.org" }});
}

test "a fence closes only on its own marker" {
    try expectLinks(
        \\```
        \\~~~
        \\[Fake](https://example.com)
        \\```
        \\[Zig](https://ziglang.org)
    , &.{.{ .name = "Zig", .url = "https://ziglang.org" }});
}

test "a code span holds no links" {
    try expectLinks("Write `[Zig](https://ziglang.org)` to link it.", &.{});
    try expectLinks(
        "``a ` tick [Fake](https://example.com)`` then [Zig](https://ziglang.org)",
        &.{.{ .name = "Zig", .url = "https://ziglang.org" }},
    );
}

test "code inside a name is kept as plain text" {
    try expectLinks(
        "[`ripgrep`](https://github.com/BurntSushi/ripgrep)",
        &.{.{ .name = "ripgrep", .url = "https://github.com/BurntSushi/ripgrep" }},
    );
}

test "an escape is removed from the name and honored in the brackets" {
    try expectLinks(
        "[a \\[b\\] c](https://example.com)",
        &.{.{ .name = "a [b] c", .url = "https://example.com" }},
    );
    try expectLinks("\\[Zig](https://ziglang.org)", &.{});
}

test "a destination is reported the way it was written" {
    try expectLinks(
        "[Chapter](./chapter.md) and [Top](#top)",
        &.{
            .{ .name = "Chapter", .url = "./chapter.md" },
            .{ .name = "Top", .url = "#top" },
        },
    );
}

test "a link without a name keeps its url" {
    try expectLinks(
        "[](https://example.com) and [ ](https://other.example.com)",
        &.{
            .{ .name = "", .url = "https://example.com" },
            .{ .name = "", .url = "https://other.example.com" },
        },
    );
}

test "carriage returns do not hide a definition" {
    try expectLinks(
        "[Zig][zig]\r\n\r\n[zig]: https://ziglang.org\r\n",
        &.{.{ .name = "Zig", .url = "https://ziglang.org" }},
    );
}

test "every link in a list is found in the order it was written" {
    try expectLinks(
        \\# Links
        \\
        \\- [Zig](https://ziglang.org)
        \\- [SQLite](https://sqlite.org)
        \\- [GTK](https://gtk.org)
    , &.{
        .{ .name = "Zig", .url = "https://ziglang.org" },
        .{ .name = "SQLite", .url = "https://sqlite.org" },
        .{ .name = "GTK", .url = "https://gtk.org" },
    });
}

test "a file without links produces none" {
    try expectLinks("", &.{});
    try expectLinks("# A heading\n\nSome prose about nothing.\n", &.{});
}
