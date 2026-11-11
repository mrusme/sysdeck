const std = @import("std");
const copy = @import("../system/copy.zig");
const launch = @import("../system/launch.zig");
const model = @import("../model.zig");
const rank = @import("core").rank;
const source = @import("source.zig");
const ssh = @import("core").ssh;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const tallied = @import("tallied.zig");
const tally = @import("core").counts;
const terminal_mod = @import("../system/terminal.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.ssh);

pub const table = tables.ssh;

const max_rows = 200;

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
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Index),
            .verb = "Connect",
        };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        const icon: model.Icon = .{ .name = self.icon };
        return self.hosts.hits(owner, text, .{ .max_rows = max_rows, .icon = icon });
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.hosts.picks(owner, limit, .{ .name = self.icon });
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.hosts.counters(id);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.hosts.forget(id);
    }

    pub fn stale(_: *Index) bool {
        return true;
    }

    pub fn retire(self: *Index) void {
        self.hosts.retire();
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
                .title = try arena.dupeSentinel(u8, attribute.keyword, 0),
                .detail = try arena.dupeSentinel(u8, attribute.value, 0),
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
        if (!copy.put(scratch, self.environ, .{ .bytes = line })) return .keep;

        self.hosts.note(id);
        return .close;
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("ssh")) return null;

    var self: Index = .{
        .hosts = try .init(context.gpa, context.io, table, context.published),
        .environ = context.environ,
        .terminal = context.terminal,
        .shell = context.environ.get("SHELL") orelse subroutines.default_shell,
        .icon = subroutines.themedIcon(&icon_names),
        .required = context.asked("ssh"),
    };
    self.hosts.prepare(context.store);
    return self;
}

fn itemsOf(arena: Allocator, found: []const ssh.Host) Allocator.Error![]Hosts.Item {
    const items = try arena.alloc(Hosts.Item, found.len);
    for (found, items) |host, *item| {
        item.* = .{
            .key = host.name,
            .title = try arena.dupeSentinel(u8, host.name, 0),
            .detail = try arena.dupeSentinel(u8, host.address, 0),
            .fields = try fieldsOf(arena, host),
            .payload = host.attributes,
        };
    }
    return items;
}

fn fieldsOf(arena: Allocator, host: ssh.Host) Allocator.Error![]const []const u8 {
    if (std.mem.eql(u8, host.name, host.address)) return arena.dupe([]const u8, &.{host.name});
    return arena.dupe([]const u8, &.{ host.name, host.address });
}

fn lineOf(arena: Allocator, attribute: ssh.Attribute) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ attribute.keyword, " ", attribute.value });
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
        .hosts = try .init(testing.allocator, testing.io, table, null),
        .environ = environ,
        .terminal = null,
        .shell = subroutines.default_shell,
        .icon = icon_names[0],
        .required = false,
    };
    errdefer self.retire();

    const catalog = try self.hosts.begin();
    const arena = catalog.allocator();
    self.hosts.publish(catalog, try itemsOf(arena, try ssh.parse(arena, gitlab)));
    return self;
}

test "every attribute of a host is an action titled by its keyword" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self = try testIndex(&environ);
    defer self.retire();

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
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self = try testIndex(&environ);
    defer self.retire();

    try testing.expectEqual(subroutines.Output.nothing, try self.run(owner, " "));

    const found = try self.run(owner, "gitlab");

    try testing.expectEqual(@as(usize, 1), found.hits.len);
    try testing.expectEqualStrings("gitlab.com", found.hits[0].row.title);
    try testing.expectEqualStrings("gitlab.com", found.hits[0].row.detail);
    try testing.expectEqualStrings("network-server", found.hits[0].row.icon.name);

    const web = try self.run(owner, "web");
    try testing.expectEqualStrings("web", web.hits[0].row.detail);
}

test "the fields leave out an address that is the name again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const scratch = arena.allocator();
    const bare: ssh.Host = .{ .name = "web", .address = "web", .attributes = &.{} };
    try testing.expectEqualDeep(@as([]const []const u8, &.{"web"}), try fieldsOf(scratch, bare));

    const named: ssh.Host = .{ .name = "web", .address = "10.0.0.5", .attributes = &.{} };
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "web", "10.0.0.5" }),
        try fieldsOf(scratch, named),
    );
}
