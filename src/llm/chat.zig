const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Role = enum { user, assistant };

pub const Turn = struct {
    role: Role,
    text: []const u8,
};

pub const prompt_marker = "> ";
pub const waiting = "Hallucinating ...";

pub const Chat = struct {
    gpa: Allocator,
    turns: std.ArrayList(Turn) = .empty,

    pub fn deinit(self: *Chat) void {
        self.clear();
        self.turns.deinit(self.gpa);
    }

    pub fn clear(self: *Chat) void {
        for (self.turns.items) |turn| self.gpa.free(turn.text);
        self.turns.clearRetainingCapacity();
    }

    pub fn ask(self: *Chat, text: []const u8) Allocator.Error!void {
        try self.append(.user, text);
    }

    pub fn answer(self: *Chat, text: []const u8) Allocator.Error!void {
        try self.append(.assistant, text);
    }

    fn empty(self: *const Chat) bool {
        return self.turns.items.len == 0;
    }

    fn append(self: *Chat, role: Role, text: []const u8) Allocator.Error!void {
        const owned = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned);

        try self.turns.append(self.gpa, .{ .role = role, .text = owned });
    }

    pub fn transcript(self: *const Chat, arena: Allocator, tail: []const u8) Allocator.Error![:0]u8 {
        var out: std.ArrayList(u8) = .empty;

        for (self.turns.items) |turn| try write(arena, &out, turn.role, turn.text);
        if (tail.len > 0) try write(arena, &out, .assistant, tail);

        return out.toOwnedSliceSentinel(arena, 0);
    }
};

fn write(
    arena: Allocator,
    out: *std.ArrayList(u8),
    role: Role,
    text: []const u8,
) Allocator.Error!void {
    if (out.items.len > 0) try out.appendSlice(arena, "\n\n");
    if (role == .assistant) return out.appendSlice(arena, text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;

        try out.appendSlice(arena, prompt_marker);
        try out.appendSlice(arena, line);
    }
}

const testing = std.testing;

fn chatOf(gpa: Allocator) Chat {
    return .{ .gpa = gpa };
}

test "a new conversation is empty and renders as nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var chat = chatOf(testing.allocator);
    defer chat.deinit();

    try testing.expect(chat.empty());
    try testing.expectEqualStrings("", try chat.transcript(arena.allocator(), ""));
}

test "a prompt is marked and an answer is not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var chat = chatOf(testing.allocator);
    defer chat.deinit();

    try chat.ask("what is zig?");
    try chat.answer("A systems language.");

    try testing.expectEqualStrings(
        "> what is zig?\n\nA systems language.",
        try chat.transcript(arena.allocator(), ""),
    );
}

test "turns are separated by a blank line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var chat = chatOf(testing.allocator);
    defer chat.deinit();

    try chat.ask("one");
    try chat.answer("first");
    try chat.ask("two");
    try chat.answer("second");

    try testing.expectEqualStrings(
        "> one\n\nfirst\n\n> two\n\nsecond",
        try chat.transcript(arena.allocator(), ""),
    );
}

test "a multi line prompt marks every line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var chat = chatOf(testing.allocator);
    defer chat.deinit();

    try chat.ask("first\nsecond");

    try testing.expectEqualStrings(
        "> first\n> second",
        try chat.transcript(arena.allocator(), ""),
    );
}

test "the streamed tail is appended as the answer in progress" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var chat = chatOf(testing.allocator);
    defer chat.deinit();

    try chat.ask("what is zig?");

    try testing.expectEqualStrings(
        "> what is zig?\n\nA systems",
        try chat.transcript(arena.allocator(), "A systems"),
    );
}

test "clearing starts a new conversation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var chat = chatOf(testing.allocator);
    defer chat.deinit();

    try chat.ask("one");
    try chat.answer("first");
    chat.clear();

    try testing.expect(chat.empty());
    try testing.expectEqualStrings("", try chat.transcript(arena.allocator(), ""));
}
