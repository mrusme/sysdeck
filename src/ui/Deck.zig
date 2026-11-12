const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const Answer = @import("Answer.zig");
const Arguments = @import("Arguments.zig");
const Backdrop = @import("Backdrop.zig");
const Blur = @import("Blur.zig");
const Focus = @import("Focus.zig");
const Footer = @import("Footer.zig");
const Reply = @import("Reply.zig");
const Selection = @import("Selection.zig");
const c = @import("../gtk/c.zig");
const cairo = @import("../gtk/cairo.zig");
const gdk = @import("../gtk/gdk.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const keys_mod = @import("keys.zig");
const List = @import("List.zig");
const logo = @import("logo.zig");
const style = @import("style.zig");

const Deck = @This();

const log = std.log.scoped(.deck);

const width = 720;
const border = 1;
const plain_opacity = 0.95;
const blurred_opacity = 0.74;
// At 0 GTK 4.14 attaches no buffer, hence sway never maps the window to place.
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
const arguments_class = "sysdeck-arguments";
const rule_class = "sysdeck-rule";
const context_class = "sysdeck-context";
const extras_class = "sysdeck-extras";

const spacing = 6;

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

pub const Options = struct {
    prompt: [:0]const u8,
    opacity: ?f64 = null,
    backdrop_source: ?Backdrop.Source = null,
    held: keys_mod.Held = .{ .left = c.key_Alt_L, .right = c.key_Alt_R },
};

app: *c.GtkApplication,
opacity: ?f64,
backdrop_source: ?Backdrop.Source,
held: keys_mod.Held,
window: *c.GtkWindow,
panel: *c.GtkOverlay,
tint: *c.GtkWidget,
entry: *c.GtkEntry,
arguments: Arguments,
top: *c.GtkBox,
rule: *c.GtkWidget,
box: *c.GtkBox,
extras: *c.GtkBox,
footer: Footer,
focus: Focus = .{},
changed: ?Changed = null,
keys: ?Keys = null,
holding: ?Holding = null,
selection: ?Selection = null,
blur: Blur = .{},
backdrop: ?Backdrop = null,
body: ?Body = null,
picker: ?*c.GtkWidget = null,
context: ?*c.GtkWidget = null,
placing: u8 = 0,
arguments_offered: bool = false,
echoing: bool = false,
navigating: bool = false,
was_focused: bool = false,
suspended: bool = false,
busy: bool = false,
closing: bool = false,

pub fn register(app: *c.GtkApplication) bool {
    var err: ?*c.GError = null;
    if (glib.g_application_register(c.cast(c.GApplication, app), null, &err) != c.FALSE) return true;

    defer if (err) |detail| glib.g_error_free(detail);
    log.err("cannot register the application: {s}", .{c.errorMessage(err)});
    return false;
}

pub fn create(app: *c.GtkApplication, options: Options) Deck {
    style.load(style.sheet);

    const window = c.cast(c.GtkWindow, gtk.gtk_application_window_new(app));
    gtk.gtk_window_set_title(window, "sysdeck");
    gtk.gtk_window_set_decorated(window, c.FALSE);
    gtk.gtk_window_set_resizable(window, c.FALSE);
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, window), window_class);

    const panel = c.cast(c.GtkOverlay, gtk.gtk_overlay_new());
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, panel), panel_class);
    gtk.gtk_widget_set_overflow(c.cast(c.GtkWidget, panel), .hidden);

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

    const inputs = c.cast(c.GtkBox, gtk.gtk_box_new(.horizontal, 0));
    gtk.gtk_box_set_homogeneous(inputs, c.TRUE);
    gtk.gtk_widget_set_hexpand(c.cast(c.GtkWidget, inputs), c.TRUE);
    gtk.gtk_box_append(top, c.cast(c.GtkWidget, inputs));

    const entry = c.cast(c.GtkEntry, gtk.gtk_entry_new());
    gtk.gtk_entry_set_placeholder_text(entry, options.prompt);
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, entry), input_class);
    logo.attach(entry);
    gtk.gtk_widget_set_hexpand(c.cast(c.GtkWidget, entry), c.TRUE);
    gtk.gtk_box_append(inputs, c.cast(c.GtkWidget, entry));

    const arguments: Arguments = .create();
    gtk.gtk_widget_add_css_class(arguments.widget(), input_class);
    gtk.gtk_widget_add_css_class(arguments.widget(), arguments_class);
    gtk.gtk_box_append(inputs, arguments.widget());

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

    const footer: Footer = .create(options.held.label());
    gtk.gtk_box_append(box, footer.widget());

    gtk.gtk_window_set_child(window, c.cast(c.GtkWidget, panel));

    return .{
        .app = app,
        .opacity = options.opacity,
        .backdrop_source = options.backdrop_source,
        .held = options.held,
        .window = window,
        .panel = panel,
        .tint = tint,
        .entry = entry,
        .arguments = arguments,
        .top = top,
        .rule = rule,
        .box = box,
        .extras = extras,
        .footer = footer,
    };
}

