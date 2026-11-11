const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const command = @import("core").command;
const copy = @import("../system/copy.zig");
const model = @import("../model.zig");
const notify = @import("../system/notify.zig");
const podman = @import("core").podman;
const rank = @import("core").rank;
const source = @import("source.zig");
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const tallied = @import("tallied.zig");
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.podman);

pub const table = tables.podman;

const max_rows = 200;
const section = "[sources.podman]";

const icon_names = [_][:0]const u8{ "package-x-generic", "application-x-executable" };

const Listed = tallied.Tallied(Payload);

const Payload = struct {
    id: []const u8,
    verb: ?podman.Verb,
    ports: []const u8,
    autoremove: bool,
    details: []const podman.Detail,
};

pub const Notice = Callback(fn (notify.Notification) void);

pub const Index = struct {
    listed: Listed,
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    settled: ?subroutines.Settled,
    notice: ?Notice = null,
    arena: std.heap.ArenaAllocator,
    program: []const u8,
    configured: bool,
    required: bool,
    icon: [:0]const u8,
    limits: command.Limits = .{},
    loading: std.Io.Mutex = .init,
    loaded: bool = false,
    absent: bool = false,
    warned: bool = false,
    work: std.Io.Group = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Search),
        };
    }

    pub fn containers(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Containers),
        };
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.listed.counters(id);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.listed.forget(id);
    }

    pub fn choose(self: *Index, _: Allocator, id: u64) subroutines.Outcome {
        const item = self.listed.find(id) orelse return .keep;
        const verb = item.payload.verb orelse return .keep;

        self.work.concurrent(self.io, control, .{ self, verb, item.payload, item.title }) catch |err| {
            log.warn("cannot {s} {s}: {t}", .{ verb.word(), item.title, err });
            return .keep;
        };

        self.listed.note(id);
        return .busy;
    }

    pub fn actions(
        self: *Index,
        arena: Allocator,
        id: u64,
    ) subroutines.Error![]const subroutines.Action {
        const item = self.listed.find(id) orelse return &.{};

        const listed = try arena.alloc(subroutines.Action, item.payload.details.len);
        for (item.payload.details, listed, 0..) |detail, *action, at| {
            action.* = .{ .id = at, .title = detail.value, .detail = detail.caption };
        }
        return listed;
    }

    pub fn perform(self: *Index, gpa: Allocator, id: u64, action: u64) subroutines.Outcome {
        const detail = self.detailAt(id, action) orelse return .keep;
        if (!copy.put(gpa, self.environ, .{ .bytes = detail.value })) return .keep;

        self.listed.note(id);
        return .close;
    }

    fn detailAt(self: *Index, id: u64, action: u64) ?podman.Detail {
        const item = self.listed.find(id) orelse return null;
        const at = std.math.cast(usize, action) orelse return null;
        if (at >= item.payload.details.len) return null;
        return item.payload.details[at];
    }

    pub fn stop(self: *Index) void {
        self.stopping.store(true, .release);
    }

    pub fn retire(self: *Index) void {
        self.stop();
        self.work.await(self.io) catch |err| switch (err) {
            error.Canceled => {},
        };
        self.listed.retire();
        self.arena.deinit();
    }

    fn load(self: *Index, asked: bool) void {
        self.loading.lock(self.io) catch return;
        defer self.loading.unlock(self.io);

        if (!self.loaded) {
            self.loaded = true;
            self.read();
        }
        if (asked and self.absent and !self.warned) {
            self.warned = true;
            log.warn("there is no {s} in $PATH, so no containers are listed", .{podman.program});
        }
    }

    fn read(self: *Index) void {
        const catalog = self.listed.begin() catch |err| return source.report(table, "read", err);
        const arena = catalog.allocator();

        const found = podman.read(self.gpa, arena, self.io, self.environ, self.program, self.limits) catch |err| {
            self.listed.discard(catalog);
            switch (err) {
                error.Canceled => {},
                error.OutOfMemory => source.report(table, "read", err),
            }
            return;
        };

        const listing = switch (found) {
            .listed => |listing| listing,
            .missing => {
                self.listed.discard(catalog);
                return self.missing();
            },
            .failed => |failure| {
                defer self.listed.discard(catalog);
                return log.warn("\"{f}\" {f}, so no containers are listed", .{
                    command.Line{ .program = self.program, .arguments = &podman.listing },
                    failure,
                });
            },
        };

        if (listing.unchecked) |failure| {
            log.warn("\"{f}\" {f}, so every container that exited with an error reads crashed", .{
                command.Line{ .program = self.program, .arguments = &podman.inspecting },
                failure,
            });
        }

        const items = itemsOf(arena, listing.containers) catch |err| {
            self.listed.discard(catalog);
            return source.report(table, "read", err);
        };
        self.listed.publish(catalog, items);
    }

    fn missing(self: *Index) void {
        self.absent = true;
        if (self.configured) {
            self.warned = true;
            return log.warn("{s} exec is {s}, which does not exist, so no containers are listed", .{
                section,
                self.program,
            });
        }
        if (self.required) {
            self.warned = true;
            log.warn("{s} enable is true, however there is no {s} in $PATH, so no containers are listed", .{
                section,
                podman.program,
            });
        }
    }

    fn rows(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
        options: tallied.Options,
    ) subroutines.Error!subroutines.Output {
        var wanted = options;
        wanted.icon = .{ .name = self.icon };
        return self.listed.hits(owner, text, wanted);
    }

    fn control(self: *Index, verb: podman.Verb, container: Payload, name: [:0]const u8) void {
        defer if (!self.stopping.load(.acquire)) {
            if (self.settled) |found| found.call(.{});
        };

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        const id = container.id;
        const done = podman.control(self.gpa, scratch, self.io, self.environ, self.program, verb, id) catch |err| {
            switch (err) {
                error.Canceled => {},
                error.OutOfMemory => log.warn("out of memory, so whether {s} could {s} is unknown", .{
                    name,
                    verb.word(),
                }),
            }
            return;
        };

        const failure: command.Failure = switch (done) {
            .done => return self.succeed(scratch, verb, container, name),
            .missing => .{ .cause = error.FileNotFound },
            .failed => |found| found,
        };
        self.fail(scratch, verb, id, name, failure);
    }

    fn succeed(self: *Index, scratch: Allocator, verb: podman.Verb, container: Payload, name: []const u8) void {
        const summary = scratch.print("{s} {s}", .{ verb.past(), name }) catch return;
        const body = switch (verb) {
            .stop => self.lastLines(scratch, container, name) catch "",
            .start, .unpause => self.describe(scratch, container, name) catch "",
        };
        self.tell(.{ .summary = summary, .body = body, .urgency = .low, .icon = self.icon });
    }

    fn lastLines(self: *Index, scratch: Allocator, container: Payload, name: []const u8) Allocator.Error![]const u8 {
        if (container.autoremove) return "";

        const found = podman.logs(self.gpa, scratch, self.io, self.environ, self.program, self.limits, container.id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return "",
        };

        const failure: command.Failure = switch (found) {
            .lines => |lines| return lines,
            .missing => .{ .cause = error.FileNotFound },
            .failed => |reason| reason,
        };
        log.warn("cannot read the last log lines of {s}: \"{f} {s}\" {f}", .{
            name,
            command.Line{ .program = self.program, .arguments = &podman.logging },
            container.id,
            failure,
        });
        return "";
    }

    fn describe(self: *Index, scratch: Allocator, container: Payload, name: []const u8) Allocator.Error![]const u8 {
        const found = podman.addresses(self.gpa, scratch, self.io, self.environ, self.program, self.limits, container.id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return bodyOf(scratch, .{}, container.ports),
        };

        const failure: command.Failure = switch (found) {
            .found => |addresses| return bodyOf(scratch, addresses, container.ports),
            .missing => .{ .cause = error.FileNotFound },
            .failed => |reason| reason,
        };
        log.warn("cannot read the addresses of {s}: \"{f} {s}\" {f}", .{
            name,
            command.Line{ .program = self.program, .arguments = &podman.inspecting },
            container.id,
            failure,
        });
        return bodyOf(scratch, .{}, container.ports);
    }

    fn fail(
        self: *Index,
        scratch: Allocator,
        verb: podman.Verb,
        id: []const u8,
        name: []const u8,
        failure: command.Failure,
    ) void {
        log.warn("cannot {s} {s}: \"{f}\" {f}", .{
            verb.word(),
            name,
            command.Line{ .program = self.program, .arguments = &.{ @tagName(verb), id } },
            failure,
        });

        const summary = scratch.print("Cannot {s} {s}", .{ verb.word(), name }) catch return;
        const body = messageOf(scratch, failure) catch return;
        self.tell(.{ .summary = summary, .body = body, .icon = self.icon });
    }

    fn tell(self: *Index, notification: notify.Notification) void {
        if (self.notice) |found| return found.call(.{notification});
        _ = notify.send(self.gpa, notification);
    }
};

