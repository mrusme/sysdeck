const std = @import("std");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.copy);

const program: [*:0]const u8 = "wl-copy";
const text_supertype: [*:0]const u8 = "text/plain";

pub const Content = struct {
    mime: []const u8,
    bytes: []const u8,
};

pub fn wayland(environ: *const std.process.Environ.Map) bool {
    const display = environ.get("WAYLAND_DISPLAY") orelse return false;
    return display.len > 0;
}

pub fn put(arena: Allocator, environ: *const std.process.Environ.Map, content: Content) bool {
    if (wayland(environ)) return spawn(arena, content);
    return handOver(arena, content);
}

fn spawn(arena: Allocator, content: Content) bool {
    const mime = arena.dupeZ(u8, content.mime) catch return false;
    var argv = [_:null]?[*:0]const u8{ program, "--type", mime.ptr };

    var writing: c_int = -1;
    var err: ?*c.GError = null;
    const started = glib.g_spawn_async_with_pipes(
        null,
        &argv,
        null,
        c.spawn_search_path | c.spawn_stdout_to_dev_null | c.spawn_stderr_to_dev_null,
        null,
        null,
        null,
        &writing,
        null,
        null,
        &err,
    ) != c.FALSE;

    if (!started) {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot start wl-copy: {s}", .{message(err)});
        return false;
    }

    defer _ = std.c.close(writing);
    return writeAll(writing, content.bytes);
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const wrote = std.c.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (wrote < 0) {
            if (std.c.errno(wrote) == .INTR) continue;
            log.warn("cannot hand {d} bytes to wl-copy", .{bytes.len});
            return false;
        }
        if (wrote == 0) return false;
        sent += @intCast(wrote);
    }
    return true;
}

fn handOver(arena: Allocator, content: Content) bool {
    const mime = arena.dupeZ(u8, content.mime) catch return false;
    if (gio.g_content_type_is_a(mime.ptr, text_supertype) == c.FALSE) {
        log.warn("{s} needs wl-copy, which wants a Wayland session", .{content.mime});
        return false;
    }

    const display = gdk.gdk_display_get_default() orelse return false;
    const board = gdk.gdk_display_get_clipboard(display);

    const text = arena.dupeZ(u8, content.bytes) catch return false;
    gdk.gdk_clipboard_set_text(board, text.ptr);
    gdk.gdk_clipboard_store_async(board, c.priority_default, null, null, null);
    return true;
}

fn message(err: ?*c.GError) []const u8 {
    const detail = err orelse return "unknown reason";
    return std.mem.span(detail.message orelse return "unknown reason");
}
