const std = @import("std");
const c = @import("../c.zig");
const launch = @import("../launch.zig");
const list = @import("../list.zig");
const rank = @import("../rank.zig");
const source = @import("../source.zig");
const store_mod = @import("../store.zig");
const subroutines = @import("../subroutines.zig");
const terminal_mod = @import("../terminal.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.bins);

pub const table = "bins";

const max_rows = 200;
const default_shell = "/bin/sh";

const icon_names = [_][:0]const u8{ "utilities-terminal", "terminal", "applications-utilities" };

const system_paths = [_][]const u8{
    "/usr/local/bin",
    "/usr/local/sbin",
    "/usr/bin",
    "/usr/sbin",
    "/bin",
    "/sbin",
};

const home_paths = [_][]const u8{
    ".bin",
    ".local/bin",
    ".cargo/bin",
    ".go/bin",
    ".gem/bin",
};

pub const Index = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    source: source.Source,
    terminal: ?terminal_mod.Terminal,
    shell: []const u8,
    icon: [:0]const u8,
    path: ?[:0]const u8 = null,
    published: source.Published = .{},
    stamp: i64 = 0,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = &vtable };
    }
};

const vtable: subroutines.Subroutine.VTable = .{
    .run = &run,
    .choose = &choose,
    .release = &release,
    .stale = &stale,
    .refresh = &refresh,
    .retire = &retire,
};

pub fn open(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    terminal: ?terminal_mod.Terminal,
    store: ?*store_mod.Store,
    max_age_minutes: i64,
    stamp: i64,
    published: source.Published,
) Allocator.Error!Index {
    var self: Index = .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .source = .{ .gpa = gpa, .name = table, .current = .init(try source.empty(gpa)) },
        .terminal = terminal,
        .shell = environ.get("SHELL") orelse default_shell,
        .icon = terminalIcon(),
        .published = published,
        .stamp = stamp,
    };

    const found = store orelse {
        self.source.needs_refresh = true;
        return self;
    };

    found.ensure(table) catch |err| {
        source.report(table, "prepare", err);
        self.source.needs_refresh = true;
        return self;
    };

    self.path = found.path;
    self.source.needs_refresh = store_mod.stale(found.updatedAt(table), stamp, max_age_minutes);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const records = found.load(arena.allocator(), table) catch |err| {
        source.report(table, "load", err);
        return self;
    };
    if (records.len == 0) return self;

    self.source.publish(try source.build(gpa, records, &iconOf, &self));
    return self;
}

fn refresh(context: *anyopaque) void {
    const self: *Index = @ptrCast(@alignCast(context));

    log.debug("refreshing the index", .{});

    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();

    const records = scan(arena.allocator(), self.io, self.environ, self.icon) catch |err| {
        return source.report(table, "scan", err);
    };

    if (self.path) |file| {
        write(self.gpa, file, records, self.stamp) catch |err| source.report(table, "write", err);
    }

    const next = source.build(self.gpa, records, &iconOf, self) catch |err| {
        return source.report(table, "publish", err);
    };
    self.source.publish(next);
    log.debug("published {d} entries", .{next.entries.len});
    self.published.call();
}

fn write(
    gpa: Allocator,
    file: [:0]const u8,
    records: []const store_mod.Record,
    stamp: i64,
) !void {
    const conn = try store_mod.connect(file);
    defer conn.close();

    try store_mod.create(gpa, conn, table);
    try store_mod.replace(gpa, conn, table, records, stamp);
}

pub fn scan(
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    icon: []const u8,
) Allocator.Error![]store_mod.Record {
    const directories = try searchPaths(
        arena,
        environ.get("HOME") orelse "",
        environ.get("PATH") orelse "",
    );

    var records: std.ArrayList(store_mod.Record) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var scanned: std.StringHashMapUnmanaged(void) = .empty;

    for (directories) |directory| {
        try walk(arena, io, directory, icon, &records, &seen, &scanned);
    }

    return records.toOwnedSlice(arena);
}

pub fn searchPaths(
    arena: Allocator,
    home: []const u8,
    path: []const u8,
) Allocator.Error![]const []const u8 {
    var wanted: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (system_paths) |directory| try add(arena, &wanted, &seen, directory);

    if (home.len > 0) {
        for (home_paths) |suffix| {
            try add(arena, &wanted, &seen, try std.fs.path.join(arena, &.{ home, suffix }));
        }
    }

    var parts = std.mem.splitScalar(u8, path, ':');
    while (parts.next()) |part| {
        if (part.len == 0 or !std.fs.path.isAbsolute(part)) continue;
        try add(arena, &wanted, &seen, part);
    }

    return wanted.toOwnedSlice(arena);
}

fn add(
    arena: Allocator,
    wanted: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    directory: []const u8,
) Allocator.Error!void {
    const trimmed = std.mem.trimEnd(u8, directory, "/");
    const kept = if (trimmed.len > 0) trimmed else directory;
    if (seen.contains(kept)) return;

    const owned = try arena.dupe(u8, kept);
    try seen.put(arena, owned, {});
    try wanted.append(arena, owned);
}

