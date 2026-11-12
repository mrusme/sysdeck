const c = @import("c.zig");

pub extern fn gexiv2_initialize() c.gboolean;
pub extern fn gexiv2_log_set_level(level: c.GExiv2LogLevel) void;
pub extern fn gexiv2_metadata_new() ?*c.GExiv2Metadata;
pub extern fn gexiv2_metadata_open_buf(
    self: *c.GExiv2Metadata,
    data: [*]const u8,
    n_data: c_long,
    err: ?*?*c.GError,
) c.gboolean;
pub extern fn gexiv2_metadata_has_exif(self: *c.GExiv2Metadata) c.gboolean;
pub extern fn gexiv2_metadata_get_pixel_width(self: *c.GExiv2Metadata) c_int;
pub extern fn gexiv2_metadata_get_pixel_height(self: *c.GExiv2Metadata) c_int;
pub extern fn gexiv2_metadata_try_get_orientation(
    self: *c.GExiv2Metadata,
    err: ?*?*c.GError,
) c.GExiv2Orientation;
pub extern fn gexiv2_metadata_try_get_tag_interpreted_string(
    self: *c.GExiv2Metadata,
    tag: [*:0]const u8,
    err: ?*?*c.GError,
) ?[*:0]u8;
pub extern fn gexiv2_metadata_try_get_gps_info(
    self: *c.GExiv2Metadata,
    longitude: *f64,
    latitude: *f64,
    altitude: *f64,
    err: ?*?*c.GError,
) c.gboolean;
