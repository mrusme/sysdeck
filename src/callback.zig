const std = @import("std");

pub fn Callback(comptime Signature: type) type {
    const Args = std.meta.ArgsTuple(Signature);
    const Return = @typeInfo(Signature).@"fn".return_type.?;

    return struct {
        const Self = @This();

        context: *anyopaque,
        run: *const fn (context: *anyopaque, args: Args) Return,

        pub fn of(comptime Owner: type, comptime method: anytype, context: *Owner) Self {
            const shim = struct {
                fn call(erased: *anyopaque, args: Args) Return {
                    const owner: *Owner = @ptrCast(@alignCast(erased));
                    return @call(.auto, method, .{owner} ++ args);
                }
            };
            return .{ .context = context, .run = &shim.call };
        }

        pub fn call(self: Self, args: Args) Return {
            return self.run(self.context, args);
        }
    };
}

const testing = std.testing;

const Counter = struct {
    seen: usize = 0,
    total: i32 = 0,

    fn note(self: *Counter) void {
        self.seen += 1;
    }

    fn add(self: *Counter, left: i32, right: i32) void {
        self.total += left + right;
    }

    fn over(self: *Counter, limit: i32) bool {
        return self.total > limit;
    }
};

test "a callback reaches the method of the owner it was bound to" {
    var counter: Counter = .{};

    const noted: Callback(fn () void) = .of(Counter, Counter.note, &counter);
    noted.call(.{});
    noted.call(.{});

    try testing.expectEqual(2, counter.seen);
}

test "the arguments are passed through in order" {
    var counter: Counter = .{};

    const added: Callback(fn (i32, i32) void) = .of(Counter, Counter.add, &counter);
    added.call(.{ 3, 4 });

    try testing.expectEqual(7, counter.total);
}

test "a callback returns what its method returns" {
    var counter: Counter = .{ .total = 10 };

    const over: Callback(fn (i32) bool) = .of(Counter, Counter.over, &counter);
    try testing.expect(over.call(.{5}));
    try testing.expect(!over.call(.{20}));
}

test "two owners of the same type keep their own state" {
    var one: Counter = .{};
    var other: Counter = .{};

    const first: Callback(fn () void) = .of(Counter, Counter.note, &one);
    const second: Callback(fn () void) = .of(Counter, Counter.note, &other);

    first.call(.{});
    second.call(.{});
    second.call(.{});

    try testing.expectEqual(1, one.seen);
    try testing.expectEqual(2, other.seen);
}
