const c = @import("c.zig");
const wayland = @import("../wayland/c.zig");

pub extern fn gdk_display_get_default() ?*c.GdkDisplay;
pub extern fn gdk_display_flush(display: *c.GdkDisplay) void;
pub extern fn gdk_display_get_monitors(display: *c.GdkDisplay) *c.GListModel;
pub extern fn gdk_toplevel_get_state(toplevel: *c.GdkToplevel) c.GdkToplevelState;
pub extern fn gdk_surface_set_input_region(surface: *c.GdkSurface, region: ?*c.cairo_region_t) void;
pub extern fn gdk_monitor_get_geometry(monitor: *c.GdkMonitor, geometry: *c.GdkRectangle) void;
pub extern fn gdk_monitor_get_connector(monitor: *c.GdkMonitor) ?[*:0]const u8;
pub extern fn gdk_monitor_is_valid(monitor: *c.GdkMonitor) c.gboolean;
pub extern fn gdk_wayland_display_get_type() c.GType;
pub extern fn gdk_wayland_display_get_wl_display(display: *c.GdkDisplay) ?*wayland.Proxy;
pub extern fn gdk_wayland_surface_get_wl_surface(surface: *c.GdkSurface) ?*wayland.Proxy;
pub extern fn gdk_wayland_monitor_get_wl_output(monitor: *c.GdkMonitor) ?*wayland.Proxy;
pub extern fn gdk_keyval_from_name(name: [*:0]const u8) c.guint;
pub extern fn gdk_display_get_app_launch_context(display: *c.GdkDisplay) *c.GdkAppLaunchContext;
pub extern fn gdk_display_get_clipboard(display: *c.GdkDisplay) *c.GdkClipboard;
pub extern fn gdk_clipboard_set_text(clipboard: *c.GdkClipboard, text: [*:0]const u8) void;
pub extern fn gdk_clipboard_store_async(
    clipboard: *c.GdkClipboard,
    io_priority: c_int,
    cancellable: ?*c.GCancellable,
    callback: ?c.GAsyncReadyCallback,
    data: c.gpointer,
) void;
pub extern fn gdk_texture_new_for_pixbuf(pixbuf: *c.GdkPixbuf) *c.GdkTexture;
pub extern fn gdk_memory_texture_new(
    width: c_int,
    height: c_int,
    format: c.GdkMemoryFormat,
    bytes: *c.GBytes,
    stride: usize,
) *c.GdkTexture;
pub extern fn gdk_texture_get_width(texture: *c.GdkTexture) c_int;
pub extern fn gdk_texture_get_height(texture: *c.GdkTexture) c_int;
pub extern fn gdk_texture_download(texture: *c.GdkTexture, data: [*]u8, stride: usize) void;
