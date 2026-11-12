const std = @import("std");
const bindings = @import("bindings");
const gtk = @import("gtk/c.zig");
const wayland = @import("wayland/c.zig");

const Library = struct {
    path: []const u8,
    decls: type,
    prefix: []const u8 = "",
};

const libraries = [_]Library{
    .{ .path = "wayland/c.zig", .decls = wayland, .prefix = "wl_" },
    .{ .path = "gtk/glib.zig", .decls = @import("gtk/glib.zig") },
    .{ .path = "gtk/gio.zig", .decls = @import("gtk/gio.zig") },
    .{ .path = "gtk/gdk.zig", .decls = @import("gtk/gdk.zig") },
    .{ .path = "gtk/gtk.zig", .decls = @import("gtk/gtk.zig") },
    .{ .path = "gtk/pixbuf.zig", .decls = @import("gtk/pixbuf.zig") },
    .{ .path = "gtk/cairo.zig", .decls = @import("gtk/cairo.zig") },
    .{ .path = "gtk/layer.zig", .decls = @import("gtk/layer.zig") },
    .{ .path = "gtk/gexiv2.zig", .decls = @import("gtk/gexiv2.zig") },
};

const layouts = [_]struct { where: []const u8, mine: type, theirs: type }{
    .{ .where = "wayland/c.zig Interface", .mine = wayland.Interface, .theirs = bindings.struct_wl_interface },
    .{ .where = "wayland/c.zig Message", .mine = wayland.Message, .theirs = bindings.struct_wl_message },
};

const prefixes = [_]struct { type: type, prefix: []const u8 }{
    .{ .type = gtk.GUserDirectory, .prefix = "G_USER_DIRECTORY_" },
    .{ .type = gtk.PangoEllipsizeMode, .prefix = "PANGO_ELLIPSIZE_" },
    .{ .type = gtk.GtkAlign, .prefix = "GTK_ALIGN_" },
    .{ .type = gtk.GtkEntryIconPosition, .prefix = "GTK_ENTRY_ICON_" },
    .{ .type = gtk.GtkOrientation, .prefix = "GTK_ORIENTATION_" },
    .{ .type = gtk.GtkSizeRequestMode, .prefix = "GTK_SIZE_REQUEST_" },
    .{ .type = gtk.GtkTextDirection, .prefix = "GTK_TEXT_DIR_" },
    .{ .type = gtk.GtkOverflow, .prefix = "GTK_OVERFLOW_" },
    .{ .type = gtk.GtkSelectionMode, .prefix = "GTK_SELECTION_" },
    .{ .type = gtk.GtkPropagationPhase, .prefix = "GTK_PHASE_" },
    .{ .type = gtk.GtkPolicyType, .prefix = "GTK_POLICY_" },
    .{ .type = gtk.GtkPositionType, .prefix = "GTK_POS_" },
    .{ .type = gtk.GtkEventSequenceState, .prefix = "GTK_EVENT_SEQUENCE_" },
    .{ .type = gtk.GtkTextWindowType, .prefix = "GTK_TEXT_WINDOW_" },
    .{ .type = gtk.GtkMessageType, .prefix = "GTK_MESSAGE_" },
    .{ .type = gtk.GtkButtonsType, .prefix = "GTK_BUTTONS_" },
    .{ .type = gtk.GtkWrapMode, .prefix = "GTK_WRAP_" },
    .{ .type = gtk.GdkInterpType, .prefix = "GDK_INTERP_" },
    .{ .type = gtk.GdkMemoryFormat, .prefix = "GDK_MEMORY_" },
    .{ .type = gtk.GtkContentFit, .prefix = "GTK_CONTENT_FIT_" },
    .{ .type = gtk.cairo_format_t, .prefix = "CAIRO_FORMAT_" },
    .{ .type = gtk.cairo_filter_t, .prefix = "CAIRO_FILTER_" },
    .{ .type = gtk.GdkColorspace, .prefix = "GDK_COLORSPACE_" },
    .{ .type = gtk.GtkLayerShellLayer, .prefix = "GTK_LAYER_SHELL_LAYER_" },
    .{ .type = gtk.GtkLayerShellEdge, .prefix = "GTK_LAYER_SHELL_EDGE_" },
    .{ .type = gtk.GtkLayerShellKeyboardMode, .prefix = "GTK_LAYER_SHELL_KEYBOARD_MODE_" },
    .{ .type = gtk.GExiv2LogLevel, .prefix = "GEXIV2_LOG_LEVEL_" },
};

