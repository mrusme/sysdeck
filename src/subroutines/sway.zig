const std = @import("std");
const box = @import("../screenshot/box.zig");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const list = @import("../ui/list.zig");
const rank = @import("core").rank;
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.sway);

pub const table = tables.sway;

const max_rows = 200;
const max_reply = 8 << 20;
const magic = "i3-ipc";
const header_len = magic.len + 8;

const icon_names = [_][:0]const u8{ "preferences-system-windows", "window", "application-x-executable" };

pub const Message = enum(u32) {
    run_command = 0,
    get_tree = 4,
};

pub const Index = struct {
    io: std.Io,
    socket_path: []const u8,
    icon: [:0]const u8,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Index) };
    }

    pub fn run(self: *Index, gpa: Allocator, query_text: []const u8) subroutines.Error!subroutines.Output {
        const reply = request(gpa, self.io, self.socket_path, .get_tree, "") catch |err| {
            log.warn("cannot read the tree: {t}", .{err});
            return .nothing;
        };
        defer gpa.free(reply);

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), reply, .{}) catch {
            return .nothing;
        };

        var found: std.ArrayList(Window) = .empty;
        collect(arena.allocator(), parsed.value, &found) catch return .nothing;
        if (found.items.len == 0) return .nothing;

        const query = std.mem.trim(u8, query_text, " \t");
        const haystacks = try arena.allocator().alloc([]const u8, found.items.len);
        for (found.items, 0..) |window, at| {
            haystacks[at] = try std.mem.concat(
                arena.allocator(),
                u8,
                &.{ window.name, " ", window.app_id },
            );
        }

        const matches = try rank.rank(gpa, haystacks, null, query);
        defer gpa.free(matches);
        if (matches.len == 0) return .nothing;

        const shown = matches[0..@min(matches.len, max_rows)];
        const hits = try gpa.alloc(subroutines.Hit, shown.len);
        errdefer gpa.free(hits);

        for (shown, 0..) |match, at| {
            const window = found.items[match.index];
            hits[at] = .{
                .row = .{
                    .id = @bitCast(window.id),
                    .icon = try iconFor(gpa, window.app_id, self.icon),
                    .title = try gpa.dupeZ(u8, window.name),
                    .detail = try gpa.dupeZ(u8, window.app_id),
                },
                .score = match.score,
            };
        }

        return .{ .hits = hits };
    }

    pub fn stale(_: *Index) bool {
        return false;
    }

    pub fn refresh(_: *Index) void {}

    pub fn retire(_: *Index, _: ?*store_mod.Store) void {}

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        var payload: [64]u8 = undefined;
        const con: i64 = @bitCast(id);
        const line = std.fmt.bufPrint(&payload, "[con_id={d}] focus", .{con}) catch return .keep;

        if (!self.command(gpa, line)) return .keep;
        return .close;
    }

    pub fn release(_: *Index, gpa: Allocator, output: subroutines.Output) void {
        switch (output) {
            .nothing, .marks, .answer => {},
            .hits => |hits| {
                for (hits) |hit| {
                    gpa.free(hit.row.title);
                    gpa.free(hit.row.detail);
                    switch (hit.row.icon) {
                        .gicon => |icon| glib.g_object_unref(icon),
                        else => {},
                    }
                }
                gpa.free(hits);
            },
        }
    }

    pub fn windowFor(self: *Index, gpa: Allocator, pids: []const i32) ?i64 {
        const reply = request(gpa, self.io, self.socket_path, .get_tree, "") catch |err| {
            log.warn("cannot read the tree: {t}", .{err});
            return null;
        };
        defer gpa.free(reply);

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            arena.allocator(),
            reply,
            .{},
        ) catch return null;

        var found: std.ArrayList(Window) = .empty;
        collect(arena.allocator(), parsed.value, &found) catch return null;

        for (pids) |pid| {
            for (found.items) |window| {
                if (window.pid == pid) return window.id;
            }
        }
        return null;
    }

    pub fn boxes(self: *Index, gpa: Allocator, skip: i32, out: *std.ArrayList(box.Box)) void {
        const reply = request(gpa, self.io, self.socket_path, .get_tree, "") catch |err| {
            log.warn("cannot read the tree: {t}", .{err});
            return;
        };
        defer gpa.free(reply);

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            arena.allocator(),
            reply,
            .{},
        ) catch return;

        var found: std.ArrayList(Window) = .empty;
        collect(arena.allocator(), parsed.value, &found) catch return;

        for (found.items) |window| {
            if (window.pid == skip) continue;
            if (!window.visible or window.rect.empty()) continue;
            out.append(gpa, window.rect) catch return;
        }
    }

    pub fn focusWindow(self: *Index, gpa: Allocator, con: i64) bool {
        var payload: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&payload, "[con_id={d}] focus", .{con}) catch return false;
        return self.command(gpa, line);
    }

    fn command(self: *Index, gpa: Allocator, payload: []const u8) bool {
        const reply = request(gpa, self.io, self.socket_path, .run_command, payload) catch |err| {
            log.warn("cannot run \"{s}\": {t}", .{ payload, err });
            return false;
        };
        defer gpa.free(reply);

        return succeeded(gpa, reply);
    }
};

