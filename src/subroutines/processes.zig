const std = @import("std");
const builtin = @import("builtin");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const fuzzy = @import("core").fuzzy;
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.processes);

pub const table = tables.processes;

const max_marks = 200;
const max_output = 1 << 20;

pub const Index = struct {
    io: std.Io,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Index) };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        const query = std.mem.trim(u8, text, " \t");
        if (query.len == 0) return .nothing;

        return self.marked(owner, query);
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        _: usize,
    ) subroutines.Error!subroutines.Output {
        return self.marked(owner, null);
    }

    fn marked(
        self: *Index,
        owner: *subroutines.Owner,
        query: ?[]const u8,
    ) subroutines.Error!subroutines.Output {
        const arena = owner.allocator();

        const running = list(arena, self.io) catch |err| {
            log.warn("cannot read the running processes: {t}", .{err});
            return .nothing;
        };

        var marks: std.ArrayList(subroutines.Mark) = .empty;

        for (running) |found| {
            if (query) |wanted| {
                if (marks.items.len == max_marks) break;
                if (fuzzy.score(wanted, found.name) == null) continue;
            }

            try marks.append(arena, .{
                .pid = found.pid,
                .name = found.name,
                .program = found.program,
            });
        }

        if (marks.items.len == 0) return .nothing;

        std.mem.sort(subroutines.Mark, marks.items, {}, byPid);
        return .{ .marks = try marks.toOwnedSlice(arena) };
    }

    pub fn stale(_: *Index) bool {
        return false;
    }

    pub fn refresh(_: *Index) void {}

    pub fn retire(_: *Index, _: ?*store_mod.Store) void {}

    pub fn choose(_: *Index, _: Allocator, id: u64) subroutines.Outcome {
        const pid = std.math.cast(std.posix.pid_t, id) orelse return .keep;
        if (!signalled(pid)) {
            log.warn("{d} is not a process this can signal", .{pid});
            return .keep;
        }

        std.posix.kill(pid, .TERM) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => log.warn("cannot signal {d}: {t}", .{ pid, err }),
        };
        return .keep;
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("processes")) return null;
    return .{ .io = context.io };
}

fn byPid(_: void, left: subroutines.Mark, right: subroutines.Mark) bool {
    return left.pid < right.pid;
}

pub fn signalled(pid: std.posix.pid_t) bool {
    return pid > 1;
}

pub const Process = struct {
    pid: i32,
    name: []const u8,
    program: []const u8,
};

const reader = switch (builtin.os.tag) {
    .linux => fromProc,
    else => fromPs,
};

pub fn list(arena: Allocator, io: std.Io) ![]const Process {
    return reader(arena, io);
}

fn fromProc(arena: Allocator, io: std.Io) ![]const Process {
    var found: std.ArrayList(Process) = .empty;

    var dir = try Dir.cwd().openDir(io, "/proc", .{ .iterate = true });
    defer dir.close(io);

    var walker = dir.iterate();
    while (try walker.next(io)) |entry| {
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        var path: [64]u8 = undefined;
        const link = std.fmt.bufPrint(&path, "/proc/{d}/exe", .{pid}) catch continue;

        var target: [std.fs.max_path_bytes]u8 = undefined;
        const length = Dir.cwd().readLink(io, link, &target) catch continue;

        const program = try arena.dupe(u8, target[0..length]);
        try found.append(arena, .{
            .pid = pid,
            .name = std.fs.path.basename(program),
            .program = program,
        });
    }

    return found.toOwnedSlice(arena);
}

fn fromPs(arena: Allocator, _: std.Io) ![]const Process {
    const user = std.mem.span(glib.g_get_user_name());

    const output = try capture(arena, &.{ "ps", "-u", user, "-o", "pid=,comm=,args=" });
    return parse(arena, output orelse "");
}

pub fn parse(arena: Allocator, output: []const u8) Allocator.Error![]const Process {
    var found: std.ArrayList(Process) = .empty;

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");

        const digits = fields.next() orelse continue;
        const pid = std.fmt.parseInt(i32, digits, 10) catch continue;

        const name = fields.next() orelse continue;
        const argv = std.mem.trim(u8, fields.rest(), " \t\r");

        var program: []const u8 = "";
        if (std.mem.indexOfAny(u8, argv, " \t")) |at| {
            program = argv[0..at];
        } else {
            program = argv;
        }
        if (!std.fs.path.isAbsolute(program)) program = "";

        try found.append(arena, .{
            .pid = pid,
            .name = try arena.dupe(u8, name),
            .program = try arena.dupe(u8, program),
        });
    }

    return found.toOwnedSlice(arena);
}

