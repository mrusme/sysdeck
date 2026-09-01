const std = @import("std");
const config_mod = @import("../config.zig");
const source_mod = @import("../subroutines/source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const terminal_mod = @import("../system/terminal.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.bench);

const fixed_members = 5;
const optional_members = 3;
const member_count = fixed_members + optional_members;

pub const Submode = enum { search, windows, history };

pub const Range = struct {
    from: usize = 0,
    to: usize = 0,

    pub fn empty(self: Range) bool {
        return self.from == self.to;
    }
};

pub const Bench = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    store: ?*store_mod.Store,
    terminal: ?terminal_mod.Terminal,

    apps: subroutines.apps.Index = undefined,
    bins: subroutines.bins.Index = undefined,
    bookmarks: subroutines.bookmarks.Index = undefined,
    processes: subroutines.processes.Index = undefined,
    whats: subroutines.whats.Index = undefined,
    sway: ?subroutines.sway.Index = null,
    clipboard: ?subroutines.clipboard.Index = null,

    markdown: subroutines.bookmarks.markdown.Adapter = undefined,
    chromium: subroutines.bookmarks.chromium.Adapter = undefined,
    firefox: subroutines.bookmarks.firefox.Adapter = undefined,
    adapters: std.ArrayList(subroutines.bookmarks.Adapter) = .empty,

    members: [member_count]subroutines.Subroutine = undefined,
    arrived: [member_count]?subroutines.Output = @splat(null),
    search: Range = .{},
    windows: Range = .{},
    history: Range = .{},
    total: usize = 0,

    refreshes: std.Io.Group = .init,

    pub fn create(
        gpa: Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        settings: *const config_mod.Config,
        settings_at: ?i64,
        published: source_mod.Published,
    ) Allocator.Error!*Bench {
        const self = try gpa.create(Bench);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .store = openStore(gpa, io, environ),
            .terminal = terminal_mod.resolve(gpa, environ, settings.terminal.command) catch null,
        };
        errdefer self.destroy();

        const index = settings.index;
        const stamp = store_mod.now(io);

        try subroutines.apps.open(
            &self.apps,
            gpa,
            self.store,
            index.maxAge(index.apps),
            stamp,
            published,
        );
        self.add(self.apps.subroutine());

        try subroutines.bins.open(
            &self.bins,
            gpa,
            io,
            environ,
            self.terminal,
            self.store,
            index.maxAge(index.bins),
            stamp,
            published,
        );
        self.add(self.bins.subroutine());

        self.createAdapters(settings);
        try subroutines.bookmarks.open(
            &self.bookmarks,
            gpa,
            environ,
            self.adapters.items,
            self.store,
            stamp,
            settings_at,
            published,
        );
        self.add(self.bookmarks.subroutine());

        self.processes = .{ .io = io };
        self.add(self.processes.subroutine());

        self.whats = .{ .gpa = gpa, .io = io, .environ = environ };
        self.add(self.whats.subroutine());

        if (settings.clipboard.enable) {
            self.clipboard = subroutines.clipboard.open(
                gpa,
                io,
                environ,
                settings.clipboard.limits(),
            ) catch null;
        }
        if (self.clipboard) |*found| self.add(found.subroutine());
        self.search = .{ .from = 0, .to = self.total };

        const history_from = self.total;
        if (self.clipboard) |*found| self.add(found.history());
        self.history = .{ .from = history_from, .to = self.total };

        const windows_from = self.total;
        if (subroutines.sway.enabled(settings.sources.sway.enable, environ)) {
            self.sway = subroutines.sway.open(gpa, io, environ) catch null;
        }
        if (self.sway) |*found| self.add(found.subroutine());
        self.windows = .{ .from = windows_from, .to = self.total };

        return self;
    }

    pub fn waitRefreshes(self: *Bench) void {
        self.refreshes.await(self.io) catch {};
    }

    pub fn destroy(self: *Bench) void {
        self.waitRefreshes();
        for (self.members[0..self.total]) |member| member.retire(self.store);

        self.adapters.deinit(self.gpa);
        if (self.terminal) |found| found.deinit(self.gpa);
        if (self.sway) |found| self.gpa.free(found.socket_path);
        if (self.store) |found| found.close();
        self.gpa.destroy(self);
    }

    pub fn rangeOf(self: *Bench, wanted: Submode) Range {
        return switch (wanted) {
            .search => self.search,
            .windows => self.windows,
            .history => self.history,
        };
    }

    pub fn membersOf(self: *Bench, range: Range) []const subroutines.Subroutine {
        return self.members[range.from..range.to];
    }

    pub fn arrivedOf(self: *Bench, range: Range) []?subroutines.Output {
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
        if (self.total >= self.members.len) return;
        self.members[self.total] = member;
        self.total += 1;
    }

    fn createAdapters(self: *Bench, settings: *const config_mod.Config) void {
        const index = settings.index;
        const home = self.environ.get("HOME") orelse "";
        const wanted = settings.bookmarks;

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
};

fn refresh(member: subroutines.Subroutine) void {
    member.refresh();
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
