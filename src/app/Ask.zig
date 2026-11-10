const std = @import("std");
const chat_mod = @import("../llm/chat.zig");
const Deck = @import("../ui/Deck.zig");
const llm_mod = @import("../subroutines/llm.zig");
const Picker = @import("../ui/Picker.zig");
const Reply = @import("../ui/Reply.zig");

const Ask = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.llm);

gpa: Allocator,
deck: *Deck,
index: *llm_mod.Index,
height: c_int,
picker: ?*Picker = null,
showing: bool = false,

pub fn create(
    gpa: Allocator,
    deck: *Deck,
    index: *llm_mod.Index,
    height: c_int,
) Allocator.Error!*Ask {
    const self = try gpa.create(Ask);
    self.* = .{ .gpa = gpa, .deck = deck, .index = index, .height = height };
    return self;
}

pub fn destroy(self: *Ask) void {
    self.gpa.destroy(self);
}

pub fn attach(self: *Ask) void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();

    const names = self.index.names(arena.allocator()) catch return;
    const made = Picker.create(
        self.gpa,
        names,
        .of(Ask, Ask.onPicked, self),
    ) catch {
        log.warn("out of memory, so the provider list is not shown", .{});
        return;
    };

    self.picker = made;
    self.deck.attachPicker(made.widget());
    made.select(self.index.chosen);
}

pub fn enter(self: *Ask) void {
    if (self.showing) return;

    self.showing = true;
    self.deck.showPicker(true);
    self.show();
}

pub fn reset(self: *Ask) void {
    self.index.clear();
    self.show();
}

pub fn leave(self: *Ask) void {
    if (!self.showing) return;

    self.showing = false;
    self.index.abort();
    self.deck.showPicker(false);
    self.deck.setAsking(false);
}

pub fn submit(self: *Ask, prompt: []const u8) void {
    const wanted = std.mem.trim(u8, prompt, " \t\n");
    if (wanted.len == 0 or self.index.busy()) return;

    if (!self.index.start(wanted)) {
        self.note();
        return self.show();
    }

    self.deck.setAsking(true);
    self.deck.setText("");
    self.show();
}

pub fn cancel(self: *Ask) bool {
    if (!self.index.busy()) return false;

    self.index.abort();
    return true;
}

pub fn cycle(self: *Ask) void {
    const found = self.picker orelse return;
    found.cycle();
}

pub fn arrived(self: *Ask) void {
    const state = self.index.settle();
    if (state == .failed) self.note();

    self.show();
    if (state != .running) self.deck.setAsking(false);
}

fn note(self: *Ask) void {
    const wanted = self.index.service() orelse {
        self.index.note("No LLM provider is configured.");
        return;
    };

    var buffer: [512]u8 = undefined;
    const text = switch (self.index.trouble) {
        .none => return,
        .missing_key => std.mem.print(
            &buffer,
            "{s} cannot be used, because {s} is not set.",
            .{ wanted.name, wanted.variable },
        ) catch return,
        .refused => std.mem.print(
            &buffer,
            "{s} did not answer. The log says why.",
            .{wanted.name},
        ) catch return,
        .lost => std.mem.print(
            &buffer,
            "{s} answered, but part of the reply is missing. The log says why.",
            .{wanted.name},
        ) catch return,
    };
    self.index.note(text);
}

fn show(self: *Ask) void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();

    const scratch = arena.allocator();
    const text = self.index.transcript(scratch) catch return;

    if (text.len == 0 and !self.index.busy()) {
        self.deck.setBody(null);
        return;
    }

    const pane = self.body() orelse return;
    if (!self.index.busy() or !endsOnPrompt(text)) return pane.setText(text);

    const waiting = scratch.printSentinel(
        "{s}\n\n{s}",
        .{ text, chat_mod.waiting },
        0,
    ) catch return pane.setText(text);
    pane.setText(waiting);
}

fn body(self: *Ask) ?*Reply {
    if (self.deck.body) |current| {
        switch (current) {
            .reply => |found| return found,
            else => {},
        }
    }

    const made = Reply.create(self.gpa, self.height) catch {
        log.warn("out of memory while building the reply pane", .{});
        return null;
    };
    self.deck.setBody(.{ .reply = made });
    return made;
}

fn onPicked(self: *Ask, at: usize) void {
    self.index.pick(at);
}

fn endsOnPrompt(text: []const u8) bool {
    var lines = std.mem.splitBackwardsScalar(u8, text, '\n');
    return std.mem.startsWith(u8, lines.first(), chat_mod.prompt_marker);
}

const testing = std.testing;

test "a transcript ending on a prompt is still waiting" {
    try testing.expect(endsOnPrompt("> what is zig?"));
    try testing.expect(endsOnPrompt("> one\n\nfirst\n\n> two"));
    try testing.expect(!endsOnPrompt("> one\n\nfirst"));
    try testing.expect(!endsOnPrompt(""));
}
