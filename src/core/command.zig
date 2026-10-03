const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const max_message = 64 << 10;
const reserve = 64 << 10;

pub const Limits = struct {
    timeout: ?Io.Duration = .fromSeconds(10),
    output: usize = 256 << 20,
};

pub const Line = struct {
    program: []const u8,
    arguments: []const []const u8,

    pub fn format(self: Line, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll(self.program);
        for (self.arguments) |argument| try writer.print(" {s}", .{argument});
    }
};

pub const Exit = struct {
    code: u8,
    output: []const u8,

    pub fn message(self: Exit) []const u8 {
        return lastLineOf(self.output);
    }
};

pub const Malformed = struct {
    expected: []const u8,
    cause: anyerror,
};

pub const Failure = union(enum) {
    exited: Exit,
    signal: u32,
    timeout: Io.Duration,
    too_large: usize,
    malformed: Malformed,
    cause: anyerror,

    pub fn format(self: Failure, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .exited => |exit| {
                try writer.print("exited with {d}", .{exit.code});
                if (exit.message().len > 0) try writer.print(": {s}", .{exit.message()});
            },
            .signal => |number| try writer.print("was ended by signal {d}", .{number}),
            .timeout => |limit| try writer.print("took longer than {d} ms", .{limit.toMilliseconds()}),
            .too_large => |limit| try writer.print("printed more than {d} bytes", .{limit}),
            .malformed => |found| try writer.print("printed what isn't {s}: {t}", .{ found.expected, found.cause }),
            .cause => |err| try writer.print("could not be started: {t}", .{err}),
        }
    }
};

pub const Ran = union(enum) {
    printed: []u8,
    missing,
    failed: Failure,
};

pub fn run(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    limits: Limits,
) error{ OutOfMemory, Canceled }!Ran {
    const ran = std.process.run(gpa, io, .{
        .argv = argv,
        .environ_map = environ,
        .stdout_limit = .limited(limits.output),
        .stderr_limit = .limited(max_message),
        .reserve_amount = reserve,
        .timeout = deadlineOf(io, limits),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.FileNotFound => .missing,
        error.Timeout => .{ .failed = .{ .timeout = limits.timeout orelse .zero } },
        error.StreamTooLong => .{ .failed = .{ .too_large = limits.output } },
        else => .{ .failed = .{ .cause = err } },
    };
    defer gpa.free(ran.stderr);
    return finished(gpa, arena, ran.term, ran.stdout, ran.stderr);
}

pub fn merged(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    limits: Limits,
) error{ OutOfMemory, Canceled }!Ran {
    var ends: [2]std.posix.fd_t = undefined;
    if (std.c.pipe2(&ends, .{ .CLOEXEC = true }) != 0) return .{ .failed = .{ .cause = error.SystemResources } };
    const reading: Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
    const writing: Io.File = .{ .handle = ends[1], .flags = .{ .nonblocking = false } };
    defer reading.close(io);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .{ .file = writing },
        .stderr = .{ .file = writing },
    }) catch |err| {
        writing.close(io);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.FileNotFound => .missing,
            else => .{ .failed = .{ .cause = err } },
        };
    };
    writing.close(io);
    defer child.kill(io);

    var buffer: Io.File.MultiReader.Buffer(1) = undefined;
    var streams: Io.File.MultiReader = undefined;
    streams.init(gpa, io, buffer.toStreams(), &.{reading});
    defer streams.deinit();

    const deadline = deadlineOf(io, limits);
    while (streams.fill(reserve, deadline)) |_| {
        if (streams.reader(0).buffered().len > limits.output) return .{ .failed = .{ .too_large = limits.output } };
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Canceled => return error.Canceled,
        error.Timeout => return .{ .failed = .{ .timeout = limits.timeout orelse .zero } },
        else => return .{ .failed = .{ .cause = err } },
    }
    streams.checkAnyError() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => .{ .failed = .{ .cause = err } },
    };

    const term = child.wait(io) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => .{ .failed = .{ .cause = err } },
    };
    return finished(gpa, arena, term, try streams.toOwnedSlice(0), "");
}

