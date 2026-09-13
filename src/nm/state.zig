const std = @import("std");

pub const device_wifi: u32 = 2;
pub const device_loopback: u32 = 32;

const device_kinds = [_][]const u8{
    "unknown",
    "ethernet",
    "wifi",
    "unused1",
    "unused2",
    "bt",
    "olpc-mesh",
    "wimax",
    "modem",
    "infiniband",
    "bond",
    "vlan",
    "adsl",
    "bridge",
    "generic",
    "team",
    "tun",
    "ip-tunnel",
    "macvlan",
    "vxlan",
    "veth",
    "macsec",
    "dummy",
    "ppp",
    "ovs-interface",
    "ovs-port",
    "ovs-bridge",
    "wpan",
    "6lowpan",
    "wireguard",
    "wifi-p2p",
    "vrf",
    "loopback",
    "hsr",
    "ipvlan",
    "geneve",
};

const aliases = [_]struct { setting: []const u8, kind: []const u8 }{
    .{ .setting = "802-3-ethernet", .kind = "ethernet" },
    .{ .setting = "802-11-wireless", .kind = "wifi" },
    .{ .setting = "802-11-olpc-mesh", .kind = "olpc-mesh" },
};

pub const Tone = enum { good, bad, idle };

pub const Status = enum {
    unknown,
    unmanaged,
    unavailable,
    disconnected,
    connecting,
    connected,
    external,
    deactivating,
    failed,

    pub fn label(self: Status) [:0]const u8 {
        return switch (self) {
            .unknown => "unknown",
            .unmanaged => "unmanaged",
            .unavailable => "unavailable",
            .disconnected => "disconnected",
            .connecting => "connecting",
            .connected => "connected",
            .external => "connected (externally)",
            .deactivating => "deactivating",
            .failed => "failed",
        };
    }

    pub fn tone(self: Status) Tone {
        return switch (self) {
            .connected, .external => .good,
            .failed => .bad,
            else => .idle,
        };
    }

    pub fn up(self: Status) bool {
        return self == .connected or self == .external;
    }
};

pub fn deviceKind(value: u32) []const u8 {
    if (value >= device_kinds.len) return device_kinds[0];
    return device_kinds[value];
}

pub fn connectionKind(setting: []const u8) []const u8 {
    for (aliases) |entry| {
        if (std.mem.eql(u8, setting, entry.setting)) return entry.kind;
    }
    return setting;
}

pub fn wireless(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "wifi");
}

pub fn deviceStatus(value: u32, external: bool) Status {
    return switch (value) {
        10 => .unmanaged,
        20 => .unavailable,
        30 => .disconnected,
        40, 50, 60, 70, 80, 90 => .connecting,
        100 => if (external) .external else .connected,
        110 => .deactivating,
        120 => .failed,
        else => .unknown,
    };
}

pub fn connectionStatus(active: ?u32, external: bool) Status {
    const value = active orelse return .disconnected;
    return switch (value) {
        1 => .connecting,
        2 => if (external) .external else .connected,
        3 => .deactivating,
        4 => .disconnected,
        else => .unknown,
    };
}

const testing = std.testing;

test "a device type number becomes the name nmcli prints" {
    try testing.expectEqualStrings("ethernet", deviceKind(1));
    try testing.expectEqualStrings("wifi", deviceKind(device_wifi));
    try testing.expectEqualStrings("bridge", deviceKind(13));
    try testing.expectEqualStrings("tun", deviceKind(16));
    try testing.expectEqualStrings("wireguard", deviceKind(29));
    try testing.expectEqualStrings("loopback", deviceKind(device_loopback));
    try testing.expectEqualStrings("geneve", deviceKind(35));
}

test "a device type that is out of range reads as unknown" {
    try testing.expectEqualStrings("unknown", deviceKind(0));
    try testing.expectEqualStrings("unknown", deviceKind(36));
    try testing.expectEqualStrings("unknown", deviceKind(9999));
}

