const std = @import("std");
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.dbus);

pub const default_timeout_ms: c.gint = 2000;

pub const Call = struct {
    name: [:0]const u8,
    path: [:0]const u8,
    interface: [:0]const u8,
    method: [:0]const u8,
    arguments: ?*c.GVariant = null,
    reply: ?[:0]const u8 = null,
    flags: c.GDBusCallFlags = c.dbus_call_none,
    timeout_ms: c.gint = default_timeout_ms,
    quiet: bool = false,
};

pub const Kind = enum {
    system,
    session,

    fn of(self: Kind) c.GBusType {
        return switch (self) {
            .system => c.bus_system,
            .session => c.bus_session,
        };
    }
};

pub const Bus = struct {
    connection: *c.GDBusConnection,

    pub fn open(kind: Kind) ?Bus {
        var err: ?*c.GError = null;
        const found = gio.g_bus_get_sync(kind.of(), null, &err) orelse {
            defer if (err) |detail| glib.g_error_free(detail);
            log.debug("cannot reach the {t} bus: {s}", .{ kind, c.errorMessage(err) });
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
            if (wanted.reply) |kind| @ptrCast(kind.ptr) else null,
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
        asked.reply = "(v)";

        const reply = self.call(asked) orelse return null;
        defer drop(reply);

        const held = childAt(reply, 0);
        defer drop(held);

        return unwrap(held);
    }

    pub fn properties(self: Bus, wanted: Call) ?*c.GVariant {
        var asked = wanted;
        asked.interface = "org.freedesktop.DBus.Properties";
        asked.method = "GetAll";
        asked.arguments = tuple(&.{string(wanted.interface)});
        asked.reply = "(a{sv})";

        const reply = self.call(asked) orelse return null;
        defer drop(reply);

        return childAt(reply, 0);
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
    return glib.g_variant_new_string(value.ptr) orelse glib.g_variant_new_string("").?;
}

pub fn valid(arena: Allocator, bytes: []const u8) Allocator.Error![:0]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return arena.dupeSentinel(u8, bytes, 0);

    const owned = try arena.dupeSentinel(u8, bytes, 0);
    const made = glib.g_utf8_make_valid(owned.ptr, @intCast(owned.len));
    defer glib.g_free(made);

    return arena.dupeSentinel(u8, std.mem.span(made), 0);
}

pub fn objectPath(value: [:0]const u8) *c.GVariant {
    return glib.g_variant_new_object_path(value.ptr);
}

pub fn boolean(value: bool) *c.GVariant {
    return glib.g_variant_new_boolean(if (value) c.TRUE else c.FALSE);
}

pub fn signed(value: i32) *c.GVariant {
    return glib.g_variant_new_int32(value);
}

pub fn unsigned(value: u32) *c.GVariant {
    return glib.g_variant_new_uint32(value);
}

pub fn byte(value: u8) *c.GVariant {
    return glib.g_variant_new_byte(value);
}

pub fn array(child: [:0]const u8, items: []const *c.GVariant) *c.GVariant {
    return glib.g_variant_new_array(@ptrCast(child.ptr), items.ptr, items.len);
}

pub fn field(key: [:0]const u8, value: *c.GVariant) *c.GVariant {
    return glib.g_variant_new_dict_entry(string(key), boxed(value));
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
    if (!isText(value)) return "";
    return std.mem.span(glib.g_variant_get_string(value, null));
}

pub fn word(value: *c.GVariant) u32 {
    if (!isKind(value, "u")) return 0;
    return glib.g_variant_get_uint32(value);
}

pub fn flag(value: *c.GVariant) bool {
    if (!isKind(value, "b")) return false;
    return glib.g_variant_get_boolean(value) != c.FALSE;
}

pub fn isKind(value: *c.GVariant, kind: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(glib.g_variant_get_type_string(value)), kind);
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

pub fn stringsOf(
    arena: Allocator,
    dictionary: *c.GVariant,
    key: [:0]const u8,
) Allocator.Error![]const []const u8 {
    const found = lookup(dictionary, key) orelse return &.{};
    defer drop(found);
    return strings(arena, found);
}

pub fn strings(arena: Allocator, value: *c.GVariant) Allocator.Error![]const []const u8 {
    if (isText(value)) return arena.dupe([]const u8, &.{try arena.dupe(u8, text(value))});
    if (!isTextArray(value)) return &.{};

    const out = try arena.alloc([]const u8, count(value));
    for (out, 0..) |*slot, at| {
        const item = childAt(value, at);
        defer drop(item);
        slot.* = try arena.dupe(u8, text(item));
    }
    return out;
}

fn isText(value: *c.GVariant) bool {
    return isKind(value, "s") or isKind(value, "o");
}

fn isTextArray(value: *c.GVariant) bool {
    return isKind(value, "as") or isKind(value, "ao");
}

pub const Criticals = struct {
    previous: c_uint,

    const fatal_mask: c_uint = 1 << 0 | 1 << 2;
    const critical: c_uint = 1 << 3;

    pub fn fatal() Criticals {
        return .{ .previous = glib.g_log_set_always_fatal(fatal_mask | critical) };
    }

    pub fn restore(self: Criticals) void {
        _ = glib.g_log_set_always_fatal(self.previous);
    }
};

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
    try testing.expectEqual(@as(usize, 0), (try stringsOf(arena.allocator(), found, "Absent")).len);
}