const Search = struct {
    pub const Context = Index;

    pub const choose = Index.choose;
    pub const actions = Index.actions;
    pub const perform = Index.perform;
    pub const counters = Index.counters;
    pub const forget = Index.forget;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        if (std.mem.trim(u8, text, " \t").len == 0) return .nothing;
        self.load(false);

        return self.rows(owner, text, .{ .max_rows = max_rows });
    }
};

const Containers = struct {
    pub const Context = Index;

    pub const choose = Index.choose;
    pub const actions = Index.actions;
    pub const perform = Index.perform;
    pub const counters = Index.counters;
    pub const forget = Index.forget;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        self.load(true);

        return self.rows(owner, text, .{
            .max_rows = std.math.maxInt(usize),
            .counted = std.mem.trim(u8, text, " \t").len > 0,
            .idle = .chosen,
        });
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("podman")) return null;

    var arena: std.heap.ArenaAllocator = .init(context.gpa);
    errdefer arena.deinit();

    const exec = context.settings.sources.podman.exec;
    const home = context.environ.get("HOME") orelse "";
    const program = if (exec.len > 0) try xdg.expand(arena.allocator(), home, exec) else podman.program;

    var self: Index = .{
        .listed = try .init(context.gpa, context.io, table, null),
        .gpa = context.gpa,
        .io = context.io,
        .environ = context.environ,
        .settled = context.settled,
        .arena = arena,
        .program = program,
        .configured = exec.len > 0,
        .required = context.asked("podman") or exec.len > 0,
        .icon = subroutines.themedIcon(&icon_names),
    };
    self.listed.prepare(context.store);
    return self;
}

