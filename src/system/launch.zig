const std = @import("std");
const builtin = @import("builtin");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const terminal_mod = @import("terminal.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.launch);

pub const login_command = "exec \"$0\"";
pub const ssh_command = "ssh -- \"$0\"";

pub fn desktop(info: *c.GDesktopAppInfo) bool {
    const context = launchContext();
    defer if (context) |value| glib.g_object_unref(value);

    var err: ?*c.GError = null;
    const started = gio.g_desktop_app_info_launch_uris_as_manager(
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
        defer if (err) |detail| glib.g_error_free(detail);
        const name = gio.g_app_info_get_display_name(c.cast(c.GAppInfo, info)) orelse
            "the chosen app";
        log.warn("cannot start {s}: {s}", .{ name, message(err) });
    }
    return started;
}

pub fn action(info: *c.GDesktopAppInfo, name: [*:0]const u8) void {
    const context = launchContext();
    defer if (context) |value| glib.g_object_unref(value);

    gio.g_desktop_app_info_launch_action(info, name, @ptrCast(context));
}

pub fn inTerminal(
    gpa: Allocator,
    terminal: terminal_mod.Terminal,
    shell: []const u8,
    command: []const u8,
    argument: []const u8,
) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const scratch = arena.allocator();
    const argv = terminalArgv(scratch, terminal.argv, shell, command, argument) catch {
        log.warn("out of memory while starting {s}", .{argument});
        return false;
    };

    return spawn(scratch, argv, argument);
}

pub fn uri(gpa: Allocator, environ: *const std.process.Environ.Map, url: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const scratch = arena.allocator();
    const browser = environ.get("BROWSER") orelse "";
    if (browser.len > 0 and inBrowser(scratch, browser, url)) return true;

    return withHandler(scratch, url);
}

pub fn file(
    gpa: Allocator,
    terminal: ?terminal_mod.Terminal,
    path: []const u8,
    mime: []const u8,
) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const scratch = arena.allocator();
    const command = handlerFor(scratch, mime) orelse {
        const url = uriOf(scratch, path) orelse return false;
        return withHandler(scratch, url);
    };

    const found = terminal orelse {
        log.warn(
            "{s} opens with \"{s}\", which needs a terminal, and no terminal is installed",
            .{ path, command },
        );
        return false;
    };

    const argv = handlerArgv(scratch, found.argv, command, path) catch {
        log.warn("out of memory while opening {s}", .{path});
        return false;
    };

    return spawn(scratch, argv, path);
}

fn uriOf(arena: Allocator, path: []const u8) ?[:0]u8 {
    const wanted = arena.dupeZ(u8, path) catch {
        log.warn("out of memory while opening {s}", .{path});
        return null;
    };

    var err: ?*c.GError = null;
    const made = glib.g_filename_to_uri(wanted.ptr, null, &err) orelse {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot open {s}: {s}", .{ path, message(err) });
        return null;
    };
    defer glib.g_free(made);

    return arena.dupeZ(u8, std.mem.span(made)) catch null;
}

fn handlerFor(arena: Allocator, mime: []const u8) ?[:0]u8 {
    if (mime.len == 0) return null;

    const wanted = arena.dupeZ(u8, mime) catch return null;

    const info = gio.g_app_info_get_default_for_type(wanted.ptr, c.FALSE) orelse return null;
    defer glib.g_object_unref(info);

    const entry = c.cast(c.GDesktopAppInfo, info);
    if (gio.g_desktop_app_info_get_boolean(entry, "Terminal") == c.FALSE) return null;

    const command = gio.g_app_info_get_commandline(info) orelse return null;
    return arena.dupeZ(u8, std.mem.span(command)) catch null;
}

fn handlerArgv(
    arena: Allocator,
    prefix: []const [:0]const u8,
    command: []const u8,
    path: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;

    for (prefix) |part| try argv.append(arena, try arena.dupeZ(u8, part));
    try argv.appendSlice(arena, try desktopArgv(arena, command, path));

    return argv.toOwnedSlice(arena);
}