test "an object path array comes back as owned slices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const reply = parse("a{oa{sa{sv}}}", sample).?;
    defer drop(reply);

    const found = properties(reply);
    const paths = try stringsOf(arena.allocator(), found, "AvailableConnections");
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

test "a single string and an array of strings both read as a list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const metadata = parse("a{sv}", "{'xesam:artist': <['Daft Punk', 'Pharrell Williams']>, " ++
        "'xesam:albumArtist': <'Daft Punk'>, 'xesam:trackNumber': <8>}").?;
    defer drop(metadata);

    const artists = try stringsOf(arena.allocator(), metadata, "xesam:artist");
    try testing.expectEqual(@as(usize, 2), artists.len);
    try testing.expectEqualStrings("Pharrell Williams", artists[1]);

    const single = try stringsOf(arena.allocator(), metadata, "xesam:albumArtist");
    try testing.expectEqual(@as(usize, 1), single.len);
    try testing.expectEqualStrings("Daft Punk", single[0]);

    const number = try stringsOf(arena.allocator(), metadata, "xesam:trackNumber");
    try testing.expectEqual(@as(usize, 0), number.len);
}

test "a dictionary of hints is built with boxed values" {
    const hints = [_]*c.GVariant{ field("urgency", byte(0)), field("transient", boolean(true)) };
    const built = glib.g_variant_ref_sink(array("{sv}", &hints));
    defer drop(built);

    try testing.expectEqualStrings("a{sv}", std.mem.span(glib.g_variant_get_type_string(built)));

    const urgency = lookup(built, "urgency").?;
    defer drop(urgency);
    try testing.expectEqualStrings("y", std.mem.span(glib.g_variant_get_type_string(urgency)));

    const empty = glib.g_variant_ref_sink(array("s", &.{}));
    defer drop(empty);
    try testing.expectEqualStrings("as", std.mem.span(glib.g_variant_get_type_string(empty)));
    try testing.expectEqual(@as(usize, 0), count(empty));
}

test "a value of the wrong type reads as empty, zero or false instead of failing" {
    const strict: Criticals = .fatal();
    defer strict.restore();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const odd = parse("a{sv}", "{'Title': <42>, 'Count': <'many'>, 'Ready': <uint32 1>}").?;
    defer drop(odd);

    try testing.expectEqualStrings("", try textOf(arena.allocator(), odd, "Title"));
    try testing.expectEqual(@as(u32, 0), wordOf(odd, "Count"));
    try testing.expect(!flagOf(odd, "Ready"));
}
