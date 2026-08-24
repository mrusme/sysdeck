const std = @import("std");
const c = @import("c.zig");
const fuzzy = @import("fuzzy.zig");
const list = @import("list.zig");
const subroutines = @import("subroutines.zig");
const Target = @import("extensions.zig").Target;

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
    call: *const fn (context: *anyopaque, what: Presentation) void,
    context: *anyopaque,
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

const Delivery = struct {
    dispatch: *Dispatch,
    member: usize,
    generation: u64,
    output: subroutines.Output,
};

pub const Dispatch = struct {
    gpa: Allocator,
    members: []const subroutines.Subroutine,
    arrived: []?subroutines.Output,
    display: Display,
    generation: std.atomic.Value(u64) = .init(0),
    inflight: std.atomic.Value(usize) = .init(0),
    pending: c.guint = 0,
    query: ?[:0]u8 = null,
    sources: std.ArrayList(Source) = .empty,
    rows: std.ArrayList(list.Row) = .empty,
    badges: std.ArrayList(list.Badge) = .empty,
    deferred: bool = false,
    stopping: bool = false,

    pub fn setMembers(
        self: *Dispatch,
        members: []const subroutines.Subroutine,
        arrived: []?subroutines.Output,
    ) void {
        self.cancelPending();
        self.clearArrived();

        self.members = members;
        self.arrived = arrived;
        for (self.arrived) |*slot| slot.* = null;

        self.sources.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.badges.clearRetainingCapacity();
    }

    pub fn schedule(self: *Dispatch, text: []const u8, when: When) void {
        self.cancelPending();

        const owned = self.gpa.dupeZ(u8, text) catch {
            log.warn("out of memory, so \"{s}\" was not dispatched", .{text});
            return;
        };
        if (self.query) |previous| self.gpa.free(previous);
        self.query = owned;

        switch (when) {
            .now => self.start(),
            .debounced => self.pending = c.g_timeout_add(debounce_ms, &onTimeout, self),
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
        };
    }

    pub fn stop(self: *Dispatch) void {
        self.stopping = true;
        self.cancelPending();

        while (self.inflight.load(.acquire) != 0) std.Thread.yield() catch {};

        const context = c.g_main_context_default();
        while (c.g_main_context_iteration(context, c.FALSE) != c.FALSE) {}

        self.clearArrived();
        self.sources.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.badges.deinit(self.gpa);
        if (self.query) |previous| self.gpa.free(previous);
        self.query = null;
    }

    fn cancelPending(self: *Dispatch) void {
        if (self.pending == 0) return;
        _ = c.g_source_remove(self.pending);
        self.pending = 0;
    }

    fn start(self: *Dispatch) void {
        const query = self.query orelse return;
        const generation = self.generation.fetchAdd(1, .release) + 1;
        log.debug("generation {d} for \"{s}\"", .{ generation, query });

        self.clearArrived();
        self.sources.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.badges.clearRetainingCapacity();
        self.deferred = false;
        self.display.call(self.display.context, .{ .rows = &.{} });

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

            _ = self.inflight.fetchAdd(1, .acquire);
            const worker = std.Thread.spawn(.{}, work, .{ self, at, generation, text }) catch |err| {
                log.warn("cannot start a worker: {t}", .{err});
                _ = self.inflight.fetchSub(1, .release);
                self.gpa.free(text);
                self.arrived[at] = .nothing;
                continue;
            };
            worker.detach();
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

        // A fallback answers what nothing else could, is held back until every
        // immediate member has arrived with nothing to show.
        const query = self.query orelse "";
        if (!self.deferred and query.len > 0 and self.settled()) {
            self.deferred = true;
            self.spawn(.fallback, self.generation.load(.acquire));
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

    // Badges are filled for every row before any row is handed a slice, so a
    // later append cannot move the memory an earlier row points at.
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

fn work(self: *Dispatch, member: usize, generation: u64, text: [:0]u8) void {
    defer _ = self.inflight.fetchSub(1, .release);
    defer self.gpa.free(text);

    // A member that never arrives would hold back the fallback stage for the
    // rest of the generation, so a failure arrives as nothing found.
    const output = self.members[member].run(self.gpa, text) catch |err| block: {
        log.warn("member {d} failed on \"{s}\": {t}", .{ member, text, err });
        break :block subroutines.Output.nothing;
    };

    const delivery = self.gpa.create(Delivery) catch {
        self.members[member].release(self.gpa, output);
        return;
    };
    delivery.* = .{
        .dispatch = self,
        .member = member,
        .generation = generation,
        .output = output,
    };

    _ = c.g_idle_add(&onDelivery, delivery);
}

fn onTimeout(data: c.gpointer) callconv(.c) c.gboolean {
    const self: *Dispatch = @ptrCast(@alignCast(data.?));
    self.pending = 0;
    self.start();
    return c.source_remove;
}

fn onDelivery(data: c.gpointer) callconv(.c) c.gboolean {
    const delivery: *Delivery = @ptrCast(@alignCast(data.?));
    const self = delivery.dispatch;
    defer self.gpa.destroy(delivery);

    const stale = delivery.generation != self.generation.load(.acquire);
    if (self.stopping or stale) {
        self.members[delivery.member].release(self.gpa, delivery.output);
        return c.source_remove;
    }

    self.deliver(delivery.member, delivery.output);
    return c.source_remove;
}
