const std = @import("std");
const model = @import("../model.zig");
const rank = @import("core").rank;
const Store = @import("core").store.Store;
const subroutines = @import("../subroutines.zig");

const Allocator = std.mem.Allocator;

const forget_icons = [_][:0]const u8{ "edit-clear-history-symbolic", "edit-clear-all-symbolic" };

pub fn offer(arena: Allocator, member: subroutines.Subroutine, id: u64) Allocator.Error![]const model.Offer {
    var offers: std.ArrayList(model.Offer) = .empty;

    if (member.counters(id)) |weight| {
        if (weight.chosen > 0) try offers.append(arena, .{
            .title = "Forget",
            .detail = try countedOf(arena, weight),
            .icon = .{ .name = subroutines.themedIcon(&forget_icons) },
            .choice = .{ .global = .forget },
        });
    }
    return offers.items;
}

pub fn perform(global: model.Global, member: subroutines.Subroutine, id: u64) subroutines.Outcome {
    switch (global) {
        .forget => {
            member.forget(id);
            return .refresh;
        },
    }
}

fn countedOf(arena: Allocator, weight: rank.Weight) Allocator.Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena, "Picked {d} {s}, listed {d} {s}", .{
        weight.chosen,
        timesOf(weight.chosen),
        weight.shown,
        timesOf(weight.shown),
    }, 0);
}

fn timesOf(count: u32) []const u8 {
    return if (count == 1) "time" else "times";
}

const testing = std.testing;

pub const Fake = struct {
    weight: ?rank.Weight = null,
    forgotten: ?u64 = null,
    own: []const subroutines.Action = &.{},
    performed: ?u64 = null,

    pub fn run(_: *Fake, _: *subroutines.Owner, _: []const u8) subroutines.Error!subroutines.Output {
        return .nothing;
    }

    pub fn choose(_: *Fake, _: Allocator, _: u64) subroutines.Outcome {
        return .close;
    }

    pub fn stale(_: *Fake) bool {
        return false;
    }

    pub fn refresh(_: *Fake) void {}

    pub fn retire(_: *Fake, _: ?*Store) void {}

    pub fn actions(self: *Fake, _: Allocator, _: u64) subroutines.Error![]const subroutines.Action {
        return self.own;
    }

    pub fn perform(self: *Fake, _: Allocator, _: u64, action: u64) subroutines.Outcome {
        self.performed = action;
        return .close;
    }

    pub fn counters(self: *Fake, _: u64) ?rank.Weight {
        if (self.forgotten != null) return .{};
        return self.weight;
    }

    pub fn forget(self: *Fake, id: u64) void {
        self.forgotten = id;
    }

    pub fn subroutine(self: *Fake) subroutines.Subroutine {
        return .{ .name = "fake", .context = self, .vtable = subroutines.vtableOf(Fake) };
    }
};

test "an entry never picked, or a source that counts nothing, offers nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var listed: Fake = .{ .weight = .{ .shown = 40 } };
    try testing.expectEqual(@as(usize, 0), (try offer(arena.allocator(), listed.subroutine(), 7)).len);

    var uncounted: Fake = .{};
    try testing.expectEqual(@as(usize, 0), (try offer(arena.allocator(), uncounted.subroutine(), 7)).len);
}

test "a picked entry offers Forget with its counters in digits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var picked: Fake = .{ .weight = .{ .shown = 41, .chosen = 3 } };
    const found = try offer(arena.allocator(), picked.subroutine(), 7);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("Forget", found[0].title);
    try testing.expectEqualStrings("Picked 3 times, listed 41 times", found[0].detail);
    try testing.expectEqual(model.Choice{ .global = .forget }, found[0].choice);

    var once: Fake = .{ .weight = .{ .chosen = 1 } };
    const single = try offer(arena.allocator(), once.subroutine(), 7);
    try testing.expectEqualStrings("Picked 1 time, listed 0 times", single[0].detail);
}

test "forgetting resets the entry through its source and refreshes the list" {
    var picked: Fake = .{ .weight = .{ .shown = 2, .chosen = 2 } };
    try testing.expectEqual(subroutines.Outcome.refresh, perform(.forget, picked.subroutine(), 7));
    try testing.expectEqual(@as(?u64, 7), picked.forgotten);
}
