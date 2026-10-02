const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const Selection = @import("Selection.zig");

const Reply = @This();

const Allocator = std.mem.Allocator;

const reply_class = "sysdeck-reply";
const step = 60;
const slack = 4;
const tail_margin = 18;
const tail_fraction = 0.06;

gpa: Allocator,
scroller: *c.GtkScrolledWindow,
view: *c.GtkTextView,
shown: std.ArrayList(u8) = .empty,
following: bool = true,

pub fn create(gpa: Allocator, height: c_int) Allocator.Error!*Reply {
    const self = try gpa.create(Reply);
    errdefer gpa.destroy(self);

    const view = c.cast(c.GtkTextView, gtk.gtk_text_view_new());
    gtk.gtk_text_view_set_editable(view, c.FALSE);
    gtk.gtk_text_view_set_cursor_visible(view, c.FALSE);
    gtk.gtk_text_view_set_wrap_mode(view, .word_char);
    gtk.gtk_text_view_set_bottom_margin(view, tail_margin);
    Selection.attach(view);

    const scroller = c.cast(c.GtkScrolledWindow, gtk.gtk_scrolled_window_new());
    gtk.gtk_scrolled_window_set_child(scroller, c.cast(c.GtkWidget, view));
    gtk.gtk_scrolled_window_set_policy(scroller, .never, .automatic);
    gtk.gtk_scrolled_window_set_propagate_natural_height(scroller, c.TRUE);
    gtk.gtk_scrolled_window_set_max_content_height(scroller, height);
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, scroller), reply_class);

    self.* = .{ .gpa = gpa, .scroller = scroller, .view = view };
    glib.g_object_set_data_full(self.widget(), owner_key, self, &onFinalized);
    return self;
}

pub fn widget(self: *Reply) *c.GtkWidget {
    return c.cast(c.GtkWidget, self.scroller);
}

pub fn setText(self: *Reply, text: [:0]const u8) void {
    self.following = self.atBottom();

    const buffer = gtk.gtk_text_view_get_buffer(self.view);
    if (grown(self.shown.items, text)) |tail| {
        var end: c.GtkTextIter = .{};
        gtk.gtk_text_buffer_get_end_iter(buffer, &end);
        gtk.gtk_text_buffer_insert(buffer, &end, tail.ptr, @intCast(tail.len));
    } else {
        gtk.gtk_text_buffer_set_text(buffer, text.ptr, -1);
    }

    self.remember(text);
    if (self.following) self.toBottom(buffer);
}

pub fn move(self: *Reply, delta: i32) void {
    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(self.scroller);
    const wanted = gtk.gtk_adjustment_get_value(adjustment) +
        @as(c.gdouble, @floatFromInt(delta * step));

    gtk.gtk_adjustment_set_value(adjustment, wanted);
}

pub fn accept(_: *Reply) void {}

fn remember(self: *Reply, text: []const u8) void {
    self.shown.clearRetainingCapacity();
    self.shown.appendSlice(self.gpa, text) catch self.shown.clearRetainingCapacity();
}

fn atBottom(self: *Reply) bool {
    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(self.scroller);
    const value = gtk.gtk_adjustment_get_value(adjustment);
    const page = gtk.gtk_adjustment_get_page_size(adjustment);
    const upper = gtk.gtk_adjustment_get_upper(adjustment);

    return value + page >= upper - slack;
}

fn toBottom(self: *Reply, buffer: *c.GtkTextBuffer) void {
    var end: c.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_end_iter(buffer, &end);

    const mark = gtk.gtk_text_buffer_create_mark(buffer, null, &end, c.FALSE);
    defer gtk.gtk_text_buffer_delete_mark(buffer, mark);

    gtk.gtk_text_view_scroll_to_mark(self.view, mark, tail_fraction, c.FALSE, 0, 0);
}

fn grown(shown: []const u8, text: []const u8) ?[]const u8 {
    if (shown.len == 0 or text.len <= shown.len) return null;
    if (!std.mem.startsWith(u8, text, shown)) return null;

    return text[shown.len..];
}

const owner_key: [*:0]const u8 = "sysdeck-reply";

fn onFinalized(data: c.gpointer) callconv(.c) void {
    const self: *Reply = @ptrCast(@alignCast(data.?));
    self.shown.deinit(self.gpa);
    self.gpa.destroy(self);
}

const testing = std.testing;

test "text that only grew is inserted as the tail" {
    try testing.expectEqualStrings(" there", grown("Hello", "Hello there").?);
    try testing.expectEqualStrings("!", grown("a", "a!").?);
}

test "text that changed is rewritten rather than appended" {
    try testing.expectEqual(@as(?[]const u8, null), grown("Hallucinating ...", "Hello"));
    try testing.expectEqual(@as(?[]const u8, null), grown("Hello", "Hell"));
    try testing.expectEqual(@as(?[]const u8, null), grown("Hello", "Hello"));
    try testing.expectEqual(@as(?[]const u8, null), grown("", "Hello"));
}