pub fn present(self: *Deck, changed: Changed, body: ?Body) void {
    self.changed = changed;
    self.blur.open();
    if (self.backdrop_source) |source| {
        if (self.blur.blurred()) {
            log.debug("the compositor blurs, so [window] static_blur is not needed", .{});
        } else {
            self.backdrop = Backdrop.take(source);
        }
    }

    const window = c.cast(c.GtkWidget, self.window);
    if (self.selection) |*found| found.install(window);
    if (self.backdrop) |*found| {
        const picture = found.widget();
        gtk.gtk_overlay_add_overlay(self.panel, picture);
        gtk.gtk_widget_insert_after(picture, c.cast(c.GtkWidget, self.panel), null);
    }

    const keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(keys, .capture);
    gtk.gtk_widget_add_controller(window, keys);
    self.focus.install();

    _ = c.connect(keys, "key-pressed", &onKeyPressed, self);
    _ = c.connect(keys, "key-released", &onKeyReleased, self);
    _ = c.connect(self.entry, "changed", &onChanged, self);
    _ = c.connect(self.entry, "activate", &onActivated, self);
    _ = c.connect(self.window, "close-request", &onCloseRequested, self);

    self.setBody(body);

    gtk.gtk_widget_realize(window);
    const surface = gtk.gtk_native_get_surface(c.cast(c.GtkNative, self.window));

    if (surface) |found| self.blur.attach(found);
    if (self.blur.path == .gtk) style.load(style.blurred);
    gtk.gtk_widget_set_opacity(self.tint, self.tintOpacity());
    if (self.backdrop != null) gtk.gtk_widget_set_opacity(c.cast(c.GtkWidget, self.panel), waiting_opacity);

    if (surface) |found| {
        _ = c.connect(found, "layout", &onLayout, self);
        _ = c.connect(found, "notify::state", &onStateChanged, self);
    }

    gtk.gtk_window_present(self.window);
    _ = gtk.gtk_widget_grab_focus(c.cast(c.GtkWidget, self.entry));
}

pub fn setText(self: *Deck, text: [:0]const u8) void {
    self.echoing = true;
    defer self.echoing = false;
    gtk.gtk_entry_buffer_set_text(gtk.gtk_entry_get_buffer(self.entry), text.ptr, -1);
}

pub fn setQuery(self: *Deck, text: [:0]const u8) void {
    self.setText(text);
    _ = gtk.gtk_widget_grab_focus(c.cast(c.GtkWidget, self.entry));
    self.selectAll();
}

pub fn selectRange(self: *Deck, start: c_int, end: c_int) void {
    gtk.gtk_editable_select_region(c.cast(c.GtkEditable, self.entry), start, end);
}

pub fn selectAll(self: *Deck) void {
    _ = glib.g_idle_add(&onSelectAll, self);
}

pub fn setBody(self: *Deck, body: ?Body) void {
    if (self.body) |current| gtk.gtk_box_remove(self.box, current.widget());

    self.body = body;
    if (body) |wanted| gtk.gtk_box_append(self.box, wanted.widget());
    gtk.gtk_widget_set_visible(self.rule, if (body != null) c.TRUE else c.FALSE);
    self.arrange();
}

pub fn setMode(self: *Deck, label: [:0]const u8) void {
    self.footer.setMode(label);
}

pub fn setAction(self: *Deck, word: [:0]const u8) void {
    self.footer.setAction(word);
}

pub fn offerArguments(self: *Deck, offered: bool) void {
    self.arguments_offered = offered;
    if (!offered) self.closeArguments();
    self.showArgumentHint();
}

pub fn openArguments(self: *Deck) bool {
    if (!self.arguments_offered) return false;

    self.arguments.open();
    self.showArgumentHint();
    return true;
}

pub fn argumentsText(self: *Deck) []const u8 {
    return self.arguments.text();
}

fn closeArguments(self: *Deck) void {
    if (!self.arguments.isOpen()) return;

    const focused = self.arguments.holds(gtk.gtk_window_get_focus(self.window));
    self.arguments.close();
    self.showArgumentHint();
    if (focused) _ = gtk.gtk_widget_grab_focus(c.cast(c.GtkWidget, self.entry));
}

fn showArgumentHint(self: *Deck) void {
    self.footer.setArguments(self.arguments_offered and !self.arguments.isOpen());
}

pub fn setContext(self: *Deck, shown: bool) void {
    self.footer.setContext(shown);
}

pub fn attachPicker(self: *Deck, widget: *c.GtkWidget) void {
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
    gtk.gtk_entry_set_placeholder_text(self.entry, text.ptr);
}

