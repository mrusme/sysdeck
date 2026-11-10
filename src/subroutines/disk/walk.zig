const std = @import("std");
const gio = @import("../../gtk/gio.zig");
const glib = @import("../../gtk/glib.zig");
const location_mod = @import("location.zig");
const store_mod = @import("core").store;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const Location = location_mod.Location;

const default_mime = "application/octet-stream";

pub fn collect(arena: Allocator, io: std.Io, self: Location) ![]store_mod.Record {
    var root = try Dir.cwd().openDir(io, self.root, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walkSelectively(arena);
    defer walker.deinit();

    var records: std.ArrayList(store_mod.Record) = .empty;

    while (true) {
        const found = walker.next(io) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const entry = found orelse break;

        if (!self.hidden and entry.basename[0] == '.') continue;
        if (self.excluded(entry.path, entry.basename)) continue;

        var kind = entry.kind;
        var size: u64 = 0;

        if (kind == .directory) {
            walker.enter(io, entry) catch {};
        } else {
            const info = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            kind = info.kind;
            size = info.size;
        }

        const mime = switch (kind) {
            .directory => block: {
                size = 0;
                break :block location_mod.directory_mime;
            },
            .file => try mimeOf(arena, entry.basename),
            else => continue,
        };
        if (!self.wants(mime)) continue;

        const full = try std.Io.Dir.path.join(arena, &.{ self.root, entry.path });
        try records.append(arena, .{
            .adapter = self.id,
            .key = full,
            .title = full[full.len - entry.basename.len ..],
            .detail = full,
            .icon = "",
            .haystack = full[full.len - entry.path.len ..],
            .mime = mime,
            .size = size,
        });
    }

    return records.toOwnedSlice(arena);
}

fn mimeOf(arena: Allocator, basename: [:0]const u8) Allocator.Error![]const u8 {
    const kind = gio.g_content_type_guess(basename.ptr, null, 0, null) orelse return default_mime;
    defer glib.g_free(kind);

    const mime = gio.g_content_type_get_mime_type(kind) orelse return default_mime;
    defer glib.g_free(mime);

    return arena.dupe(u8, std.mem.span(mime));
}

const testing = std.testing;

const Tree = struct {
    tmp: testing.TmpDir,
    root: []const u8,

    fn make(arena: Allocator) !Tree {
        const io = testing.io;

        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();

        try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "one" });
        try tmp.dir.writeFile(io, .{ .sub_path = "photo.png", .data = "two" });
        try tmp.dir.writeFile(io, .{ .sub_path = ".hidden.txt", .data = "three" });

        try tmp.dir.createDirPath(io, ".cache");
        try tmp.dir.writeFile(io, .{ .sub_path = ".cache/inside.txt", .data = "four" });

        try tmp.dir.createDirPath(io, "sub");
        try tmp.dir.writeFile(io, .{ .sub_path = "sub/deep.txt", .data = "fivex" });

        try tmp.dir.createDirPath(io, "sub/node_modules");
        try tmp.dir.writeFile(io, .{ .sub_path = "sub/node_modules/left.txt", .data = "six" });

        try tmp.dir.symLink(io, "notes.txt", "link.txt", .{});
        try tmp.dir.symLink(io, "sub", "shortcut", .{});

        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buffer);

        return .{ .tmp = tmp, .root = try arena.dupe(u8, buffer[0..length]) };
    }

    fn cleanup(self: *Tree) void {
        self.tmp.cleanup();
    }
};

fn recordOf(records: []const store_mod.Record, haystack: []const u8) ?store_mod.Record {
    for (records) |record| {
        if (std.mem.eql(u8, record.haystack, haystack)) return record;
    }
    return null;
}

fn collected(arena: Allocator, self: Location) ![]store_mod.Record {
    return collect(arena, testing.io, self);
}

