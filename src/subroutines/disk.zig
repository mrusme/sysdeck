const std = @import("std");
const config_mod = @import("../config.zig");
const copy = @import("../system/copy.zig");
const gio = @import("../gtk/gio.zig");
const indexed = @import("indexed.zig");
const launch = @import("../system/launch.zig");
const model = @import("../model.zig");
const location_mod = @import("disk/location.zig");
const media = @import("core").media;
const rank = @import("core").rank;
const source = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tally = @import("core").counts;
const tables = @import("core").tables;
const terminal_mod = @import("../system/terminal.zig");
const walk = @import("disk/walk.zig");
const zqlite = @import("zqlite");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.disk);

pub const table = tables.disk;
pub const Location = location_mod.Location;

const max_rows = 200;
const browse_rows = 100;
const fallback_icon: [:0]const u8 = "text-x-generic";

const Action = enum(u64) { copy = 1 };

pub const Index = struct {
    indexed: indexed.Indexed,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    terminal: ?terminal_mod.Terminal,
    arena: std.heap.ArenaAllocator,
    locations: []const Location,
    due: []bool,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Search),
            .verb = "Open",
        };
    }

    pub fn browse(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Browse),
            .verb = "Open",
        };
    }

    fn attached(self: *Index) indexed.Media {
        return .{ .context = self, .load = &loadPath };
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("disk")) return null;

    const gpa = context.gpa;
    const stamp = context.stamp;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    const locations = try resolved(
        arena.allocator(),
        context.environ,
        context.settings.sources.disk,
        context.settings.index,
    );
    if (locations.len == 0) {
        arena.deinit();
        if (context.asked("disk")) {
            log.warn(
                "[sources.disk] enable is true, however no locations entry could be used, " ++
                    "so the disk browser is left out",
                .{},
            );
        }
        return null;
    }

    const due = try gpa.alloc(bool, locations.len);
    errdefer gpa.free(due);
    @memset(due, true);

    var self: Index = .{
        .indexed = try .init(gpa, context.io, table, stamp, context.published),
        .io = context.io,
        .environ = context.environ,
        .terminal = context.terminal,
        .arena = arena,
        .locations = locations,
        .due = due,
    };

    const found = self.indexed.prepare(context.store) orelse {
        self.indexed.source.needs_refresh = true;
        return self;
    };

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    for (locations, due) |location, *wanted_now| {
        wanted_now.* = expired(found, scratch.allocator(), location, stamp);
    }
    self.indexed.source.needs_refresh = pending(due);

    const records = self.indexed.stored(found, scratch.allocator()) orelse return self;

    const kept = try known(scratch.allocator(), locations, records);
    if (kept.len < records.len) self.indexed.source.needs_refresh = true;
    if (kept.len == 0) return self;

    try self.indexed.adopt(kept, &iconOf, null);
    return self;
}

fn resolved(
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    wanted: config_mod.Config.Sources.Disk,
    settings: config_mod.Config.Index,
) Allocator.Error![]const Location {
    var found: std.ArrayList(Location) = .empty;

    for (wanted.locations) |entry| {
        const age = settings.age(entry.max_age_minutes);
        const location = (try location_mod.resolve(arena, environ, entry, age)) orelse continue;

        if (taken(found.items, location.id)) {
            log.warn(
                "the [sources.disk] location \"{s}\" is configured more than once, " ++
                    "so the second one is left out",
                .{location.id},
            );
            continue;
        }

        try found.append(arena, location);
    }

    return found.toOwnedSlice(arena);
}

const Search = struct {
    pub const Context = Index;

    pub const choose = shared.choose;
    pub const stale = shared.stale;
    pub const refresh = shared.refresh;
    pub const actions = shared.actions;
    pub const perform = shared.perform;
    pub const counters = shared.counters;
    pub const forget = shared.forget;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.indexed.hits(owner, text, .{
            .max_rows = max_rows,
            .media = self.attached(),
        });
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.indexed.picks(owner, .{ .limit = limit, .media = self.attached() });
    }

    pub fn retire(self: *Index, store: ?*store_mod.Store) void {
        self.indexed.retire(store);
        self.indexed.gpa.free(self.due);
        self.arena.deinit();
    }
};

const Browse = struct {
    pub const Context = Index;

    pub const choose = shared.choose;
    pub const actions = shared.actions;
    pub const perform = shared.perform;
    pub const counters = shared.counters;
    pub const forget = shared.forget;

    pub fn stale(_: *Index) bool {
        return false;
    }

    pub fn refresh(_: *Index) void {}

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.indexed.hits(owner, text, .{
            .max_rows = browse_rows,
            .idle = .ranked,
            .media = self.attached(),
        });
    }

    pub fn retire(_: *Index, _: ?*store_mod.Store) void {}
};

