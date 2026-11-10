const std = @import("std");
const command = @import("command.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const program = "podman";
pub const listing = [_][]const u8{ "ps", "-a", "--pod", "--format", "json" };
pub const inspecting = [_][]const u8{ "container", "inspect", "--format", "json" };
pub const logging = [_][]const u8{ "logs", "--tail", "3" };

const output_format = "podman's JSON";
const replacement = "\u{fffd}";
const max_output = 64 << 10;

pub const Status = enum {
    running,
    paused,
    created,
    stopped,
    crashed,
    stopping,
    removing,
    other,

    pub fn verb(self: Status) ?Verb {
        return switch (self) {
            .running => .stop,
            .paused => .unpause,
            .created, .stopped, .crashed => .start,
            .stopping, .removing, .other => null,
        };
    }
};

pub const Verb = enum {
    start,
    stop,
    unpause,

    pub fn label(self: Verb) [:0]const u8 {
        return switch (self) {
            .start => "Start",
            .stop => "Stop",
            .unpause => "Resume",
        };
    }

    pub fn word(self: Verb) []const u8 {
        return switch (self) {
            .start => "start",
            .stop => "stop",
            .unpause => "resume",
        };
    }

    pub fn past(self: Verb) []const u8 {
        return switch (self) {
            .start => "Started",
            .stop => "Stopped",
            .unpause => "Resumed",
        };
    }
};

pub const Field = enum {
    name,
    id,
    image,
    image_id,
    pod,

    pub fn label(self: Field) [:0]const u8 {
        return switch (self) {
            .name => "Name",
            .id => "ID",
            .image => "Image",
            .image_id => "Image ID",
            .pod => "Pod",
        };
    }
};

pub const Detail = struct {
    field: Field,
    value: [:0]const u8,
    caption: [:0]const u8,
};

pub const Container = struct {
    id: []const u8,
    name: [:0]const u8,
    image: [:0]const u8,
    status: Status,
    word: [:0]const u8,
    ports: []const u8,
    autoremove: bool,
    details: []const Detail,
};

pub const Addresses = struct {
    v4: []const []const u8 = &.{},
    v6: []const []const u8 = &.{},
};

pub const Listing = struct {
    containers: []const Container,
    unchecked: ?command.Failure = null,
};

pub const Read = union(enum) {
    listed: Listing,
    missing,
    failed: command.Failure,
};

pub const Done = union(enum) {
    done,
    missing,
    failed: command.Failure,
};

pub const Located = union(enum) {
    found: Addresses,
    missing,
    failed: command.Failure,
};

pub const Logged = union(enum) {
    lines: []const u8,
    missing,
    failed: command.Failure,
};

const ParseError = std.json.ParseError(std.json.Scanner);

const State = enum { created, initialized, running, stopped, paused, exited, removing, stopping };

const Mapping = struct {
    host_ip: []const u8 = "",
    host_port: u32 = 0,
    container_port: u32 = 0,
    range: u32 = 1,
    protocol: []const u8 = "tcp",
};

const Listed = struct {
    Id: []const u8 = "",
    Names: ?[]const []const u8 = null,
    Image: []const u8 = "",
    ImageID: []const u8 = "",
    State: []const u8 = "",
    ExitCode: i32 = 0,
    IsInfra: bool = false,
    PodName: []const u8 = "",
    Ports: ?[]const Mapping = null,
    AutoRemove: bool = false,

    fn name(self: Listed) []const u8 {
        const names = self.Names orelse return "";
        if (names.len == 0) return "";
        return trimmed(names[0]);
    }

    fn failed(self: Listed) bool {
        const state = std.meta.stringToEnum(State, self.State) orelse return false;
        return (state == .exited or state == .stopped) and self.ExitCode != 0;
    }
};

const Inspected = struct {
    Id: []const u8 = "",
    State: ?struct { StoppedByUser: bool = false } = null,
};

const Network = struct {
    IPAddress: []const u8 = "",
    GlobalIPv6Address: []const u8 = "",
};

const Settings = struct {
    IPAddress: []const u8 = "",
    GlobalIPv6Address: []const u8 = "",
    Networks: ?std.json.ArrayHashMap(Network) = null,
};

const Networked = struct {
    NetworkSettings: ?Settings = null,
};

const Checked = struct {
    stopped: []const []const u8 = &.{},
    failure: ?command.Failure = null,
};

pub fn read(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
    limits: command.Limits,
) error{ OutOfMemory, Canceled }!Read {
    var argv: [listing.len + 1][]const u8 = undefined;
    argv[0] = path;
    @memcpy(argv[1..], &listing);

    const output = switch (try command.run(gpa, arena, io, environ, &argv, limits)) {
        .printed => |output| output,
        .missing => return .missing,
        .failed => |failure| return .{ .failed = failure },
    };
    defer gpa.free(output);

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    const found = scan(scratch.allocator(), output) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .failed = .{ .malformed = .{ .expected = output_format, .cause = err } } },
    };

    const checked = try check(gpa, arena, scratch.allocator(), io, environ, path, limits, found);
    return .{ .listed = .{
        .containers = try build(arena, found, checked.stopped),
        .unchecked = checked.failure,
    } };
}

