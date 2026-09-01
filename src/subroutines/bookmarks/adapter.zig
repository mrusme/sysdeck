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

const testing = std.testing;