const names = [_]struct { mine: []const u8, theirs: []const u8 }{
    .{ .mine = "TRUE", .theirs = "TRUE" },
    .{ .mine = "FALSE", .theirs = "FALSE" },
    .{ .mine = "key_file_none", .theirs = "G_KEY_FILE_NONE" },
    .{ .mine = "key_file_keep_translations", .theirs = "G_KEY_FILE_KEEP_TRANSLATIONS" },
    .{ .mine = "resource_lookup_none", .theirs = "G_RESOURCE_LOOKUP_FLAGS_NONE" },
    .{ .mine = "bus_system", .theirs = "G_BUS_TYPE_SYSTEM" },
    .{ .mine = "bus_session", .theirs = "G_BUS_TYPE_SESSION" },
    .{ .mine = "dbus_call_none", .theirs = "G_DBUS_CALL_FLAGS_NONE" },
    .{ .mine = "dbus_call_no_auto_start", .theirs = "G_DBUS_CALL_FLAGS_NO_AUTO_START" },
    .{ .mine = "dbus_call_allow_interactive_authorization", .theirs = "G_DBUS_CALL_FLAGS_ALLOW_INTERACTIVE_AUTHORIZATION" },
    .{ .mine = "connect_default", .theirs = "G_CONNECT_DEFAULT" },
    .{ .mine = "application_non_unique", .theirs = "G_APPLICATION_NON_UNIQUE" },
    .{ .mine = "source_remove", .theirs = "G_SOURCE_REMOVE" },
    .{ .mine = "source_continue", .theirs = "G_SOURCE_CONTINUE" },
    .{ .mine = "spawn_search_path", .theirs = "G_SPAWN_SEARCH_PATH" },
    .{ .mine = "spawn_stdout_to_dev_null", .theirs = "G_SPAWN_STDOUT_TO_DEV_NULL" },
    .{ .mine = "spawn_stderr_to_dev_null", .theirs = "G_SPAWN_STDERR_TO_DEV_NULL" },
    .{ .mine = "toplevel_state_focused", .theirs = "GDK_TOPLEVEL_STATE_FOCUSED" },
    .{ .mine = "priority_default", .theirs = "G_PRIORITY_DEFAULT" },
    .{ .mine = "modifier_shift", .theirs = "GDK_SHIFT_MASK" },
    .{ .mine = "modifier_control", .theirs = "GDK_CONTROL_MASK" },
    .{ .mine = "modifier_alt", .theirs = "GDK_ALT_MASK" },
    .{ .mine = "modifier_super", .theirs = "GDK_SUPER_MASK" },
    .{ .mine = "key_void", .theirs = "GDK_KEY_VoidSymbol" },
    .{ .mine = "response_ok", .theirs = "GTK_RESPONSE_OK" },
    .{ .mine = "style_provider_priority_application", .theirs = "GTK_STYLE_PROVIDER_PRIORITY_APPLICATION" },
    .{ .mine = "invalid_list_position", .theirs = "GTK_INVALID_LIST_POSITION" },
    .{ .mine = "cairo_status_success", .theirs = "CAIRO_STATUS_SUCCESS" },
    .{ .mine = "button_secondary", .theirs = "GDK_BUTTON_SECONDARY" },
};

const derived = [_][]const u8{ "modifier_mask", "dialog_default_flags" };

const Named = struct { type: type, name: []const u8 };

