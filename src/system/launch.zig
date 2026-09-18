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
    const argv = terminalArgv(gpa, terminal.argv, shell, command, argument) catch {
        log.warn("out of memory while starting {s}", .{argument});
        return false;
    };
    defer release(gpa, argv);

    return spawn(gpa, argv, argument);
}

pub fn uri(gpa: Allocator, environ: *const std.process.Environ.Map, url: []const u8) bool {
    const browser = environ.get("BROWSER") orelse "";
    if (browser.len > 0 and inBrowser(gpa, browser, url)) return true;

    return withHandler(gpa, url);
}

pub fn file(
    gpa: Allocator,
    terminal: ?terminal_mod.Terminal,
    path: []const u8,
    mime: []const u8,
) bool {
    const command = handlerFor(gpa, mime) orelse {
        const url = uriOf(gpa, path) orelse return false;
        defer gpa.free(url);
        return withHandler(gpa, url);
    };
    defer gpa.free(command);

    const found = terminal orelse {
        log.warn(
            "{s} opens with \"{s}\", which needs a terminal, and no terminal is installed",
            .{ path, command },
        );
        return false;
    };

    const argv = handlerArgv(gpa, found.argv, command, path) catch {
        log.warn("out of memory while opening {s}", .{path});
        return false;
    };
    defer release(gpa, argv);

    return spawn(gpa, argv, path);
}

fn uriOf(gpa: Allocator, path: []const u8) ?[:0]u8 {
    const wanted = gpa.dupeZ(u8, path) catch {
        log.warn("out of memory while opening {s}", .{path});
        return null;
    };
    defer gpa.free(wanted);

    var err: ?*c.GError = null;
    const made = glib.g_filename_to_uri(wanted.ptr, null, &err) orelse {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot open {s}: {s}", .{ path, message(err) });
        return null;
    };
    defer glib.g_free(made);

    return gpa.dupeZ(u8, std.mem.span(made)) catch null;
}

fn handlerFor(gpa: Allocator, mime: []const u8) ?[:0]u8 {
    if (mime.len == 0) return null;

    const wanted = gpa.dupeZ(u8, mime) catch return null;
    defer gpa.free(wanted);

    const info = gio.g_app_info_get_default_for_type(wanted.ptr, c.FALSE) orelse return null;
    defer glib.g_object_unref(info);

    const entry = c.cast(c.GDesktopAppInfo, info);
    if (gio.g_desktop_app_info_get_boolean(entry, "Terminal") == c.FALSE) return null;

    const command = gio.g_app_info_get_commandline(info) orelse return null;
    return gpa.dupeZ(u8, std.mem.span(command)) catch null;
}

fn handlerArgv(
    gpa: Allocator,
    prefix: []const [:0]const u8,
    command: []const u8,
    path: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (argv.items) |part| gpa.free(part);
        argv.deinit(gpa);
    }

    for (prefix) |part| try argv.append(gpa, try gpa.dupeZ(u8, part));

    const parts = try desktopArgv(gpa, command, path);
    defer gpa.free(parts);
    try argv.appendSlice(gpa, parts);

    return argv.toOwnedSlice(gpa);
}

pub fn desktopArgv(
    gpa: Allocator,
    command: []const u8,
    path: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (argv.items) |part| gpa.free(part);
        argv.deinit(gpa);
    }

    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(gpa);

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
            try token.append(gpa, command[at]);
            continue;
        }

        if (!quoted and (byte == ' ' or byte == '\t')) {
            if (token.items.len > 0 or open) {
                try argv.append(gpa, try token.toOwnedSliceSentinel(gpa, 0));
            }
            open = false;
            continue;
        }

        if (byte == '%' and at + 1 < command.len) {
            at += 1;
            switch (command[at]) {
                '%' => try token.append(gpa, '%'),
                'f', 'F', 'u', 'U' => {
                    try token.appendSlice(gpa, path);
                    placed = true;
                },
                else => {},
            }
            continue;
        }

        try token.append(gpa, byte);
    }

    if (token.items.len > 0 or open) {
        try argv.append(gpa, try token.toOwnedSliceSentinel(gpa, 0));
    }

    if (argv.items.len > 0 and !placed) try argv.append(gpa, try gpa.dupeZ(u8, path));

    return argv.toOwnedSlice(gpa);
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