fn parse(gpa: Allocator, arena: Allocator, json: []const u8, stopped: []const []const u8) ParseError![]const Container {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    return build(arena, try scan(scratch.allocator(), json), stopped);
}

pub fn control(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
    verb: Verb,
    id: []const u8,
) error{ OutOfMemory, Canceled }!Done {
    const argv = [_][]const u8{ path, @tagName(verb), id };
    return switch (try command.run(gpa, arena, io, environ, &argv, .{ .timeout = null, .output = max_output })) {
        .printed => |output| {
            gpa.free(output);
            return .done;
        },
        .missing => .missing,
        .failed => |failure| .{ .failed = failure },
    };
}

pub fn addresses(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
    limits: command.Limits,
    id: []const u8,
) error{ OutOfMemory, Canceled }!Located {
    var argv: [inspecting.len + 2][]const u8 = undefined;
    argv[0] = path;
    @memcpy(argv[1 .. inspecting.len + 1], &inspecting);
    argv[inspecting.len + 1] = id;

    const output = switch (try command.run(gpa, arena, io, environ, &argv, limits)) {
        .printed => |output| output,
        .missing => return .missing,
        .failed => |failure| return .{ .failed = failure },
    };
    defer gpa.free(output);

    const found = std.json.parseFromSliceLeaky([]const Networked, arena, output, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .failed = .{ .malformed = .{ .expected = output_format, .cause = err } } },
    };
    return .{ .found = try addressesOf(arena, found) };
}

pub fn logs(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
    limits: command.Limits,
    id: []const u8,
) error{ OutOfMemory, Canceled }!Logged {
    var argv: [logging.len + 2][]const u8 = undefined;
    argv[0] = path;
    @memcpy(argv[1 .. logging.len + 1], &logging);
    argv[logging.len + 1] = id;

    return switch (try command.merged(gpa, arena, io, environ, &argv, limits)) {
        .printed => |output| {
            defer gpa.free(output);
            return .{ .lines = try cleaned(arena, output) };
        },
        .missing => .missing,
        .failed => |failure| .{ .failed = failure },
    };
}

fn cleaned(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;

    var at: usize = 0;
    while (at < raw.len) {
        const byte = raw[at];
        if (byte == 0x1b) {
            at = escaped(raw, at);
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            if (byte == '\n' or byte == '\t') try text.append(arena, byte);
            at += 1;
            continue;
        }

        const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        if (length == 0 or at + length > raw.len or !std.unicode.utf8ValidateSlice(raw[at .. at + length])) {
            try text.appendSlice(arena, replacement);
            at += 1;
            continue;
        }
        try text.appendSlice(arena, raw[at .. at + length]);
        at += length;
    }
    return std.mem.trim(u8, text.items, "\n");
}

fn escaped(raw: []const u8, start: usize) usize {
    var at = start + 1;
    if (at == raw.len) return at;

    switch (raw[at]) {
        '[' => {
            at += 1;
            while (at < raw.len and (raw[at] < 0x40 or raw[at] > 0x7e)) at += 1;
            return @min(at + 1, raw.len);
        },
        ']' => {
            at += 1;
            while (at < raw.len) : (at += 1) {
                if (raw[at] == 0x07) return at + 1;
                if (raw[at] == 0x1b and at + 1 < raw.len and raw[at + 1] == '\\') return at + 2;
            }
            return at;
        },
        else => return at + 1,
    }
}