pub fn enabled(configured: ?bool, environ: *const std.process.Environ.Map) bool {
    if (configured) |wanted| return wanted;
    const socket_path = environ.get("SWAYSOCK") orelse return false;
    return socket_path.len > 0;
}

pub fn open(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) Allocator.Error!?Index {
    const found = environ.get("SWAYSOCK") orelse return null;
    if (found.len == 0) return null;

    return .{
        .io = io,
        .socket_path = try gpa.dupe(u8, found),
        .icon = windowIcon(),
    };
}

fn windowIcon() [:0]const u8 {
    const display = gdk.gdk_display_get_default() orelse return icon_names[icon_names.len - 1];
    const theme = gtk.gtk_icon_theme_get_for_display(display);

    for (icon_names) |name| {
        if (gtk.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    }
    return icon_names[icon_names.len - 1];
}

fn iconFor(gpa: Allocator, app_id: []const u8, fallback: [:0]const u8) Allocator.Error!list.Icon {
    if (app_id.len == 0) return .{ .name = fallback };

    const desktop_id = try std.fmt.allocPrintSentinel(gpa, "{s}.desktop", .{app_id}, 0);
    defer gpa.free(desktop_id);

    const info = gio.g_desktop_app_info_new(desktop_id.ptr) orelse return .{ .name = fallback };
    defer glib.g_object_unref(info);

    const icon = gio.g_app_info_get_icon(c.cast(c.GAppInfo, info)) orelse
        return .{ .name = fallback };
    return .{ .gicon = @ptrCast(glib.g_object_ref(icon)) };
}

pub const Window = struct {
    id: i64,
    pid: i32,
    name: []const u8,
    app_id: []const u8,
    rect: box.Box,
    visible: bool,
};

pub fn collect(arena: Allocator, node: std.json.Value, out: *std.ArrayList(Window)) Allocator.Error!void {
    const fields = switch (node) {
        .object => |object| object,
        else => return,
    };

    if (windowOf(fields)) |window| try out.append(arena, window);

    for ([_][]const u8{ "nodes", "floating_nodes" }) |branch| {
        const children = fields.get(branch) orelse continue;
        const items = switch (children) {
            .array => |array| array.items,
            else => continue,
        };
        for (items) |child| try collect(arena, child, out);
    }
}

fn windowOf(fields: std.json.ObjectMap) ?Window {
    const pid = switch (fields.get("pid") orelse return null) {
        .integer => |value| value,
        else => return null,
    };

    const id = switch (fields.get("id") orelse return null) {
        .integer => |value| value,
        else => return null,
    };

    return .{
        .id = id,
        .pid = std.math.cast(i32, pid) orelse return null,
        .name = text(fields, "name"),
        .app_id = appId(fields),
        .rect = rectOf(fields),
        .visible = flag(fields, "visible"),
    };
}

fn rectOf(fields: std.json.ObjectMap) box.Box {
    const found = switch (fields.get("rect") orelse return .{ .x = 0, .y = 0, .width = 0, .height = 0 }) {
        .object => |object| object,
        else => return .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };

    return .{
        .x = number(found, "x"),
        .y = number(found, "y"),
        .width = number(found, "width"),
        .height = number(found, "height"),
    };
}

fn number(fields: std.json.ObjectMap, key: []const u8) i32 {
    return switch (fields.get(key) orelse return 0) {
        .integer => |value| std.math.cast(i32, value) orelse 0,
        else => 0,
    };
}

fn flag(fields: std.json.ObjectMap, key: []const u8) bool {
    return switch (fields.get(key) orelse return false) {
        .bool => |value| value,
        else => false,
    };
}

fn appId(fields: std.json.ObjectMap) []const u8 {
    const found = text(fields, "app_id");
    if (found.len > 0) return found;

    const properties = switch (fields.get("window_properties") orelse return "") {
        .object => |object| object,
        else => return "",
    };
    return text(properties, "class");
}

fn text(fields: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (fields.get(key) orelse return "") {
        .string => |value| value,
        else => "",
    };
}

pub fn frame(buffer: *[header_len]u8, kind: Message, length: u32) void {
    @memcpy(buffer[0..magic.len], magic);
    std.mem.writeInt(u32, buffer[magic.len..][0..4], length, .little);
    std.mem.writeInt(u32, buffer[magic.len + 4 ..][0..4], @intFromEnum(kind), .little);
}

pub const Header = struct {
    length: u32,
    kind: u32,
};

pub fn parseHeader(bytes: []const u8) ?Header {
    if (bytes.len < header_len) return null;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return null;

    return .{
        .length = std.mem.readInt(u32, bytes[magic.len..][0..4], .little),
        .kind = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little),
    };
}

