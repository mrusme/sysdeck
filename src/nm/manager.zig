const std = @import("std");
const c = @import("../gtk/c.zig");
const dbus = @import("dbus.zig");
const state = @import("state.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.nm);

pub const service: [:0]const u8 = "org.freedesktop.NetworkManager";
pub const root: [:0]const u8 = "/org/freedesktop/NetworkManager";

const objects_path: [:0]const u8 = "/org/freedesktop";
const objects_interface: [:0]const u8 = "org.freedesktop.DBus.ObjectManager";
const manager_interface: [:0]const u8 = "org.freedesktop.NetworkManager";
const device_interface: [:0]const u8 = "org.freedesktop.NetworkManager.Device";
const active_interface: [:0]const u8 = "org.freedesktop.NetworkManager.Connection.Active";
const settings_interface: [:0]const u8 = "org.freedesktop.NetworkManager.Settings.Connection";

const external_flag: u32 = 1 << 7;
const nowhere: [:0]const u8 = "/";

pub const Device = struct {
    path: [:0]const u8,
    interface: []const u8,
    kind: []const u8,
    type_id: u32,
    state: u32,
    active: [:0]const u8,
    external: bool,
    connection: []const u8 = "",

    pub fn status(self: Device) state.Status {
        return state.deviceStatus(self.state, self.external);
    }
};

pub const Connection = struct {
    path: [:0]const u8,
    uuid: []const u8,
    id: []const u8,
    kind: []const u8,
    active: [:0]const u8,
    activation: ?u32,
    external: bool,
    device: []const u8 = "",

    pub fn status(self: Connection) state.Status {
        return state.connectionStatus(self.activation, self.external);
    }
};

pub const Snapshot = struct {
    devices: []const Device,
    connections: []const Connection,
    wireless_enabled: bool,

    pub fn deviceFor(self: Snapshot, interface: []const u8) ?Device {
        for (self.devices) |found| {
            if (std.mem.eql(u8, found.interface, interface)) return found;
        }
        return null;
    }

    pub fn connectionFor(self: Snapshot, uuid: []const u8) ?Connection {
        for (self.connections) |found| {
            if (std.mem.eql(u8, found.uuid, uuid)) return found;
        }
        return null;
    }

    pub fn wirelessDevice(self: Snapshot) ?Device {
        for (self.devices) |found| {
            if (found.type_id == state.device_wifi) return found;
        }
        return null;
    }
};

const Active = struct {
    path: [:0]const u8,
    connection: []const u8,
    state: u32,
    flags: u32,
    devices: []const []const u8,
};

const Walked = struct {
    devices: []Device,
    actives: []Active,
    settings: [][:0]const u8,
    wireless: bool,
};

pub fn read(arena: Allocator, bus: dbus.Bus) Allocator.Error!?Snapshot {
    const reply = bus.call(.{
        .name = service,
        .path = objects_path,
        .interface = objects_interface,
        .method = "GetManagedObjects",
    }) orelse return null;
    defer dbus.drop(reply);

    const objects = dbus.childAt(reply, 0);
    defer dbus.drop(objects);

    const found = try walk(arena, objects);
    mark(found.devices, found.actives);

    const devices = try ownDevices(arena, found.devices);
    const connections = try describe(arena, bus, found.settings, found.actives);
    attach(devices, connections, found.actives);

    return .{
        .devices = devices,
        .connections = try ownConnections(arena, connections),
        .wireless_enabled = found.wireless,
    };
}

fn walk(arena: Allocator, objects: *c.GVariant) Allocator.Error!Walked {
    var devices: std.ArrayList(Device) = .empty;
    var actives: std.ArrayList(Active) = .empty;
    var settings: std.ArrayList([:0]const u8) = .empty;
    var wireless = false;

    var at: usize = 0;
    while (at < dbus.count(objects)) : (at += 1) {
        const entry = dbus.childAt(objects, at);
        defer dbus.drop(entry);

        const named = dbus.childAt(entry, 0);
        defer dbus.drop(named);

        const path = try arena.dupeZ(u8, dbus.text(named));

        const faces = dbus.childAt(entry, 1);
        defer dbus.drop(faces);

        if (dbus.lookup(faces, device_interface)) |found| {
            defer dbus.drop(found);
            if (try deviceOf(arena, path, found)) |made| try devices.append(arena, made);
        }
        if (dbus.lookup(faces, active_interface)) |found| {
            defer dbus.drop(found);
            try actives.append(arena, try activeOf(arena, path, found));
        }
        if (dbus.lookup(faces, settings_interface)) |found| {
            dbus.drop(found);
            try settings.append(arena, path);
        }
        if (dbus.lookup(faces, manager_interface)) |found| {
            defer dbus.drop(found);
            wireless = dbus.flagOf(found, "WirelessEnabled");
        }
    }

    return .{
        .devices = devices.items,
        .actives = actives.items,
        .settings = settings.items,
        .wireless = wireless,
    };
}

fn deviceOf(
    arena: Allocator,
    path: [:0]const u8,
    properties: *c.GVariant,
) Allocator.Error!?Device {
    const type_id = dbus.wordOf(properties, "DeviceType");
    if (type_id == state.device_loopback) return null;
    if (!dbus.flagOf(properties, "Managed")) return null;

    return .{
        .path = path,
        .interface = try dbus.textOf(arena, properties, "Interface"),
        .kind = state.deviceKind(type_id),
        .type_id = type_id,
        .state = dbus.wordOf(properties, "State"),
        .active = try pathOf(arena, properties, "ActiveConnection"),
        .external = false,
    };
}

fn activeOf(
    arena: Allocator,
    path: [:0]const u8,
    properties: *c.GVariant,
) Allocator.Error!Active {
    return .{
        .path = path,
        .connection = try dbus.textOf(arena, properties, "Connection"),
        .state = dbus.wordOf(properties, "State"),
        .flags = dbus.wordOf(properties, "StateFlags"),
        .devices = try dbus.pathsOf(arena, properties, "Devices"),
    };
}

fn describe(
    arena: Allocator,
    bus: dbus.Bus,
    paths: []const [:0]const u8,
    actives: []const Active,
) Allocator.Error![]Connection {
    var out: std.ArrayList(Connection) = .empty;

    for (paths) |path| {
        const reply = bus.call(.{
            .name = service,
            .path = path,
            .interface = settings_interface,
            .method = "GetSettings",
            .quiet = true,
        }) orelse continue;
        defer dbus.drop(reply);

        const groups = dbus.childAt(reply, 0);
        defer dbus.drop(groups);

        const group = dbus.lookup(groups, "connection") orelse continue;
        defer dbus.drop(group);

        const uuid = try dbus.textOf(arena, group, "uuid");
        if (uuid.len == 0) continue;

        const found = activeFor(actives, path);
        try out.append(arena, .{
            .path = path,
            .uuid = uuid,
            .id = try dbus.textOf(arena, group, "id"),
            .kind = state.connectionKind(try dbus.textOf(arena, group, "type")),
            .active = if (found) |one| one.path else "",
            .activation = if (found) |one| one.state else null,
            .external = if (found) |one| one.flags & external_flag != 0 else false,
        });
    }

    return out.items;
}

fn activeFor(actives: []const Active, path: []const u8) ?Active {
    for (actives) |found| {
        if (std.mem.eql(u8, found.connection, path)) return found;
    }
    return null;
}

fn mark(devices: []Device, actives: []const Active) void {
    for (devices) |*device| {
        if (device.active.len == 0) continue;

        for (actives) |found| {
            if (!std.mem.eql(u8, found.path, device.active)) continue;
            device.external = found.flags & external_flag != 0;
        }
    }
}

fn ownDevices(arena: Allocator, devices: []const Device) Allocator.Error![]Device {
    var out: std.ArrayList(Device) = .empty;
    for (devices) |device| {
        if (device.external) continue;
        try out.append(arena, device);
    }
    return out.items;
}

fn attach(devices: []Device, connections: []Connection, actives: []const Active) void {
    for (connections) |*one| {
        if (one.active.len == 0) continue;

        for (actives) |found| {
            if (!std.mem.eql(u8, found.path, one.active)) continue;

            for (found.devices) |path| {
                for (devices) |*device| {
                    if (!std.mem.eql(u8, device.path, path)) continue;
                    one.device = device.interface;
                    device.connection = one.id;
                }
            }
        }
    }
}

fn ownConnections(arena: Allocator, connections: []const Connection) Allocator.Error![]Connection {
    var out: std.ArrayList(Connection) = .empty;
    for (connections) |one| {
        if (std.mem.eql(u8, one.kind, "loopback")) continue;
        if (one.active.len > 0 and one.device.len == 0) continue;
        try out.append(arena, one);
    }
    return out.items;
}

fn pathOf(
    arena: Allocator,
    properties: *c.GVariant,
    key: [:0]const u8,
) Allocator.Error![:0]const u8 {
    const found = dbus.lookup(properties, key) orelse return "";
    defer dbus.drop(found);

    const text = dbus.text(found);
    if (std.mem.eql(u8, text, nowhere)) return "";
    return arena.dupeZ(u8, text);
}

pub fn activate(bus: dbus.Bus, connection: [:0]const u8, device: [:0]const u8) bool {
    const parts = [_]*c.GVariant{
        dbus.objectPath(if (connection.len > 0) connection else nowhere),
        dbus.objectPath(if (device.len > 0) device else nowhere),
        dbus.objectPath(nowhere),
    };

    const reply = bus.call(.{
        .name = service,
        .path = root,
        .interface = manager_interface,
        .method = "ActivateConnection",
        .arguments = dbus.tuple(&parts),
        .flags = c.dbus_call_allow_interactive_authorization,
    }) orelse return false;

    dbus.drop(reply);
    return true;
}

pub fn deactivate(bus: dbus.Bus, active: [:0]const u8) bool {
    const parts = [_]*c.GVariant{dbus.objectPath(active)};

    const reply = bus.call(.{
        .name = service,
        .path = root,
        .interface = manager_interface,
        .method = "DeactivateConnection",
        .arguments = dbus.tuple(&parts),
        .flags = c.dbus_call_allow_interactive_authorization,
    }) orelse return false;

    dbus.drop(reply);
    return true;
}

pub fn disconnect(bus: dbus.Bus, device: [:0]const u8) bool {
    const reply = bus.call(.{
        .name = service,
        .path = device,
        .interface = device_interface,
        .method = "Disconnect",
        .flags = c.dbus_call_allow_interactive_authorization,
    }) orelse return false;

    dbus.drop(reply);
    return true;
}

pub fn setWireless(bus: dbus.Bus, on: bool) bool {
    return bus.setProperty(.{
        .name = service,
        .path = root,
        .interface = manager_interface,
        .method = "Set",
        .flags = c.dbus_call_allow_interactive_authorization,
    }, "WirelessEnabled", dbus.boolean(on));
}

pub fn deviceState(bus: dbus.Bus, device: [:0]const u8) ?u32 {
    const found = bus.property(.{
        .name = service,
        .path = device,
        .interface = device_interface,
        .method = "Get",
        .quiet = true,
    }, "State") orelse return null;
    defer dbus.drop(found);

    return dbus.word(found);
}

pub fn present(bus: dbus.Bus) bool {
    const found = bus.property(.{
        .name = service,
        .path = root,
        .interface = manager_interface,
        .method = "Get",
        .flags = c.dbus_call_no_auto_start,
        .quiet = true,
    }, "Version") orelse return false;

    dbus.drop(found);
    return true;
}

pub fn awaitReady(
    io: std.Io,
    bus: dbus.Bus,
    device: [:0]const u8,
    budget_ms: i64,
    step_ms: i64,
) bool {
    var waited: i64 = 0;
    while (waited < budget_ms) {
        const found = deviceState(bus, device) orelse return false;
        if (found != 20) return true;

        io.sleep(.fromMilliseconds(step_ms), .awake) catch return false;
        waited += step_ms;
    }

    log.warn("{s} is still unavailable after {d}ms", .{ device, budget_ms });
    return false;
}

const testing = std.testing;

const managed_objects =
    \\{'/org/freedesktop/NetworkManager': {'org.freedesktop.NetworkManager': {
    \\    'WirelessEnabled': <false>}},
    \\ '/org/freedesktop/NetworkManager/Devices/1': {
    \\   'org.freedesktop.NetworkManager.Device': {
    \\     'Interface': <'lo'>, 'DeviceType': <uint32 32>, 'State': <uint32 100>,
    \\     'Managed': <true>, 'ActiveConnection': <objectpath '/org/freedesktop/NetworkManager/ActiveConnection/1'>}},
    \\ '/org/freedesktop/NetworkManager/Devices/2': {
    \\   'org.freedesktop.NetworkManager.Device': {
    \\     'Interface': <'enp0s13f0u1u1c2'>, 'DeviceType': <uint32 1>, 'State': <uint32 100>,
    \\     'Managed': <true>, 'ActiveConnection': <objectpath '/org/freedesktop/NetworkManager/ActiveConnection/2'>}},
    \\ '/org/freedesktop/NetworkManager/Devices/3': {
    \\   'org.freedesktop.NetworkManager.Device': {
    \\     'Interface': <'wlp0s20f3'>, 'DeviceType': <uint32 2>, 'State': <uint32 20>,
    \\     'Managed': <true>, 'ActiveConnection': <objectpath '/'>}},
    \\ '/org/freedesktop/NetworkManager/Devices/4': {
    \\   'org.freedesktop.NetworkManager.Device': {
    \\     'Interface': <'vnet0'>, 'DeviceType': <uint32 16>, 'State': <uint32 100>,
    \\     'Managed': <false>, 'ActiveConnection': <objectpath '/'>}},
    \\ '/org/freedesktop/NetworkManager/ActiveConnection/2': {
    \\   'org.freedesktop.NetworkManager.Connection.Active': {
    \\     'Connection': <objectpath '/org/freedesktop/NetworkManager/Settings/1'>,
    \\     'State': <uint32 2>, 'StateFlags': <uint32 76>,
    \\     'Devices': <[objectpath '/org/freedesktop/NetworkManager/Devices/2']>}},
    \\ '/org/freedesktop/NetworkManager/Settings/1': {
    \\   'org.freedesktop.NetworkManager.Settings.Connection': {'Unsaved': <false>}},
    \\ '/org/freedesktop/NetworkManager/Settings/2': {
    \\   'org.freedesktop.NetworkManager.Settings.Connection': {'Unsaved': <false>}}}
;

fn objectsOf(source: [:0]const u8) *c.GVariant {
    return dbus.parse("a{oa{sa{sv}}}", source).?;
}

fn walked(arena: Allocator, source: [:0]const u8) !Walked {
    const objects = objectsOf(source);
    defer dbus.drop(objects);
    return walk(arena, objects);
}

test "loopback and unmanaged devices are left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try walked(arena.allocator(), managed_objects);

    try testing.expectEqual(@as(usize, 2), found.devices.len);
    for (found.devices) |device| {
        try testing.expect(!std.mem.eql(u8, device.interface, "lo"));
        try testing.expect(!std.mem.eql(u8, device.interface, "vnet0"));
    }
}

