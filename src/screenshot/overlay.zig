const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const box = @import("box.zig");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const layer = @import("../gtk/layer.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.screenshot);

const window_class = "sysdeck-shot";
const wash_class = "sysdeck-shot-wash";
const frame_class = "sysdeck-shot-frame";

const border = 2;
const namespace: [*:0]const u8 = "sysdeck";

const css =
    \\window.sysdeck-shot {
    \\  background: transparent;
    \\}
    \\.sysdeck-shot-wash {
    \\  background: rgba(255, 255, 255, 0.25);
    \\}
    \\.sysdeck-shot-frame {
    \\  border: 2px solid rgb(0, 0, 0);
    \\}
;

pub const Mode = enum {
    any,
    region,
    window,
    screen,

    fn snaps(self: Mode) bool {
        return self != .region;
    }

    fn drags(self: Mode) bool {
        return self == .any or self == .region;
    }
};

pub const Picked = Callback(fn (chosen: ?box.Box) void);

const Surface = struct {
    owner: *Overlay,
    monitor: *c.GdkMonitor,
    origin: box.Box,
    window: *c.GtkWindow,
    fixed: *c.GtkFixed,
    wash: [4]*c.GtkWidget,
    frame: *c.GtkWidget,

    fn draw(self: *Surface, chosen: ?box.Box) void {
        const across = self.origin.width;
        const down = self.origin.height;

        const wanted = chosen orelse {
            self.put(self.wash[0], .{ .x = 0, .y = 0, .width = across, .height = down });
            for (self.wash[1..]) |widget| gtk.gtk_widget_set_visible(widget, c.FALSE);
            gtk.gtk_widget_set_visible(self.frame, c.FALSE);
            return;
        };

        const left = wanted.x - self.origin.x;
        const top = wanted.y - self.origin.y;

        const from_x = std.math.clamp(left, 0, across);
        const from_y = std.math.clamp(top, 0, down);
        const to_x = std.math.clamp(left + wanted.width, 0, across);
        const to_y = std.math.clamp(top + wanted.height, 0, down);

        self.put(self.wash[0], .{ .x = 0, .y = 0, .width = across, .height = from_y });
        self.put(self.wash[1], .{ .x = 0, .y = to_y, .width = across, .height = down - to_y });
        self.put(self.wash[2], .{
            .x = 0,
            .y = from_y,
            .width = from_x,
            .height = to_y - from_y,
        });
        self.put(self.wash[3], .{
            .x = to_x,
            .y = from_y,
            .width = across - to_x,
            .height = to_y - from_y,
        });

        self.put(self.frame, .{
            .x = left - border / 2,
            .y = top - border / 2,
            .width = wanted.width + border,
            .height = wanted.height + border,
        });
    }

    fn put(self: *Surface, widget: *c.GtkWidget, wanted: box.Box) void {
        if (wanted.empty()) return gtk.gtk_widget_set_visible(widget, c.FALSE);

        gtk.gtk_widget_set_size_request(widget, wanted.width, wanted.height);
        gtk.gtk_fixed_move(self.fixed, widget, @floatFromInt(wanted.x), @floatFromInt(wanted.y));
        gtk.gtk_widget_set_visible(widget, c.TRUE);
    }
};

pub const Overlay = struct {
    gpa: Allocator,
    mode: Mode,
    picked: Picked,
    boxes: []const box.Box,
    surfaces: std.ArrayList(*Surface) = .empty,
    chosen: ?box.Box = null,
    hovered: ?box.Box = null,
    dragging: bool = false,
    start_x: i32 = 0,
    start_y: i32 = 0,
    finished: bool = false,

    pub fn create(
        gpa: Allocator,
        mode: Mode,
        boxes: []const box.Box,
        picked: Picked,
    ) Allocator.Error!?*Overlay {
        if (layer.gtk_layer_is_supported() == c.FALSE) {
            log.warn("this compositor has no wlr-layer-shell, so nothing can be selected", .{});
            return null;
        }

        const self = try gpa.create(Overlay);
        errdefer gpa.destroy(self);

        self.* = .{ .gpa = gpa, .mode = mode, .picked = picked, .boxes = boxes };

        applyStyle();
        self.raise();

        if (self.surfaces.items.len == 0) {
            self.destroy();
            return null;
        }

        self.layout();
        return self;
    }

    pub fn destroy(self: *Overlay) void {
        for (self.surfaces.items) |surface| {
            gtk.gtk_window_destroy(surface.window);
            glib.g_object_unref(surface.monitor);
            self.gpa.destroy(surface);
        }
        self.surfaces.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn raise(self: *Overlay) void {
        const display = gdk.gdk_display_get_default() orelse return;
        const monitors = gdk.gdk_display_get_monitors(display);
        const count = gio.g_list_model_get_n_items(monitors);

        var at: c.guint = 0;
        while (at < count) : (at += 1) {
            const item = gio.g_list_model_get_item(monitors, at) orelse continue;
            const monitor: *c.GdkMonitor = @ptrCast(item);

            self.attach(monitor) catch {
                glib.g_object_unref(monitor);
                return;
            };
        }
    }

    fn attach(self: *Overlay, monitor: *c.GdkMonitor) Allocator.Error!void {
        try self.surfaces.ensureUnusedCapacity(self.gpa, 1);
        const surface = try self.gpa.create(Surface);

        var area: c.GdkRectangle = undefined;
        gdk.gdk_monitor_get_geometry(monitor, &area);

        const window = c.cast(c.GtkWindow, gtk.gtk_window_new());
        gtk.gtk_window_set_decorated(window, c.FALSE);
        gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, window), window_class);

        layer.gtk_layer_init_for_window(window);
        layer.gtk_layer_set_namespace(window, namespace);
        layer.gtk_layer_set_layer(window, .overlay);
        layer.gtk_layer_set_monitor(window, monitor);
        layer.gtk_layer_set_exclusive_zone(window, -1);
        layer.gtk_layer_set_keyboard_mode(window, .exclusive);
        for ([_]c.GtkLayerShellEdge{ .left, .right, .top, .bottom }) |edge| {
            layer.gtk_layer_set_anchor(window, edge, c.TRUE);
        }

        const fixed = c.cast(c.GtkFixed, gtk.gtk_fixed_new());
        gtk.gtk_window_set_child(window, c.cast(c.GtkWidget, fixed));

        var wash: [4]*c.GtkWidget = undefined;
        for (&wash) |*slot| {
            const made = gtk.gtk_box_new(.horizontal, 0);
            gtk.gtk_widget_add_css_class(made, wash_class);
            gtk.gtk_fixed_put(fixed, made, 0, 0);
            slot.* = made;
        }

        const frame = gtk.gtk_box_new(.horizontal, 0);
        gtk.gtk_widget_add_css_class(frame, frame_class);
        gtk.gtk_fixed_put(fixed, frame, 0, 0);

        surface.* = .{
            .owner = self,
            .monitor = monitor,
            .origin = .{ .x = area.x, .y = area.y, .width = area.width, .height = area.height },
            .window = window,
            .fixed = fixed,
            .wash = wash,
            .frame = frame,
        };
        self.surfaces.appendAssumeCapacity(surface);

        const motion = gtk.gtk_event_controller_motion_new();
        gtk.gtk_widget_add_controller(c.cast(c.GtkWidget, window), motion);
        _ = c.connect(motion, "enter", &onMotion, surface);
        _ = c.connect(motion, "motion", &onMotion, surface);

        const drag = gtk.gtk_gesture_drag_new();
        gtk.gtk_widget_add_controller(
            c.cast(c.GtkWidget, window),
            c.cast(c.GtkEventController, drag),
        );
        _ = c.connect(drag, "drag-begin", &onDragBegin, surface);
        _ = c.connect(drag, "drag-update", &onDragUpdate, surface);
        _ = c.connect(drag, "drag-end", &onDragEnd, surface);

        const cancel = gtk.gtk_gesture_click_new();
        gtk.gtk_gesture_single_set_button(c.cast(c.GtkGestureSingle, cancel), c.button_secondary);
        gtk.gtk_widget_add_controller(
            c.cast(c.GtkWidget, window),
            c.cast(c.GtkEventController, cancel),
        );
        _ = c.connect(cancel, "pressed", &onCancelled, surface);

        const keys = gtk.gtk_event_controller_key_new();
        gtk.gtk_event_controller_set_propagation_phase(keys, .capture);
        gtk.gtk_widget_add_controller(c.cast(c.GtkWidget, window), keys);
        _ = c.connect(keys, "key-pressed", &onKeyPressed, surface);
        _ = c.connect(window, "close-request", &onCloseRequested, surface);

        gtk.gtk_widget_set_cursor_from_name(c.cast(c.GtkWidget, window), "crosshair");
        gtk.gtk_window_present(window);
    }

    fn showing(self: *Overlay) ?box.Box {
        if (self.chosen) |found| return found;
        if (self.mode.snaps()) return self.hovered;
        return null;
    }

    fn track(self: *Overlay, x: i32, y: i32) void {
        if (!self.mode.snaps()) return self.mark(null);

        const at = box.smallest(self.boxes, x, y) orelse return self.mark(null);
        self.mark(self.boxes[at]);
    }

    fn mark(self: *Overlay, found: ?box.Box) void {
        if (std.meta.eql(self.hovered, found)) return;

        self.hovered = found;
        self.layout();
    }

    fn begin(self: *Overlay, x: i32, y: i32) void {
        self.start_x = x;
        self.start_y = y;
        self.dragging = self.mode.drags();
    }

    fn extend(self: *Overlay, x: i32, y: i32) void {
        if (!self.dragging) return;
        if (self.chosen == null and x == self.start_x and y == self.start_y) return;

        self.chosen = box.spanning(self.start_x, self.start_y, x, y);
        self.layout();
    }

    fn settle(self: *Overlay) void {
        const wanted = self.showing();

        self.dragging = false;
        self.chosen = null;

        const found = wanted orelse return;
        if (found.width <= 1 and found.height <= 1) return self.layout();
        self.finish(found);
    }

    fn finish(self: *Overlay, wanted: ?box.Box) void {
        if (self.finished) return;
        self.finished = true;

        self.chosen = wanted;
        for (self.surfaces.items) |surface| {
            gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, surface.window), c.FALSE);
        }
        _ = glib.g_idle_add(&onSettled, self);
    }

    fn layout(self: *Overlay) void {
        const wanted = self.showing();
        for (self.surfaces.items) |surface| surface.draw(wanted);
    }
};

