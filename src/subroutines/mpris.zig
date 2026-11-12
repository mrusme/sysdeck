const std = @import("std");
const icons = @import("core").icons;
const mpris = @import("../system/mpris.zig");
const notify = @import("../system/notify.zig");
const picture = @import("../system/picture.zig");
const rank = @import("core").rank;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const tallied = @import("tallied.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.mpris);

pub const table = tables.mpris;

const art_budget: std.Io.Duration = .fromSeconds(2);
const art_side = 256;
const local_art_bytes = 16 << 20;
const asking = "What's playing?";
const start_icon = "media-playback-start-symbolic";

const Action = union(enum) {
    send: mpris.Command,
    show,

    fn needs(self: Action) mpris.Capability {
        return switch (self) {
            .send => |command| command.needs(),
            .show => .play,
        };
    }
};

const Entry = struct {
    title: [:0]const u8,
    icons: []const [:0]const u8,
    action: Action,
};

const entries = [_]Entry{
    .{ .title = "Play", .icons = &.{start_icon}, .action = .{ .send = .play } },
    .{ .title = "Pause", .icons = &.{"media-playback-pause-symbolic"}, .action = .{ .send = .pause } },
    .{ .title = "Play/Pause", .icons = &.{start_icon}, .action = .{ .send = .play_pause } },
    .{ .title = "Stop", .icons = &.{"media-playback-stop-symbolic"}, .action = .{ .send = .stop } },
    .{ .title = "Next", .icons = &.{"media-skip-forward-symbolic"}, .action = .{ .send = .next } },
    .{ .title = "Previous", .icons = &.{"media-skip-backward-symbolic"}, .action = .{ .send = .previous } },
    .{ .title = asking, .icons = &.{ "audio-x-generic-symbolic", "audio-x-generic" }, .action = .show },
};

const Commands = tallied.Tallied(Action);

pub const Message = struct {
    summary: []const u8,
    body: []const u8,
};

pub const Index = struct {
    commands: Commands,
    gpa: Allocator,
    io: std.Io,
    settled: ?subroutines.Settled,
    arena: std.heap.ArenaAllocator,
    known: ?mpris.Snapshot = null,
    reading: std.Io.Mutex = .init,
    work: std.Io.Group = .init,
    client: std.http.Client,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Index),
            .verb = "Turn it up!",
        };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        const found = try self.commands.hits(owner, text, .{ .max_rows = entries.len, .counted = false });
        const matched = switch (found) {
            .hits => |hits| hits,
            else => return .nothing,
        };
        return self.annotated(owner.allocator(), matched, try self.players());
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.commands.picks(owner, limit, .none);
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.commands.counters(id);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.commands.forget(id);
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        const found = self.commands.find(id) orelse return .keep;
        return switch (found.payload) {
            .send => |command| self.send(gpa, id, found.title, command),
            .show => self.show(id),
        };
    }

    pub fn retire(self: *Index) void {
        self.work.await(self.io) catch |err| switch (err) {
            error.Canceled => {},
        };
        self.client.deinit();
        self.commands.retire();
        self.arena.deinit();
    }

    fn players(self: *Index) Allocator.Error!mpris.Snapshot {
        self.reading.lockUncancelable(self.io);
        defer self.reading.unlock(self.io);

        if (self.known) |found| return found;
        const found = try mpris.read(self.arena.allocator());
        self.known = found;
        return found;
    }

    fn annotated(
        self: *Index,
        arena: Allocator,
        matched: []const subroutines.Hit,
        snapshot: mpris.Snapshot,
    ) subroutines.Error!subroutines.Output {
        var kept: std.ArrayList(subroutines.Hit) = .empty;
        var ids: std.ArrayList(u64) = .empty;

        for (matched) |hit| {
            const found = self.commands.find(hit.row.id) orelse continue;
            const player = snapshot.target(found.payload.needs()) orelse continue;

            var shown = hit;
            shown.row.detail = try detailOf(arena, found.payload, player);
            try kept.append(arena, shown);
            try ids.append(arena, hit.row.id);
        }

        self.commands.noteShown(ids.items);
        if (kept.items.len == 0) return .nothing;
        return .{ .hits = kept.items };
    }

    fn send(
        self: *Index,
        gpa: Allocator,
        id: u64,
        title: []const u8,
        command: mpris.Command,
    ) subroutines.Outcome {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const snapshot = mpris.read(arena.allocator()) catch return .keep;
        const player = snapshot.target(command.needs()) orelse {
            missing(snapshot, title);
            return .close;
        };

        if (mpris.run(player, command)) self.commands.note(id);
        return .close;
    }

    fn show(self: *Index, id: u64) subroutines.Outcome {
        self.work.concurrent(self.io, tell, .{ self, id }) catch |err| {
            log.warn("cannot ask what is playing: {t}", .{err});
            return .keep;
        };
        return .busy;
    }

    fn tell(self: *Index, id: u64) void {
        defer if (self.settled) |found| found.call(.{.close});

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        const snapshot = mpris.read(scratch) catch return exhausted();
        const player = snapshot.target(.play) orelse return missing(snapshot, asking);

        const message = messageOf(scratch, player) catch return exhausted();
        const image = self.artOf(player.track.art);
        defer if (image) |found| found.deinit();

        const sent = notify.send(self.gpa, .{
            .summary = message.summary,
            .body = message.body,
            .urgency = .low,
            .image = image,
        });
        if (sent) self.commands.note(id);
    }

    fn artOf(self: *Index, url: []const u8) ?notify.Image {
        if (url.len == 0) return null;

        const bytes = self.loadWithin(url) orelse return null;
        defer self.gpa.free(bytes);

        const decoded = switch (picture.decode(bytes, .{ .width = art_side, .height = art_side }, picture.budget)) {
            .picture => |found| found,
            .failed => |problem| {
                defer problem.deinit();
                log.warn("cannot decode the art at {s}: {f}, so the notification has no picture", .{
                    shortened(url),
                    problem,
                });
                return null;
            },
        };
        defer decoded.deinit();
        return .of(decoded.pixbuf);
    }

    fn loadWithin(self: *Index, url: []const u8) ?[]u8 {
        const limit: usize = if (icons.isRemote(url)) icons.max_bytes else local_art_bytes;
        const fetched = icons.loadWithin(&self.client, self.gpa, self.io, url, limit, art_budget) catch |err| {
            switch (err) {
                error.Canceled => {},
                else => log.warn("cannot load the art at {s}: {t}", .{ shortened(url), err }),
            }
            return null;
        };

        switch (fetched) {
            .image => |image| return image.bytes,
            .failed => |failure| {
                log.warn("cannot load the art at {s}: {f}, so the notification has no picture", .{
                    shortened(url),
                    failure,
                });
                return null;
            },
        }
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("mpris")) return null;

    var commands: Commands = try .init(context.gpa, context.io, table, null);
    errdefer commands.retire();

    var items: [entries.len]Commands.Item = undefined;
    inline for (entries, &items) |entry, *item| {
        item.* = .{
            .key = entry.title,
            .title = entry.title,
            .icon = .{ .name = subroutines.themedIcon(entry.icons) },
            .fields = &.{entry.title},
            .payload = entry.action,
        };
    }
    commands.publish(try commands.begin(), &items);
    commands.prepare(context.store);

    return .{
        .commands = commands,
        .gpa = context.gpa,
        .io = context.io,
        .settled = context.settled,
        .arena = .init(context.gpa),
        .client = .{ .allocator = context.gpa, .io = context.io },
    };
}

