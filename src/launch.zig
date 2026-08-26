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
    defer release(gpa, argv);

    return spawn(gpa, argv, path);
}

pub fn uri(gpa: Allocator, environ: *const std.process.Environ.Map, url: []const u8) bool {
    const browser = environ.get("BROWSER") orelse "";
    if (browser.len > 0 and inBrowser(gpa, browser, url)) return true;

    return withHandler(gpa, url);
}

fn inBrowser(gpa: Allocator, browser: []const u8, url: []const u8) bool {
    var commands = std.mem.splitScalar(u8, browser, ':');
    while (commands.next()) |command| {
        const argv = browserArgv(gpa, command, url) catch {
            log.warn("out of memory while opening {s}", .{url});
            return false;
        };
        defer release(gpa, argv);

        if (argv.len == 0) continue;
        if (spawn(gpa, argv, url)) return true;
    }
    return false;
}

fn withHandler(gpa: Allocator, url: []const u8) bool {
    const text = gpa.dupeZ(u8, url) catch {
        log.warn("out of memory while opening {s}", .{url});
        return false;
    };
    defer gpa.free(text);

    const context = launchContext();
    defer if (context) |value| c.g_object_unref(value);

    var err: ?*c.GError = null;
    const opened = c.g_app_info_launch_default_for_uri(text.ptr, @ptrCast(context), &err) != c.FALSE;

    if (!opened) {
        defer if (err) |detail| c.g_error_free(detail);
        log.warn("cannot open {s}: {s}", .{ url, message(err) });
    }
    return opened;
}

pub fn browserArgv(
    gpa: Allocator,
    command: []const u8,
    url: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (argv.items) |part| gpa.free(part);
        argv.deinit(gpa);
    }

    var placed = false;
    var parts = std.mem.tokenizeAny(u8, command, " \t");
    while (parts.next()) |part| try argv.append(gpa, try expand(gpa, part, url, &placed));

    if (argv.items.len > 0 and !placed) try argv.append(gpa, try gpa.dupeZ(u8, url));

    return argv.toOwnedSlice(gpa);
}

fn expand(gpa: Allocator, part: []const u8, url: []const u8, placed: *bool) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var at: usize = 0;
    while (at < part.len) : (at += 1) {
        const next = if (at + 1 < part.len) part[at + 1] else 0;
        if (part[at] != '%' or (next != 's' and next != '%')) {
            try out.append(gpa, part[at]);
            continue;
        }

        if (next == 's') {
            try out.appendSlice(gpa, url);
            placed.* = true;
        } else {
            try out.append(gpa, '%');
        }
        at += 1;
    }

    return out.toOwnedSliceSentinel(gpa, 0);
}

fn spawn(gpa: Allocator, argv: []const [:0]u8, what: []const u8) bool {
    const pointers = gpa.allocSentinel(?[*:0]const u8, argv.len, null) catch {
        log.warn("out of memory while starting {s}", .{what});
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
        log.warn("cannot start {s}: {s}", .{ what, message(err) });
    }
    return started;
}

fn release(gpa: Allocator, argv: [][:0]u8) void {
    for (argv) |part| gpa.free(part);
    gpa.free(argv);
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

fn expectArgv(expected: []const []const u8, actual: []const [:0]u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqualStrings(want, got);
}

test "the terminal prefix comes before the login shell" {
    const gpa = testing.allocator;

    const argv = try terminalArgv(gpa, &.{ "ghostty", "-e" }, "/bin/bash", "/usr/bin/htop");
    defer release(gpa, argv);

    try expectArgv(
        &.{ "ghostty", "-e", "/bin/bash", "-l", "-c", login_command, "/usr/bin/htop" },
        argv,
    );
}

test "a terminal without a prefix flag runs the shell directly" {
    const gpa = testing.allocator;

    const argv = try terminalArgv(gpa, &.{"kitty"}, "/bin/sh", "/usr/bin/top");
    defer release(gpa, argv);

    try expectArgv(&.{ "kitty", "/bin/sh", "-l", "-c", login_command, "/usr/bin/top" }, argv);
}

test "a path is passed as an argument rather than spliced into the command" {
    const gpa = testing.allocator;

    const argv = try terminalArgv(gpa, &.{"foot"}, "/bin/sh", "/opt/my tools/a b");
    defer release(gpa, argv);

    try testing.expectEqualStrings(login_command, argv[argv.len - 2]);
    try testing.expectEqualStrings("/opt/my tools/a b", argv[argv.len - 1]);
}

fn expectBrowserArgv(command: []const u8, expected: []const []const u8) !void {
    const gpa = testing.allocator;

    const argv = try browserArgv(gpa, command, "https://ziglang.org");
    defer release(gpa, argv);

    try expectArgv(expected, argv);
}

test "a browser command without a placeholder gets the url appended" {
    try expectBrowserArgv("firefox", &.{ "firefox", "https://ziglang.org" });
    try expectBrowserArgv(
        "flatpak run org.mozilla.firefox",
        &.{ "flatpak", "run", "org.mozilla.firefox", "https://ziglang.org" },
    );
}

test "a placeholder is replaced rather than appended" {
    try expectBrowserArgv(
        "firefox --new-tab %s",
        &.{ "firefox", "--new-tab", "https://ziglang.org" },
    );
    try expectBrowserArgv("chromium --app=%s", &.{ "chromium", "--app=https://ziglang.org" });
}

test "a doubled percent is a percent and not a placeholder" {
    try expectBrowserArgv("open %%s", &.{ "open", "%s", "https://ziglang.org" });
}

test "an empty command produces no arguments" {
    try expectBrowserArgv("", &.{});
    try expectBrowserArgv("   ", &.{});
}