fn addressesOf(arena: Allocator, found: []const Networked) Allocator.Error!Addresses {
    var v4: std.ArrayList([]const u8) = .empty;
    var v6: std.ArrayList([]const u8) = .empty;

    for (found) |one| {
        const settings = one.NetworkSettings orelse continue;
        try note(arena, &v4, settings.IPAddress);
        try note(arena, &v6, settings.GlobalIPv6Address);

        const networks = settings.Networks orelse continue;
        for (networks.map.values()) |network| {
            try note(arena, &v4, network.IPAddress);
            try note(arena, &v6, network.GlobalIPv6Address);
        }
    }
    return .{ .v4 = v4.items, .v6 = v6.items };
}

fn note(arena: Allocator, list: *std.ArrayList([]const u8), raw: []const u8) Allocator.Error!void {
    const address = trimmed(raw);
    if (address.len == 0 or among(list.items, address)) return;
    try list.append(arena, address);
}

fn portsOf(arena: Allocator, mappings: []const Mapping) Allocator.Error![]const u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    const writer = &text.writer;

    for (mappings, 0..) |mapping, at| {
        if (at > 0) writer.writeAll(", ") catch return error.OutOfMemory;
        const host = if (mapping.host_ip.len == 0) "0.0.0.0" else mapping.host_ip;
        if (mapping.range > 1) {
            writer.print("{s}:{d}-{d}->{d}-{d}/{s}", .{
                host,
                mapping.host_port,
                mapping.host_port + mapping.range - 1,
                mapping.container_port,
                mapping.container_port + mapping.range - 1,
                mapping.protocol,
            }) catch return error.OutOfMemory;
        } else {
            writer.print("{s}:{d}->{d}/{s}", .{
                host,
                mapping.host_port,
                mapping.container_port,
                mapping.protocol,
            }) catch return error.OutOfMemory;
        }
    }
    return text.written();
}

fn scan(scratch: Allocator, json: []const u8) ParseError![]const Listed {
    return std.json.parseFromSliceLeaky([]const Listed, scratch, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn check(
    gpa: Allocator,
    arena: Allocator,
    scratch: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
    limits: command.Limits,
    found: []const Listed,
) error{ OutOfMemory, Canceled }!Checked {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(scratch, path);
    try argv.appendSlice(scratch, &inspecting);
    for (found) |one| {
        if (!one.IsInfra and one.Id.len > 0 and one.failed()) try argv.append(scratch, one.Id);
    }
    if (argv.items.len == inspecting.len + 1) return .{};

    const output = switch (try command.run(gpa, arena, io, environ, argv.items, limits)) {
        .printed => |output| output,
        .missing => return .{ .failure = .{ .cause = error.FileNotFound } },
        .failed => |failure| return .{ .failure = failure },
    };
    defer gpa.free(output);

    const inspected = std.json.parseFromSliceLeaky([]const Inspected, scratch, output, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .failure = .{ .malformed = .{ .expected = output_format, .cause = err } } },
    };

    var stopped: std.ArrayList([]const u8) = .empty;
    for (inspected) |one| {
        const state = one.State orelse continue;
        if (state.StoppedByUser) try stopped.append(scratch, one.Id);
    }
    return .{ .stopped = stopped.items };
}

fn build(arena: Allocator, found: []const Listed, stopped: []const []const u8) Allocator.Error![]const Container {
    var containers: std.ArrayList(Container) = .empty;
    try containers.ensureTotalCapacity(arena, found.len);

    for (found) |one| {
        if (one.IsInfra or one.Id.len == 0 or one.name().len == 0) continue;

        const status = statusOf(one, stopped);
        containers.appendAssumeCapacity(.{
            .id = try arena.dupe(u8, one.Id),
            .name = try arena.dupeSentinel(u8, one.name(), 0),
            .image = try arena.dupeSentinel(u8, trimmed(one.Image), 0),
            .status = status,
            .word = if (status == .other) try arena.dupeSentinel(u8, one.State, 0) else @tagName(status),
            .ports = try portsOf(arena, one.Ports orelse &.{}),
            .autoremove = one.AutoRemove,
            .details = try detailsOf(arena, one),
        });
    }

    std.mem.sort(Container, containers.items, {}, byName);
    return containers.items;
}

fn statusOf(one: Listed, stopped: []const []const u8) Status {
    const state = std.meta.stringToEnum(State, one.State) orelse return .other;
    return switch (state) {
        .running => .running,
        .paused => .paused,
        .created, .initialized => .created,
        .exited, .stopped => if (one.ExitCode == 0 or among(stopped, one.Id)) .stopped else .crashed,
        .stopping => .stopping,
        .removing => .removing,
    };
}

fn among(ids: []const []const u8, id: []const u8) bool {
    for (ids) |found| {
        if (std.mem.eql(u8, found, id)) return true;
    }
    return false;
}

fn byName(_: void, left: Container, right: Container) bool {
    return switch (std.ascii.orderIgnoreCase(left.name, right.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, left.name, right.name) == .lt,
    };
}

fn detailsOf(arena: Allocator, one: Listed) Allocator.Error![]const Detail {
    var details: std.ArrayList(Detail) = .empty;
    try add(arena, &details, .name, one.name());
    try add(arena, &details, .id, one.Id);
    try add(arena, &details, .image, one.Image);
    try add(arena, &details, .image_id, one.ImageID);
    try add(arena, &details, .pod, one.PodName);
    return details.items;
}

fn add(arena: Allocator, details: *std.ArrayList(Detail), field: Field, raw: []const u8) Allocator.Error!void {
    const text = trimmed(raw);
    if (text.len == 0) return;
    try details.append(arena, .{ .field = field, .value = try arena.dupeSentinel(u8, text, 0), .caption = field.label() });
}

fn trimmed(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, &std.ascii.whitespace);
}

