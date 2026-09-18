const std = @import("std");
const c = @import("../gtk/c.zig");
const counters = @import("../nm/counters.zig");
const dbus = @import("../nm/dbus.zig");
const gdk = @import("../gtk/gdk.zig");
const gtk = @import("../gtk/gtk.zig");
const model = @import("../model.zig");
const manager = @import("../nm/manager.zig");
const rank = @import("core").rank;
const state = @import("../nm/state.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.nm);

pub const table = tables.nm;

const max_rows = 200;
const radio_budget_ms = 10_000;
const radio_step_ms = 200;

const wireless_names = [_][:0]const u8{ "network-wireless", "network-wireless-symbolic" };
const wired_names = [_][:0]const u8{ "network-wired", "network-wired-symbolic" };
const tunnel_names = [_][:0]const u8{ "network-vpn", "network-vpn-symbolic" };
const bridge_names = [_][:0]const u8{ "network-workgroup", "network-server" };

const Icons = struct {
    wireless: [:0]const u8 = wireless_names[0],
    wired: [:0]const u8 = wired_names[0],
    tunnel: [:0]const u8 = tunnel_names[0],
    bridge: [:0]const u8 = bridge_names[0],

    fn forKind(self: Icons, kind: []const u8) [:0]const u8 {
        if (state.wireless(kind)) return self.wireless;
        if (std.mem.eql(u8, kind, "ethernet")) return self.wired;
        if (std.mem.eql(u8, kind, "bridge")) return self.bridge;
        if (tunnelled(kind)) return self.tunnel;
        return self.wired;
    }
};

fn tunnelled(kind: []const u8) bool {
    for ([_][]const u8{ "wireguard", "vpn", "tun", "ip-tunnel", "ppp", "pppoe" }) |name| {
        if (std.mem.eql(u8, kind, name)) return true;
    }
    return false;
}

const Item = struct {
    kind: counters.Kind,
    key: []const u8,
    subtype: []const u8,
    loaded: rank.Weight = .{},
    added: rank.Weight = .{},

    fn weight(self: Item) rank.Weight {
        return .{
            .shown = self.loaded.shown +| self.added.shown,
            .chosen = self.loaded.chosen +| self.added.chosen,
        };
    }
};

const Candidate = struct {
    kind: counters.Kind,
    key: []const u8,
    subtype: []const u8,
    item: usize = 0,
    title: []const u8,
    detail: []const u8,
    haystack: []const u8,
    status: state.Status,
    icon: [:0]const u8,
};

pub const Index = struct {
    gpa: Allocator,
    io: std.Io,
    bus: dbus.Bus,
    settled: subroutines.Settled,
    icons: Icons,
    counting: bool = false,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item) = .empty,
    mutex: std.Io.Mutex = .init,
    work: std.Io.Group = .init,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Search) };
    }

    pub fn network(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Network) };
    }

    fn hits(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
        idle: bool,
    ) subroutines.Error!subroutines.Output {
        const query = std.mem.trim(u8, text, " \t");
        if (query.len == 0 and !idle) return .nothing;

        const scratch = owner.allocator();
        const found = (try manager.read(scratch, self.bus)) orelse return .nothing;

        const candidates = try collect(scratch, self.icons, found);
        if (candidates.len == 0) return .nothing;

        const haystacks = try scratch.alloc([]const u8, candidates.len);
        for (candidates, haystacks) |one, *slot| slot.* = one.haystack;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.adopt(candidates);

        const weights = try scratch.alloc(rank.Weight, candidates.len);
        for (candidates, weights) |one, *slot| slot.* = self.items.items[one.item].weight();

        const matches = try rank.rank(scratch, haystacks, weights, query);
        if (matches.len == 0) return .nothing;

        for (matches) |match| self.items.items[candidates[match.index].item].added.shown +|= 1;

        return .{ .hits = try build(scratch, candidates, matches[0..@min(matches.len, max_rows)]) };
    }

    fn picked(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        const scratch = owner.allocator();
        const found = (try manager.read(scratch, self.bus)) orelse return .nothing;

        const candidates = try collect(scratch, self.icons, found);
        if (candidates.len == 0) return .nothing;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.adopt(candidates);

        const weights = try scratch.alloc(rank.Weight, candidates.len);
        for (candidates, weights) |one, *slot| slot.* = self.items.items[one.item].weight();

        const matches = try rank.picks(scratch, weights, limit);
        if (matches.len == 0) return .nothing;

        return .{ .hits = try build(scratch, candidates, matches) };
    }

    fn adopt(self: *Index, candidates: []Candidate) Allocator.Error!void {
        for (candidates) |*one| one.item = try self.intern(one.*);
    }

    fn intern(self: *Index, one: Candidate) Allocator.Error!usize {
        const arena = self.arena.allocator();

        for (self.items.items, 0..) |*item, at| {
            if (item.kind != one.kind) continue;
            if (!std.mem.eql(u8, item.key, one.key)) continue;

            if (!std.mem.eql(u8, item.subtype, one.subtype)) {
                item.subtype = try arena.dupe(u8, one.subtype);
            }
            return at;
        }

        try self.items.append(self.gpa, .{
            .kind = one.kind,
            .key = try arena.dupe(u8, one.key),
            .subtype = try arena.dupe(u8, one.subtype),
        });
        return self.items.items.len - 1;
    }

    fn itemAt(self: *Index, id: u64) ?Item {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const at: usize = @intCast(id);
        if (at >= self.items.items.len) return null;
        return self.items.items[at];
    }

    fn note(self: *Index, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const at: usize = @intCast(id);
        if (at >= self.items.items.len) return;
        self.items.items[at].added.chosen +|= 1;
    }

    fn settle(self: *Index) subroutines.Outcome {
        self.settled.call(self.settled.context);
        return .busy;
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        const item = self.itemAt(id) orelse return .keep;

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const found = (manager.read(arena.allocator(), self.bus) catch null) orelse {
            log.warn("cannot read NetworkManager, so {s} was left alone", .{item.key});
            return .keep;
        };

        self.note(id);
        return switch (item.kind) {
            .device => self.chooseDevice(found, item.key),
            .connection => self.chooseConnection(found, item.key),
        };
    }

    fn chooseDevice(self: *Index, found: manager.Snapshot, key: []const u8) subroutines.Outcome {
        const device = found.deviceFor(key) orelse {
            log.warn("{s} is no longer a device NetworkManager offers", .{key});
            return .keep;
        };

        if (device.status().up()) {
            if (!manager.disconnect(self.bus, device.path)) return .keep;
            return self.settle();
        }

        if (device.status() == .unavailable) {
            if (!state.wireless(device.kind)) {
                log.warn("{s} is unavailable and is not wifi, so nothing can turn it on", .{key});
                return .keep;
            }
            if (!manager.setWireless(self.bus, true)) return .keep;
            return self.settle();
        }

        if (!manager.activate(self.bus, "", device.path)) return .keep;
        return self.settle();
    }

    fn chooseConnection(
        self: *Index,
        found: manager.Snapshot,
        key: []const u8,
    ) subroutines.Outcome {
        const one = found.connectionFor(key) orelse {
            log.warn("{s} is no longer a connection NetworkManager offers", .{key});
            return .keep;
        };

        if (one.active.len > 0) {
            if (!manager.deactivate(self.bus, one.active)) return .keep;
            return self.settle();
        }

        if (state.wireless(one.kind) and !found.wireless_enabled) {
            const radio = found.wirelessDevice() orelse {
                log.warn("{s} needs wifi and no wifi device is present", .{one.id});
                return .keep;
            };
            return self.spawnRadio(one.path, radio.path);
        }

        if (!manager.activate(self.bus, one.path, "")) return .keep;
        return self.settle();
    }

    fn spawnRadio(
        self: *Index,
        connection: [:0]const u8,
        device: [:0]const u8,
    ) subroutines.Outcome {
        const one = self.gpa.dupeZ(u8, connection) catch return .keep;

        const radio = self.gpa.dupeZ(u8, device) catch {
            self.gpa.free(one);
            return .keep;
        };

        self.work.concurrent(self.io, enable, .{ self, one, radio }) catch |err| {
            log.warn("cannot start the wifi activation: {t}", .{err});
            self.gpa.free(one);
            self.gpa.free(radio);
            return .keep;
        };
        return .busy;
    }

    pub fn stale(_: *Index) bool {
        return false;
    }

    pub fn refresh(_: *Index) void {}

    pub fn retire(self: *Index, store: ?*store_mod.Store) void {
        self.work.await(self.io) catch {};

        if (store) |found| self.record(found);
        self.items.deinit(self.gpa);
        self.arena.deinit();
        self.bus.close();
    }

    fn record(self: *Index, store: *store_mod.Store) void {
        if (!self.counting) return;

        var moved: std.ArrayList(counters.Count) = .empty;
        defer moved.deinit(self.gpa);

        for (self.items.items) |item| {
            if (item.added.shown == 0 and item.added.chosen == 0) continue;
            moved.append(self.gpa, .{
                .kind = item.kind,
                .key = item.key,
                .subtype = item.subtype,
                .shown = item.added.shown,
                .chosen = item.added.chosen,
            }) catch break;
        }

        counters.flush(store.conn, moved.items) catch |err| {
            log.warn("cannot record the {s} counters: {t}", .{ table, err });
        };
    }
};

