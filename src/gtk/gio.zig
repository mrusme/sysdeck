const std = @import("std");
const c = @import("c.zig");

const gboolean = gboolean;
const gpointer = c.gpointer;
const guint = c.guint;
const gulong = c.gulong;
const gdouble = c.gdouble;

pub extern fn g_list_model_get_n_items(list: *c.GListModel) c.guint;
pub extern fn g_list_model_get_item(list: *c.GListModel, position: c.guint) ?*anyopaque;
pub extern fn g_memory_input_stream_new_from_bytes(bytes: *c.GBytes) *c.GMemoryInputStream;
pub extern fn g_app_info_get_all() ?*c.GList;
pub extern fn g_app_info_get_id(appinfo: *c.GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_display_name(appinfo: *c.GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_name(appinfo: *c.GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_description(appinfo: *c.GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_executable(appinfo: *c.GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_icon(appinfo: *c.GAppInfo) ?*c.GIcon;
pub extern fn g_app_info_should_show(appinfo: *c.GAppInfo) c.gboolean;
pub extern fn g_app_info_get_commandline(appinfo: *c.GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_default_for_type(
    content_type: [*:0]const u8,
    must_support_uris: c.gboolean,
) ?*c.GAppInfo;
pub extern fn g_app_info_launch_default_for_uri(
    uri: [*:0]const u8,
    launch_context: ?*c.GAppLaunchContext,
    err: *?*c.GError,
) c.gboolean;
pub extern fn g_icon_to_string(icon: *c.GIcon) ?[*:0]u8;
pub extern fn g_icon_new_for_string(str: [*:0]const u8, err: ?*?*c.GError) ?*c.GIcon;
pub extern fn g_content_type_guess(
    filename: ?[*:0]const u8,
    data: ?[*]const u8,
    data_size: usize,
    result_uncertain: ?*c.gboolean,
) ?[*:0]u8;
pub extern fn g_content_type_get_mime_type(content_type: [*:0]const u8) ?[*:0]u8;
pub extern fn g_content_type_get_description(content_type: [*:0]const u8) ?[*:0]u8;
pub extern fn g_content_type_get_icon(content_type: [*:0]const u8) ?*c.GIcon;
pub extern fn g_content_type_is_a(content_type: [*:0]const u8, supertype: [*:0]const u8) c.gboolean;
pub extern fn g_desktop_app_info_new(desktop_id: [*:0]const u8) ?*c.GDesktopAppInfo;
pub extern fn g_desktop_app_info_get_generic_name(info: *c.GDesktopAppInfo) ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_keywords(info: *c.GDesktopAppInfo) ?[*:null]const ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_filename(info: *c.GDesktopAppInfo) ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_boolean(
    info: *c.GDesktopAppInfo,
    key: [*:0]const u8,
) c.gboolean;
pub extern fn g_desktop_app_info_list_actions(info: *c.GDesktopAppInfo) [*:null]const ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_action_name(
    info: *c.GDesktopAppInfo,
    action_name: [*:0]const u8,
) ?[*:0]u8;
pub extern fn g_desktop_app_info_launch_action(
    info: *c.GDesktopAppInfo,
    action_name: [*:0]const u8,
    launch_context: ?*c.GAppLaunchContext,
) void;
pub extern fn g_desktop_app_info_launch_uris_as_manager(
    appinfo: *c.GDesktopAppInfo,
    uris: ?*c.GList,
    launch_context: ?*c.GAppLaunchContext,
    spawn_flags: c.GSpawnFlags,
    user_setup: ?c.GSpawnChildSetupFunc,
    user_setup_data: c.gpointer,
    pid_callback: ?c.GDesktopAppLaunchCallback,
    pid_callback_data: c.gpointer,
    err: *?*c.GError,
) c.gboolean;
pub extern fn g_bus_get_sync(
    bus_type: c.GBusType,
    cancellable: ?*c.GCancellable,
    err: ?*?*c.GError,
) ?*c.GDBusConnection;
pub extern fn g_dbus_connection_call_sync(
    connection: *c.GDBusConnection,
    bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    method_name: [*:0]const u8,
    parameters: ?*c.GVariant,
    reply_type: ?*const c.GVariantType,
    flags: c.GDBusCallFlags,
    timeout_msec: c.gint,
    cancellable: ?*c.GCancellable,
    err: ?*?*c.GError,
) ?*c.GVariant;
