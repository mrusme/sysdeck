const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const answer_mod = @import("answer.zig");
const reply_mod = @import("reply.zig");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const keys_mod = @import("keys.zig");
const list_mod = @import("list.zig");

const width = 640;

const window_class = "sysdeck";
const deck_class = "sysdeck-deck";
const input_class = "sysdeck-input";
const extras_class = "sysdeck-extras";

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
    \\.sysdeck-title {
    \\  font-weight: bold;
    \\}
    \\.sysdeck-glyph {
    \\  font-size: 24px;
    \\}
    \\.sysdeck-detail {
    \\  font-size: 0.85em;
    \\  opacity: 0.6;
    \\}
    \\.sysdeck-number {
    \\  opacity: 0.45;
    \\}
    \\.sysdeck-answer {
    \\  font-size: 1.6em;
    \\}
    \\.sysdeck-man {
    \\  font-size: 0.9em;
    \\}
    \\.sysdeck-caption {
    \\  font-size: 0.85em;
    \\  opacity: 0.6;
    \\}
    \\.sysdeck-reader {
    \\  font-size: 0.9em;
    \\}
    \\.sysdeck-reader text {
    \\  background: transparent;
    \\}
    \\.sysdeck-reply {
    \\  font-size: 0.95em;
    \\}
    \\.sysdeck-reply text {
    \\  background: transparent;
    \\}
    \\.sysdeck-badge {
    \\  background: alpha(currentColor, 0.15);
    \\  border-radius: 5px;
    \\  font-size: 0.75em;
    \\  padding: 0 2px;
    \\}
    \\.sysdeck-badge button.sysdeck-focus {
    \\  min-height: 14px;
    \\  padding: 0 2px;
    \\}
    \\.sysdeck-badge button.sysdeck-kill {
    \\  min-height: 14px;
    \\  min-width: 14px;
    \\  padding: 0;
    \\  opacity: 0.6;
    \\}
    \\.sysdeck-badge button.sysdeck-kill:hover {
    \\  opacity: 1;
    \\}
    \\.sysdeck-badge label.sysdeck-status {
    \\  padding: 0 3px;
    \\}
    \\.sysdeck-badge.sysdeck-good {
    \\  background: alpha(#2ec27e, 0.4);
    \\}
    \\.sysdeck-badge.sysdeck-bad {
    \\  background: alpha(#e01b24, 0.4);
    \\}
;

pub const Body = union(enum) {
    list: *list_mod.List,
    answer: *answer_mod.Answer,
    reply: *reply_mod.Reply,

    fn widget(self: Body) *c.GtkWidget {
        return switch (self) {
            inline else => |body| body.widget(),
        };
    }

    fn move(self: Body, delta: i32) void {
        switch (self) {
            inline else => |body| body.move(delta),
        }
    }

    fn accept(self: Body) void {
        switch (self) {
            inline else => |body| body.accept(),
        }
    }
};

pub const Changed = Callback(fn (text: []const u8) void);

pub const Keys = Callback(fn (keyval: c.guint, state: c.GdkModifierType) bool);
pub const Holding = Callback(fn (held: bool) void);

pub const Deck = struct {
    app: *c.GtkApplication,
    prompt: [:0]const u8,
    changed: Changed = undefined,
    keys: ?Keys = null,
    holding: ?Holding = null,
    held: keys_mod.Held = .{ .left = c.key_Alt_L, .right = c.key_Alt_R },
    echoing: bool = false,
    restoring: bool = false,
    navigating: bool = false,
    window: *c.GtkWindow = undefined,
    entry: *c.GtkEntry = undefined,
    box: *c.GtkBox = undefined,
    extras: *c.GtkBox = undefined,
    body: ?Body = null,
    picker: ?*c.GtkWidget = null,
    context: ?*c.GtkWidget = null,
    returning: ?*c.GtkWidget = null,
    was_active: bool = false,
    presented: bool = false,
    suspended: bool = false,
    busy: bool = false,
    closing: bool = false,

    pub fn present(self: *Deck, changed: Changed, body: ?Body) void {
        applyStyle();

        self.changed = changed;

        const window = c.cast(c.GtkWindow, gtk.gtk_application_window_new(self.app));
        gtk.gtk_window_set_title(window, "sysdeck");
        gtk.gtk_window_set_decorated(window, c.FALSE);
        gtk.gtk_window_set_resizable(window, c.FALSE);
        gtk.gtk_window_set_default_size(window, width, -1);
        gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, window), window_class);

        const box = c.cast(c.GtkBox, gtk.gtk_box_new(.vertical, spacing));
        gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, box), deck_class);
        gtk.gtk_widget_set_size_request(c.cast(c.GtkWidget, box), width - 2 * padding, -1);

        const entry = c.cast(c.GtkEntry, gtk.gtk_entry_new());
        gtk.gtk_entry_set_placeholder_text(entry, self.prompt);
        gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, entry), input_class);
        gtk.gtk_widget_set_hexpand(c.cast(c.GtkWidget, entry), c.TRUE);
        gtk.gtk_box_append(box, c.cast(c.GtkWidget, entry));

        const extras = c.cast(c.GtkBox, gtk.gtk_box_new(.vertical, spacing));
        gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, extras), extras_class);
        gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, extras), c.FALSE);
        gtk.gtk_box_append(box, c.cast(c.GtkWidget, extras));

        gtk.gtk_window_set_child(window, c.cast(c.GtkWidget, box));

        self.window = window;
        self.entry = entry;
        self.box = box;
        self.extras = extras;
        self.presented = true;

        const keys = gtk.gtk_event_controller_key_new();
        gtk.gtk_event_controller_set_propagation_phase(keys, .capture);
        gtk.gtk_widget_add_controller(c.cast(c.GtkWidget, window), keys);

        const focus = gtk.gtk_event_controller_focus_new();
        gtk.gtk_widget_add_controller(c.cast(c.GtkWidget, entry), focus);

        _ = c.connect(focus, "enter", &onFocusEntered, self);
        _ = c.connect(keys, "key-pressed", &onKeyPressed, self);
        _ = c.connect(keys, "key-released", &onKeyReleased, self);
        _ = c.connect(entry, "changed", &onChanged, self);
        _ = c.connect(entry, "activate", &onActivated, self);
        _ = c.connect(window, "notify::is-active", &onActiveChanged, self);

        self.setBody(body);

        gtk.gtk_window_present(window);
        _ = gtk.gtk_widget_grab_focus(c.cast(c.GtkWidget, entry));
    }

    pub fn setText(self: *Deck, text: [:0]const u8) void {
        if (!self.presented) return;

        self.echoing = true;
        defer self.echoing = false;
        gtk.gtk_entry_buffer_set_text(gtk.gtk_entry_get_buffer(self.entry), text.ptr, -1);
    }

    pub fn selectRange(self: *Deck, start: c_int, end: c_int) void {
        if (!self.presented) return;
        gtk.gtk_editable_select_region(c.cast(c.GtkEditable, self.entry), start, end);
    }

    pub fn selectAll(self: *Deck) void {
        if (!self.presented) return;
        _ = glib.g_idle_add(&onSelectAll, self);
    }

    pub fn setBody(self: *Deck, body: ?Body) void {
        if (!self.presented) {
            if (body) |wanted| c.discard(wanted.widget());
            return;
        }

        if (self.body) |current| gtk.gtk_box_remove(self.box, current.widget());

        self.body = body;
        if (body) |wanted| gtk.gtk_box_append(self.box, wanted.widget());
        self.arrange();
    }

    pub fn attachPicker(self: *Deck, widget: *c.GtkWidget) void {
        if (!self.presented) return;

        self.picker = widget;
        gtk.gtk_widget_set_visible(widget, c.FALSE);
        gtk.gtk_box_append(self.box, widget);
        self.arrange();
    }

    pub fn showPicker(self: *Deck, shown: bool) void {
        const widget = self.picker orelse return;
        gtk.gtk_widget_set_visible(widget, if (shown) c.TRUE else c.FALSE);
    }

    pub fn setPrompt(self: *Deck, text: [:0]const u8) void {
        if (!self.presented) return;
        gtk.gtk_entry_set_placeholder_text(self.entry, text.ptr);
    }

    pub fn setAsking(self: *Deck, asking: bool) void {
        if (!self.presented) return;

        const widget = c.cast(c.GtkWidget, self.entry);
        gtk.gtk_widget_set_sensitive(widget, if (asking) c.FALSE else c.TRUE);
        if (!asking) _ = gtk.gtk_widget_grab_focus(widget);
    }

    pub fn attachContext(self: *Deck, widget: *c.GtkWidget) void {
        if (!self.presented) return;

        self.context = widget;
        gtk.gtk_widget_set_visible(widget, c.FALSE);
        gtk.gtk_box_append(self.box, widget);
        self.arrange();
    }

    pub fn takeFocus(self: *Deck, widget: *c.GtkWidget) void {
        if (!self.presented or self.returning != null) return;

        self.returning = gtk.gtk_window_get_focus(self.window);
        _ = gtk.gtk_widget_grab_focus(widget);
    }

    pub fn giveFocus(self: *Deck) void {
        if (!self.presented) return;

        const previous = self.returning orelse return;
        self.returning = null;

        self.restoring = true;
        defer self.restoring = false;

        const entry = c.cast(c.GtkWidget, self.entry);
        if (previous == entry or gtk.gtk_widget_is_ancestor(previous, entry) != c.FALSE) {
            _ = gtk.gtk_entry_grab_focus_without_selecting(self.entry);
            return;
        }
        _ = gtk.gtk_widget_grab_focus(previous);
    }

    fn arrange(self: *Deck) void {
        var previous: *c.GtkWidget = c.cast(c.GtkWidget, self.entry);

        if (self.picker) |widget| {
            gtk.gtk_box_reorder_child_after(self.box, widget, previous);
            previous = widget;
        }
        if (self.body) |body| {
            gtk.gtk_box_reorder_child_after(self.box, body.widget(), previous);
            previous = body.widget();
        }
        if (self.context) |widget| {
            gtk.gtk_box_reorder_child_after(self.box, widget, previous);
            previous = widget;
        }
        gtk.gtk_box_reorder_child_after(self.box, self.extrasWidget(), previous);
    }

    fn extrasWidget(self: *Deck) *c.GtkWidget {
        return c.cast(c.GtkWidget, self.extras);
    }

    pub fn disableInput(self: *Deck) void {
        if (!self.presented or self.busy) return;
        self.busy = true;

        gtk.gtk_widget_set_sensitive(c.cast(c.GtkWidget, self.entry), c.FALSE);
        if (self.body) |found| gtk.gtk_widget_set_sensitive(found.widget(), c.FALSE);
        if (self.picker) |found| gtk.gtk_widget_set_sensitive(found, c.FALSE);
        if (self.context) |found| gtk.gtk_widget_set_sensitive(found, c.FALSE);
    }

    pub fn conceal(self: *Deck) void {
        if (!self.presented) return;

        self.suspended = true;
        gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, self.window), c.FALSE);
    }

    pub fn reveal(self: *Deck) void {
        if (!self.presented) return;

        self.suspended = false;
        self.was_active = false;
        gtk.gtk_window_present(self.window);
        _ = gtk.gtk_widget_grab_focus(c.cast(c.GtkWidget, self.entry));
    }

    pub fn close(self: *Deck) void {
        if (self.closing) return;
        self.closing = true;
        glib.g_application_quit(c.cast(c.GApplication, self.app));
    }

    fn navigate(self: *Deck, body: Body, delta: i32) void {
        self.navigating = true;
        defer self.navigating = false;
        body.move(delta);
    }

    pub fn typed(self: *Deck) []const u8 {
        if (!self.presented) return "";
        return std.mem.span(gtk.gtk_entry_buffer_get_text(gtk.gtk_entry_get_buffer(self.entry)));
    }
};

