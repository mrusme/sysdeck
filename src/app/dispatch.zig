const std = @import("std");
const fuzzy = @import("core").fuzzy;
const jobs = @import("jobs.zig");
const list = @import("../ui/list.zig");
const subroutines = @import("../subroutines.zig");
pub const Target = @import("../extensions.zig").Target;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.dispatch);

const debounce_ms = 300;
const max_rows = 200;

pub const When = enum { debounced, now };

pub const Presentation = union(enum) {
    rows: []const list.Row,
    answer: [:0]const u8,
};

pub const Display = struct {
    call: *const fn (context: *anyopaque, what: Presentation) void = &ignore,
    context: *anyopaque = undefined,

    fn ignore(_: *anyopaque, _: Presentation) void {}
};

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
    pub const Result = subroutines.Output;

    pub fn begin(owner: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(owner));
        self.start();
    }

    pub fn produce(member: Member, gpa: Allocator, work: Work) ?Result {
        const output = switch (work) {
            .query => |text| member.run(gpa, text),
            .picks => |limit| member.picks(gpa, limit),
        };

        return output catch |err| block: {
            switch (work) {
                .query => |text| log.warn("a member failed on \"{s}\": {t}", .{ text, err }),
                .picks => log.warn("a member failed to list its picks: {t}", .{err}),
            }
            break :block Result.nothing;
        };
    }

    pub fn discard(_: Member, gpa: Allocator, work: Work) void {
        switch (work) {
            .query => |text| gpa.free(text),
            .picks => {},
        }
    }

    pub fn release(member: Member, gpa: Allocator, result: Result) void {
        member.release(gpa, result);
    }

    pub fn accept(owner: *anyopaque, at: usize, member: Member, result: Result) void {
        const self: *Dispatch = @ptrCast(@alignCast(owner));
        if (at >= self.arrived.len) return release(member, self.gpa, result);
        self.deliver(at, result);
    }
};

pub const Runner = jobs.Runner(Job);