test "the three settings that start with a digit are aliased" {
    try testing.expectEqualStrings("ethernet", connectionKind("802-3-ethernet"));
    try testing.expectEqualStrings("wifi", connectionKind("802-11-wireless"));
    try testing.expectEqualStrings("olpc-mesh", connectionKind("802-11-olpc-mesh"));
}

test "every other setting name is its own kind" {
    for ([_][]const u8{ "wireguard", "loopback", "bridge", "tun", "vpn", "bond" }) |name| {
        try testing.expectEqualStrings(name, connectionKind(name));
    }
    try testing.expectEqualStrings("", connectionKind(""));
}

test "a device kind and a connection kind agree on what wireless means" {
    try testing.expect(wireless(deviceKind(device_wifi)));
    try testing.expect(wireless(connectionKind("802-11-wireless")));
    try testing.expect(!wireless(deviceKind(1)));
    try testing.expect(!wireless(connectionKind("wireguard")));
}

test "a device state becomes the word for it" {
    try testing.expectEqual(Status.unmanaged, deviceStatus(10, false));
    try testing.expectEqual(Status.unavailable, deviceStatus(20, false));
    try testing.expectEqual(Status.disconnected, deviceStatus(30, false));
    try testing.expectEqual(Status.connected, deviceStatus(100, false));
    try testing.expectEqual(Status.deactivating, deviceStatus(110, false));
    try testing.expectEqual(Status.failed, deviceStatus(120, false));
}

test "every state between prepare and secondaries reads as connecting" {
    for ([_]u32{ 40, 50, 60, 70, 80, 90 }) |value| {
        try testing.expectEqual(Status.connecting, deviceStatus(value, false));
    }
}

test "a state nobody defined reads as unknown" {
    try testing.expectEqual(Status.unknown, deviceStatus(0, false));
    try testing.expectEqual(Status.unknown, deviceStatus(45, false));
    try testing.expectEqual(Status.unknown, deviceStatus(1000, false));
}

test "an activated device that nobody configured says so" {
    try testing.expectEqual(Status.external, deviceStatus(100, true));
    try testing.expectEqualStrings("connected (externally)", deviceStatus(100, true).label());
    try testing.expectEqual(Status.disconnected, deviceStatus(30, true));
}

test "a connection with no activation is disconnected" {
    try testing.expectEqual(Status.disconnected, connectionStatus(null, false));
    try testing.expectEqual(Status.disconnected, connectionStatus(null, true));
    try testing.expectEqual(Status.disconnected, connectionStatus(4, false));
}

test "an active connection carries its own state" {
    try testing.expectEqual(Status.connecting, connectionStatus(1, false));
    try testing.expectEqual(Status.connected, connectionStatus(2, false));
    try testing.expectEqual(Status.external, connectionStatus(2, true));
    try testing.expectEqual(Status.deactivating, connectionStatus(3, false));
    try testing.expectEqual(Status.unknown, connectionStatus(0, false));
}

test "only being up is green and only failing is red" {
    try testing.expectEqual(Tone.good, Status.connected.tone());
    try testing.expectEqual(Tone.good, Status.external.tone());
    try testing.expectEqual(Tone.bad, Status.failed.tone());

    const quiet = [_]Status{
        .unknown,
        .unmanaged,
        .unavailable,
        .disconnected,
        .connecting,
        .deactivating,
    };
    for (quiet) |found| try testing.expectEqual(Tone.idle, found.tone());
}

test "up is the same two states the color calls good" {
    for (std.enums.values(Status)) |found| {
        try testing.expectEqual(found.tone() == .good, found.up());
    }
}

test "every status has a word of its own" {
    const all = std.enums.values(Status);
    for (all, 0..) |found, at| {
        try testing.expect(found.label().len > 0);
        for (all[at + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, found.label(), other.label()));
        }
    }
}