fn deckFrom(data: c.gpointer) *Deck {
    return @ptrCast(@alignCast(data.?));
}

fn onChanged(_: *c.GtkEditable, data: c.gpointer) callconv(.c) void {
    const self = deckFrom(data);
    if (self.closing or self.echoing) return;
    self.changed.call(.{self.typed()});
}

fn onFocusEntered(_: *c.GtkEventControllerFocus, data: c.gpointer) callconv(.c) void {
    const self = deckFrom(data);
    if (self.restoring) return;
    self.selectAll();
}

fn onKeyReleased(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    _: c.GdkModifierType,
    data: c.gpointer,
) callconv(.c) void {
    const self = deckFrom(data);
    if (self.held.matches(keyval) and !self.closing) {
        if (self.holding) |found| found.call(.{false});
    }
}

fn onSelectAll(data: c.gpointer) callconv(.c) c.gboolean {
    const self = deckFrom(data);
    if (!self.closing) self.selectRange(0, -1);
    return c.source_remove;
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
    state: c.GdkModifierType,
    data: c.gpointer,
) callconv(.c) c.gboolean {
    const self = deckFrom(data);

    if (self.busy) {
        if (keyval == c.key_Escape) self.close();
        return c.TRUE;
    }

    if (self.held.matches(keyval)) {
        if (!self.closing) {
            if (self.holding) |found| found.call(.{true});
        }
        return c.FALSE;
    }

    if (self.keys) |found| {
        if (found.call(.{ keyval, state })) return c.TRUE;
    }

    switch (keyval) {
        c.key_Escape => {
            self.close();
            return c.TRUE;
        },
        c.key_Down, c.key_KP_Down => {
            const body = self.body orelse return c.FALSE;
            self.navigate(body, 1);
            return c.TRUE;
        },
        c.key_Up, c.key_KP_Up => {
            const body = self.body orelse return c.FALSE;
            self.navigate(body, -1);
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
    if (self.suspended) return;

    if (gtk.gtk_window_is_active(window) != c.FALSE) {
        self.was_active = true;
        return;
    }
    if (self.was_active) self.close();
}

fn applyStyle() void {
    const display = gdk.gdk_display_get_default() orelse return;

    const provider = gtk.gtk_css_provider_new();
    defer glib.g_object_unref(provider);

    gtk.gtk_css_provider_load_from_string(provider, css);
    gtk.gtk_style_context_add_provider_for_display(
        display,
        c.cast(c.GtkStyleProvider, provider),
        c.style_provider_priority_application,
    );
}
