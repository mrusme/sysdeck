const std = @import("std");
const c = @import("c.zig");

const gboolean = gboolean;
const gpointer = c.gpointer;
const guint = c.guint;
const gulong = c.gulong;
const gdouble = c.gdouble;

pub extern fn g_list_free_full(list: ?*c.GList, free_func: c.GDestroyNotify) void;
pub extern fn g_error_free(err: *c.GError) void;
pub extern fn g_key_file_new() *c.GKeyFile;
pub extern fn g_key_file_free(key_file: *c.GKeyFile) void;
pub extern fn g_key_file_load_from_file(
    key_file: *c.GKeyFile,
    file: [*:0]const u8,
    flags: c.GKeyFileFlags,
    err: ?*?*c.GError,
) c.gboolean;
pub extern fn g_key_file_load_from_data(
    key_file: *c.GKeyFile,
    data: [*]const u8,
    length: usize,
    flags: c.GKeyFileFlags,
    err: ?*?*c.GError,
) c.gboolean;
pub extern fn g_key_file_get_string(
    key_file: *c.GKeyFile,
    group_name: [*:0]const u8,
    key: [*:0]const u8,
    err: ?*?*c.GError,
) ?[*:0]u8;
pub extern fn g_bytes_new(data: [*]const u8, size: usize) *c.GBytes;
pub extern fn g_bytes_unref(bytes: *c.GBytes) void;
pub extern fn g_get_user_name() [*:0]const u8;
pub extern fn g_filename_to_uri(
    filename: [*:0]const u8,
    hostname: ?[*:0]const u8,
    err: ?*?*c.GError,
) ?[*:0]u8;
pub extern fn g_get_user_special_dir(directory: c.GUserDirectory) ?[*:0]const u8;
pub extern fn g_date_time_new_now_local() ?*c.GDateTime;
pub extern fn g_find_program_in_path(program: [*:0]const u8) ?[*:0]u8;
pub extern fn g_object_set_data(object: c.gpointer, key: [*:0]const u8, data: c.gpointer) void;
pub extern fn g_object_set_data_full(
    object: c.gpointer,
    key: [*:0]const u8,
    data: c.gpointer,
    destroy: ?c.GDestroyNotify,
) void;
pub extern fn g_object_get_data(object: c.gpointer, key: [*:0]const u8) c.gpointer;
pub extern fn g_object_ref(object: c.gpointer) c.gpointer;
pub extern fn g_object_ref_sink(object: c.gpointer) c.gpointer;
pub extern fn g_object_unref(object: c.gpointer) void;
pub extern fn g_free(mem: c.gpointer) void;
pub extern fn g_set_prgname(name: [*:0]const u8) void;
pub extern fn g_signal_connect_data(
    instance: c.gpointer,
    detailed_signal: [*:0]const u8,
    c_handler: c.GCallback,
    data: c.gpointer,
    destroy_data: ?c.GClosureNotify,
    connect_flags: c.GConnectFlags,
) c.gulong;
pub extern fn g_application_run(application: *c.GApplication, argc: c_int, argv: ?[*][*:0]u8) c_int;
pub extern fn g_application_quit(application: *c.GApplication) void;
pub extern fn g_idle_add(function: c.GSourceFunc, data: c.gpointer) c.guint;
pub extern fn g_timeout_add(interval: c.guint, function: c.GSourceFunc, data: c.gpointer) c.guint;
pub extern fn g_source_remove(tag: c.guint) c.gboolean;
pub extern fn g_main_context_default() *c.GMainContext;
pub extern fn g_main_context_iteration(context: ?*c.GMainContext, may_block: c.gboolean) c.gboolean;
pub extern fn g_main_loop_new(context: ?*c.GMainContext, is_running: c.gboolean) *c.GMainLoop;
pub extern fn g_main_loop_run(loop: *c.GMainLoop) void;
pub extern fn g_main_loop_quit(loop: *c.GMainLoop) void;
pub extern fn g_main_loop_unref(loop: *c.GMainLoop) void;
pub extern fn g_spawn_sync(
    working_directory: ?[*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*:null]const ?[*:0]const u8,
    flags: c.GSpawnFlags,
    child_setup: ?c.GSpawnChildSetupFunc,
    user_data: c.gpointer,
    standard_output: ?*?[*:0]u8,
    standard_error: ?*?[*:0]u8,
    exit_status: ?*c_int,
    err: *?*c.GError,
) c.gboolean;
pub extern fn g_get_environ() [*:null]?[*:0]u8;
pub extern fn g_environ_setenv(
    envp: ?[*:null]?[*:0]u8,
    variable: [*:0]const u8,
    value: [*:0]const u8,
    overwrite: c.gboolean,
) [*:null]?[*:0]u8;
pub extern fn g_strfreev(str_array: ?[*:null]?[*:0]u8) void;
pub extern fn g_utf8_make_valid(str: [*:0]const u8, len: isize) [*:0]u8;
pub extern fn g_markup_escape_text(text: [*]const u8, length: isize) ?[*:0]u8;
pub extern fn g_spawn_async(
    working_directory: ?[*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*:null]const ?[*:0]const u8,
    flags: c.GSpawnFlags,
    child_setup: ?c.GSpawnChildSetupFunc,
    user_data: c.gpointer,
    child_pid: ?*c.GPid,
    err: *?*c.GError,
) c.gboolean;
pub extern fn g_spawn_async_with_pipes(
    working_directory: ?[*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*:null]const ?[*:0]const u8,
    flags: c.GSpawnFlags,
    child_setup: ?c.GSpawnChildSetupFunc,
    user_data: c.gpointer,
    child_pid: ?*c.GPid,
    standard_input: ?*c_int,
    standard_output: ?*c_int,
    standard_error: ?*c_int,
    err: *?*c.GError,
) c.gboolean;
pub extern fn g_date_time_new_from_unix_local(t: i64) ?*c.GDateTime;
pub extern fn g_date_time_add_days(datetime: *c.GDateTime, days: c_int) ?*c.GDateTime;
pub extern fn g_date_time_format(datetime: *c.GDateTime, format: [*:0]const u8) ?[*:0]u8;
pub extern fn g_date_time_unref(datetime: *c.GDateTime) void;
pub extern fn g_variant_new_boolean(value: c.gboolean) *c.GVariant;
pub extern fn g_variant_new_string(string: [*:0]const u8) *c.GVariant;
pub extern fn g_variant_new_object_path(object_path: [*:0]const u8) *c.GVariant;
pub extern fn g_variant_new_variant(value: *c.GVariant) *c.GVariant;
pub extern fn g_variant_new_tuple(children: [*]const *c.GVariant, n_children: c.gsize) *c.GVariant;
pub extern fn g_variant_get_boolean(value: *c.GVariant) c.gboolean;
pub extern fn g_variant_get_uint32(value: *c.GVariant) u32;
pub extern fn g_variant_get_uint64(value: *c.GVariant) u64;
pub extern fn g_variant_get_string(value: *c.GVariant, length: ?*c.gsize) [*:0]const u8;
pub extern fn g_variant_get_objv(value: *c.GVariant, length: ?*c.gsize) [*]const [*:0]const u8;
pub extern fn g_variant_get_variant(value: *c.GVariant) *c.GVariant;
pub extern fn g_variant_n_children(value: *c.GVariant) c.gsize;
pub extern fn g_variant_get_child_value(value: *c.GVariant, index: c.gsize) *c.GVariant;
pub extern fn g_variant_lookup_value(
    dictionary: *c.GVariant,
    key: [*:0]const u8,
    expected_type: ?*const c.GVariantType,
) ?*c.GVariant;
pub extern fn g_variant_is_of_type(value: *c.GVariant, kind: *const c.GVariantType) c.gboolean;
pub extern fn g_variant_get_type_string(value: *c.GVariant) [*:0]const u8;
pub extern fn g_variant_ref_sink(value: *c.GVariant) *c.GVariant;
pub extern fn g_variant_unref(value: *c.GVariant) void;
pub extern fn g_variant_type_new(type_string: [*:0]const u8) *c.GVariantType;
pub extern fn g_variant_type_free(kind: *c.GVariantType) void;
pub extern fn g_variant_parse(
    kind: ?*const c.GVariantType,
    text: [*:0]const u8,
    limit: ?[*:0]const u8,
    endptr: ?*?[*:0]const u8,
    err: ?*?*c.GError,
) ?*c.GVariant;
