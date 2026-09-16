const std = @import("std");
const c = @import("../gtk/c.zig");
const copy = @import("../system/copy.zig");
const gdk = @import("../gtk/gdk.zig");
const gtk = @import("../gtk/gtk.zig");
const launch = @import("../system/launch.zig");
const list = @import("../ui/list.zig");
const source = @import("source.zig");
const ssh = @import("core").ssh;
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const tallied = @import("tallied.zig");
const tally = @import("core").tally;
const terminal_mod = @import("../system/terminal.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.ssh);

pub const table = tables.ssh;

const max_rows = 200;
const default_shell = "/bin/sh";
const copied_mime = "text/plain";

const icon_names = [_][:0]const u8{ "network-server", "utilities-terminal" };

const Hosts = tallied.Tallied([]const ssh.Attribute);

pub const Index = struct {
    hosts: Hosts,
    environ: *const std.process.Environ.Map,
    terminal: ?terminal_mod.Terminal,
    shell: []const u8,
    icon: [:0]const u8,
    required: bool,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Index) };
    }

    pub fn run(self: *Index, gpa: Allocator, text: []const u8) subroutines.Error!subroutines.Output {
        const icon: list.Icon = .{ .name = self.icon };
        return self.hosts.hits(gpa, text, .{ .max_rows = max_rows, .icon = icon });
    }

    pub fn picks(self: *Index, gpa: Allocator, limit: usize) subroutines.Error!subroutines.Output {
        return self.hosts.picks(gpa, limit, .{ .name = self.icon });
    }

    pub fn release(self: *Index, gpa: Allocator, output: subroutines.Output) void {
        self.hosts.release(gpa, output);
    }

    pub fn stale(_: *Index) bool {
        return true;
    }

    pub fn retire(self: *Index, store: ?*store_mod.Store) void {
        self.hosts.retire(store);
    }

    pub fn refresh(self: *Index) void {
        const home = self.environ.get("HOME") orelse "";
        if (home.len == 0) {
            if (self.required) {
                log.warn("HOME is not set, so no hosts from ~/.ssh/config are listed", .{});
            }
            return;
        }

        const catalog = self.hosts.begin() catch |err| return source.report(table, "read", err);
        const arena = catalog.allocator();

        const found = ssh.read(arena, self.hosts.io, home, self.environ) catch |err| switch (err) {
            error.FileNotFound => block: {
                if (self.required) {
                    log.warn(
                        "[sources.ssh] enable is true, however {s}/.ssh/config does not exist, " ++
                            "so no hosts are listed",
                        .{home},
                    );
                }
                break :block &.{};
            },
            else => {
                log.warn("cannot read {s}/.ssh/config: {t}, so no hosts are listed", .{
                    home,
                    err,
                });
                return self.hosts.discard(catalog);
            },
        };

        const items = itemsOf(arena, found) catch |err| {
            self.hosts.discard(catalog);
            return source.report(table, "read", err);
        };
        self.hosts.publish(catalog, items);
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        const host = self.hosts.find(id) orelse return .keep;

        const terminal = self.terminal orelse {
            log.warn("no terminal is installed, so {s} cannot be connected to", .{host.key});
            return .keep;
        };

        const command = launch.ssh_command;
        if (!launch.inTerminal(gpa, terminal, self.shell, command, host.key)) return .keep;

        self.hosts.note(id);
        return .close;
    }

    pub fn actions(
        self: *Index,
        arena: Allocator,
        id: u64,
    ) subroutines.Error![]const subroutines.Action {
        const host = self.hosts.find(id) orelse return &.{};

        const found = try arena.alloc(subroutines.Action, host.payload.len);
        for (host.payload, found, 0..) |attribute, *action, at| {
            action.* = .{
                .id = at,
                .title = try arena.dupeZ(u8, attribute.keyword),
                .detail = try arena.dupeZ(u8, attribute.value),
            };
        }
        return found;
    }

    pub fn perform(self: *Index, gpa: Allocator, id: u64, action: u64) subroutines.Outcome {
        const host = self.hosts.find(id) orelse return .keep;

        const at = std.math.cast(usize, action) orelse return .keep;
        if (at >= host.payload.len) return .keep;

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const scratch = arena.allocator();
        const line = lineOf(scratch, host.payload[at]) catch return .keep;
        if (!copy.put(scratch, self.environ, .{ .mime = copied_mime, .bytes = line })) return .keep;

        self.hosts.note(id);
        return .close;
    }
};

pub fn enabled(configured: ?bool) bool {
    return configured orelse true;
}

pub fn open(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    terminal: ?terminal_mod.Terminal,
    store: ?*store_mod.Store,
    configured: ?bool,
    published: source.Published,
) Allocator.Error!Index {
    var self: Index = .{
        .hosts = try .init(gpa, io, table, published),
        .environ = environ,
        .terminal = terminal,
        .shell = environ.get("SHELL") orelse default_shell,
        .icon = themed(),
        .required = configured == true,
    };
    self.hosts.prepare(store);
    return self;
}

