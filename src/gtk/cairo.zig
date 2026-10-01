const c = @import("c.zig");

pub extern fn cairo_image_surface_create(
    format: c.cairo_format_t,
    width: c_int,
    height: c_int,
) *c.cairo_surface_t;
pub extern fn cairo_image_surface_create_for_data(
    data: [*]u8,
    format: c.cairo_format_t,
    width: c_int,
    height: c_int,
    stride: c_int,
) *c.cairo_surface_t;
pub extern fn cairo_image_surface_get_data(surface: *c.cairo_surface_t) ?[*]u8;
pub extern fn cairo_image_surface_get_width(surface: *c.cairo_surface_t) c_int;
pub extern fn cairo_image_surface_get_height(surface: *c.cairo_surface_t) c_int;
pub extern fn cairo_image_surface_get_stride(surface: *c.cairo_surface_t) c_int;
pub extern fn cairo_format_stride_for_width(format: c.cairo_format_t, width: c_int) c_int;
pub extern fn cairo_surface_status(surface: *c.cairo_surface_t) c.cairo_status_t;
pub extern fn cairo_surface_flush(surface: *c.cairo_surface_t) void;
pub extern fn cairo_surface_mark_dirty(surface: *c.cairo_surface_t) void;
pub extern fn cairo_surface_destroy(surface: *c.cairo_surface_t) void;

pub extern fn cairo_create(target: *c.cairo_surface_t) *c.cairo_t;
pub extern fn cairo_destroy(cr: *c.cairo_t) void;
pub extern fn cairo_status(cr: *c.cairo_t) c.cairo_status_t;
pub extern fn cairo_save(cr: *c.cairo_t) void;
pub extern fn cairo_restore(cr: *c.cairo_t) void;
pub extern fn cairo_translate(cr: *c.cairo_t, tx: f64, ty: f64) void;
pub extern fn cairo_scale(cr: *c.cairo_t, sx: f64, sy: f64) void;
pub extern fn cairo_rotate(cr: *c.cairo_t, angle: f64) void;
pub extern fn cairo_rectangle(cr: *c.cairo_t, x: f64, y: f64, width: f64, height: f64) void;
pub extern fn cairo_clip(cr: *c.cairo_t) void;
pub extern fn cairo_paint(cr: *c.cairo_t) void;
pub extern fn cairo_set_source_surface(
    cr: *c.cairo_t,
    surface: *c.cairo_surface_t,
    x: f64,
    y: f64,
) void;
pub extern fn cairo_get_source(cr: *c.cairo_t) *c.cairo_pattern_t;
pub extern fn cairo_pattern_set_filter(pattern: *c.cairo_pattern_t, filter: c.cairo_filter_t) void;

pub extern fn cairo_region_create_rectangle(rectangle: *const c.cairo_rectangle_int_t) *c.cairo_region_t;
pub extern fn cairo_region_destroy(region: *c.cairo_region_t) void;