fn itemsOf(arena: Allocator, found: []const podman.Container) Allocator.Error![]Listed.Item {
    const items = try arena.alloc(Listed.Item, found.len);
    for (found, items) |container, *item| {
        const badges = try arena.alloc(model.Badge, 1);
        badges[0] = .{ .status = .{ .text = container.word, .tone = toneOf(container.status) } };

        const verb = container.status.verb();
        item.* = .{
            .key = container.name,
            .title = container.name,
            .detail = container.image,
            .verb = if (verb) |chosen| chosen.label() else "",
            .badges = badges,
            .fields = try arena.dupe([]const u8, &.{ container.name, container.image }),
            .payload = .{
                .id = container.id,
                .verb = verb,
                .ports = container.ports,
                .autoremove = container.autoremove,
                .details = container.details,
            },
        };
    }
    return items;
}

fn toneOf(status: podman.Status) model.Tone {
    return switch (status) {
        .running => .good,
        .crashed => .bad,
        else => .idle,
    };
}

fn bodyOf(arena: Allocator, addresses: podman.Addresses, ports: []const u8) Allocator.Error![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    if (addresses.v4.len > 0) try lines.append(arena, try lineOf(arena, "IPv4", addresses.v4));
    if (addresses.v6.len > 0) try lines.append(arena, try lineOf(arena, "IPv6", addresses.v6));
    if (ports.len > 0) try lines.append(arena, try lineOf(arena, "Ports", &.{ports}));
    return std.mem.join(arena, "\n", lines.items);
}

