const std = @import("std");
const fuzzy = @import("core").fuzzy;
const list = @import("ui/list.zig");
const Store = @import("core").store.Store;

const Allocator = std.mem.Allocator;

pub const apps = @import("subroutines/apps.zig");
pub const bins = @import("subroutines/bins.zig");
pub const bookmarks = @import("subroutines/bookmarks.zig");
pub const clipboard = @import("subroutines/clipboard.zig");
pub const disk = @import("subroutines/disk.zig");
pub const llm = @import("subroutines/llm.zig");
pub const nm = @import("subroutines/nm.zig");
pub const processes = @import("subroutines/processes.zig");
pub const screenshot = @import("subroutines/screenshot.zig");
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
    busy,
    query: [:0]u8,
};

pub const Settled = struct {
    call: *const fn (context: *anyopaque) void = &ignore,
    context: *anyopaque = undefined,

    fn ignore(_: *anyopaque) void {}
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
        picks: ?*const fn (context: *anyopaque, gpa: Allocator, limit: usize) Error!Output = null,
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

    pub fn recommends(self: Subroutine) bool {
        return self.vtable.picks != null;
    }

    pub fn picks(self: Subroutine, gpa: Allocator, limit: usize) Error!Output {
        const call = self.vtable.picks orelse return .nothing;
        return call(self.context, gpa, limit);
    }
};

pub fn vtableOf(comptime Methods: type) *const Subroutine.VTable {
    const Self = if (@hasDecl(Methods, "Context")) Methods.Context else Methods;

    const shim = struct {
        fn of(context: *anyopaque) *Self {
            return @ptrCast(@alignCast(context));
        }

        fn run(context: *anyopaque, gpa: Allocator, text: []const u8) Error!Output {
            return Methods.run(of(context), gpa, text);
        }

        fn choose(context: *anyopaque, gpa: Allocator, id: u64) Outcome {
            return Methods.choose(of(context), gpa, id);
        }

        fn release(context: *anyopaque, gpa: Allocator, output: Output) void {
            Methods.release(of(context), gpa, output);
        }

        fn stale(context: *anyopaque) bool {
            return Methods.stale(of(context));
        }

        fn refresh(context: *anyopaque) void {
            Methods.refresh(of(context));
        }

        fn retire(context: *anyopaque, store: ?*Store) void {
            Methods.retire(of(context), store);
        }

        fn actions(context: *anyopaque, arena: Allocator, id: u64) Error![]const Action {
            return Methods.actions(of(context), arena, id);
        }

        fn perform(context: *anyopaque, gpa: Allocator, id: u64, action: u64) Outcome {
            return Methods.perform(of(context), gpa, id, action);
        }

        fn picks(context: *anyopaque, gpa: Allocator, limit: usize) Error!Output {
            return Methods.picks(of(context), gpa, limit);
        }

        const table: Subroutine.VTable = .{
            .run = &run,
            .choose = &choose,
            .release = &release,
            .stale = &stale,
            .refresh = &refresh,
            .retire = &retire,
            .actions = if (@hasDecl(Methods, "actions")) &actions else null,
            .perform = if (@hasDecl(Methods, "perform")) &perform else null,
            .picks = if (@hasDecl(Methods, "picks")) &picks else null,
        };
    };

    return &shim.table;
}

test {
    _ = apps;
    _ = bins;
    _ = bookmarks;
    _ = clipboard;
    _ = disk;
    _ = llm;
    _ = nm;
    _ = processes;
    _ = screenshot;
    _ = sway;
    _ = whats;
}
