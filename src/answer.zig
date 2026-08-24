const std = @import("std");
const c = @import("c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.answer);

const answer_class = "sysdeck-answer";
const margin = 6;

pub const Accepted = struct {
    call: *const fn (context: *anyopaque) void,
    context: *anyopaque,
};

pub const Answer = struct {
    gpa: Allocator,
    accepted: Accepted,
    label: *c.GtkLabel,

    pub fn create(gpa: Allocator, accepted: Accepted) Allocator.Error!*Answer {
        const self = try gpa.create(Answer);

        const made = c.gtk_label_new(null);
        const label = c.cast(c.GtkLabel, made);
        c.gtk_label_set_ellipsize(label, .middle);
        c.gtk_label_set_xalign(label, 0);
        c.gtk_label_set_max_width_chars(label, 1);
        c.gtk_widget_set_hexpand(made, c.TRUE);
        c.gtk_widget_set_margin_start(made, margin);
        c.gtk_widget_set_margin_end(made, margin);
        c.gtk_widget_add_css_class(made, answer_class);

        self.* = .{ .gpa = gpa, .accepted = accepted, .label = label };
        return self;
    }

    pub fn destroy(self: *Answer) void {
        self.gpa.destroy(self);
    }

    pub fn widget(self: *Answer) *c.GtkWidget {
        return c.cast(c.GtkWidget, self.label);
    }

    pub fn setText(self: *Answer, text: [:0]const u8) void {
        c.gtk_label_set_text(self.label, text.ptr);
    }

    pub fn move(_: *Answer, _: i32) void {}

    // The text belongs to this process for as long as it runs, so the window
    // is only closed once a clipboard manager has been given the chance to
    // take it over.
    pub fn accept(self: *Answer) void {
        const clipboard = c.gtk_widget_get_clipboard(self.widget());
        c.gdk_clipboard_set_text(clipboard, c.gtk_label_get_text(self.label));

        const handoff = self.gpa.create(Handoff) catch {
            return self.accepted.call(self.accepted.context);
        };
        handoff.* = .{ .gpa = self.gpa, .accepted = self.accepted };

        c.gdk_clipboard_store_async(clipboard, c.priority_default, null, &onStored, handoff);
    }
};

// The answer widget is torn down with the rest of the window, so what the
// store needs to finish is kept apart from it.
const Handoff = struct {
    gpa: Allocator,
    accepted: Accepted,
};

fn onStored(source: c.gpointer, result: *c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const handoff: *Handoff = @ptrCast(@alignCast(data.?));
    defer handoff.gpa.destroy(handoff);

    const clipboard: *c.GdkClipboard = @ptrCast(@alignCast(source.?));
    var err: ?*c.GError = null;
    if (c.gdk_clipboard_store_finish(clipboard, result, &err) == c.FALSE) {
        defer if (err) |detail| c.g_error_free(detail);
        log.debug("the clipboard was not stored, so the answer ends with this process", .{});
    }

    handoff.accepted.call(handoff.accepted.context);
}