const testing = std.testing;

fn parsed(arena: Allocator, json: []const u8) ![]const Container {
    return parse(testing.allocator, arena, json, &.{});
}

fn only(arena: Allocator, json: []const u8) !Container {
    const containers = try parsed(arena, json);
    try testing.expectEqual(@as(usize, 1), containers.len);
    return containers[0];
}

test "a container is titled by its name and described by its image" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try only(arena.allocator(),
        \\[{"Id": "f809d929cfda", "Names": ["postgres"], "Image": "docker.io/library/postgres:alpine",
        \\  "State": "running", "ExitCode": 0}]
    );
    try testing.expectEqualStrings("f809d929cfda", found.id);
    try testing.expectEqualStrings("postgres", found.name);
    try testing.expectEqualStrings("docker.io/library/postgres:alpine", found.image);
    try testing.expectEqual(Status.running, found.status);
}

test "containers are sorted by name, ignoring case" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const containers = try parsed(arena.allocator(),
        \\[{"Id": "1", "Names": ["redis"], "State": "exited"},
        \\ {"Id": "2", "Names": ["Minio"], "State": "exited"},
        \\ {"Id": "3", "Names": ["minio"], "State": "exited"},
        \\ {"Id": "4", "Names": ["alpha"], "State": "exited"}]
    );
    try testing.expectEqual(@as(usize, 4), containers.len);
    for ([_][]const u8{ "alpha", "Minio", "minio", "redis" }, containers) |name, container| {
        try testing.expectEqualStrings(name, container.name);
    }
}

test "a pod's infra container is left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try only(arena.allocator(),
        \\[{"Id": "a", "Names": ["5c1b0b9a8e7f-infra"], "State": "running", "IsInfra": true,
        \\  "Pod": "5c1b0b9a8e7f", "PodName": "web"},
        \\ {"Id": "b", "Names": ["web-app"], "State": "running", "IsInfra": false,
        \\  "Pod": "5c1b0b9a8e7f", "PodName": "web"}]
    );
    try testing.expectEqualStrings("web-app", found.name);
}

test "each state reads as its badge's word" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const containers = try parsed(arena.allocator(),
        \\[{"Id": "1", "Names": ["a"], "State": "running"},
        \\ {"Id": "2", "Names": ["b"], "State": "paused"},
        \\ {"Id": "3", "Names": ["c"], "State": "created"},
        \\ {"Id": "4", "Names": ["d"], "State": "initialized"},
        \\ {"Id": "5", "Names": ["e"], "State": "exited", "ExitCode": 0},
        \\ {"Id": "6", "Names": ["f"], "State": "stopped", "ExitCode": 0},
        \\ {"Id": "7", "Names": ["g"], "State": "exited", "ExitCode": 1},
        \\ {"Id": "8", "Names": ["h"], "State": "stopping"},
        \\ {"Id": "9", "Names": ["i"], "State": "removing"},
        \\ {"Id": "10", "Names": ["j"], "State": "unknown"},
        \\ {"Id": "11", "Names": ["k"], "State": "restarting"}]
    );

    const Expected = struct { word: []const u8, status: Status, verb: ?Verb };
    const wanted = [_]Expected{
        .{ .word = "running", .status = .running, .verb = .stop },
        .{ .word = "paused", .status = .paused, .verb = .unpause },
        .{ .word = "created", .status = .created, .verb = .start },
        .{ .word = "created", .status = .created, .verb = .start },
        .{ .word = "stopped", .status = .stopped, .verb = .start },
        .{ .word = "stopped", .status = .stopped, .verb = .start },
        .{ .word = "crashed", .status = .crashed, .verb = .start },
        .{ .word = "stopping", .status = .stopping, .verb = null },
        .{ .word = "removing", .status = .removing, .verb = null },
        .{ .word = "unknown", .status = .other, .verb = null },
        .{ .word = "restarting", .status = .other, .verb = null },
    };
    try testing.expectEqual(wanted.len, containers.len);
    for (wanted, containers) |expected, container| {
        try testing.expectEqualStrings(expected.word, container.word);
        try testing.expectEqual(expected.status, container.status);
        try testing.expectEqual(expected.verb, container.status.verb());
    }
}

