const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.jobs);

pub fn Runner(comptime Job: type) type {
    return struct {
        const Self = @This();

        const Delivery = struct {
            node: std.DoublyLinkedList.Node = .{},
            at: usize,
            member: Job.Member,
            generation: u64,
            result: Job.Result = undefined,
        };

        gpa: Allocator,
        io: std.Io,
        group: std.Io.Group = .init,
        generation: std.atomic.Value(u64) = .init(0),
        owner: ?*anyopaque = null,
        pending: c.guint = 0,
        stopping: bool = false,
        guard: std.Io.Mutex = .init,
        delivered: std.DoublyLinkedList = .{},
        posted: c.guint = 0,

        pub fn bump(self: *Self) u64 {
            return self.generation.fetchAdd(1, .monotonic) + 1;
        }

        pub fn current(self: *Self) u64 {
            return self.generation.load(.monotonic);
        }

        pub fn after(self: *Self, owner: *anyopaque, milliseconds: c.guint) void {
            self.cancel();
            self.owner = owner;
            self.pending = glib.g_timeout_add(milliseconds, &onTimeout, self);
        }

        pub fn cancel(self: *Self) void {
            if (self.pending == 0) return;
            _ = glib.g_source_remove(self.pending);
            self.pending = 0;
        }

        pub fn spawn(
            self: *Self,
            owner: *anyopaque,
            at: usize,
            member: Job.Member,
            generation: u64,
            work: Job.Work,
        ) bool {
            const delivery = self.gpa.create(Delivery) catch {
                log.warn("cannot start job {d}: out of memory", .{at});
                return false;
            };
            delivery.* = .{ .at = at, .member = member, .generation = generation };
            self.owner = owner;

            self.group.concurrent(self.io, task, .{ self, delivery, work }) catch |err| {
                self.gpa.destroy(delivery);
                log.warn("cannot start job {d}: {t}", .{ at, err });
                return false;
            };
            return true;
        }

        pub fn stop(self: *Self) void {
            self.stopping = true;
            self.cancel();
            self.group.cancel(self.io);

            if (self.posted != 0) _ = glib.g_source_remove(self.posted);
            var taken = self.take();
            while (taken.popFirst()) |node| {
                const delivery = deliveryOf(node);
                Job.release(delivery.member, self.gpa, delivery.result);
                self.gpa.destroy(delivery);
            }
        }

        fn task(self: *Self, delivery: *Delivery, work: Job.Work) void {
            const member = delivery.member;
            defer Job.discard(member, self.gpa, work);

            std.Io.checkCancel(self.io) catch return self.gpa.destroy(delivery);

            delivery.result = Job.produce(member, self.gpa, work);
            self.post(delivery);
        }

        fn post(self: *Self, delivery: *Delivery) void {
            self.guard.lockUncancelable(self.io);
            defer self.guard.unlock(self.io);

            self.delivered.append(&delivery.node);
            if (self.posted == 0) self.posted = glib.g_idle_add(&onDelivered, self);
        }

        fn take(self: *Self) std.DoublyLinkedList {
            self.guard.lockUncancelable(self.io);
            defer self.guard.unlock(self.io);

            const taken = self.delivered;
            self.delivered = .{};
            self.posted = 0;
            return taken;
        }

        fn deliveryOf(node: *std.DoublyLinkedList.Node) *Delivery {
            return @fieldParentPtr("node", node);
        }

        fn onTimeout(data: c.gpointer) callconv(.c) c.gboolean {
            const self: *Self = @ptrCast(@alignCast(data.?));
            self.pending = 0;

            const owner = self.owner orelse return c.source_remove;
            if (!self.stopping) Job.begin(owner);
            return c.source_remove;
        }

        fn onDelivered(data: c.gpointer) callconv(.c) c.gboolean {
            const self: *Self = @ptrCast(@alignCast(data.?));
            var taken = self.take();
            var accepted = false;

            while (taken.popFirst()) |node| {
                const delivery = deliveryOf(node);
                defer self.gpa.destroy(delivery);

                if (delivery.generation != self.current()) {
                    Job.release(delivery.member, self.gpa, delivery.result);
                    continue;
                }

                Job.accept(self.owner.?, delivery.at, delivery.member, delivery.result);
                accepted = true;
            }

            if (accepted) Job.settle(self.owner.?);
            return c.source_remove;
        }
    };
}

