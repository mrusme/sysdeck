const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const fuzzy = @import("core").fuzzy;
const jobs = @import("jobs.zig");
const model = @import("../model.zig");
const subroutines = @import("../subroutines.zig");
pub const Target = @import("../extensions.zig").Target;

const Dispatch = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.dispatch);

const debounce_ms = 300;
const max_rows = 200;

pub const When = enum { debounced, now };

pub const Presentation = union(enum) {
    rows: []const model.Row,
    answer: [:0]const u8,
};

pub const Display = Callback(fn (what: Presentation) void);

const Source = struct {
    member: usize,
    id: u64,
};

const Ranked = struct {
    member: usize,
    at: usize,
    score: fuzzy.Score,

    fn before(_: void, left: Ranked, right: Ranked) bool {
        if (left.score != right.score) return left.score > right.score;
        if (left.member != right.member) return left.member < right.member;
        return left.at < right.at;
    }
};

const Request = union(enum) {
    query: [:0]u8,
    picks: usize,
};

const Job = struct {
    pub const Member = subroutines.Subroutine;
    pub const Work = Request;
    pub const Result = subroutines.Produced;

    pub fn begin(context: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(context));
        self.start();
    }

    pub fn produce(member: Member, gpa: Allocator, work: Work) ?Result {
        const owner = subroutines.Owner.create(gpa) catch return null;

        const output = switch (work) {
            .query => |text| member.run(owner, text),
            .picks => |limit| member.picks(owner, limit),
        };

        return .{ .owner = owner, .output = output catch |err| block: {
            switch (work) {
                .query => |text| log.warn("a member failed on \"{s}\": {t}", .{ text, err }),
                .picks => log.warn("a member failed to list its picks: {t}", .{err}),
            }
            break :block .nothing;
        } };
    }

    pub fn discard(_: Member, gpa: Allocator, work: Work) void {
        switch (work) {
            .query => |text| gpa.free(text),
            .picks => {},
        }
    }

    pub fn release(_: Member, gpa: Allocator, result: Result) void {
        result.release(gpa);
    }

    pub fn accept(context: *anyopaque, at: usize, _: Member, result: Result) void {
        const self: *Dispatch = @ptrCast(@alignCast(context));
        if (at >= self.arrived.len) return result.release(self.gpa);
        self.deliver(at, result);
    }
};

pub const Runner = jobs.Runner(Job);

gpa: Allocator,
members: []const subroutines.Subroutine,
arrived: []?subroutines.Produced,
display: ?Display = null,
runner: Runner,
query: ?[:0]u8 = null,
sources: std.ArrayList(Source) = .empty,
rows: std.ArrayList(model.Row) = .empty,
badges: std.ArrayList(model.Badge) = .empty,
deferred: bool = false,
picks: ?usize = null,
picking: bool = false,

pub fn init(gpa: Allocator, io: std.Io) Dispatch {
    return .{
        .gpa = gpa,
        .members = &.{},
        .arrived = &.{},
        .runner = .{ .gpa = gpa, .io = io },
    };
}

pub fn setMembers(
    self: *Dispatch,
    members: []const subroutines.Subroutine,
    arrived: []?subroutines.Produced,
    picks: ?usize,
) void {
    self.runner.cancel();
    _ = self.runner.bump();
    self.clearArrived();

    self.members = members;
    self.arrived = arrived;
    self.picks = picks;
    for (self.arrived) |*slot| slot.* = null;

    self.sources.clearRetainingCapacity();
    self.rows.clearRetainingCapacity();
    self.badges.clearRetainingCapacity();
}

pub fn schedule(self: *Dispatch, text: []const u8, when: When) void {
    if (self.runner.stopping) return;
    self.runner.cancel();

    const owned = self.gpa.dupeZ(u8, text) catch {
        log.warn("out of memory, so \"{s}\" was not dispatched", .{text});
        return;
    };
    if (self.query) |previous| self.gpa.free(previous);
    self.query = owned;

    switch (when) {
        .now => self.start(),
        .debounced => self.runner.after(self, debounce_ms),
    }
}

pub fn choose(self: *Dispatch, id: u64) subroutines.Outcome {
    const source = self.sourceOf(id) orelse return .keep;
    return self.members[source.member].choose(self.gpa, source.id);
}

pub fn actions(self: *Dispatch, arena: Allocator, id: u64) []const subroutines.Action {
    const source = self.sourceOf(id) orelse return &.{};
    return self.members[source.member].actions(arena, source.id) catch |err| {
        log.warn("member {d} has no actions for {d}: {t}", .{ source.member, id, err });
        return &.{};
    };
}

pub fn perform(self: *Dispatch, id: u64, action: u64) subroutines.Outcome {
    const source = self.sourceOf(id) orelse return .keep;
    return self.members[source.member].perform(self.gpa, source.id, action);
}

