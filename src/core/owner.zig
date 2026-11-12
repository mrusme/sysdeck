const std = @import("std");

const Permissions = std.Io.File.Permissions;
const log = std.log.scoped(.owner);

pub const supported = Permissions.has_executable_bit;
pub const folder: Permissions = if (supported) .fromMode(0o700) else .default_dir;
pub const file: Permissions = if (supported) .fromMode(0o600) else .default_file;

pub fn narrowFolder(io: std.Io, opened: std.Io.Dir, name: []const u8) void {
    const info = opened.stat(io) catch return;
    const wanted = narrowed(info.permissions) orelse return;

    opened.setPermissions(io, wanted) catch |err| {
        log.warn("cannot restrict {s} to its owner: {t}", .{ name, err });
    };
}

pub fn narrowFile(io: std.Io, path: []const u8) void {
    const opened = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer opened.close(io);

    const info = opened.stat(io) catch return;
    const wanted = narrowed(info.permissions) orelse return;

    opened.setPermissions(io, wanted) catch |err| {
        log.warn("cannot restrict {s} to its owner: {t}", .{ path, err });
    };
}

fn narrowed(permissions: Permissions) ?Permissions {
    if (comptime !supported) return null;

    const mode = permissions.toMode();
    if (mode & 0o077 == 0) return null;
    return .fromMode(mode & 0o700);
}
