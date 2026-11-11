const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const fuzzy = @import("core").fuzzy;
const globals = @import("globals.zig");
const jobs = @import("jobs.zig");
const model = @import("../model.zig");
const subroutines = @import("../subroutines.zig");
pub const Target = @import("../extensions.zig").Target;

const Dispatch = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.dispatch);

const max_rows = 200;

pub const When = enum { debounced, now };

pub const Presentation = union(enum) {
    rows: Rows,
    answer: [:0]const u8,
};

pub const Rows = struct {
    all: []const model.Row = &.{},
    selected: usize = 0,
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

    pub fn produce(member: Member, gpa: Allocator, work: Work) Result {
        const owner = subroutines.Owner.create(gpa) catch {
            log.warn("out of memory, so member {s} delivers nothing", .{member.name});
            return .{};
        };

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

    pub fn settle(context: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(context));
        self.rebuild();
    }
};

pub const Runner = jobs.Runner(Job);

gpa: Allocator,
members: []const subroutines.Subroutine,
arrived: []?subroutines.Produced,
display: ?Display = null,
runner: Runner,
debounce_ms: u32,
query: ?[:0]u8 = null,
sources: std.ArrayList(Source) = .empty,
rows: std.ArrayList(model.Row) = .empty,
badges: std.ArrayList(model.Badge) = .empty,
deferred: bool = false,
picks: ?usize = null,
picking: bool = false,
capped: bool = true,
refreshing: bool = false,
kept: ?Source = null,

pub fn init(gpa: Allocator, io: std.Io, debounce_ms: u32) Dispatch {
    return .{
        .gpa = gpa,
        .members = &.{},
        .arrived = &.{},
        .runner = .{ .gpa = gpa, .io = io },
        .debounce_ms = debounce_ms,
    };
}

pub fn setMembers(
    self: *Dispatch,
    members: []const subroutines.Subroutine,
    arrived: []?subroutines.Produced,
    picks: ?usize,
    capped: bool,
) void {
    self.runner.cancel();
    _ = self.runner.bump();
    self.clearArrived();

    self.members = members;
    self.arrived = arrived;
    self.picks = picks;
    self.capped = capped;
    self.refreshing = false;
    self.kept = null;
    for (self.arrived) |*slot| slot.* = null;

    self.sources.clearRetainingCapacity();
    self.rows.clearRetainingCapacity();
    self.badges.clearRetainingCapacity();
}

pub fn schedule(self: *Dispatch, text: []const u8, when: When) void {
    if (self.runner.stopping) return;
    self.runner.cancel();

    const owned = self.gpa.dupeSentinel(u8, text, 0) catch {
        log.warn("out of memory, so \"{s}\" was not dispatched", .{text});
        return;
    };
    if (self.query) |previous| self.gpa.free(previous);
    self.query = owned;
    self.refreshing = false;
    self.kept = null;

    switch (when) {
        .now => self.start(),
        .debounced => if (self.debounce_ms == 0)
            self.start()
        else
            self.runner.after(self, self.debounce_ms),
    }
}

pub fn rerun(self: *Dispatch, selected: ?u64) void {
    if (self.runner.stopping) return;
    self.runner.cancel();

    self.kept = if (selected) |id| self.sourceOf(id) else null;
    self.refreshing = true;
    self.start();
}

pub fn choose(self: *Dispatch, id: u64) subroutines.Outcome {
    const source = self.sourceOf(id) orelse return .keep;
    return self.members[source.member].choose(self.gpa, source.id);
}

pub fn takesArguments(self: *Dispatch, id: u64) bool {
    const source = self.sourceOf(id) orelse return false;
    return self.members[source.member].takesArguments();
}

pub fn chooseWith(self: *Dispatch, id: u64, arguments: []const u8) subroutines.Outcome {
    const source = self.sourceOf(id) orelse return .keep;
    return self.members[source.member].chooseWith(self.gpa, source.id, arguments);
}

pub fn actions(self: *Dispatch, arena: Allocator, id: u64) []const model.Offer {
    const source = self.sourceOf(id) orelse return &.{};
    return offersOf(arena, self.members[source.member], source.id) catch |err| {
        log.warn("member {d} has no actions for {d}: {t}", .{ source.member, id, err });
        return &.{};
    };
}

pub fn perform(self: *Dispatch, id: u64, choice: model.Choice) subroutines.Outcome {
    const source = self.sourceOf(id) orelse return .keep;
    const member = self.members[source.member];
    return switch (choice) {
        .own => |action| member.perform(self.gpa, source.id, action),
        .global => |global| globals.perform(global, member, source.id),
    };
}