fn sourceOf(self: *Dispatch, id: u64) ?Source {
    const at: usize = @intCast(id);
    if (at >= self.sources.items.len) return null;
    return self.sources.items[at];
}

pub fn rowOf(self: *Dispatch, id: u64) ?model.Row {
    const at: usize = @intCast(id);
    if (at >= self.sources.items.len or at >= self.rows.items.len) return null;
    return self.rows.items[at];
}

pub fn target(self: *Dispatch, id: u64) ?Target {
    const at: usize = @intCast(id);
    const row = self.rowOf(id) orelse return null;
    return .{
        .source = self.members[self.sources.items[at].member].name,
        .title = row.title,
        .detail = row.detail,
        .media = row.media,
    };
}

pub fn stop(self: *Dispatch) void {
    self.runner.stop();

    self.clearArrived();
    self.sources.deinit(self.gpa);
    self.rows.deinit(self.gpa);
    self.badges.deinit(self.gpa);
    if (self.query) |previous| self.gpa.free(previous);
    self.query = null;
}

fn start(self: *Dispatch) void {
    if (self.runner.stopping) return;

    const query = self.query orelse return;
    const generation = self.runner.bump();
    log.debug("generation {d} for \"{s}\"", .{ generation, query });

    self.clearArrived();
    self.sources.clearRetainingCapacity();
    self.rows.clearRetainingCapacity();
    self.badges.clearRetainingCapacity();
    self.deferred = false;
    self.picking = false;
    self.show(.{ .rows = &.{} });

    if (self.picks) |limit| {
        if (blank(query)) {
            self.picking = true;
            return self.spawnPicks(limit, generation);
        }
    }
    self.spawn(.immediate, generation);
}

fn spawn(self: *Dispatch, stage: subroutines.Stage, generation: u64) void {
    const query = self.query orelse return;

    for (self.members, 0..) |member, at| {
        if (member.stage != stage) continue;

        const text = self.gpa.dupeZ(u8, query) catch {
            log.warn("out of memory, so member {d} was not started", .{at});
            self.forget(at);
            continue;
        };

        if (!self.runner.spawn(self, at, member, generation, .{ .query = text })) {
            self.gpa.free(text);
            self.forget(at);
        }
    }
}

fn spawnPicks(self: *Dispatch, limit: usize, generation: u64) void {
    for (self.members, 0..) |member, at| {
        if (!member.recommends()) {
            self.forget(at);
            continue;
        }

        if (!self.runner.spawn(self, at, member, generation, .{ .picks = limit })) {
            self.forget(at);
        }
    }
}

fn forget(self: *Dispatch, at: usize) void {
    self.deliver(at, .{});
}

fn settled(self: *Dispatch) bool {
    for (self.members, self.arrived) |member, slot| {
        if (member.stage == .immediate and slot == null) return false;
    }
    return true;
}

fn answerOf(self: *Dispatch) ?[:0]const u8 {
    for (self.arrived) |slot| {
        switch ((slot orelse continue).output) {
            .answer => |text| return text,
            else => {},
        }
    }
    return null;
}

fn deliver(self: *Dispatch, member: usize, produced: subroutines.Produced) void {
    if (self.arrived[member]) |previous| previous.release(self.gpa);
    self.arrived[member] = produced;
    self.rebuild();
}

fn rebuild(self: *Dispatch) void {
    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(self.gpa);

    var total: usize = 0;
    for (self.arrived) |slot| {
        total += switch ((slot orelse continue).output) {
            .hits => |found| found.len,
            else => continue,
        };
    }

    ranked.ensureTotalCapacity(self.gpa, total) catch |err| {
        log.err("cannot rank {d} hits, so nothing is shown: {t}", .{ total, err });
        return self.show(.{ .rows = &.{} });
    };

    for (self.arrived, 0..) |slot, member| {
        const hits = switch ((slot orelse continue).output) {
            .hits => |found| found,
            else => continue,
        };
        for (hits, 0..) |hit, at| {
            ranked.appendAssumeCapacity(.{
                .member = member,
                .at = at,
                .score = hit.score,
            });
        }
    }

    std.mem.sort(Ranked, ranked.items, {}, Ranked.before);

    self.sources.clearRetainingCapacity();
    self.rows.clearRetainingCapacity();
    self.badges.clearRetainingCapacity();

    const wanted = ranked.items[0..@min(ranked.items.len, max_rows)];
    if (self.sources.ensureTotalCapacity(self.gpa, wanted.len)) {
        self.rows.ensureTotalCapacity(self.gpa, wanted.len) catch |err| {
            log.err("cannot hold {d} rows, so nothing is shown: {t}", .{ wanted.len, err });
            return self.show(.{ .rows = &.{} });
        };
    } else |err| {
        log.err("cannot hold {d} rows, so nothing is shown: {t}", .{ wanted.len, err });
        return self.show(.{ .rows = &.{} });
    }

    for (wanted) |entry| {
        const hit = self.hitsOf(entry.member)[entry.at];
        self.sources.appendAssumeCapacity(.{ .member = entry.member, .id = hit.row.id });

        var row = hit.row;
        row.id = self.sources.items.len - 1;
        self.rows.appendAssumeCapacity(row);
    }

    if (self.rows.items.len > 0) {
        self.attachBadges();
        return self.show(.{ .rows = self.rows.items });
    }

    const query = self.query orelse "";
    if (!self.deferred and !self.picking and query.len > 0 and self.settled()) {
        self.deferred = true;
        self.spawn(.fallback, self.runner.current());
    }

    if (self.answerOf()) |text| {
        return self.show(.{ .answer = text });
    }
    self.show(.{ .rows = &.{} });
}