test "a verb names its footer label, the word of a failure and what was done" {
    try testing.expectEqualStrings("Start", Verb.start.label());
    try testing.expectEqualStrings("Stop", Verb.stop.label());
    try testing.expectEqualStrings("Resume", Verb.unpause.label());
    try testing.expectEqualStrings("resume", Verb.unpause.word());
    try testing.expectEqualStrings("Started", Verb.start.past());
    try testing.expectEqualStrings("Stopped", Verb.stop.past());
    try testing.expectEqualStrings("Resumed", Verb.unpause.past());
    try testing.expectEqualStrings("unpause", @tagName(Verb.unpause));
}

test "a container that exited with an error reads stopped when podman stop or kill ended it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const containers = try parse(testing.allocator, arena.allocator(),
        \\[{"Id": "a", "Names": ["killed"], "State": "exited", "ExitCode": 137},
        \\ {"Id": "b", "Names": ["broken"], "State": "exited", "ExitCode": 137}]
    , &.{"a"});
    try testing.expectEqual(@as(usize, 2), containers.len);
    try testing.expectEqualStrings("broken", containers[0].name);
    try testing.expectEqual(Status.crashed, containers[0].status);
    try testing.expectEqualStrings("killed", containers[1].name);
    try testing.expectEqual(Status.stopped, containers[1].status);
}

test "a container's details come in the menu's order, the pod only in a pod" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const containers = try parsed(arena.allocator(),
        \\[{"Id": "b1", "Names": ["web-app"], "Image": "docker.io/library/nginx:1.30-alpine",
        \\  "ImageID": "c0ffee", "State": "running", "Pod": "5c1b", "PodName": "web"},
        \\ {"Id": "c2", "Names": ["lonely"], "Image": "fedora:44", "ImageID": "", "State": "running",
        \\  "Pod": "", "PodName": ""}]
    );
    try testing.expectEqual(@as(usize, 2), containers.len);

    const lonely = containers[0];
    try testing.expectEqual(@as(usize, 3), lonely.details.len);
    try testing.expectEqual(Field.name, lonely.details[0].field);
    try testing.expectEqual(Field.id, lonely.details[1].field);
    try testing.expectEqual(Field.image, lonely.details[2].field);

    const app = containers[1];
    const Expected = struct { field: Field, value: []const u8, caption: []const u8 };
    const wanted = [_]Expected{
        .{ .field = .name, .value = "web-app", .caption = "Name" },
        .{ .field = .id, .value = "b1", .caption = "ID" },
        .{ .field = .image, .value = "docker.io/library/nginx:1.30-alpine", .caption = "Image" },
        .{ .field = .image_id, .value = "c0ffee", .caption = "Image ID" },
        .{ .field = .pod, .value = "web", .caption = "Pod" },
    };
    try testing.expectEqual(wanted.len, app.details.len);
    for (wanted, app.details) |expected, detail| {
        try testing.expectEqual(expected.field, detail.field);
        try testing.expectEqualStrings(expected.value, detail.value);
        try testing.expectEqualStrings(expected.caption, detail.caption);
    }
}

