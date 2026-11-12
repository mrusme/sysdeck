const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const overlay = @import("../screenshot/overlay.zig");
const rank = @import("core").rank;
const sway = @import("sway.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const tallied = @import("tallied.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.screenshot);

pub const table = tables.screenshot;

const keyword = "screenshot";
const title: [:0]const u8 = "Screenshot";
const detail: [:0]const u8 = "Select a region, a window or a screen";
const fields = [_][]const u8{keyword};

const Entry = tallied.Tallied(void);

const icon_names = [_][:0]const u8{
    "applets-screenshooter",
    "accessories-screenshot",
    "camera-photo",
    "image-x-generic",
};

const Action = enum(u64) {
    region = 1,
    window = 2,
    screen = 3,

    fn mode(self: Action) overlay.Mode {
        return switch (self) {
            .region => .region,
            .window => .window,
            .screen => .screen,
        };
    }
};

pub const Requested = Callback(fn (mode: overlay.Mode) void);

pub const Index = struct {
    entry: Entry,
    icon: [:0]const u8,
    windows: bool,
    requested: Requested,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Index),
            .verb = "Capture",
        };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.entry.hits(owner, text, .{ .max_rows = 1, .icon = .{ .name = self.icon } });
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.entry.picks(owner, limit, .{ .name = self.icon });
    }

    pub fn choose(self: *Index, _: Allocator, id: u64) subroutines.Outcome {
        if (self.entry.find(id) == null) return .keep;

        self.entry.note(id);
        self.requested.call(.{.any});
        return .keep;
    }

    pub fn actions(
        self: *Index,
        arena: Allocator,
        _: u64,
    ) subroutines.Error![]const subroutines.Action {
        var found: std.ArrayList(subroutines.Action) = .empty;

        try found.append(arena, .{
            .id = @backingInt(Action.region),
            .title = "Region",
            .detail = "Drag a rectangle",
        });

        if (self.windows) try found.append(arena, .{
            .id = @backingInt(Action.window),
            .title = "Window",
            .detail = "Pick one window",
        });

        try found.append(arena, .{
            .id = @backingInt(Action.screen),
            .title = "Screen",
            .detail = "Pick one whole screen",
        });

        return found.items;
    }

    pub fn perform(self: *Index, _: Allocator, id: u64, action: u64) subroutines.Outcome {
        const wanted = std.enums.fromInt(Action, action) orelse return .keep;
        if (self.entry.find(id) == null) return .keep;

        self.entry.note(id);
        self.requested.call(.{wanted.mode()});
        return .keep;
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.entry.counters(id);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.entry.forget(id);
    }

    pub fn retire(self: *Index) void {
        self.entry.retire();
    }
};

fn entryOf(gpa: Allocator, io: std.Io, store: ?*store_mod.Store) Allocator.Error!Entry {
    var entry: Entry = try .init(gpa, io, table, null);
    errdefer entry.retire();

    const items = [_]Entry.Item{.{
        .key = keyword,
        .title = title,
        .detail = detail,
        .fields = &fields,
        .payload = {},
    }};
    entry.publish(try entry.begin(), &items);
    entry.prepare(store);
    return entry;
}

fn enabled(wanted: bool, environ: *const std.process.Environ.Map) bool {
    if (!wanted) return false;

    const display = environ.get("WAYLAND_DISPLAY") orelse return false;
    return display.len > 0;
}

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!enabled(context.wanted("screenshot"), context.environ)) {
        if (context.asked("screenshot")) {
            log.warn(
                "[sources.screenshot] enable is true, however this is no Wayland session, " ++
                    "so nothing can be captured",
                .{},
            );
        }
        return null;
    }

    const requested = context.requested orelse return null;
    return .{
        .entry = try entryOf(context.gpa, context.io, context.store),
        .icon = subroutines.themedIcon(&icon_names),
        .windows = sway.enabled(context.settings.sources.sway.enable, context.environ),
        .requested = requested,
    };
}

const testing = std.testing;
const tmpPath = @import("core").xdg.tmpPath;

const Asked = struct {
    count: usize = 0,
    last: ?overlay.Mode = null,

    fn take(self: *Asked, mode: overlay.Mode) void {
        self.count += 1;
        self.last = mode;
    }
};

fn indexOf(asked: *Asked, store: ?*store_mod.Store) !Index {
    return .{
        .entry = try entryOf(testing.allocator, testing.io, store),
        .icon = "camera-photo",
        .windows = true,
        .requested = .of(Asked, Asked.take, asked),
    };
}

