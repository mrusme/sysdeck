const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const c = @import("../gtk/c.zig");
const chat_mod = @import("../llm/chat.zig");
const config_mod = @import("../config.zig");
const glib = @import("../gtk/glib.zig");
const service_mod = @import("../llm/service.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const zenai = @import("zenai");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.llm);

pub const table = tables.llm;

pub const setting = "llm_provider";

pub const State = enum { idle, running, done, failed };

pub const Trouble = enum { none, missing_key, refused, lost };

pub const Notify = Callback(fn () void);

pub const Index = struct {
    gpa: Allocator,
    io: std.Io,
    services: []const service_mod.Service,
    store: ?*store_mod.Store,
    chat: chat_mod.Chat,
    chosen: usize = 0,
    notify: ?Notify = null,

    guard: std.Io.Mutex = .init,
    streamed: std.ArrayList(u8) = .empty,
    posted: bool = false,
    state: State = .idle,
    trouble: Trouble = .none,
    interrupt: zenai.http.Interrupt = .{},
    group: std.Io.Group = .init,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Index) };
    }

    pub fn run(_: *Index, _: *subroutines.Owner, _: []const u8) subroutines.Error!subroutines.Output {
        return .nothing;
    }

    pub fn choose(_: *Index, _: Allocator, _: u64) subroutines.Outcome {
        return .keep;
    }

    pub fn stale(_: *Index) bool {
        return false;
    }

    pub fn refresh(_: *Index) void {}

    pub fn retire(self: *Index, _: ?*store_mod.Store) void {
        self.interrupt.fire();
        self.group.await(self.io) catch |err| switch (err) {
            error.Canceled => {},
        };

        self.chat.deinit();
        self.streamed.deinit(self.gpa);
        service_mod.release(self.gpa, self.services);
    }

    pub fn names(self: *Index, arena: Allocator) Allocator.Error![]const [:0]const u8 {
        const out = try arena.alloc([:0]const u8, self.services.len);
        for (self.services, out) |found, *slot| slot.* = found.name;
        return out;
    }

    pub fn service(self: *Index) ?service_mod.Service {
        if (self.chosen >= self.services.len) return null;
        return self.services[self.chosen];
    }

    pub fn pick(self: *Index, at: usize) void {
        if (at >= self.services.len or at == self.chosen) return;

        self.chosen = at;
        const store = self.store orelse return;
        store.remember(setting, self.services[at].name);
    }

    pub fn restore(self: *Index) void {
        const store = self.store orelse return;

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();

        const wanted = store.setting(arena.allocator(), setting) orelse return;
        for (self.services, 0..) |found, at| {
            if (std.mem.eql(u8, found.name, wanted)) {
                self.chosen = at;
                return;
            }
        }
    }

    pub fn busy(self: *Index) bool {
        return self.state == .running;
    }

    pub fn start(self: *Index, prompt: []const u8) bool {
        if (self.busy()) return false;

        const wanted = self.service() orelse return false;
        self.chat.ask(prompt) catch return false;

        const turns = self.gpa.dupe(chat_mod.Turn, self.chat.turns.items) catch return false;

        self.streamed.clearRetainingCapacity();
        self.state = .running;
        self.trouble = .none;
        self.interrupt.reset();

        self.group.concurrent(self.io, work, .{ self, wanted, turns }) catch {
            self.gpa.free(turns);
            self.state = .failed;
            self.trouble = .refused;
            return false;
        };
        return true;
    }

    pub fn abort(self: *Index) void {
        if (!self.busy()) return;
        self.interrupt.fire();
    }

    pub fn settle(self: *Index) State {
        self.guard.lockUncancelable(self.io);
        const wanted = self.state;
        const streamed = self.streamed.items;
        self.guard.unlock(self.io);

        if (wanted != .done and wanted != .failed) return wanted;

        if (streamed.len > 0) self.chat.answer(streamed) catch |err| {
            log.warn("cannot add the reply to the transcript: {t}", .{err});
        };
        self.streamed.clearRetainingCapacity();
        self.state = .idle;
        return wanted;
    }

    pub fn transcript(self: *Index, arena: Allocator) Allocator.Error![:0]u8 {
        self.guard.lockUncancelable(self.io);
        defer self.guard.unlock(self.io);

        return self.chat.transcript(arena, self.streamed.items);
    }

    pub fn note(self: *Index, text: []const u8) void {
        self.chat.answer(text) catch |err| {
            log.warn("cannot add the notice to the transcript: {t}", .{err});
        };
        self.trouble = .none;
    }

    pub fn clear(self: *Index) void {
        if (self.busy()) return;

        self.chat.clear();
        self.streamed.clearRetainingCapacity();
        self.state = .idle;
        self.trouble = .none;
    }

    fn post(self: *Index) void {
        if (self.posted) return;

        self.posted = true;
        _ = glib.g_idle_add(&onIdle, self);
    }
};

