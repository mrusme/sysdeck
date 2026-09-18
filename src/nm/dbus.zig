const std = @import("std");
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.nm);

pub const default_timeout_ms: c.gint = 2000;

pub const Call = struct {
    name: [:0]const u8,
    path: [:0]const u8,
    interface: [:0]const u8,
    method: [:0]const u8,
    arguments: ?*c.GVariant = null,
    flags: c.GDBusCallFlags = c.dbus_call_none,
    timeout_ms: c.gint = default_timeout_ms,
    quiet: bool = false,
};

pub const Bus = struct {
    connection: *c.GDBusConnection,

    pub fn open() ?Bus {
        var err: ?*c.GError = null;
        const found = gio.g_bus_get_sync(c.bus_system, null, &err) orelse {
            defer if (err) |detail| glib.g_error_free(detail);
            log.debug("cannot reach the system bus: {s}", .{c.errorMessage(err)});
            return null;
        };
        return .{ .connection = found };
    }

    pub fn close(self: Bus) void {
        glib.g_object_unref(self.connection);
    }

    pub fn call(self: Bus, wanted: Call) ?*c.GVariant {
        var err: ?*c.GError = null;
        return gio.g_dbus_connection_call_sync(
            self.connection,
            wanted.name.ptr,
            wanted.path.ptr,
            wanted.interface.ptr,
            wanted.method.ptr,
            wanted.arguments,
            null,
            wanted.flags,
            wanted.timeout_ms,
            null,
            &err,
        ) orelse {
            report(wanted, err);
            return null;
        };
    }

    pub fn property(self: Bus, wanted: Call, key: [:0]const u8) ?*c.GVariant {
        var asked = wanted;
        asked.interface = "org.freedesktop.DBus.Properties";
        asked.method = "Get";
        asked.arguments = tuple(&.{ string(wanted.interface), string(key) });

        const reply = self.call(asked) orelse return null;
        defer drop(reply);

        const held = childAt(reply, 0);
        defer drop(held);

        return unwrap(held);
    }

    pub fn setProperty(self: Bus, wanted: Call, key: [:0]const u8, value: *c.GVariant) bool {
        var asked = wanted;
        asked.interface = "org.freedesktop.DBus.Properties";
        asked.method = "Set";
        asked.arguments = tuple(&.{ string(wanted.interface), string(key), boxed(value) });

        const reply = self.call(asked) orelse return false;
        drop(reply);
        return true;
    }
};

fn report(wanted: Call, err: ?*c.GError) void {
    defer if (err) |detail| glib.g_error_free(detail);

    const remote = if (err) |detail| gio.g_dbus_error_get_remote_error(detail) else null;
    defer if (remote) |found| glib.g_free(found);

    const named = if (remote) |found| std.mem.span(found) else "no name";
    if (wanted.quiet) {
        log.debug("{s}.{s} failed: {s}: {s}", .{
            wanted.interface,
            wanted.method,
            named,
            c.errorMessage(err),
        });
        return;
    }
    log.warn("{s}.{s} failed: {s}: {s}", .{
        wanted.interface,
        wanted.method,
        named,
        c.errorMessage(err),
    });
}

pub fn string(value: [:0]const u8) *c.GVariant {
    return glib.g_variant_new_string(value.ptr);
}

pub fn objectPath(value: [:0]const u8) *c.GVariant {
    return glib.g_variant_new_object_path(value.ptr);
}

pub fn boolean(value: bool) *c.GVariant {
    return glib.g_variant_new_boolean(if (value) c.TRUE else c.FALSE);
}

pub fn boxed(value: *c.GVariant) *c.GVariant {
    return glib.g_variant_new_variant(value);
}

pub fn tuple(parts: []const *c.GVariant) *c.GVariant {
    return glib.g_variant_new_tuple(parts.ptr, parts.len);
}

pub fn drop(value: *c.GVariant) void {
    glib.g_variant_unref(value);
}

pub fn unwrap(value: *c.GVariant) *c.GVariant {
    return glib.g_variant_get_variant(value);
}

pub fn count(value: *c.GVariant) usize {
    return glib.g_variant_n_children(value);
}

pub fn childAt(value: *c.GVariant, at: usize) *c.GVariant {
    return glib.g_variant_get_child_value(value, at);
}

pub fn lookup(dictionary: *c.GVariant, key: [:0]const u8) ?*c.GVariant {
    return glib.g_variant_lookup_value(dictionary, key.ptr, null);
}

pub fn text(value: *c.GVariant) []const u8 {
    return std.mem.span(glib.g_variant_get_string(value, null));
}

pub fn word(value: *c.GVariant) u32 {
    return glib.g_variant_get_uint32(value);
}

pub fn flag(value: *c.GVariant) bool {
    return glib.g_variant_get_boolean(value) != c.FALSE;
}

pub fn textOf(
    arena: Allocator,
    dictionary: *c.GVariant,
    key: [:0]const u8,
) Allocator.Error![]const u8 {
    const found = lookup(dictionary, key) orelse return "";
    defer drop(found);
    return arena.dupe(u8, text(found));
}

pub fn wordOf(dictionary: *c.GVariant, key: [:0]const u8) u32 {
    const found = lookup(dictionary, key) orelse return 0;
    defer drop(found);
    return word(found);
}