test "a device carries its interface, kind and state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try walked(arena.allocator(), managed_objects);
    const snapshot: Snapshot = .{
        .devices = found.devices,
        .connections = &.{},
        .wireless_enabled = found.wireless,
    };

    const wired = snapshot.deviceFor("enp0s13f0u1u1c2").?;
    try testing.expectEqualStrings("ethernet", wired.kind);
    try testing.expectEqual(@as(u32, 100), wired.state);
    try testing.expectEqualStrings(
        "/org/freedesktop/NetworkManager/ActiveConnection/2",
        wired.active,
    );

    const radio = snapshot.deviceFor("wlp0s20f3").?;
    try testing.expectEqualStrings("wifi", radio.kind);
    try testing.expectEqual(state.Status.unavailable, radio.status());
    try testing.expectEqualStrings("", radio.active);
}

test "a device path of slash reads as no active connection" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try walked(arena.allocator(), managed_objects);
    const snapshot: Snapshot = .{
        .devices = found.devices,
        .connections = &.{},
        .wireless_enabled = found.wireless,
    };

    try testing.expectEqual(@as(usize, 0), snapshot.deviceFor("wlp0s20f3").?.active.len);
}

test "the radio flag and the settings paths come out of the same reply" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try walked(arena.allocator(), managed_objects);

    try testing.expect(!found.wireless);
    try testing.expectEqual(@as(usize, 2), found.settings.len);
    try testing.expectEqual(@as(usize, 1), found.actives.len);
    try testing.expectEqual(@as(u32, 76), found.actives[0].flags);
}

