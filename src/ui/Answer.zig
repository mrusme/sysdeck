const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");

const Answer = @This();

const Allocator = std.mem.Allocator;

const answer_class = "sysdeck-answer";

pub const Accepted = Callback(fn (text: [:0]const u8) void);

gpa: Allocator,
accepted: Accepted,
label: *c.GtkLabel,

pub fn create(gpa: Allocator, accepted: Accepted) Allocator.Error!*Answer {
    const self = try gpa.create(Answer);

    const made = gtk.gtk_label_new(null);
    const label = c.cast(c.GtkLabel, made);
    gtk.gtk_label_set_ellipsize(label, .middle);
    gtk.gtk_label_set_xalign(label, 0);
    gtk.gtk_label_set_max_width_chars(label, 1);
    gtk.gtk_widget_set_hexpand(made, c.TRUE);
    gtk.gtk_widget_add_css_class(made, answer_class);

    self.* = .{ .gpa = gpa, .accepted = accepted, .label = label };
    glib.g_object_set_data_full(made, owner_key, self, &onFinalized);
    return self;
}

pub fn widget(self: *Answer) *c.GtkWidget {
    return c.cast(c.GtkWidget, self.label);
}

pub fn setText(self: *Answer, text: [:0]const u8) void {
    gtk.gtk_label_set_text(self.label, text.ptr);
}

pub fn move(_: *Answer, _: i32) void {}

pub fn accept(self: *Answer) void {
    self.accepted.call(.{std.mem.span(gtk.gtk_label_get_text(self.label))});
}

const owner_key: [*:0]const u8 = "sysdeck-answer";

fn onFinalized(data: c.gpointer) callconv(.c) void {
    const self: *Answer = @ptrCast(@alignCast(data.?));
    self.gpa.destroy(self);
}