fn rowOf(self: *Index, owner: *subroutines.Owner, text: []const u8) !subroutines.Hit {
    const found = try self.run(owner, text);
    try testing.expectEqual(1, found.hits.len);
    return found.hits[0];
}

test "the word screenshot is matched and a stray query is not" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var asked: Asked = .{};
    var self = try indexOf(&asked, null);
    defer self.retire();

    for ([_][]const u8{ "screenshot", "shot", "scr" }) |query| {
        try testing.expectEqualStrings(title, (try rowOf(&self, owner, query)).row.title);
    }
    try testing.expectEqual(subroutines.Output.nothing, try self.run(owner, "zzz"));
    try testing.expectEqual(subroutines.Output.nothing, try self.run(owner, " "));
}

test "a choice adds the bonus every source's entries get" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var asked: Asked = .{};
    var self = try indexOf(&asked, null);
    defer self.retire();

    const first = try rowOf(&self, owner, "screen");
    try testing.expectEqual(148, first.score);
    try testing.expectEqualStrings("camera-photo", first.row.icon.name);

    try testing.expectEqual(subroutines.Outcome.keep, self.choose(testing.allocator, first.row.id));
    try testing.expectEqual(1, asked.count);
    try testing.expectEqual(overlay.Mode.any, asked.last.?);

    const second = try rowOf(&self, owner, "screen");
    try testing.expectEqual(162, second.score);
}

test "the entry is recommended from its second choice" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var asked: Asked = .{};
    var self = try indexOf(&asked, null);
    defer self.retire();

    const id = (try rowOf(&self, owner, "screenshot")).row.id;

    _ = self.choose(testing.allocator, id);
    try testing.expectEqual(subroutines.Output.nothing, try self.picks(owner, 5));

    _ = self.choose(testing.allocator, id);
    const picked = try self.picks(owner, 5);
    try testing.expectEqual(1, picked.hits.len);
    try testing.expectEqualStrings(title, picked.hits[0].row.title);
    try testing.expectEqual(id, picked.hits[0].row.id);
}

test "an Alt action counts toward the entry and asks for its mode" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var asked: Asked = .{};
    var self = try indexOf(&asked, null);
    defer self.retire();

    const id = (try rowOf(&self, owner, "screenshot")).row.id;

    _ = self.perform(testing.allocator, id, @backingInt(Action.window));
    try testing.expectEqual(overlay.Mode.window, asked.last.?);
    try testing.expectEqual(1, self.entry.counts.weight(id).chosen);

    _ = self.perform(testing.allocator, id, 9);
    _ = self.perform(testing.allocator, id + 1, @backingInt(Action.screen));
    _ = self.choose(testing.allocator, id + 1);
    try testing.expectEqual(1, asked.count);
    try testing.expectEqual(1, self.entry.counts.weight(id).chosen);
}

test "the choices are kept in the counts table for the next run" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer, "sysdeck.db");

    var asked: Asked = .{};
    {
        const store = try store_mod.Store.open(testing.allocator, testing.io, path);
        defer store.close();

        var first = try indexOf(&asked, store);
        defer first.retire();

        const id = (try rowOf(&first, owner, "screenshot")).row.id;
        _ = first.choose(testing.allocator, id);
        _ = first.choose(testing.allocator, id);
    }

    const store = try store_mod.Store.open(testing.allocator, testing.io, path);
    defer store.close();

    var again = try indexOf(&asked, store);
    defer again.retire();

    const picked = try again.picks(owner, 5);
    try testing.expectEqual(1, picked.hits.len);
    try testing.expectEqualStrings(title, picked.hits[0].row.title);
}

test "an action number maps to the mode it names" {
    try testing.expectEqual(overlay.Mode.region, Action.region.mode());
    try testing.expectEqual(overlay.Mode.window, Action.window.mode());
    try testing.expectEqual(overlay.Mode.screen, Action.screen.mode());

    try testing.expectEqual(null, std.enums.fromInt(Action, 0));
    try testing.expectEqual(null, std.enums.fromInt(Action, 4));
}

test "the subroutine is off without a Wayland session" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try testing.expect(!enabled(true, &environ));

    try environ.put("WAYLAND_DISPLAY", "wayland-1");
    try testing.expect(enabled(true, &environ));
    try testing.expect(!enabled(false, &environ));
}
