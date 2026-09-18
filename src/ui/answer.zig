const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.answer);

const answer_class = "sysdeck-answer";
const margin = 6;

pub const Accepted = Callback(fn () void);

pub const Answer = struct {
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
        gtk.gtk_widget_set_margin_start(made, margin);
        gtk.gtk_widget_set_margin_end(made, margin);
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
        const clipboard = gtk.gtk_widget_get_clipboard(self.widget());
        gdk.gdk_clipboard_set_text(clipboard, gtk.gtk_label_get_text(self.label));

        const handoff = self.gpa.create(Handoff) catch {
            return self.accepted.call(.{});
        };
        handoff.* = .{ .gpa = self.gpa, .accepted = self.accepted };

        gdk.gdk_clipboard_store_async(clipboard, c.priority_default, null, &onStored, handoff);
    }
};

const owner_key: [*:0]const u8 = "sysdeck-answer";

fn onFinalized(data: c.gpointer) callconv(.c) void {
    const self: *Answer = @ptrCast(@alignCast(data.?));
    self.gpa.destroy(self);
}

const Handoff = struct {
    gpa: Allocator,
    accepted: Accepted,
};

fn onStored(source: c.gpointer, result: *c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const handoff: *Handoff = @ptrCast(@alignCast(data.?));
    defer handoff.gpa.destroy(handoff);

    const clipboard: *c.GdkClipboard = @ptrCast(@alignCast(source.?));
    var err: ?*c.GError = null;
    if (gdk.gdk_clipboard_store_finish(clipboard, result, &err) == c.FALSE) {
        defer if (err) |detail| glib.g_error_free(detail);
        log.debug("the clipboard was not stored, so the answer ends with this process", .{});
    }

    handoff.accepted.call(.{});
}
