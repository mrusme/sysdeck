const std = @import("std");

pub const cairo = @import("cairo.zig");
pub const gdk = @import("gdk.zig");
pub const gio = @import("gio.zig");
pub const glib = @import("glib.zig");
pub const gtk = @import("gtk.zig");
pub const layer = @import("layer.zig");
pub const pixbuf = @import("pixbuf.zig");

pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;
pub const gulong = c_ulong;
pub const guint = c_uint;
pub const gint = c_int;
pub const gsize = usize;
pub const GType = gsize;
pub const gdouble = f64;

pub const TRUE: gboolean = 1;
pub const FALSE: gboolean = 0;

pub const GObject = opaque {};
pub const GParamSpec = opaque {};
pub const GApplication = opaque {};

pub const GList = extern struct {
    data: gpointer,
    next: ?*GList,
    prev: ?*GList,
};

pub const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]u8,
};

pub const GKeyFile = opaque {};
pub const GKeyFileFlags = guint;

pub const key_file_none: GKeyFileFlags = 0;

pub const GBytes = opaque {};
pub const GInputStream = opaque {};
pub const GMemoryInputStream = opaque {};

pub const GResource = opaque {};
pub const GResourceLookupFlags = guint;

pub const resource_lookup_none: GResourceLookupFlags = 0;

pub const GAsyncResult = opaque {};
pub const GCancellable = opaque {};

pub const GVariant = opaque {};
pub const GVariantType = opaque {};

pub const GAction = opaque {};
pub const GActionGroup = opaque {};
pub const GActionMap = opaque {};
pub const GSimpleAction = opaque {};
pub const GSimpleActionGroup = opaque {};
pub const GMenu = opaque {};
pub const GMenuModel = opaque {};
pub const GDBusConnection = opaque {};

pub const GBusType = gint;

pub const bus_system: GBusType = 1;

pub const GDBusCallFlags = guint;

pub const dbus_call_none: GDBusCallFlags = 0;
pub const dbus_call_no_auto_start: GDBusCallFlags = 1 << 0;
pub const dbus_call_allow_interactive_authorization: GDBusCallFlags = 1 << 1;

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

pub fn errorMessage(err: ?*GError) []const u8 {
    const detail = err orelse return "no detail";
    return std.mem.span(detail.message orelse return "no detail");
}

pub fn installed(gpa: std.mem.Allocator, program: []const u8) bool {
    const name = gpa.dupeZ(u8, program) catch return false;
    defer gpa.free(name);

    const found = glib.g_find_program_in_path(name.ptr) orelse return false;
    glib.g_free(found);
    return true;
}

pub fn waylandDisplay() ?*GdkDisplay {
    const display = gdk.gdk_display_get_default() orelse return null;
    if (glib.g_type_check_instance_is_a(display, gdk.gdk_wayland_display_get_type()) == FALSE) return null;
    return display;
}

pub fn discard(widget: *GtkWidget) void {
    _ = glib.g_object_ref_sink(widget);
    glib.g_object_unref(widget);
}

