const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const list = @import("list.zig");
const Store = @import("store.zig").Store;

const Allocator = std.mem.Allocator;

pub const apps = @import("subroutines/apps.zig");
pub const bins = @import("subroutines/bins.zig");
pub const bookmarks = @import("subroutines/bookmarks.zig");
pub const processes = @import("subroutines/processes.zig");
pub const sway = @import("subroutines/sway.zig");
pub const whats = @import("subroutines/whats.zig");

pub const Error = error{ OutOfMemory, Failed };

pub const Hit = struct {
    row: list.Row,
    score: fuzzy.Score,
};

pub const Mark = struct {
    pid: i32,
    name: []const u8,
    program: []const u8,
};

pub const Action = struct {
    id: u64,
    title: [:0]const u8,
    detail: [:0]const u8 = "",
};

pub const Output = union(enum) {
    nothing,
    hits: []const Hit,
    marks: []const Mark,
    answer: [:0]const u8,
};

pub const Outcome = union(enum) {
    close,
    keep,
    query: [:0]u8,
};

pub const Stage = enum { immediate, fallback };

pub const Subroutine = struct {
    name: []const u8,
    context: *anyopaque,
    vtable: *const VTable,
    stage: Stage = .immediate,

    pub const VTable = struct {
        run: *const fn (context: *anyopaque, gpa: Allocator, text: []const u8) Error!Output,
        choose: *const fn (context: *anyopaque, gpa: Allocator, id: u64) Outcome,
        release: *const fn (context: *anyopaque, gpa: Allocator, output: Output) void,
        stale: *const fn (context: *anyopaque) bool,
        refresh: *const fn (context: *anyopaque) void,
        retire: *const fn (context: *anyopaque, store: ?*Store) void,
        actions: ?*const fn (context: *anyopaque, arena: Allocator, id: u64) Error![]const Action = null,
        perform: ?*const fn (context: *anyopaque, gpa: Allocator, id: u64, action: u64) Outcome = null,
    };

    pub fn run(self: Subroutine, gpa: Allocator, text: []const u8) Error!Output {
        return self.vtable.run(self.context, gpa, text);
    }

    pub fn choose(self: Subroutine, gpa: Allocator, id: u64) Outcome {
        return self.vtable.choose(self.context, gpa, id);
    }

    pub fn release(self: Subroutine, gpa: Allocator, output: Output) void {
        self.vtable.release(self.context, gpa, output);
    }

    pub fn stale(self: Subroutine) bool {
        return self.vtable.stale(self.context);
    }

    pub fn refresh(self: Subroutine) void {
        self.vtable.refresh(self.context);
    }

    pub fn retire(self: Subroutine, store: ?*Store) void {
        self.vtable.retire(self.context, store);
    }

    pub fn actions(self: Subroutine, arena: Allocator, id: u64) Error![]const Action {
        const call = self.vtable.actions orelse return &.{};
        return call(self.context, arena, id);
    }

    pub fn perform(self: Subroutine, gpa: Allocator, id: u64, action: u64) Outcome {
        const call = self.vtable.perform orelse return .keep;
        return call(self.context, gpa, id, action);
    }
};

test {
    _ = apps;
    _ = bins;
    _ = bookmarks;
    _ = processes;
    _ = sway;
    _ = whats;
}
