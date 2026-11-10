const std = @import("std");
const c = @import("../gtk/c.zig");
const flow = @import("core").flow;
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");

const Flow = @This();

const spacing_key: [*:0]const u8 = "sysdeck-flow-spacing";
const gap_key: [*:0]const u8 = "sysdeck-flow-gap";

var layout_type: c.GType = 0;
var widget_type: c.GType = 0;
var inherited: ?*c.GObjectClass = null;

made: *c.GtkWidget,

pub fn create(spacing: u16, gap: u16) Flow {
    register();

    const made = c.cast(c.GtkWidget, glib.g_object_new(widget_type, null));
    glib.g_object_set_data(made, spacing_key, @ptrFromInt(@as(usize, spacing)));
    glib.g_object_set_data(made, gap_key, @ptrFromInt(@as(usize, gap)));
    return .{ .made = made };
}

pub fn widget(self: Flow) *c.GtkWidget {
    return self.made;
}

pub fn add(self: Flow, child: *c.GtkWidget) void {
    gtk.gtk_widget_set_parent(child, self.made);
}

fn register() void {
    if (widget_type != 0) return;

    layout_type = derive(gtk.gtk_layout_manager_get_type(), "SysdeckFlowLayout", &onLayoutClass);
    widget_type = derive(gtk.gtk_widget_get_type(), "SysdeckFlow", &onWidgetClass);
}

fn derive(parent: c.GType, name: [*:0]const u8, class_init: c.GClassInitFunc) c.GType {
    var query: c.GTypeQuery = undefined;
    glib.g_type_query(parent, &query);

    return glib.g_type_register_static_simple(
        parent,
        name,
        query.class_size,
        class_init,
        query.instance_size,
        null,
        0,
    );
}

fn onLayoutClass(class: c.gpointer, _: c.gpointer) callconv(.c) void {
    const layout: *c.GtkLayoutManagerClass = @ptrCast(@alignCast(class.?));
    layout.get_request_mode = &onRequestMode;
    layout.measure = &onMeasure;
    layout.allocate = &onAllocate;
}

fn onWidgetClass(class: c.gpointer, _: c.gpointer) callconv(.c) void {
    inherited = @ptrCast(@alignCast(glib.g_type_class_peek_parent(class).?));

    const object: *c.GObjectClass = @ptrCast(@alignCast(class.?));
    object.dispose = &onDispose;
    gtk.gtk_widget_class_set_layout_manager_type(@ptrCast(class.?), layout_type);
}

fn onDispose(object: *c.GObject) callconv(.c) void {
    const self = c.cast(c.GtkWidget, object);
    while (gtk.gtk_widget_get_first_child(self)) |child| gtk.gtk_widget_unparent(child);

    if (inherited.?.dispose) |chained| chained(object);
}

fn onRequestMode(_: *c.GtkLayoutManager, _: *c.GtkWidget) callconv(.c) c.GtkSizeRequestMode {
    return .height_for_width;
}

fn onMeasure(
    _: *c.GtkLayoutManager,
    self: *c.GtkWidget,
    orientation: c.GtkOrientation,
    for_size: c_int,
    minimum: *c_int,
    natural: *c_int,
    minimum_baseline: *c_int,
    natural_baseline: *c_int,
) callconv(.c) void {
    minimum_baseline.* = -1;
    natural_baseline.* = -1;

    switch (orientation) {
        .horizontal => {
            const spacing = numberOf(self, spacing_key);
            var narrowest: c_int = 0;
            var line: c_int = 0;

            var child = first(self);
            while (child) |found| : (child = after(found)) {
                const size = sizeOf(found, .horizontal, -1);
                narrowest = @max(narrowest, size.minimum);
                line += size.natural + if (line > 0) spacing else 0;
            }

            minimum.* = narrowest;
            natural.* = @max(narrowest, line);
        },
        .vertical => {
            const height = if (for_size < 0) tallest(self) else arrange(self, for_size, .measuring);
            minimum.* = height;
            natural.* = height;
        },
    }
}

fn onAllocate(
    _: *c.GtkLayoutManager,
    self: *c.GtkWidget,
    width: c_int,
    _: c_int,
    _: c_int,
) callconv(.c) void {
    _ = arrange(self, width, .placing);
}

fn tallest(self: *c.GtkWidget) c_int {
    var tall: c_int = 0;

    var child = first(self);
    while (child) |found| : (child = after(found)) {
        tall = @max(tall, sizeOf(found, .vertical, -1).natural);
    }
    return tall;
}

fn arrange(self: *c.GtkWidget, width: c_int, purpose: enum { measuring, placing }) c_int {
    const gap = numberOf(self, gap_key);
    const mirrored = gtk.gtk_widget_get_direction(self) == .rtl;

    var cursor: flow.Cursor = .{ .available = width, .spacing = numberOf(self, spacing_key) };
    var top: c_int = 0;

    var head = first(self);
    while (head) |from| {
        var ahead = cursor;
        var line: ?u32 = null;
        var tall: c_int = 0;

        var until: ?*c.GtkWidget = from;
        while (until) |child| : (until = after(child)) {
            var tried = ahead;
            const spot = tried.put(sizeOf(child, .horizontal, -1).natural);
            if (line) |current| {
                if (spot.line != current) break;
            }

            line = spot.line;
            ahead = tried;
            tall = @max(tall, sizeOf(child, .vertical, spot.width).natural);
        }

        if (from != first(self)) top += gap;

        if (purpose == .placing) {
            var placer = cursor;
            var member: ?*c.GtkWidget = from;
            while (member != until) : (member = after(member.?)) {
                const child = member.?;
                const spot = placer.put(sizeOf(child, .horizontal, -1).natural);
                const height = sizeOf(child, .vertical, spot.width).natural;

                gtk.gtk_widget_size_allocate(child, &.{
                    .x = if (mirrored) width - spot.x - spot.width else spot.x,
                    .y = top + @divTrunc(tall - height, 2),
                    .width = spot.width,
                    .height = height,
                }, -1);
            }
        }

        cursor = ahead;
        top += tall;
        head = until;
    }

    return top;
}

const Size = struct {
    minimum: c_int,
    natural: c_int,
};

fn sizeOf(child: *c.GtkWidget, orientation: c.GtkOrientation, for_size: c_int) Size {
    var size: Size = .{ .minimum = 0, .natural = 0 };
    gtk.gtk_widget_measure(child, orientation, for_size, &size.minimum, &size.natural, null, null);
    return size;
}

fn numberOf(self: *c.GtkWidget, key: [*:0]const u8) c_int {
    return @intCast(@intFromPtr(glib.g_object_get_data(self, key)));
}

fn first(self: *c.GtkWidget) ?*c.GtkWidget {
    return laidOut(gtk.gtk_widget_get_first_child(self));
}

fn after(child: *c.GtkWidget) ?*c.GtkWidget {
    return laidOut(gtk.gtk_widget_get_next_sibling(child));
}

fn laidOut(from: ?*c.GtkWidget) ?*c.GtkWidget {
    var child = from;
    while (child) |found| : (child = gtk.gtk_widget_get_next_sibling(found)) {
        if (gtk.gtk_widget_should_layout(found) != c.FALSE) return found;
    }
    return null;
}
