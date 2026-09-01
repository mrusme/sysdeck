const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Link = struct {
    url: []const u8,
    name: []const u8,
    folder: []const u8 = "",
    tags: []const u8 = "",
};

pub const Adapter = struct {
    name: []const u8,
    max_age_minutes: i64,
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        collect: *const fn (context: *anyopaque, arena: Allocator) Allocator.Error![]const Link,
    };

    pub fn collect(self: Adapter, arena: Allocator) Allocator.Error![]const Link {
        return self.vtable.collect(self.context, arena);
    }
};

pub fn vtableOf(comptime Methods: type) *const Adapter.VTable {
    const shim = struct {
        fn collect(context: *anyopaque, arena: Allocator) Allocator.Error![]const Link {
            const self: *Methods = @ptrCast(@alignCast(context));
            return Methods.collect(self, arena);
        }

        const table: Adapter.VTable = .{ .collect = &collect };
    };

    return &shim.table;
}

pub fn expand(arena: Allocator, home: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, path, "~")) return path;
    if (path.len == 1) return home;
    if (path[1] != '/') return path;

    return std.fs.path.join(arena, &.{ home, path[2..] });
}

const testing = std.testing;

test "a home relative path is expanded and the rest is left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const home = "/home/tester";

    try testing.expectEqualStrings("/home/tester/notes.md", try expand(gpa, home, "~/notes.md"));
    try testing.expectEqualStrings("/home/tester", try expand(gpa, home, "~"));
    try testing.expectEqualStrings("/srv/notes.md", try expand(gpa, home, "/srv/notes.md"));
    try testing.expectEqualStrings("~other/notes.md", try expand(gpa, home, "~other/notes.md"));
    try testing.expectEqualStrings("~/notes.md", try expand(gpa, "", "~/notes.md"));
}