const tags = [_]Named{
    .{ .type = wayland.Proxy, .name = "wl_proxy" },
    .{ .type = wayland.Queue, .name = "wl_event_queue" },
    .{ .type = wayland.Display, .name = "wl_display" },
    .{ .type = wayland.Surface, .name = "wl_surface" },
    .{ .type = wayland.Output, .name = "wl_output" },
    .{ .type = wayland.Interface, .name = "wl_interface" },
    .{ .type = wayland.Message, .name = "wl_message" },
};

const nominals = found: {
    @setEvalBranchQuota(100_000);

    var list: []const Named = &tags;
    for (@typeInfo(gtk).@"struct".decl_names) |name| {
        if (@TypeOf(@field(gtk, name)) != type) continue;
        const T = @field(gtk, name);
        const declared = switch (@typeInfo(T)) {
            .@"opaque" => true,
            .@"struct" => |info| info.layout == .@"extern",
            else => false,
        };
        if (declared) list = list ++ [_]Named{.{ .type = T, .name = name }};
    }
    break :found list;
};

const Scalar = struct {
    kind: enum { integer, float, nothing },
    bits: u16 = 0,
    signed: bool = false,
};

fn scalarOf(comptime T: type) ?Scalar {
    return switch (@typeInfo(T)) {
        .int => |info| .{
            .kind = .integer,
            .bits = info.bits,
            .signed = info.signedness == .signed,
        },
        .float => |info| .{ .kind = .float, .bits = info.bits },
        .bool => .{ .kind = .integer, .bits = 1 },
        .@"enum" => |info| scalarOf(info.tag_type),
        .void => .{ .kind = .nothing },
        else => null,
    };
}

fn unwrapped(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| unwrapped(info.child),
        else => T,
    };
}

fn same(comptime Mine: type, comptime Theirs: type) bool {
    for (nominals) |entry| {
        if (entry.type != Mine) continue;
        if (!@hasDecl(bindings, entry.name)) return false;
        const Declared = @field(bindings, entry.name);
        return @TypeOf(Declared) == type and Declared == Theirs;
    }
    return false;
}

fn agrees(comptime Mine: type, comptime Theirs: type) bool {
    const One = unwrapped(Mine);
    const Two = unwrapped(Theirs);
    if (scalarOf(One)) |one| {
        const two = scalarOf(Two) orelse return false;
        return one.kind == two.kind and one.bits == two.bits and one.signed == two.signed;
    }
    return switch (@typeInfo(One)) {
        .pointer => |one| switch (@typeInfo(Two)) {
            .pointer => |two| agrees(one.child, two.child),
            else => false,
        },
        .@"fn" => @typeInfo(Two) == .@"fn" and compared("", One, Two).len == 0,
        .@"opaque" => if (One == anyopaque) Two == anyopaque else same(One, Two),
        .@"struct" => same(One, Two),
        else => false,
    };
}

fn nameOf(comptime T: type) []const u8 {
    for (nominals) |entry| {
        if (entry.type == T) return entry.name;
    }
    const full = @typeName(T);
    const base = if (std.mem.findScalarLast(u8, full, '.')) |at| full[at + 1 ..] else full;
    const tag = std.mem.cutPrefix(u8, base, "struct_") orelse base;
    return std.mem.trimStart(u8, tag, "_");
}

fn describe(comptime T: type) []const u8 {
    if (scalarOf(T)) |scalar| return switch (scalar.kind) {
        .integer => std.fmt.comptimePrint("{s}{d}", .{ if (scalar.signed) "i" else "u", scalar.bits }),
        .float => std.fmt.comptimePrint("f{d}", .{scalar.bits}),
        .nothing => "void",
    };
    return switch (@typeInfo(T)) {
        .optional => |info| describe(info.child),
        .pointer => |info| "a pointer to " ++ describe(info.child),
        .@"fn" => "a function",
        .@"opaque" => if (T == anyopaque) "void" else nameOf(T),
        else => nameOf(T),
    };
}