fn enable(self: *Index, connection: [:0]const u8, device: [:0]const u8) void {
    defer self.gpa.free(connection);
    defer self.gpa.free(device);
    defer self.settled.call(self.settled.context);

    if (!manager.setWireless(self.bus, true)) return;
    if (!manager.awaitReady(self.io, self.bus, device, radio_budget_ms, radio_step_ms)) return;

    _ = manager.activate(self.bus, connection, "");
}

fn collect(
    arena: Allocator,
    icons: Icons,
    found: manager.Snapshot,
) Allocator.Error![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;

    for (found.devices) |device| {
        try out.append(arena, .{
            .kind = .device,
            .key = device.interface,
            .subtype = device.kind,
            .title = device.interface,
            .detail = try detailOf(arena, device.kind, device.connection),
            .haystack = try std.mem.concat(arena, u8, &.{
                device.interface,
                " ",
                device.kind,
                " ",
                device.connection,
            }),
            .status = device.status(),
            .icon = icons.forKind(device.kind),
        });
    }

    for (found.connections) |one| {
        try out.append(arena, .{
            .kind = .connection,
            .key = one.uuid,
            .subtype = one.kind,
            .title = one.id,
            .detail = try detailOf(arena, one.kind, one.device),
            .haystack = try std.mem.concat(arena, u8, &.{
                one.id,
                " ",
                one.kind,
                " ",
                one.device,
            }),
            .status = one.status(),
            .icon = icons.forKind(one.kind),
        });
    }

    return out.items;
}

