const std = @import("std");

pub fn contains(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

const testing = std.testing;

test "a name is found only when the list holds it exactly" {
    try testing.expect(contains(&.{ "apps", "bins" }, "bins"));
    try testing.expect(!contains(&.{ "apps", "bins" }, "bin"));
    try testing.expect(!contains(&.{ "apps", "bins" }, "Bins"));
    try testing.expect(!contains(&.{}, "apps"));
}