pub fn desktopArgv(
    arena: Allocator,
    command: []const u8,
    path: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;
    var token: std.ArrayList(u8) = .empty;

    var quoted = false;
    var open = false;
    var placed = false;
    var at: usize = 0;

    while (at < command.len) : (at += 1) {
        const byte = command[at];

        if (byte == '"') {
            quoted = !quoted;
            open = true;
            continue;
        }

        if (quoted and byte == '\\' and at + 1 < command.len) {
            at += 1;
            try token.append(arena, command[at]);
            continue;
        }

        if (!quoted and (byte == ' ' or byte == '\t')) {
            if (token.items.len > 0 or open) {
                try argv.append(arena, try token.toOwnedSliceSentinel(arena, 0));
            }
            open = false;
            continue;
        }

        if (byte == '%' and at + 1 < command.len) {
            at += 1;
            switch (command[at]) {
                '%' => try token.append(arena, '%'),
                'f', 'F', 'u', 'U' => {
                    try token.appendSlice(arena, path);
                    placed = true;
                },
                else => {},
            }
            continue;
        }

        try token.append(arena, byte);
    }

    if (token.items.len > 0 or open) {
        try argv.append(arena, try token.toOwnedSliceSentinel(arena, 0));
    }

    if (argv.items.len > 0 and !placed) try argv.append(arena, try arena.dupeZ(u8, path));

    return argv.toOwnedSlice(arena);
}

fn inBrowser(arena: Allocator, browser: []const u8, url: []const u8) bool {
    var commands = std.mem.splitScalar(u8, browser, ':');
    while (commands.next()) |command| {
        const argv = browserArgv(arena, command, url) catch {
            log.warn("out of memory while opening {s}", .{url});
            return false;
        };

        if (argv.len == 0) continue;
        if (spawn(arena, argv, url)) return true;
    }
    return false;
}

fn withHandler(arena: Allocator, url: []const u8) bool {
    const text = arena.dupeZ(u8, url) catch {
        log.warn("out of memory while opening {s}", .{url});
        return false;
    };

    const context = launchContext();
    defer if (context) |value| glib.g_object_unref(value);

    var err: ?*c.GError = null;
    const opened = gio.g_app_info_launch_default_for_uri(text.ptr, @ptrCast(context), &err) != c.FALSE;

    if (!opened) {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot open {s}: {s}", .{ url, message(err) });
    }
    return opened;
}

pub fn browserArgv(
    arena: Allocator,
    command: []const u8,
    url: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;

    var placed = false;
    var parts = std.mem.tokenizeAny(u8, command, " \t");
    while (parts.next()) |part| try argv.append(arena, try expand(arena, part, url, &placed));

    if (argv.items.len > 0 and !placed) try argv.append(arena, try arena.dupeZ(u8, url));

    return argv.toOwnedSlice(arena);
}

fn expand(arena: Allocator, part: []const u8, url: []const u8, placed: *bool) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;

    var at: usize = 0;
    while (at < part.len) : (at += 1) {
        const next = if (at + 1 < part.len) part[at + 1] else 0;
        if (part[at] != '%' or (next != 's' and next != '%')) {
            try out.append(arena, part[at]);
            continue;
        }

        if (next == 's') {
            try out.appendSlice(arena, url);
            placed.* = true;
        } else {
            try out.append(arena, '%');
        }
        at += 1;
    }

    return out.toOwnedSliceSentinel(arena, 0);
}

fn spawn(arena: Allocator, argv: []const [:0]u8, what: []const u8) bool {
    const pointers = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch {
        log.warn("out of memory while starting {s}", .{what});
        return false;
    };
    for (argv, 0..) |part, index| pointers[index] = part.ptr;

    var err: ?*c.GError = null;
    const started = glib.g_spawn_async(
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
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot start {s}: {s}", .{ what, message(err) });
    }
    return started;
}

pub fn terminalArgv(
    arena: Allocator,
    prefix: []const [:0]const u8,
    shell: []const u8,
    command: []const u8,
    argument: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;

    for (prefix) |part| try argv.append(arena, try arena.dupeZ(u8, part));
    for ([_][]const u8{ shell, "-i", "-l", "-c", command, argument }) |part| {
        try argv.append(arena, try arena.dupeZ(u8, part));
    }

    return argv.toOwnedSlice(arena);
}

fn launchContext() ?*c.GdkAppLaunchContext {
    const display = gdk.gdk_display_get_default() orelse return null;
    return gdk.gdk_display_get_app_launch_context(display);
}

fn message(err: ?*c.GError) [*:0]const u8 {
    const detail = err orelse return "no detail";
    return detail.message orelse "no detail";
}

const detach: ?c.GSpawnChildSetupFunc = switch (builtin.os.tag) {
    .windows => null,
    else => &newSession,
};

extern fn setsid() c_int;

fn newSession(_: c.gpointer) callconv(.c) void {
    _ = setsid();
}

const testing = std.testing;

fn expectArgv(expected: []const []const u8, actual: []const [:0]u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqualStrings(want, got);
}

test "the terminal prefix comes before the interactive login shell" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const prefix = [_][:0]const u8{ "ghostty", "-e" };
    const argv = try terminalArgv(arena.allocator(), &prefix, "/bin/bash", login_command, "/usr/bin/htop");

    try expectArgv(
        &.{ "ghostty", "-e", "/bin/bash", "-i", "-l", "-c", login_command, "/usr/bin/htop" },
        argv,
    );
}