fn walk(
    arena: Allocator,
    io: std.Io,
    directory: []const u8,
    icon: []const u8,
    records: *std.ArrayList(store_mod.Record),
    seen: *std.StringHashMapUnmanaged(void),
    scanned: *std.StringHashMapUnmanaged(void),
) Allocator.Error!void {
    var dir = Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = dir.realPath(io, &buffer) catch return;
    const real = buffer[0..length];
    if (scanned.contains(real)) return;
    try scanned.put(arena, try arena.dupe(u8, real), {});

    var walker = dir.iterate();
    while (walker.next(io) catch return) |found| {
        if (found.kind == .directory) continue;
        if (seen.contains(found.name)) continue;

        const info = dir.statFile(io, found.name, .{}) catch continue;
        if (info.kind != .file) continue;
        if (!executable(info.permissions)) continue;

        const name = try arena.dupe(u8, found.name);
        try seen.put(arena, name, {});
        try records.append(arena, .{
            .key = name,
            .title = name,
            .detail = try std.fs.path.join(arena, &.{ directory, name }),
            .program = try std.fs.path.join(arena, &.{ directory, name }),
            .icon = icon,
            .haystack = name,
        });
    }
}

fn executable(permissions: std.Io.File.Permissions) bool {
    if (!std.Io.File.Permissions.has_executable_bit) return true;
    return permissions.toMode() & 0o111 != 0;
}

fn terminalIcon() [:0]const u8 {
    const display = c.gdk_display_get_default() orelse return icon_names[0];
    const theme = c.gtk_icon_theme_get_for_display(display);

    for (icon_names) |name| {
        if (c.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    }
    return icon_names[0];
}

fn iconOf(context: *anyopaque, arena: Allocator, record: store_mod.Record) list.Icon {
    const self: *Index = @ptrCast(@alignCast(context));
    if (record.icon.len == 0) return .{ .name = self.icon };

    const name = arena.dupeZ(u8, record.icon) catch return .{ .name = self.icon };
    return .{ .name = name };
}

fn run(context: *anyopaque, gpa: Allocator, text: []const u8) subroutines.Error!subroutines.Output {
    const self: *Index = @ptrCast(@alignCast(context));

    const query = std.mem.trim(u8, text, " \t");
    if (query.len == 0) return .nothing;

    const of = self.source.snapshot();
    if (of.entries.len == 0) return .nothing;

    const weights = try of.weights(gpa);
    defer gpa.free(weights);

    const matches = try rank.rank(gpa, of.haystacks, weights, query);
    defer gpa.free(matches);
    if (matches.len == 0) return .nothing;

    of.noteShown(matches);

    const shown = matches[0..@min(matches.len, max_rows)];
    const hits = try gpa.alloc(subroutines.Hit, shown.len);
    for (shown, 0..) |match, at| {
        const entry = of.entries[match.index];
        hits[at] = .{
            .row = .{
                .id = match.index,
                .icon = entry.icon,
                .title = entry.title,
                .detail = entry.detail,
                .program = entry.program,
            },
            .score = match.score,
        };
    }

    return .{ .hits = hits };
}

fn choose(context: *anyopaque, gpa: Allocator, id: u64) subroutines.Outcome {
    const self: *Index = @ptrCast(@alignCast(context));

    const of = self.source.snapshot();
    const index: usize = @intCast(id);
    if (index >= of.entries.len) return .keep;

    const entry = of.entries[index];
    const terminal = self.terminal orelse {
        log.warn("no terminal is installed, so {s} cannot be started", .{entry.detail});
        return .keep;
    };

    if (!launch.inTerminal(gpa, terminal, self.shell, entry.detail)) return .keep;

    of.noteChosen(index);
    return .close;
}

fn release(_: *anyopaque, gpa: Allocator, output: subroutines.Output) void {
    switch (output) {
        .nothing, .marks, .answer => {},
        .hits => |hits| gpa.free(hits),
    }
}

fn stale(context: *anyopaque) bool {
    const self: *Index = @ptrCast(@alignCast(context));
    return self.source.needs_refresh;
}

fn retire(context: *anyopaque, store: ?*store_mod.Store) void {
    const self: *Index = @ptrCast(@alignCast(context));
    if (store) |found| self.source.flush(found);
    self.source.deinit();
}

const testing = std.testing;

test "the fixed directories come before the path entries" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try searchPaths(arena.allocator(), "/home/tester", "/opt/tools/bin");

    try testing.expectEqualStrings("/usr/local/bin", found[0]);
    try testing.expectEqualStrings("/home/tester/.bin", found[system_paths.len]);
    try testing.expectEqualStrings("/opt/tools/bin", found[found.len - 1]);
}

test "a path entry already among the fixed directories is not repeated" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try searchPaths(arena.allocator(), "", "/usr/bin:/opt/extra/bin:/usr/bin");

    var usr_bin: usize = 0;
    var extra: usize = 0;
    for (found) |directory| {
        if (std.mem.eql(u8, directory, "/usr/bin")) usr_bin += 1;
        if (std.mem.eql(u8, directory, "/opt/extra/bin")) extra += 1;
    }

    try testing.expectEqual(@as(usize, 1), usr_bin);
    try testing.expectEqual(@as(usize, 1), extra);
}

test "a trailing slash does not make a second entry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try searchPaths(arena.allocator(), "", "/usr/bin/");

    var usr_bin: usize = 0;
    for (found) |directory| {
        if (std.mem.eql(u8, directory, "/usr/bin")) usr_bin += 1;
    }
    try testing.expectEqual(@as(usize, 1), usr_bin);
}

test "relative and empty path entries are left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try searchPaths(arena.allocator(), "", "::relative/bin:.");

    for (found) |directory| try testing.expect(std.fs.path.isAbsolute(directory));
    try testing.expectEqual(system_paths.len, found.len);
}

test "no home leaves the home directories out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try searchPaths(arena.allocator(), "", "");
    try testing.expectEqual(system_paths.len, found.len);
}
