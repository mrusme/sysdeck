const std = @import("std");
const c = @import("../gtk/c.zig");
const dbus = @import("dbus.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.mpris);

const prefix = "org.mpris.MediaPlayer2.";
const playerctld = prefix ++ "playerctld";
const object_path = "/org/mpris/MediaPlayer2";
const root_interface = "org.mpris.MediaPlayer2";
const player_interface = root_interface ++ ".Player";
const playerctld_interface = "com.github.altdesktop.playerctld";
const timeout_ms = 1000;

pub const Capability = enum { play, pause, go_next, go_previous };

pub const Command = enum {
    play,
    pause,
    play_pause,
    stop,
    next,
    previous,

    pub fn needs(self: Command) Capability {
        return switch (self) {
            .play, .play_pause, .stop => .play,
            .pause => .pause,
            .next => .go_next,
            .previous => .go_previous,
        };
    }

    fn method(self: Command) [:0]const u8 {
        return switch (self) {
            .play => "Play",
            .pause => "Pause",
            .play_pause => "PlayPause",
            .stop => "Stop",
            .next => "Next",
            .previous => "Previous",
        };
    }
};

pub const Status = enum {
    playing,
    paused,
    stopped,

    fn of(text: []const u8) ?Status {
        if (std.mem.eql(u8, text, "Playing")) return .playing;
        if (std.mem.eql(u8, text, "Paused")) return .paused;
        if (std.mem.eql(u8, text, "Stopped")) return .stopped;
        return null;
    }

    fn rank(status: ?Status) u2 {
        return switch (status orelse return 2) {
            .playing => 0,
            .paused => 1,
            .stopped => 2,
        };
    }
};

pub const Track = struct {
    title: []const u8 = "",
    artists: []const []const u8 = &.{},
    album: []const u8 = "",
    art: []const u8 = "",

    pub fn artist(self: Track, arena: Allocator) Allocator.Error![]const u8 {
        return std.mem.join(arena, ", ", self.artists);
    }
};

pub const Player = struct {
    bus: dbus.Kind,
    name: [:0]const u8,
    identity: []const u8 = "",
    status: ?Status = null,
    can_play: bool = false,
    can_pause: bool = false,
    can_go_next: bool = false,
    can_go_previous: bool = false,
    track: Track = .{},

    pub fn label(self: Player) []const u8 {
        if (self.identity.len > 0) return self.identity;
        return self.name[prefix.len..];
    }

    pub fn can(self: Player, capability: Capability) bool {
        return switch (capability) {
            .play => self.can_play,
            .pause => self.can_pause,
            .go_next => self.can_go_next,
            .go_previous => self.can_go_previous,
        };
    }
};

pub const Snapshot = struct {
    players: []const Player = &.{},

    pub fn target(self: Snapshot, capability: Capability) ?Player {
        for (self.players) |player| {
            if (player.can(capability)) return player;
        }
        return null;
    }
};

const Names = struct {
    names: []const [:0]const u8 = &.{},
    by_activity: bool = false,
};

pub fn read(arena: Allocator) Allocator.Error!Snapshot {
    var players: std.ArrayList(Player) = .empty;
    var by_activity = false;

    for ([_]dbus.Kind{ .session, .system }) |kind| {
        const bus = dbus.Bus.open(kind) orelse {
            if (kind == .session) log.warn("there is no session bus, so no player can be reached", .{});
            continue;
        };
        defer bus.close();

        const listed = try namesOn(arena, bus);
        by_activity = by_activity or listed.by_activity;
        for (listed.names) |name| try players.append(arena, try playerOn(arena, bus, kind, name));
    }

    if (!by_activity) rankByStatus(players.items);
    return .{ .players = players.items };
}

pub fn run(player: Player, command: Command) bool {
    const bus = dbus.Bus.open(player.bus) orelse return false;
    defer bus.close();

    const reply = bus.call(.{
        .name = player.name,
        .path = object_path,
        .interface = player_interface,
        .method = command.method(),
        .reply = "()",
        .timeout_ms = timeout_ms,
    }) orelse return false;
    dbus.drop(reply);
    return true;
}

fn namesOn(arena: Allocator, bus: dbus.Bus) Allocator.Error!Names {
    const reply = bus.call(.{
        .name = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .method = "ListNames",
        .reply = "(as)",
        .timeout_ms = timeout_ms,
    }) orelse return .{};
    defer dbus.drop(reply);

    const listed = dbus.childAt(reply, 0);
    defer dbus.drop(listed);

    const all = try dbus.strings(arena, listed);
    if (contains(all, playerctld)) {
        if (try activityOn(arena, bus)) |ordered| {
            return .{ .names = try playersAmong(arena, ordered), .by_activity = true };
        }
    }

    const names = try playersAmong(arena, all);
    std.mem.sort([:0]const u8, names, {}, before);
    return .{ .names = names };
}

fn activityOn(arena: Allocator, bus: dbus.Bus) Allocator.Error!?[]const []const u8 {
    const found = bus.property(.{
        .name = playerctld,
        .path = object_path,
        .interface = playerctld_interface,
        .method = "Get",
        .timeout_ms = timeout_ms,
    }, "PlayerNames") orelse {
        log.warn("cannot read the players of playerctld, so they are taken in name order", .{});
        return null;
    };
    defer dbus.drop(found);
    return try dbus.strings(arena, found);
}

fn playersAmong(arena: Allocator, names: []const []const u8) Allocator.Error![][:0]const u8 {
    var players: std.ArrayList([:0]const u8) = .empty;
    for (names) |name| {
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) continue;
        if (std.mem.eql(u8, name, playerctld)) continue;
        try players.append(arena, try arena.dupeSentinel(u8, name, 0));
    }
    return players.items;
}

