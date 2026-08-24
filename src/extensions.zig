const std = @import("std");
const c = @import("c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.extensions);

pub const man = @import("extensions/man.zig");

const debounce_ms = 150;

pub const Error = error{ OutOfMemory, Failed };

pub const Target = struct {
    source: []const u8,
    title: []const u8,
    detail: []const u8,
};

pub const Page = struct {
    label: [:0]const u8,
    text: [:0]const u8,
};

pub const Content = union(enum) {
    nothing,
    pages: []const Page,
};

pub const Extension = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        wants: *const fn (context: *anyopaque, source: []const u8) bool,
        probe: *const fn (context: *anyopaque, gpa: Allocator, target: Target) Error!Content,
        widget: *const fn (context: *anyopaque) *c.GtkWidget,
        update: *const fn (context: *anyopaque, content: Content) void,
        release: *const fn (context: *anyopaque, gpa: Allocator, content: Content) void,
        key: *const fn (context: *anyopaque, keyval: c.guint, state: c.GdkModifierType) bool,
    };

    pub fn wants(self: Extension, source: []const u8) bool {
        return self.vtable.wants(self.context, source);
    }

    pub fn probe(self: Extension, gpa: Allocator, target: Target) Error!Content {
        return self.vtable.probe(self.context, gpa, target);
    }

    pub fn widget(self: Extension) *c.GtkWidget {
        return self.vtable.widget(self.context);
    }

    pub fn update(self: Extension, content: Content) void {
        self.vtable.update(self.context, content);
    }

    pub fn release(self: Extension, gpa: Allocator, content: Content) void {
        self.vtable.release(self.context, gpa, content);
    }

    pub fn key(self: Extension, keyval: c.guint, state: c.GdkModifierType) bool {
        return self.vtable.key(self.context, keyval, state);
    }
};

const Owned = struct {
    source: []const u8,
    title: []const u8,
    detail: []const u8,

    fn target(self: Owned) Target {
        return .{ .source = self.source, .title = self.title, .detail = self.detail };
    }

    fn deinit(self: Owned, gpa: Allocator) void {
        gpa.free(self.source);
        gpa.free(self.title);
        gpa.free(self.detail);
    }
};

const Delivery = struct {
    manager: *Manager,
    member: usize,
    generation: u64,
    content: Content,
};

