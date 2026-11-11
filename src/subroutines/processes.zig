const std = @import("std");
const builtin = @import("builtin");
const glib = @import("../gtk/glib.zig");
const fuzzy = @import("core").fuzzy;
const launch = @import("../system/launch.zig");
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.processes);

pub const table = tables.processes;

const max_marks = 200;

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
                .parent = found.parent,
                .name = found.name,
                .program = found.program,
            });
        }

        if (marks.items.len == 0) return .nothing;

        std.mem.sort(subroutines.Mark, marks.items, {}, byPid);
        return .{ .marks = try marks.toOwnedSlice(arena) };
    }

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
    parent: i32 = 0,
    name: []const u8,
    program: []const u8,
};

const reader = switch (builtin.target.os.tag) {
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
        const link = std.mem.print(&path, "/proc/{d}/exe", .{pid}) catch continue;

        var target: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = Dir.cwd().readLink(io, link, &target) catch continue;

        const status = std.mem.print(&path, "/proc/{d}/stat", .{pid}) catch continue;

        var line: [512]u8 = undefined;
        const stat = Dir.cwd().readFile(io, status, &line) catch continue;
        const parent = parentOf(stat) orelse continue;

        const program = try arena.dupe(u8, target[0..length]);
        try found.append(arena, .{
            .pid = pid,
            .parent = parent,
            .name = std.Io.Dir.path.basename(program),
            .program = program,
        });
    }

    return found.toOwnedSlice(arena);
}

pub fn parentOf(stat: []const u8) ?i32 {
    const named = std.mem.findScalarLast(u8, stat, ')') orelse return null;

    var fields = std.mem.tokenizeScalar(u8, stat[named + 1 ..], ' ');
    _ = fields.next() orelse return null;
    return std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch null;
}

fn fromPs(arena: Allocator, _: std.Io) ![]const Process {
    const user = std.mem.span(glib.g_get_user_name());

    const output = try launch.capture(arena, &.{ "ps", "-u", user, "-o", "pid=,ppid=,comm=,args=" }, null);
    return parse(arena, output orelse "");
}

pub fn parse(arena: Allocator, output: []const u8) Allocator.Error![]const Process {
    var found: std.ArrayList(Process) = .empty;

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");

        const digits = fields.next() orelse continue;
        const pid = std.fmt.parseInt(i32, digits, 10) catch continue;
        const parent = std.fmt.parseInt(i32, fields.next() orelse continue, 10) catch continue;

        const name = fields.next() orelse continue;
        const argv = std.mem.trim(u8, fields.rest(), " \t\r");

        var program: []const u8 = "";
        if (std.mem.findAny(u8, argv, " \t")) |at| {
            program = argv[0..at];
        } else {
            program = argv;
        }
        if (!std.Io.Dir.path.isAbsolute(program)) program = "";

        try found.append(arena, .{
            .pid = pid,
            .parent = parent,
            .name = try arena.dupe(u8, name),
            .program = try arena.dupe(u8, program),
        });
    }

    return found.toOwnedSlice(arena);
}

pub fn belongs(mark: subroutines.Mark, program: []const u8) bool {
    if (program.len == 0) return false;

    if (mark.program.len > 0 and std.mem.eql(u8, mark.program, program)) return true;
    if (mark.program.len > 0 and std.Io.Dir.path.isAbsolute(program)) return false;

    return std.mem.eql(u8, mark.name, std.Io.Dir.path.basename(program));
}

pub fn top(marks: []const subroutines.Mark, mark: subroutines.Mark, program: []const u8) bool {
    for (marks) |other| {
        if (other.pid == mark.parent) return !belongs(other, program);
    }
    return true;
}

const testing = std.testing;

fn parsed(arena: Allocator, output: []const u8) []const Process {
    return parse(arena, output) catch unreachable;
}

