const std = @import("std");
const c = @import("../gtk/c.zig");
const gtk = @import("../gtk/gtk.zig");

const Arguments = @This();

const placeholder = "Arguments";

entry: *c.GtkEntry,

pub fn create() Arguments {
    const entry = c.cast(c.GtkEntry, gtk.gtk_entry_new());
    gtk.gtk_entry_set_placeholder_text(entry, placeholder);
    gtk.gtk_widget_set_hexpand(c.cast(c.GtkWidget, entry), c.TRUE);
    gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, entry), c.FALSE);
    return .{ .entry = entry };
}

pub fn widget(self: Arguments) *c.GtkWidget {
    return c.cast(c.GtkWidget, self.entry);
}

pub fn isOpen(self: Arguments) bool {
    return gtk.gtk_widget_get_visible(self.widget()) != c.FALSE;
}

pub fn holds(self: Arguments, focus: ?*c.GtkWidget) bool {
    const found = focus orelse return false;
    return found == self.widget() or gtk.gtk_widget_is_ancestor(found, self.widget()) != c.FALSE;
}

pub fn open(self: Arguments) void {
    gtk.gtk_widget_set_visible(self.widget(), c.TRUE);
    _ = gtk.gtk_entry_grab_focus_without_selecting(self.entry);
}

pub fn close(self: Arguments) void {
    gtk.gtk_entry_buffer_set_text(gtk.gtk_entry_get_buffer(self.entry), "", -1);
    gtk.gtk_widget_set_visible(self.widget(), c.FALSE);
}

pub fn text(self: Arguments) []const u8 {
    if (!self.isOpen()) return "";
    return std.mem.span(gtk.gtk_entry_buffer_get_text(gtk.gtk_entry_get_buffer(self.entry)));
}