fn lineOf(arena: Allocator, label: []const u8, values: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ label, ": ", try std.mem.join(arena, ", ", values) });
}

fn messageOf(arena: Allocator, failure: command.Failure) Allocator.Error![]const u8 {
    switch (failure) {
        .exited => |exit| if (exit.output.len > 0) return podman.cleaned(arena, exit.output),
        else => {},
    }
    return arena.print("{f}", .{failure});
}

const testing = std.testing;
const config_mod = @import("../config.zig");
const counts_mod = @import("core").counts;

const Recorder = struct {
    settled: usize = 0,
    notified: usize = 0,
    summary: [256]u8 = undefined,
    summary_len: usize = 0,
    body: [256]u8 = undefined,
    body_len: usize = 0,
    urgency: notify.Urgency = .normal,

    fn onSettled(self: *Recorder) void {
        self.settled += 1;
    }

    fn onNotice(self: *Recorder, notification: notify.Notification) void {
        self.notified += 1;
        self.urgency = notification.urgency;
        self.summary_len = @min(notification.summary.len, self.summary.len);
        @memcpy(self.summary[0..self.summary_len], notification.summary[0..self.summary_len]);
        self.body_len = @min(notification.body.len, self.body.len);
        @memcpy(self.body[0..self.body_len], notification.body[0..self.body_len]);
    }
};

const Rig = struct {
    tmp: testing.TmpDir,
    root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    script_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    script: []const u8 = "",
    environ: std.process.Environ.Map,
    settings: config_mod.Config = .{},
    recorder: Recorder = .{},
    owner: *subroutines.Owner = undefined,

    fn init(self: *Rig, json: []const u8) !void {
        try self.initWith(json, "exit 0");
    }

    fn initWith(self: *Rig, json: []const u8, body: []const u8) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .environ = .init(testing.allocator) };
        errdefer self.environ.deinit();
        errdefer self.tmp.cleanup();

        const length = try self.tmp.dir.realPath(testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..length];
        self.script = try std.mem.print(&self.script_buffer, "{s}/podman", .{self.root});

        try self.environ.put("PATH", "/usr/bin:/bin");

        const script = try testing.allocator.print(
            \\#!/bin/sh
            \\echo "$*" >> "$0.log"
            \\case "$1" in
            \\  ps) cat "$0.json" ;;
            \\  container) cat "$0.inspect" 2>/dev/null || echo '[]' ;;
            \\  *) {s} ;;
            \\esac
            \\
        , .{body});
        defer testing.allocator.free(script);
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "podman",
            .data = script,
            .flags = .{ .permissions = .executable_file },
        });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "podman.json", .data = json });

        self.owner = try subroutines.Owner.create(testing.allocator);
    }

    fn deinit(self: *Rig) void {
        self.owner.destroy(testing.allocator);
        self.environ.deinit();
        self.tmp.cleanup();
    }

    fn open(self: *Rig) !Index {
        self.settings = .{ .sources = .{ .podman = .{ .exec = self.script } } };
        var index = (try podman_source.open(.{
            .gpa = testing.allocator,
            .io = testing.io,
            .environ = &self.environ,
            .settings = &self.settings,
            .settled = .of(Recorder, Recorder.onSettled, &self.recorder),
        })).?;
        index.notice = .of(Recorder, Recorder.onNotice, &self.recorder);
        return index;
    }

    fn calls(self: *Rig) ![]const u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "podman.log", self.owner.allocator(), .limited(1 << 16)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => err,
        };
    }

    fn rows(self: *Rig, index: *Index, query: []const u8) ![]const subroutines.Hit {
        return switch (try Search.run(index, self.owner, query)) {
            .hits => |hits| hits,
            else => &.{},
        };
    }

    fn overview(self: *Rig, index: *Index, query: []const u8) ![]const subroutines.Hit {
        return switch (try Containers.run(index, self.owner, query)) {
            .hits => |hits| hits,
            else => &.{},
        };
    }

    fn rowOf(self: *Rig, index: *Index, query: []const u8) !model.Row {
        const found = try self.rows(index, query);
        try testing.expectEqual(@as(usize, 1), found.len);
        return found[0].row;
    }
};

