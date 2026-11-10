const std = @import("std");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const terminal_mod = @import("terminal.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.launch);

const max_output = 1 << 20;

pub const login_command = "exec \"$0\"";
pub const ssh_command = "ssh -- \"$0\"";

const desktop_group = "Desktop Entry";
const exec_key = "Exec";

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
        log.warn("cannot start {s}: {s}", .{ nameOf(info), c.errorMessage(err) });
    }
    return started;
}

pub fn desktopWith(gpa: Allocator, info: *c.GDesktopAppInfo, arguments: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const scratch = arena.allocator();
    const words = wordsOf(scratch, arguments) orelse return false;

    const keys = keyFileOf(info) orelse {
        log.warn("cannot read the desktop entry of {s}, so it cannot take arguments", .{nameOf(info)});
        return false;
    };
    defer glib.g_key_file_free(keys);

    const exec = glib.g_key_file_get_string(keys, desktop_group, exec_key, null) orelse {
        log.warn("{s} has no Exec line, so it cannot take arguments", .{nameOf(info)});
        return false;
    };
    defer glib.g_free(exec);

    const wanted = execWith(scratch, std.mem.span(exec), words) catch {
        log.warn("out of memory while starting {s}", .{nameOf(info)});
        return false;
    };
    glib.g_key_file_set_string(keys, desktop_group, exec_key, wanted.ptr);

    const changed = gio.g_desktop_app_info_new_from_keyfile(keys) orelse {
        log.warn("cannot start {s} with \"{s}\"", .{ nameOf(info), arguments });
        return false;
    };
    defer glib.g_object_unref(changed);

    return desktop(changed);
}

pub fn keyFileOf(info: *c.GDesktopAppInfo) ?*c.GKeyFile {
    const path = gio.g_desktop_app_info_get_filename(info) orelse return null;

    const keys = glib.g_key_file_new();
    if (glib.g_key_file_load_from_file(keys, path, c.key_file_keep_translations, null) != c.FALSE) {
        return keys;
    }

    glib.g_key_file_free(keys);
    return null;
}

pub fn execWith(arena: Allocator, exec: []const u8, words: []const []const u8) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, exec);

    for (words) |word| {
        try out.appendSlice(arena, " \"");
        for (word) |byte| switch (byte) {
            '"', '`', '$', '\\' => try out.appendSlice(arena, &.{ '\\', byte }),
            '%' => try out.appendSlice(arena, "%%"),
            else => try out.append(arena, byte),
        };
        try out.append(arena, '"');
    }

    return out.toOwnedSliceSentinel(arena, 0);
}

pub fn loginCommandWith(arena: Allocator, arguments: []const u8) Allocator.Error![:0]u8 {
    return arena.printSentinel("{s} {s}", .{ login_command, arguments }, 0);
}

fn wordsOf(arena: Allocator, arguments: []const u8) ?[]const []const u8 {
    const text = arena.dupeSentinel(u8, arguments, 0) catch {
        log.warn("out of memory while reading the arguments \"{s}\"", .{arguments});
        return null;
    };

    var parsed: ?[*:null]?[*:0]u8 = null;
    var err: ?*c.GError = null;
    if (glib.g_shell_parse_argv(text.ptr, null, &parsed, &err) == c.FALSE) {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot read the arguments \"{s}\": {s}", .{ arguments, c.errorMessage(err) });
        return null;
    }
    defer glib.g_strfreev(parsed);

    var words: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (parsed.?[at]) |word| : (at += 1) {
        words.append(arena, arena.dupe(u8, std.mem.span(word)) catch return null) catch return null;
    }
    return words.items;
}

fn nameOf(info: *c.GDesktopAppInfo) [*:0]const u8 {
    return gio.g_app_info_get_display_name(c.cast(c.GAppInfo, info)) orelse "the chosen app";
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
    const wanted = arena.dupeSentinel(u8, path, 0) catch {
        log.warn("out of memory while opening {s}", .{path});
        return null;
    };

    var err: ?*c.GError = null;
    const made = glib.g_filename_to_uri(wanted.ptr, null, &err) orelse {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot open {s}: {s}", .{ path, c.errorMessage(err) });
        return null;
    };
    defer glib.g_free(made);

    return arena.dupeSentinel(u8, std.mem.span(made), 0) catch null;
}

fn handlerFor(arena: Allocator, mime: []const u8) ?[:0]u8 {
    if (mime.len == 0) return null;

    const wanted = arena.dupeSentinel(u8, mime, 0) catch return null;

    const info = gio.g_app_info_get_default_for_type(wanted.ptr, c.FALSE) orelse return null;
    defer glib.g_object_unref(info);

    const entry = c.cast(c.GDesktopAppInfo, info);
    if (gio.g_desktop_app_info_get_boolean(entry, "Terminal") == c.FALSE) return null;

    const command = gio.g_app_info_get_commandline(info) orelse return null;
    return arena.dupeSentinel(u8, std.mem.span(command), 0) catch null;
}

