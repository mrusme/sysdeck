const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub fn match(pattern: []const u8, name: []const u8) bool {
    if (name.len > 0 and name[0] == '.' and !dotted(pattern)) return false;

    var wanted: usize = 0;
    var at: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;

    while (at < name.len) {
        if (wanted < pattern.len and pattern[wanted] == '*') {
            wanted += 1;
            star = wanted;
            mark = at;
            continue;
        }

        if (wanted < pattern.len) {
            if (single(pattern, wanted, name[at])) |next| {
                wanted = next;
                at += 1;
                continue;
            }
        }

        wanted = star orelse return false;
        mark += 1;
        at = mark;
    }

    while (wanted < pattern.len and pattern[wanted] == '*') wanted += 1;
    return wanted == pattern.len;
}

pub fn expand(
    arena: Allocator,
    io: std.Io,
    pattern: []const u8,
) Allocator.Error![]const []const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.tokenizeScalar(u8, pattern, std.fs.path.sep);
    while (parts.next()) |part| try segments.append(arena, part);

    var found: std.ArrayList([]const u8) = .empty;
    const base = if (std.fs.path.isAbsolute(pattern)) std.fs.path.sep_str else "";
    try descend(arena, io, &found, base, segments.items);

    std.mem.sort([]const u8, found.items, {}, before);
    return found.items;
}

fn descend(
    arena: Allocator,
    io: std.Io,
    found: *std.ArrayList([]const u8),
    base: []const u8,
    segments: []const []const u8,
) Allocator.Error!void {
    if (segments.len == 0) {
        Dir.cwd().access(io, base, .{ .follow_symlinks = false }) catch return;
        return found.append(arena, base);
    }

    const segment = segments[0];
    const rest = segments[1..];

    if (!wild(segment)) {
        const next = try std.fs.path.join(arena, &.{ base, try literal(arena, segment) });
        return descend(arena, io, found, next, rest);
    }

    const path = if (base.len == 0) "." else base;
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var entries = dir.iterate();
    while (entries.next(io) catch return) |entry| {
        if (!match(segment, entry.name)) continue;

        const next = try std.fs.path.join(arena, &.{ base, entry.name });
        try descend(arena, io, found, next, rest);
    }
}

fn single(pattern: []const u8, at: usize, byte: u8) ?usize {
    switch (pattern[at]) {
        '?' => return at + 1,
        '[' => if (bracket(pattern, at, byte)) |found| {
            return if (found.matched) found.next else null;
        },
        '\\' => if (at + 1 < pattern.len) {
            return if (pattern[at + 1] == byte) at + 2 else null;
        },
        else => {},
    }
    return if (pattern[at] == byte) at + 1 else null;
}

const Class = struct {
    matched: bool,
    next: usize,
};

fn bracket(pattern: []const u8, at: usize, byte: u8) ?Class {
    var cursor = at + 1;
    const negated = cursor < pattern.len and (pattern[cursor] == '!' or pattern[cursor] == '^');
    if (negated) cursor += 1;

    const first = cursor;
    var matched = false;

    while (cursor < pattern.len) {
        const low = pattern[cursor];
        if (low == ']' and cursor > first) {
            return .{ .matched = matched != negated, .next = cursor + 1 };
        }

        const ranged = cursor + 2 < pattern.len and pattern[cursor + 1] == '-';
        if (ranged and pattern[cursor + 2] != ']') {
            if (low <= byte and byte <= pattern[cursor + 2]) matched = true;
            cursor += 3;
            continue;
        }

        if (low == byte) matched = true;
        cursor += 1;
    }
    return null;
}

fn dotted(pattern: []const u8) bool {
    return std.mem.startsWith(u8, pattern, ".") or std.mem.startsWith(u8, pattern, "\\.");
}

fn wild(segment: []const u8) bool {
    var at: usize = 0;
    while (at < segment.len) : (at += 1) {
        switch (segment[at]) {
            '\\' => at += 1,
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}

fn literal(arena: Allocator, segment: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, segment, '\\') == null) return segment;

    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < segment.len) : (at += 1) {
        if (segment[at] == '\\' and at + 1 < segment.len) at += 1;
        try out.append(arena, segment[at]);
    }
    return out.items;
}