const podman_source = @This();

const fleet =
    \\[{"Id": "1111", "Names": ["web"], "Image": "docker.io/library/nginx:1.30-alpine", "ImageID": "c0ffee",
    \\  "State": "running", "Ports": [{"host_ip": "", "container_port": 80, "host_port": 18080, "range": 1,
    \\  "protocol": "tcp"}]},
    \\ {"Id": "2222", "Names": ["postgres"], "Image": "docker.io/library/postgres:alpine", "State": "exited",
    \\  "ExitCode": 1},
    \\ {"Id": "3333", "Names": ["cache"], "Image": "docker.io/valkey/valkey:9", "State": "paused"},
    \\ {"Id": "4444", "Names": ["queue"], "Image": "docker.io/library/rabbitmq:4", "State": "stopping"},
    \\ {"Id": "5555", "Names": ["old"], "Image": "registry.fedoraproject.org/fedora:44", "State": "exited",
    \\  "ExitCode": 0},
    \\ {"Id": "6666", "Names": ["gone"], "Image": "registry.fedoraproject.org/fedora:44", "State": "removing"}]
;

test "nothing runs until a query has text, and the containers are read once" {
    var rig: Rig = undefined;
    try rig.init(fleet);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "")).len);
    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "  ")).len);
    try testing.expectEqualStrings("", try rig.calls());

    const web = try rig.rowOf(&index, "web");
    try testing.expectEqualStrings("web", web.title);
    try testing.expectEqualStrings("docker.io/library/nginx:1.30-alpine", web.detail);
    _ = try rig.rowOf(&index, "cache");
    try testing.expectEqualStrings(
        "ps -a --pod --format json\ncontainer inspect --format json 2222\n",
        try rig.calls(),
    );
}

test "a failed listing is not retried and lists nothing" {
    var rig: Rig = undefined;
    try rig.initWith("[]", "exit 0");
    defer rig.deinit();
    try rig.tmp.dir.deleteFile(testing.io, "podman.json");

    var index = try rig.open();
    defer index.retire();

    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "web")).len);
    try testing.expectEqual(@as(usize, 0), (try rig.overview(&index, "")).len);
    try testing.expectEqualStrings("ps -a --pod --format json\n", try rig.calls());
}

test "a row shows the container's state as a badge and Return's verb" {
    var rig: Rig = undefined;
    try rig.init(fleet);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const Expected = struct { query: []const u8, word: []const u8, tone: model.Tone, verb: []const u8 };
    const wanted = [_]Expected{
        .{ .query = "web", .word = "running", .tone = .good, .verb = "Stop" },
        .{ .query = "postgres", .word = "crashed", .tone = .bad, .verb = "Start" },
        .{ .query = "cache", .word = "paused", .tone = .idle, .verb = "Resume" },
        .{ .query = "queue", .word = "stopping", .tone = .idle, .verb = "" },
        .{ .query = "old", .word = "stopped", .tone = .idle, .verb = "Start" },
        .{ .query = "gone", .word = "removing", .tone = .idle, .verb = "" },
    };
    for (wanted) |expected| {
        const row = try rig.rowOf(&index, expected.query);
        try testing.expectEqual(@as(usize, 1), row.badges.len);
        try testing.expectEqualStrings(expected.word, row.badges[0].status.text);
        try testing.expectEqual(expected.tone, row.badges[0].status.tone);
        try testing.expectEqualStrings(expected.verb, row.verb);
        try testing.expectEqualStrings(index.icon, row.icon.name);
    }
}

test "the search matches the name and the image, not the ID" {
    var rig: Rig = undefined;
    try rig.init(fleet);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    try testing.expectEqualStrings("web", (try rig.rowOf(&index, "nginx")).title);
    try testing.expectEqualStrings("postgres", (try rig.rowOf(&index, "postgres")).title);
    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "2222")).len);
    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "c0ffee")).len);
}

