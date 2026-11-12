const std = @import("std");
const Callback = @import("callback.zig").Callback;
const c = @import("gtk/c.zig");
const config = @import("config.zig");
const Counts = @import("core").counts.Counts;
const fuzzy = @import("core").fuzzy;
const gdk = @import("gtk/gdk.zig");
const gio = @import("gtk/gio.zig");
const glib = @import("gtk/glib.zig");
const gtk = @import("gtk/gtk.zig");
const model = @import("model.zig");
const rank = @import("core").rank;
const Store = @import("core").store.Store;
const terminal_mod = @import("system/terminal.zig");

const Allocator = std.mem.Allocator;

pub const apps = @import("subroutines/apps.zig");
pub const source = @import("subroutines/source.zig");
pub const bins = @import("subroutines/bins.zig");
pub const bookmarks = @import("subroutines/bookmarks.zig");
pub const clipboard = @import("subroutines/clipboard.zig");
pub const disk = @import("subroutines/disk.zig");
pub const inca = @import("subroutines/inca.zig");
pub const llm = @import("subroutines/llm.zig");
pub const mpris = @import("subroutines/mpris.zig");
pub const nm = @import("subroutines/nm.zig");
pub const podman = @import("subroutines/podman.zig");
pub const processes = @import("subroutines/processes.zig");
pub const screenshot = @import("subroutines/screenshot.zig");
pub const snippets = @import("subroutines/snippets.zig");
pub const ssh = @import("subroutines/ssh.zig");
pub const sway = @import("subroutines/sway.zig");
pub const websearch = @import("subroutines/websearch.zig");
pub const whats = @import("subroutines/whats.zig");

pub const Error = error{OutOfMemory};

pub const default_shell = "/bin/sh";

pub const Hit = struct {
    row: model.Row,
    score: fuzzy.Score,
};

pub const Mark = struct {
    pid: i32,
    parent: i32 = 0,
    name: []const u8,
    program: []const u8,
};