fn functionOf(comptime T: type) ?std.builtin.Type.Fn {
    return switch (@typeInfo(T)) {
        .@"fn" => |info| info,
        .optional => |info| functionOf(info.child),
        .pointer => |info| if (@typeInfo(info.child) == .@"fn") @typeInfo(info.child).@"fn" else null,
        else => null,
    };
}

fn matched(comptime where: []const u8, comptime Mine: type, comptime Theirs: type) []const []const u8 {
    if (functionOf(Mine) != null and functionOf(Theirs) != null) return compared(where, Mine, Theirs);
    if (agrees(Mine, Theirs)) return &.{};
    return &.{std.fmt.comptimePrint(
        "{s} is {s}, the header says {s}",
        .{ where, describe(Mine), describe(Theirs) },
    )};
}

fn returned(comptime where: []const u8, comptime Mine: type, comptime Theirs: type) []const []const u8 {
    if (agrees(Mine, Theirs)) return &.{};
    return &.{std.fmt.comptimePrint(
        "{s} returns {s}, the header returns {s}",
        .{ where, describe(Mine), describe(Theirs) },
    )};
}

fn compared(comptime where: []const u8, comptime Mine: type, comptime Theirs: type) []const []const u8 {
    const mine = functionOf(Mine) orelse return matched(where, Mine, Theirs);
    const theirs = functionOf(Theirs) orelse return matched(where, Mine, Theirs);

    const unprototyped = theirs.param_types.len == 0 and theirs.attrs.varargs;
    if (unprototyped and mine.param_types.len == 0 and !mine.attrs.varargs) {
        return returned(where, mine.return_type.?, theirs.return_type.?);
    }

    if (mine.param_types.len != theirs.param_types.len or mine.attrs.varargs != theirs.attrs.varargs) {
        return &.{std.fmt.comptimePrint(
            "{s}: {d} parameters{s}, the header declares {d}{s}",
            .{
                where,
                mine.param_types.len,
                if (mine.attrs.varargs) " and a variadic tail" else "",
                theirs.param_types.len,
                if (theirs.attrs.varargs) " and a variadic tail" else "",
            },
        )};
    }

    var list = returned(where, mine.return_type.?, theirs.return_type.?);
    for (mine.param_types, theirs.param_types, 1..) |ours, other, at| {
        const name = std.fmt.comptimePrint("{s} parameter {d}", .{ where, at });
        list = list ++ matched(name, ours.?, other.?);
    }
    return list;
}

const Leaf = struct {
    name: []const u8,
    offset: usize,
    type: type,
};

fn leavesOf(comptime T: type, comptime name: []const u8, comptime base: usize) []const Leaf {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var list: []const Leaf = &.{};
            for (info.field_names, info.field_types) |field, Field| {
                const path = if (name.len == 0) field else name ++ "." ++ field;
                list = list ++ leavesOf(Field, path, base + @offsetOf(T, field));
            }
            return list;
        },
        .array => |info| {
            var list: []const Leaf = &.{};
            for (0..info.len) |at| {
                const path = std.fmt.comptimePrint("{s}[{d}]", .{ name, at });
                list = list ++ leavesOf(info.child, path, base + at * @sizeOf(info.child));
            }
            return list;
        },
        else => return &.{.{ .name = name, .offset = base, .type = T }},
    }
}

fn laidOut(comptime where: []const u8, comptime Mine: type, comptime Theirs: type) []const []const u8 {
    const mine = leavesOf(Mine, "", 0);
    const theirs = leavesOf(Theirs, "", 0);

    if (@sizeOf(Mine) != @sizeOf(Theirs) or mine.len != theirs.len) {
        return &.{std.fmt.comptimePrint(
            "{s}: {d} fields in {d} bytes, the header has {d} in {d}",
            .{ where, mine.len, @sizeOf(Mine), theirs.len, @sizeOf(Theirs) },
        )};
    }

    var list: []const []const u8 = &.{};
    for (mine, theirs) |one, two| {
        const field = where ++ " " ++ one.name;
        if (one.offset != two.offset) {
            list = list ++ [_][]const u8{std.fmt.comptimePrint(
                "{s} is at byte {d}, the header has it at byte {d}",
                .{ field, one.offset, two.offset },
            )};
            continue;
        }
        list = list ++ matched(field, one.type, two.type);
    }
    return list;
}

