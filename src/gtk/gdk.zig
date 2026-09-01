const std = @import("std");
const c = @import("c.zig");

const gboolean = gboolean;
const gpointer = c.gpointer;
const guint = c.guint;
const gulong = c.gulong;
const gdouble = c.gdouble;

pub extern fn gdk_display_get_default() ?*c.GdkDisplay;
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
pub extern fn gdk_clipboard_store_finish(
    clipboard: *c.GdkClipboard,
    result: *c.GAsyncResult,
    err: *?*c.GError,
) c.gboolean;
pub extern fn gdk_texture_new_for_pixbuf(pixbuf: *c.GdkPixbuf) *c.GdkTexture;
pub extern fn gdk_texture_get_width(texture: *c.GdkTexture) c_int;
pub extern fn gdk_texture_get_height(texture: *c.GdkTexture) c_int;
