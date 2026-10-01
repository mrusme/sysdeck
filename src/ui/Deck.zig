const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const Answer = @import("Answer.zig");
const Backdrop = @import("Backdrop.zig");
const Blur = @import("Blur.zig");
const Footer = @import("Footer.zig");
const Reply = @import("Reply.zig");
const c = @import("../gtk/c.zig");
const cairo = @import("../gtk/cairo.zig");
const gdk = @import("../gtk/gdk.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const keys_mod = @import("keys.zig");
const List = @import("List.zig");

const Deck = @This();

const log = std.log.scoped(.deck);

const width = 720;
const border = 1;
const radius = 14;
const plain_opacity = 0.95;
const blurred_opacity = 0.74;
// At 0 GTK 4.12 attaches no buffer, hence sway never maps the window to place.
const waiting_opacity = 0.01;
const placing_tries = 10;
const placing_interval_ms = 10;

const window_class = "sysdeck";
const panel_class = "sysdeck-panel";
const tint_class = "sysdeck-tint";
const theme_class = "background";
const deck_class = "sysdeck-deck";
const top_class = "sysdeck-top";
const input_class = "sysdeck-input";
const rule_class = "sysdeck-rule";
const context_class = "sysdeck-context";
const extras_class = "sysdeck-extras";

const spacing = 6;

const css =
    \\window.sysdeck {
    \\  background: transparent;
    \\}
    \\.sysdeck-panel {
    \\  margin: 28px 48px 64px 48px;
    \\  border: 1px solid alpha(currentColor, 0.16);
    \\
++ std.fmt.comptimePrint("  border-radius: {d}px;\n", .{radius}) ++
    \\  box-shadow: 0 16px 36px alpha(black, 0.45);
    \\}
    \\.sysdeck-top {
    \\  min-height: 58px;
    \\  padding: 0 16px;
    \\}
    \\.sysdeck-input {
    \\  background: transparent;
    \\  border: none;
    \\  box-shadow: none;
    \\  outline: none;
    \\  padding: 0;
    \\  font-size: 1.4em;
    \\}
    \\.sysdeck-rule {
    \\  background: alpha(currentColor, 0.1);
    \\  min-height: 1px;
    \\}
    \\.sysdeck-deck scrolledwindow,
    \\.sysdeck-deck list,
    \\.sysdeck-deck notebook,
    \\.sysdeck-deck notebook > header,
    \\.sysdeck-deck notebook > stack,
    \\.sysdeck-deck textview,
    \\.sysdeck-deck textview text {
    \\  background: transparent;
    \\}
    \\.sysdeck-list {
    \\  margin: 6px 0 8px 0;
    \\}
    \\.sysdeck-context {
    \\  border-top: 1px solid alpha(currentColor, 0.1);
    \\  margin-top: 0;
    \\  padding-top: 6px;
    \\}
    \\.sysdeck-deck row {
    \\  border-radius: 9px;
    \\  margin: 0 8px;
    \\}
    \\.sysdeck-deck row:not(:selected) {
    \\  background: transparent;
    \\}
    \\.sysdeck-deck row:hover:not(:selected) {
    \\  background: alpha(currentColor, 0.06);
    \\}
    \\.sysdeck-extras {
    \\  border-top: 1px solid alpha(currentColor, 0.1);
    \\  padding: 8px;
    \\}
    \\.sysdeck-footer {
    \\  min-height: 34px;
    \\  padding: 0 14px 0 16px;
    \\  font-size: 0.85em;
    \\}
    \\.sysdeck-footer label,
    \\.sysdeck-input placeholder {
    \\  text-shadow: 0 1px 1px black;
    \\}
    \\.sysdeck-hint,
    \\.sysdeck-input placeholder {
    \\  opacity: 0.6;
    \\}
    \\.sysdeck-keycap {
    \\  background: alpha(currentColor, 0.12);
    \\  border-radius: 5px;
    \\  padding: 0 6px;
    \\  min-width: 10px;
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
    \\  padding: 8px 16px 10px 16px;
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
    \\.sysdeck-reply {
    \\  font-size: 0.95em;
    \\  margin: 8px 8px 8px 16px;
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

const blur_css =
    \\.sysdeck-panel {
    \\  backdrop-filter: blur(16px);
    \\}
;

pub const Body = union(enum) {
    list: *List,
    answer: *Answer,
    reply: *Reply,

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

app: *c.GtkApplication,
prompt: [:0]const u8,
opacity: ?f64 = null,
backdrop_source: ?Backdrop.Source = null,
changed: ?Changed = null,
keys: ?Keys = null,
holding: ?Holding = null,
held: keys_mod.Held = .{ .left = c.key_Alt_L, .right = c.key_Alt_R },
echoing: bool = false,
restoring: bool = false,
navigating: bool = false,
window: *c.GtkWindow = undefined,
panel: *c.GtkOverlay = undefined,
tint: *c.GtkWidget = undefined,
blur: Blur = .{},
backdrop: ?Backdrop = null,
placing: u8 = 0,
footer: Footer = undefined,
mode_label: [:0]const u8 = "",
action_word: [:0]const u8 = "",
offered: bool = false,
entry: *c.GtkEntry = undefined,
top: *c.GtkBox = undefined,
rule: *c.GtkWidget = undefined,
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
    loadStyle(css);

    self.changed = changed;
    self.blur.open();
    if (self.backdrop_source) |source| {
        if (self.blur.blurred()) {
            log.debug("the compositor blurs, so [window] static_blur is not needed", .{});
        } else {
            self.backdrop = Backdrop.take(source);
        }
    }

    const window = c.cast(c.GtkWindow, gtk.gtk_application_window_new(self.app));
    gtk.gtk_window_set_title(window, "sysdeck");
    gtk.gtk_window_set_decorated(window, c.FALSE);
    gtk.gtk_window_set_resizable(window, c.FALSE);
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, window), window_class);

    const panel = c.cast(c.GtkOverlay, gtk.gtk_overlay_new());
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, panel), panel_class);
    gtk.gtk_widget_set_overflow(c.cast(c.GtkWidget, panel), .hidden);
    if (self.backdrop) |*found| gtk.gtk_overlay_add_overlay(panel, found.widget());

    const tint = gtk.gtk_box_new(.vertical, 0);
    gtk.gtk_widget_add_css_class(tint, tint_class);
    gtk.gtk_widget_add_css_class(tint, theme_class);
    gtk.gtk_overlay_add_overlay(panel, tint);

    const box = c.cast(c.GtkBox, gtk.gtk_box_new(.vertical, 0));
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, box), deck_class);
    gtk.gtk_widget_set_size_request(c.cast(c.GtkWidget, box), width - 2 * border, -1);
    gtk.gtk_overlay_add_overlay(panel, c.cast(c.GtkWidget, box));
    gtk.gtk_overlay_set_measure_overlay(panel, c.cast(c.GtkWidget, box), c.TRUE);

    const top = c.cast(c.GtkBox, gtk.gtk_box_new(.horizontal, spacing));
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, top), top_class);
    gtk.gtk_box_append(box, c.cast(c.GtkWidget, top));

    const entry = c.cast(c.GtkEntry, gtk.gtk_entry_new());
    gtk.gtk_entry_set_placeholder_text(entry, self.prompt);
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, entry), input_class);
    gtk.gtk_widget_set_hexpand(c.cast(c.GtkWidget, entry), c.TRUE);
    gtk.gtk_box_append(top, c.cast(c.GtkWidget, entry));

    const rule = gtk.gtk_separator_new(.horizontal);
    gtk.gtk_widget_add_css_class(rule, rule_class);
    gtk.gtk_widget_set_visible(rule, c.FALSE);
    gtk.gtk_box_append(box, rule);

    const extras = c.cast(c.GtkBox, gtk.gtk_box_new(.vertical, spacing));
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, extras), extras_class);
    gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, extras), c.FALSE);
    gtk.gtk_box_append(box, c.cast(c.GtkWidget, extras));

    const end = gtk.gtk_separator_new(.horizontal);
    gtk.gtk_widget_add_css_class(end, rule_class);
    gtk.gtk_box_append(box, end);

    const footer: Footer = .create(self.held.label());
    footer.setMode(self.mode_label);
    footer.setAction(self.action_word);
    footer.setContext(self.offered);
    gtk.gtk_box_append(box, footer.widget());

    gtk.gtk_window_set_child(window, c.cast(c.GtkWidget, panel));

    self.window = window;
    self.panel = panel;
    self.tint = tint;
    self.entry = entry;
    self.top = top;
    self.rule = rule;
    self.box = box;
    self.extras = extras;
    self.footer = footer;
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

    gtk.gtk_widget_realize(c.cast(c.GtkWidget, window));
    const surface = gtk.gtk_native_get_surface(c.cast(c.GtkNative, window));

    if (surface) |found| self.blur.attach(found);
    if (self.blur.path == .gtk) loadStyle(blur_css);
    gtk.gtk_widget_set_opacity(tint, self.tintOpacity());
    if (self.backdrop != null) gtk.gtk_widget_set_opacity(c.cast(c.GtkWidget, panel), waiting_opacity);

    if (surface) |found| _ = c.connect(found, "layout", &onLayout, self);

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
    gtk.gtk_widget_set_visible(self.rule, if (body != null) c.TRUE else c.FALSE);
    self.arrange();
}