fn work(self: *Index, wanted: service_mod.Service, turns: []chat_mod.Turn) void {
    defer self.gpa.free(turns);

    const outcome = service_mod.run(self.io, self.gpa, wanted, turns, &self.interrupt, .{
        .call = &onDelta,
        .context = self,
    });

    self.guard.lockUncancelable(self.io);
    defer self.guard.unlock(self.io);

    if (outcome) |_| {
        self.state = .done;
    } else |err| {
        self.state = .failed;
        self.trouble = switch (err) {
            error.MissingKey => .missing_key,
            else => .refused,
        };
    }
    self.post();
}

fn onDelta(context: *anyopaque, text: []const u8) void {
    const self: *Index = @ptrCast(@alignCast(context));

    self.guard.lockUncancelable(self.io);
    defer self.guard.unlock(self.io);

    self.streamed.appendSlice(self.gpa, text) catch |err| {
        log.warn("cannot keep {d} bytes of the reply: {t}", .{ text.len, err });
        self.trouble = .lost;
    };
    self.post();
}

fn onIdle(data: c.gpointer) callconv(.c) c.gboolean {
    const self: *Index = @ptrCast(@alignCast(data.?));

    self.guard.lockUncancelable(self.io);
    self.posted = false;
    self.guard.unlock(self.io);

    if (self.notify) |found| found.call(.{});
    return c.source_remove;
}

pub fn enabled(settings: config_mod.Config.Sources.Llm) bool {
    if (settings.providers.len > 0) return true;

    log.debug("no [[sources.llm.providers]] entry is configured", .{});
    return false;
}

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    const settings = context.settings.sources.llm;
    if (!context.wanted("llm") or !enabled(settings)) return null;

    const gpa = context.gpa;
    var self: Index = .{
        .gpa = gpa,
        .io = context.io,
        .services = try service_mod.collect(gpa, context.environ, settings.providers),
        .store = context.store,
        .chat = .{ .gpa = gpa },
        .notify = context.streamed,
    };
    self.restore();
    return self;
}

const testing = std.testing;

test "a subroutine with no services has nothing to send" {
    const bare: config_mod.Config.Sources.Llm = .{};
    try testing.expect(!enabled(bare));

    const one: config_mod.Config.Sources.Llm = .{
        .providers = &.{.{ .kind = "openai", .name = "local", .model = "qwen" }},
    };
    try testing.expect(enabled(one));
}

const configured: config_mod.Config = .{
    .sources = .{
        .llm = .{
            .providers = &.{
                .{
                    .kind = "openai",
                    .name = "local",
                    .model = "qwen",
                    .base_url = "http://host/v1",
                },
                .{
                    .kind = "openai",
                    .name = "cloud",
                    .model = "gpt-4o",
                    .base_url = "http://other/v1",
                },
            },
        },
    },
};

fn indexOf(gpa: Allocator, environ: *const std.process.Environ.Map) !Index {
    return (try open(.{
        .gpa = gpa,
        .io = undefined,
        .environ = environ,
        .settings = &configured,
    })).?;
}

test "the first service is chosen when nothing was remembered" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var made = try indexOf(testing.allocator, &environ);
    defer service_mod.release(testing.allocator, made.services);
    defer made.chat.deinit();
    defer made.streamed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), made.chosen);
    try testing.expectEqualStrings("local", made.service().?.name);
}

test "picking beyond the list is ignored" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var made = try indexOf(testing.allocator, &environ);
    defer service_mod.release(testing.allocator, made.services);
    defer made.chat.deinit();
    defer made.streamed.deinit(testing.allocator);

    made.pick(1);
    try testing.expectEqualStrings("cloud", made.service().?.name);

    made.pick(9);
    try testing.expectEqualStrings("cloud", made.service().?.name);
}

test "the names are listed in order for the dropdown" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var made = try indexOf(testing.allocator, &environ);
    defer service_mod.release(testing.allocator, made.services);
    defer made.chat.deinit();
    defer made.streamed.deinit(testing.allocator);

    const listed = try made.names(arena.allocator());
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("local", listed[0]);
    try testing.expectEqualStrings("cloud", listed[1]);
}