test "ps output becomes pids, names and paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = parsed(arena.allocator(),
        \\ 1073     1 systemd         /usr/lib/systemd/systemd --user
        \\ 1112  1073 dbus-broker     /usr/bin/dbus-broker --log 4 --controller 9
        \\21044 20741 btop            btop
    );

    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqual(@as(i32, 1073), found[0].pid);
    try testing.expectEqual(@as(i32, 1), found[0].parent);
    try testing.expectEqual(@as(i32, 1073), found[1].parent);
    try testing.expectEqual(@as(i32, 20741), found[2].parent);
    try testing.expectEqualStrings("systemd", found[0].name);
    try testing.expectEqualStrings("/usr/lib/systemd/systemd", found[0].program);
    try testing.expectEqualStrings("/usr/bin/dbus-broker", found[1].program);
}

test "an argv that is not a path leaves the program empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = parsed(arena.allocator(), "21044 20741 btop            btop -p 1\n");

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("btop", found[0].name);
    try testing.expectEqualStrings("", found[0].program);
}

test "lines that make no sense are skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = parsed(arena.allocator(),
        \\notapid  1  something  /usr/bin/something
        \\
        \\1234
        \\1235 1
        \\1236 noparent  /usr/bin/noparent
        \\ 4321 1 ok              /usr/bin/ok
    );

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(i32, 4321), found[0].pid);
}

test "the picks mark every running process, whatever the limit" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    var self: Index = .{ .io = testing.io };
    const found = try self.picks(owner, 1);

    const own = std.os.linux.getpid();

    var seen = false;
    for (found.marks) |mark| seen = seen or mark.pid == own;
    try testing.expect(seen);
}

test "the parent is the field after the state, whatever the name contains" {
    try testing.expectEqual(@as(?i32, 23908), parentOf("23910 (cat) R 23908 23910 23908 0 -1"));
    try testing.expectEqual(@as(?i32, 77), parentOf("812 (a) (b 9 9) S 77 812 812 0 -1"));
    try testing.expectEqual(@as(?i32, 1), parentOf("5 (Web Content) S 1 5"));

    try testing.expectEqual(@as(?i32, null), parentOf("812 (cat"));
    try testing.expectEqual(@as(?i32, null), parentOf("812 (cat) S"));
    try testing.expectEqual(@as(?i32, null), parentOf("812 (cat) S x 1"));
    try testing.expectEqual(@as(?i32, null), parentOf(""));
}

test "the picks know the parent of this process" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    var self: Index = .{ .io = testing.io };
    const found = try self.picks(owner, 1);

    const own = std.os.linux.getpid();
    for (found.marks) |mark| {
        if (mark.pid != own) continue;
        return testing.expectEqual(std.os.linux.getppid(), mark.parent);
    }
    return error.TestExpectedEqual;
}

const browser = "/usr/lib64/firefox/firefox";

fn marked(pid: i32, parent: i32, program: []const u8) subroutines.Mark {
    return .{ .pid = pid, .parent = parent, .name = std.Io.Dir.path.basename(program), .program = program };
}

test "only the main process of a browser is a top process" {
    const marks = [_]subroutines.Mark{
        marked(22597, 1, "/usr/bin/timeout"),
        marked(22599, 22597, browser),
        marked(22713, 22599, browser),
        marked(22765, 22599, browser),
        marked(22773, 22765, browser),
        marked(22782, 22765, browser),
    };

    var tops: usize = 0;
    for (marks) |mark| {
        if (!belongs(mark, "firefox")) continue;
        if (!top(&marks, mark, "firefox")) continue;

        tops += 1;
        try testing.expectEqual(@as(i32, 22599), mark.pid);
    }
    try testing.expectEqual(@as(usize, 1), tops);
}

test "separate instances are each a top process" {
    const marks = [_]subroutines.Mark{
        marked(900, 1, "/usr/bin/plasmashell"),
        marked(1001, 900, "/usr/bin/konsole"),
        marked(1002, 900, "/usr/bin/konsole"),
        marked(1003, 1, "/usr/bin/konsole"),
    };

    for (marks[1..]) |mark| try testing.expect(top(&marks, mark, "/usr/bin/konsole"));
}

test "a process whose parent is not among the marks is a top process" {
    const marks = [_]subroutines.Mark{
        marked(1001, 900, browser),
        marked(1002, 1001, browser),
    };

    try testing.expect(top(&marks, marks[0], browser));
    try testing.expect(!top(&marks, marks[1], browser));
    try testing.expect(top(&marks, marks[1], "/usr/bin/konsole"));
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
