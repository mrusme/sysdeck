const std = @import("std");

const usage =
    \\Usage: libraries <name>[ >= <version>]...
    \\
;

const missing =
    \\sysdeck needs the development files for {s}, which {s} cannot find.
    \\
    \\  Fedora        gtk4-devel glib2-devel sqlite-devel libgexiv2-devel
    \\                cairo-devel wayland-devel gtk4-layer-shell-devel
    \\  Debian        libgtk-4-dev libglib2.0-dev libsqlite3-dev libgexiv2-dev
    \\                libcairo2-dev libwayland-dev libgtk4-layer-shell-dev
    \\  Arch          gtk4 glib2 sqlite libgexiv2 cairo wayland gtk4-layer-shell
    \\  Alpine        gtk4.0-dev glib-dev sqlite-dev gexiv2-dev cairo-dev
    \\                wayland-dev gtk4-layer-shell-dev
    \\  Gentoo        gui-libs/gtk:4 dev-libs/glib dev-db/sqlite media-libs/gexiv2
    \\                x11-libs/cairo dev-libs/wayland gui-libs/gtk4-layer-shell
    \\  Void          gtk4-devel glib-devel sqlite-devel gexiv2-devel cairo-devel
    \\                wayland-devel gtk4-layer-shell-devel
    \\  FreeBSD       gtk4 glib sqlite3 gexiv2 cairo wayland gtk4-layer-shell
    \\  OpenBSD       gtk+4 glib2 sqlite3 gexiv2 cairo wayland gtk4-layer-shell
    \\  NetBSD        gtk4 glib2 sqlite3 gexiv2 cairo wayland gtk4-layer-shell
    \\
    \\Set PKG_CONFIG if the tool is installed under another name, such as
    \\pkgconf on the BSDs.
    \\
;

const outdated =
    \\sysdeck needs {s} {s} or later, and this system has {s}
    \\
;

const conflicting =
    \\{s} finds each library on its own and rejects them together:
    \\{s}
;

const comparison = " >= ";

const Requirement = struct {
    name: []const u8,
    minimum: ?[]const u8,

    fn parse(text: []const u8) Requirement {
        const name, const minimum = std.mem.cut(u8, text, comparison) orelse return .{
            .name = text,
            .minimum = null,
        };
        return .{ .name = name, .minimum = minimum };
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const pkg_config = std.zig.PkgConfig.exe(init.environ_map);

    var arguments = init.minimal.args.iterate();
    _ = arguments.skip();

    var wanted: std.ArrayList([]const u8) = .empty;
    while (arguments.next()) |argument| try wanted.append(arena, argument);
    if (wanted.items.len == 0) {
        std.debug.print(usage, .{});
        return 2;
    }

    const together = try run(arena, io, try std.mem.concat(arena, []const u8, &.{
        &.{ pkg_config, "--print-errors", "--exists" },
        wanted.items,
    }));
    if (together) |result| {
        if (result.term.success()) return 0;
    }

    for (wanted.items) |text| {
        const requirement: Requirement = .parse(text);

        if (!try succeeds(arena, io, &.{ pkg_config, "--exists", requirement.name })) {
            std.debug.print(missing, .{ requirement.name, pkg_config });
            return 1;
        }

        const minimum = requirement.minimum orelse continue;
        if (try succeeds(arena, io, &.{ pkg_config, "--exists", text })) continue;

        const found = try run(arena, io, &.{ pkg_config, "--modversion", requirement.name });
        std.debug.print(outdated, .{
            requirement.name,
            minimum,
            std.mem.trim(u8, if (found) |result| result.stdout else "", " \t\r\n"),
        });
        return 1;
    }

    std.debug.print(conflicting, .{ pkg_config, if (together) |result| result.stderr else "" });
    return 1;
}

fn run(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !?std.process.RunResult {
    return std.process.run(arena, io, .{ .argv = argv }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn succeeds(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !bool {
    const result = try run(arena, io, argv) orelse return false;
    return result.term.success();
}

const testing = std.testing;

test "a bare name has no minimum" {
    const parsed: Requirement = .parse("glib-2.0");

    try testing.expectEqualStrings("glib-2.0", parsed.name);
    try testing.expectEqual(null, parsed.minimum);
}

test "a name with a minimum is split at the comparison" {
    const parsed: Requirement = .parse("gtk4 >= 4.14");

    try testing.expectEqualStrings("gtk4", parsed.name);
    try testing.expectEqualStrings("4.14", parsed.minimum.?);
}