pub const Action = struct {
    id: u64,
    title: [:0]const u8,
    detail: [:0]const u8 = "",
    icon: model.Icon = .none,
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

    pub fn init(gpa: Allocator) Owner {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Owner) void {
        for (self.icons.items) |icon| glib.g_object_unref(icon);
        self.arena.deinit();
    }

    pub fn create(gpa: Allocator) Allocator.Error!*Owner {
        const self = try gpa.create(Owner);
        self.* = .init(gpa);
        return self;
    }

    pub fn destroy(self: *Owner, gpa: Allocator) void {
        self.deinit();
        gpa.destroy(self);
    }

    pub fn allocator(self: *Owner) Allocator {
        return self.arena.allocator();
    }

    pub fn keep(self: *Owner, icon: *c.GIcon) model.Icon {
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

pub const Context = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    settings: *const config.Config,
    resolved: config.Settings = .{},
    settings_at: ?i64 = null,
    stamp: i64 = 0,
    store: ?*Store = null,
    terminal: ?terminal_mod.Terminal = null,
    published: ?source.Published = null,
    settled: ?Settled = null,
    requested: ?screenshot.Requested = null,
    streamed: ?llm.Notify = null,

    pub fn wanted(self: Context, comptime name: []const u8) bool {
        return config.Config.Sources.on(@field(self.settings.sources, name).enable);
    }

    pub fn asked(self: Context, comptime name: []const u8) bool {
        return @field(self.settings.sources, name).enable == true;
    }

    pub fn age(self: Context, override: ?i64) i64 {
        return self.settings.index.age(override);
    }
};

pub const Outcome = union(enum) {
    close,
    keep,
    busy,
    refresh,
    query: [:0]u8,
};

pub const Next = enum(u8) { close, refresh };

pub const Settled = Callback(fn (next: Next) void);

pub const Stage = enum { immediate, fallback };

pub const Subroutine = struct {
    name: []const u8,
    context: *anyopaque,
    vtable: *const VTable,
    stage: Stage = .immediate,
    verb: [:0]const u8 = "",

    pub const VTable = struct {
        run: *const fn (context: *anyopaque, owner: *Owner, text: []const u8) Error!Output,
        choose: *const fn (context: *anyopaque, gpa: Allocator, id: u64) Outcome,
        actions: ?*const fn (context: *anyopaque, arena: Allocator, id: u64) Error![]const Action = null,
        perform: ?*const fn (context: *anyopaque, gpa: Allocator, id: u64, action: u64) Outcome = null,
        picks: ?*const fn (context: *anyopaque, owner: *Owner, limit: usize) Error!Output = null,
        chooseWith: ?*const fn (context: *anyopaque, gpa: Allocator, id: u64, arguments: []const u8) Outcome = null,
        counters: ?*const fn (context: *anyopaque, id: u64) ?rank.Weight = null,
        forget: ?*const fn (context: *anyopaque, id: u64) void = null,
    };

    pub fn run(self: Subroutine, owner: *Owner, text: []const u8) Error!Output {
        return self.vtable.run(self.context, owner, text);
    }

    pub fn choose(self: Subroutine, gpa: Allocator, id: u64) Outcome {
        return self.vtable.choose(self.context, gpa, id);
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

    pub fn takesArguments(self: Subroutine) bool {
        return self.vtable.chooseWith != null;
    }

    pub fn chooseWith(self: Subroutine, gpa: Allocator, id: u64, arguments: []const u8) Outcome {
        const call = self.vtable.chooseWith orelse return .keep;
        return call(self.context, gpa, id, arguments);
    }

    pub fn counters(self: Subroutine, id: u64) ?rank.Weight {
        const call = self.vtable.counters orelse return null;
        return call(self.context, id);
    }

    pub fn forget(self: Subroutine, id: u64) void {
        const call = self.vtable.forget orelse return;
        call(self.context, id);
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

        fn actions(context: *anyopaque, arena: Allocator, id: u64) Error![]const Action {
            return Methods.actions(of(context), arena, id);
        }

        fn perform(context: *anyopaque, gpa: Allocator, id: u64, action: u64) Outcome {
            return Methods.perform(of(context), gpa, id, action);
        }

        fn picks(context: *anyopaque, owner: *Owner, limit: usize) Error!Output {
            return Methods.picks(of(context), owner, limit);
        }

        fn chooseWith(context: *anyopaque, gpa: Allocator, id: u64, arguments: []const u8) Outcome {
            return Methods.chooseWith(of(context), gpa, id, arguments);
        }

        fn counters(context: *anyopaque, id: u64) ?rank.Weight {
            return Methods.counters(of(context), id);
        }

        fn forget(context: *anyopaque, id: u64) void {
            Methods.forget(of(context), id);
        }

        const table: Subroutine.VTable = .{
            .run = &run,
            .choose = &choose,
            .actions = if (@hasDecl(Methods, "actions")) &actions else null,
            .perform = if (@hasDecl(Methods, "perform")) &perform else null,
            .picks = if (@hasDecl(Methods, "picks")) &picks else null,
            .chooseWith = if (@hasDecl(Methods, "chooseWith")) &chooseWith else null,
            .counters = if (@hasDecl(Methods, "counters")) &counters else null,
            .forget = if (@hasDecl(Methods, "forget")) &forget else null,
        };
    };

    return &shim.table;
}

pub const Lifecycle = struct {
    name: []const u8,
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stale: *const fn (context: *anyopaque) bool,
        refresh: *const fn (context: *anyopaque) void,
        stop: *const fn (context: *anyopaque) void,
        retire: *const fn (context: *anyopaque) void,
    };

    pub fn stale(self: Lifecycle) bool {
        return self.vtable.stale(self.context);
    }

    pub fn refresh(self: Lifecycle) void {
        self.vtable.refresh(self.context);
    }

    pub fn stop(self: Lifecycle) void {
        self.vtable.stop(self.context);
    }

    pub fn retire(self: Lifecycle) void {
        self.vtable.retire(self.context);
    }
};

pub fn lifecycleOf(comptime Index: type) *const Lifecycle.VTable {
    comptime {
        if (@hasDecl(Index, "stale") != @hasDecl(Index, "refresh")) {
            @compileError(@typeName(Index) ++ " declares only one of pub stale and pub refresh");
        }
        if (keepsCounters(Index) and !@hasDecl(Index, "retire")) {
            @compileError(@typeName(Index) ++ " keeps counters and declares no pub retire to write them");
        }
    }

    const shim = struct {
        fn of(context: *anyopaque) *Index {
            return @ptrCast(@alignCast(context));
        }

        fn stale(context: *anyopaque) bool {
            return if (comptime @hasDecl(Index, "stale")) Index.stale(of(context)) else false;
        }

        fn refresh(context: *anyopaque) void {
            if (comptime @hasDecl(Index, "refresh")) Index.refresh(of(context));
        }

        fn stop(context: *anyopaque) void {
            if (comptime @hasDecl(Index, "stop")) Index.stop(of(context));
        }

        fn retire(context: *anyopaque) void {
            if (comptime @hasDecl(Index, "retire")) Index.retire(of(context));
        }

        const table: Lifecycle.VTable = .{
            .stale = &stale,
            .refresh = &refresh,
            .stop = &stop,
            .retire = &retire,
        };
    };

    return &shim.table;
}

fn keepsCounters(comptime Index: type) bool {
    for (@typeInfo(Index).@"struct".field_types) |field| {
        if (field == Counts) return true;
        if (@typeInfo(field) != .@"struct") continue;

        for (@typeInfo(field).@"struct".field_types) |inner| {
            if (inner == Counts) return true;
        }
    }
    return false;
}

pub fn themedIcon(names: []const [:0]const u8) [:0]const u8 {
    const last = names[names.len - 1];
    const display = gdk.gdk_display_get_default() orelse return last;
    const theme = gtk.gtk_icon_theme_get_for_display(display);

    for (names) |name| {
        if (gtk.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    }
    return last;
}

test {
    _ = apps;
    _ = bins;
    _ = bookmarks;
    _ = clipboard;
    _ = disk;
    _ = inca;
    _ = llm;
    _ = mpris;
    _ = nm;
    _ = podman;
    _ = processes;
    _ = screenshot;
    _ = snippets;
    _ = ssh;
    _ = sway;
    _ = websearch;
    _ = whats;
}

const testing = std.testing;

test "an owner frees its memory and unrefs the icons it kept" {
    const owner = try Owner.create(testing.allocator);

    const icon = gio.g_icon_new_for_string("image-png", null).?;
    var alive: ?*anyopaque = icon;
    glib.g_object_add_weak_pointer(c.cast(c.GObject, icon), &alive);

    const kept = owner.keep(icon);
    try testing.expectEqual(icon, kept.gicon);

    const text = try owner.allocator().dupe(u8, "rows live here");
    try testing.expectEqualStrings("rows live here", text);

    owner.destroy(testing.allocator);
    try testing.expectEqual(null, alive);
}

test "an icon the owner has no room for is released at once" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var owner: Owner = .init(failing.allocator());
    defer owner.deinit();

    const icon = gio.g_icon_new_for_string("image-png", null).?;
    var alive: ?*anyopaque = icon;
    glib.g_object_add_weak_pointer(c.cast(c.GObject, icon), &alive);

    try testing.expect(owner.keep(icon) == .none);
    try testing.expectEqual(null, alive);
}

test "a produced result without an owner is released without a free" {
    const empty: Produced = .{};
    empty.release(testing.allocator);

    try testing.expectEqual(Output.nothing, empty.output);
}

const Fixed = struct {
    chosen: []const u8 = "",
    forgotten: bool = false,

    fn run(_: *Fixed, _: *Owner, _: []const u8) Error!Output {
        return .nothing;
    }

    fn choose(_: *Fixed, _: Allocator, _: u64) Outcome {
        return .close;
    }
};

const Started = struct {
    pub const Context = Fixed;

    const run = Fixed.run;
    const choose = Fixed.choose;

    pub fn chooseWith(self: *Fixed, _: Allocator, _: u64, arguments: []const u8) Outcome {
        self.chosen = arguments;
        return .close;
    }
};

test "a subroutine takes arguments exactly when it declares chooseWith" {
    var fixed: Fixed = .{};

    const plain: Subroutine = .{ .name = "plain", .context = &fixed, .vtable = vtableOf(Fixed) };
    try testing.expect(!plain.takesArguments());
    try testing.expectEqual(Outcome.keep, plain.chooseWith(testing.allocator, 1, "--private-window"));

    const started: Subroutine = .{ .name = "started", .context = &fixed, .vtable = vtableOf(Started) };
    try testing.expect(started.takesArguments());
    try testing.expectEqual(Outcome.close, started.chooseWith(testing.allocator, 1, "--private-window"));
    try testing.expectEqualStrings("--private-window", fixed.chosen);
}

const Counted = struct {
    pub const Context = Fixed;

    const run = Fixed.run;
    const choose = Fixed.choose;

    pub fn counters(self: *Fixed, id: u64) ?rank.Weight {
        if (id != 7 or self.forgotten) return null;
        return .{ .shown = 4, .chosen = 2 };
    }

    pub fn forget(self: *Fixed, _: u64) void {
        self.forgotten = true;
    }
};

const Aged = struct {
    refreshed: usize = 0,
    stopped: usize = 0,
    retired: usize = 0,

    pub fn stale(_: *Aged) bool {
        return true;
    }

    pub fn refresh(self: *Aged) void {
        self.refreshed += 1;
    }

    pub fn stop(self: *Aged) void {
        self.stopped += 1;
    }

    pub fn retire(self: *Aged) void {
        self.retired += 1;
    }
};

test "a lifecycle calls what its index declares and does nothing for the rest" {
    var aged: Aged = .{};
    const declared: Lifecycle = .{ .name = "aged", .context = &aged, .vtable = lifecycleOf(Aged) };

    try testing.expect(declared.stale());
    declared.refresh();
    declared.stop();
    declared.retire();
    try testing.expectEqual(1, aged.refreshed);
    try testing.expectEqual(1, aged.stopped);
    try testing.expectEqual(1, aged.retired);

    var fixed: Fixed = .{};
    const bare: Lifecycle = .{ .name = "fixed", .context = &fixed, .vtable = lifecycleOf(Fixed) };

    try testing.expect(!bare.stale());
    bare.refresh();
    bare.stop();
    bare.retire();
}

test "only a subroutine that declares counters has any to read or forget" {
    var fixed: Fixed = .{};

    const plain: Subroutine = .{ .name = "plain", .context = &fixed, .vtable = vtableOf(Fixed) };
    try testing.expectEqual(null, plain.counters(7));
    plain.forget(7);
    try testing.expect(!fixed.forgotten);

    const counted: Subroutine = .{ .name = "counted", .context = &fixed, .vtable = vtableOf(Counted) };
    try testing.expectEqual(rank.Weight{ .shown = 4, .chosen = 2 }, counted.counters(7).?);
    try testing.expectEqual(null, counted.counters(8));

    counted.forget(7);
    try testing.expect(fixed.forgotten);
}

pub const Fixture = struct {
    tmp: testing.TmpDir,
    environ: std.process.Environ.Map,
    owner: *Owner,
    root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    script_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    script: []const u8 = "",

    pub fn init(self: *Fixture, name: []const u8, script: []const u8) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .environ = .init(testing.allocator), .owner = undefined };
        errdefer self.environ.deinit();
        errdefer self.tmp.cleanup();

        const length = try self.tmp.dir.realPath(testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..length];
        self.script = try std.mem.print(&self.script_buffer, "{s}/{s}", .{ self.root, name });

        try self.environ.put("PATH", "/usr/bin:/bin");
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = name,
            .data = script,
            .flags = .{ .permissions = .executable_file },
        });

        self.owner = try Owner.create(testing.allocator);
    }

    pub fn deinit(self: *Fixture) void {
        self.owner.destroy(testing.allocator);
        self.environ.deinit();
        self.tmp.cleanup();
    }

    pub fn hits(self: *Fixture, comptime View: type, index: *View.Context, query: []const u8) ![]const Hit {
        return switch (try View.run(index, self.owner, query)) {
            .hits => |found| found,
            else => &.{},
        };
    }

    pub fn only(self: *Fixture, comptime View: type, index: *View.Context, query: []const u8) !model.Row {
        const found = try self.hits(View, index, query);
        try testing.expectEqual(1, found.len);
        return found[0].row;
    }
};

pub fn expectNoLeak(comptime run: anytype, extra: anytype) !void {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        @call(.auto, run, .{failing.allocator()} ++ extra) catch |err| {
            if (err != error.OutOfMemory) return err;
        };
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failing.has_induced_failure) break;
    }
    try testing.expect(fail_index > 0);
}
