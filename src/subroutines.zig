const std = @import("std");
const c = @import("gtk/c.zig");
const fuzzy = @import("core").fuzzy;
const gio = @import("gtk/gio.zig");
const glib = @import("gtk/glib.zig");
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
pub const snippets = @import("subroutines/snippets.zig");
pub const ssh = @import("subroutines/ssh.zig");
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
    icon: list.Icon = .none,
};

pub const Output = union(enum) {
    nothing,
    hits: []const Hit,
    marks: []const Mark,
    answer: [:0]const u8,
};

pub const Owner = struct {
    arena: std.heap.ArenaAllocator,
    icons: std.ArrayList(*c.GIcon) = .empty,

    pub fn create(gpa: Allocator) Allocator.Error!*Owner {
        const self = try gpa.create(Owner);
        self.* = .{ .arena = .init(gpa) };
        return self;
    }

    pub fn destroy(self: *Owner, gpa: Allocator) void {
        for (self.icons.items) |icon| glib.g_object_unref(icon);
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn allocator(self: *Owner) Allocator {
        return self.arena.allocator();
    }

    pub fn keep(self: *Owner, icon: *c.GIcon) list.Icon {
        self.icons.append(self.allocator(), icon) catch {
            glib.g_object_unref(icon);
            return .none;
        };
        return .{ .gicon = icon };
    }
};

pub const Produced = struct {
    owner: ?*Owner = null,
    output: Output = .nothing,

    pub fn release(self: Produced, gpa: Allocator) void {
        const found = self.owner orelse return;
        found.destroy(gpa);
    }
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
        run: *const fn (context: *anyopaque, owner: *Owner, text: []const u8) Error!Output,
        choose: *const fn (context: *anyopaque, gpa: Allocator, id: u64) Outcome,
        stale: *const fn (context: *anyopaque) bool,
        refresh: *const fn (context: *anyopaque) void,
        retire: *const fn (context: *anyopaque, store: ?*Store) void,
        actions: ?*const fn (context: *anyopaque, arena: Allocator, id: u64) Error![]const Action = null,
        perform: ?*const fn (context: *anyopaque, gpa: Allocator, id: u64, action: u64) Outcome = null,
        picks: ?*const fn (context: *anyopaque, owner: *Owner, limit: usize) Error!Output = null,
    };

    pub fn run(self: Subroutine, owner: *Owner, text: []const u8) Error!Output {
        return self.vtable.run(self.context, owner, text);
    }

    pub fn choose(self: Subroutine, gpa: Allocator, id: u64) Outcome {
        return self.vtable.choose(self.context, gpa, id);
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

    pub fn picks(self: Subroutine, owner: *Owner, limit: usize) Error!Output {
        const call = self.vtable.picks orelse return .nothing;
        return call(self.context, owner, limit);
    }
};

pub fn vtableOf(comptime Methods: type) *const Subroutine.VTable {
    const Self = if (@hasDecl(Methods, "Context")) Methods.Context else Methods;

    const shim = struct {
        fn of(context: *anyopaque) *Self {
            return @ptrCast(@alignCast(context));
        }

        fn run(context: *anyopaque, owner: *Owner, text: []const u8) Error!Output {
            return Methods.run(of(context), owner, text);
        }

        fn choose(context: *anyopaque, gpa: Allocator, id: u64) Outcome {
            return Methods.choose(of(context), gpa, id);
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

        fn picks(context: *anyopaque, owner: *Owner, limit: usize) Error!Output {
            return Methods.picks(of(context), owner, limit);
        }

        const table: Subroutine.VTable = .{
            .run = &run,
            .choose = &choose,
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
    _ = snippets;
    _ = ssh;
    _ = sway;
    _ = whats;
}

const testing = std.testing;

test "an owner frees its memory and unrefs the icons it kept" {
    const owner = try Owner.create(testing.allocator);

    const icon = gio.g_icon_new_for_string("image-png", null).?;
    var alive: ?*anyopaque = icon;
    glib.g_object_add_weak_pointer(icon, &alive);

    const kept = owner.keep(icon);
    try testing.expectEqual(icon, kept.gicon);

    const text = try owner.allocator().dupe(u8, "rows live here");
    try testing.expectEqualStrings("rows live here", text);

    owner.destroy(testing.allocator);
    try testing.expectEqual(@as(?*anyopaque, null), alive);
}

test "a produced result without an owner is released without a free" {
    const empty: Produced = .{};
    empty.release(testing.allocator);

    try testing.expectEqual(Output.nothing, empty.output);
}