fn before(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

const testing = std.testing;

test "a star matches any run of characters and a question mark exactly one" {
    try testing.expect(match("*", "config"));
    try testing.expect(match("*.conf", "work.conf"));
    try testing.expect(!match("*.conf", ".conf.conf"));
    try testing.expect(match("w*k*", "work"));
    try testing.expect(match("*", ""));
    try testing.expect(match("host?", "host1"));
    try testing.expect(!match("host?", "host"));
    try testing.expect(!match("host?", "host12"));
    try testing.expect(!match("*.conf", "work.config"));
}

test "a bracket matches one character from its set or range" {
    try testing.expect(match("host[12]", "host2"));
    try testing.expect(!match("host[12]", "host3"));
    try testing.expect(match("[a-c]*", "beta"));
    try testing.expect(!match("[a-c]*", "delta"));
    try testing.expect(match("[]x]", "]"));
    try testing.expect(match("a[-]b", "a-b"));
}

test "a negated bracket matches what its set leaves out" {
    try testing.expect(match("[!a-c]*", "delta"));
    try testing.expect(!match("[!a-c]*", "alpha"));
    try testing.expect(match("[^0-9]", "x"));
    try testing.expect(!match("[^0-9]", "7"));
}

test "an unclosed bracket is an ordinary character" {
    try testing.expect(match("a[b", "a[b"));
    try testing.expect(!match("a[b", "ab"));
}

test "an escaped wildcard is matched literally" {
    try testing.expect(match("a\\*b", "a*b"));
    try testing.expect(!match("a\\*b", "axb"));
    try testing.expect(match("what\\?", "what?"));
}

test "a leading dot has to be matched by a dot" {
    try testing.expect(!match("*", ".hidden"));
    try testing.expect(!match("?hidden", ".hidden"));
    try testing.expect(!match("[.]hidden", ".hidden"));
    try testing.expect(match(".*", ".hidden"));
    try testing.expect(match("\\.hidden", ".hidden"));
    try testing.expect(match("*.conf", "a.conf"));
}

fn touch(dir: Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(testing.io, parent);
    const file = try dir.createFile(testing.io, path, .{});
    file.close(testing.io);
}

fn rooted(buffer: []u8, tmp: testing.TmpDir, suffix: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, suffix });
}

test "expanding lists the matches in byte order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = [_][]const u8{
        "config.d/b.conf",
        "config.d/a.conf",
        "config.d/C.conf",
        "config.d/.x.conf",
        "config.d/notes",
    };
    for (paths) |path| try touch(tmp.dir, path);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const pattern = try rooted(&buffer, tmp, "config.d/*.conf");
    const found = try expand(arena.allocator(), testing.io, pattern);

    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expect(std.mem.endsWith(u8, found[0], "config.d/C.conf"));
    try testing.expect(std.mem.endsWith(u8, found[1], "config.d/a.conf"));
    try testing.expect(std.mem.endsWith(u8, found[2], "config.d/b.conf"));
}

test "a wildcard directory is expanded on the way down" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const u8{ "hosts/work/config", "hosts/home/config", "hosts/home/other" }) |path| {
        try touch(tmp.dir, path);
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const pattern = try rooted(&buffer, tmp, "hosts/*/config");
    const found = try expand(arena.allocator(), testing.io, pattern);

    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expect(std.mem.endsWith(u8, found[0], "hosts/home/config"));
    try testing.expect(std.mem.endsWith(u8, found[1], "hosts/work/config"));
}

test "a literal path is found only when it exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try touch(tmp.dir, "work");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const there = try expand(arena.allocator(), testing.io, try rooted(&buffer, tmp, "work"));
    try testing.expectEqual(@as(usize, 1), there.len);

    const missing = try expand(arena.allocator(), testing.io, try rooted(&buffer, tmp, "home"));
    try testing.expectEqual(@as(usize, 0), missing.len);
}

test "nothing matching gives nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const in_empty = try expand(arena.allocator(), testing.io, try rooted(&buffer, tmp, "*.conf"));
    try testing.expectEqual(@as(usize, 0), in_empty.len);

    const gone = try rooted(&buffer, tmp, "gone/*");
    const no_directory = try expand(arena.allocator(), testing.io, gone);
    try testing.expectEqual(@as(usize, 0), no_directory.len);
}