test "the containers mode lists every container, the most picked first, then by name" {
    var rig: Rig = undefined;
    try rig.init(fleet);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    _ = try rig.overview(&index, "");
    index.listed.note(counts_mod.id("old"));
    index.listed.note(counts_mod.id("old"));
    index.listed.note(counts_mod.id("postgres"));

    const found = try rig.overview(&index, "");
    try testing.expectEqual(@as(usize, 6), found.len);
    for ([_][]const u8{ "old", "postgres", "cache", "gone", "queue", "web" }, found) |title, hit| {
        try testing.expectEqualStrings(title, hit.row.title);
    }
}

test "the overview counts nothing as shown, a typed query counts what it lists" {
    var rig: Rig = undefined;
    try rig.init(fleet);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    try testing.expectEqual(@as(usize, 6), (try rig.overview(&index, "")).len);
    try testing.expectEqual(@as(?rank.Weight, null), index.listed.counts.added.get(counts_mod.id("web")));

    try testing.expectEqual(@as(usize, 1), (try rig.overview(&index, "web")).len);
    try testing.expectEqual(@as(u32, 1), index.listed.counts.added.get(counts_mod.id("web")).?.shown);
}

test "Return stops a running container, starts a stopped one and resumes a paused one, then settles" {
    var rig: Rig = undefined;
    try rig.init(fleet);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const Expected = struct { query: []const u8, summary: []const u8 };
    const wanted = [_]Expected{
        .{ .query = "web", .summary = "Stopped web" },
        .{ .query = "postgres", .summary = "Started postgres" },
        .{ .query = "cache", .summary = "Resumed cache" },
    };
    for (wanted, 1..) |expected, count| {
        const row = try rig.rowOf(&index, expected.query);
        try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, row.id));
        try index.work.await(testing.io);
        try testing.expectEqual(@as(u32, 1), index.counters(row.id).?.chosen);

        try testing.expectEqual(count, rig.recorder.notified);
        try testing.expectEqualStrings(expected.summary, rig.recorder.summary[0..rig.recorder.summary_len]);
        try testing.expectEqualStrings("", rig.recorder.body[0..rig.recorder.body_len]);
        try testing.expectEqual(notify.Urgency.low, rig.recorder.urgency);
    }

    try testing.expectEqualStrings(
        "ps -a --pod --format json\ncontainer inspect --format json 2222\n" ++
            "stop 1111\nlogs --tail 3 1111\nstart 2222\ncontainer inspect --format json 2222\n" ++
            "unpause 3333\ncontainer inspect --format json 3333\n",
        try rig.calls(),
    );
    try testing.expectEqual(@as(usize, 3), rig.recorder.settled);
}

test "a started container's notification lists its addresses and forwarded ports" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"Id": "7777", "Names": ["site"], "Image": "docker.io/library/nginx:1.30-alpine", "State": "created",
        \\  "Ports": [{"host_ip": "", "container_port": 80, "host_port": 18082, "range": 1, "protocol": "tcp"},
        \\            {"host_ip": "127.0.0.1", "container_port": 443, "host_port": 18443, "range": 1,
        \\             "protocol": "tcp"}]},
        \\ {"Id": "8888", "Names": ["plain"], "Image": "docker.io/library/nginx:1.30-alpine", "State": "created"}]
    );
    defer rig.deinit();
    try rig.tmp.dir.writeFile(testing.io, .{ .sub_path = "podman.inspect", .data =
        \\[{"Id": "7777", "NetworkSettings": {"IPAddress": "",
        \\  "Networks": {"site-net": {"IPAddress": "10.89.1.2", "GlobalIPv6Address": "fdce:381f:acd2:28f8::2"}}}}]
    });

    var index = try rig.open();
    defer index.retire();

    const site = try rig.rowOf(&index, "site");
    try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, site.id));
    try index.work.await(testing.io);

    try testing.expectEqualStrings("Started site", rig.recorder.summary[0..rig.recorder.summary_len]);
    try testing.expectEqualStrings(
        "IPv4: 10.89.1.2\nIPv6: fdce:381f:acd2:28f8::2\n" ++
            "Ports: 0.0.0.0:18082->80/tcp, 127.0.0.1:18443->443/tcp",
        rig.recorder.body[0..rig.recorder.body_len],
    );
    try testing.expect(std.mem.endsWith(u8, try rig.calls(), "start 7777\ncontainer inspect --format json 7777\n"));

    try rig.tmp.dir.writeFile(testing.io, .{ .sub_path = "podman.inspect", .data =
        \\[{"Id": "8888", "NetworkSettings": {"IPAddress": "", "GlobalIPv6Address": ""}}]
    });
    const plain = try rig.rowOf(&index, "plain");
    try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, plain.id));
    try index.work.await(testing.io);

    try testing.expectEqualStrings("Started plain", rig.recorder.summary[0..rig.recorder.summary_len]);
    try testing.expectEqualStrings("", rig.recorder.body[0..rig.recorder.body_len]);
}

