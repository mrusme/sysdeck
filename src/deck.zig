const std = @import("std");
const c = @import("c.zig");
const list_mod = @import("list.zig");

const width = 640;

const window_class = "sysdeck";
const deck_class = "sysdeck-deck";
const input_class = "sysdeck-input";

const spacing = 6;
const padding = 6;

const css =
    \\window.sysdeck > .sysdeck-deck {
    \\  border: 1px solid alpha(currentColor, 0.15);
    \\  padding: 6px;
    \\}
    \\.sysdeck-deck list {
    \\  background: transparent;
    \\}
    \\.sysdeck-deck row {
    \\  border-radius: 6px;
    \\}
;

pub const Body = union(enum) {
    list: *list_mod.List,

    fn widget(self: Body) *c.GtkWidget {
        return switch (self) {
            .list => |body| body.widget(),
        };
    }

    fn filter(self: Body, query: []const u8) void {
        switch (self) {
            .list => |body| body.filter(query),
        }
    }

    fn move(self: Body, delta: i32) void {
        switch (self) {
            .list => |body| body.move(delta),
        }
    }

    fn accept(self: Body) void {
        switch (self) {
            .list => |body| body.accept(),
        }
    }

    fn destroy(self: Body) void {
        switch (self) {
            .list => |body| body.destroy(),
        }
    }
};

pub const Deck = struct {
    app: *c.GtkApplication,
    prompt: [:0]const u8,
    entry: *c.GtkEntry = undefined,
    box: *c.GtkBox = undefined,
    body: ?Body = null,
    was_active: bool = false,
    closing: bool = false,

    pub fn present(self: *Deck, body: Body) void {
        applyStyle();

        const window = c.cast(c.GtkWindow, c.gtk_application_window_new(self.app));
        c.gtk_window_set_title(window, "sysdeck");
        c.gtk_window_set_decorated(window, c.FALSE);
        c.gtk_window_set_resizable(window, c.FALSE);
        c.gtk_window_set_default_size(window, width, -1);
        c.gtk_widget_add_css_class(c.cast(c.GtkWidget, window), window_class);

        const box = c.cast(c.GtkBox, c.gtk_box_new(.vertical, spacing));
        c.gtk_widget_add_css_class(c.cast(c.GtkWidget, box), deck_class);
        c.gtk_widget_set_size_request(c.cast(c.GtkWidget, box), width - 2 * padding, -1);

        const entry = c.cast(c.GtkEntry, c.gtk_entry_new());
        c.gtk_entry_set_placeholder_text(entry, self.prompt);
        c.gtk_widget_add_css_class(c.cast(c.GtkWidget, entry), input_class);
        c.gtk_widget_set_hexpand(c.cast(c.GtkWidget, entry), c.TRUE);
        c.gtk_box_append(box, c.cast(c.GtkWidget, entry));

        c.gtk_window_set_child(window, c.cast(c.GtkWidget, box));

        self.entry = entry;
        self.box = box;

        const keys = c.gtk_event_controller_key_new();
        c.gtk_widget_add_controller(c.cast(c.GtkWidget, entry), keys);

        _ = c.connect(keys, "key-pressed", &onKeyPressed, self);
        _ = c.connect(entry, "changed", &onChanged, self);
        _ = c.connect(entry, "activate", &onActivated, self);
        _ = c.connect(window, "notify::is-active", &onActiveChanged, self);

        self.setBody(body);

        c.gtk_window_present(window);
        _ = c.gtk_widget_grab_focus(c.cast(c.GtkWidget, entry));
    }

    pub fn setBody(self: *Deck, body: ?Body) void {
        if (self.body) |current| {
            c.gtk_box_remove(self.box, current.widget());
            current.destroy();
        }

        self.body = body;
        if (body) |wanted| c.gtk_box_append(self.box, wanted.widget());
    }

    pub fn close(self: *Deck) void {
        if (self.closing) return;
        self.closing = true;
        c.g_application_quit(c.cast(c.GApplication, self.app));
    }

    fn typed(self: *Deck) []const u8 {
        return std.mem.span(c.gtk_entry_buffer_get_text(c.gtk_entry_get_buffer(self.entry)));
    }
};

fn deckFrom(data: c.gpointer) *Deck {
    return @ptrCast(@alignCast(data.?));
}

fn onChanged(_: *c.GtkEditable, data: c.gpointer) callconv(.c) void {
    const self = deckFrom(data);
    const body = self.body orelse return;
    body.filter(self.typed());
}

fn onActivated(_: *c.GtkEntry, data: c.gpointer) callconv(.c) void {
    const self = deckFrom(data);
    const body = self.body orelse return;
    body.accept();
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    _: c.GdkModifierType,
    data: c.gpointer,
) callconv(.c) c.gboolean {
    const self = deckFrom(data);

    switch (keyval) {
        c.key_Escape => {
            self.close();
            return c.TRUE;
        },
        c.key_Down, c.key_KP_Down => {
            const body = self.body orelse return c.FALSE;
            body.move(1);
            return c.TRUE;
        },
        c.key_Up, c.key_KP_Up => {
            const body = self.body orelse return c.FALSE;
            body.move(-1);
            return c.TRUE;
        },
        c.key_Return, c.key_KP_Enter, c.key_ISO_Enter => {
            const body = self.body orelse return c.FALSE;
            body.accept();
            return c.TRUE;
        },
        else => return c.FALSE,
    }
}

fn onActiveChanged(window: *c.GtkWindow, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const self = deckFrom(data);

    // is-active is notified on the way in as well, so closing on every
    // inactive notification would kill the window before it is ever shown.
    if (c.gtk_window_is_active(window) != c.FALSE) {
        self.was_active = true;
        return;
    }
    if (self.was_active) self.close();
}

fn applyStyle() void {
    const display = c.gdk_display_get_default() orelse return;

    const provider = c.gtk_css_provider_new();
    defer c.g_object_unref(provider);

    c.gtk_css_provider_load_from_string(provider, css);
    c.gtk_style_context_add_provider_for_display(
        display,
        c.cast(c.GtkStyleProvider, provider),
        c.style_provider_priority_application,
    );
}