pub const Manager = struct {
    gpa: Allocator,
    members: []const Extension,
    box: ?*c.GtkBox = null,
    generation: std.atomic.Value(u64) = .init(0),
    inflight: std.atomic.Value(usize) = .init(0),
    pending: c.guint = 0,
    selection: ?Owned = null,
    busy: bool = false,
    stopping: bool = false,

    pub fn attach(self: *Manager, box: *c.GtkBox) void {
        self.box = box;
        for (self.members) |member| {
            const pane = member.widget();
            show(pane, false);
            c.gtk_box_append(box, pane);
        }
        self.syncBox();
    }

    fn syncBox(self: *Manager) void {
        const box = self.box orelse return;

        for (self.members) |member| {
            if (c.gtk_widget_get_visible(member.widget()) != c.FALSE) {
                return show(c.cast(c.GtkWidget, box), true);
            }
        }
        show(c.cast(c.GtkWidget, box), false);
    }

    pub fn select(self: *Manager, target: ?Target) void {
        if (self.stopping) return;
        if (self.busy) return;
        self.busy = true;
        defer self.busy = false;

        self.cancelPending();
        self.clearSelection();

        const wanted = target orelse return self.hideAll();
        if (!self.anyWants(wanted.source)) return self.hideAll();

        self.selection = own(self.gpa, wanted) catch {
            log.warn("out of memory, so {s} was not looked up", .{wanted.title});
            return self.hideAll();
        };

        self.pending = c.g_timeout_add(debounce_ms, &onTimeout, self);
    }

    pub fn key(self: *Manager, keyval: c.guint, state: c.GdkModifierType) bool {
        for (self.members) |member| {
            if (c.gtk_widget_get_visible(member.widget()) == c.FALSE) continue;
            if (member.key(keyval, state)) return true;
        }
        return false;
    }

    pub fn stop(self: *Manager) void {
        self.stopping = true;
        self.cancelPending();

        while (self.inflight.load(.acquire) != 0) std.Thread.yield() catch {};

        const context = c.g_main_context_default();
        while (c.g_main_context_iteration(context, c.FALSE) != c.FALSE) {}

        self.clearSelection();
    }

    fn anyWants(self: *Manager, source: []const u8) bool {
        for (self.members) |member| {
            if (member.wants(source)) return true;
        }
        return false;
    }

    fn hideAll(self: *Manager) void {
        for (self.members) |member| show(member.widget(), false);
        self.syncBox();
    }

    fn cancelPending(self: *Manager) void {
        if (self.pending == 0) return;
        _ = c.g_source_remove(self.pending);
        self.pending = 0;
    }

    fn clearSelection(self: *Manager) void {
        const current = self.selection orelse return;
        current.deinit(self.gpa);
        self.selection = null;
    }

    fn start(self: *Manager) void {
        const current = self.selection orelse return;
        const generation = self.generation.fetchAdd(1, .release) + 1;
        log.debug("generation {d} for {s} from {s}", .{
            generation,
            current.title,
            current.source,
        });

        for (self.members, 0..) |member, at| {
            if (!member.wants(current.source)) {
                show(member.widget(), false);
                self.syncBox();
                continue;
            }

            const owned = own(self.gpa, current.target()) catch continue;

            _ = self.inflight.fetchAdd(1, .acquire);
            const worker = std.Thread.spawn(.{}, work, .{ self, at, generation, owned }) catch |err| {
                log.warn("cannot start a worker: {t}", .{err});
                _ = self.inflight.fetchSub(1, .release);
                owned.deinit(self.gpa);
                continue;
            };
            worker.detach();
        }
    }

    fn deliver(self: *Manager, member: usize, content: Content) void {
        const extension = self.members[member];

        if (content == .nothing) {
            show(extension.widget(), false);
            self.syncBox();
            return extension.release(self.gpa, content);
        }

        extension.update(content);
        show(extension.widget(), true);
        self.syncBox();
        extension.release(self.gpa, content);
    }
};

fn show(pane: *c.GtkWidget, visible: bool) void {
    const wanted: c.gboolean = if (visible) c.TRUE else c.FALSE;
    if (c.gtk_widget_get_visible(pane) == wanted) return;
    c.gtk_widget_set_visible(pane, wanted);
}

fn own(gpa: Allocator, target: Target) Allocator.Error!Owned {
    const source = try gpa.dupe(u8, target.source);
    errdefer gpa.free(source);
    const title = try gpa.dupe(u8, target.title);
    errdefer gpa.free(title);
    const detail = try gpa.dupe(u8, target.detail);

    return .{ .source = source, .title = title, .detail = detail };
}

fn work(self: *Manager, member: usize, generation: u64, owned: Owned) void {
    defer _ = self.inflight.fetchSub(1, .release);
    defer owned.deinit(self.gpa);

    const content = self.members[member].probe(self.gpa, owned.target()) catch |err| {
        log.warn("extension {d} failed on {s}: {t}", .{ member, owned.title, err });
        return;
    };

    const delivery = self.gpa.create(Delivery) catch {
        self.members[member].release(self.gpa, content);
        return;
    };
    delivery.* = .{
        .manager = self,
        .member = member,
        .generation = generation,
        .content = content,
    };

    _ = c.g_idle_add(&onDelivery, delivery);
}

fn onTimeout(data: c.gpointer) callconv(.c) c.gboolean {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    self.pending = 0;
    self.start();
    return c.source_remove;
}

fn onDelivery(data: c.gpointer) callconv(.c) c.gboolean {
    const delivery: *Delivery = @ptrCast(@alignCast(data.?));
    const self = delivery.manager;
    defer self.gpa.destroy(delivery);

    const stale = delivery.generation != self.generation.load(.acquire);
    if (self.stopping or stale) {
        self.members[delivery.member].release(self.gpa, delivery.content);
        return c.source_remove;
    }

    self.deliver(delivery.member, delivery.content);
    return c.source_remove;
}

test {
    _ = man;
}
