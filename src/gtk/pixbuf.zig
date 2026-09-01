const std = @import("std");
const c = @import("c.zig");

const gboolean = gboolean;
const gpointer = c.gpointer;
const guint = c.guint;
const gulong = c.gulong;
const gdouble = c.gdouble;

pub extern fn gdk_pixbuf_new_from_stream(
    stream: *c.GInputStream,
    cancellable: ?*c.GCancellable,
    err: *?*c.GError,
) ?*c.GdkPixbuf;
pub extern fn gdk_pixbuf_apply_embedded_orientation(src: *c.GdkPixbuf) ?*c.GdkPixbuf;
pub extern fn gdk_pixbuf_get_width(pixbuf: *c.GdkPixbuf) c_int;
pub extern fn gdk_pixbuf_get_height(pixbuf: *c.GdkPixbuf) c_int;
pub extern fn gdk_pixbuf_scale_simple(
    src: *c.GdkPixbuf,
    dest_width: c_int,
    dest_height: c_int,
    interp_type: c.GdkInterpType,
) ?*c.GdkPixbuf;