test "forwarded ports read as podman ps prints them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const containers = try parsed(arena.allocator(),
        \\[{"Id": "a", "Names": ["web"], "State": "running", "Ports": [
        \\   {"host_ip": "127.0.0.1", "container_port": 80, "host_port": 18080, "range": 1, "protocol": "tcp"},
        \\   {"host_ip": "", "container_port": 9000, "host_port": 19000, "range": 2, "protocol": "tcp"},
        \\   {"host_ip": "", "container_port": 53, "host_port": 18053, "range": 1, "protocol": "udp"}]},
        \\ {"Id": "b", "Names": ["zero"], "State": "running", "Ports": null},
        \\ {"Id": "c", "Names": ["empty"], "State": "running", "Ports": []}]
    );
    try testing.expectEqual(@as(usize, 3), containers.len);
    try testing.expectEqualStrings("", containers[0].ports);
    try testing.expectEqualStrings(
        "127.0.0.1:18080->80/tcp, 0.0.0.0:19000-19001->9000-9001/tcp, 0.0.0.0:18053->53/udp",
        containers[1].ports,
    );
    try testing.expectEqualStrings("", containers[2].ports);
}

fn addressesIn(arena: Allocator, json: []const u8) !Addresses {
    const found = try std.json.parseFromSliceLeaky([]const Networked, arena, json, .{ .ignore_unknown_fields = true });
    return addressesOf(arena, found);
}

test "the addresses come from every network the container is on, each once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try addressesIn(arena.allocator(),
        \\[{"Id": "a", "NetworkSettings": {"IPAddress": "10.88.0.5", "GlobalIPv6Address": "",
        \\  "Networks": {"podman": {"IPAddress": "10.88.0.5", "GlobalIPv6Address": ""},
        \\               "sysdeck-test-net6": {"IPAddress": "10.89.1.2",
        \\                                     "GlobalIPv6Address": "fdce:381f:acd2:28f8::2"}}}}]
    );
    try testing.expectEqual(@as(usize, 2), found.v4.len);
    try testing.expectEqualStrings("10.88.0.5", found.v4[0]);
    try testing.expectEqualStrings("10.89.1.2", found.v4[1]);
    try testing.expectEqual(@as(usize, 1), found.v6.len);
    try testing.expectEqualStrings("fdce:381f:acd2:28f8::2", found.v6[0]);
}

test "a container on pasta has no address" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try addressesIn(arena.allocator(),
        \\[{"Id": "a", "NetworkSettings": {"IPAddress": "", "GlobalIPv6Address": "",
        \\  "SandboxKey": "/run/user/1000/netns/netns-3364e403"}},
        \\ {"Id": "b", "NetworkSettings": null}]
    );
    try testing.expectEqual(@as(usize, 0), found.v4.len);
    try testing.expectEqual(@as(usize, 0), found.v6.len);
}

test "null and unknown fields are read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const containers = try parsed(arena.allocator(),
        \\[{"AutoRemove": false, "Command": ["postgres"], "Exited": true, "ExitedAt": 1789938691,
        \\  "ExposedPorts": {"5432": ["tcp"]}, "Id": "f809", "Image": "postgres:alpine", "Labels": null,
        \\  "Mounts": ["/var/lib/postgresql"], "Names": ["postgres"], "Namespaces": {}, "Networks": [],
        \\  "Ports": [{"host_ip": "", "container_port": 5432, "host_port": 5432, "range": 1, "protocol": "tcp"}],
        \\  "Size": null, "State": "exited", "ExitCode": 0, "Status": "Exited (0) 2 weeks ago"},
        \\ {"Id": "", "Names": ["no-id"], "State": "running"},
        \\ {"Id": "e1", "Names": null, "State": "running"}]
    );
    try testing.expectEqual(@as(usize, 1), containers.len);
    try testing.expectEqualStrings("postgres", containers[0].name);
    try testing.expectEqual(Status.stopped, containers[0].status);
}

const Script = struct {
    tmp: testing.TmpDir,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    log_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path: []const u8 = "",
    environ: std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Script, body: []const u8) !void {
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .environ = .init(testing.allocator),
            .arena = .init(testing.allocator),
        };
        errdefer self.deinit();

        try self.environ.put("PATH", "/usr/bin:/bin");
        const script = try testing.allocator.print("#!/bin/sh\necho \"$*\" >> \"$0.log\"\n{s}\n", .{body});
        defer testing.allocator.free(script);
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "podman",
            .data = script,
            .flags = .{ .permissions = .executable_file },
        });
        const length = try self.tmp.dir.realPath(testing.io, &self.buffer);
        self.path = try std.mem.print(self.buffer[length..], "{s}/podman", .{self.buffer[0..length]});
    }

    fn deinit(self: *Script) void {
        self.arena.deinit();
        self.environ.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *Script, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }

    fn calls(self: *Script) ![]const u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "podman.log", self.arena.allocator(), .limited(1 << 16)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => err,
        };
    }

    fn run(self: *Script) !Read {
        return read(testing.allocator, self.arena.allocator(), testing.io, &self.environ, self.path, .{});
    }

    fn send(self: *Script, verb: Verb, id: []const u8) !Done {
        return control(testing.allocator, self.arena.allocator(), testing.io, &self.environ, self.path, verb, id);
    }
};

