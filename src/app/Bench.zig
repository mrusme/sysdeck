const std = @import("std");
const benchmark = @import("../benchmark.zig");
const config_mod = @import("../config.zig");
const clock = @import("core").clock;
const modes = @import("../modes.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const terminal_mod = @import("../system/terminal.zig");

const Bench = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.bench);

const search_sources = [_][]const u8{
    "apps",
    "bins",
    "bookmarks",
    "disk",
    "processes",
    "whats",
    "clipboard",
    "screenshot",
    "nm",
    "ssh",
    "snippets",
    "websearch",
    "mpris",
    "inca",
    "podman",
};

const mode_sources = [_][]const u8{ "llm", "sway" };

const member_count = search_sources.len + std.enums.values(modes.Mode).len - 1;
const source_count = search_sources.len + mode_sources.len;
const on = config_mod.Config.Sources.on;

pub const Range = struct {
    from: usize = 0,
    to: usize = 0,

    pub fn empty(self: Range) bool {
        return self.from == self.to;
    }
};

gpa: Allocator,
io: std.Io,
environ: *const std.process.Environ.Map,
store: ?*store_mod.Store = null,
terminal: ?terminal_mod.Terminal = null,

apps: ?subroutines.apps.Index = null,
bins: ?subroutines.bins.Index = null,
bookmarks: ?subroutines.bookmarks.Index = null,
processes: ?subroutines.processes.Index = null,
whats: ?subroutines.whats.Index = null,
sway: ?subroutines.sway.Index = null,
disk: ?subroutines.disk.Index = null,
clipboard: ?subroutines.clipboard.Index = null,
screenshot: ?subroutines.screenshot.Index = null,
llm: ?subroutines.llm.Index = null,
nm: ?subroutines.nm.Index = null,
ssh: ?subroutines.ssh.Index = null,
snippets: ?subroutines.snippets.Index = null,
websearch: ?subroutines.websearch.Index = null,
mpris: ?subroutines.mpris.Index = null,
inca: ?subroutines.inca.Index = null,
podman: ?subroutines.podman.Index = null,

markdown: subroutines.bookmarks.markdown.Adapter = undefined,
chromium: subroutines.bookmarks.chromium.Adapter = undefined,
firefox: subroutines.bookmarks.firefox.Adapter = undefined,
adapters: std.ArrayList(subroutines.bookmarks.Adapter) = .empty,

lifecycles: [source_count]subroutines.Lifecycle = undefined,
opened: usize = 0,
members: [member_count]subroutines.Subroutine = undefined,
arrived: [member_count]?subroutines.Produced = @splat(null),
ranges: std.EnumArray(modes.Mode, Range) = .initFill(.{}),
total: usize = 0,

refreshes: std.Io.Group = .init,

pub fn create(context: subroutines.Context) Allocator.Error!*Bench {
    const gpa = context.gpa;

    const self = try gpa.create(Bench);
    self.* = .{ .gpa = gpa, .io = context.io, .environ = context.environ };
    errdefer self.destroy();

    var opened = context;
    benchmark.begin(.open, "store");
    opened.store = openStore(gpa, context.io, context.environ);
    benchmark.end(.open, "store", null);
    benchmark.begin(.open, "terminal");
    opened.terminal = terminalFor(gpa, context);
    benchmark.end(.open, "terminal", null);
    opened.stamp = clock.now(context.io);

    self.store = opened.store;
    self.terminal = opened.terminal;

    self.createAdapters(opened);

    inline for (search_sources ++ mode_sources) |name| {
        benchmark.begin(.open, name);
        defer benchmark.end(.open, name, @intFromBool(@field(self, name) != null));
        @field(self, name) = if (comptime std.mem.eql(u8, name, "bookmarks"))
            try subroutines.bookmarks.open(opened, self.adapters.items)
        else
            try @field(subroutines, name).open(opened);

        if (@field(self, name)) |*found| self.register(name, found);
    }

    inline for (search_sources) |name| {
        if (@field(self, name)) |*found| self.add(found.subroutine());
    }
    self.mark(.search, 0);

    const history_from = self.total;
    if (self.clipboard) |*found| self.add(found.history());
    self.mark(.history, history_from);

    const asking_from = self.total;
    if (self.llm) |*found| self.add(found.subroutine());
    self.mark(.llm, asking_from);

    const windows_from = self.total;
    if (self.sway) |*found| self.add(found.subroutine());
    self.mark(.windows, windows_from);

    const browsing_from = self.total;
    if (self.disk) |*found| self.add(found.browse());
    self.mark(.disk, browsing_from);

    const evaluating_from = self.total;
    if (self.whats) |*found| self.add(found.evaluate());
    self.mark(.whats, evaluating_from);

    const networking_from = self.total;
    if (self.nm) |*found| self.add(found.network());
    self.mark(.nm, networking_from);

    const looking_from = self.total;
    if (self.inca) |*found| self.add(found.phonebook());
    self.mark(.phonebook, looking_from);

    const managing_from = self.total;
    if (self.podman) |*found| self.add(found.containers());
    self.mark(.containers, managing_from);

    return self;
}

