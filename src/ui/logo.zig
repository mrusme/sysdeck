const std = @import("std");
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");

const log = std.log.scoped(.logo);

const bundle align(@alignOf(usize)) = @embedFile("resources").*;
const path = "/sysdeck/logo-symbolic.svg";
const uri = "resource://" ++ path;

pub fn attach(entry: *c.GtkEntry) void {
    const resource = open() orelse return;
    defer gio.g_resource_unref(resource);
    gio.g_resources_register(resource);

    var err: ?*c.GError = null;
    const icon = gio.g_icon_new_for_string(uri, &err) orelse {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot make an icon of {s}: {s}, so the entry shows no logo", .{ uri, c.errorMessage(err) });
        return;
    };
    defer glib.g_object_unref(icon);
    gtk.gtk_entry_set_icon_from_gicon(entry, .primary, icon);
}

fn open() ?*c.GResource {
    const bytes = glib.g_bytes_new_static(&bundle, bundle.len);
    defer glib.g_bytes_unref(bytes);

    var err: ?*c.GError = null;
    return gio.g_resource_new_from_data(bytes, &err) orelse {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot read the embedded resources: {s}, so the entry shows no logo", .{c.errorMessage(err)});
        return null;
    };
}

const testing = std.testing;

test "the logo is bundled under the path the icon names, with the -symbolic suffix GTK recolors" {
    const resource = open() orelse return error.Unreadable;
    defer gio.g_resource_unref(resource);

    var size: usize = 0;
    const found = gio.g_resource_get_info(resource, path, c.resource_lookup_none, &size, null, null);
    try testing.expect(found != c.FALSE);
    try testing.expect(size > 0);
    try testing.expect(std.mem.endsWith(u8, uri, "-symbolic.svg"));
}
