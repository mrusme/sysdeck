const std = @import("std");
const xdg = @import("core").xdg;
const adapters = @import("../adapter.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.bookmarks);

pub const name = "chromium";

const max_file_bytes = 16 << 20;
const max_folders = 100;
const separator = "/";

pub const Adapter = struct {
    io: std.Io,
    home: []const u8,
    files: []const []const u8,
    max_age_minutes: i64,

    pub fn adapter(self: *Adapter) adapters.Adapter {
        return .{
            .name = name,
            .max_age_minutes = self.max_age_minutes,
            .context = self,
            .vtable = adapters.vtableOf(Adapter),
        };
    }

    pub fn collect(self: *Adapter, arena: Allocator) Allocator.Error!adapters.Collected {
        var links: std.ArrayList(adapters.Link) = .empty;
        var complete = true;

        for (self.files) |file| {
            const path = try xdg.expand(arena, self.home, file);

            const text = Dir.cwd().readFileAlloc(
                self.io,
                path,
                arena,
                .limited(max_file_bytes),
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    log.debug("{s} is not there", .{path});
                    continue;
                },
                else => {
                    log.warn("cannot read {s}: {t}", .{ path, err });
                    complete = false;
                    continue;
                },
            };

            parse(arena, text, &links) catch |err| switch (err) {
                error.OutOfMemory => |leftover| return leftover,
                else => {
                    log.warn("cannot read the bookmarks in {s}: {t}", .{ path, err });
                    complete = false;
                },
            };
        }

        return .{ .links = try links.toOwnedSlice(arena), .complete = complete };
    }
};

fn parse(arena: Allocator, text: []const u8, out: *std.ArrayList(adapters.Link)) !void {
    const document = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});

    const roots = switch (document) {
        .object => |fields| fields.get("roots") orelse return error.Malformed,
        else => return error.Malformed,
    };

    const folders = switch (roots) {
        .object => |found| found,
        else => return error.Malformed,
    };

    for (folders.values()) |root| try walk(arena, root, "", 0, out);
}

fn walk(
    arena: Allocator,
    node: std.json.Value,
    folder: []const u8,
    depth: usize,
    out: *std.ArrayList(adapters.Link),
) Allocator.Error!void {
    const children = switch (node) {
        .object => |fields| fields.get("children") orelse return,
        else => return,
    };

    const items = switch (children) {
        .array => |found| found.items,
        else => return,
    };

    for (items) |child| {
        const fields = switch (child) {
            .object => |found| found,
            else => continue,
        };

        const kind = textOf(fields, "type");

        if (std.mem.eql(u8, kind, "url")) {
            try out.append(arena, .{
                .url = textOf(fields, "url"),
                .name = textOf(fields, "name"),
                .folder = folder,
            });
            continue;
        }

        if (!std.mem.eql(u8, kind, "folder")) continue;
        if (depth == max_folders) {
            log.warn("the bookmarks in \"{s}\" are nested more than {d} folders deep, so they are left out", .{
                folder,
                max_folders,
            });
            continue;
        }
        try walk(arena, child, try nest(arena, folder, textOf(fields, "name")), depth + 1, out);
    }
}

fn nest(arena: Allocator, folder: []const u8, folder_name: []const u8) Allocator.Error![]const u8 {
    if (folder_name.len == 0) return folder;
    if (folder.len == 0) return folder_name;

    return arena.print("{s}" ++ separator ++ "{s}", .{ folder, folder_name });
}

fn textOf(fields: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (fields.get(key) orelse return "") {
        .string => |text| text,
        else => "",
    };
}

const testing = std.testing;

const fixture =
    \\{
    \\  "checksum": "0123456789abcdef",
    \\  "roots": {
    \\    "bookmark_bar": {
    \\      "children": [
    \\        { "date_added": "13300000000000000", "type": "url", "name": "Zig",
    \\          "url": "https://ziglang.org" },
    \\        {
    \\          "type": "folder",
    \\          "name": "Dev",
    \\          "children": [
    \\            { "type": "url", "name": "SQLite", "url": "https://sqlite.org" },
    \\            {
    \\              "type": "folder",
    \\              "name": "Languages",
    \\              "children": [
    \\                { "type": "url", "name": "", "url": "https://example.com/unnamed" }
    \\              ]
    \\            },
    \\            { "type": "folder", "name": "Empty", "children": [] }
    \\          ]
    \\        }
    \\      ],
    \\      "name": "Bookmark bar",
    \\      "type": "folder"
    \\    },
    \\    "other": {
    \\      "children": [
    \\        { "type": "url", "name": "Print",
    \\          "url": "javascript:(function(){window.print()})()" },
    \\        { "type": "url", "name": "GTK", "url": "https://gtk.org" }
    \\      ],
    \\      "name": "Other bookmarks",
    \\      "type": "folder"
    \\    },
    \\    "synced": { "children": [], "name": "Mobile bookmarks", "type": "folder" },
    \\    "sync_transaction_version": "1"
    \\  },
    \\  "version": 1
    \\}