test "a failed address lookup still notifies with the forwarded ports" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"Id": "7777", "Names": ["site"], "Image": "nginx", "State": "created",
        \\  "Ports": [{"host_ip": "", "container_port": 80, "host_port": 18082, "range": 1, "protocol": "tcp"}]}]
    );
    defer rig.deinit();
    try rig.tmp.dir.writeFile(testing.io, .{ .sub_path = "podman.inspect", .data = "not json" });

    var index = try rig.open();
    defer index.retire();

    const site = try rig.rowOf(&index, "site");
    try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, site.id));
    try index.work.await(testing.io);

    try testing.expectEqualStrings("Started site", rig.recorder.summary[0..rig.recorder.summary_len]);
    try testing.expectEqualStrings("Ports: 0.0.0.0:18082->80/tcp", rig.recorder.body[0..rig.recorder.body_len]);
    try testing.expectEqual(@as(usize, 1), rig.recorder.settled);
}

test "Return does nothing on a container that is stopping or removing" {
    var rig: Rig = undefined;
    try rig.init(fleet);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    for ([_][]const u8{ "queue", "gone" }) |query| {
        const row = try rig.rowOf(&index, query);
        try testing.expectEqual(subroutines.Outcome.keep, index.choose(testing.allocator, row.id));
        try testing.expectEqual(@as(u32, 0), index.counters(row.id).?.chosen);
    }
    try testing.expectEqual(subroutines.Outcome.keep, index.choose(testing.allocator, 42));

    try index.work.await(testing.io);
    try testing.expectEqualStrings(
        "ps -a --pod --format json\ncontainer inspect --format json 2222\n",
        try rig.calls(),
    );
    try testing.expectEqual(@as(usize, 0), rig.recorder.settled);
}

test "a failed command warns, notifies with podman's message and still settles" {
    var rig: Rig = undefined;
    try rig.initWith(fleet, "echo 'Error: unable to start container \"2222\": pasta failed with exit code 1:' >&2; " ++
        "echo 'Listen failed for HOST TCP port 127.0.0.1/16379: Address already in use' >&2; exit 125");
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const row = try rig.rowOf(&index, "postgres");
    try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, row.id));
    try index.work.await(testing.io);

    try testing.expectEqual(@as(usize, 1), rig.recorder.notified);
    try testing.expectEqual(notify.Urgency.normal, rig.recorder.urgency);
    try testing.expectEqualStrings("Cannot start postgres", rig.recorder.summary[0..rig.recorder.summary_len]);
    try testing.expectEqualStrings(
        "Error: unable to start container \"2222\": pasta failed with exit code 1:\n" ++
            "Listen failed for HOST TCP port 127.0.0.1/16379: Address already in use",
        rig.recorder.body[0..rig.recorder.body_len],
    );
    try testing.expectEqual(@as(usize, 1), rig.recorder.settled);
}

test "podman's error output is notified without escapes and with valid UTF-8" {
    var rig: Rig = undefined;
    try rig.initWith(fleet, "printf '\\033[31mError\\033[0m: no such file /tmp/caf\\351\\n' >&2; exit 125");
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const row = try rig.rowOf(&index, "postgres");
    try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, row.id));
    try index.work.await(testing.io);

    try testing.expectEqualStrings(
        "Error: no such file /tmp/caf\u{fffd}",
        rig.recorder.body[0..rig.recorder.body_len],
    );
}