fn onSettled(data: c.gpointer) callconv(.c) c.gboolean {
    const self: *Overlay = @ptrCast(@alignCast(data.?));
    self.picked.call(.{self.chosen});
    return c.source_remove;
}

fn surfaceOf(data: c.gpointer) *Surface {
    return @ptrCast(@alignCast(data.?));
}

fn onMotion(
    _: *c.GtkEventControllerMotion,
    x: c.gdouble,
    y: c.gdouble,
    data: c.gpointer,
) callconv(.c) void {
    const self = surfaceOf(data);
    if (self.owner.dragging) return;

    self.owner.track(self.origin.x + round(x), self.origin.y + round(y));
}

fn onDragBegin(
    _: *c.GtkGestureDrag,
    x: c.gdouble,
    y: c.gdouble,
    data: c.gpointer,
) callconv(.c) void {
    const self = surfaceOf(data);
    self.owner.begin(self.origin.x + round(x), self.origin.y + round(y));
}

fn onDragUpdate(
    _: *c.GtkGestureDrag,
    x: c.gdouble,
    y: c.gdouble,
    data: c.gpointer,
) callconv(.c) void {
    const self = surfaceOf(data);
    self.owner.extend(self.owner.start_x + round(x), self.owner.start_y + round(y));
}

fn onDragEnd(
    _: *c.GtkGestureDrag,
    x: c.gdouble,
    y: c.gdouble,
    data: c.gpointer,
) callconv(.c) void {
    const self = surfaceOf(data);
    self.owner.extend(self.owner.start_x + round(x), self.owner.start_y + round(y));
    self.owner.settle();
}

fn onCancelled(
    _: *c.GtkGestureClick,
    _: c_int,
    _: c.gdouble,
    _: c.gdouble,
    data: c.gpointer,
) callconv(.c) void {
    surfaceOf(data).owner.finish(null);
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    _: c.GdkModifierType,
    data: c.gpointer,
) callconv(.c) c.gboolean {
    if (keyval != c.key_Escape) return c.FALSE;

    surfaceOf(data).owner.finish(null);
    return c.TRUE;
}

fn onCloseRequested(_: *c.GtkWindow, data: c.gpointer) callconv(.c) c.gboolean {
    surfaceOf(data).owner.finish(null);
    return c.TRUE;
}

fn round(value: c.gdouble) i32 {
    return @intFromFloat(@round(value));
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

const testing = std.testing;

test "a region never snaps and a window never drags" {
    try testing.expect(Mode.any.snaps());
    try testing.expect(Mode.any.drags());

    try testing.expect(!Mode.region.snaps());
    try testing.expect(Mode.region.drags());

    try testing.expect(Mode.window.snaps());
    try testing.expect(!Mode.window.drags());

    try testing.expect(Mode.screen.snaps());
    try testing.expect(!Mode.screen.drags());
}