const answering =
    \\case "$1" in
    \\  ps) cat "$0.json" ;;
    \\  container) cat "$0.inspect" ;;
    \\esac
;

test "the containers are listed with ps -a --pod --format json" {
    var script: Script = undefined;
    try script.init(
        \\printf '[{"Id": "a1", "Names": ["%s"], "Image": "img", "State": "running"}]\n' "$*"
    );
    defer script.deinit();

    const containers = (try script.run()).listed.containers;
    try testing.expectEqual(@as(usize, 1), containers.len);
    try testing.expectEqualStrings("ps -a --pod --format json", containers[0].name);
    try testing.expectEqualStrings("ps -a --pod --format json\n", try script.calls());
}

test "a container that exited with an error is crashed unless podman stop or kill ended it" {
    var script: Script = undefined;
    try script.init(answering);
    defer script.deinit();

    try script.write("podman.json",
        \\[{"Id": "a", "Names": ["postgres"], "State": "exited", "ExitCode": 1},
        \\ {"Id": "b", "Names": ["sleeper"], "State": "exited", "ExitCode": 137},
        \\ {"Id": "c", "Names": ["redis"], "State": "exited", "ExitCode": 0}]
    );
    try script.write("podman.inspect",
        \\[{"Id": "a", "State": {"Status": "exited", "ExitCode": 1}},
        \\ {"Id": "b", "State": {"Status": "exited", "ExitCode": 137, "StoppedByUser": true}}]
    );

    const listed = (try script.run()).listed;
    try testing.expectEqual(@as(?command.Failure, null), listed.unchecked);
    try testing.expectEqual(@as(usize, 3), listed.containers.len);
    try testing.expectEqual(Status.crashed, listed.containers[0].status);
    try testing.expectEqual(Status.stopped, listed.containers[1].status);
    try testing.expectEqual(Status.stopped, listed.containers[2].status);
}

test "only containers that exited with an error are inspected" {
    var script: Script = undefined;
    try script.init(answering);
    defer script.deinit();

    try script.write("podman.json",
        \\[{"Id": "a", "Names": ["one"], "State": "running"},
        \\ {"Id": "b", "Names": ["two"], "State": "exited", "ExitCode": 0},
        \\ {"Id": "c", "Names": ["three"], "State": "created"}]
    );
    _ = try script.run();
    try testing.expectEqualStrings("ps -a --pod --format json\n", try script.calls());

    try script.write("podman.json",
        \\[{"Id": "a", "Names": ["one"], "State": "exited", "ExitCode": 2},
        \\ {"Id": "b", "Names": ["two"], "State": "exited", "ExitCode": 0},
        \\ {"Id": "c", "Names": ["three"], "State": "stopped", "ExitCode": 143},
        \\ {"Id": "d", "Names": ["d-infra"], "State": "exited", "ExitCode": 9, "IsInfra": true}]
    );
    try script.write("podman.inspect", "[]");
    _ = try script.run();
    try testing.expectEqualStrings(
        "ps -a --pod --format json\nps -a --pod --format json\ncontainer inspect --format json a c\n",
        try script.calls(),
    );
}

test "a failed inspection leaves those containers crashed" {
    var script: Script = undefined;
    try script.init(
        \\case "$1" in
        \\  ps) cat "$0.json" ;;
        \\  container) echo 'Error: no such container b' >&2; exit 125 ;;
        \\esac
    );
    defer script.deinit();

    try script.write("podman.json",
        \\[{"Id": "a", "Names": ["one"], "State": "exited", "ExitCode": 1},
        \\ {"Id": "b", "Names": ["two"], "State": "exited", "ExitCode": 137}]
    );

    const listed = (try script.run()).listed;
    try testing.expectEqual(@as(u8, 125), listed.unchecked.?.exited.code);
    try testing.expectEqualStrings("Error: no such container b", listed.unchecked.?.exited.output);
    for (listed.containers) |container| try testing.expectEqual(Status.crashed, container.status);
}

