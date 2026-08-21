pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;
pub const gulong = c_ulong;
pub const guint = c_uint;
pub const gdouble = f64;

pub const TRUE: gboolean = 1;
pub const FALSE: gboolean = 0;

pub const GParamSpec = opaque {};
pub const GApplication = opaque {};

pub const GCallback = *const fn () callconv(.c) void;
pub const GClosureNotify = *const fn (data: gpointer, closure: gpointer) callconv(.c) void;

pub const GConnectFlags = guint;
pub const connect_default: GConnectFlags = 0;

pub extern fn g_object_unref(object: gpointer) void;
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

pub const GdkDisplay = opaque {};
pub const GdkModifierType = guint;

pub extern fn gdk_display_get_default() ?*GdkDisplay;

pub const graphene_rect_t = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const key_Escape: guint = 0xff1b;
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
pub const GtkEditable = opaque {};
pub const GtkEntry = opaque {};
pub const GtkEntryBuffer = opaque {};
pub const GtkListBox = opaque {};
pub const GtkListBoxRow = opaque {};
pub const GtkScrolledWindow = opaque {};
pub const GtkAdjustment = opaque {};
pub const GtkCssProvider = opaque {};
pub const GtkStyleProvider = opaque {};
pub const GtkEventController = opaque {};
pub const GtkEventControllerKey = opaque {};

pub extern fn gtk_application_new(application_id: ?[*:0]const u8, flags: GApplicationFlags) *GtkApplication;
pub extern fn gtk_application_window_new(application: *GtkApplication) *GtkWidget;

pub extern fn gtk_window_set_title(window: *GtkWindow, title: ?[*:0]const u8) void;
pub extern fn gtk_window_set_decorated(window: *GtkWindow, setting: gboolean) void;
pub extern fn gtk_window_set_resizable(window: *GtkWindow, resizable: gboolean) void;
pub extern fn gtk_window_set_default_size(window: *GtkWindow, width: c_int, height: c_int) void;
pub extern fn gtk_window_set_child(window: *GtkWindow, child: ?*GtkWidget) void;
pub extern fn gtk_window_present(window: *GtkWindow) void;
pub extern fn gtk_window_is_active(window: *GtkWindow) gboolean;

pub extern fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: gboolean) void;
pub extern fn gtk_widget_set_vexpand(widget: *GtkWidget, expand: gboolean) void;
pub extern fn gtk_widget_set_size_request(widget: *GtkWidget, width: c_int, height: c_int) void;
pub extern fn gtk_widget_set_can_focus(widget: *GtkWidget, can_focus: gboolean) void;
pub extern fn gtk_widget_grab_focus(widget: *GtkWidget) gboolean;
pub extern fn gtk_widget_add_css_class(widget: *GtkWidget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_add_controller(widget: *GtkWidget, controller: *GtkEventController) void;
pub extern fn gtk_widget_get_first_child(widget: *GtkWidget) ?*GtkWidget;
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

pub extern fn gtk_label_new(str: ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_label_set_ellipsize(self: *GtkLabel, mode: PangoEllipsizeMode) void;
pub extern fn gtk_label_set_max_width_chars(self: *GtkLabel, n_chars: c_int) void;
pub extern fn gtk_label_set_xalign(self: *GtkLabel, xalign: f32) void;

pub extern fn gtk_entry_new() *GtkWidget;
pub extern fn gtk_entry_get_buffer(entry: *GtkEntry) *GtkEntryBuffer;
pub extern fn gtk_entry_set_placeholder_text(entry: *GtkEntry, text: ?[*:0]const u8) void;
pub extern fn gtk_entry_buffer_get_text(buffer: *GtkEntryBuffer) [*:0]const u8;

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

pub extern fn gtk_event_controller_key_new() *GtkEventController;
