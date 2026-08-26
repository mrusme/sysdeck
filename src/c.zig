const std = @import("std");

pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;
pub const gulong = c_ulong;
pub const guint = c_uint;
pub const gdouble = f64;

pub const TRUE: gboolean = 1;
pub const FALSE: gboolean = 0;

pub const GParamSpec = opaque {};
pub const GApplication = opaque {};

pub const GList = extern struct {
    data: gpointer,
    next: ?*GList,
    prev: ?*GList,
};

pub extern fn g_list_free_full(list: ?*GList, free_func: GDestroyNotify) void;

pub const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]u8,
};

pub extern fn g_error_free(err: *GError) void;

pub const GKeyFile = opaque {};
pub const GKeyFileFlags = guint;

pub const key_file_none: GKeyFileFlags = 0;

pub extern fn g_key_file_new() *GKeyFile;
pub extern fn g_key_file_free(key_file: *GKeyFile) void;
pub extern fn g_key_file_load_from_file(
    key_file: *GKeyFile,
    file: [*:0]const u8,
    flags: GKeyFileFlags,
    err: ?*?*GError,
) gboolean;
pub extern fn g_key_file_load_from_data(
    key_file: *GKeyFile,
    data: [*]const u8,
    length: usize,
    flags: GKeyFileFlags,
    err: ?*?*GError,
) gboolean;
pub extern fn g_key_file_get_string(
    key_file: *GKeyFile,
    group_name: [*:0]const u8,
    key: [*:0]const u8,
    err: ?*?*GError,
) ?[*:0]u8;

pub const GAsyncResult = opaque {};
pub const GCancellable = opaque {};

pub const GCallback = *const fn () callconv(.c) void;
pub const GAsyncReadyCallback = *const fn (
    source: gpointer,
    result: *GAsyncResult,
    data: gpointer,
) callconv(.c) void;
pub const GClosureNotify = *const fn (data: gpointer, closure: gpointer) callconv(.c) void;
pub const GDestroyNotify = *const fn (data: gpointer) callconv(.c) void;
pub const GSourceFunc = *const fn (data: gpointer) callconv(.c) gboolean;

pub const GConnectFlags = guint;
pub const connect_default: GConnectFlags = 0;

pub extern fn g_get_user_name() [*:0]const u8;

pub extern fn g_find_program_in_path(program: [*:0]const u8) ?[*:0]u8;

pub fn installed(gpa: std.mem.Allocator, program: []const u8) bool {
    const name = gpa.dupeZ(u8, program) catch return false;
    defer gpa.free(name);

    const found = g_find_program_in_path(name.ptr) orelse return false;
    g_free(found);
    return true;
}

pub extern fn g_object_set_data(object: gpointer, key: [*:0]const u8, data: gpointer) void;
pub extern fn g_object_get_data(object: gpointer, key: [*:0]const u8) gpointer;
pub extern fn g_object_ref(object: gpointer) gpointer;
pub extern fn g_object_unref(object: gpointer) void;
pub extern fn g_free(mem: gpointer) void;
pub extern fn g_set_prgname(name: [*:0]const u8) void;

pub extern fn g_signal_connect_data(
    instance: gpointer,
    detailed_signal: [*:0]const u8,
    c_handler: GCallback,
    data: gpointer,
    destroy_data: ?GClosureNotify,
    connect_flags: GConnectFlags,
) gulong;

pub inline fn connect(
    instance: anytype,
    signal: [*:0]const u8,
    handler: anytype,
    data: gpointer,
) gulong {
    comptime checkHandler(@TypeOf(handler));
    return g_signal_connect_data(@ptrCast(instance), signal, @ptrCast(handler), data, null, connect_default);
}

fn checkHandler(comptime T: type) void {
    const message = "a signal handler is a pointer to a callconv(.c) function, not " ++ @typeName(T);
    const pointer = switch (@typeInfo(T)) {
        .pointer => |info| info,
        else => @compileError(message),
    };
    const function = switch (@typeInfo(pointer.child)) {
        .@"fn" => |info| info,
        else => @compileError(message),
    };
    switch (function.calling_convention) {
        .auto, .@"inline" => @compileError(message),
        else => {},
    }
}

pub inline fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(ptr);
}

pub const GApplicationFlags = guint;
pub const application_non_unique: GApplicationFlags = 1 << 5;

pub extern fn g_application_run(application: *GApplication, argc: c_int, argv: ?[*][*:0]u8) c_int;
pub extern fn g_application_quit(application: *GApplication) void;