test "output that isn't podman's JSON is malformed" {
    var script: Script = undefined;
    try script.init("echo 'CONTAINER ID  IMAGE  COMMAND'");
    defer script.deinit();

    const failure = (try script.run()).failed;
    try testing.expectEqualStrings("podman's JSON", failure.malformed.expected);
}

test "start, stop and unpause run podman with the container's ID" {
    var script: Script = undefined;
    try script.init("echo \"$2\"");
    defer script.deinit();

    try testing.expectEqual(Done.done, try script.send(.start, "f809d929cfda"));
    try testing.expectEqual(Done.done, try script.send(.stop, "f809d929cfda"));
    try testing.expectEqual(Done.done, try script.send(.unpause, "efce64d4a69f"));
    try testing.expectEqualStrings(
        "start f809d929cfda\nstop f809d929cfda\nunpause efce64d4a69f\n",
        try script.calls(),
    );
}

test "the addresses are read with container inspect and the container's ID" {
    var script: Script = undefined;
    try script.init(
        \\echo '[{"Id": "b1", "NetworkSettings": {"Networks": {"web": {"IPAddress": "10.89.0.2"}}}}]'
    );
    defer script.deinit();

    const found = (try addresses(
        testing.allocator,
        script.arena.allocator(),
        testing.io,
        &script.environ,
        script.path,
        .{},
        "b1",
    )).found;
    try testing.expectEqual(@as(usize, 1), found.v4.len);
    try testing.expectEqualStrings("10.89.0.2", found.v4[0]);
    try testing.expectEqualStrings("container inspect --format json b1\n", try script.calls());
}

test "the last log lines are read from both streams with podman logs --tail 3" {
    var script: Script = undefined;
    try script.init(
        \\echo 'listening on :80'
        \\echo 'shutting down' >&2
        \\echo 'bye'
    );
    defer script.deinit();

    const lines = (try logs(
        testing.allocator,
        script.arena.allocator(),
        testing.io,
        &script.environ,
        script.path,
        .{},
        "b1",
    )).lines;
    try testing.expectEqualStrings("listening on :80\nshutting down\nbye", lines);
    try testing.expectEqualStrings("logs --tail 3 b1\n", try script.calls());
}

test "log lines lose their escape sequences and control characters, and invalid bytes are replaced" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try testing.expectEqualStrings(
        "red and caf\u{fffd}\nprogress done\ttab",
        try cleaned(scratch, "\x1b[31mred\x1b[0m and caf\xe9\nprogress\r done\ttab\n\n"),
    );
    try testing.expectEqualStrings("titled caf\u{e9}", try cleaned(scratch, "\x1b]0;window\x07titled caf\u{e9}"));
    try testing.expectEqualStrings("cut", try cleaned(scratch, "cut\x1b[1"));
    try testing.expectEqualStrings("\u{fffd}\u{fffd}", try cleaned(scratch, "\xf0\x9f"));
    try testing.expectEqualStrings("", try cleaned(scratch, "\n\n"));
}

test "a container run with --rm is marked as one that removes itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const containers = try parsed(arena.allocator(),
        \\[{"Id": "a", "Names": ["kept"], "State": "running", "AutoRemove": false},
        \\ {"Id": "b", "Names": ["passing"], "State": "running", "AutoRemove": true}]
    );
    try testing.expect(!containers[0].autoremove);
    try testing.expect(containers[1].autoremove);
}

test "a failed command reports podman's error output" {
    var script: Script = undefined;
    try script.init(
        \\echo 'Error: unable to start container "f809": pasta failed with exit code 1:' >&2
        \\echo 'Listen failed for HOST TCP port 127.0.0.1/16379: Address already in use' >&2
        \\echo "Couldn't listen on requested ports" >&2
        \\exit 125
    );
    defer script.deinit();

    const failure = (try script.send(.start, "f809")).failed;
    try testing.expectEqual(@as(u8, 125), failure.exited.code);
    try testing.expectEqualStrings(
        "Error: unable to start container \"f809\": pasta failed with exit code 1:\n" ++
            "Listen failed for HOST TCP port 127.0.0.1/16379: Address already in use\n" ++
            "Couldn't listen on requested ports",
        failure.exited.output,
    );
}
