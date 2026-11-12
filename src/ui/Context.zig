const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const Deck = @import("Deck.zig");
const List = @import("List.zig");
const model = @import("../model.zig");

const Context = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.context);

const max_numbered = 9;

pub const Chosen = Callback(fn (row: u64, choice: model.Choice) void);

gpa: Allocator,
chosen: Chosen,
arena: std.heap.ArenaAllocator,
list: *List,
row: u64 = 0,
choices: []const model.Choice = &.{},
showing: bool = false,

pub fn create(gpa: Allocator, lines: u16, chosen: Chosen) Allocator.Error!*Context {
    const self = try gpa.create(Context);
    errdefer gpa.destroy(self);

    const made = try List.create(gpa, lines, .of(Context, Context.onPicked, self));
    made.setFocusable(true);

    self.* = .{
        .gpa = gpa,
        .chosen = chosen,
        .arena = .init(gpa),
        .list = made,
    };
    glib.g_object_set_data_full(c.cast(c.GObject, made.widget()), owner_key, self, &onFinalized);
    return self;
}

pub fn widget(self: *Context) *c.GtkWidget {
    return self.list.widget();
}

pub fn begin(self: *Context) Allocator {
    _ = self.arena.reset(.retain_capacity);
    return self.arena.allocator();
}

pub fn open(
    self: *Context,
    deck: *Deck,
    row: u64,
    offers: []const model.Offer,
) void {
    const arena = self.arena.allocator();
    const rows = arena.alloc(model.Row, offers.len) catch return self.exhausted(deck);
    const choices = arena.alloc(model.Choice, offers.len) catch return self.exhausted(deck);

    for (offers, rows, choices, 0..) |offer, *slot, *choice, at| {
        slot.* = .{
            .id = at,
            .icon = offer.icon,
            .number = if (at < max_numbered) @intCast(at + 1) else 0,
            .title = offer.title,
            .detail = offer.detail,
            .separated = offer.separated,
        };
        choice.* = offer.choice;
    }

    const at = if (self.showing and self.row == row) self.list.selectedAt() orelse 0 else 0;
    self.row = row;
    self.choices = choices;
    self.showing = true;
    self.list.setRows(rows, at);
    gtk.gtk_widget_set_visible(self.widget(), c.TRUE);
    deck.focus.take(self.widget());
}

fn exhausted(self: *Context, deck: *Deck) void {
    log.warn("out of memory, so the context was not shown", .{});
    self.close(deck);
}

pub fn close(self: *Context, deck: *Deck) void {
    if (!self.showing) return;
    self.showing = false;
    self.choices = &.{};

    deck.focus.give();
    gtk.gtk_widget_set_visible(self.widget(), c.FALSE);
    self.list.setRows(&.{}, 0);
}

pub fn key(self: *Context, keyval: c.guint) bool {
    if (!self.showing) return false;

    switch (keyval) {
        c.key_Up, c.key_KP_Up => {
            self.list.move(-1);
            return true;
        },
        c.key_Down, c.key_KP_Down => {
            self.list.move(1);
            return true;
        },
        c.key_Return, c.key_KP_Enter, c.key_ISO_Enter => {
            self.list.accept();
            return true;
        },
        else => {},
    }

    const digit = c.digitOf(keyval) orelse return false;
    if (digit > 0) self.list.pick(digit - 1);
    return true;
}

fn onPicked(self: *Context, id: u64) void {
    const at = std.math.cast(usize, id) orelse return;
    if (at >= self.choices.len) return;
    self.chosen.call(.{ self.row, self.choices[at] });
}

const owner_key: [*:0]const u8 = "sysdeck-context";

fn onFinalized(data: c.gpointer) callconv(.c) void {
    const self: *Context = @ptrCast(@alignCast(data.?));
    self.arena.deinit();
    self.gpa.destroy(self);
}