test "a command that ends after stop still notifies, but doesn't settle" {
    var rig: Rig = undefined;
    try rig.initWith(fleet, "sleep 0.3");
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const row = try rig.rowOf(&index, "web");
    try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, row.id));
    index.stop();
    try index.work.await(testing.io);

    try testing.expectEqual(@as(usize, 0), rig.recorder.settled);
    try testing.expectEqual(@as(usize, 1), rig.recorder.notified);
    try testing.expectEqualStrings("Stopped web", rig.recorder.summary[0..rig.recorder.summary_len]);
    try testing.expect(std.mem.find(u8, try rig.calls(), "stop 1111\nlogs --tail 3 1111\n") != null);
}

test "a stopped container's notification shows its last log lines" {
    var rig: Rig = undefined;
    try rig.initWith(fleet,
        \\[ "$1" = logs ] && { echo 'listening on :80'; echo 'shutting down' >&2; echo 'bye'; }; exit 0
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const web = try rig.rowOf(&index, "web");
    try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, web.id));
    try index.work.await(testing.io);

    try testing.expectEqualStrings("Stopped web", rig.recorder.summary[0..rig.recorder.summary_len]);
    try testing.expectEqualStrings("listening on :80\nshutting down\nbye", rig.recorder.body[0..rig.recorder.body_len]);
    try testing.expectEqual(notify.Urgency.low, rig.recorder.urgency);
}

test "a container that removes itself is stopped without reading its logs" {
    var rig: Rig = undefined;
    try rig.initWith(
        \\[{"Id": "9999", "Names": ["passing"], "Image": "fedora", "State": "running", "AutoRemove": true}]
    ,
        \\[ "$1" = logs ] && echo 'never read'; exit 0
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const passing = try rig.rowOf(&index, "passing");
    try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, passing.id));
    try index.work.await(testing.io);

    try testing.expectEqualStrings("Stopped passing", rig.recorder.summary[0..rig.recorder.summary_len]);
    try testing.expectEqualStrings("", rig.recorder.body[0..rig.recorder.body_len]);
    try testing.expect(std.mem.endsWith(u8, try rig.calls(), "stop 9999\n"));
}

test "a failed log lookup still notifies the stop, without a body" {
    var rig: Rig = undefined;
    try rig.initWith(fleet,
        \\[ "$1" = logs ] && { echo 'Error: no such container' >&2; exit 125; }; exit 0
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const web = try rig.rowOf(&index, "web");
    try testing.expectEqual(subroutines.Outcome.busy, index.choose(testing.allocator, web.id));
    try index.work.await(testing.io);

    try testing.expectEqualStrings("Stopped web", rig.recorder.summary[0..rig.recorder.summary_len]);
    try testing.expectEqualStrings("", rig.recorder.body[0..rig.recorder.body_len]);
    try testing.expectEqual(@as(usize, 1), rig.recorder.settled);
}

test "a container's details are its actions" {
    var rig: Rig = undefined;
    try rig.init(fleet);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const row = try rig.rowOf(&index, "web");
    const found = try index.actions(rig.owner.allocator(), row.id);

    const Expected = struct { title: []const u8, detail: []const u8 };
    const wanted = [_]Expected{
        .{ .title = "web", .detail = "Name" },
        .{ .title = "1111", .detail = "ID" },
        .{ .title = "docker.io/library/nginx:1.30-alpine", .detail = "Image" },
        .{ .title = "c0ffee", .detail = "Image ID" },
    };
    try testing.expectEqual(wanted.len, found.len);
    for (wanted, found, 0..) |expected, action, at| {
        try testing.expectEqual(@as(u64, at), action.id);
        try testing.expectEqualStrings(expected.title, action.title);
        try testing.expectEqualStrings(expected.detail, action.detail);
    }

    try testing.expectEqual(@as(usize, 0), (try index.actions(rig.owner.allocator(), 42)).len);
    try testing.expectEqual(subroutines.Outcome.keep, index.perform(testing.allocator, row.id, 9));
}