fn offersOf(arena: Allocator, member: subroutines.Subroutine, id: u64) subroutines.Error![]const model.Offer {
    const own = try member.actions(arena, id);
    const shared = try globals.offer(arena, member, id);

    const offers = try arena.alloc(model.Offer, own.len + shared.len);
    for (own, offers[0..own.len]) |action, *slot| {
        slot.* = .{
            .title = action.title,
            .detail = action.detail,
            .icon = action.icon,
            .choice = .{ .own = action.id },
        };
    }
    for (shared, offers[own.len..], 0..) |found, *slot, at| {
        slot.* = found;
        slot.separated = at == 0 and own.len > 0;
    }
    return offers;
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
    if (!self.refreshing) self.show(.{ .rows = .{} });

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

        const text = self.gpa.dupeSentinel(u8, query, 0) catch {
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
    self.rebuild();
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
}

fn rebuild(self: *Dispatch) void {
    if (self.refreshing) {
        if (!self.settled()) return;
        self.refreshing = false;
    }
    const kept = self.kept;
    self.kept = null;

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
        return self.show(.{ .rows = .{} });
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

    const wanted = if (self.capped) ranked.items[0..@min(ranked.items.len, max_rows)] else ranked.items;
    if (self.sources.ensureTotalCapacity(self.gpa, wanted.len)) {
        self.rows.ensureTotalCapacity(self.gpa, wanted.len) catch |err| {
            log.err("cannot hold {d} rows, so nothing is shown: {t}", .{ wanted.len, err });
            return self.show(.{ .rows = .{} });
        };
    } else |err| {
        log.err("cannot hold {d} rows, so nothing is shown: {t}", .{ wanted.len, err });
        return self.show(.{ .rows = .{} });
    }

    for (wanted) |entry| {
        const hit = self.hitsOf(entry.member)[entry.at];
        self.sources.appendAssumeCapacity(.{ .member = entry.member, .id = hit.row.id });

        var row = hit.row;
        row.id = self.sources.items.len - 1;
        if (row.verb.len == 0) row.verb = self.members[entry.member].verb;
        self.rows.appendAssumeCapacity(row);
    }

    if (self.rows.items.len > 0) {
        self.attachBadges();
        return self.show(.{ .rows = .{ .all = self.rows.items, .selected = self.positionOf(kept) } });
    }

    const query = self.query orelse "";
    if (!self.deferred and !self.picking and query.len > 0 and self.settled()) {
        self.deferred = true;
        self.spawn(.fallback, self.runner.current());
    }

    if (self.answerOf()) |text| {
        return self.show(.{ .answer = text });
    }
    self.show(.{ .rows = .{} });
}

fn positionOf(self: *Dispatch, wanted: ?Source) usize {
    const found = wanted orelse return 0;
    for (self.sources.items, 0..) |source, at| {
        if (source.member == found.member and source.id == found.id) return at;
    }
    return 0;
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
                if (!subroutines.processes.top(marks, mark, row.program)) continue;
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
};

test "a job runs its query or lists the picks, and frees only the query" {
    var fake: Fake = .{};
    const member: subroutines.Subroutine = .{
        .name = "fake",
        .context = &fake,
        .vtable = subroutines.vtableOf(Fake),
    };

    const query: Request = .{ .query = try testing.allocator.dupeSentinel(u8, "firefox", 0) };
    const ran = Job.produce(member, testing.allocator, query);
    try testing.expectEqual(subroutines.Output.nothing, ran.output);
    ran.release(testing.allocator);
    Job.discard(member, testing.allocator, query);

    try testing.expectEqual(@as(usize, 1), fake.ran);
    try testing.expectEqual(@as(?usize, null), fake.listed);

    const picks: Request = .{ .picks = 5 };
    const listed = Job.produce(member, testing.allocator, picks);
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

test "a row takes the verb of its member unless it brings its own" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    var fake: Fake = .{};
    const members = [_]subroutines.Subroutine{
        .{ .name = "bins", .context = &fake, .vtable = subroutines.vtableOf(Fake), .verb = "Run" },
        .{ .name = "nm", .context = &fake, .vtable = subroutines.vtableOf(Fake), .verb = "Connect" },
    };
    const commands = [_]subroutines.Hit{.{ .row = .{ .id = 4, .title = "zig" }, .score = 30 }};
    const networks = [_]subroutines.Hit{
        .{ .row = .{ .id = 9, .title = "Luna", .verb = "Disconnect" }, .score = 20 },
    };
    var arrived = [_]?subroutines.Produced{
        .{ .output = .{ .hits = &commands } },
        .{ .output = .{ .hits = &networks } },
    };
    dispatch.members = &members;
    dispatch.arrived = &arrived;

    dispatch.rebuild();

    try testing.expectEqual(@as(usize, 2), dispatch.rows.items.len);
    try testing.expectEqualStrings("Run", dispatch.rowOf(0).?.verb);
    try testing.expectEqualStrings("Disconnect", dispatch.rowOf(1).?.verb);
}

test "a row gets a badge for each top process of its program and keeps its own" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    var fake: Fake = .{};
    const members = [_]subroutines.Subroutine{
        .{ .name = "apps", .context = &fake, .vtable = subroutines.vtableOf(Fake) },
        .{ .name = "processes", .context = &fake, .vtable = subroutines.vtableOf(Fake) },
    };
    const own = [_]model.Badge{.{ .status = .{ .text = "beta", .tone = .idle } }};
    const programs = [_]subroutines.Hit{
        .{ .row = .{ .id = 4, .title = "Firefox", .program = "firefox", .badges = &own }, .score = 30 },
        .{ .row = .{ .id = 5, .title = "Konsole", .program = "/usr/bin/konsole" }, .score = 20 },
        .{ .row = .{ .id = 6, .title = "Kate", .program = "/usr/bin/kate" }, .score = 10 },
    };
    const marks = [_]subroutines.Mark{
        .{ .pid = 700, .parent = 1, .name = "konsole", .program = "/usr/bin/konsole" },
        .{ .pid = 701, .parent = 1, .name = "konsole", .program = "/usr/bin/konsole" },
        .{ .pid = 800, .parent = 700, .name = "firefox", .program = "/usr/lib64/firefox/firefox" },
        .{ .pid = 801, .parent = 800, .name = "firefox", .program = "/usr/lib64/firefox/firefox" },
        .{ .pid = 802, .parent = 801, .name = "firefox", .program = "/usr/lib64/firefox/firefox" },
    };
    var arrived = [_]?subroutines.Produced{
        .{ .output = .{ .hits = &programs } },
        .{ .output = .{ .marks = &marks } },
    };
    dispatch.members = &members;
    dispatch.arrived = &arrived;

    dispatch.rebuild();

    const browser = dispatch.rowOf(0).?.badges;
    try testing.expectEqual(@as(usize, 2), browser.len);
    try testing.expectEqualStrings("beta", browser[0].status.text);
    try testing.expectEqual(@as(i32, 800), browser[1].process);

    const terminal = dispatch.rowOf(1).?.badges;
    try testing.expectEqual(@as(usize, 2), terminal.len);
    try testing.expectEqual(@as(i32, 700), terminal[0].process);
    try testing.expectEqual(@as(i32, 701), terminal[1].process);

    try testing.expectEqual(@as(usize, 0), dispatch.rowOf(2).?.badges.len);
}