fn handlerArgv(
    arena: Allocator,
    prefix: []const [:0]const u8,
    command: []const u8,
    path: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;

    for (prefix) |part| try argv.append(arena, try arena.dupeSentinel(u8, part, 0));
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

    if (argv.items.len > 0 and !placed) try argv.append(arena, try arena.dupeSentinel(u8, path, 0));

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
    const text = arena.dupeSentinel(u8, url, 0) catch {
        log.warn("out of memory while opening {s}", .{url});
        return false;
    };

    const context = launchContext();
    defer if (context) |value| glib.g_object_unref(value);

    var err: ?*c.GError = null;
    const opened = gio.g_app_info_launch_default_for_uri(text.ptr, @ptrCast(context), &err) != c.FALSE;

    if (!opened) {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot open {s}: {s}", .{ url, c.errorMessage(err) });
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

    if (argv.items.len > 0 and !placed) try argv.append(arena, try arena.dupeSentinel(u8, url, 0));

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
        log.warn("cannot start {s}: {s}", .{ what, c.errorMessage(err) });
    }
    return started;
}

pub fn capture(
    gpa: Allocator,
    argv: []const []const u8,
    environ: ?[*:null]?[*:0]u8,
) Allocator.Error!?[]u8 {
    const parts = try gpa.allocSentinel(?[*:0]const u8, argv.len, null);
    defer {
        for (parts) |part| {
            if (part) |text| gpa.free(std.mem.span(text));
        }
        gpa.free(parts);
    }
    for (parts) |*part| part.* = null;
    for (argv, 0..) |part, at| parts[at] = (try gpa.dupeSentinel(u8, part, 0)).ptr;

    var out: ?[*:0]u8 = null;
    var status: c_int = 0;
    var err: ?*c.GError = null;

    const ran = glib.g_spawn_sync(
        null,
        parts.ptr,
        @ptrCast(environ),
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
        log.warn("cannot run {s}: {s}", .{ argv[0], c.errorMessage(err) });
        return null;
    }

    const text = out orelse return null;
    defer glib.g_free(text);

    if (status != 0) return null;

    const span = std.mem.span(text);
    if (span.len == 0 or span.len > max_output) return null;

    const valid = glib.g_utf8_make_valid(text, @intCast(span.len));
    defer glib.g_free(valid);

    return try gpa.dupe(u8, std.mem.span(valid));
}

pub fn terminalArgv(
    arena: Allocator,
    prefix: []const [:0]const u8,
    shell: []const u8,
    command: []const u8,
    argument: []const u8,
) Allocator.Error![][:0]u8 {
    var argv: std.ArrayList([:0]u8) = .empty;

    for (prefix) |part| try argv.append(arena, try arena.dupeSentinel(u8, part, 0));
    for ([_][]const u8{ shell, "-i", "-l", "-c", command, argument }) |part| {
        try argv.append(arena, try arena.dupeSentinel(u8, part, 0));
    }

    return argv.toOwnedSlice(arena);
}

fn launchContext() ?*c.GdkAppLaunchContext {
    const display = gdk.gdk_display_get_default() orelse return null;
    return gdk.gdk_display_get_app_launch_context(display);
}

const detach: ?c.GSpawnChildSetupFunc = &newSession;

fn newSession(_: c.gpointer) callconv(.c) void {
    _ = std.c.setsid();
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
    try testing.expect(std.mem.find(u8, ssh_command, " -- ") != null);
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

fn reparsed(arena: Allocator, exec: []const u8) ![]const []const u8 {
    var expanded: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < exec.len) : (at += 1) {
        if (exec[at] != '%' or at + 1 == exec.len) {
            try expanded.append(arena, exec[at]);
            continue;
        }
        at += 1;
        if (exec[at] == '%') try expanded.append(arena, '%');
    }
    return wordsOf(arena, try expanded.toOwnedSlice(arena)) orelse error.Unparsed;
}

test "each argument is appended in quotes after the field codes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const exec = try execWith(arena.allocator(), "firefox %u", &.{"--private-window"});
    try testing.expectEqualStrings("firefox %u \"--private-window\"", exec);
}

test "no arguments leave the exec line as it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("firefox %u", try execWith(arena.allocator(), "firefox %u", &.{}));
}

test "every argument reaches the app literally, the way gio expands and splits the exec line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const words = [_][]const u8{ "two words", "say \"hi\"", "$HOME", "`id`", "back\\slash", "100%", "%u", "'single'" };
    const exec = try execWith(arena.allocator(), "app %U", &words);

    const argv = try reparsed(arena.allocator(), exec);
    try testing.expectEqual(words.len + 1, argv.len);
    try testing.expectEqualStrings("app", argv[0]);
    for (words, argv[1..]) |want, got| try testing.expectEqualStrings(want, got);
}

test "the characters the desktop entry spec reserves inside quotes are escaped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const exec = try execWith(arena.allocator(), "app", &.{"$HOME `id` \\ \" 5%"});
    try testing.expectEqualStrings("app \"\\$HOME \\`id\\` \\\\ \\\" 5%%\"", exec);
}

test "a flatpak exec keeps its forwarded files apart from the arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const exec = try execWith(
        arena.allocator(),
        "/usr/bin/flatpak run --command=firefox --file-forwarding org.mozilla.firefox @@u %u @@",
        &.{"--private-window"},
    );
    try testing.expect(std.mem.endsWith(u8, exec, "@@u %u @@ \"--private-window\""));
}

test "a bin's arguments follow the program as typed, for the shell to read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const command = try loginCommandWith(arena.allocator(), "--color=auto ~/notes | less");
    try testing.expectEqualStrings("exec \"$0\" --color=auto ~/notes | less", command);
}

test "arguments with an open quote are not read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expect(wordsOf(arena.allocator(), "--title \"unclosed") == null);
}