const shared = struct {
    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.indexed.counters(id);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.indexed.forget(id);
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        const of = self.indexed.source.snapshot();
        const at = of.find(id) orelse return .keep;

        const entry = of.entries[at];
        if (!launch.file(gpa, self.terminal, entry.detail, entry.mime)) return .keep;

        self.indexed.noteChosen(id);
        return .close;
    }

    pub fn actions(
        self: *Index,
        arena: Allocator,
        id: u64,
    ) subroutines.Error![]const subroutines.Action {
        const entry = self.indexed.entryAt(id) orelse return &.{};

        const found = try arena.alloc(subroutines.Action, 1);
        found[0] = .{
            .id = @intFromEnum(Action.copy),
            .title = "Copy path",
            .detail = entry.detail,
        };
        return found;
    }

    pub fn perform(self: *Index, gpa: Allocator, id: u64, action: u64) subroutines.Outcome {
        const wanted = std.enums.fromInt(Action, action) orelse return .keep;

        const of = self.indexed.source.snapshot();
        const at = of.find(id) orelse return .keep;

        switch (wanted) {
            .copy => {
                if (!copy.put(gpa, self.environ, .{ .bytes = of.entries[at].detail })) return .keep;

                self.indexed.noteChosen(id);
                return .close;
            },
        }
    }

    pub fn stale(self: *Index) bool {
        return self.indexed.stale();
    }

    pub fn refresh(self: *Index) void {
        log.debug("refreshing the index", .{});

        var arena: std.heap.ArenaAllocator = .init(self.indexed.gpa);
        defer arena.deinit();

        const records = rebuild(arena.allocator(), self) catch |err| {
            return source.report(table, "rebuild", err);
        };

        self.indexed.republish(records, &iconOf, null);
    }
};

fn rebuild(arena: Allocator, self: *Index) ![]store_mod.Record {
    const gpa = self.indexed.gpa;
    const file = self.indexed.path orelse return gather(arena, self);

    const conn = try store_mod.connect(file, .{});
    defer conn.close();

    try store_mod.create(gpa, conn, table);
    try forgetGone(gpa, arena, conn, self.locations);

    for (self.locations, self.due) |location, due| {
        if (!due) continue;

        const records = collect(arena, self.io, location) orelse continue;
        try store_mod.replace(
            gpa,
            conn,
            table,
            .{ .adapter = location.id },
            records,
            self.indexed.stamp,
        );

        const name = try store_mod.qualify(arena, table, location.id);
        try store_mod.writeSetting(conn, name, try location.fingerprint(arena));
    }

    return store_mod.read(arena, conn, table);
}

fn gather(arena: Allocator, self: *Index) Allocator.Error![]store_mod.Record {
    var records: std.ArrayList(store_mod.Record) = .empty;

    for (self.locations, self.due) |location, due| {
        if (!due) continue;
        try records.appendSlice(arena, collect(arena, self.io, location) orelse continue);
    }

    return records.toOwnedSlice(arena);
}

fn collect(arena: Allocator, io: std.Io, location: Location) ?[]store_mod.Record {
    const records = walk.collect(arena, io, location) catch |err| {
        log.warn(
            "cannot read the [sources.disk] location \"{s}\" at {s}: {t}, " ++
                "so what was indexed before is kept",
            .{ location.id, location.root, err },
        );
        return null;
    };

    log.debug("{s} collected {d} entries", .{ location.id, records.len });
    return records;
}

fn forgetGone(
    gpa: Allocator,
    arena: Allocator,
    conn: zqlite.Conn,
    locations: []const Location,
) !void {
    const ids = try names(arena, locations);

    for (try store_mod.present(arena, conn, table)) |id| {
        if (taken(locations, id)) continue;
        try store_mod.dropSetting(conn, try store_mod.qualify(arena, table, id));
    }

    try store_mod.keepAdapters(gpa, conn, table, ids);
}

fn expired(
    store: *store_mod.Store,
    arena: Allocator,
    location: Location,
    stamp: i64,
) bool {
    const name = store_mod.qualify(arena, table, location.id) catch return true;
    if (store_mod.stale(store.updatedAt(name), stamp, location.max_age_minutes)) return true;

    const wanted = location.fingerprint(arena) catch return true;
    const written = store.setting(arena, name) orelse return true;

    if (std.mem.eql(u8, wanted, written)) return false;

    log.debug("the {s} location was configured differently, so it is indexed again", .{
        location.id,
    });
    return true;
}

fn known(
    arena: Allocator,
    locations: []const Location,
    records: []const store_mod.Record,
) Allocator.Error![]store_mod.Record {
    var kept: std.ArrayList(store_mod.Record) = .empty;

    for (records) |record| {
        if (!taken(locations, record.adapter)) continue;
        try kept.append(arena, record);
    }

    return kept.toOwnedSlice(arena);
}

fn names(arena: Allocator, locations: []const Location) Allocator.Error![]const []const u8 {
    const found = try arena.alloc([]const u8, locations.len);
    for (locations, 0..) |location, at| found[at] = location.id;
    return found;
}

fn taken(locations: []const Location, id: []const u8) bool {
    for (locations) |location| {
        if (std.mem.eql(u8, location.id, id)) return true;
    }
    return false;
}