pub fn waitRefreshes(self: *Bench) void {
    self.refreshes.await(self.io) catch |err| switch (err) {
        error.Canceled => {},
    };
}

pub fn stop(self: *Bench) void {
    for (self.lifecycles[0..self.opened]) |lifecycle| lifecycle.stop();
}

pub fn destroy(self: *Bench) void {
    self.waitRefreshes();
    self.stop();
    for (self.lifecycles[0..self.opened]) |lifecycle| lifecycle.retire();

    self.adapters.deinit(self.gpa);
    if (self.terminal) |found| found.deinit(self.gpa);
    if (self.sway) |found| found.deinit(self.gpa);
    if (self.store) |found| found.close();
    self.gpa.destroy(self);
}

pub fn rangeOf(self: *Bench, wanted: modes.Mode) Range {
    return self.ranges.get(wanted);
}

fn mark(self: *Bench, wanted: modes.Mode, from: usize) void {
    self.ranges.set(wanted, .{ .from = from, .to = self.total });
}

pub fn membersOf(self: *Bench, range: Range) []const subroutines.Subroutine {
    return self.members[range.from..range.to];
}

pub fn arrivedOf(self: *Bench, range: Range) []?subroutines.Produced {
    return self.arrived[range.from..range.to];
}

pub fn startRefreshes(self: *Bench) void {
    for (self.lifecycles[0..self.opened]) |lifecycle| {
        if (!lifecycle.stale()) continue;

        self.refreshes.concurrent(self.io, refresh, .{lifecycle}) catch |err| {
            log.warn("cannot refresh {s} on a worker: {t}, so it runs before the window opens", .{
                lifecycle.name,
                err,
            });
            lifecycle.refresh();
        };
    }
}

fn register(self: *Bench, comptime name: []const u8, index: anytype) void {
    std.debug.assert(self.opened < self.lifecycles.len);
    self.lifecycles[self.opened] = .{
        .name = name,
        .context = index,
        .vtable = subroutines.lifecycleOf(@TypeOf(index.*)),
    };
    self.opened += 1;
}

fn add(self: *Bench, member: subroutines.Subroutine) void {
    std.debug.assert(self.total < self.members.len);
    self.members[self.total] = member;
    self.total += 1;
}