fn externally(arena: Allocator) ![:0]const u8 {
    const swapped = try std.mem.replaceOwned(
        u8,
        arena,
        managed_objects,
        "'StateFlags': <uint32 76>",
        "'StateFlags': <uint32 204>",
    );
    return arena.dupeZ(u8, swapped);
}

test "an external activation marks the device it is on" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try walked(arena.allocator(), try externally(arena.allocator()));
    mark(found.devices, found.actives);

    for (found.devices) |device| {
        if (!std.mem.eql(u8, device.interface, "enp0s13f0u1u1c2")) continue;
        try testing.expect(device.external);
        try testing.expectEqual(state.Status.external, device.status());
        try testing.expectEqualStrings("connected (externally)", device.status().label());
    }
}

test "an externally connected device is left out of the list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const found = try walked(gpa, try externally(gpa));
    mark(found.devices, found.actives);

    const kept = try ownDevices(gpa, found.devices);
    const snapshot: Snapshot = .{
        .devices = kept,
        .connections = &.{},
        .wireless_enabled = found.wireless,
    };

    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqual(@as(?Device, null), snapshot.deviceFor("enp0s13f0u1u1c2"));
    try testing.expectEqualStrings("wlp0s20f3", kept[0].interface);
}

test "a loopback connection is never listed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const connections = [_]Connection{
        .{
            .path = "/s/1",
            .uuid = "aaaa",
            .id = "lo",
            .kind = "loopback",
            .active = "/a/1",
            .activation = 2,
            .external = true,
            .device = "lo",
        },
        .{
            .path = "/s/2",
            .uuid = "bbbb",
            .id = "Luna",
            .kind = "wifi",
            .active = "",
            .activation = null,
            .external = false,
        },
    };

    const kept = try ownConnections(arena.allocator(), &connections);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("Luna", kept[0].id);
}

