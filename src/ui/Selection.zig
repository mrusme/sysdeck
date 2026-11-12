const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");

const Selection = @This();

const log = std.log.scoped(.selection);

pub const Handler = Callback(fn (text: [:0]const u8) void);

const group_name = "selection";
const menu_action = group_name ++ ".menu";
const copy_action = group_name ++ ".copy";
const search_action = group_name ++ ".search";
const menu_keys = "Menu|<Shift>F10";
const request_type: *const c.GVariantType = @ptrCast("(sii)");

copied: Handler,
searched: Handler,
offered: ?*c.GVariant = null,
copy: ?*c.GSimpleAction = null,
search: ?*c.GSimpleAction = null,
popover: ?*c.GtkWidget = null,

pub fn install(self: *Selection, window: *c.GtkWidget) void {
    const group = self.build();
    defer glib.g_object_unref(group);
    gtk.gtk_widget_insert_action_group(window, group_name, c.cast(c.GActionGroup, group));

    const menu = gio.g_menu_new();
    defer glib.g_object_unref(menu);
    gio.g_menu_append(menu, "Copy", copy_action);
    gio.g_menu_append(menu, "Search", search_action);

    const popover = gtk.gtk_popover_menu_new_from_model(c.cast(c.GMenuModel, menu));
    gtk.gtk_popover_set_has_arrow(c.cast(c.GtkPopover, popover), c.FALSE);
    gtk.gtk_popover_set_position(c.cast(c.GtkPopover, popover), .bottom);
    gtk.gtk_widget_set_halign(popover, .start);
    gtk.gtk_widget_set_parent(popover, window);
    self.popover = popover;
}

pub fn release(self: *Selection) void {
    if (self.popover) |found| gtk.gtk_widget_unparent(found);
    self.popover = null;
    self.forget();
}

pub fn attach(view: *c.GtkTextView) void {
    const widget = c.cast(c.GtkWidget, view);

    const click = gtk.gtk_gesture_click_new();
    gtk.gtk_gesture_single_set_button(c.cast(c.GtkGestureSingle, click), c.button_secondary);
    gtk.gtk_event_controller_set_propagation_phase(c.cast(c.GtkEventController, click), .capture);
    gtk.gtk_widget_add_controller(widget, c.cast(c.GtkEventController, click));
    _ = c.connect(click, "pressed", &onPressed, view);

    const keys = gtk.gtk_shortcut_controller_new();
    const shortcut = gtk.gtk_shortcut_new(
        gtk.gtk_shortcut_trigger_parse_string(menu_keys),
        gtk.gtk_callback_action_new(&onMenuKey, null, null),
    );
    gtk.gtk_shortcut_controller_add_shortcut(c.cast(c.GtkShortcutController, keys), shortcut);
    gtk.gtk_event_controller_set_propagation_phase(keys, .capture);
    gtk.gtk_widget_add_controller(widget, keys);
}

fn build(self: *Selection) *c.GSimpleActionGroup {
    const group = gio.g_simple_action_group_new();
    _ = self.add(group, "menu", request_type, &onMenu);
    self.copy = self.add(group, "copy", null, &onCopy);
    self.search = self.add(group, "search", null, &onSearch);
    self.enable(false);
    return group;
}

fn add(
    self: *Selection,
    group: *c.GSimpleActionGroup,
    name: [*:0]const u8,
    parameter: ?*const c.GVariantType,
    handler: *const fn (*c.GSimpleAction, ?*c.GVariant, c.gpointer) callconv(.c) void,
) *c.GSimpleAction {
    const action = gio.g_simple_action_new(name, parameter);
    defer glib.g_object_unref(action);

    _ = c.connect(action, "activate", handler, self);
    gio.g_action_map_add_action(c.cast(c.GActionMap, group), c.cast(c.GAction, action));
    return action;
}