test "changing the members ends the generation the running jobs carry" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    const before = dispatch.runner.current();
    dispatch.setMembers(&.{}, &.{}, null, true);

    try testing.expect(dispatch.runner.current() != before);
}

const Shown = struct {
    count: usize = 0,
    rows: usize = 0,
    selected: usize = 0,

    fn onDisplay(self: *Shown, what: Presentation) void {
        self.count += 1;
        switch (what) {
            .rows => |shown| {
                self.rows = shown.all.len;
                self.selected = shown.selected;
            },
            .answer => {},
        }
    }
};

test "a rerun keeps the rows on screen until every member has answered" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    var shown: Shown = .{};
    dispatch.display = .of(Shown, Shown.onDisplay, &shown);

    var first: Fake = .{};
    var second: Fake = .{};
    const members = [_]subroutines.Subroutine{
        .{ .name = "bins", .context = &first, .vtable = subroutines.vtableOf(Fake) },
        .{ .name = "apps", .context = &second, .vtable = subroutines.vtableOf(Fake) },
    };
    const commands = [_]subroutines.Hit{.{ .row = .{ .id = 4, .title = "zig" }, .score = 30 }};
    var arrived = [_]?subroutines.Produced{ .{ .output = .{ .hits = &commands } }, null };
    dispatch.members = &members;
    dispatch.arrived = &arrived;
    dispatch.refreshing = true;

    dispatch.rebuild();
    try testing.expectEqual(@as(usize, 0), shown.count);

    arrived[1] = .{};
    dispatch.rebuild();
    try testing.expectEqual(@as(usize, 1), shown.count);
    try testing.expectEqual(@as(usize, 1), shown.rows);
    try testing.expect(!dispatch.refreshing);
}

