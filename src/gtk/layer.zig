const c = @import("c.zig");

pub extern fn gtk_layer_is_supported() c.gboolean;
pub extern fn gtk_layer_init_for_window(window: *c.GtkWindow) void;
pub extern fn gtk_layer_set_namespace(window: *c.GtkWindow, name_space: ?[*:0]const u8) void;
pub extern fn gtk_layer_set_layer(window: *c.GtkWindow, layer: c.GtkLayerShellLayer) void;
pub extern fn gtk_layer_set_monitor(window: *c.GtkWindow, monitor: ?*c.GdkMonitor) void;
pub extern fn gtk_layer_set_anchor(
    window: *c.GtkWindow,
    edge: c.GtkLayerShellEdge,
    anchor_to_edge: c.gboolean,
) void;
pub extern fn gtk_layer_set_exclusive_zone(window: *c.GtkWindow, exclusive_zone: c_int) void;
pub extern fn gtk_layer_set_keyboard_mode(
    window: *c.GtkWindow,
    mode: c.GtkLayerShellKeyboardMode,
) void;