test "a tree is walked and every entry becomes a record" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();

    var tree = try Tree.make(scratch);
    defer tree.cleanup();

    const records = try collected(scratch, .{ .id = "files", .root = tree.root });

    const notes = recordOf(records, "notes.txt").?;
    try testing.expectEqualStrings("files", notes.adapter);
    try testing.expectEqualStrings("notes.txt", notes.title);
    try testing.expectEqualStrings("text/plain", notes.mime);
    try testing.expectEqual(@as(u64, 3), notes.size);
    try testing.expectEqualStrings(notes.key, notes.detail);
    try testing.expect(std.mem.startsWith(u8, notes.key, tree.root));
    try testing.expect(std.mem.endsWith(u8, notes.key, "/notes.txt"));

    const photo = recordOf(records, "photo.png").?;
    try testing.expectEqualStrings("image/png", photo.mime);

    const sub = recordOf(records, "sub").?;
    try testing.expectEqualStrings("inode/directory", sub.mime);
    try testing.expectEqual(@as(u64, 0), sub.size);

    const deep = recordOf(records, "sub/deep.txt").?;
    try testing.expectEqualStrings("deep.txt", deep.title);
    try testing.expectEqual(@as(u64, 5), deep.size);
}

test "a dotfile and a dot directory are left out unless they are asked for" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();

    var tree = try Tree.make(scratch);
    defer tree.cleanup();

    const plain = try collected(scratch, .{ .id = "files", .root = tree.root });
    try testing.expectEqual(@as(?store_mod.Record, null), recordOf(plain, ".hidden.txt"));
    try testing.expectEqual(@as(?store_mod.Record, null), recordOf(plain, ".cache"));
    try testing.expectEqual(@as(?store_mod.Record, null), recordOf(plain, ".cache/inside.txt"));

    const all = try collected(scratch, .{ .id = "files", .root = tree.root, .hidden = true });
    try testing.expect(recordOf(all, ".hidden.txt") != null);
    try testing.expect(recordOf(all, ".cache/inside.txt") != null);
}

test "an excluded directory is neither indexed nor walked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();

    var tree = try Tree.make(scratch);
    defer tree.cleanup();

    const records = try collected(scratch, .{
        .id = "files",
        .root = tree.root,
        .exclude = &.{"node_modules"},
    });

    try testing.expectEqual(@as(?store_mod.Record, null), recordOf(records, "sub/node_modules"));
    try testing.expectEqual(
        @as(?store_mod.Record, null),
        recordOf(records, "sub/node_modules/left.txt"),
    );
    try testing.expect(recordOf(records, "sub/deep.txt") != null);
}

test "a symlink to a file is a record and a symlink to a directory is not walked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();

    var tree = try Tree.make(scratch);
    defer tree.cleanup();

    const records = try collected(scratch, .{ .id = "files", .root = tree.root });

    const link = recordOf(records, "link.txt").?;
    try testing.expectEqualStrings("text/plain", link.mime);
    try testing.expectEqual(@as(u64, 3), link.size);

    const shortcut = recordOf(records, "shortcut").?;
    try testing.expectEqualStrings("inode/directory", shortcut.mime);
    try testing.expectEqual(@as(u64, 0), shortcut.size);
    try testing.expectEqual(
        @as(?store_mod.Record, null),
        recordOf(records, "shortcut/deep.txt"),
    );
}

test "only keeps the types that were asked for, and folders are still walked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();

    var tree = try Tree.make(scratch);
    defer tree.cleanup();

    const images = try collected(scratch, .{
        .id = "files",
        .root = tree.root,
        .only = &.{"image/*"},
    });

    try testing.expectEqual(@as(usize, 1), images.len);
    try testing.expectEqualStrings("photo.png", images[0].title);

    const text = try collected(scratch, .{
        .id = "files",
        .root = tree.root,
        .only = &.{"text/plain"},
    });

    try testing.expect(recordOf(text, "sub/deep.txt") != null);
    try testing.expectEqual(@as(?store_mod.Record, null), recordOf(text, "sub"));
}

test "a root that is not there is reported rather than read as empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.FileNotFound, collected(arena.allocator(), .{
        .id = "gone",
        .root = "/nonexistent/sysdeck/location",
    }));
}