pub fn setMode(self: *Deck, label: [:0]const u8) void {
    self.mode_label = label;
    if (self.presented) self.footer.setMode(label);
}

pub fn setAction(self: *Deck, word: [:0]const u8) void {
    self.action_word = word;
    if (self.presented) self.footer.setAction(word);
}

pub fn setContext(self: *Deck, shown: bool) void {
    self.offered = shown;
    if (self.presented) self.footer.setContext(shown);
}

pub fn attachPicker(self: *Deck, widget: *c.GtkWidget) void {
    if (!self.presented) return;

    self.picker = widget;
    gtk.gtk_widget_set_visible(widget, c.FALSE);
    gtk.gtk_widget_set_valign(widget, .center);
    gtk.gtk_box_append(self.top, widget);
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
    gtk.gtk_widget_add_css_class(widget, context_class);
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
    var previous: *c.GtkWidget = self.rule;

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
    if (self.backdrop != null) {
        self.placing = 0;
        gtk.gtk_widget_set_opacity(c.cast(c.GtkWidget, self.panel), waiting_opacity);
    }
    gtk.gtk_window_present(self.window);
    _ = gtk.gtk_widget_grab_focus(c.cast(c.GtkWidget, self.entry));
}

pub fn close(self: *Deck) void {
    if (self.closing) return;
    self.closing = true;
    glib.g_application_quit(c.cast(c.GApplication, self.app));
}

