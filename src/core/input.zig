const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_bytes: std.Io.Limit = .limited(64 << 20);

pub const Item = struct {
    text: [:0]const u8,
    label: [:0]const u8,
};

pub const Lines = struct {
    gpa: Allocator,
    buffer: [:0]u8,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item),

    pub fn deinit(self: *Lines) void {
        self.items.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.free(self.buffer);
        self.* = undefined;
    }
};

pub const ReadError = Allocator.Error || std.Io.Reader.ShortError || error{TooLarge};

pub fn read(gpa: Allocator, io: std.Io) ReadError!Lines {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(gpa);

    var staging: [64 * 1024]u8 = undefined;
    var source = std.Io.File.stdin().reader(io, &staging);
    source.interface.appendRemaining(gpa, &raw, max_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.TooLarge,
        else => |leftover| return leftover,
    };

    return try collect(gpa, try raw.toOwnedSliceSentinel(gpa, 0));
}

pub fn collect(gpa: Allocator, buffer: [:0]u8) Allocator.Error!Lines {
    var lines: Lines = .{
        .gpa = gpa,
        .buffer = buffer,
        .arena = .init(gpa),
        .items = .empty,
    };
    errdefer lines.deinit();

    const scratch = lines.arena.allocator();

    var start: usize = 0;
    while (start < buffer.len) {
        const break_at = std.mem.indexOfScalarPos(u8, buffer, start, '\n') orelse buffer.len;
        var end = break_at;
        if (end > start and buffer[end - 1] == '\r') end -= 1;
        if (end < buffer.len) buffer[end] = 0;

        if (end > start) {
            const text = buffer[start..end :0];
            try lines.items.append(gpa, .{
                .text = text,
                .label = if (isPrintable(text)) text else try sanitize(scratch, text),
            });
        }

        start = break_at + 1;
    }

    return lines;
}

fn isPrintable(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return std.unicode.utf8ValidateSlice(text);
}

fn sanitize(gpa: Allocator, text: []const u8) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureUnusedCapacity(gpa, text.len + 1);

    var at: usize = 0;
    while (at < text.len) {
        const byte = text[at];
        if (byte == '\t') {
            try out.append(gpa, ' ');
            at += 1;
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            try out.appendSlice(gpa, replacement);
            at += 1;
            continue;
        }

        const width = std.unicode.utf8ByteSequenceLength(byte) catch {
            try out.appendSlice(gpa, replacement);
            at += 1;
            continue;
        };
        if (at + width > text.len or !std.unicode.utf8ValidateSlice(text[at..][0..width])) {
            try out.appendSlice(gpa, replacement);
            at += 1;
            continue;
        }

        try out.appendSlice(gpa, text[at..][0..width]);
        at += width;
    }

    return try out.toOwnedSliceSentinel(gpa, 0);
}

const replacement = "\u{fffd}";

const testing = std.testing;

fn collectSlice(source: []const u8) !Lines {
    return try collect(testing.allocator, try testing.allocator.dupeZ(u8, source));
}

test "every line becomes an item" {
    var lines = try collectSlice("alpha\nbeta\ngamma\n");
    defer lines.deinit();

    try testing.expectEqual(@as(usize, 3), lines.items.items.len);
    try testing.expectEqualStrings("alpha", lines.items.items[0].text);
    try testing.expectEqualStrings("beta", lines.items.items[1].text);
    try testing.expectEqualStrings("gamma", lines.items.items[2].text);
}

test "a missing final newline still yields a line" {
    var lines = try collectSlice("alpha\nbeta");
    defer lines.deinit();

    try testing.expectEqual(@as(usize, 2), lines.items.items.len);
    try testing.expectEqualStrings("beta", lines.items.items[1].text);
}

test "carriage returns are dropped" {
    var lines = try collectSlice("one\r\ntwo\r\n");
    defer lines.deinit();

    try testing.expectEqual(@as(usize, 2), lines.items.items.len);
    try testing.expectEqualStrings("one", lines.items.items[0].text);
    try testing.expectEqualStrings("two", lines.items.items[1].text);
}

test "empty lines are left out" {
    var lines = try collectSlice("\nalpha\n\n\r\nbeta\n");
    defer lines.deinit();

    try testing.expectEqual(@as(usize, 2), lines.items.items.len);
    try testing.expectEqualStrings("alpha", lines.items.items[0].text);
    try testing.expectEqualStrings("beta", lines.items.items[1].text);
}

test "nothing on standard input yields nothing" {
    var lines = try collectSlice("");
    defer lines.deinit();

    try testing.expectEqual(@as(usize, 0), lines.items.items.len);
}

test "a clean line shares its bytes with the label" {
    var lines = try collectSlice("caf\u{e9} au lait\n");
    defer lines.deinit();

    const item = lines.items.items[0];
    try testing.expectEqual(item.text.ptr, item.label.ptr);
}

test "invalid UTF-8 is replaced in the label but not in the text" {
    var lines = try collectSlice("a\xffb\n");
    defer lines.deinit();

    const item = lines.items.items[0];
    try testing.expectEqualStrings("a\xffb", item.text);
    try testing.expectEqualStrings("a" ++ replacement ++ "b", item.label);
}

test "a truncated multi-byte sequence is replaced byte by byte" {
    var lines = try collectSlice("\xe2\x82\n");
    defer lines.deinit();

    try testing.expectEqualStrings(replacement ++ replacement, lines.items.items[0].label);
}

test "tabs become spaces and other control bytes become replacements" {
    var lines = try collectSlice("a\tb\x07c\n");
    defer lines.deinit();

    try testing.expectEqualStrings("a b" ++ replacement ++ "c", lines.items.items[0].label);
}