test "a connection active on a device that was dropped goes with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const connections = [_]Connection{
        .{
            .path = "/s/1",
            .uuid = "aaaa",
            .id = "virbr0",
            .kind = "bridge",
            .active = "/a/1",
            .activation = 2,
            .external = true,
        },
        .{
            .path = "/s/2",
            .uuid = "bbbb",
            .id = "Wired connection 2",
            .kind = "ethernet",
            .active = "/a/2",
            .activation = 2,
            .external = false,
            .device = "enp0s13f0u1u1c2",
        },
    };

    const kept = try ownConnections(arena.allocator(), &connections);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("Wired connection 2", kept[0].id);
}

test "a saved connection that is not active is kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const connections = [_]Connection{.{
        .path = "/s/2",
        .uuid = "bbbb",
        .id = "esma102-usmi102",
        .kind = "wireguard",
        .active = "",
        .activation = null,
        .external = false,
    }};

    const kept = try ownConnections(arena.allocator(), &connections);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("esma102-usmi102", kept[0].id);
}

test "an activation that is not external leaves the device plainly connected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try walked(arena.allocator(), managed_objects);
    mark(found.devices, found.actives);

    const snapshot: Snapshot = .{
        .devices = found.devices,
        .connections = &.{},
        .wireless_enabled = found.wireless,
    };

    const wired = snapshot.deviceFor("enp0s13f0u1u1c2").?;
    try testing.expect(!wired.external);
    try testing.expectEqual(state.Status.connected, wired.status());
}