fn createAdapters(self: *Bench, context: subroutines.Context) void {
    if (!context.wanted("bookmarks")) return;

    const index = context.settings.index;
    const wanted = context.settings.sources.bookmarks;
    const home = self.environ.get("HOME") orelse "";

    if (wanted.markdown.files.len > 0) {
        self.markdown = .{
            .io = self.io,
            .home = home,
            .files = wanted.markdown.files,
            .max_age_minutes = index.age(wanted.markdown.max_age_minutes),
        };
        self.append(self.markdown.adapter(), "markdown");
    }

    if (wanted.chromium.files.len > 0) {
        self.chromium = .{
            .io = self.io,
            .home = home,
            .files = wanted.chromium.files,
            .max_age_minutes = index.age(wanted.chromium.max_age_minutes),
        };
        self.append(self.chromium.adapter(), "chromium");
    }

    if (wanted.firefox.files.len > 0) {
        self.firefox = .{
            .io = self.io,
            .home = home,
            .files = wanted.firefox.files,
            .max_age_minutes = index.age(wanted.firefox.max_age_minutes),
        };
        self.append(self.firefox.adapter(), "firefox");
    }
}

fn append(self: *Bench, adapter: subroutines.bookmarks.Adapter, name: []const u8) void {
    self.adapters.append(self.gpa, adapter) catch {
        log.warn("out of memory, so the {s} bookmarks are left out", .{name});
    };
}

fn refresh(lifecycle: subroutines.Lifecycle) void {
    benchmark.begin(.refresh, lifecycle.name);
    defer benchmark.end(.refresh, lifecycle.name, null);
    lifecycle.refresh();
}

fn terminalFor(gpa: Allocator, context: subroutines.Context) ?terminal_mod.Terminal {
    return terminal_mod.resolve(gpa, context.environ, context.settings.terminal.command) catch {
        log.warn("out of memory, so no terminal is available", .{});
        return null;
    };
}

fn openStore(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) ?*store_mod.Store {
    const path = store_mod.defaultPath(gpa, environ) catch {
        log.warn("out of memory, so the indexes are not kept", .{});
        return null;
    } orelse {
        log.warn("there is no absolute $XDG_DATA_HOME or $HOME, so the indexes are not kept", .{});
        return null;
    };
    defer gpa.free(path);

    return store_mod.Store.open(gpa, io, path) catch |err| {
        log.warn("cannot open {s}: {t}, so the indexes are not kept", .{ path, err });
        return null;
    };
}

const testing = std.testing;

const Twice = struct {
    refreshed: std.atomic.Value(usize) = .init(0),
    stopped: usize = 0,
    retired: usize = 0,

    pub fn stale(_: *Twice) bool {
        return true;
    }

    pub fn refresh(self: *Twice) void {
        _ = self.refreshed.fetchAdd(1, .monotonic);
    }

    pub fn stop(self: *Twice) void {
        self.stopped += 1;
    }

    pub fn retire(self: *Twice) void {
        self.retired += 1;
    }
};

const Fresh = struct {
    refreshed: std.atomic.Value(usize) = .init(0),

    pub fn stale(_: *Fresh) bool {
        return false;
    }

    pub fn refresh(self: *Fresh) void {
        _ = self.refreshed.fetchAdd(1, .monotonic);
    }
};

const View = struct {
    pub const Context = Twice;

    pub fn run(_: *Twice, _: *subroutines.Owner, _: []const u8) subroutines.Error!subroutines.Output {
        return .nothing;
    }

    pub fn choose(_: *Twice, _: Allocator, _: u64) subroutines.Outcome {
        return .keep;
    }
};

test "an index with two views is refreshed once and retired once, and a fresh one not at all" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var twice: Twice = .{};
    var fresh: Fresh = .{};
    const view: subroutines.Subroutine = .{
        .name = "twice",
        .context = &twice,
        .vtable = subroutines.vtableOf(View),
    };

    const self = try testing.allocator.create(Bench);
    self.* = .{ .gpa = testing.allocator, .io = testing.io, .environ = &environ };
    self.register("twice", &twice);
    self.register("fresh", &fresh);
    self.add(view);
    self.add(view);

    self.startRefreshes();
    self.waitRefreshes();
    self.stop();
    self.destroy();

    try testing.expectEqual(1, twice.refreshed.load(.monotonic));
    try testing.expectEqual(2, twice.stopped);
    try testing.expectEqual(1, twice.retired);
    try testing.expectEqual(0, fresh.refreshed.load(.monotonic));
}