fn detailOf(arena: Allocator, kind: []const u8, on: []const u8) Allocator.Error![]const u8 {
    if (on.len == 0) return kind;
    return std.mem.concat(arena, u8, &.{ kind, ", ", on });
}

fn build(
    arena: Allocator,
    candidates: []const Candidate,
    matches: []const rank.Match,
) Allocator.Error![]subroutines.Hit {
    var made: std.ArrayList(subroutines.Hit) = .empty;

    for (matches) |match| {
        const one = candidates[match.index];

        const worn = try arena.alloc(model.Badge, 1);
        worn[0] = .{ .status = .{ .text = one.status.label(), .tone = toneOf(one.status) } };

        try made.append(arena, .{
            .row = .{
                .id = one.item,
                .icon = .{ .name = one.icon },
                .title = try arena.dupeZ(u8, one.title),
                .detail = try arena.dupeZ(u8, one.detail),
                .badges = worn,
            },
            .score = match.score,
        });
    }

    return made.toOwnedSlice(arena);
}

fn toneOf(found: state.Status) model.Tone {
    return switch (found.tone()) {
        .good => .good,
        .bad => .bad,
        .idle => .idle,
    };
}

const Search = struct {
    pub const Context = Index;

    pub const choose = Index.choose;
    pub const stale = Index.stale;
    pub const refresh = Index.refresh;
    pub const retire = Index.retire;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.hits(owner, text, false);
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.picked(owner, limit);
    }
};

const Network = struct {
    pub const Context = Index;

    pub const choose = Index.choose;
    pub const stale = Index.stale;
    pub const refresh = Index.refresh;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.hits(owner, text, true);
    }

    pub fn retire(_: *Index, _: ?*store_mod.Store) void {}
};

pub fn enabled(configured: ?bool, bus: ?dbus.Bus) bool {
    if (configured) |wanted| return wanted;
    const found = bus orelse return false;
    return manager.present(found);
}

pub fn open(
    gpa: Allocator,
    io: std.Io,
    bus: dbus.Bus,
    store: ?*store_mod.Store,
    settled: subroutines.Settled,
) Allocator.Error!Index {
    var self: Index = .{
        .gpa = gpa,
        .io = io,
        .bus = bus,
        .settled = settled,
        .icons = themed(),
        .arena = .init(gpa),
    };
    errdefer self.arena.deinit();
    errdefer self.items.deinit(gpa);

    const found = store orelse return self;
    counters.ensure(found.conn) catch |err| {
        log.warn("cannot prepare the {s} table: {t}, so nothing is counted", .{ table, err });
        return self;
    };
    self.counting = true;

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    const stored = counters.load(scratch.allocator(), found.conn) catch |err| {
        log.warn("cannot read the {s} counters: {t}", .{ table, err });
        return self;
    };

    const arena = self.arena.allocator();
    for (stored) |one| {
        try self.items.append(gpa, .{
            .kind = one.kind,
            .key = try arena.dupe(u8, one.key),
            .subtype = try arena.dupe(u8, one.subtype),
            .loaded = .{ .shown = one.shown, .chosen = one.chosen },
        });
    }

    return self;
}