fn before(_: void, left: [:0]const u8, right: [:0]const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn contains(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

fn rankByStatus(players: []Player) void {
    std.mem.sort(Player, players, {}, louder);
}

fn louder(_: void, left: Player, right: Player) bool {
    return Status.rank(left.status) < Status.rank(right.status);
}

fn playerOn(arena: Allocator, bus: dbus.Bus, kind: dbus.Kind, name: [:0]const u8) Allocator.Error!Player {
    var player: Player = .{ .bus = kind, .name = name };

    const call: dbus.Call = .{
        .name = name,
        .path = object_path,
        .interface = player_interface,
        .method = "GetAll",
        .timeout_ms = timeout_ms,
    };
    if (bus.properties(call)) |found| {
        defer dbus.drop(found);
        try fill(arena, &player, found);
    }

    var root = call;
    root.interface = root_interface;
    root.quiet = true;
    if (bus.property(root, "Identity")) |found| {
        defer dbus.drop(found);
        player.identity = try arena.dupe(u8, dbus.text(found));
    }
    return player;
}

fn fill(arena: Allocator, player: *Player, properties: *c.GVariant) Allocator.Error!void {
    player.status = Status.of(try dbus.textOf(arena, properties, "PlaybackStatus"));
    player.can_play = dbus.flagOf(properties, "CanPlay");
    player.can_pause = dbus.flagOf(properties, "CanPause");
    player.can_go_next = dbus.flagOf(properties, "CanGoNext");
    player.can_go_previous = dbus.flagOf(properties, "CanGoPrevious");

    const metadata = dbus.lookup(properties, "Metadata") orelse return;
    defer dbus.drop(metadata);
    if (!dbus.isKind(metadata, "a{sv}")) return;

    player.track = .{
        .title = try dbus.textOf(arena, metadata, "xesam:title"),
        .artists = try dbus.stringsOf(arena, metadata, "xesam:artist"),
        .album = try dbus.textOf(arena, metadata, "xesam:album"),
        .art = try dbus.textOf(arena, metadata, "mpris:artUrl"),
    };
}

const testing = std.testing;

fn filled(arena: Allocator, properties: [:0]const u8) !Player {
    const parsed = dbus.parse("a{sv}", properties).?;
    defer dbus.drop(parsed);

    var player: Player = .{ .bus = .session, .name = prefix ++ "spotify" };
    try fill(arena, &player, parsed);
    return player;
}

test "the properties of a player are read with its track" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const player = try filled(arena.allocator(),
        \\{'PlaybackStatus': <'Playing'>, 'CanPlay': <true>, 'CanPause': <true>,
        \\ 'CanGoNext': <true>, 'CanGoPrevious': <false>, 'Volume': <1.0>,
        \\ 'Metadata': <{'xesam:title': <'Get Lucky'>, 'xesam:artist': <['Daft Punk', 'Pharrell Williams']>,
        \\   'xesam:album': <'Random Access Memories'>,
        \\   'mpris:artUrl': <'https://i.scdn.co/image/ab67616d0000b273'>,
        \\   'mpris:trackid': <objectpath '/com/spotify/track/2Foc5Q5nqNiosCNqttzHof'>}>}
    );

    try testing.expectEqual(@as(?Status, .playing), player.status);
    try testing.expect(player.can(.play) and player.can(.pause) and player.can(.go_next));
    try testing.expect(!player.can(.go_previous));
    try testing.expectEqualStrings("Get Lucky", player.track.title);
    const artist = try player.track.artist(arena.allocator());
    try testing.expectEqualStrings("Daft Punk, Pharrell Williams", artist);
    try testing.expectEqualStrings("Random Access Memories", player.track.album);
    try testing.expectEqualStrings("https://i.scdn.co/image/ab67616d0000b273", player.track.art);
}

test "a single artist string, a missing album and an odd status are read as such" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const player = try filled(arena.allocator(),
        \\{'PlaybackStatus': <'Buffering'>, 'CanPlay': <true>,
        \\ 'Metadata': <{'xesam:title': <'Radio'>, 'xesam:artist': <'Somebody'>}>}
    );

    try testing.expectEqual(@as(?Status, null), player.status);
    try testing.expectEqualStrings("Somebody", try player.track.artist(arena.allocator()));
    try testing.expectEqualStrings("", player.track.album);
    try testing.expectEqualStrings("", player.track.art);
}

