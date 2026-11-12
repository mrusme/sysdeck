const std = @import("std");

pub fn now(io: std.Io) i64 {
    return of(std.Io.Clock.real.now(io));
}

pub fn of(at: std.Io.Timestamp) i64 {
    return at.toMilliseconds();
}

const testing = std.testing;

test "a timestamp becomes milliseconds" {
    try testing.expectEqual(0, of(.zero));
    try testing.expectEqual(1, of(.fromNanoseconds(std.time.ns_per_ms)));
    try testing.expectEqual(1_500, of(.fromNanoseconds(3 * std.time.ns_per_s / 2)));
}