test "a connection is matched to the activation that names it" {
    const actives = [_]Active{.{
        .path = "/org/freedesktop/NetworkManager/ActiveConnection/2",
        .connection = "/org/freedesktop/NetworkManager/Settings/1",
        .state = 2,
        .flags = 76,
        .devices = &.{},
    }};

    const found = activeFor(&actives, "/org/freedesktop/NetworkManager/Settings/1").?;
    try testing.expectEqual(@as(u32, 2), found.state);
    try testing.expectEqual(
        @as(?Active, null),
        activeFor(&actives, "/org/freedesktop/NetworkManager/Settings/2"),
    );
}

test "a connection with no activation reports itself disconnected" {
    const one: Connection = .{
        .path = "/org/freedesktop/NetworkManager/Settings/2",
        .uuid = "8520c266-7cab-4ddb-978e-1839977eef96",
        .id = "Luna",
        .kind = "wifi",
        .active = "",
        .activation = null,
        .external = false,
    };

    try testing.expectEqual(state.Status.disconnected, one.status());
    try testing.expectEqual(state.Tone.idle, one.status().tone());
    try testing.expect(!one.status().up());
}

test "a snapshot finds a connection by uuid and the wireless device by type" {
    const connections = [_]Connection{
        .{
            .path = "/s/1",
            .uuid = "aaaa",
            .id = "Wired",
            .kind = "ethernet",
            .active = "/a/1",
            .activation = 2,
            .external = false,
        },
        .{
            .path = "/s/2",
            .uuid = "bbbb",
            .id = "Luna",
            .kind = "wifi",
            .active = "",
            .activation = null,
            .external = false,
        },
    };
    const devices = [_]Device{
        .{
            .path = "/d/1",
            .interface = "enp0s31f6",
            .kind = "ethernet",
            .type_id = 1,
            .state = 100,
            .active = "/a/1",
            .external = false,
        },
        .{
            .path = "/d/2",
            .interface = "wlp0s20f3",
            .kind = "wifi",
            .type_id = state.device_wifi,
            .state = 20,
            .active = "",
            .external = false,
        },
    };

    const snapshot: Snapshot = .{
        .devices = &devices,
        .connections = &connections,
        .wireless_enabled = false,
    };

    try testing.expectEqualStrings("Luna", snapshot.connectionFor("bbbb").?.id);
    try testing.expectEqual(@as(?Connection, null), snapshot.connectionFor("cccc"));
    try testing.expectEqualStrings("wlp0s20f3", snapshot.wirelessDevice().?.interface);
    try testing.expectEqual(@as(?Device, null), snapshot.deviceFor("nope"));
}

test "a reply holding no objects walks to nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try walked(arena.allocator(), "@a{oa{sa{sv}}} {}");

    try testing.expectEqual(@as(usize, 0), found.devices.len);
    try testing.expectEqual(@as(usize, 0), found.actives.len);
    try testing.expectEqual(@as(usize, 0), found.settings.len);
    try testing.expect(!found.wireless);
}

test "a device whose properties are missing is dropped rather than guessed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const bare =
        \\{'/org/freedesktop/NetworkManager/Devices/9': {
        \\  'org.freedesktop.NetworkManager.Device': {'Interface': <'eth9'>}}}
    ;
    const found = try walked(arena.allocator(), bare);

    try testing.expectEqual(@as(usize, 0), found.devices.len);
}
