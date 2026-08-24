const std = @import("std");
const c = @import("../c.zig");
const list = @import("../list.zig");
const rank = @import("../rank.zig");
const store_mod = @import("../store.zig");
const subroutines = @import("../subroutines.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.sway);

pub const table = "sway";

const max_rows = 200;
const max_reply = 8 << 20;
const magic = "i3-ipc";
const header_len = magic.len + 8;

const icon_names = [_][:0]const u8{ "preferences-system-windows", "window", "application-x-executable" };

const libc = struct {
    extern fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
    extern fn connect(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    extern fn read(fd: c_int, buffer: [*]u8, count: usize) isize;
    extern fn write(fd: c_int, buffer: [*]const u8, count: usize) isize;
    extern fn close(fd: c_int) c_int;
};

pub const Message = enum(u32) {
    run_command = 0,
    get_tree = 4,
};

pub const Index = struct {
    socket_path: [:0]const u8,
    icon: [:0]const u8,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = &vtable };
    }

    // A pid only matches when it is the process that created the surface, and
    // an application that spreads over several processes has just one of those.
    // The tree says which, so the con id is what actually gets focused.
    pub fn windowFor(self: *Index, gpa: Allocator, pids: []const i32) ?i64 {
        const reply = request(gpa, self.socket_path, .get_tree, "") catch |err| {
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

    pub fn focusWindow(self: *Index, gpa: Allocator, con: i64) bool {
        var payload: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&payload, "[con_id={d}] focus", .{con}) catch return false;
        return self.command(gpa, line);
    }

    fn command(self: *Index, gpa: Allocator, payload: []const u8) bool {
        const reply = request(gpa, self.socket_path, .run_command, payload) catch |err| {
            log.warn("cannot run \"{s}\": {t}", .{ payload, err });
            return false;
        };
        defer gpa.free(reply);

        return succeeded(gpa, reply);
    }
};

const vtable: subroutines.Subroutine.VTable = .{
    .run = &run,
    .choose = &choose,
    .release = &release,
    .stale = &stale,
    .refresh = &refresh,
    .retire = &retire,
};

pub fn enabled(configured: ?bool, environ: *const std.process.Environ.Map) bool {
    if (configured) |wanted| return wanted;
    const socket_path = environ.get("SWAYSOCK") orelse return false;
    return socket_path.len > 0;
}

pub fn open(gpa: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?Index {
    const found = environ.get("SWAYSOCK") orelse return null;
    if (found.len == 0) return null;

    return .{
        .socket_path = try gpa.dupeZ(u8, found),
        .icon = windowIcon(),
    };
}

fn windowIcon() [:0]const u8 {
    const display = c.gdk_display_get_default() orelse return icon_names[icon_names.len - 1];
    const theme = c.gtk_icon_theme_get_for_display(display);

    for (icon_names) |name| {
        if (c.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    }
    return icon_names[icon_names.len - 1];
}

fn run(context: *anyopaque, gpa: Allocator, query_text: []const u8) subroutines.Error!subroutines.Output {
    const self: *Index = @ptrCast(@alignCast(context));

    const reply = request(gpa, self.socket_path, .get_tree, "") catch |err| {
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

fn iconFor(gpa: Allocator, app_id: []const u8, fallback: [:0]const u8) Allocator.Error!list.Icon {
    if (app_id.len == 0) return .{ .name = fallback };

    const desktop_id = try std.fmt.allocPrintSentinel(gpa, "{s}.desktop", .{app_id}, 0);
    defer gpa.free(desktop_id);

    const info = c.g_desktop_app_info_new(desktop_id.ptr) orelse return .{ .name = fallback };
    defer c.g_object_unref(info);

    const icon = c.g_app_info_get_icon(@ptrCast(info)) orelse return .{ .name = fallback };
    return .{ .gicon = @ptrCast(c.g_object_ref(icon)) };
}

fn choose(context: *anyopaque, gpa: Allocator, id: u64) subroutines.Outcome {
    const self: *Index = @ptrCast(@alignCast(context));

    var payload: [64]u8 = undefined;
    const con: i64 = @bitCast(id);
    const line = std.fmt.bufPrint(&payload, "[con_id={d}] focus", .{con}) catch return .keep;

    if (!self.command(gpa, line)) return .keep;
    return .close;
}

fn release(_: *anyopaque, gpa: Allocator, output: subroutines.Output) void {
    switch (output) {
        .nothing, .marks, .answer => {},
        .hits => |hits| {
            for (hits) |hit| {
                gpa.free(hit.row.title);
                gpa.free(hit.row.detail);
                switch (hit.row.icon) {
                    .gicon => |icon| c.g_object_unref(icon),
                    else => {},
                }
            }
            gpa.free(hits);
        },
    }
}

fn stale(_: *anyopaque) bool {
    return false;
}

fn refresh(_: *anyopaque) void {}

fn retire(_: *anyopaque, _: ?*store_mod.Store) void {}

pub const Window = struct {
    id: i64,
    pid: i32,
    name: []const u8,
    app_id: []const u8,
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

fn request(gpa: Allocator, path: [:0]const u8, kind: Message, payload: []const u8) Error![]u8 {
    const fd = libc.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.Unreachable;
    defer _ = libc.close(fd);

    var address: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    if (path.len >= address.path.len) return error.Unreachable;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);

    if (libc.connect(fd, &address, @sizeOf(@TypeOf(address))) < 0) return error.Refused;

    var head: [header_len]u8 = undefined;
    frame(&head, kind, @intCast(payload.len));
    try sendAll(fd, &head);
    try sendAll(fd, payload);

    var reply: [header_len]u8 = undefined;
    try receiveAll(fd, &reply);

    const header = parseHeader(&reply) orelse return error.Malformed;
    if (header.length > max_reply) return error.TooLarge;

    const body = try gpa.alloc(u8, header.length);
    errdefer gpa.free(body);

    try receiveAll(fd, body);
    return body;
}

fn sendAll(fd: c_int, bytes: []const u8) Error!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const wrote = libc.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (wrote <= 0) return error.Refused;
        sent += @intCast(wrote);
    }
}

fn receiveAll(fd: c_int, bytes: []u8) Error!void {
    var taken: usize = 0;
    while (taken < bytes.len) {
        const got = libc.read(fd, bytes.ptr + taken, bytes.len - taken);
        if (got <= 0) return error.Malformed;
        taken += @intCast(got);
    }
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
    \\      {"id":5,"type":"con","name":"Find Files/Folders","app_id":"org.kde.kfind","pid":131633},
    \\      {"id":7,"type":"con","name":"Xterm","app_id":null,"pid":900,
    \\       "window_properties":{"class":"XTerm","instance":"xterm"}}
    \\    ],"floating_nodes":[
    \\      {"id":9,"type":"con","name":"Floater","app_id":"foot","pid":901}
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