pub fn setAsking(self: *Deck, asking: bool) void {
    const widget = c.cast(c.GtkWidget, self.entry);
    gtk.gtk_widget_set_sensitive(widget, if (asking) c.FALSE else c.TRUE);
    if (!asking) _ = gtk.gtk_widget_grab_focus(widget);
}

pub fn attachContext(self: *Deck, widget: *c.GtkWidget) void {
    self.context = widget;
    gtk.gtk_widget_add_css_class(widget, context_class);
    gtk.gtk_widget_set_visible(widget, c.FALSE);
    gtk.gtk_box_append(self.box, widget);
    self.arrange();
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
    if (self.busy) return;
    self.busy = true;

    gtk.gtk_window_set_focus(self.window, null);
    gtk.gtk_widget_set_sensitive(c.cast(c.GtkWidget, self.entry), c.FALSE);
    gtk.gtk_widget_set_sensitive(self.arguments.widget(), c.FALSE);
    if (self.body) |found| gtk.gtk_widget_set_sensitive(found.widget(), c.FALSE);
    if (self.picker) |found| gtk.gtk_widget_set_sensitive(found, c.FALSE);
    if (self.context) |found| gtk.gtk_widget_set_sensitive(found, c.FALSE);
}

pub fn enableInput(self: *Deck) void {
    if (!self.busy) return;
    self.busy = false;

    gtk.gtk_widget_set_sensitive(c.cast(c.GtkWidget, self.entry), c.TRUE);
    gtk.gtk_widget_set_sensitive(self.arguments.widget(), c.TRUE);
    if (self.body) |found| gtk.gtk_widget_set_sensitive(found.widget(), c.TRUE);
    if (self.picker) |found| gtk.gtk_widget_set_sensitive(found, c.TRUE);
    if (self.context) |found| gtk.gtk_widget_set_sensitive(found, c.TRUE);
    _ = gtk.gtk_entry_grab_focus_without_selecting(self.entry);
}

pub fn conceal(self: *Deck) void {
    self.suspended = true;
    gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, self.window), c.FALSE);
    if (gdk.gdk_display_get_default()) |display| gdk.gdk_display_flush(display);
}

pub fn reveal(self: *Deck) void {
    if (self.closing) return;

    self.suspended = false;
    self.was_focused = false;
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
    self.conceal();
    glib.g_application_quit(c.cast(c.GApplication, self.app));
}

pub fn dispose(self: *Deck) void {
    self.closing = true;
    self.body = null;
    self.picker = null;
    self.context = null;
    self.blur.close();
    if (self.selection) |*found| found.release();
    gtk.gtk_window_destroy(self.window);
}

fn navigate(self: *Deck, body: Body, delta: i32) void {
    self.navigating = true;
    defer self.navigating = false;
    body.move(delta);
}

pub fn typed(self: *Deck) []const u8 {
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
    if (self.closing) return;

    const body = self.body orelse return;
    body.accept();
}

fn onCloseRequested(_: *c.GtkWindow, data: c.gpointer) callconv(.c) c.gboolean {
    deckFrom(data).close();
    return c.TRUE;
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    state: c.GdkModifierType,
    data: c.gpointer,
) callconv(.c) c.gboolean {
    const self = deckFrom(data);
    if (self.closing) return c.TRUE;

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

    if (self.arguments.holds(gtk.gtk_window_get_focus(self.window))) {
        switch (keyval) {
            c.key_Escape => {
                self.closeArguments();
                return c.TRUE;
            },
            c.key_BackSpace => if (self.arguments.text().len == 0) {
                self.closeArguments();
                return c.TRUE;
            },
            else => {},
        }
    }

    if (self.keys) |found| {
        if (found.call(.{ keyval, state })) return c.TRUE;
    }

    switch (keyval) {
        c.key_Tab, c.key_ISO_Left_Tab => return c.TRUE,
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

fn onStateChanged(surface: *c.GdkSurface, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const self = deckFrom(data);
    if (self.suspended) return;

    const state = gdk.gdk_toplevel_get_state(c.cast(c.GdkToplevel, surface));
    if (state & c.toplevel_state_focused != 0) {
        self.was_focused = true;
        return;
    }
    if (self.was_focused) self.close();
}

fn onLayout(surface: *c.GdkSurface, _: c_int, _: c_int, data: c.gpointer) callconv(.c) void {
    const self = deckFrom(data);
    if (self.closing) return;

    const area = self.panelArea() orelse return;
    const region = cairo.cairo_region_create_rectangle(&area);
    defer cairo.cairo_region_destroy(region);

    gdk.gdk_surface_set_input_region(surface, region);
    self.blur.shape(area, style.radius);

    if (self.backdrop != null and self.placing == 0) {
        self.placing = 1;
        _ = glib.g_idle_add(&onPlace, self);
    }
}

fn onPlace(data: c.gpointer) callconv(.c) c.gboolean {
    const self = deckFrom(data);
    if (!self.closing) self.placeBackdrop();
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