fn pending(due: []const bool) bool {
    for (due) |wanted| {
        if (wanted) return true;
    }
    return false;
}

fn iconOf(_: ?*anyopaque, arena: Allocator, record: store_mod.Record) model.Icon {
    if (record.mime.len == 0) return .{ .name = fallback_icon };

    const mime = arena.dupeZ(u8, record.mime) catch return .{ .name = fallback_icon };
    const icon = gio.g_content_type_get_icon(mime.ptr) orelse return .{ .name = fallback_icon };
    return .{ .gicon = icon };
}

fn loadPath(context: ?*anyopaque, _: Allocator, id: u64) ?media.Payload {
    const self: *Index = @ptrCast(@alignCast(context orelse return null));
    const entry = self.indexed.entryAt(id) orelse return null;
    return .{ .path = entry.detail };
}

test {
    _ = location_mod;
    _ = walk;
}

const testing = std.testing;

const rows = [_]store_mod.Record{
    .{
        .adapter = "documents",
        .key = "/home/tester/documents/notes.txt",
        .title = "notes.txt",
        .detail = "/home/tester/documents/notes.txt",
        .icon = "",
        .haystack = "notes.txt",
        .mime = "text/plain",
    },
    .{
        .adapter = "downloads",
        .key = "/home/tester/downloads/zig.tar.xz",
        .title = "zig.tar.xz",
        .detail = "/home/tester/downloads/zig.tar.xz",
        .icon = "",
        .haystack = "zig.tar.xz",
        .mime = "application/x-xz",
    },
};

test "rows of a location that is no longer configured are left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const locations = [_]Location{.{ .id = "documents", .root = "/home/tester/documents" }};
    const kept = try known(arena.allocator(), &locations, &rows);

    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("documents", kept[0].adapter);

    const nothing = try known(arena.allocator(), &.{}, &rows);
    try testing.expectEqual(@as(usize, 0), nothing.len);
}

test "an entry offers copying its path, and an unknown row offers nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self: Index = .{
        .indexed = try .init(testing.allocator, testing.io, table, 0, null),
        .io = testing.io,
        .environ = &environ,
        .terminal = null,
        .arena = .init(testing.allocator),
        .locations = &.{},
        .due = &.{},
    };
    defer {
        self.indexed.retire(null);
        self.arena.deinit();
    }
    try self.indexed.adopt(&rows, &iconOf, null);

    const wanted = tally.idOf("documents", "/home/tester/documents/notes.txt");
    const found = try shared.actions(&self, arena.allocator(), wanted);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u64, @intFromEnum(Action.copy)), found[0].id);
    try testing.expectEqualStrings("Copy path", found[0].title);
    try testing.expectEqualStrings("/home/tester/documents/notes.txt", found[0].detail);

    const none = try shared.actions(&self, arena.allocator(), 7);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "a row's media handle opens its own file, also after a refresh reordered the index" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self: Index = .{
        .indexed = try .init(testing.allocator, testing.io, table, 0, null),
        .io = testing.io,
        .environ = &environ,
        .terminal = null,
        .arena = .init(testing.allocator),
        .locations = &.{},
        .due = &.{},
    };
    defer {
        self.indexed.retire(null);
        self.arena.deinit();
    }
    try self.indexed.adopt(&rows, &iconOf, null);

    const found = try Search.run(&self, owner, "notes");
    const handle = found.hits[0].row.media.?;

    const reordered = [_]store_mod.Record{ rows[1], rows[0] };
    try self.indexed.adopt(&reordered, &iconOf, null);

    const payload = handle.open(arena.allocator());
    try testing.expect(payload != null);
    try testing.expectEqualStrings("/home/tester/documents/notes.txt", payload.?.path);
}

test "only the first action number is an action" {
    try testing.expectEqual(@as(?Action, .copy), std.enums.fromInt(Action, 1));
    try testing.expectEqual(@as(?Action, null), std.enums.fromInt(Action, 0));
    try testing.expectEqual(@as(?Action, null), std.enums.fromInt(Action, 2));
}

test "a location is due when any one of them is" {
    try testing.expect(!pending(&.{ false, false }));
    try testing.expect(pending(&.{ false, true }));
    try testing.expect(!pending(&.{}));
}

test "a location configured twice is taken once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/tester");

    const locations = try resolved(arena.allocator(), &environ, .{ .locations = &.{
        .{ .id = "documents", .path = "~/documents" },
        .{ .id = "documents", .path = "~/other" },
        .{ .id = "", .path = "~/nameless" },
        .{ .id = "downloads", .path = "~/downloads", .max_age_minutes = 15 },
    } }, .{ .max_age_minutes = 90 });

    try testing.expectEqual(@as(usize, 2), locations.len);
    try testing.expectEqualStrings("/home/tester/documents", locations[0].root);
    try testing.expectEqual(@as(i64, 90), locations[0].max_age_minutes);
    try testing.expectEqualStrings("downloads", locations[1].id);
    try testing.expectEqual(@as(i64, 15), locations[1].max_age_minutes);
}