const Error = error{ Unreachable, Refused, Malformed, TooLarge } || Allocator.Error;

fn request(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    kind: Message,
    payload: []const u8,
) Error![]u8 {
    const address = std.Io.net.UnixAddress.init(path) catch return error.Unreachable;

    const stream = address.connect(io) catch return error.Refused;
    defer stream.close(io);

    var head: [header_len]u8 = undefined;
    frame(&head, kind, @intCast(payload.len));

    var sending: [header_len]u8 = undefined;
    var out = stream.writer(io, &sending);
    out.interface.writeAll(&head) catch return error.Refused;
    out.interface.writeAll(payload) catch return error.Refused;
    out.interface.flush() catch return error.Refused;

    var receiving: [header_len]u8 = undefined;
    var in = stream.reader(io, &receiving);

    var reply: [header_len]u8 = undefined;
    in.interface.readSliceAll(&reply) catch return error.Malformed;

    const header = parseHeader(&reply) orelse return error.Malformed;
    if (header.length > max_reply) return error.TooLarge;

    const body = try gpa.alloc(u8, header.length);
    errdefer gpa.free(body);

    in.interface.readSliceAll(body) catch return error.Malformed;
    return body;
}

fn succeeded(gpa: Allocator, reply: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, reply, .{}) catch return false;
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return false,
    };
    if (items.len == 0) return false;

    const first = switch (items[0]) {
        .object => |object| object,
        else => return false,
    };
    return switch (first.get("success") orelse return false) {
        .bool => |value| value,
        else => false,
    };
}

const testing = std.testing;

test "a request is framed the way sway expects" {
    var buffer: [header_len]u8 = undefined;
    frame(&buffer, .get_tree, 0);

    try testing.expectEqualStrings("i3-ipc", buffer[0..6]);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buffer[6..10], .little));
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, buffer[10..14], .little));

    frame(&buffer, .run_command, 15);
    try testing.expectEqual(@as(u32, 15), std.mem.readInt(u32, buffer[6..10], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buffer[10..14], .little));
}

test "a reply header is read back" {
    var buffer: [header_len]u8 = undefined;
    frame(&buffer, .get_tree, 4436);

    const header = parseHeader(&buffer).?;
    try testing.expectEqual(@as(u32, 4436), header.length);
    try testing.expectEqual(@as(u32, 4), header.kind);
}