pub const GMainContext = opaque {};

pub const source_remove: gboolean = FALSE;

pub extern fn g_idle_add(function: GSourceFunc, data: gpointer) guint;
pub extern fn g_timeout_add(interval: guint, function: GSourceFunc, data: gpointer) guint;
pub extern fn g_source_remove(tag: guint) gboolean;
pub extern fn g_main_context_default() *GMainContext;
pub extern fn g_main_context_iteration(context: ?*GMainContext, may_block: gboolean) gboolean;

pub const GMainLoop = opaque {};

pub extern fn g_main_loop_new(context: ?*GMainContext, is_running: gboolean) *GMainLoop;
pub extern fn g_main_loop_run(loop: *GMainLoop) void;
pub extern fn g_main_loop_quit(loop: *GMainLoop) void;
pub extern fn g_main_loop_unref(loop: *GMainLoop) void;

pub const GPid = c_int;
pub const GSpawnFlags = guint;

pub const spawn_search_path: GSpawnFlags = 1 << 2;
pub const spawn_stdout_to_dev_null: GSpawnFlags = 1 << 3;
pub const spawn_stderr_to_dev_null: GSpawnFlags = 1 << 4;

pub const GSpawnChildSetupFunc = *const fn (data: gpointer) callconv(.c) void;

pub extern fn g_spawn_sync(
    working_directory: ?[*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*:null]const ?[*:0]const u8,
    flags: GSpawnFlags,
    child_setup: ?GSpawnChildSetupFunc,
    user_data: gpointer,
    standard_output: ?*?[*:0]u8,
    standard_error: ?*?[*:0]u8,
    exit_status: ?*c_int,
    err: *?*GError,
) gboolean;

pub extern fn g_get_environ() [*:null]?[*:0]u8;
pub extern fn g_environ_setenv(
    envp: ?[*:null]?[*:0]u8,
    variable: [*:0]const u8,
    value: [*:0]const u8,
    overwrite: gboolean,
) [*:null]?[*:0]u8;
pub extern fn g_strfreev(str_array: ?[*:null]?[*:0]u8) void;
pub extern fn g_utf8_make_valid(str: [*:0]const u8, len: isize) [*:0]u8;

pub extern fn g_spawn_async(
    working_directory: ?[*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*:null]const ?[*:0]const u8,
    flags: GSpawnFlags,
    child_setup: ?GSpawnChildSetupFunc,
    user_data: gpointer,
    child_pid: ?*GPid,
    err: *?*GError,
) gboolean;

pub const GAppInfo = opaque {};
pub const GDesktopAppInfo = opaque {};
pub const GAppLaunchContext = opaque {};
pub const GIcon = opaque {};

pub const GDesktopAppLaunchCallback = *const fn (
    appinfo: *GDesktopAppInfo,
    pid: GPid,
    data: gpointer,
) callconv(.c) void;

