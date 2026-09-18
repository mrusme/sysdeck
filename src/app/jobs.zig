const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.jobs);

pub fn Runner(comptime Job: type) type {
    return struct {
        const Self = @This();

        const Delivery = struct {
            runner: *Self,
            owner: *anyopaque,
            at: usize,
            member: Job.Member,
            generation: u64,
            result: Job.Result,
        };

        gpa: Allocator,
        io: std.Io,
        group: std.Io.Group = .init,
        generation: std.atomic.Value(u64) = .init(0),
        owner: ?*anyopaque = null,
        pending: c.guint = 0,
        stopping: bool = false,

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
            self.group.concurrent(self.io, task, .{
                self,
                owner,
                at,
                member,
                generation,
                work,
            }) catch |err| {
                log.warn("cannot start job {d}: {t}", .{ at, err });
                return false;
            };
            return true;
        }

        pub fn stop(self: *Self) void {
            self.stopping = true;
            self.cancel();
            self.group.cancel(self.io);
            drain();
        }

        fn task(
            self: *Self,
            owner: *anyopaque,
            at: usize,
            member: Job.Member,
            generation: u64,
            work: Job.Work,
        ) void {
            defer Job.discard(member, self.gpa, work);

            std.Io.checkCancel(self.io) catch return;

            const result = Job.produce(member, self.gpa, work) orelse return;

            const delivery = self.gpa.create(Delivery) catch {
                Job.release(member, self.gpa, result);
                return;
            };
            delivery.* = .{
                .runner = self,
                .owner = owner,
                .at = at,
                .member = member,
                .generation = generation,
                .result = result,
            };

            _ = glib.g_idle_add(&onDelivery, delivery);
        }

        fn onTimeout(data: c.gpointer) callconv(.c) c.gboolean {
            const self: *Self = @ptrCast(@alignCast(data.?));
            self.pending = 0;

            const owner = self.owner orelse return c.source_remove;
            if (!self.stopping) Job.begin(owner);
            return c.source_remove;
        }

        fn onDelivery(data: c.gpointer) callconv(.c) c.gboolean {
            const delivery: *Delivery = @ptrCast(@alignCast(data.?));
            const self = delivery.runner;
            defer self.gpa.destroy(delivery);

            if (self.stopping or delivery.generation != self.current()) {
                Job.release(delivery.member, self.gpa, delivery.result);
                return c.source_remove;
            }

            Job.accept(delivery.owner, delivery.at, delivery.member, delivery.result);
            return c.source_remove;
        }
    };
}

fn drain() void {
    const context = glib.g_main_context_default();
    while (glib.g_main_context_iteration(context, c.FALSE) != c.FALSE) {}
}

const testing = std.testing;

const Tally = struct {
    produced: usize = 0,
    accepted: usize = 0,
    released: usize = 0,
};

const Counted = struct {
    pub const Member = *Tally;
    pub const Work = void;
    pub const Result = usize;

    pub fn begin(_: *anyopaque) void {}

    pub fn produce(member: Member, _: Allocator, _: Work) ?Result {
        member.produced += 1;
        return member.produced;
    }

    pub fn discard(_: Member, _: Allocator, _: Work) void {}

    pub fn release(member: Member, _: Allocator, _: Result) void {
        member.released += 1;
    }

    pub fn accept(_: *anyopaque, _: usize, member: Member, _: Result) void {
        member.accepted += 1;
    }
};

fn awaited(runner: *Runner(Counted), tally: *Tally) !void {
    const generation = runner.bump();
    try testing.expect(runner.spawn(tally, 0, tally, generation, {}));
    runner.group.await(runner.io) catch |err| switch (err) {
        error.Canceled => {},
    };
}

test "a result from the generation that is current is delivered" {
    var tally: Tally = .{};
    var runner: Runner(Counted) = .{ .gpa = testing.allocator, .io = testing.io };

    try awaited(&runner, &tally);
    drain();

    try testing.expectEqual(@as(usize, 1), tally.produced);
    try testing.expectEqual(@as(usize, 1), tally.accepted);
    try testing.expectEqual(@as(usize, 0), tally.released);
}

test "a result that arrives after its generation ended is released by its own member" {
    var tally: Tally = .{};
    var runner: Runner(Counted) = .{ .gpa = testing.allocator, .io = testing.io };

    try awaited(&runner, &tally);
    _ = runner.bump();
    drain();

    try testing.expectEqual(@as(usize, 1), tally.produced);
    try testing.expectEqual(@as(usize, 0), tally.accepted);
    try testing.expectEqual(@as(usize, 1), tally.released);
}