test "a header that is short or wrong is refused" {
    var buffer: [header_len]u8 = undefined;
    frame(&buffer, .get_tree, 0);

    try testing.expectEqual(@as(?Header, null), parseHeader(buffer[0 .. header_len - 1]));

    buffer[0] = 'x';
    try testing.expectEqual(@as(?Header, null), parseHeader(&buffer));
}

fn walked(arena: Allocator, source: []const u8) []const Window {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, source, .{}) catch unreachable;
    var found: std.ArrayList(Window) = .empty;
    collect(arena, parsed.value, &found) catch unreachable;
    return found.items;
}

const tree =
    \\{"type":"root","name":"root","nodes":[
    \\  {"type":"output","name":"HEADLESS-1","nodes":[
    \\    {"type":"workspace","name":"1","nodes":[
    \\      {"id":5,"type":"con","name":"Find Files/Folders","app_id":"org.kde.kfind","pid":131633,
    \\       "visible":true,"rect":{"x":0,"y":0,"width":640,"height":800}},
    \\      {"id":7,"type":"con","name":"Xterm","app_id":null,"pid":900,"visible":false,
    \\       "rect":{"x":640,"y":0,"width":640,"height":800},
    \\       "window_properties":{"class":"XTerm","instance":"xterm"}}
    \\    ],"floating_nodes":[
    \\      {"id":9,"type":"con","name":"Floater","app_id":"foot","pid":901,"visible":true,
    \\       "rect":{"x":100,"y":100,"width":400,"height":300}}
    \\    ]}
    \\  ]}
    \\]}
;

test "the tree walk finds windows at any depth" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = walked(arena.allocator(), tree);

    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqual(@as(i64, 5), found[0].id);
    try testing.expectEqualStrings("Find Files/Folders", found[0].name);
    try testing.expectEqualStrings("org.kde.kfind", found[0].app_id);
    try testing.expectEqual(@as(i32, 131633), found[0].pid);
}

test "an xwayland window falls back to its class" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = walked(arena.allocator(), tree);
    try testing.expectEqualStrings("XTerm", found[1].app_id);
}

test "a floating window is found too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = walked(arena.allocator(), tree);
    try testing.expectEqualStrings("Floater", found[2].name);
    try testing.expectEqualStrings("foot", found[2].app_id);
}

test "a window carries its rectangle and whether it is shown" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = walked(arena.allocator(), tree);

    try testing.expect(found[0].visible);
    try testing.expectEqual(@as(i32, 0), found[0].rect.x);
    try testing.expectEqual(@as(i32, 640), found[0].rect.width);
    try testing.expectEqual(@as(i32, 800), found[0].rect.height);

    try testing.expect(!found[1].visible);

    try testing.expect(found[2].visible);
    try testing.expectEqual(@as(i32, 100), found[2].rect.x);
    try testing.expectEqual(@as(i32, 400), found[2].rect.width);
}

test "a window with no rectangle reads as empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const bare =
        \\{"id":3,"type":"con","name":"Bare","app_id":"none","pid":7}
    ;
    const found = walked(arena.allocator(), bare);

    try testing.expect(found[0].rect.empty());
    try testing.expect(!found[0].visible);
}

test "a tree with no windows yields none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const bare =
        \\{"type":"root","nodes":[{"type":"output","name":"HEADLESS-1","nodes":[
        \\  {"type":"workspace","name":"1","nodes":[],"floating_nodes":[]}]}]}
    ;
    try testing.expectEqual(@as(usize, 0), walked(arena.allocator(), bare).len);
}

test "a run_command reply is read for success" {
    try testing.expect(succeeded(testing.allocator, "[{\"success\": true}]"));
    try testing.expect(!succeeded(testing.allocator, "[{\"success\": false}]"));
    try testing.expect(!succeeded(testing.allocator, "[]"));
    try testing.expect(!succeeded(testing.allocator, "not json"));
}
