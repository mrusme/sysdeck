const std = @import("std");
const list = @import("list.zig");
const rank = @import("rank.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.source);

pub const Published = struct {
    notify: ?*const fn (context: *anyopaque) void = null,
    context: *anyopaque = undefined,

    pub fn call(self: Published) void {
        const notify = self.notify orelse return;
        notify(self.context);
    }
};

pub const Counter = struct {
    shown: std.atomic.Value(u32) = .init(0),
    chosen: std.atomic.Value(u32) = .init(0),
};

pub const Entry = struct {
    adapter: []const u8,
    key: []const u8,
    title: [:0]const u8,
    detail: [:0]const u8,
    icon: list.Icon,
    haystack: []const u8,
    program: []const u8,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    haystacks: []const []const u8,
    loaded: []const rank.Weight,
    counters: []Counter,

    pub fn destroy(self: *Snapshot, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn weights(self: *Snapshot, gpa: Allocator) Allocator.Error![]rank.Weight {
        const found = try gpa.alloc(rank.Weight, self.entries.len);
        for (self.counters, self.loaded, 0..) |*counter, base, at| {
            found[at] = .{
                .shown = base.shown +| counter.shown.load(.monotonic),
                .chosen = base.chosen +| counter.chosen.load(.monotonic),
            };
        }
        return found;
    }

    pub fn noteShown(self: *Snapshot, matches: []const rank.Match) void {
        for (matches) |match| _ = self.counters[match.index].shown.fetchAdd(1, .monotonic);
    }

    pub fn noteChosen(self: *Snapshot, index: usize) void {
        _ = self.counters[index].chosen.fetchAdd(1, .monotonic);
    }
};

pub const Source = struct {
    gpa: Allocator,
    name: []const u8,
    current: std.atomic.Value(*Snapshot),
    retired: std.ArrayList(*Snapshot) = .empty,
    needs_refresh: bool = false,

    pub fn snapshot(self: *Source) *Snapshot {
        return self.current.load(.acquire);
    }

    pub fn publish(self: *Source, next: *Snapshot) void {
        const previous = self.current.swap(next, .release);
        self.retired.append(self.gpa, previous) catch previous.destroy(self.gpa);
    }

    pub fn flush(self: *Source, store: *store_mod.Store) void {
        var deltas: std.ArrayList(store_mod.Delta) = .empty;
        defer deltas.deinit(self.gpa);

        self.collect(&deltas, self.snapshot());
        for (self.retired.items) |old| self.collect(&deltas, old);

        store.flush(self.name, deltas.items);
    }

    pub fn deinit(self: *Source) void {
        self.snapshot().destroy(self.gpa);
        for (self.retired.items) |old| old.destroy(self.gpa);
        self.retired.deinit(self.gpa);
    }

    fn collect(self: *Source, deltas: *std.ArrayList(store_mod.Delta), of: *Snapshot) void {
        for (of.counters, of.entries) |*counter, entry| {
            const shown = counter.shown.load(.monotonic);
            const chosen = counter.chosen.load(.monotonic);
            if (shown == 0 and chosen == 0) continue;

            deltas.append(self.gpa, .{
                .adapter = entry.adapter,
                .key = entry.key,
                .shown = shown,
                .chosen = chosen,
            }) catch return;
        }
    }
};

pub fn empty(gpa: Allocator) Allocator.Error!*Snapshot {
    return build(gpa, &.{}, noIcon, undefined);
}

pub const IconOf = *const fn (context: *anyopaque, arena: Allocator, record: store_mod.Record) list.Icon;

pub fn build(
    gpa: Allocator,
    records: []const store_mod.Record,
    iconOf: IconOf,
    context: *anyopaque,
) Allocator.Error!*Snapshot {
    const self = try gpa.create(Snapshot);
    errdefer gpa.destroy(self);

    self.* = .{
        .arena = .init(gpa),
        .entries = &.{},
        .haystacks = &.{},
        .loaded = &.{},
        .counters = &.{},
    };
    errdefer self.arena.deinit();

    const arena = self.arena.allocator();

    const entries = try arena.alloc(Entry, records.len);
    const haystacks = try arena.alloc([]const u8, records.len);
    const loaded = try arena.alloc(rank.Weight, records.len);
    const counters = try arena.alloc(Counter, records.len);

    for (records, 0..) |record, at| {
        entries[at] = .{
            .adapter = try arena.dupe(u8, record.adapter),
            .key = try arena.dupe(u8, record.key),
            .title = try arena.dupeZ(u8, record.title),
            .detail = try arena.dupeZ(u8, record.detail),
            .icon = iconOf(context, arena, record),
            .haystack = try arena.dupe(u8, record.haystack),
            .program = try arena.dupe(u8, record.program),
        };
        haystacks[at] = entries[at].haystack;
        loaded[at] = .{ .shown = record.shown, .chosen = record.chosen };
        counters[at] = .{};
    }

    self.entries = entries;
    self.haystacks = haystacks;
    self.loaded = loaded;
    self.counters = counters;
    return self;
}

fn noIcon(_: *anyopaque, _: Allocator, _: store_mod.Record) list.Icon {
    return .none;
}

pub fn report(name: []const u8, action: []const u8, err: anyerror) void {
    log.warn("cannot {s} the {s} index: {t}", .{ action, name, err });
}

const testing = std.testing;

const sample = [_]store_mod.Record{
    .{ .key = "a", .title = "Alpha", .detail = "First", .icon = "", .haystack = "Alpha", .shown = 4, .chosen = 2 },
    .{ .key = "b", .title = "Beta", .detail = "Second", .icon = "", .haystack = "Beta" },
};

fn testSource() !Source {
    return .{
        .gpa = testing.allocator,
        .name = "apps",
        .current = .init(try build(testing.allocator, &sample, noIcon, undefined)),
    };
}

test "a snapshot carries the loaded counts" {
    var self = try testSource();
    defer self.deinit();

    const of = self.snapshot();
    try testing.expectEqual(@as(usize, 2), of.entries.len);
    try testing.expectEqualStrings("Alpha", of.entries[0].title);
    try testing.expectEqual(@as(u32, 4), of.loaded[0].shown);
    try testing.expectEqual(@as(u32, 2), of.loaded[0].chosen);
    try testing.expectEqual(@as(u32, 0), of.counters[0].shown.load(.monotonic));
}

test "weights add what this run counted to what was loaded" {
    var self = try testSource();
    defer self.deinit();

    const of = self.snapshot();
    of.noteShown(&.{ .{ .index = 0, .score = 0 }, .{ .index = 1, .score = 0 } });
    of.noteChosen(0);

    const found = try of.weights(testing.allocator);
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(u32, 5), found[0].shown);
    try testing.expectEqual(@as(u32, 3), found[0].chosen);
    try testing.expectEqual(@as(u32, 1), found[1].shown);
    try testing.expectEqual(@as(u32, 0), found[1].chosen);
}

test "a published snapshot replaces the current one and the old is kept" {
    var self = try testSource();
    defer self.deinit();

    const first = self.snapshot();
    first.noteChosen(0);

    self.publish(try build(testing.allocator, sample[0..1], noIcon, undefined));

    try testing.expectEqual(@as(usize, 1), self.snapshot().entries.len);
    try testing.expectEqual(@as(usize, 1), self.retired.items.len);
    try testing.expectEqual(first, self.retired.items[0]);
}

test "only entries that moved are flushed, across retired snapshots too" {
    var self = try testSource();
    defer self.deinit();

    self.snapshot().noteChosen(0);
    self.publish(try build(testing.allocator, &sample, noIcon, undefined));
    self.snapshot().noteShown(&.{.{ .index = 1, .score = 0 }});

    var deltas: std.ArrayList(store_mod.Delta) = .empty;
    defer deltas.deinit(testing.allocator);

    self.collect(&deltas, self.snapshot());
    for (self.retired.items) |old| self.collect(&deltas, old);

    try testing.expectEqual(@as(usize, 2), deltas.items.len);
    try testing.expectEqualStrings("b", deltas.items[0].key);
    try testing.expectEqualStrings("", deltas.items[0].adapter);
    try testing.expectEqual(@as(u32, 1), deltas.items[0].shown);
    try testing.expectEqualStrings("a", deltas.items[1].key);
    try testing.expectEqual(@as(u32, 1), deltas.items[1].chosen);
}