fn integer(comptime value: anytype) comptime_int {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => @intFromBool(value),
        .@"enum" => @backingInt(value),
        else => value,
    };
}

fn named(comptime where: []const u8, comptime mine: comptime_int, comptime theirs: []const u8) []const []const u8 {
    if (!@hasDecl(bindings, theirs)) return &.{where ++ ": the headers don't declare " ++ theirs};

    const value = integer(@field(bindings, theirs));
    if (mine == value) return &.{};
    return &.{std.fmt.comptimePrint("{s} is {d}, {s} is {d}", .{ where, mine, theirs, value })};
}

fn enumerated(comptime name: []const u8) []const []const u8 {
    const where = "gtk/c.zig " ++ name;
    const T = @field(gtk, name);
    const prefix = for (prefixes) |entry| {
        if (entry.type == T) break entry.prefix;
    } else return &.{where ++ ": no C prefix in drift.zig"};

    var list: []const []const u8 = &.{};
    const info = @typeInfo(T).@"enum";
    for (info.field_names, info.field_values) |field, value| {
        var upper: [field.len]u8 = undefined;
        _ = std.ascii.upperString(&upper, field);
        list = list ++ named(where ++ "." ++ field, value, prefix ++ upper);
    }
    return list;
}

fn valued(comptime name: []const u8) []const []const u8 {
    const where = "gtk/c.zig " ++ name;
    const mine = integer(@field(gtk, name));
    for (names) |entry| {
        if (std.mem.eql(u8, entry.mine, name)) return named(where, mine, entry.theirs);
    }
    for (derived) |entry| {
        if (std.mem.eql(u8, entry, name)) return &.{};
    }
    if (std.mem.startsWith(u8, name, "key_")) return named(where, mine, "GDK_KEY_" ++ name["key_".len..]);
    return &.{where ++ ": no C name in drift.zig"};
}

fn typed(comptime name: []const u8) []const []const u8 {
    const where = "gtk/c.zig " ++ name;
    const Mine = @field(gtk, name);
    if (@typeInfo(Mine) == .@"struct" and @typeInfo(Mine).@"struct".layout != .@"extern") return &.{};
    if (!@hasDecl(bindings, name)) return &.{where ++ ": the headers don't declare it"};

    const Theirs = @field(bindings, name);
    return switch (@typeInfo(Mine)) {
        .@"opaque" => &.{},
        .@"struct" => laidOut(where, Mine, Theirs),
        else => compared(where, Mine, Theirs),
    };
}

const problems = found: {
    @setEvalBranchQuota(10_000_000);

    var list: []const []const u8 = &.{};
    for (libraries) |library| {
        for (@typeInfo(library.decls).@"struct".decl_names) |name| {
            if (!std.mem.startsWith(u8, name, library.prefix)) continue;

            const where = library.path ++ " " ++ name;
            if (!@hasDecl(bindings, name)) {
                list = list ++ [_][]const u8{where ++ ": the headers no longer declare it"};
                continue;
            }
            list = list ++ compared(where, @TypeOf(@field(library.decls, name)), @TypeOf(@field(bindings, name)));
        }
    }

    for (@typeInfo(gtk).@"struct".decl_names) |name| {
        const Value = @TypeOf(@field(gtk, name));
        if (Value == type) {
            list = list ++ typed(name);
            if (@typeInfo(@field(gtk, name)) == .@"enum") list = list ++ enumerated(name);
        } else if (@typeInfo(Value) != .@"fn") {
            list = list ++ valued(name);
        }
    }

    for (layouts) |entry| list = list ++ laidOut(entry.where, entry.mine, entry.theirs);
    break :found list;
};

test "the bindings agree with the system headers" {
    if (problems.len == 0) return;

    for (problems) |one| std.debug.print("{s}\n", .{one});
    return error.BindingsDrifted;
}
