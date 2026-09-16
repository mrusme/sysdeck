const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const c = @import("gtk/c.zig");
const glib = @import("gtk/glib.zig");
const capture = @import("clipboard/capture.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const default = @import("app/session.zig");
const dmenu = @import("app/dmenu.zig");
const input = @import("core").input;
const precheck = @import("system/precheck.zig");

const Allocator = std.mem.Allocator;

const prgname = "sysdeck";
const version = build_options.version;

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .warn,
    },
};

pub fn main(init: std.process.Init) !u8 {
    glib.g_set_prgname(prgname);

    const gpa = init.gpa;

    var arguments: std.ArrayList([:0]const u8) = .empty;
    defer arguments.deinit(gpa);

    var walker = init.minimal.args.iterate();
    _ = walker.skip();
    while (walker.next()) |argument| try arguments.append(gpa, argument);

    const loaded = config.load(gpa, init.io, init.environ_map);
    defer loaded.deinit();

    var failure: cli.Failure = undefined;
    const action = cli.parse(arguments.items, loaded.value.list.rows(), &failure) catch {
        try write(init.io, .stderr(), "{s}: {f}\n\n{s}\n", .{ prgname, failure, cli.usage });
        return 2;
    };

    const options = switch (action) {
        .help => {
            try write(init.io, .stdout(), "{s}\n", .{cli.usage});
            return 0;
        },
        .version => {
            try write(init.io, .stdout(), prgname ++ " " ++ version ++ "\n", .{});
            return 0;
        },
        .run => |wanted| wanted,
    };

    const interactive = options.mode != .clipboard and options.mode != .clipboard_clear;
    if (precheck.isRunningOn(init)) return precheck.refuse(interactive);

    return switch (options.mode) {
        .default => if (default.run(init, &loaded.value, loaded.changed_at, &loaded, options)) 0 else 1,
        .dmenu => try pick(init, options),
        .clipboard => try capture.run(init, loaded.value.sources.clipboard.limits()),
        .clipboard_clear => try capture.clear(init),
    };
}

fn pick(init: std.process.Init, options: cli.Options) !u8 {
    const gpa = init.gpa;

    if (try std.Io.File.stdin().isTty(init.io)) {
        try write(init.io, .stderr(), "{s}: --dmenu needs a list on standard input\n", .{prgname});
        return 2;
    }

    var lines = input.read(gpa, init.io) catch |err| switch (err) {
        error.TooLarge => {
            try write(init.io, .stderr(), "{s}: standard input is too long to read\n", .{prgname});
            return 2;
        },
        error.ReadFailed => {
            try write(init.io, .stderr(), "{s}: cannot read standard input\n", .{prgname});
            return 2;
        },
        error.OutOfMemory => |leftover| return leftover,
    };
    defer lines.deinit();

    if (lines.items.items.len == 0) {
        try write(init.io, .stderr(), "{s}: standard input held no items\n", .{prgname});
        return 1;
    }

    const picked = dmenu.run(gpa, lines.items.items, options) orelse return 1;
    try write(init.io, .stdout(), "{s}\n", .{lines.items.items[picked].text});
    return 0;
}

fn write(io: std.Io, file: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var out = file.writer(io, &buffer);
    try out.interface.print(fmt, args);
    try out.interface.flush();
}

test {
    _ = @import("app/bench.zig");
    _ = @import("app/dispatch.zig");
    _ = @import("app/dmenu.zig");
    _ = @import("app/jobs.zig");
    _ = @import("app/panes.zig");
    _ = @import("cli.zig");
    _ = @import("clipboard/capture.zig");
    _ = @import("clipboard/clipboard.zig");
    _ = @import("config.zig");
    _ = @import("extensions.zig");
    _ = @import("gtk/c.zig");
    _ = @import("llm/chat.zig");
    _ = @import("subroutines/llm.zig");
    _ = @import("llm/service.zig");
    _ = @import("nm/dbus.zig");
    _ = @import("nm/counters.zig");
    _ = @import("nm/manager.zig");
    _ = @import("nm/state.zig");
    _ = @import("app/ask.zig");
    _ = @import("app/shot.zig");
    _ = @import("screenshot/box.zig");
    _ = @import("screenshot/capture.zig");
    _ = @import("screenshot/overlay.zig");
    _ = @import("screenshot/image.zig");
    _ = @import("screenshot/save.zig");
    _ = @import("subroutines.zig");
    _ = @import("subroutines/indexed.zig");
    _ = @import("subroutines/source.zig");
    _ = @import("subroutines/tallied.zig");
    _ = @import("system/launch.zig");
    _ = @import("system/terminal.zig");
    _ = @import("ui/keys.zig");
    _ = @import("ui/reply.zig");
}