fn themed() Icons {
    const display = gdk.gdk_display_get_default() orelse return .{};
    const theme = gtk.gtk_icon_theme_get_for_display(display);

    return .{
        .wireless = pick(theme, &wireless_names),
        .wired = pick(theme, &wired_names),
        .tunnel = pick(theme, &tunnel_names),
        .bridge = pick(theme, &bridge_names),
    };
}

fn pick(theme: *c.GtkIconTheme, names: []const [:0]const u8) [:0]const u8 {
    for (names) |name| {
        if (gtk.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    }
    return names[names.len - 1];
}

const testing = std.testing;

fn testIndex() Index {
    return .{
        .gpa = testing.allocator,
        .io = testing.io,
        .bus = undefined,
        .settled = .{},
        .icons = .{},
        .arena = .init(testing.allocator),
    };
}

fn shut(self: *Index) void {
    self.items.deinit(self.gpa);
    self.arena.deinit();
}

const wifi: Candidate = .{
    .kind = .connection,
    .key = "8520c266-7cab-4ddb-978e-1839977eef96",
    .subtype = "wifi",
    .title = "Luna",
    .detail = "wifi",
    .haystack = "Luna wifi ",
    .status = .disconnected,
    .icon = "network-wireless",
};

test "a detail names the kind alone when nothing carries it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    try testing.expectEqualStrings("wifi", try detailOf(gpa, "wifi", ""));
    try testing.expectEqualStrings("wifi, wlp0s20f3", try detailOf(gpa, "wifi", "wlp0s20f3"));
    try testing.expectEqualStrings(
        "ethernet, Wired connection 2",
        try detailOf(gpa, "ethernet", "Wired connection 2"),
    );
}

test "an icon is chosen by kind" {
    const icons: Icons = .{};

    try testing.expectEqualStrings("network-wireless", icons.forKind("wifi"));
    try testing.expectEqualStrings("network-wired", icons.forKind("ethernet"));
    try testing.expectEqualStrings("network-workgroup", icons.forKind("bridge"));
    try testing.expectEqualStrings("network-vpn", icons.forKind("wireguard"));
    try testing.expectEqualStrings("network-vpn", icons.forKind("tun"));
    try testing.expectEqualStrings("network-wired", icons.forKind("geneve"));
}

test "a tone follows what the state calls it" {
    try testing.expectEqual(model.Tone.good, toneOf(.connected));
    try testing.expectEqual(model.Tone.good, toneOf(.external));
    try testing.expectEqual(model.Tone.bad, toneOf(.failed));
    try testing.expectEqual(model.Tone.idle, toneOf(.disconnected));
    try testing.expectEqual(model.Tone.idle, toneOf(.unavailable));
}

test "interning the same entry twice gives the same id" {
    var self = testIndex();
    defer shut(&self);

    const first = try self.intern(wifi);
    const second = try self.intern(wifi);

    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), self.items.items.len);
}

test "an id keeps its meaning as more entries arrive" {
    var self = testIndex();
    defer shut(&self);

    const luna = try self.intern(wifi);

    var other = wifi;
    other.key = "f6523f58-3c3a-4e7e-8233-504757b1fc03";
    other.title = "ALDAHOTELS";
    _ = try self.intern(other);

    try testing.expectEqual(luna, try self.intern(wifi));
    try testing.expectEqualStrings(wifi.key, self.itemAt(luna).?.key);
}

test "a device and a connection sharing a key are interned apart" {
    var self = testIndex();
    defer shut(&self);

    var device = wifi;
    device.kind = .device;
    device.key = "virbr0";

    var one = wifi;
    one.kind = .connection;
    one.key = "virbr0";

    const left = try self.intern(device);
    const right = try self.intern(one);

    try testing.expect(left != right);
    try testing.expectEqual(counters.Kind.device, self.itemAt(left).?.kind);
    try testing.expectEqual(counters.Kind.connection, self.itemAt(right).?.kind);
}

test "a subtype that changed is picked up without a new id" {
    var self = testIndex();
    defer shut(&self);

    const at = try self.intern(wifi);

    var renamed = wifi;
    renamed.subtype = "wireguard";
    try testing.expectEqual(at, try self.intern(renamed));
    try testing.expectEqualStrings("wireguard", self.itemAt(at).?.subtype);
}