fn deadlineOf(io: Io, limits: Limits) Io.Timeout {
    const budget: Io.Timeout = if (limits.timeout) |limit| .{ .duration = .{ .raw = limit, .clock = .awake } } else .none;
    return budget.toDeadline(io);
}

fn finished(
    gpa: Allocator,
    arena: Allocator,
    term: std.process.Child.Term,
    output: []u8,
    errors: []const u8,
) Allocator.Error!Ran {
    errdefer gpa.free(output);

    const failure: Failure = switch (term) {
        .exited => |code| if (code == 0) return .{ .printed = output } else .{ .exited = .{
            .code = code,
            .output = try arena.dupe(u8, explanation(errors, output)),
        } },
        .signal => |number| .{ .signal = @intFromEnum(number) },
        .stopped, .unknown => .{ .cause = error.Unexpected },
    };
    gpa.free(output);
    return .{ .failed = failure };
}

fn explanation(errors: []const u8, output: []const u8) []const u8 {
    const printed = std.mem.trim(u8, errors, &std.ascii.whitespace);
    if (printed.len > 0) return printed;
    return lastLineOf(output);
}

fn lastLineOf(text: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, &std.ascii.whitespace), '\n');
    return std.mem.trim(u8, lines.first(), &std.ascii.whitespace);
}

const testing = std.testing;

const Script = struct {
    tmp: testing.TmpDir,
    buffer: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",
    environ: std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Script, body: []const u8) !void {
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .environ = .init(testing.allocator),
            .arena = .init(testing.allocator),
        };
        errdefer self.deinit();

        try self.environ.put("PATH", "/usr/bin:/bin");
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "program",
            .data = body,
            .flags = .{ .permissions = .executable_file },
        });
        const length = try self.tmp.dir.realPath(testing.io, &self.buffer);
        self.path = try std.fmt.bufPrint(self.buffer[length..], "{s}/program", .{self.buffer[0..length]});
    }

    fn deinit(self: *Script) void {
        self.arena.deinit();
        self.environ.deinit();
        self.tmp.cleanup();
    }

    fn merge(self: *Script, limits: Limits) !Ran {
        return command.merged(testing.allocator, self.arena.allocator(), testing.io, &self.environ, &.{self.path}, limits);
    }

    fn run(self: *Script, arguments: []const []const u8, limits: Limits) !Ran {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.append(testing.allocator, self.path);
        try argv.appendSlice(testing.allocator, arguments);
        return command.run(testing.allocator, self.arena.allocator(), testing.io, &self.environ, argv.items, limits);
    }
};

const command = @This();

test "the arguments reach the program as given and its output comes back" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\nprintf '%s|' \"$@\"\n");
    defer script.deinit();

    const printed = (try script.run(&.{ "ps", "-a", "two words" }, .{})).printed;
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings("ps|-a|two words|", printed);
}

test "a command line prints the program and its arguments" {
    var buffer: [64]u8 = undefined;
    const line: Line = .{ .program = "/usr/bin/podman", .arguments = &.{ "ps", "-a" } };
    try testing.expectEqualStrings("/usr/bin/podman ps -a", try std.fmt.bufPrint(&buffer, "{f}", .{line}));

    const bare: Line = .{ .program = "inca", .arguments = &.{} };
    try testing.expectEqualStrings("inca", try std.fmt.bufPrint(&buffer, "{f}", .{bare}));
}

test "a program that isn't there is missing" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\n");
    defer script.deinit();

    script.path = "/nonexistent/sysdeck-test/program";
    try testing.expectEqual(Ran.missing, try script.run(&.{}, .{}));
}

