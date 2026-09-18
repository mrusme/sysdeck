const c = @import("c.zig");

pub extern fn gdk_pixbuf_new_from_data(
    data: [*]const u8,
    colorspace: c.GdkColorspace,
    has_alpha: c.gboolean,
    bits_per_sample: c_int,
    width: c_int,
    height: c_int,
    rowstride: c_int,
    destroy_fn: ?*const fn (pixels: [*]u8, data: c.gpointer) callconv(.c) void,
    destroy_fn_data: c.gpointer,
) ?*c.GdkPixbuf;
pub extern fn gdk_pixbuf_save_to_bufferv(
    pixbuf: *c.GdkPixbuf,
    buffer: *?[*]u8,
    buffer_size: *usize,
    kind: [*:0]const u8,
    option_keys: ?[*:null]const ?[*:0]const u8,
    option_values: ?[*:null]const ?[*:0]const u8,
    err: ?*?*c.GError,
) c.gboolean;
pub extern fn gdk_pixbuf_new_from_stream(
    stream: *c.GInputStream,
    cancellable: ?*c.GCancellable,
    err: ?*?*c.GError,
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
