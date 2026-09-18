const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const Deck = @import("Deck.zig");
const List = @import("List.zig");
const model = @import("../model.zig");
const subroutines = @import("../subroutines.zig");

const Context = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.context);

const max_numbered = 9;

pub const Chosen = Callback(fn (row: u64, action: u64) void);

gpa: Allocator,
chosen: Chosen,
arena: std.heap.ArenaAllocator,
list: *List,
row: u64 = 0,
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
    glib.g_object_set_data_full(made.widget(), owner_key, self, &onFinalized);
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
    found: []const subroutines.Action,
) void {
    const rows = self.arena.allocator().alloc(model.Row, found.len) catch {
        log.warn("out of memory, so the context was not shown", .{});
        return self.close(deck);
    };

    for (found, rows, 0..) |action, *slot, at| {
        slot.* = .{
            .id = action.id,
            .icon = action.icon,
            .number = if (at < max_numbered) @intCast(at + 1) else 0,
            .title = action.title,
            .detail = action.detail,
        };
    }

    self.row = row;
    self.showing = true;
    self.list.setRows(rows);
    gtk.gtk_widget_set_visible(self.widget(), c.TRUE);
    deck.takeFocus(self.widget());
}

pub fn close(self: *Context, deck: *Deck) void {
    if (!self.showing) return;
    self.showing = false;

    deck.giveFocus();
    gtk.gtk_widget_set_visible(self.widget(), c.FALSE);
    self.list.setRows(&.{});
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
    self.chosen.call(.{ self.row, id });
}

const owner_key: [*:0]const u8 = "sysdeck-context";

fn onFinalized(data: c.gpointer) callconv(.c) void {
    const self: *Context = @ptrCast(@alignCast(data.?));
    self.arena.deinit();
    self.gpa.destroy(self);
}