test "metadata of the wrong type and missing capabilities leave a player that can do nothing" {
    const strict: dbus.Criticals = .fatal();
    defer strict.restore();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const player = try filled(arena.allocator(), "{'Metadata': <'not a dictionary'>, 'CanPlay': <'yes'>}");

    try testing.expectEqualStrings("", player.track.title);
    try testing.expect(!player.can(.play));
}

test "only player names are kept, without playerctld itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const names = try playersAmong(arena.allocator(), &.{
        "org.freedesktop.DBus",
        prefix ++ "vlc",
        ":1.42",
        playerctld,
        prefix,
        prefix ++ "spotify",
    });

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings(prefix ++ "vlc", names[0]);
    try testing.expectEqualStrings(prefix ++ "spotify", names[1]);
}

fn named(name: [:0]const u8, status: ?Status) Player {
    return .{ .bus = .session, .name = name, .status = status, .can_play = true };
}

test "a playing player goes first, then a paused one, and the rest keeps its order" {
    var players = [_]Player{
        named(prefix ++ "chromium", .paused),
        named(prefix ++ "firefox", null),
        named(prefix ++ "mpd", .stopped),
        named(prefix ++ "spotify", .playing),
        named(prefix ++ "vlc", .paused),
    };
    rankByStatus(&players);

    try testing.expectEqualStrings(prefix ++ "spotify", players[0].name);
    try testing.expectEqualStrings(prefix ++ "chromium", players[1].name);
    try testing.expectEqualStrings(prefix ++ "vlc", players[2].name);
    try testing.expectEqualStrings(prefix ++ "firefox", players[3].name);
    try testing.expectEqualStrings(prefix ++ "mpd", players[4].name);
}

test "each command goes to the first player that can do it" {
    var paused = named(prefix ++ "chromium", .paused);
    paused.can_go_next = false;
    var playing = named(prefix ++ "spotify", .playing);
    playing.can_go_next = true;
    playing.can_pause = true;

    const snapshot: Snapshot = .{ .players = &.{ paused, playing } };

    try testing.expectEqualStrings(prefix ++ "chromium", snapshot.target(Command.play.needs()).?.name);
    try testing.expectEqualStrings(prefix ++ "spotify", snapshot.target(Command.next.needs()).?.name);
    try testing.expectEqualStrings(prefix ++ "spotify", snapshot.target(Command.pause.needs()).?.name);
    try testing.expectEqual(@as(?Player, null), snapshot.target(Command.previous.needs()));
    try testing.expectEqual(@as(?Player, null), (Snapshot{}).target(.play));
}

test "the capability of a command follows playerctl" {
    try testing.expectEqual(Capability.play, Command.play.needs());
    try testing.expectEqual(Capability.play, Command.play_pause.needs());
    try testing.expectEqual(Capability.play, Command.stop.needs());
    try testing.expectEqual(Capability.pause, Command.pause.needs());
    try testing.expectEqual(Capability.go_next, Command.next.needs());
    try testing.expectEqual(Capability.go_previous, Command.previous.needs());
}

test "a player is named by its identity, or by its bus name without the prefix" {
    var player = named(prefix ++ "firefox.instance_1_23", null);
    try testing.expectEqualStrings("firefox.instance_1_23", player.label());
    player.identity = "Mozilla Firefox";
    try testing.expectEqualStrings("Mozilla Firefox", player.label());
}