fn forget(self: *Selection) void {
    if (self.offered) |found| glib.g_variant_unref(found);
    self.offered = null;
}

fn enable(self: *Selection, allowed: bool) void {
    const flag = if (allowed) c.TRUE else c.FALSE;
    if (self.copy) |found| gio.g_simple_action_set_enabled(found, flag);
    if (self.search) |found| gio.g_simple_action_set_enabled(found, flag);
}

fn text(self: *const Selection) ?[:0]const u8 {
    const found = self.offered orelse return null;

    var length: usize = 0;
    const bytes = glib.g_variant_get_string(found, &length);
    return bytes[0..length :0];
}

fn intAt(tuple: *c.GVariant, index: usize) c_int {
    const child = glib.g_variant_get_child_value(tuple, index);
    defer glib.g_variant_unref(child);
    return glib.g_variant_get_int32(child);
}

fn request(view: *c.GtkTextView, x: f64, y: f64) void {
    const widget = c.cast(c.GtkWidget, view);
    const root = c.cast(c.GtkWidget, gtk.gtk_widget_get_root(widget) orelse return);

    var point: c.graphene_point_t = undefined;
    const from: c.graphene_point_t = .{ .x = @floatCast(x), .y = @floatCast(y) };
    if (gtk.gtk_widget_compute_point(widget, root, &from, &point) == c.FALSE) return;

    const selected = selectedText(view);
    defer if (selected) |found| glib.g_free(found);

    const chosen = glib.g_variant_new_string(selected orelse "") orelse return;
    const parts = [_]*c.GVariant{
        chosen,
        glib.g_variant_new_int32(@intFromFloat(point.x)),
        glib.g_variant_new_int32(@intFromFloat(point.y)),
    };
    const wanted = glib.g_variant_ref_sink(glib.g_variant_new_tuple(&parts, parts.len));
    defer glib.g_variant_unref(wanted);

    if (gtk.gtk_widget_activate_action_variant(widget, menu_action, wanted) == c.FALSE) {
        log.warn("the window has no {s} action, so the text shows no menu", .{menu_action});
    }
}

fn selectedText(view: *c.GtkTextView) ?[*:0]u8 {
    const buffer = gtk.gtk_text_view_get_buffer(view);

    var start: c.GtkTextIter = .{};
    var end: c.GtkTextIter = .{};
    if (gtk.gtk_text_buffer_get_selection_bounds(buffer, &start, &end) == c.FALSE) return null;
    return gtk.gtk_text_buffer_get_text(buffer, &start, &end, c.FALSE);
}

fn caretOf(view: *c.GtkTextView) c.GdkRectangle {
    const buffer = gtk.gtk_text_view_get_buffer(view);

    var start: c.GtkTextIter = .{};
    var end: c.GtkTextIter = .{};
    if (gtk.gtk_text_buffer_get_selection_bounds(buffer, &start, &end) == c.FALSE) {
        gtk.gtk_text_buffer_get_iter_at_mark(buffer, &start, gtk.gtk_text_buffer_get_insert(buffer));
    }

    var location: c.GdkRectangle = undefined;
    gtk.gtk_text_view_get_iter_location(view, &start, &location);

    var x: c_int = 0;
    var y: c_int = 0;
    gtk.gtk_text_view_buffer_to_window_coords(view, .widget, location.x, location.y, &x, &y);
    return .{ .x = x, .y = y, .width = 1, .height = location.height };
}

fn selectionFrom(data: c.gpointer) *Selection {
    return @ptrCast(@alignCast(data.?));
}

fn onMenu(_: *c.GSimpleAction, parameter: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self = selectionFrom(data);
    const wanted = parameter orelse return;

    self.forget();
    self.offered = glib.g_variant_get_child_value(wanted, 0);
    self.enable(if (self.text()) |found| found.len > 0 else false);

    const popover = c.cast(c.GtkPopover, self.popover orelse return);
    const place: c.GdkRectangle = .{ .x = intAt(wanted, 1), .y = intAt(wanted, 2), .width = 1, .height = 1 };
    gtk.gtk_popover_set_pointing_to(popover, &place);
    gtk.gtk_popover_popup(popover);
}