pub inline fn connect(
    instance: anytype,
    signal: [*:0]const u8,
    handler: anytype,
    data: gpointer,
) gulong {
    comptime checkHandler(@TypeOf(handler));
    return glib.g_signal_connect_data(@ptrCast(instance), signal, @ptrCast(handler), data, null, connect_default);
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

const hierarchy = .{
    .{ GApplication, GObject },
    .{ GtkApplication, GApplication },
    .{ GtkWidget, GObject },
    .{ GtkWindow, GtkWidget },
    .{ GtkWindow, GtkNative },
    .{ GtkWindow, GtkRoot },
    .{ GtkRoot, GtkWidget },
    .{ GtkDialog, GtkWindow },
    .{ GtkMessageDialog, GtkDialog },
    .{ GtkBox, GtkWidget },
    .{ GtkFixed, GtkWidget },
    .{ GtkOverlay, GtkWidget },
    .{ GtkDropDown, GtkWidget },
    .{ GtkGestureDrag, GtkGesture },
    .{ GtkGestureClick, GtkGesture },
    .{ GtkGesture, GtkEventController },
    .{ GtkShortcutController, GtkEventController },
    .{ GtkPopover, GtkWidget },
    .{ GtkPopoverMenu, GtkPopover },
    .{ GSimpleAction, GAction },
    .{ GSimpleActionGroup, GActionGroup },
    .{ GSimpleActionGroup, GActionMap },
    .{ GMenu, GMenuModel },
    .{ GtkLabel, GtkWidget },
    .{ GtkImage, GtkWidget },
    .{ GtkPicture, GtkWidget },
    .{ GtkButton, GtkWidget },
    .{ GtkEntry, GtkWidget },
    .{ GtkListBox, GtkWidget },
    .{ GtkListBoxRow, GtkWidget },
    .{ GtkScrolledWindow, GtkWidget },
    .{ GtkNotebook, GtkWidget },
    .{ GtkTextView, GtkWidget },
    .{ GtkEntry, GtkEditable },
    .{ GtkCssProvider, GtkStyleProvider },
    .{ GDesktopAppInfo, GAppInfo },
    .{ GdkSurface, GdkToplevel },
    .{ GdkTexture, GdkPaintable },
    .{ GtkMediaStream, GdkPaintable },
    .{ GdkAppLaunchContext, GAppLaunchContext },
    .{ GMemoryInputStream, GInputStream },
    .{ GtkMediaFile, GtkMediaStream },
};

fn derives(comptime From: type, comptime To: type) bool {
    @setEvalBranchQuota(10_000);
    if (From == To) return true;

    inline for (hierarchy) |edge| {
        if (edge[0] == From and derives(edge[1], To)) return true;
    }
    return false;
}

pub inline fn cast(comptime T: type, ptr: anytype) *T {
    const From = comptime switch (@typeInfo(@TypeOf(ptr))) {
        .pointer => |info| info.child,
        else => @compileError("cast needs a pointer, not " ++ @typeName(@TypeOf(ptr))),
    };
    if (comptime !derives(From, T) and !derives(T, From)) {
        @compileError("a " ++ @typeName(From) ++ " is not a " ++ @typeName(T));
    }
    return @ptrCast(ptr);
}

pub const GApplicationFlags = guint;
pub const application_non_unique: GApplicationFlags = 1 << 5;

pub const GMainContext = opaque {};

pub const source_remove: gboolean = FALSE;

pub const GMainLoop = opaque {};

pub const GPid = c_int;
pub const GSpawnFlags = guint;

pub const spawn_search_path: GSpawnFlags = 1 << 2;
pub const spawn_stdout_to_dev_null: GSpawnFlags = 1 << 3;
pub const spawn_stderr_to_dev_null: GSpawnFlags = 1 << 4;

pub const GSpawnChildSetupFunc = *const fn (data: gpointer) callconv(.c) void;

pub const GDateTime = opaque {};

pub const GUserDirectory = enum(c_uint) {
    desktop = 0,
    documents = 1,
    download = 2,
    music = 3,
    pictures = 4,
    public_share = 5,
    templates = 6,
    videos = 7,
};

pub const GAppInfo = opaque {};
pub const GDesktopAppInfo = opaque {};
pub const GAppLaunchContext = opaque {};
pub const GIcon = opaque {};

pub const GDesktopAppLaunchCallback = *const fn (
    appinfo: *GDesktopAppInfo,
    pid: GPid,
    data: gpointer,
) callconv(.c) void;

pub const GdkDisplay = opaque {};
pub const GdkSurface = opaque {};
pub const GdkToplevel = opaque {};
pub const GdkToplevelState = guint;

pub const toplevel_state_focused: GdkToplevelState = 1 << 6;

pub const GdkMonitor = opaque {};
pub const GListModel = opaque {};
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

pub const GdkRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

pub const graphene_point_t = extern struct {
    x: f32,
    y: f32,
};

pub const graphene_rect_t = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const key_d: guint = 0x0064;
pub const key_f: guint = 0x0066;
pub const key_k: guint = 0x006b;
pub const key_l: guint = 0x006c;
pub const key_n: guint = 0x006e;
pub const key_h: guint = 0x0068;
pub const key_t: guint = 0x0074;
pub const key_w: guint = 0x0077;
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

pub const GtkEntryIconPosition = enum(guint) {
    primary = 0,
    secondary = 1,
};

pub const GtkOrientation = enum(guint) {
    horizontal = 0,
    vertical = 1,
};

pub const GtkOverflow = enum(guint) {
    visible = 0,
    hidden = 1,
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
pub const GtkRoot = opaque {};
pub const GtkWindow = opaque {};
pub const GtkNative = opaque {};
pub const GtkBox = opaque {};
pub const GtkOverlay = opaque {};
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
pub const GtkTextMark = opaque {};

pub const GtkTextIter = extern struct {
    dummy1: gpointer = null,
    dummy2: gpointer = null,
    dummy3: c_int = 0,
    dummy4: c_int = 0,
    dummy5: c_int = 0,
    dummy6: c_int = 0,
    dummy7: c_int = 0,
    dummy8: c_int = 0,
    dummy9: gpointer = null,
    dummy10: gpointer = null,
    dummy11: c_int = 0,
    dummy12: c_int = 0,
    dummy13: c_int = 0,
    dummy14: gpointer = null,
};
pub const GtkCssProvider = opaque {};
pub const GtkStyleProvider = opaque {};
pub const GtkEventController = opaque {};
pub const GtkShortcutController = opaque {};
pub const GtkShortcut = opaque {};
pub const GtkShortcutTrigger = opaque {};
pub const GtkShortcutAction = opaque {};
pub const GtkPopover = opaque {};
pub const GtkPopoverMenu = opaque {};

pub const GtkShortcutFunc = *const fn (
    widget: *GtkWidget,
    args: ?*GVariant,
    data: gpointer,
) callconv(.c) gboolean;

pub const GtkPositionType = enum(guint) {
    left = 0,
    right = 1,
    top = 2,
    bottom = 3,
};

pub const GtkEventSequenceState = enum(guint) {
    none = 0,
    claimed = 1,
    denied = 2,
};

pub const GtkTextWindowType = enum(guint) {
    widget = 1,
    text = 2,
    left = 3,
    right = 4,
    top = 5,
    bottom = 6,
};
pub const GtkEventControllerMotion = opaque {};
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

pub const GtkButton = opaque {};

pub const style_provider_priority_application: guint = 600;

pub const GtkWrapMode = enum(guint) {
    none = 0,
    char = 1,
    word = 2,
    word_char = 3,
};

pub const GdkPaintable = opaque {};
pub const GdkPixbuf = opaque {};

pub const GdkInterpType = enum(guint) {
    nearest = 0,
    tiles = 1,
    bilinear = 2,
    hyper = 3,
};
pub const GdkTexture = opaque {};

pub const GdkMemoryFormat = enum(c_uint) {
    r8g8b8 = 7,
};
pub const GtkPicture = opaque {};

pub const GtkMediaStream = opaque {};
pub const GtkMediaFile = opaque {};

pub const GtkContentFit = enum(guint) {
    fill = 0,
    contain = 1,
    cover = 2,
    scale_down = 3,
};

pub const GtkIconTheme = opaque {};

pub const GtkFixed = opaque {};
pub const GtkDropDown = opaque {};

pub const invalid_list_position: guint = 0xffffffff;
pub const GtkGesture = opaque {};
pub const GtkGestureDrag = opaque {};
pub const GtkGestureClick = opaque {};

pub const cairo_t = opaque {};
pub const cairo_surface_t = opaque {};
pub const cairo_pattern_t = opaque {};
pub const cairo_region_t = opaque {};

pub const cairo_rectangle_int_t = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

pub const cairo_format_t = enum(c_int) {
    invalid = -1,
    argb32 = 0,
    rgb24 = 1,
};

pub const cairo_filter_t = enum(c_uint) {
    fast = 0,
    good = 1,
    best = 2,
    nearest = 3,
    bilinear = 4,
};

pub const cairo_status_t = c_uint;
pub const cairo_status_success: cairo_status_t = 0;

pub const GdkColorspace = enum(c_uint) {
    rgb = 0,
};

pub const GtkLayerShellLayer = enum(c_uint) {
    background = 0,
    bottom = 1,
    top = 2,
    overlay = 3,
};

pub const GtkLayerShellEdge = enum(c_uint) {
    left = 0,
    right = 1,
    top = 2,
    bottom = 3,
};

pub const GtkLayerShellKeyboardMode = enum(c_uint) {
    none = 0,
    exclusive = 1,
    on_demand = 2,
};

pub const button_secondary: guint = 3;

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