;

fn expectLinks(text: []const u8, expected: []const adapters.Link) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var found: std.ArrayList(adapters.Link) = .empty;
    try parse(arena.allocator(), text, &found);

    try testing.expectEqual(expected.len, found.items.len);
    for (expected, found.items) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.url, got.url);
        try testing.expectEqualStrings(want.folder, got.folder);
    }
}

test "every bookmark in the tree is found, whatever root it is under" {
    try expectLinks(fixture, &.{
        .{ .name = "Zig", .url = "https://ziglang.org", .folder = "" },
        .{ .name = "SQLite", .url = "https://sqlite.org", .folder = "Dev" },
        .{ .name = "", .url = "https://example.com/unnamed", .folder = "Dev/Languages" },
        .{ .name = "Print", .url = "javascript:(function(){window.print()})()", .folder = "" },
        .{ .name = "GTK", .url = "https://gtk.org", .folder = "" },
    });
}

test "a folder without a name does not lengthen the path" {
    try expectLinks(
        \\{"roots": {"other": {"children": [
        \\  {"type": "folder", "children": [
        \\    {"type": "url", "name": "Zig", "url": "https://ziglang.org"}
        \\  ]}
        \\]}}}
    , &.{.{ .name = "Zig", .url = "https://ziglang.org", .folder = "" }});
}

test "a node that is neither a url nor a folder is skipped" {
    try expectLinks(
        \\{"roots": {"other": {"children": [
        \\  {"type": "url", "name": "No url"},
        \\  {"name": "No type", "url": "https://example.com"},
        \\  "a string",
        \\  {"type": "folder", "name": "Dev", "children": {"not": "an array"}},
        \\  {"type": "url", "name": "Zig", "url": "https://ziglang.org"}
        \\]}}}
    , &.{
        .{ .name = "No url", .url = "", .folder = "" },
        .{ .name = "Zig", .url = "https://ziglang.org", .folder = "" },
    });
}

test "a file that is not a bookmarks file is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var found: std.ArrayList(adapters.Link) = .empty;

    try testing.expectError(
        error.SyntaxError,
        parse(arena.allocator(), "not json at all", &found),
    );
    try testing.expectError(
        error.Malformed,
        parse(arena.allocator(), "{\"version\": 1}", &found),
    );
    try testing.expectError(
        error.Malformed,
        parse(arena.allocator(), "{\"roots\": []}", &found),
    );
    try testing.expectError(
        error.Malformed,
        parse(arena.allocator(), "[]", &found),
    );
    try testing.expectEqual(0, found.items.len);
}

fn nested(arena: Allocator, depth: usize) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "{\"roots\": {\"other\": {\"children\": [");
    for (0..depth) |_| try text.appendSlice(arena, "{\"type\": \"folder\", \"name\": \"f\", \"children\": [");
    try text.appendSlice(arena, "{\"type\": \"url\", \"name\": \"deep\", \"url\": \"https://deep.example\"}");
    for (0..depth) |_| try text.appendSlice(arena, "]}");
    try text.appendSlice(arena, "]}}}");
    return text.items;
}

test "bookmarks are read down to 100 folders deep and no further" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var kept: std.ArrayList(adapters.Link) = .empty;
    try parse(arena.allocator(), try nested(arena.allocator(), max_folders), &kept);
    try testing.expectEqual(1, kept.items.len);

    var dropped: std.ArrayList(adapters.Link) = .empty;
    try parse(arena.allocator(), try nested(arena.allocator(), max_folders + 1), &dropped);
    try testing.expectEqual(0, dropped.items.len);
}

test "an empty tree gives no bookmarks" {
    try expectLinks("{\"roots\": {}}", &.{});
    try expectLinks("{\"roots\": {\"other\": {\"children\": []}}}", &.{});
}

fn completed(arena: Allocator, root: []const u8, file: []const u8) !bool {
    var adapter: Adapter = .{
        .io = testing.io,
        .home = "",
        .files = &.{try std.Io.Dir.path.join(arena, &.{ root, file })},
        .max_age_minutes = 60,
    };
    return (try adapter.collect(arena)).complete;
}

test "a bookmarks file that is not there is skipped, and one that cannot be read is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buffer[0..try xdg.tmpRoot(&tmp, &buffer)];
    try tmp.dir.createDir(testing.io, "Bookmarks", .default_dir);

    try testing.expect(try completed(arena.allocator(), root, "Gone"));
    try testing.expect(!try completed(arena.allocator(), root, "Bookmarks"));
}