test "the key and subtype are copied rather than borrowed" {
    var self = testIndex();
    defer shut(&self);

    var buffer: [64]u8 = undefined;
    @memcpy(buffer[0..4], "Luna");

    var borrowed = wifi;
    borrowed.key = buffer[0..4];

    const at = try self.intern(borrowed);
    @memset(&buffer, 'x');

    try testing.expectEqualStrings("Luna", self.itemAt(at).?.key);
}

test "an id nobody interned resolves to nothing" {
    var self = testIndex();
    defer shut(&self);

    try testing.expectEqual(@as(?Item, null), self.itemAt(0));
    _ = try self.intern(wifi);
    try testing.expectEqual(@as(?Item, null), self.itemAt(1));
}

test "choosing and showing add to what the database already held" {
    var self = testIndex();
    defer shut(&self);

    const at = try self.intern(wifi);
    self.items.items[at].loaded = .{ .shown = 10, .chosen = 4 };
    self.items.items[at].added = .{ .shown = 2, .chosen = 1 };

    const found = self.items.items[at].weight();
    try testing.expectEqual(@as(u32, 12), found.shown);
    try testing.expectEqual(@as(u32, 5), found.chosen);

    self.note(at);
    try testing.expectEqual(@as(u32, 6), self.items.items[at].weight().chosen);
}

test "candidates carry both the devices and the connections" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const devices = [_]manager.Device{.{
        .path = "/d/1",
        .interface = "wlp0s20f3",
        .kind = "wifi",
        .type_id = state.device_wifi,
        .state = 20,
        .active = "",
        .external = false,
    }};
    const connections = [_]manager.Connection{.{
        .path = "/s/1",
        .uuid = "8520c266",
        .id = "Luna",
        .kind = "wifi",
        .active = "",
        .activation = null,
        .external = false,
    }};

    const found = try collect(arena.allocator(), .{}, .{
        .devices = &devices,
        .connections = &connections,
        .wireless_enabled = false,
    });

    try testing.expectEqual(@as(usize, 2), found.len);

    try testing.expectEqual(counters.Kind.device, found[0].kind);
    try testing.expectEqualStrings("wlp0s20f3", found[0].key);
    try testing.expectEqualStrings("wifi", found[0].detail);
    try testing.expectEqual(state.Status.unavailable, found[0].status);

    try testing.expectEqual(counters.Kind.connection, found[1].kind);
    try testing.expectEqualStrings("8520c266", found[1].key);
    try testing.expectEqualStrings("Luna", found[1].title);
    try testing.expectEqual(state.Status.disconnected, found[1].status);
}

test "a haystack carries the title, the kind and what it is on" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const connections = [_]manager.Connection{.{
        .path = "/s/1",
        .uuid = "aaaa",
        .id = "Wired connection 2",
        .kind = "ethernet",
        .active = "/a/1",
        .activation = 2,
        .external = false,
        .device = "enp0s13f0u1u1c2",
    }};

    const found = try collect(arena.allocator(), .{}, .{
        .devices = &.{},
        .connections = &connections,
        .wireless_enabled = true,
    });

    try testing.expectEqualStrings(
        "Wired connection 2 ethernet enp0s13f0u1u1c2",
        found[0].haystack,
    );
    try testing.expectEqualStrings("ethernet, enp0s13f0u1u1c2", found[0].detail);
    try testing.expectEqual(state.Status.connected, found[0].status);
}

test "a built row carries the status badge and the interned id" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var one = wifi;
    one.item = 7;
    one.status = .failed;

    const candidates = [_]Candidate{one};
    const matches = [_]rank.Match{.{ .index = 0, .score = 42 }};

    var self = testIndex();
    defer shut(&self);

    const found = try build(owner.allocator(), &candidates, &matches);

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u64, 7), found[0].row.id);
    try testing.expectEqualStrings("Luna", found[0].row.title);
    try testing.expectEqual(@as(usize, 1), found[0].row.badges.len);
    try testing.expectEqualStrings("failed", found[0].row.badges[0].status.text);
    try testing.expectEqual(model.Tone.bad, found[0].row.badges[0].status.tone);
    try testing.expectEqual(@as(i32, 42), found[0].score);
}

test "the search vtable answers an empty query with nothing" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var self = testIndex();
    defer shut(&self);

    try testing.expectEqual(subroutines.Output.nothing, try Search.run(&self, owner, ""));
    try testing.expectEqual(subroutines.Output.nothing, try Search.run(&self, owner, "  "));
}
