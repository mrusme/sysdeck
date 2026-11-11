const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const osdetect = @import("osdetect");

const log = std.log.scoped(.sysdeck);

pub const unsupported_platform_exit_code: u8 = 71;

const dialog_title = "sysdeck";
const button_label = "fml";

const refusal: [:0]const u8 =
    "Hello and thank you for your interest in <i>sysdeck</i>!\n\n" ++
    "We regret to inform you that even a deliberately unserious project " ++
    "like <i>sysdeck</i> will flat-out refuse to run on a ridiculous " ++
    "clown setup like <i>Omarchy</i>. If you want to try <i>sysdeck</i>, " ++
    "please do yourself a favor and install a proper Linux distribution " ++
    "first.\n\n" ++
    "If, however, you insist on staying on <i>Omarchy</i>, you are highly " ++
    "unlikely to be the target audience for <i>sysdeck</i> in the first " ++
    "place.\n\n" ++
    "Thank you for your understanding.";

pub fn isRunningOn(init: std.process.Init) bool {
    if (init.environ_map.get("SYSDECK_FAKE_OMARCHY") != null) return true;

    var environment = osdetect.detectInit(init) catch return false;
    defer environment.deinit();
    return environment.isOmarchyLinux();
}

pub fn refuse(interactive: bool) u8 {
    if (!interactive or gtk.gtk_init_check() == c.FALSE) {
        log.err("sysdeck does not run on Omarchy", .{});
        return unsupported_platform_exit_code;
    }

    const dialog = gtk.gtk_message_dialog_new(
        null,
        c.dialog_default_flags,
        .warning,
        .none,
        null,
    );
    const message = c.cast(c.GtkMessageDialog, dialog);
    gtk.gtk_message_dialog_format_secondary_markup(message, "%s", refusal.ptr);
    _ = gtk.gtk_dialog_add_button(c.cast(c.GtkDialog, dialog), button_label, c.response_ok);

    const window = c.cast(c.GtkWindow, dialog);
    gtk.gtk_window_set_title(window, dialog_title);

    const loop = glib.g_main_loop_new(null, c.FALSE);
    defer glib.g_main_loop_unref(loop);
    _ = c.connect(dialog, "response", &onResponse, loop);
    _ = c.connect(dialog, "close-request", &onCloseRequested, loop);

    gtk.gtk_window_present(window);
    glib.g_main_loop_run(loop);
    gtk.gtk_window_destroy(window);

    return unsupported_platform_exit_code;
}

fn onResponse(_: *c.GtkDialog, _: c_int, data: c.gpointer) callconv(.c) void {
    const loop: *c.GMainLoop = @ptrCast(data.?);
    glib.g_main_loop_quit(loop);
}

fn onCloseRequested(_: *c.GtkWindow, data: c.gpointer) callconv(.c) c.gboolean {
    const loop: *c.GMainLoop = @ptrCast(data.?);
    glib.g_main_loop_quit(loop);
    return c.TRUE;
}
