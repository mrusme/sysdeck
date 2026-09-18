const std = @import("std");
const bindings = @import("bindings");
const c = @import("c.zig");

const prefix = "wl_";

const layouts = [_]struct { name: []const u8, mine: type, theirs: type }{
    .{ .name = "Interface", .mine = c.Interface, .theirs = bindings.struct_wl_interface },
    .{ .name = "Message", .mine = c.Message, .theirs = bindings.struct_wl_message },
};

const Shape = struct {
    kind: enum { integer, float, pointer, aggregate, nothing },
    bits: u16 = 0,
    signed: bool = false,
    size: usize = 0,
};

fn shapeOf(comptime T: type) Shape {
    return switch (@typeInfo(T)) {
        .int => |info| .{
            .kind = .integer,
            .bits = info.bits,
            .signed = info.signedness == .signed,
        },
        .float => |info| .{ .kind = .float, .bits = info.bits },
        .bool => .{ .kind = .integer, .bits = 1 },
        .pointer, .@"fn" => .{ .kind = .pointer },
        .optional => |info| shapeOf(info.child),
        .@"enum" => |info| shapeOf(info.tag_type),
        .void => .{ .kind = .nothing },
        .@"struct", .array, .@"union" => .{ .kind = .aggregate, .size = @sizeOf(T) },
        else => .{ .kind = .aggregate },
    };
}

fn agrees(a: Shape, b: Shape) bool {
    if (a.kind != b.kind) return false;
    return switch (a.kind) {
        .integer => a.bits == b.bits and a.signed == b.signed,
        .float => a.bits == b.bits,
        .aggregate => a.size == b.size,
        .pointer, .nothing => true,
    };
}

fn describe(comptime shape: Shape) []const u8 {
    return switch (shape.kind) {
        .integer => std.fmt.comptimePrint("{s}{d}", .{ if (shape.signed) "i" else "u", shape.bits }),
        .float => std.fmt.comptimePrint("f{d}", .{shape.bits}),
        .pointer => "a pointer",
        .aggregate => std.fmt.comptimePrint("{d} bytes by value", .{shape.size}),
        .nothing => "void",
    };
}

const problems = found: {
    @setEvalBranchQuota(100_000);

    var list: []const []const u8 = &.{};
    for (@typeInfo(c).@"struct".decls) |decl| {
        if (!std.mem.startsWith(u8, decl.name, prefix)) continue;

        const where = "wayland/c.zig " ++ decl.name;
        if (!@hasDecl(bindings, decl.name)) {
            list = list ++ [_][]const u8{where ++ ": wayland-client.h no longer declares it"};
            continue;
        }

        const Mine = @TypeOf(@field(c, decl.name));
        const Theirs = @TypeOf(@field(bindings, decl.name));

        if (@typeInfo(Mine) != .@"fn" or @typeInfo(Theirs) != .@"fn") {
            const mine = shapeOf(Mine);
            const theirs = shapeOf(Theirs);
            if (!agrees(mine, theirs)) list = list ++ [_][]const u8{std.fmt.comptimePrint(
                "{s}: declared as {s}, the header says {s}",
                .{ where, describe(mine), describe(theirs) },
            )};
            continue;
        }

        const mine = @typeInfo(Mine).@"fn";
        const theirs = @typeInfo(Theirs).@"fn";

        if (mine.params.len != theirs.params.len or mine.is_var_args != theirs.is_var_args) {
            list = list ++ [_][]const u8{std.fmt.comptimePrint(
                "{s}: {d} parameters{s}, the header declares {d}{s}",
                .{
                    where,
                    mine.params.len,
                    if (mine.is_var_args) " and a variadic tail" else "",
                    theirs.params.len,
                    if (theirs.is_var_args) " and a variadic tail" else "",
                },
            )};
            continue;
        }

        const back = shapeOf(mine.return_type.?);
        const theirBack = shapeOf(theirs.return_type.?);
        if (!agrees(back, theirBack)) list = list ++ [_][]const u8{std.fmt.comptimePrint(
            "{s}: returns {s}, the header returns {s}",
            .{ where, describe(back), describe(theirBack) },
        )};

        for (mine.params, theirs.params, 1..) |ours, other, at| {
            const one = shapeOf(ours.type.?);
            const two = shapeOf(other.type.?);
            if (agrees(one, two)) continue;

            list = list ++ [_][]const u8{std.fmt.comptimePrint(
                "{s}: parameter {d} is {s}, the header says {s}",
                .{ where, at, describe(one), describe(two) },
            )};
        }
    }

    for (layouts) |entry| {
        const mine = @typeInfo(entry.mine).@"struct".fields;
        const theirs = @typeInfo(entry.theirs).@"struct".fields;

        if (@sizeOf(entry.mine) != @sizeOf(entry.theirs) or mine.len != theirs.len) {
            list = list ++ [_][]const u8{std.fmt.comptimePrint(
                "wayland/c.zig {s}: {d} fields in {d} bytes, the header has {d} in {d}",
                .{
                    entry.name,
                    mine.len,
                    @sizeOf(entry.mine),
                    theirs.len,
                    @sizeOf(entry.theirs),
                },
            )};
            continue;
        }

        for (mine, theirs) |ours, other| {
            const at = @offsetOf(entry.mine, ours.name);
            const there = @offsetOf(entry.theirs, other.name);
            if (at == there and agrees(shapeOf(ours.type), shapeOf(other.type))) continue;

            list = list ++ [_][]const u8{std.fmt.comptimePrint(
                "wayland/c.zig {s}.{s}: {s} at byte {d}, the header has {s} at byte {d}",
                .{
                    entry.name,
                    ours.name,
                    describe(shapeOf(ours.type)),
                    at,
                    describe(shapeOf(other.type)),
                    there,
                },
            )};
        }
    }
    break :found list;
};

test "the wayland bindings agree with wayland-client.h" {
    if (problems.len == 0) return;

    for (problems) |one| std.debug.print("{s}\n", .{one});
    return error.BindingsDrifted;
}
