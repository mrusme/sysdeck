const std = @import("std");
const build_options = @import("build_options");
const c = @import("c.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const default = @import("default.zig");
const dmenu = @import("dmenu.zig");
const input = @import("input.zig");

const Allocator = std.mem.Allocator;

const prgname = "sysdeck";
const version = build_options.version;

pub fn main(init: std.process.Init) !u8 {
    c.g_set_prgname(prgname);

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

    return switch (options.mode) {
        .default => if (default.run(init, &loaded.value, options)) 0 else 1,
        .dmenu => try pick(init, options),
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
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("extensions.zig");
    _ = @import("fuzzy.zig");
    _ = @import("input.zig");
    _ = @import("keys.zig");
    _ = @import("launch.zig");
    _ = @import("rank.zig");
    _ = @import("source.zig");
    _ = @import("store.zig");
    _ = @import("subroutines.zig");
    _ = @import("terminal.zig");
}