pub fn flagOf(dictionary: *c.GVariant, key: [:0]const u8) bool {
    const found = lookup(dictionary, key) orelse return false;
    defer drop(found);
    return flag(found);
}

pub fn pathsOf(
    arena: Allocator,
    dictionary: *c.GVariant,
    key: [:0]const u8,
) Allocator.Error![]const []const u8 {
    const found = lookup(dictionary, key) orelse return &.{};
    defer drop(found);

    const out = try arena.alloc([]const u8, count(found));
    for (out, 0..) |*slot, at| {
        const entry = childAt(found, at);
        defer drop(entry);
        slot.* = try arena.dupe(u8, text(entry));
    }
    return out;
}

pub fn parse(kind: [:0]const u8, source: [:0]const u8) ?*c.GVariant {
    const wanted = glib.g_variant_type_new(kind.ptr);
    defer glib.g_variant_type_free(wanted);

    var err: ?*c.GError = null;
    return glib.g_variant_parse(wanted, source.ptr, null, null, &err) orelse {
        defer if (err) |detail| glib.g_error_free(detail);
        log.debug("cannot parse a {s}: {s}", .{ kind, c.errorMessage(err) });
        return null;
    };
}

const testing = std.testing;

const sample =
    \\{'/org/freedesktop/NetworkManager/Devices/1': {
    \\  'org.freedesktop.NetworkManager.Device': {
    \\    'Interface': <'wlp0s20f3'>, 'DeviceType': <uint32 2>, 'State': <uint32 20>,
    \\    'Managed': <true>, 'Real': <false>,
    \\    'AvailableConnections': <[objectpath '/org/freedesktop/NetworkManager/Settings/3',
    \\                              '/org/freedesktop/NetworkManager/Settings/4']>}}}
;

fn properties(reply: *c.GVariant) *c.GVariant {
    const entry = childAt(reply, 0);
    defer drop(entry);

    const faces = childAt(entry, 1);
    defer drop(faces);

    return lookup(faces, "org.freedesktop.NetworkManager.Device").?;
}

test "a managed objects reply is walked down to its properties" {
    const reply = parse("a{oa{sa{sv}}}", sample).?;
    defer drop(reply);

    try testing.expectEqual(@as(usize, 1), count(reply));

    const entry = childAt(reply, 0);
    defer drop(entry);

    const path = childAt(entry, 0);
    defer drop(path);
    try testing.expectEqualStrings("/org/freedesktop/NetworkManager/Devices/1", text(path));
}

test "strings, words and flags are read out of a property dictionary" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const reply = parse("a{oa{sa{sv}}}", sample).?;
    defer drop(reply);

    const found = properties(reply);
    defer drop(found);

    try testing.expectEqualStrings("wlp0s20f3", try textOf(arena.allocator(), found, "Interface"));
    try testing.expectEqual(@as(u32, 2), wordOf(found, "DeviceType"));
    try testing.expectEqual(@as(u32, 20), wordOf(found, "State"));
    try testing.expect(flagOf(found, "Managed"));
    try testing.expect(!flagOf(found, "Real"));
}

test "a key that is absent reads as empty, zero or false" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const reply = parse("a{oa{sa{sv}}}", sample).?;
    defer drop(reply);

    const found = properties(reply);
    defer drop(found);

    try testing.expectEqual(@as(?*c.GVariant, null), lookup(found, "Absent"));
    try testing.expectEqualStrings("", try textOf(arena.allocator(), found, "Absent"));
    try testing.expectEqual(@as(u32, 0), wordOf(found, "Absent"));
    try testing.expect(!flagOf(found, "Absent"));
    try testing.expectEqual(@as(usize, 0), (try pathsOf(arena.allocator(), found, "Absent")).len);
}

test "an object path array comes back as owned slices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const reply = parse("a{oa{sa{sv}}}", sample).?;
    defer drop(reply);

    const found = properties(reply);
    const paths = try pathsOf(arena.allocator(), found, "AvailableConnections");
    drop(found);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("/org/freedesktop/NetworkManager/Settings/3", paths[0]);
    try testing.expectEqualStrings("/org/freedesktop/NetworkManager/Settings/4", paths[1]);
}

test "arguments are built as a tuple of the right signature" {
    const parts = [_]*c.GVariant{
        objectPath("/org/freedesktop/NetworkManager/Settings/2"),
        objectPath("/"),
        objectPath("/"),
    };
    const built = glib.g_variant_ref_sink(tuple(&parts));
    defer drop(built);

    try testing.expectEqualStrings("(ooo)", std.mem.span(glib.g_variant_get_type_string(built)));
    try testing.expectEqual(@as(usize, 3), count(built));
}

test "a boxed boolean carries its value under the variant" {
    const on = boxed(boolean(true));
    const parts = [_]*c.GVariant{ string("iface"), string("WirelessEnabled"), on };
    const built = glib.g_variant_ref_sink(tuple(&parts));
    defer drop(built);

    try testing.expectEqualStrings("(ssv)", std.mem.span(glib.g_variant_get_type_string(built)));

    const held = childAt(built, 2);
    defer drop(held);

    const inner = unwrap(held);
    defer drop(inner);
    try testing.expect(flag(inner));
}

test "text that cannot be parsed yields nothing" {
    try testing.expectEqual(@as(?*c.GVariant, null), parse("a{oa{sa{sv}}}", "not a variant"));
}