fn release(gpa: Allocator, argv: [][:0]u8) void {
    for (argv) |part| gpa.free(part);
    gpa.free(argv);
}

pub fn terminalArgv(
    gpa: Allocator,
    prefix: []const [:0]const u8,
    shell: []const u8,
    command: []const u8,
    argument: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (argv.items) |part| gpa.free(part);
        argv.deinit(gpa);
    }

    for (prefix) |part| try argv.append(gpa, try gpa.dupeZ(u8, part));
    try argv.append(gpa, try gpa.dupeZ(u8, shell));
    try argv.append(gpa, try gpa.dupeZ(u8, "-i"));
    try argv.append(gpa, try gpa.dupeZ(u8, "-l"));
    try argv.append(gpa, try gpa.dupeZ(u8, "-c"));
    try argv.append(gpa, try gpa.dupeZ(u8, command));
    try argv.append(gpa, try gpa.dupeZ(u8, argument));

    return argv.toOwnedSlice(gpa);
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
    const gpa = testing.allocator;

    const prefix = [_][:0]const u8{ "ghostty", "-e" };
    const argv = try terminalArgv(gpa, &prefix, "/bin/bash", login_command, "/usr/bin/htop");
    defer release(gpa, argv);

    try expectArgv(
        &.{ "ghostty", "-e", "/bin/bash", "-i", "-l", "-c", login_command, "/usr/bin/htop" },
        argv,
    );
}

test "a terminal without a prefix flag runs the shell directly" {
    const gpa = testing.allocator;

    const argv = try terminalArgv(gpa, &.{"kitty"}, "/bin/sh", login_command, "/usr/bin/top");
    defer release(gpa, argv);

    try expectArgv(&.{ "kitty", "/bin/sh", "-i", "-l", "-c", login_command, "/usr/bin/top" }, argv);
}

test "a path is passed as an argument rather than spliced into the command" {
    const gpa = testing.allocator;

    const argv = try terminalArgv(gpa, &.{"foot"}, "/bin/sh", login_command, "/opt/my tools/a b");
    defer release(gpa, argv);

    try testing.expectEqualStrings(login_command, argv[argv.len - 2]);
    try testing.expectEqualStrings("/opt/my tools/a b", argv[argv.len - 1]);
}

test "a host is passed to ssh as an argument rather than spliced into the command" {
    const gpa = testing.allocator;

    const prefix = [_][:0]const u8{ "ghostty", "-e" };
    const argv = try terminalArgv(gpa, &prefix, "/usr/bin/zsh", ssh_command, "my host");
    defer release(gpa, argv);

    try expectArgv(
        &.{ "ghostty", "-e", "/usr/bin/zsh", "-i", "-l", "-c", "ssh -- \"$0\"", "my host" },
        argv,
    );
}

test "a host that looks like an option is still a host" {
    const gpa = testing.allocator;

    const argv = try terminalArgv(gpa, &.{"foot"}, "/bin/sh", ssh_command, "-oProxyCommand=id");
    defer release(gpa, argv);

    try testing.expectEqualStrings(ssh_command, argv[argv.len - 2]);
    try testing.expectEqualStrings("-oProxyCommand=id", argv[argv.len - 1]);
    try testing.expect(std.mem.indexOf(u8, ssh_command, " -- ") != null);
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

const test_path = "/home/tester/notes.txt";

fn expectDesktopArgv(command: []const u8, expected: []const []const u8) !void {
    const gpa = testing.allocator;

    const argv = try desktopArgv(gpa, command, test_path);
    defer release(gpa, argv);

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
    const gpa = testing.allocator;

    const argv = try handlerArgv(gpa, &.{ "ghostty", "-e" }, "nvim %F", test_path);
    defer release(gpa, argv);

    try expectArgv(&.{ "ghostty", "-e", "nvim", test_path }, argv);
}
