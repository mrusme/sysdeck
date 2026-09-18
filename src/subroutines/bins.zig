const std = @import("std");
const indexed = @import("indexed.zig");
const launch = @import("../system/launch.zig");
const model = @import("../model.zig");
const source = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const terminal_mod = @import("../system/terminal.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.bins);

pub const table = tables.bins;

const max_rows = 200;

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
    indexed: indexed.Indexed,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    terminal: ?terminal_mod.Terminal,
    shell: []const u8,
    icon: [:0]const u8,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Index) };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.indexed.hits(owner, text, .{ .max_rows = max_rows });
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.indexed.picks(owner, .{ .limit = limit });
    }

    pub fn stale(self: *Index) bool {
        return self.indexed.stale();
    }

    pub fn retire(self: *Index, store: ?*store_mod.Store) void {
        self.indexed.retire(store);
    }

    pub fn refresh(self: *Index) void {
        log.debug("refreshing the index", .{});

        var arena: std.heap.ArenaAllocator = .init(self.indexed.gpa);
        defer arena.deinit();

        const scanned = scan(arena.allocator(), self.io, self.environ, self.icon) catch |err| {
            return source.report(table, "scan", err);
        };

        const records = self.indexed.write(arena.allocator(), scanned);
        self.indexed.republish(records, &iconOf, self);
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        const of = self.indexed.source.snapshot();
        const index = of.find(id) orelse return .keep;

        const entry = of.entries[index];
        const terminal = self.terminal orelse {
            log.warn("no terminal is installed, so {s} cannot be started", .{entry.detail});
            return .keep;
        };

        const command = launch.login_command;
        if (!launch.inTerminal(gpa, terminal, self.shell, command, entry.detail)) return .keep;

        self.indexed.noteChosen(id);
        return .close;
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("bins")) return null;

    var self: Index = .{
        .indexed = try .init(context.gpa, context.io, table, context.stamp, context.published),
        .io = context.io,
        .environ = context.environ,
        .terminal = context.terminal,
        .shell = context.environ.get("SHELL") orelse subroutines.default_shell,
        .icon = subroutines.themedIcon(&icon_names),
    };
    errdefer self.indexed.retire(null);

    const found = self.indexed.prepare(context.store) orelse return self;
    self.indexed.source.needs_refresh = store_mod.stale(
        found.updatedAt(table),
        context.stamp,
        context.age(context.settings.sources.bins.max_age_minutes),
    );

    var arena: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena.deinit();

    const records = self.indexed.stored(found, arena.allocator()) orelse return self;
    if (records.len == 0) return self;

    try self.indexed.adopt(records, &iconOf, &self);
    return self;
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

    var parts = std.mem.splitScalar(u8, path, ':');
    while (parts.next()) |part| {
        if (part.len == 0 or !std.fs.path.isAbsolute(part)) continue;
        try add(arena, &wanted, &seen, part);
    }

    for (system_paths) |directory| try add(arena, &wanted, &seen, directory);

    if (home.len > 0) {
        for (home_paths) |suffix| {
            try add(arena, &wanted, &seen, try std.fs.path.join(arena, &.{ home, suffix }));
        }
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

fn iconOf(context: ?*anyopaque, arena: Allocator, record: store_mod.Record) model.Icon {
    const self: *Index = @ptrCast(@alignCast(context orelse return .none));
    if (record.icon.len == 0) return .{ .name = self.icon };

    const name = arena.dupeZ(u8, record.icon) catch return .{ .name = self.icon };
    return .{ .name = name };
}

const testing = std.testing;

test "the path entries come first, so a name is shadowed the way the shell shadows it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try searchPaths(arena.allocator(), "/home/tester", "/opt/tools/bin");

    try testing.expectEqualStrings("/opt/tools/bin", found[0]);
    try testing.expectEqualStrings("/usr/local/bin", found[1]);
    try testing.expectEqualStrings("/home/tester/.bin", found[1 + system_paths.len]);
}

test "a home directory the user put on the path keeps the position the path gave it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try searchPaths(
        arena.allocator(),
        "/home/tester",
        "/home/tester/.local/bin:/usr/bin",
    );

    try testing.expectEqualStrings("/home/tester/.local/bin", found[0]);
    try testing.expectEqualStrings("/usr/bin", found[1]);

    var seen: usize = 0;
    for (found) |directory| {
        if (std.mem.eql(u8, directory, "/home/tester/.local/bin")) seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
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