fn exhausted() void {
    log.warn("out of memory, so nothing is told", .{});
}

fn missing(snapshot: mpris.Snapshot, title: []const u8) void {
    if (snapshot.players.len == 0) {
        log.warn("no player is running, so \"{s}\" went nowhere", .{title});
    } else {
        log.warn("no running player can do \"{s}\"", .{title});
    }
}

fn detailOf(arena: Allocator, action: Action, player: mpris.Player) Allocator.Error![:0]const u8 {
    return switch (action) {
        .send => arena.dupeSentinel(u8, player.label(), 0),
        .show => playing(arena, player),
    };
}

fn playing(arena: Allocator, player: mpris.Player) Allocator.Error![:0]const u8 {
    const artist = try player.track.artist(arena);
    const title = player.track.title;

    if (artist.len > 0 and title.len > 0) {
        return arena.printSentinel("{s} · {s}", .{ artist, title }, 0);
    }
    if (title.len > 0) return arena.dupeSentinel(u8, title, 0);
    if (artist.len > 0) return arena.dupeSentinel(u8, artist, 0);
    return arena.dupeSentinel(u8, player.label(), 0);
}

pub fn messageOf(arena: Allocator, player: mpris.Player) Allocator.Error!Message {
    const track = player.track;
    const summary = if (track.title.len > 0) track.title else player.label();
    const artist = try track.artist(arena);

    const body = if (artist.len > 0 and track.album.len > 0)
        try std.mem.concat(arena, u8, &.{ artist, "\n", track.album })
    else if (artist.len > 0) artist else track.album;

    return .{ .summary = summary, .body = body };
}

fn shortened(url: []const u8) []const u8 {
    if (!std.ascii.startsWithIgnoreCase(url, "data:")) return url;
    const comma = std.mem.findScalar(u8, url, ',') orelse return "a data URL";
    return url[0..comma];
}

const testing = std.testing;
const config_mod = @import("../config.zig");
const counts_mod = @import("core").counts;