pub const Dispatch = struct {
    gpa: Allocator,
    members: []const subroutines.Subroutine,
    arrived: []?subroutines.Output,
    display: Display,
    runner: Runner,
    query: ?[:0]u8 = null,
    sources: std.ArrayList(Source) = .empty,
    rows: std.ArrayList(list.Row) = .empty,
    badges: std.ArrayList(list.Badge) = .empty,
    deferred: bool = false,
    picks: ?usize = null,
    picking: bool = false,

    pub fn init(gpa: Allocator, io: std.Io) Dispatch {
        return .{
            .gpa = gpa,
            .members = &.{},
            .arrived = &.{},
            .display = .{},
            .runner = .{ .gpa = gpa, .io = io },
        };
    }

    pub fn setMembers(
        self: *Dispatch,
        members: []const subroutines.Subroutine,
        arrived: []?subroutines.Output,
        picks: ?usize,
    ) void {
        self.runner.cancel();
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

    pub fn rowOf(self: *Dispatch, id: u64) ?list.Row {
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
        self.display.call(self.display.context, .{ .rows = &.{} });

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
                self.arrived[at] = .nothing;
                continue;
            };

            if (!self.runner.spawn(self, at, member, generation, .{ .query = text })) {
                self.gpa.free(text);
                self.arrived[at] = .nothing;
            }
        }
    }

    fn spawnPicks(self: *Dispatch, limit: usize, generation: u64) void {
        for (self.members, 0..) |member, at| {
            if (!member.recommends()) {
                self.arrived[at] = .nothing;
                continue;
            }

            if (!self.runner.spawn(self, at, member, generation, .{ .picks = limit })) {
                self.arrived[at] = .nothing;
            }
        }
    }

    fn settled(self: *Dispatch) bool {
        for (self.members, self.arrived) |member, slot| {
            if (member.stage == .immediate and slot == null) return false;
        }
        return true;
    }

    fn answerOf(self: *Dispatch) ?[:0]const u8 {
        for (self.arrived) |slot| {
            switch (slot orelse continue) {
                .answer => |text| return text,
                else => {},
            }
        }
        return null;
    }

    fn deliver(self: *Dispatch, member: usize, output: subroutines.Output) void {
        if (self.arrived[member]) |previous| self.members[member].release(self.gpa, previous);
        self.arrived[member] = output;
        self.rebuild();
    }

    fn rebuild(self: *Dispatch) void {
        var ranked: std.ArrayList(Ranked) = .empty;
        defer ranked.deinit(self.gpa);

        for (self.arrived, 0..) |slot, member| {
            const hits = switch (slot orelse continue) {
                .hits => |found| found,
                else => continue,
            };
            for (hits, 0..) |hit, at| {
                ranked.append(self.gpa, .{
                    .member = member,
                    .at = at,
                    .score = hit.score,
                }) catch break;
            }
        }

        std.mem.sort(Ranked, ranked.items, {}, Ranked.before);

        self.sources.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.badges.clearRetainingCapacity();

        for (ranked.items[0..@min(ranked.items.len, max_rows)]) |entry| {
            const hit = self.hitsOf(entry.member)[entry.at];
            self.sources.append(self.gpa, .{ .member = entry.member, .id = hit.row.id }) catch break;

            var row = hit.row;
            row.id = self.sources.items.len - 1;
            self.rows.append(self.gpa, row) catch break;
        }

        if (self.rows.items.len > 0) {
            self.attachBadges();
            return self.display.call(self.display.context, .{ .rows = self.rows.items });
        }

        const query = self.query orelse "";
        if (!self.deferred and !self.picking and query.len > 0 and self.settled()) {
            self.deferred = true;
            self.spawn(.fallback, self.runner.current());
        }

        if (self.answerOf()) |text| {
            return self.display.call(self.display.context, .{ .answer = text });
        }
        self.display.call(self.display.context, .{ .rows = &.{} });
    }

    fn hitsOf(self: *Dispatch, member: usize) []const subroutines.Hit {
        return switch (self.arrived[member].?) {
            .hits => |found| found,
            else => &.{},
        };
    }

    fn attachBadges(self: *Dispatch) void {
        var spans: std.ArrayList(usize) = .empty;
        defer spans.deinit(self.gpa);

        for (self.rows.items) |row| {
            spans.append(self.gpa, self.badges.items.len) catch break;
            if (row.program.len == 0) continue;

            for (self.arrived) |slot| {
                const marks = switch (slot orelse continue) {
                    .marks => |found| found,
                    else => continue,
                };
                for (marks) |mark| {
                    if (!subroutines.processes.belongs(mark, row.program)) continue;
                    self.badges.append(self.gpa, .{ .pid = mark.pid }) catch break;
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
            const output = slot orelse continue;
            self.members[member].release(self.gpa, output);
            self.arrived[member] = null;
        }
    }
};

fn blank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t").len == 0;
}

const testing = std.testing;

const Fake = struct {
    ran: usize = 0,
    listed: ?usize = null,

    pub fn run(self: *Fake, _: Allocator, _: []const u8) subroutines.Error!subroutines.Output {
        self.ran += 1;
        return .nothing;
    }

    pub fn picks(self: *Fake, _: Allocator, limit: usize) subroutines.Error!subroutines.Output {
        self.listed = limit;
        return .nothing;
    }

    pub fn choose(_: *Fake, _: Allocator, _: u64) subroutines.Outcome {
        return .keep;
    }

    pub fn release(_: *Fake, _: Allocator, _: subroutines.Output) void {}

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
    try testing.expectEqual(subroutines.Output.nothing, Job.produce(member, testing.allocator, query).?);
    Job.discard(member, testing.allocator, query);

    try testing.expectEqual(@as(usize, 1), fake.ran);
    try testing.expectEqual(@as(?usize, null), fake.listed);

    const picks: Request = .{ .picks = 5 };
    try testing.expectEqual(subroutines.Output.nothing, Job.produce(member, testing.allocator, picks).?);
    Job.discard(member, testing.allocator, picks);

    try testing.expectEqual(@as(usize, 1), fake.ran);
    try testing.expectEqual(@as(?usize, 5), fake.listed);
}

test "a query of spaces and tabs is blank" {
    try testing.expect(blank(""));
    try testing.expect(blank(" \t "));
    try testing.expect(!blank(" fire "));
}