fn itemsOf(arena: Allocator, found: []const ssh.Host) Allocator.Error![]Hosts.Item {
    const items = try arena.alloc(Hosts.Item, found.len);
    for (found, items) |host, *item| {
        item.* = .{
            .key = host.name,
            .title = try arena.dupeZ(u8, host.name),
            .detail = try arena.dupeZ(u8, host.address),
            .haystack = try haystackOf(arena, host),
            .payload = host.attributes,
        };
    }
    return items;
}

fn haystackOf(arena: Allocator, host: ssh.Host) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, host.name, host.address)) return host.name;
    return std.mem.concat(arena, u8, &.{ host.name, " ", host.address });
}

fn lineOf(arena: Allocator, attribute: ssh.Attribute) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ attribute.keyword, " ", attribute.value });
}

fn themed() [:0]const u8 {
    const display = gdk.gdk_display_get_default() orelse return icon_names[0];
    const theme = gtk.gtk_icon_theme_get_for_display(display);

    for (icon_names) |name| {
        if (gtk.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    }
    return icon_names[0];
}

const testing = std.testing;

const gitlab =
    \\Host gitlab.com
    \\  HostName gitlab.com
    \\  Port 22
    \\  User git
    \\  ClearAllForwardings yes
    \\  PreferredAuthentications publickey
    \\  PubkeyAuthentication yes
    \\  IdentityFile ~/.ssh/f0g6-sk2
    \\  IdentityFile ~/.ssh/f0g6-sk3
    \\
    \\Host web
    \\  User deploy
;

fn testIndex(environ: *const std.process.Environ.Map) !Index {
    var self: Index = .{
        .hosts = try .init(testing.allocator, testing.io, table, .{}),
        .environ = environ,
        .terminal = null,
        .shell = default_shell,
        .icon = icon_names[0],
        .required = false,
    };
    errdefer self.retire(null);

    const catalog = try self.hosts.begin();
    const arena = catalog.allocator();
    self.hosts.publish(catalog, try itemsOf(arena, try ssh.parse(arena, gitlab)));
    return self;
}

test "every attribute of a host is an action titled by its keyword" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self = try testIndex(&environ);
    defer self.retire(null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try self.actions(arena.allocator(), tally.id("gitlab.com"));
    try testing.expectEqual(@as(usize, 8), found.len);

    const expected = [_][2][]const u8{
        .{ "HostName", "gitlab.com" },
        .{ "Port", "22" },
        .{ "User", "git" },
        .{ "ClearAllForwardings", "yes" },
        .{ "PreferredAuthentications", "publickey" },
        .{ "PubkeyAuthentication", "yes" },
        .{ "IdentityFile", "~/.ssh/f0g6-sk2" },
        .{ "IdentityFile", "~/.ssh/f0g6-sk3" },
    };
    for (expected, found, 0..) |pair, action, at| {
        try testing.expectEqual(@as(u64, at), action.id);
        try testing.expectEqualStrings(pair[0], action.title);
        try testing.expectEqualStrings(pair[1], action.detail);
    }

    try testing.expectEqual(@as(usize, 0), (try self.actions(arena.allocator(), 42)).len);
}

test "the copied line is the keyword and the value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const line = try lineOf(arena.allocator(), .{ .keyword = "HostName", .value = "gitlab.com" });
    try testing.expectEqualStrings("HostName gitlab.com", line);
}

test "a host is matched by its name and its address, and shown with the address" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self = try testIndex(&environ);
    defer self.retire(null);

    const gpa = testing.allocator;
    try testing.expectEqual(subroutines.Output.nothing, try self.run(gpa, " "));

    const found = try self.run(gpa, "gitlab");
    defer self.release(gpa, found);

    try testing.expectEqual(@as(usize, 1), found.hits.len);
    try testing.expectEqualStrings("gitlab.com", found.hits[0].row.title);
    try testing.expectEqualStrings("gitlab.com", found.hits[0].row.detail);
    try testing.expectEqualStrings("network-server", found.hits[0].row.icon.name);

    const web = try self.run(gpa, "web");
    defer self.release(gpa, web);
    try testing.expectEqualStrings("web", web.hits[0].row.detail);
}

test "the haystack leaves out an address that is the name again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();
    const bare: ssh.Host = .{ .name = "web", .address = "web", .attributes = &.{} };
    try testing.expectEqualStrings("web", try haystackOf(scratch, bare));

    const named: ssh.Host = .{ .name = "web", .address = "10.0.0.5", .attributes = &.{} };
    try testing.expectEqualStrings("web 10.0.0.5", try haystackOf(scratch, named));
}

test "the source is on unless it is turned off" {
    try testing.expect(enabled(null));
    try testing.expect(enabled(true));
    try testing.expect(!enabled(false));
}