const Rig = struct {
    environ: std.process.Environ.Map,
    settings: config_mod.Config = .{},
    index: Index = undefined,
    owner: *subroutines.Owner = undefined,

    fn init(self: *Rig) !void {
        self.* = .{ .environ = .init(testing.allocator) };
        self.index = (try open(.{
            .gpa = testing.allocator,
            .io = testing.io,
            .environ = &self.environ,
            .settings = &self.settings,
        })).?;
        self.owner = try subroutines.Owner.create(testing.allocator);
    }

    fn deinit(self: *Rig) void {
        self.owner.destroy(testing.allocator);
        self.index.retire();
        self.environ.deinit();
    }

    fn titles(self: *Rig, query: []const u8) ![]const []const u8 {
        const found = try self.index.run(self.owner, query);
        const hits = switch (found) {
            .hits => |hits| hits,
            else => return &.{},
        };
        const out = try self.owner.allocator().alloc([]const u8, hits.len);
        for (hits, out) |hit, *slot| slot.* = hit.row.title;
        return out;
    }

    fn detailOf(self: *Rig, query: []const u8) ![]const u8 {
        const found = try self.index.run(self.owner, query);
        return found.hits[0].row.detail;
    }
};

const prefix = "org.mpris.MediaPlayer2.";

fn spotify() mpris.Player {
    return .{
        .bus = .session,
        .name = prefix ++ "spotify",
        .identity = "Spotify",
        .status = .playing,
        .can_play = true,
        .can_pause = true,
        .can_go_next = true,
        .can_go_previous = true,
        .track = .{
            .title = "Get Lucky",
            .artists = &.{ "Daft Punk", "Pharrell Williams" },
            .album = "Random Access Memories",
        },
    };
}

test "nothing is asked of D-Bus until a query matches, nor for the picks" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    try testing.expectEqual(@as(usize, 0), (try rig.titles("zzzz")).len);
    try testing.expectEqual(@as(usize, 0), (try rig.titles("")).len);
    _ = try rig.index.picks(rig.owner, 5);

    try testing.expectEqual(@as(?mpris.Snapshot, null), rig.index.known);
}

test "a match lists the commands with the player they go to and the track" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    const players = [_]mpris.Player{spotify()};
    rig.index.known = .{ .players = &players };

    const found = try rig.titles("play");
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("Spotify", try rig.detailOf("next"));
    try testing.expectEqualStrings("Daft Punk, Pharrell Williams · Get Lucky", try rig.detailOf("what"));
}

test "a command no player can do is left out, and no player hides them all" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var stuck = spotify();
    stuck.can_go_next = false;
    const players = [_]mpris.Player{stuck};
    rig.index.known = .{ .players = &players };

    try testing.expectEqual(@as(usize, 0), (try rig.titles("next")).len);
    try testing.expectEqual(@as(usize, 1), (try rig.titles("previous")).len);

    rig.index.known = .{};
    try testing.expectEqual(@as(usize, 0), (try rig.titles("play")).len);
}

test "only the rows that are listed are counted as shown" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var silent = spotify();
    silent.can_play = false;
    const players = [_]mpris.Player{silent};
    rig.index.known = .{ .players = &players };

    try testing.expectEqual(@as(usize, 1), (try rig.titles("pause")).len);

    const counts = &rig.index.commands.counts;
    try testing.expectEqual(@as(u32, 1), counts.weight(counts_mod.id("Pause")).shown);
    try testing.expectEqual(@as(u32, 0), counts.weight(counts_mod.id("Play/Pause")).shown);
}

test "the track reads as artist and title, or whatever part of it there is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var player = spotify();
    try testing.expectEqualStrings("Daft Punk, Pharrell Williams · Get Lucky", try playing(scratch, player));

    player.track.artists = &.{};
    try testing.expectEqualStrings("Get Lucky", try playing(scratch, player));

    player.track = .{ .artists = &.{"Daft Punk"} };
    try testing.expectEqualStrings("Daft Punk", try playing(scratch, player));

    player.track = .{};
    try testing.expectEqualStrings("Spotify", try playing(scratch, player));
}

test "the notification has the title, then the artists and the album on lines of their own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var player = spotify();
    const full = try messageOf(scratch, player);
    try testing.expectEqualStrings("Get Lucky", full.summary);
    try testing.expectEqualStrings("Daft Punk, Pharrell Williams\nRandom Access Memories", full.body);

    player.track.album = "";
    try testing.expectEqualStrings("Daft Punk, Pharrell Williams", (try messageOf(scratch, player)).body);

    player.track = .{ .album = "Live" };
    const bare = try messageOf(scratch, player);
    try testing.expectEqualStrings("Spotify", bare.summary);
    try testing.expectEqualStrings("Live", bare.body);
}

test "a data URL is shortened to its header before it is logged" {
    try testing.expectEqualStrings("data:image/png;base64", shortened("data:image/png;base64,iVBORw0KGgo="));
    try testing.expectEqualStrings("a data URL", shortened("data:broken"));
    try testing.expectEqualStrings("https://i.scdn.co/image/a", shortened("https://i.scdn.co/image/a"));
}
