const std = @import("std");
const c = @import("c.zig");
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

pub fn refuse() u8 {
    if (c.gtk_init_check() == c.FALSE) {
        log.err("sysdeck does not run on Omarchy", .{});
        return unsupported_platform_exit_code;
    }

    const dialog = c.gtk_message_dialog_new(
        null,
        c.dialog_default_flags,
        .warning,
        .none,
        null,
    );
    const message = c.cast(c.GtkMessageDialog, dialog);
    c.gtk_message_dialog_format_secondary_markup(message, "%s", refusal.ptr);
    _ = c.gtk_dialog_add_button(c.cast(c.GtkDialog, dialog), button_label, c.response_ok);

    const window = c.cast(c.GtkWindow, dialog);
    c.gtk_window_set_title(window, dialog_title);

    const loop = c.g_main_loop_new(null, c.FALSE);
    defer c.g_main_loop_unref(loop);
    _ = c.connect(dialog, "response", &onResponse, loop);

    c.gtk_window_present(window);
    c.g_main_loop_run(loop);
    c.gtk_window_destroy(window);

    return unsupported_platform_exit_code;
}

fn onResponse(_: *c.GtkDialog, _: c_int, data: c.gpointer) callconv(.c) void {
    const loop: *c.GMainLoop = @ptrCast(data.?);
    c.g_main_loop_quit(loop);
}
