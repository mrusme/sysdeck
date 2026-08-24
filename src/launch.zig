const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const terminal_mod = @import("terminal.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.launch);

pub const login_command = "exec \"$0\"";

pub fn desktop(info: *c.GDesktopAppInfo) bool {
    const context = launchContext();
    defer if (context) |value| c.g_object_unref(value);

    var err: ?*c.GError = null;
    const started = c.g_desktop_app_info_launch_uris_as_manager(
        info,
        null,
        @ptrCast(context),
        c.spawn_search_path | c.spawn_stdout_to_dev_null | c.spawn_stderr_to_dev_null,
        detach,
        null,
        null,
        null,
        &err,
    ) != c.FALSE;

    if (!started) {
        defer if (err) |detail| c.g_error_free(detail);
        const name = c.g_app_info_get_display_name(@ptrCast(info)) orelse "the chosen app";
        log.warn("cannot start {s}: {s}", .{ name, message(err) });
    }
    return started;
}

pub fn action(info: *c.GDesktopAppInfo, name: [*:0]const u8) void {
    const context = launchContext();
    defer if (context) |value| c.g_object_unref(value);

    c.g_desktop_app_info_launch_action(info, name, @ptrCast(context));
}

pub fn inTerminal(
    gpa: Allocator,
    terminal: terminal_mod.Terminal,
    shell: []const u8,
    path: []const u8,
) bool {
    const argv = terminalArgv(gpa, terminal.argv, shell, path) catch {
        log.warn("out of memory while starting {s}", .{path});
        return false;
    };
    defer {
        for (argv) |part| gpa.free(part);
        gpa.free(argv);
    }

    const pointers = gpa.allocSentinel(?[*:0]const u8, argv.len, null) catch {
        log.warn("out of memory while starting {s}", .{path});
        return false;
    };
    defer gpa.free(pointers);
    for (argv, 0..) |part, index| pointers[index] = part.ptr;

    var err: ?*c.GError = null;
    const started = c.g_spawn_async(
        null,
        pointers.ptr,
        null,
        c.spawn_search_path | c.spawn_stdout_to_dev_null | c.spawn_stderr_to_dev_null,
        detach,
        null,
        null,
        &err,
    ) != c.FALSE;

    if (!started) {
        defer if (err) |detail| c.g_error_free(detail);
        log.warn("cannot start {s}: {s}", .{ path, message(err) });
    }
    return started;
}

pub fn terminalArgv(
    gpa: Allocator,
    prefix: []const [:0]const u8,
    shell: []const u8,
    path: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (argv.items) |part| gpa.free(part);
        argv.deinit(gpa);
    }

    for (prefix) |part| try argv.append(gpa, try gpa.dupeZ(u8, part));
    try argv.append(gpa, try gpa.dupeZ(u8, shell));
    try argv.append(gpa, try gpa.dupeZ(u8, "-l"));
    try argv.append(gpa, try gpa.dupeZ(u8, "-c"));
    try argv.append(gpa, try gpa.dupeZ(u8, login_command));
    try argv.append(gpa, try gpa.dupeZ(u8, path));

    return argv.toOwnedSlice(gpa);
}

fn launchContext() ?*c.GdkAppLaunchContext {
    const display = c.gdk_display_get_default() orelse return null;
    return c.gdk_display_get_app_launch_context(display);
}

fn message(err: ?*c.GError) [*:0]const u8 {
    const detail = err orelse return "no detail";
    return detail.message orelse "no detail";
}

const detach: ?c.GSpawnChildSetupFunc = switch (builtin.os.tag) {
    .windows => null,
    else => &newSession,
};

// The app has to keep running once sysdeck quits, hence the child is put in a
// session of its own instead of staying in our process group.
extern fn setsid() c_int;

fn newSession(_: c.gpointer) callconv(.c) void {
    _ = setsid();
}

const testing = std.testing;

fn free(gpa: Allocator, argv: [][:0]u8) void {
    for (argv) |part| gpa.free(part);
    gpa.free(argv);
}

fn expectArgv(expected: []const []const u8, actual: []const [:0]u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqualStrings(want, got);
}

test "the terminal prefix comes before the login shell" {
    const gpa = testing.allocator;

    const argv = try terminalArgv(gpa, &.{ "ghostty", "-e" }, "/bin/bash", "/usr/bin/htop");
    defer free(gpa, argv);

    try expectArgv(
        &.{ "ghostty", "-e", "/bin/bash", "-l", "-c", login_command, "/usr/bin/htop" },
        argv,
    );
}

test "a terminal without a prefix flag runs the shell directly" {
    const gpa = testing.allocator;

    const argv = try terminalArgv(gpa, &.{"kitty"}, "/bin/sh", "/usr/bin/top");
    defer free(gpa, argv);

    try expectArgv(&.{ "kitty", "/bin/sh", "-l", "-c", login_command, "/usr/bin/top" }, argv);
}

test "a path is passed as an argument rather than spliced into the command" {
    const gpa = testing.allocator;

    const argv = try terminalArgv(gpa, &.{"foot"}, "/bin/sh", "/opt/my tools/a b");
    defer free(gpa, argv);

    try testing.expectEqualStrings(login_command, argv[argv.len - 2]);
    try testing.expectEqualStrings("/opt/my tools/a b", argv[argv.len - 1]);
}