pub fn dispose(self: *Deck) void {
    if (!self.presented) return;

    self.presented = false;
    self.closing = true;
    self.body = null;
    self.picker = null;
    self.context = null;
    self.blur.close();
    gtk.gtk_window_destroy(self.window);
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

fn deckFrom(data: c.gpointer) *Deck {
    return @ptrCast(@alignCast(data.?));
}

fn onChanged(_: *c.GtkEditable, data: c.gpointer) callconv(.c) void {
    const self = deckFrom(data);
    if (self.closing or self.echoing) return;

    const changed = self.changed orelse return;
    changed.call(.{self.typed()});
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

fn onLayout(surface: *c.GdkSurface, _: c_int, _: c_int, data: c.gpointer) callconv(.c) void {
    const self = deckFrom(data);
    if (!self.presented) return;

    const area = self.panelArea() orelse return;
    const region = cairo.cairo_region_create_rectangle(&area);
    defer cairo.cairo_region_destroy(region);

    gdk.gdk_surface_set_input_region(surface, region);
    self.blur.shape(area, radius);

    if (self.backdrop != null and self.placing == 0) {
        self.placing = 1;
        _ = glib.g_idle_add(&onPlace, self);
    }
}

fn onPlace(data: c.gpointer) callconv(.c) c.gboolean {
    const self = deckFrom(data);
    if (self.presented) self.placeBackdrop();
    return c.source_remove;
}

fn placeBackdrop(self: *Deck) void {
    const found = if (self.backdrop) |*backdrop| backdrop else return;
    if (gdk.gdk_display_get_default()) |display| gdk.gdk_display_flush(display);

    const origin = self.surfaceBounds(c.cast(c.GtkWidget, found.fixed));
    const placement: Backdrop.Placement = if (origin) |bounds| found.place(bounds.x, bounds.y) else .missing;

    switch (placement) {
        .placed => return self.showPanel(),
        .missing => if (self.placing < placing_tries) {
            self.placing += 1;
            _ = glib.g_timeout_add(placing_interval_ms, &onPlace, self);
            return;
        } else {
            log.warn(
                "sway shows no window of this process after {d} tries, so the window has no blurred background",
                .{placing_tries},
            );
        },
        .failed => {},
    }

    found.hide();
    self.backdrop = null;
    gtk.gtk_widget_set_opacity(self.tint, self.tintOpacity());
    self.showPanel();
}

fn showPanel(self: *Deck) void {
    gtk.gtk_widget_set_opacity(c.cast(c.GtkWidget, self.panel), 1);
}

const Bounds = struct { x: f64, y: f64, width: f64, height: f64 };

fn surfaceBounds(self: *Deck, widget: *c.GtkWidget) ?Bounds {
    var bounds: c.graphene_rect_t = undefined;
    const found = gtk.gtk_widget_compute_bounds(widget, c.cast(c.GtkWidget, self.window), &bounds);
    if (found == c.FALSE) return null;

    var x: f64 = 0;
    var y: f64 = 0;
    gtk.gtk_native_get_surface_transform(c.cast(c.GtkNative, self.window), &x, &y);
    return .{ .x = bounds.x + x, .y = bounds.y + y, .width = bounds.width, .height = bounds.height };
}

fn tintOpacity(self: *const Deck) f64 {
    if (self.opacity) |wanted| return wanted;
    return if (self.blur.blurred() or self.backdrop != null) blurred_opacity else plain_opacity;
}

fn panelArea(self: *Deck) ?c.cairo_rectangle_int_t {
    const bounds = self.surfaceBounds(c.cast(c.GtkWidget, self.panel)) orelse return null;
    if (bounds.width <= 0 or bounds.height <= 0) return null;

    const left = @floor(bounds.x);
    const top = @floor(bounds.y);
    return .{
        .x = @intFromFloat(left),
        .y = @intFromFloat(top),
        .width = @intFromFloat(@ceil(bounds.x + bounds.width) - left),
        .height = @intFromFloat(@ceil(bounds.y + bounds.height) - top),
    };
}

fn loadStyle(text: [*:0]const u8) void {
    const display = gdk.gdk_display_get_default() orelse return;

    const provider = gtk.gtk_css_provider_new();
    defer glib.g_object_unref(provider);

    gtk.gtk_css_provider_load_from_string(provider, text);
    gtk.gtk_style_context_add_provider_for_display(
        display,
        c.cast(c.GtkStyleProvider, provider),
        c.style_provider_priority_application,
    );
}

const testing = std.testing;

test "the stylesheet names no color, because a theme that lacks the name draws nothing" {
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, css, '@'));
}