fn show(self: *Dispatch, what: Presentation) void {
    const found = self.display orelse return;
    found.call(.{what});
}

fn hitsOf(self: *Dispatch, member: usize) []const subroutines.Hit {
    return switch (self.arrived[member].?.output) {
        .hits => |found| found,
        else => &.{},
    };
}

fn attachBadges(self: *Dispatch) void {
    var spans: std.ArrayList(usize) = .empty;
    defer spans.deinit(self.gpa);

    spans.ensureTotalCapacity(self.gpa, self.rows.items.len) catch |err| {
        log.warn("cannot hold the badges of {d} rows: {t}", .{ self.rows.items.len, err });
        return;
    };

    for (self.rows.items) |row| {
        spans.appendAssumeCapacity(self.badges.items.len);
        for (row.badges) |worn| self.badges.append(self.gpa, worn) catch |err| {
            log.warn("cannot hold a badge of \"{s}\": {t}", .{ row.title, err });
        };
        if (row.program.len == 0) continue;

        for (self.arrived) |slot| {
            const marks = switch ((slot orelse continue).output) {
                .marks => |found| found,
                else => continue,
            };
            for (marks) |mark| {
                if (!subroutines.processes.belongs(mark, row.program)) continue;
                self.badges.append(self.gpa, .{ .process = mark.pid }) catch |err| {
                    log.warn("cannot hold a badge of \"{s}\": {t}", .{ row.title, err });
                };
            }
        }
    }

    for (self.rows.items, 0..) |*row, at| {
        if (at >= spans.items.len) break;
        const from = spans.items[at];
        const to = if (at + 1 < spans.items.len) spans.items[at + 1] else self.badges.items.len;
        row.badges = self.badges.items[from..to];
    }
}

fn clearArrived(self: *Dispatch) void {
    for (self.arrived, 0..) |slot, member| {
        const produced = slot orelse continue;
        produced.release(self.gpa);
        self.arrived[member] = null;
    }
}

fn blank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t").len == 0;
}

const testing = std.testing;

const Fake = struct {
    ran: usize = 0,
    listed: ?usize = null,

    pub fn run(
        self: *Fake,
        _: *subroutines.Owner,
        _: []const u8,
    ) subroutines.Error!subroutines.Output {
        self.ran += 1;
        return .nothing;
    }

    pub fn picks(
        self: *Fake,
        _: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        self.listed = limit;
        return .nothing;
    }

    pub fn choose(_: *Fake, _: Allocator, _: u64) subroutines.Outcome {
        return .keep;
    }

    pub fn stale(_: *Fake) bool {
        return false;
    }

    pub fn refresh(_: *Fake) void {}

    pub fn retire(_: *Fake, _: ?*@import("core").store.Store) void {}
};

test "a job runs its query or lists the picks, and frees only the query" {
    var fake: Fake = .{};
    const member: subroutines.Subroutine = .{
        .name = "fake",
        .context = &fake,
        .vtable = subroutines.vtableOf(Fake),
    };

    const query: Request = .{ .query = try testing.allocator.dupeZ(u8, "firefox") };
    const ran = Job.produce(member, testing.allocator, query).?;
    try testing.expectEqual(subroutines.Output.nothing, ran.output);
    ran.release(testing.allocator);
    Job.discard(member, testing.allocator, query);

    try testing.expectEqual(@as(usize, 1), fake.ran);
    try testing.expectEqual(@as(?usize, null), fake.listed);

    const picks: Request = .{ .picks = 5 };
    const listed = Job.produce(member, testing.allocator, picks).?;
    try testing.expectEqual(subroutines.Output.nothing, listed.output);
    listed.release(testing.allocator);
    Job.discard(member, testing.allocator, picks);

    try testing.expectEqual(@as(usize, 1), fake.ran);
    try testing.expectEqual(@as(?usize, 5), fake.listed);
}

test "a query of spaces and tabs is blank" {
    try testing.expect(blank(""));
    try testing.expect(blank(" \t "));
    try testing.expect(!blank(" fire "));
}

test "changing the members ends the generation the running jobs carry" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io);
    defer dispatch.stop();

    const before = dispatch.runner.current();
    dispatch.setMembers(&.{}, &.{}, null);

    try testing.expect(dispatch.runner.current() != before);
}