fn onCopy(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self = selectionFrom(data);
    const found = self.text() orelse return;
    self.copied.call(.{found});
}

fn onSearch(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self = selectionFrom(data);
    const found = self.text() orelse return;
    self.searched.call(.{found});
}

fn onPressed(gesture: *c.GtkGesture, _: c_int, x: f64, y: f64, data: c.gpointer) callconv(.c) void {
    _ = gtk.gtk_gesture_set_state(gesture, .claimed);
    request(@ptrCast(@alignCast(data.?)), x, y);
}

fn onMenuKey(widget: *c.GtkWidget, _: ?*c.GVariant, _: c.gpointer) callconv(.c) c.gboolean {
    const view = c.cast(c.GtkTextView, widget);
    const caret = caretOf(view);
    request(view, @floatFromInt(caret.x), @floatFromInt(caret.y + caret.height));
    return c.TRUE;
}

const testing = std.testing;

const Seen = struct {
    copied: std.ArrayList(u8) = .empty,
    searched: std.ArrayList(u8) = .empty,

    fn onCopied(self: *Seen, excerpt: [:0]const u8) void {
        self.copied.appendSlice(testing.allocator, excerpt) catch {};
    }

    fn onSearched(self: *Seen, excerpt: [:0]const u8) void {
        self.searched.appendSlice(testing.allocator, excerpt) catch {};
    }

    fn deinit(self: *Seen) void {
        self.copied.deinit(testing.allocator);
        self.searched.deinit(testing.allocator);
    }
};

fn enabled(group: *c.GSimpleActionGroup, name: [*:0]const u8) bool {
    return gio.g_action_group_get_action_enabled(c.cast(c.GActionGroup, group), name) != c.FALSE;
}

fn open(group: *c.GSimpleActionGroup, excerpt: [*:0]const u8) void {
    const parts = [_]*c.GVariant{
        glib.g_variant_new_string(excerpt).?,
        glib.g_variant_new_int32(10),
        glib.g_variant_new_int32(20),
    };
    const wanted = glib.g_variant_new_tuple(&parts, parts.len);
    gio.g_action_group_activate_action(c.cast(c.GActionGroup, group), "menu", wanted);
}

test "Copy and Search stay greyed out until a selection is offered, and an empty one keeps them so" {
    var seen: Seen = .{};
    defer seen.deinit();

    var selection: Selection = .{
        .copied = .of(Seen, Seen.onCopied, &seen),
        .searched = .of(Seen, Seen.onSearched, &seen),
    };
    defer selection.release();

    const group = selection.build();
    defer glib.g_object_unref(group);

    try testing.expect(!enabled(group, "copy"));
    try testing.expect(!enabled(group, "search"));

    open(group, "");
    try testing.expect(!enabled(group, "copy"));
    try testing.expect(!enabled(group, "search"));
}

test "an offered selection enables both, and each hands it to its handler" {
    var seen: Seen = .{};
    defer seen.deinit();

    var selection: Selection = .{
        .copied = .of(Seen, Seen.onCopied, &seen),
        .searched = .of(Seen, Seen.onSearched, &seen),
    };
    defer selection.release();

    const group = selection.build();
    defer glib.g_object_unref(group);

    open(group, "line two");
    try testing.expect(enabled(group, "copy"));
    try testing.expect(enabled(group, "search"));

    gio.g_action_group_activate_action(c.cast(c.GActionGroup, group), "copy", null);
    gio.g_action_group_activate_action(c.cast(c.GActionGroup, group), "search", null);
    try testing.expectEqualStrings("line two", seen.copied.items);
    try testing.expectEqualStrings("line two", seen.searched.items);
}