fn capture(arena: Allocator, argv: []const []const u8) !?[]u8 {
    const parts = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |part, at| parts[at] = (try arena.dupeZ(u8, part)).ptr;

    var out: ?[*:0]u8 = null;
    var status: c_int = 0;
    var err: ?*c.GError = null;

    const ran = glib.g_spawn_sync(
        null,
        parts.ptr,
        null,
        c.spawn_search_path | c.spawn_stderr_to_dev_null,
        null,
        null,
        &out,
        null,
        &status,
        &err,
    ) != c.FALSE;

    if (!ran) {
        defer if (err) |detail| glib.g_error_free(detail);
        return null;
    }

    const text = out orelse return null;
    defer glib.g_free(text);

    const span = std.mem.span(text);
    if (span.len == 0 or span.len > max_output) return null;

    return try arena.dupe(u8, span);
}

pub fn belongs(mark: subroutines.Mark, program: []const u8) bool {
    if (program.len == 0) return false;

    if (mark.program.len > 0 and std.mem.eql(u8, mark.program, program)) return true;
    if (mark.program.len > 0 and std.fs.path.isAbsolute(program)) return false;

    return std.mem.eql(u8, mark.name, std.fs.path.basename(program));
}

const testing = std.testing;

fn parsed(arena: Allocator, output: []const u8) []const Process {
    return parse(arena, output) catch unreachable;
}

test "ps output becomes pids, names and paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = parsed(arena.allocator(),
        \\ 1073 systemd         /usr/lib/systemd/systemd --user
        \\ 1112 dbus-broker     /usr/bin/dbus-broker --log 4 --controller 9
        \\21044 btop            btop
    );

    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqual(@as(i32, 1073), found[0].pid);
    try testing.expectEqualStrings("systemd", found[0].name);
    try testing.expectEqualStrings("/usr/lib/systemd/systemd", found[0].program);
    try testing.expectEqualStrings("/usr/bin/dbus-broker", found[1].program);
}

test "an argv that is not a path leaves the program empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = parsed(arena.allocator(), "21044 btop            btop -p 1\n");

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("btop", found[0].name);
    try testing.expectEqualStrings("", found[0].program);
}

test "lines that make no sense are skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = parsed(arena.allocator(),
        \\notapid  something  /usr/bin/something
        \\
        \\1234
        \\ 4321 ok              /usr/bin/ok
    );

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(i32, 4321), found[0].pid);
}

test "the picks mark every running process, whatever the limit" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var self: Index = .{ .io = testing.io };
    const found = try self.picks(owner, 1);

    const own = std.os.linux.getpid();

    var seen = false;
    for (found.marks) |mark| seen = seen or mark.pid == own;
    try testing.expect(seen);
}

test "a mark belongs to a row with the same path" {
    const mark: subroutines.Mark = .{ .pid = 1, .name = "btop", .program = "/usr/bin/btop" };

    try testing.expect(belongs(mark, "/usr/bin/btop"));
    try testing.expect(!belongs(mark, "/opt/btop"));
    try testing.expect(!belongs(mark, ""));
}

test "a mark with no path falls back to the base name" {
    const mark: subroutines.Mark = .{ .pid = 1, .name = "btop", .program = "" };

    try testing.expect(belongs(mark, "/usr/bin/btop"));
    try testing.expect(belongs(mark, "btop"));
    try testing.expect(!belongs(mark, "/usr/bin/htop"));
}

test "a bare program name still matches a mark that has a path" {
    const mark: subroutines.Mark = .{ .pid = 1, .name = "firefox", .program = "/usr/lib/firefox/firefox" };

    try testing.expect(belongs(mark, "firefox"));
    try testing.expect(!belongs(mark, "chromium"));
}

test signalled {
    try testing.expect(signalled(4711));
    try testing.expect(signalled(2));
    try testing.expect(!signalled(1));
    try testing.expect(!signalled(0));
    try testing.expect(!signalled(-1));
    try testing.expect(!signalled(-4711));
}