test "a failing program reports its exit code and its error output, whose last line explains it" {
    var script: Script = undefined;
    try script.init(
        \\#!/bin/sh
        \\echo 'starting' >&2
        \\echo 'level=ERROR msg="Could not open the database"' >&2
        \\exit 3
        \\
    );
    defer script.deinit();

    const failure = (try script.run(&.{}, .{})).failed;
    try testing.expectEqual(@as(u8, 3), failure.exited.code);
    try testing.expectEqualStrings("starting\nlevel=ERROR msg=\"Could not open the database\"", failure.exited.output);
    try testing.expectEqualStrings("level=ERROR msg=\"Could not open the database\"", failure.exited.message());

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "exited with 3: level=ERROR msg=\"Could not open the database\"",
        try std.fmt.bufPrint(&buffer, "{f}", .{failure}),
    );
}

test "without error output the last line of the output explains the exit" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\necho 'first'\necho 'broken database'\nexit 1\n");
    defer script.deinit();

    const failure = (try script.run(&.{}, .{})).failed;
    try testing.expectEqualStrings("broken database", failure.exited.output);
    try testing.expectEqualStrings("broken database", failure.exited.message());
}

test "a program past its deadline is killed and reported" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\nexec sleep 5\n");
    defer script.deinit();

    const started = Io.Clock.awake.now(testing.io);
    const failure = (try script.run(&.{}, .{ .timeout = .fromMilliseconds(200) })).failed;
    const took = started.durationTo(Io.Clock.awake.now(testing.io));

    try testing.expectEqual(@as(i64, 200), failure.timeout.toMilliseconds());
    try testing.expect(took.toMilliseconds() < 2000);
}

test "a program without a deadline is waited for" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\nsleep 0.3\necho done\n");
    defer script.deinit();

    const started = Io.Clock.awake.now(testing.io);
    const printed = (try script.run(&.{}, .{ .timeout = null })).printed;
    defer testing.allocator.free(printed);
    const took = started.durationTo(Io.Clock.awake.now(testing.io));

    try testing.expectEqualStrings("done\n", printed);
    try testing.expect(took.toMilliseconds() >= 300);
}

test "output beyond the limit is too large" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\nprintf '%0100d' 0\n");
    defer script.deinit();

    const failure = (try script.run(&.{}, .{ .output = 16 })).failed;
    try testing.expectEqual(@as(usize, 16), failure.too_large);
}

test "merged output keeps the order in which both streams were written" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\necho first\necho second >&2\necho third\necho fourth >&2\n");
    defer script.deinit();

    const printed = (try script.merge(.{})).printed;
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings("first\nsecond\nthird\nfourth\n", printed);
}

test "a merged program that fails reports the last line it wrote on either stream" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\necho 'starting'\necho 'Error: no such container' >&2\nexit 125\n");
    defer script.deinit();

    const failure = (try script.merge(.{})).failed;
    try testing.expectEqual(@as(u8, 125), failure.exited.code);
    try testing.expectEqualStrings("Error: no such container", failure.exited.message());

    script.path = "/nonexistent/sysdeck-test/program";
    try testing.expectEqual(Ran.missing, try script.merge(.{}));
}

test "a merged program past its deadline or its limit is killed and reported" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\nprintf '%0100d' 0\nexec sleep 5\n");
    defer script.deinit();

    const started = Io.Clock.awake.now(testing.io);
    const late = (try script.merge(.{ .timeout = .fromMilliseconds(200) })).failed;
    try testing.expectEqual(@as(i64, 200), late.timeout.toMilliseconds());
    try testing.expect(started.durationTo(Io.Clock.awake.now(testing.io)).toMilliseconds() < 2000);

    const large = (try script.merge(.{ .output = 16 })).failed;
    try testing.expectEqual(@as(usize, 16), large.too_large);
}

test "output that isn't the expected format names what was expected" {
    const failure: Failure = .{ .malformed = .{ .expected = "podman's JSON", .cause = error.SyntaxError } };

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "printed what isn't podman's JSON: SyntaxError",
        try std.fmt.bufPrint(&buffer, "{f}", .{failure}),
    );
}