test "a terminal without a prefix flag runs the shell directly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const argv = try terminalArgv(arena.allocator(), &.{"kitty"}, "/bin/sh", login_command, "/usr/bin/top");

    try expectArgv(&.{ "kitty", "/bin/sh", "-i", "-l", "-c", login_command, "/usr/bin/top" }, argv);
}

test "a path is passed as an argument rather than spliced into the command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const argv = try terminalArgv(arena.allocator(), &.{"foot"}, "/bin/sh", login_command, "/opt/my tools/a b");

    try testing.expectEqualStrings(login_command, argv[argv.len - 2]);
    try testing.expectEqualStrings("/opt/my tools/a b", argv[argv.len - 1]);
}

test "a host is passed to ssh as an argument rather than spliced into the command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const prefix = [_][:0]const u8{ "ghostty", "-e" };
    const argv = try terminalArgv(arena.allocator(), &prefix, "/usr/bin/zsh", ssh_command, "my host");

    try expectArgv(
        &.{ "ghostty", "-e", "/usr/bin/zsh", "-i", "-l", "-c", "ssh -- \"$0\"", "my host" },
        argv,
    );
}

test "a host that looks like an option is still a host" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const argv = try terminalArgv(arena.allocator(), &.{"foot"}, "/bin/sh", ssh_command, "-oProxyCommand=id");

    try testing.expectEqualStrings(ssh_command, argv[argv.len - 2]);
    try testing.expectEqualStrings("-oProxyCommand=id", argv[argv.len - 1]);
    try testing.expect(std.mem.indexOf(u8, ssh_command, " -- ") != null);
}

fn expectBrowserArgv(command: []const u8, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const argv = try browserArgv(arena.allocator(), command, "https://ziglang.org");

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

const test_path = "/home/tester/notes.txt";

fn expectDesktopArgv(command: []const u8, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const argv = try desktopArgv(arena.allocator(), command, test_path);

    try expectArgv(expected, argv);
}

test "every code that names the file is the path, the way gio passes it" {
    try expectDesktopArgv("nvim %F", &.{ "nvim", test_path });
    try expectDesktopArgv("/usr/bin/hx %f", &.{ "/usr/bin/hx", test_path });
    try expectDesktopArgv("gedit %U", &.{ "gedit", test_path });
    try expectDesktopArgv("gedit %u", &.{ "gedit", test_path });
}

test "a command without a code still gets the file" {
    try expectDesktopArgv("nvim", &.{ "nvim", test_path });
    try expectDesktopArgv("ranger --cmd", &.{ "ranger", "--cmd", test_path });
    try expectDesktopArgv("", &.{});
}

test "the codes that name the entry rather than the file are dropped" {
    try expectDesktopArgv("app %i %c %k %f", &.{ "app", test_path });
    try expectDesktopArgv("app %i", &.{ "app", test_path });
    try expectDesktopArgv("app --name=%c %f", &.{ "app", "--name=", test_path });
}

test "a doubled percent is a percent and not a code" {
    try expectDesktopArgv("app %%f", &.{ "app", "%f", test_path });
}

test "a quoted argument stays one argument" {
    try expectDesktopArgv(
        "\"/opt/my editor/bin/edit\" --wait %f",
        &.{ "/opt/my editor/bin/edit", "--wait", test_path },
    );
    try expectDesktopArgv("app \"\" %f", &.{ "app", "", test_path });
    try expectDesktopArgv("app \"a \\\"b\\\" c\" %f", &.{ "app", "a \"b\" c", test_path });
}

test "a code inside a quoted argument is expanded where it stands" {
    try expectDesktopArgv("app \"--file=%f\"", &.{ "app", "--file=" ++ test_path });
}

test "the terminal comes before the command it runs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const argv = try handlerArgv(arena.allocator(), &.{ "ghostty", "-e" }, "nvim %F", test_path);

    try expectArgv(&.{ "ghostty", "-e", "nvim", test_path }, argv);
}

fn builtArgv(gpa: Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const scratch = arena.allocator();
    _ = try terminalArgv(scratch, &.{ "ghostty", "-e" }, "/bin/sh", login_command, test_path);
    _ = try browserArgv(scratch, "firefox --new-tab %s", "https://ziglang.org");
    _ = try desktopArgv(scratch, "\"/opt/my editor\" --wait %f", test_path);
    _ = try handlerArgv(scratch, &.{"foot"}, "nvim %F", test_path);
}

test "an argv that runs out of memory leaves nothing behind" {
    try testing.checkAllAllocationFailures(testing.allocator, builtArgv, .{});
}