pub extern fn g_app_info_get_all() ?*GList;
pub extern fn g_app_info_get_id(appinfo: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_display_name(appinfo: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_name(appinfo: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_description(appinfo: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_executable(appinfo: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_icon(appinfo: *GAppInfo) ?*GIcon;
pub extern fn g_app_info_should_show(appinfo: *GAppInfo) gboolean;
pub extern fn g_app_info_launch_default_for_uri(
    uri: [*:0]const u8,
    launch_context: ?*GAppLaunchContext,
    err: *?*GError,
) gboolean;

pub extern fn g_icon_to_string(icon: *GIcon) ?[*:0]u8;
pub extern fn g_icon_new_for_string(str: [*:0]const u8, err: ?*?*GError) ?*GIcon;

pub extern fn g_desktop_app_info_new(desktop_id: [*:0]const u8) ?*GDesktopAppInfo;
pub extern fn g_desktop_app_info_get_generic_name(info: *GDesktopAppInfo) ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_keywords(info: *GDesktopAppInfo) ?[*:null]const ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_filename(info: *GDesktopAppInfo) ?[*:0]const u8;
pub extern fn g_desktop_app_info_list_actions(info: *GDesktopAppInfo) [*:null]const ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_action_name(
    info: *GDesktopAppInfo,
    action_name: [*:0]const u8,
) ?[*:0]u8;
pub extern fn g_desktop_app_info_launch_action(
    info: *GDesktopAppInfo,
    action_name: [*:0]const u8,
    launch_context: ?*GAppLaunchContext,
) void;
pub extern fn g_desktop_app_info_launch_uris_as_manager(
    appinfo: *GDesktopAppInfo,
    uris: ?*GList,
    launch_context: ?*GAppLaunchContext,
    spawn_flags: GSpawnFlags,
    user_setup: ?GSpawnChildSetupFunc,
    user_setup_data: gpointer,
    pid_callback: ?GDesktopAppLaunchCallback,
    pid_callback_data: gpointer,
    err: *?*GError,
) gboolean;

pub const GdkDisplay = opaque {};
pub const GdkAppLaunchContext = opaque {};
pub const GdkClipboard = opaque {};
pub const GdkModifierType = guint;

pub const priority_default: c_int = 0;

pub const modifier_shift: GdkModifierType = 1 << 0;
pub const modifier_control: GdkModifierType = 1 << 2;
pub const modifier_alt: GdkModifierType = 1 << 3;
pub const modifier_super: GdkModifierType = 1 << 26;
pub const modifier_mask: GdkModifierType =
    modifier_shift | modifier_control | modifier_alt | modifier_super;

pub extern fn gdk_display_get_default() ?*GdkDisplay;
pub extern fn gdk_keyval_from_name(name: [*:0]const u8) guint;
pub extern fn gdk_display_get_app_launch_context(display: *GdkDisplay) *GdkAppLaunchContext;
pub extern fn gdk_clipboard_set_text(clipboard: *GdkClipboard, text: [*:0]const u8) void;
pub extern fn gdk_clipboard_store_async(
    clipboard: *GdkClipboard,
    io_priority: c_int,
    cancellable: ?*GCancellable,
    callback: ?GAsyncReadyCallback,
    data: gpointer,
) void;
pub extern fn gdk_clipboard_store_finish(
    clipboard: *GdkClipboard,
    result: *GAsyncResult,
    err: *?*GError,
) gboolean;

pub const graphene_rect_t = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const key_f: guint = 0x0066;
pub const key_t: guint = 0x0074;
pub const key_Page_Up: guint = 0xff55;
pub const key_Page_Down: guint = 0xff56;
pub const key_KP_Page_Up: guint = 0xff9a;
pub const key_KP_Page_Down: guint = 0xff9b;
pub const key_0: guint = 0x0030;
pub const key_9: guint = 0x0039;
pub const key_KP_0: guint = 0xffb0;
pub const key_KP_9: guint = 0xffb9;
pub const key_F1: guint = 0xffbe;
pub const key_F12: guint = 0xffc9;
pub const key_Escape: guint = 0xff1b;
pub const key_Shift_L: guint = 0xffe1;
pub const key_Shift_R: guint = 0xffe2;
pub const key_Control_L: guint = 0xffe3;
pub const key_Control_R: guint = 0xffe4;
pub const key_Alt_L: guint = 0xffe9;
pub const key_Alt_R: guint = 0xffea;
pub const key_Super_L: guint = 0xffeb;
pub const key_Super_R: guint = 0xffec;
pub const key_void: guint = 0xffffff;
pub const key_Return: guint = 0xff0d;
pub const key_KP_Enter: guint = 0xff8d;
pub const key_ISO_Enter: guint = 0xfe34;
pub const key_Up: guint = 0xff52;
pub const key_Down: guint = 0xff54;
pub const key_KP_Up: guint = 0xff97;
pub const key_KP_Down: guint = 0xff99;

pub const PangoEllipsizeMode = enum(guint) {
    none = 0,
    start = 1,
    middle = 2,
    end = 3,
};

pub const GtkAlign = enum(guint) {
    fill = 0,
    start = 1,
    end = 2,
    center = 3,
    baseline_fill = 4,
};

pub const GtkOrientation = enum(guint) {
    horizontal = 0,
    vertical = 1,
};

pub const GtkSelectionMode = enum(guint) {
    none = 0,
    single = 1,
    browse = 2,
    multiple = 3,
};

pub const GtkPropagationPhase = enum(guint) {
    none = 0,
    capture = 1,
    bubble = 2,
    target = 3,
};

pub const GtkPolicyType = enum(guint) {
    always = 0,
    automatic = 1,
    never = 2,
    external = 3,
};

pub const GtkApplication = opaque {};
pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GtkBox = opaque {};
pub const GtkLabel = opaque {};
pub const GtkImage = opaque {};
pub const GtkEditable = opaque {};
pub const GtkEntry = opaque {};
pub const GtkEntryBuffer = opaque {};
pub const GtkListBox = opaque {};
pub const GtkListBoxRow = opaque {};
pub const GtkScrolledWindow = opaque {};
pub const GtkAdjustment = opaque {};
pub const GtkNotebook = opaque {};
pub const GtkTextView = opaque {};
pub const GtkTextBuffer = opaque {};
pub const GtkCssProvider = opaque {};
pub const GtkStyleProvider = opaque {};
pub const GtkEventController = opaque {};
pub const GtkEventControllerKey = opaque {};
pub const GtkEventControllerFocus = opaque {};
pub const GtkDialog = opaque {};
pub const GtkMessageDialog = opaque {};

pub const GtkDialogFlags = guint;
pub const dialog_default_flags: GtkDialogFlags = 0;

pub const GtkMessageType = enum(guint) {
    info = 0,
    warning = 1,
    question = 2,
    fault = 3,
    other = 4,
};

pub const GtkButtonsType = enum(guint) {
    none = 0,
    ok = 1,
    close = 2,
    cancel = 3,
    yes_no = 4,
    ok_cancel = 5,
};

pub const response_ok: c_int = -5;

pub extern fn gtk_init_check() gboolean;
pub extern fn gtk_message_dialog_new(parent: ?*GtkWindow, flags: GtkDialogFlags, message_type: GtkMessageType, buttons: GtkButtonsType, message_format: ?[*:0]const u8, ...) *GtkWidget;
pub extern fn gtk_message_dialog_format_secondary_markup(dialog: *GtkMessageDialog, message_format: ?[*:0]const u8, ...) void;
pub extern fn gtk_dialog_add_button(
    dialog: *GtkDialog,
    button_text: [*:0]const u8,
    response_id: c_int,
) *GtkWidget;

pub extern fn gtk_application_new(application_id: ?[*:0]const u8, flags: GApplicationFlags) *GtkApplication;
pub extern fn gtk_application_window_new(application: *GtkApplication) *GtkWidget;

pub extern fn gtk_window_set_title(window: *GtkWindow, title: ?[*:0]const u8) void;
pub extern fn gtk_window_set_decorated(window: *GtkWindow, setting: gboolean) void;
pub extern fn gtk_window_set_resizable(window: *GtkWindow, resizable: gboolean) void;
pub extern fn gtk_window_set_default_size(window: *GtkWindow, width: c_int, height: c_int) void;
pub extern fn gtk_window_set_child(window: *GtkWindow, child: ?*GtkWidget) void;
pub extern fn gtk_window_present(window: *GtkWindow) void;
pub extern fn gtk_window_destroy(window: *GtkWindow) void;
pub extern fn gtk_window_is_active(window: *GtkWindow) gboolean;
pub extern fn gtk_window_get_focus(window: *GtkWindow) ?*GtkWidget;

pub extern fn gtk_widget_set_valign(widget: *GtkWidget, alignment: GtkAlign) void;
pub extern fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: gboolean) void;
pub extern fn gtk_widget_set_vexpand(widget: *GtkWidget, expand: gboolean) void;
pub extern fn gtk_widget_set_size_request(widget: *GtkWidget, width: c_int, height: c_int) void;
pub extern fn gtk_widget_set_can_focus(widget: *GtkWidget, can_focus: gboolean) void;
pub extern fn gtk_widget_grab_focus(widget: *GtkWidget) gboolean;
pub extern fn gtk_widget_add_css_class(widget: *GtkWidget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_add_controller(widget: *GtkWidget, controller: *GtkEventController) void;
pub extern fn gtk_widget_get_first_child(widget: *GtkWidget) ?*GtkWidget;
pub extern fn gtk_widget_is_ancestor(widget: *GtkWidget, ancestor: *GtkWidget) gboolean;
pub extern fn gtk_widget_get_clipboard(widget: *GtkWidget) *GdkClipboard;
pub extern fn gtk_widget_set_margin_start(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_end(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_top(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_bottom(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_measure(
    widget: *GtkWidget,
    orientation: GtkOrientation,
    for_size: c_int,
    minimum: ?*c_int,
    natural: ?*c_int,
    minimum_baseline: ?*c_int,
    natural_baseline: ?*c_int,
) void;
pub extern fn gtk_widget_compute_bounds(
    widget: *GtkWidget,
    target: *GtkWidget,
    out_bounds: *graphene_rect_t,
) gboolean;

pub extern fn gtk_box_new(orientation: GtkOrientation, spacing: c_int) *GtkWidget;
pub extern fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;
pub extern fn gtk_box_remove(box: *GtkBox, child: *GtkWidget) void;
pub extern fn gtk_box_reorder_child_after(box: *GtkBox, child: *GtkWidget, sibling: ?*GtkWidget) void;

pub const GtkButton = opaque {};

pub extern fn gtk_button_new_with_label(label: [*:0]const u8) *GtkWidget;
pub extern fn gtk_button_set_has_frame(button: *GtkButton, has_frame: gboolean) void;

pub extern fn gtk_label_new(str: ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_label_get_text(self: *GtkLabel) [*:0]const u8;
pub extern fn gtk_label_set_text(self: *GtkLabel, str: [*:0]const u8) void;
pub extern fn gtk_label_set_ellipsize(self: *GtkLabel, mode: PangoEllipsizeMode) void;
pub extern fn gtk_label_set_max_width_chars(self: *GtkLabel, n_chars: c_int) void;
pub extern fn gtk_label_set_xalign(self: *GtkLabel, xalign: f32) void;

pub extern fn gtk_image_new() *GtkWidget;
pub extern fn gtk_image_set_from_gicon(image: *GtkImage, icon: ?*GIcon) void;
pub extern fn gtk_image_set_from_icon_name(image: *GtkImage, icon_name: ?[*:0]const u8) void;
pub extern fn gtk_image_set_pixel_size(image: *GtkImage, pixel_size: c_int) void;

pub extern fn gtk_entry_new() *GtkWidget;
pub extern fn gtk_entry_get_buffer(entry: *GtkEntry) *GtkEntryBuffer;
pub extern fn gtk_entry_set_placeholder_text(entry: *GtkEntry, text: ?[*:0]const u8) void;
pub extern fn gtk_entry_grab_focus_without_selecting(entry: *GtkEntry) gboolean;
pub extern fn gtk_entry_buffer_get_text(buffer: *GtkEntryBuffer) [*:0]const u8;
pub extern fn gtk_entry_buffer_set_text(buffer: *GtkEntryBuffer, chars: [*:0]const u8, n_chars: c_int) void;

pub extern fn gtk_editable_select_region(editable: *GtkEditable, start_pos: c_int, end_pos: c_int) void;

pub extern fn gtk_list_box_new() *GtkWidget;
pub extern fn gtk_list_box_append(box: *GtkListBox, child: *GtkWidget) void;
pub extern fn gtk_list_box_remove(box: *GtkListBox, child: *GtkWidget) void;
pub extern fn gtk_list_box_set_selection_mode(box: *GtkListBox, mode: GtkSelectionMode) void;
pub extern fn gtk_list_box_select_row(box: *GtkListBox, row: ?*GtkListBoxRow) void;
pub extern fn gtk_list_box_get_selected_row(box: *GtkListBox) ?*GtkListBoxRow;
pub extern fn gtk_list_box_get_row_at_index(box: *GtkListBox, index: c_int) ?*GtkListBoxRow;
pub extern fn gtk_list_box_row_get_index(row: *GtkListBoxRow) c_int;

pub extern fn gtk_scrolled_window_new() *GtkWidget;
pub extern fn gtk_scrolled_window_set_child(window: *GtkScrolledWindow, child: ?*GtkWidget) void;
pub extern fn gtk_scrolled_window_set_policy(
    window: *GtkScrolledWindow,
    hscrollbar_policy: GtkPolicyType,
    vscrollbar_policy: GtkPolicyType,
) void;
pub extern fn gtk_scrolled_window_set_propagate_natural_height(
    window: *GtkScrolledWindow,
    propagate: gboolean,
) void;
pub extern fn gtk_scrolled_window_set_max_content_height(window: *GtkScrolledWindow, height: c_int) void;
pub extern fn gtk_scrolled_window_get_vadjustment(window: *GtkScrolledWindow) *GtkAdjustment;

pub extern fn gtk_adjustment_get_value(adjustment: *GtkAdjustment) gdouble;
pub extern fn gtk_adjustment_set_value(adjustment: *GtkAdjustment, value: gdouble) void;
pub extern fn gtk_adjustment_get_page_size(adjustment: *GtkAdjustment) gdouble;

pub const style_provider_priority_application: guint = 600;

pub extern fn gtk_css_provider_new() *GtkCssProvider;
pub extern fn gtk_css_provider_load_from_string(provider: *GtkCssProvider, string: [*:0]const u8) void;
pub extern fn gtk_style_context_add_provider_for_display(
    display: *GdkDisplay,
    provider: *GtkStyleProvider,
    priority: guint,
) void;

pub const GtkWrapMode = enum(guint) {
    none = 0,
    char = 1,
    word = 2,
    word_char = 3,
};

pub extern fn gtk_notebook_new() *GtkWidget;
pub extern fn gtk_notebook_append_page(
    notebook: *GtkNotebook,
    child: *GtkWidget,
    tab_label: ?*GtkWidget,
) c_int;
pub extern fn gtk_notebook_remove_page(notebook: *GtkNotebook, page_num: c_int) void;
pub extern fn gtk_notebook_get_n_pages(notebook: *GtkNotebook) c_int;
pub extern fn gtk_notebook_set_current_page(notebook: *GtkNotebook, page_num: c_int) void;
pub extern fn gtk_notebook_get_current_page(notebook: *GtkNotebook) c_int;
pub extern fn gtk_notebook_get_nth_page(notebook: *GtkNotebook, page_num: c_int) ?*GtkWidget;
pub extern fn gtk_notebook_get_tab_label_text(
    notebook: *GtkNotebook,
    child: *GtkWidget,
) ?[*:0]const u8;
pub extern fn gtk_notebook_set_scrollable(notebook: *GtkNotebook, scrollable: gboolean) void;

pub extern fn gtk_text_view_new() *GtkWidget;
pub extern fn gtk_text_view_get_buffer(view: *GtkTextView) *GtkTextBuffer;
pub extern fn gtk_text_view_set_editable(view: *GtkTextView, setting: gboolean) void;
pub extern fn gtk_text_view_set_cursor_visible(view: *GtkTextView, setting: gboolean) void;
pub extern fn gtk_text_view_set_monospace(view: *GtkTextView, monospace: gboolean) void;
pub extern fn gtk_text_view_set_wrap_mode(view: *GtkTextView, wrap_mode: GtkWrapMode) void;
pub extern fn gtk_text_buffer_set_text(buffer: *GtkTextBuffer, text: [*:0]const u8, len: c_int) void;

pub extern fn gtk_widget_set_visible(widget: *GtkWidget, visible: gboolean) void;
pub extern fn gtk_widget_get_visible(widget: *GtkWidget) gboolean;

pub extern fn gtk_event_controller_key_new() *GtkEventController;
pub extern fn gtk_event_controller_set_propagation_phase(
    controller: *GtkEventController,
    phase: GtkPropagationPhase,
) void;
pub extern fn gtk_event_controller_focus_new() *GtkEventController;

pub const GtkIconTheme = opaque {};

pub extern fn gtk_icon_theme_get_for_display(display: *GdkDisplay) *GtkIconTheme;
pub extern fn gtk_icon_theme_has_icon(self: *GtkIconTheme, icon_name: [*:0]const u8) gboolean;

pub fn digitOf(keyval: guint) ?u8 {
    if (keyval >= key_0 and keyval <= key_9) return @intCast(keyval - key_0);
    if (keyval >= key_KP_0 and keyval <= key_KP_9) return @intCast(keyval - key_KP_0);
    return null;
}

pub fn functionOf(keyval: guint) ?u8 {
    if (keyval >= key_F1 and keyval <= key_F12) return @intCast(keyval - key_F1 + 1);
    return null;
}

const testing = std.testing;

test digitOf {
    try testing.expectEqual(@as(?u8, 1), digitOf(key_0 + 1));
    try testing.expectEqual(@as(?u8, 5), digitOf(key_0 + 5));
    try testing.expectEqual(@as(?u8, 0), digitOf(key_0));
    try testing.expectEqual(@as(?u8, 3), digitOf(key_KP_0 + 3));

    try testing.expectEqual(@as(?u8, null), digitOf(key_Escape));
    try testing.expectEqual(@as(?u8, null), digitOf(key_Up));
}

test functionOf {
    try testing.expectEqual(@as(?u8, 1), functionOf(key_F1));
    try testing.expectEqual(@as(?u8, 5), functionOf(key_F1 + 4));
    try testing.expectEqual(@as(?u8, 12), functionOf(key_F12));

    try testing.expectEqual(@as(?u8, null), functionOf(key_F1 - 1));
    try testing.expectEqual(@as(?u8, null), functionOf(key_F12 + 1));
    try testing.expectEqual(@as(?u8, null), functionOf(key_0 + 1));
}