const testing = std.testing;

pub fn dispatchPending() void {
    const context = glib.g_main_context_default();
    while (glib.g_main_context_iteration(context, c.FALSE) != c.FALSE) {}
}

const Tally = struct {
    produced: std.atomic.Value(usize) = .init(0),
    accepted: usize = 0,
    released: usize = 0,
    settled: usize = 0,
};

const Counted = struct {
    pub const Member = *Tally;
    pub const Work = void;
    pub const Result = usize;

    fn begin(_: *anyopaque) void {}

    fn produce(member: Member, _: Allocator, _: Work) Result {
        return member.produced.fetchAdd(1, .monotonic) + 1;
    }

    fn discard(_: Member, _: Allocator, _: Work) void {}

    pub fn release(member: Member, _: Allocator, _: Result) void {
        member.released += 1;
    }

    fn accept(_: *anyopaque, _: usize, member: Member, _: Result) void {
        member.accepted += 1;
    }

    fn settle(owner: *anyopaque) void {
        const tally: *Tally = @ptrCast(@alignCast(owner));
        tally.settled += 1;
    }
};

fn finish(runner: *Runner(Counted)) void {
    runner.group.await(runner.io) catch |err| switch (err) {
        error.Canceled => {},
    };
}

fn started(runner: *Runner(Counted), tally: *Tally, count: usize) !void {
    const generation = runner.bump();
    for (0..count) |at| try testing.expect(runner.spawn(tally, at, tally, generation, {}));
    finish(runner);
}

test "a result from the generation that is current is delivered" {
    var tally: Tally = .{};
    var runner: Runner(Counted) = .{ .gpa = testing.allocator, .io = testing.io };
    defer runner.stop();

    try started(&runner, &tally, 1);
    dispatchPending();

    try testing.expectEqual(1, tally.produced.load(.monotonic));
    try testing.expectEqual(1, tally.accepted);
    try testing.expectEqual(0, tally.released);
    try testing.expectEqual(1, tally.settled);
}

test "a result that arrives after its generation ended is released by its own member" {
    var tally: Tally = .{};
    var runner: Runner(Counted) = .{ .gpa = testing.allocator, .io = testing.io };
    defer runner.stop();

    try started(&runner, &tally, 1);
    _ = runner.bump();
    dispatchPending();

    try testing.expectEqual(1, tally.produced.load(.monotonic));
    try testing.expectEqual(0, tally.accepted);
    try testing.expectEqual(1, tally.released);
    try testing.expectEqual(0, tally.settled);
}

test "several results queued before the main context runs are settled once" {
    var tally: Tally = .{};
    var runner: Runner(Counted) = .{ .gpa = testing.allocator, .io = testing.io };
    defer runner.stop();

    try started(&runner, &tally, 3);
    dispatchPending();

    try testing.expectEqual(3, tally.produced.load(.monotonic));
    try testing.expectEqual(3, tally.accepted);
    try testing.expectEqual(1, tally.settled);
}

test "stop releases a queued result without running the main context" {
    dispatchPending();

    var tally: Tally = .{};
    var runner: Runner(Counted) = .{ .gpa = testing.allocator, .io = testing.io };

    try started(&runner, &tally, 3);
    runner.stop();

    try testing.expectEqual(3, tally.released);

    const context = glib.g_main_context_default();
    try testing.expect(glib.g_main_context_iteration(context, c.FALSE) == c.FALSE);
    try testing.expectEqual(0, tally.accepted);
    try testing.expectEqual(0, tally.settled);
}
