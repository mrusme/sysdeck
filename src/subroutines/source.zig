const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const model = @import("../model.zig");
const rank = @import("core").rank;
const store_mod = @import("core").store;
const counts = @import("core").counts;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.source);

pub const Published = Callback(fn () void);

pub const Entry = struct {
    adapter: []const u8,
    key: []const u8,
    title: [:0]const u8,
    detail: [:0]const u8,
    icon: model.Icon,
    haystack: []const u8,
    program: []const u8,
    mime: []const u8 = "",
    size: u64 = 0,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    ids: []const u64,
    places: std.AutoHashMapUnmanaged(u64, usize),
    haystacks: []const []const u8,

    pub fn find(self: *Snapshot, id: u64) ?usize {
        return self.places.get(id);
    }

    pub fn destroy(self: *Snapshot, gpa: Allocator) void {
        for (self.entries) |entry| {
            switch (entry.icon) {
                .gicon => |icon| glib.g_object_unref(icon),
                else => {},
            }
        }
        self.arena.deinit();
        gpa.destroy(self);
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

    pub fn deinit(self: *Source) void {
        self.snapshot().destroy(self.gpa);
        for (self.retired.items) |old| old.destroy(self.gpa);
        self.retired.deinit(self.gpa);
    }
};

pub fn empty(gpa: Allocator) Allocator.Error!*Snapshot {
    return build(gpa, &.{}, noIcon, null);
}

pub const IconOf = *const fn (context: ?*anyopaque, arena: Allocator, record: store_mod.Record) model.Icon;

pub fn build(
    gpa: Allocator,
    records: []const store_mod.Record,
    iconOf: IconOf,
    context: ?*anyopaque,
) Allocator.Error!*Snapshot {
    const self = try gpa.create(Snapshot);
    errdefer gpa.destroy(self);

    self.* = .{
        .arena = .init(gpa),
        .entries = &.{},
        .ids = &.{},
        .places = .empty,
        .haystacks = &.{},
    };
    errdefer self.arena.deinit();

    const arena = self.arena.allocator();

    const entries = try arena.alloc(Entry, records.len);
    const ids = try arena.alloc(u64, records.len);
    const haystacks = try arena.alloc([]const u8, records.len);
    for (records, 0..) |record, at| {
        entries[at] = .{
            .adapter = try arena.dupe(u8, record.adapter),
            .key = try arena.dupe(u8, record.key),
            .title = try arena.dupeZ(u8, record.title),
            .detail = try arena.dupeZ(u8, record.detail),
            .icon = iconOf(context, arena, record),
            .haystack = try arena.dupe(u8, record.haystack),
            .program = try arena.dupe(u8, record.program),
            .mime = try arena.dupe(u8, record.mime),
            .size = record.size,
        };
        haystacks[at] = entries[at].haystack;
        ids[at] = counts.idOf(record.adapter, record.key);

        const slot = try self.places.getOrPut(arena, ids[at]);
        if (!slot.found_existing) slot.value_ptr.* = at;
    }

    self.entries = entries;
    self.ids = ids;
    self.haystacks = haystacks;
    return self;
}

fn noIcon(_: ?*anyopaque, _: Allocator, _: store_mod.Record) model.Icon {
    return .none;
}

pub fn report(name: []const u8, action: []const u8, err: anyerror) void {
    log.warn("cannot {s} the {s} index: {t}", .{ action, name, err });
}

const testing = std.testing;

const sample = [_]store_mod.Record{
    .{ .key = "a", .title = "Alpha", .detail = "First", .icon = "", .haystack = "Alpha" },
    .{ .key = "b", .title = "Beta", .detail = "Second", .icon = "", .haystack = "Beta" },
};

fn testSource() !Source {
    return .{
        .gpa = testing.allocator,
        .name = "apps",
        .current = .init(try build(testing.allocator, &sample, noIcon, null)),
    };
}

test "a published snapshot replaces the current one and the old is kept" {
    var self = try testSource();
    defer self.deinit();

    const first = self.snapshot();

    self.publish(try build(testing.allocator, sample[0..1], noIcon, null));

    try testing.expectEqual(@as(usize, 1), self.snapshot().entries.len);
    try testing.expectEqual(@as(usize, 1), self.retired.items.len);
    try testing.expectEqual(first, self.retired.items[0]);
}

fn published(gpa: Allocator) !void {
    const of = try build(gpa, &sample, noIcon, null);
    of.destroy(gpa);
}

test "a snapshot that runs out of memory leaves nothing behind" {
    try testing.checkAllAllocationFailures(testing.allocator, published, .{});
}
test "a snapshot gives every entry a stable id" {
    var self = try testSource();
    defer self.deinit();

    const of = self.snapshot();
    try testing.expectEqual(@as(usize, 2), of.entries.len);
    try testing.expectEqual(counts.idOf("", "a"), of.ids[0]);
    try testing.expectEqual(@as(?usize, 0), of.find(counts.idOf("", "a")));
    try testing.expectEqual(@as(?usize, 1), of.find(counts.idOf("", "b")));
    try testing.expectEqual(@as(?usize, null), of.find(counts.id("gone")));
}
