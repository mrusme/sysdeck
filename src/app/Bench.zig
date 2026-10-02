const std = @import("std");
const config_mod = @import("../config.zig");
const clock = @import("core").clock;
const source_mod = @import("../subroutines/source.zig");
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
};

const member_count = search_sources.len + std.enums.values(modes.Mode).len - 1;
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

markdown: subroutines.bookmarks.markdown.Adapter = undefined,
chromium: subroutines.bookmarks.chromium.Adapter = undefined,
firefox: subroutines.bookmarks.firefox.Adapter = undefined,
adapters: std.ArrayList(subroutines.bookmarks.Adapter) = .empty,

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
    opened.store = openStore(gpa, context.io, context.environ);
    opened.terminal = terminalFor(gpa, context);
    opened.stamp = clock.now(context.io);

    self.store = opened.store;
    self.terminal = opened.terminal;

    self.createAdapters(opened);

    inline for (search_sources) |name| {
        @field(self, name) = if (comptime std.mem.eql(u8, name, "bookmarks"))
            try subroutines.bookmarks.open(opened, self.adapters.items)
        else
            try @field(subroutines, name).open(opened);

        if (@field(self, name)) |*found| self.add(found.subroutine());
    }
    self.mark(.search, 0);

    const history_from = self.total;
    if (self.clipboard) |*found| self.add(found.history());
    self.mark(.history, history_from);

    const asking_from = self.total;
    self.llm = try subroutines.llm.open(opened);
    if (self.llm) |*found| self.add(found.subroutine());
    self.mark(.llm, asking_from);

    const windows_from = self.total;
    self.sway = try subroutines.sway.open(opened);
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

    return self;
}

pub fn waitRefreshes(self: *Bench) void {
    self.refreshes.await(self.io) catch |err| switch (err) {
        error.Canceled => {},
    };
    if (self.websearch) |*found| found.stop();
}

pub fn destroy(self: *Bench) void {
    self.waitRefreshes();
    for (self.members[0..self.total]) |member| member.retire(self.store);

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
    for (self.members[0..self.total], 0..) |member, at| {
        if (!member.stale()) continue;

        self.refreshes.concurrent(self.io, refresh, .{member}) catch |err| {
            log.warn("cannot refresh member {d}: {t}", .{ at, err });
        };
    }
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

fn refresh(member: subroutines.Subroutine) void {
    member.refresh();
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
    const path = store_mod.defaultPath(gpa, environ) catch null orelse return null;
    defer gpa.free(path);

    return store_mod.Store.open(gpa, io, path) catch |err| {
        log.warn("cannot open {s}: {t}, so the indexes are not kept", .{ path, err });
        return null;
    };
}