test "a rerun selects the row that was selected, wherever it moved" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    var shown: Shown = .{};
    dispatch.display = .of(Shown, Shown.onDisplay, &shown);

    var first: Fake = .{};
    var second: Fake = .{};
    const members = [_]subroutines.Subroutine{
        .{ .name = "bins", .context = &first, .vtable = subroutines.vtableOf(Fake) },
        .{ .name = "apps", .context = &second, .vtable = subroutines.vtableOf(Fake) },
    };
    const commands = [_]subroutines.Hit{.{ .row = .{ .id = 4, .title = "zig" }, .score = 30 }};
    const programs = [_]subroutines.Hit{.{ .row = .{ .id = 7, .title = "Zed" }, .score = 20 }};
    var arrived = [_]?subroutines.Produced{
        .{ .output = .{ .hits = &commands } },
        .{ .output = .{ .hits = &programs } },
    };
    dispatch.members = &members;
    dispatch.arrived = &arrived;
    dispatch.query = try testing.allocator.dupeSentinel(u8, "z", 0);
    dispatch.rebuild();
    try testing.expectEqualStrings("Zed", dispatch.rowOf(1).?.title);

    dispatch.rerun(1);
    try testing.expectEqual(@as(usize, 1), shown.count);

    const moved = [_]subroutines.Hit{
        .{ .row = .{ .id = 4, .title = "zig" }, .score = 30 },
        .{ .row = .{ .id = 7, .title = "zag" }, .score = 25 },
    };
    arrived = .{ .{ .output = .{ .hits = &moved } }, .{ .output = .{ .hits = &programs } } };
    dispatch.rebuild();

    try testing.expectEqual(@as(usize, 2), shown.count);
    try testing.expectEqual(@as(usize, 3), shown.rows);
    try testing.expectEqual(@as(usize, 2), shown.selected);
    try testing.expectEqualStrings("Zed", dispatch.rowOf(2).?.title);
}

test "changing the members drops a rerun and sets the cap" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    dispatch.refreshing = true;
    dispatch.kept = .{ .member = 0, .id = 9 };
    dispatch.setMembers(&.{}, &.{}, null, false);

    try testing.expect(!dispatch.refreshing);
    try testing.expectEqual(@as(?Source, null), dispatch.kept);
    try testing.expect(!dispatch.capped);
}

test "a rerun settles when one member failed" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    var shown: Shown = .{};
    dispatch.display = .of(Shown, Shown.onDisplay, &shown);

    var first: Fake = .{};
    var second: Fake = .{};
    const members = [_]subroutines.Subroutine{
        .{ .name = "bins", .context = &first, .vtable = subroutines.vtableOf(Fake) },
        .{ .name = "apps", .context = &second, .vtable = subroutines.vtableOf(Fake) },
    };
    const commands = [_]subroutines.Hit{.{ .row = .{ .id = 4, .title = "zig" }, .score = 30 }};
    var arrived = [_]?subroutines.Produced{ .{ .output = .{ .hits = &commands } }, null };
    dispatch.members = &members;
    dispatch.arrived = &arrived;
    dispatch.refreshing = true;

    const failed = Job.produce(members[1], testing.failing_allocator, .{ .picks = 5 });
    Job.accept(&dispatch, 1, members[1], failed);
    Job.settle(&dispatch);

    try testing.expectEqual(1, shown.count);
    try testing.expectEqual(1, shown.rows);
    try testing.expect(!dispatch.refreshing);
}

test "a debounce of 0 dispatches a query at once, and any other waits for it" {
    var waiting: Dispatch = .init(testing.allocator, testing.io, 300);
    defer waiting.stop();

    var later: Shown = .{};
    waiting.display = .of(Shown, Shown.onDisplay, &later);
    waiting.schedule("zig", .debounced);

    try testing.expectEqual(0, later.count);
    try testing.expect(waiting.runner.pending != 0);

    var direct: Dispatch = .init(testing.allocator, testing.io, 0);
    defer direct.stop();

    var now: Shown = .{};
    direct.display = .of(Shown, Shown.onDisplay, &now);
    direct.schedule("zig", .debounced);

    try testing.expectEqual(1, now.count);
    try testing.expectEqual(0, direct.runner.pending);
}

test "a kept row that is gone selects the first" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    var shown: Shown = .{};
    dispatch.display = .of(Shown, Shown.onDisplay, &shown);

    var fake: Fake = .{};
    const members = [_]subroutines.Subroutine{
        .{ .name = "bins", .context = &fake, .vtable = subroutines.vtableOf(Fake) },
    };
    const commands = [_]subroutines.Hit{
        .{ .row = .{ .id = 4, .title = "zig" }, .score = 30 },
        .{ .row = .{ .id = 5, .title = "zag" }, .score = 25 },
    };
    var arrived = [_]?subroutines.Produced{.{ .output = .{ .hits = &commands } }};
    dispatch.members = &members;
    dispatch.arrived = &arrived;
    dispatch.refreshing = true;
    dispatch.kept = .{ .member = 0, .id = 9 };

    dispatch.rebuild();
    try testing.expectEqual(@as(usize, 2), shown.rows);
    try testing.expectEqual(@as(usize, 0), shown.selected);
    try testing.expectEqual(@as(?Source, null), dispatch.kept);
}

test "a new query after a rerun clears the list again" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    var shown: Shown = .{};
    dispatch.display = .of(Shown, Shown.onDisplay, &shown);
    dispatch.query = try testing.allocator.dupeSentinel(u8, "zig", 0);

    dispatch.rerun(null);
    try testing.expectEqual(@as(usize, 0), shown.count);
    try testing.expect(dispatch.refreshing);

    dispatch.schedule("zag", .now);
    try testing.expectEqual(@as(usize, 1), shown.count);
    try testing.expectEqual(@as(usize, 0), shown.rows);
    try testing.expect(!dispatch.refreshing);
}

test "only an uncapped mode keeps more than 200 rows" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    var fake: Fake = .{};
    const members = [_]subroutines.Subroutine{
        .{ .name = "inca", .context = &fake, .vtable = subroutines.vtableOf(Fake) },
    };
    var hits: [250]subroutines.Hit = undefined;
    for (&hits, 0..) |*hit, at| hit.* = .{ .row = .{ .id = at, .title = "contact" }, .score = 1 };
    var arrived = [_]?subroutines.Produced{.{ .output = .{ .hits = &hits } }};
    dispatch.members = &members;
    dispatch.arrived = &arrived;

    dispatch.rebuild();
    try testing.expectEqual(@as(usize, max_rows), dispatch.rows.items.len);

    dispatch.capped = false;
    dispatch.rebuild();
    try testing.expectEqual(@as(usize, 250), dispatch.rows.items.len);
}

test "the own actions come first and a line opens the global ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const own = [_]subroutines.Action{
        .{ .id = 4, .title = "New Window" },
        .{ .id = 9, .title = "New Private Window" },
    };
    var picked: globals.Fake = .{ .weight = .{ .shown = 2, .chosen = 2 }, .own = &own };

    const offers = try offersOf(arena.allocator(), picked.subroutine(), 7);
    try testing.expectEqual(@as(usize, 3), offers.len);
    try testing.expectEqual(model.Choice{ .own = 4 }, offers[0].choice);
    try testing.expectEqual(model.Choice{ .own = 9 }, offers[1].choice);
    try testing.expectEqual(model.Choice{ .global = .forget }, offers[2].choice);
    try testing.expect(!offers[0].separated and !offers[1].separated);
    try testing.expect(offers[2].separated);
}

test "without own actions the global ones need no line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var picked: globals.Fake = .{ .weight = .{ .chosen = 1 } };
    const offers = try offersOf(arena.allocator(), picked.subroutine(), 7);
    try testing.expectEqual(@as(usize, 1), offers.len);
    try testing.expect(!offers[0].separated);
}

test "a global action reaches the row's own subroutine under the subroutine's id" {
    var dispatch: Dispatch = .init(testing.allocator, testing.io, 300);
    defer dispatch.stop();

    var other: Fake = .{};
    var picked: globals.Fake = .{ .weight = .{ .chosen = 2 } };
    const members = [_]subroutines.Subroutine{
        .{ .name = "bins", .context = &other, .vtable = subroutines.vtableOf(Fake) },
        picked.subroutine(),
    };
    const commands = [_]subroutines.Hit{.{ .row = .{ .id = 4, .title = "zig" }, .score = 30 }};
    const counted = [_]subroutines.Hit{.{ .row = .{ .id = 7, .title = "Zed" }, .score = 20 }};
    var arrived = [_]?subroutines.Produced{
        .{ .output = .{ .hits = &commands } },
        .{ .output = .{ .hits = &counted } },
    };
    dispatch.members = &members;
    dispatch.arrived = &arrived;
    dispatch.rebuild();

    try testing.expectEqual(subroutines.Outcome.close, dispatch.perform(1, .{ .own = 3 }));
    try testing.expectEqual(@as(?u64, 3), picked.performed);

    try testing.expectEqual(subroutines.Outcome.refresh, dispatch.perform(1, .{ .global = .forget }));
    try testing.expectEqual(@as(?u64, 7), picked.forgotten);
}
