const std = @import("std");
const c = @import("gtk/c.zig");
const gtk = @import("gtk/gtk.zig");
const jobs = @import("app/jobs.zig");
const media = @import("core").media;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.extensions);

pub const man = @import("extensions/man.zig");
pub const preview = @import("extensions/preview.zig");

const debounce_ms = 150;

pub const Error = error{OutOfMemory};

pub const Target = struct {
    source: []const u8,
    title: []const u8,
    detail: []const u8,
    media: ?media.Handle = null,
};

pub const Page = struct {
    label: [:0]const u8,
    text: [:0]const u8,
};

pub const Frame = union(enum) {
    none,
    still: *c.GdkTexture,
    motion: *c.GBytes,
    text: [:0]const u8,
};

pub const Preview = struct {
    kind: media.Kind,
    icon: [:0]const u8,
    caption: [:0]const u8,
    place: ?media.Place = null,
    frame: Frame = .none,
};

pub const Content = union(enum) {
    nothing,
    pages: []const Page,
    preview: Preview,
};

pub const Extension = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        wants: *const fn (context: *anyopaque, target: Target) bool,
        probe: *const fn (context: *anyopaque, gpa: Allocator, target: Target) Error!Content,
        widget: *const fn (context: *anyopaque) *c.GtkWidget,
        update: *const fn (context: *anyopaque, content: Content) void,
        release: *const fn (context: *anyopaque, gpa: Allocator, content: Content) void,
        key: *const fn (context: *anyopaque, keyval: c.guint, state: c.GdkModifierType) bool,
    };

    pub fn wants(self: Extension, target: Target) bool {
        return self.vtable.wants(self.context, target);
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

pub fn vtableOf(comptime Methods: type) *const Extension.VTable {
    const shim = struct {
        fn of(context: *anyopaque) *Methods {
            return @ptrCast(@alignCast(context));
        }

        fn wants(context: *anyopaque, target: Target) bool {
            return Methods.wants(of(context), target);
        }

        fn probe(context: *anyopaque, gpa: Allocator, target: Target) Error!Content {
            return Methods.probe(of(context), gpa, target);
        }

        fn widget(context: *anyopaque) *c.GtkWidget {
            return Methods.widget(of(context));
        }

        fn update(context: *anyopaque, content: Content) void {
            Methods.update(of(context), content);
        }

        fn release(context: *anyopaque, gpa: Allocator, content: Content) void {
            Methods.release(of(context), gpa, content);
        }

        fn key(context: *anyopaque, keyval: c.guint, state: c.GdkModifierType) bool {
            return Methods.key(of(context), keyval, state);
        }

        const table: Extension.VTable = .{
            .wants = &wants,
            .probe = &probe,
            .widget = &widget,
            .update = &update,
            .release = &release,
            .key = &key,
        };
    };

    return &shim.table;
}

const Owned = struct {
    source: []const u8,
    title: []const u8,
    detail: []const u8,
    media: ?media.Handle = null,

    fn target(self: Owned) Target {
        return .{
            .source = self.source,
            .title = self.title,
            .detail = self.detail,
            .media = self.media,
        };
    }

    fn deinit(self: Owned, gpa: Allocator) void {
        gpa.free(self.source);
        gpa.free(self.title);
        gpa.free(self.detail);
        if (self.media) |found| gpa.free(found.mime);
    }
};

const Job = struct {
    pub const Member = Extension;
    pub const Work = Owned;
    pub const Result = Content;

    pub fn begin(owner: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(owner));
        self.start();
    }

    pub fn produce(member: Member, gpa: Allocator, work: Work) Result {
        return member.probe(gpa, work.target()) catch |err| {
            log.warn("an extension failed on {s}: {t}", .{ work.title, err });
            return .nothing;
        };
    }

    pub fn discard(_: Member, gpa: Allocator, work: Work) void {
        work.deinit(gpa);
    }

    pub fn release(member: Member, gpa: Allocator, result: Result) void {
        member.release(gpa, result);
    }

    pub fn accept(owner: *anyopaque, at: usize, member: Member, result: Result) void {
        const self: *Manager = @ptrCast(@alignCast(owner));
        if (at >= self.members.len) return release(member, self.gpa, result);
        self.deliver(at, result);
    }

    pub fn settle(owner: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(owner));
        self.syncBox();
    }
};

pub const Runner = jobs.Runner(Job);

pub const Manager = struct {
    gpa: Allocator,
    members: []const Extension,
    runner: Runner,
    box: ?*c.GtkBox = null,
    selection: ?Owned = null,
    busy: bool = false,

    pub fn init(gpa: Allocator, io: std.Io) Manager {
        return .{
            .gpa = gpa,
            .members = &.{},
            .runner = .{ .gpa = gpa, .io = io },
        };
    }

    pub fn attach(self: *Manager, box: *c.GtkBox) void {
        self.box = box;
        for (self.members) |member| {
            const pane = member.widget();
            show(pane, false);
            gtk.gtk_box_append(box, pane);
        }
        self.syncBox();
    }

    fn syncBox(self: *Manager) void {
        const box = self.box orelse return;

        for (self.members) |member| {
            if (gtk.gtk_widget_get_visible(member.widget()) != c.FALSE) {
                return show(c.cast(c.GtkWidget, box), true);
            }
        }
        show(c.cast(c.GtkWidget, box), false);
    }

    pub fn select(self: *Manager, target: ?Target) void {
        if (self.runner.stopping) return;
        if (self.busy) return;
        self.busy = true;
        defer self.busy = false;

        self.runner.cancel();
        _ = self.runner.bump();
        self.clearSelection();

        const wanted = target orelse return self.hideAll();
        if (!self.anyWants(wanted)) return self.hideAll();

        self.selection = own(self.gpa, wanted) catch {
            log.warn("out of memory, so {s} was not looked up", .{wanted.title});
            return self.hideAll();
        };

        self.runner.after(self, debounce_ms);
    }

    pub fn key(self: *Manager, keyval: c.guint, state: c.GdkModifierType) bool {
        for (self.members) |member| {
            if (gtk.gtk_widget_get_visible(member.widget()) == c.FALSE) continue;
            if (member.key(keyval, state)) return true;
        }
        return false;
    }

    pub fn stop(self: *Manager) void {
        self.runner.stop();
        self.clearSelection();
    }

    fn anyWants(self: *Manager, target: Target) bool {
        for (self.members) |member| {
            if (member.wants(target)) return true;
        }
        return false;
    }

    fn hideAll(self: *Manager) void {
        for (self.members) |member| show(member.widget(), false);
        self.syncBox();
    }

    fn clearSelection(self: *Manager) void {
        const current = self.selection orelse return;
        current.deinit(self.gpa);
        self.selection = null;
    }

    fn start(self: *Manager) void {
        const current = self.selection orelse return;
        const generation = self.runner.bump();
        log.debug("generation {d} for {s} from {s}", .{
            generation,
            current.title,
            current.source,
        });

        for (self.members, 0..) |member, at| {
            if (member.wants(current.target()) and self.probe(at, member, current, generation)) {
                continue;
            }
            show(member.widget(), false);
        }
        self.syncBox();
    }

    fn probe(self: *Manager, at: usize, member: Extension, current: Owned, generation: u64) bool {
        const owned = own(self.gpa, current.target()) catch {
            log.warn("out of memory, so {s} was not looked up", .{current.title});
            return false;
        };

        if (self.runner.spawn(self, at, member, generation, owned)) return true;
        owned.deinit(self.gpa);
        return false;
    }

    fn deliver(self: *Manager, member: usize, content: Content) void {
        const extension = self.members[member];
        defer extension.release(self.gpa, content);

        if (content == .nothing) return show(extension.widget(), false);

        extension.update(content);
        show(extension.widget(), true);
    }
};

fn show(pane: *c.GtkWidget, visible: bool) void {
    const wanted: c.gboolean = if (visible) c.TRUE else c.FALSE;
    if (gtk.gtk_widget_get_visible(pane) == wanted) return;
    gtk.gtk_widget_set_visible(pane, wanted);
}

fn own(gpa: Allocator, target: Target) Allocator.Error!Owned {
    const source = try gpa.dupe(u8, target.source);
    errdefer gpa.free(source);
    const title = try gpa.dupe(u8, target.title);
    errdefer gpa.free(title);
    const detail = try gpa.dupe(u8, target.detail);
    errdefer gpa.free(detail);

    var handle = target.media;
    if (handle) |*found| found.mime = try gpa.dupe(u8, found.mime);

    return .{ .source = source, .title = title, .detail = detail, .media = handle };
}

test {
    _ = man;
    _ = preview;
}

const testing = std.testing;

test "a new selection drops the lookups still running for the previous one" {
    var manager: Manager = .init(testing.allocator, testing.io);
    defer manager.stop();

    const looking = manager.runner.bump();
    manager.select(null);
    try testing.expect(manager.runner.current() != looking);

    const cleared = manager.runner.current();
    manager.select(.{ .source = "inca", .title = "Tom Ato", .detail = "" });
    try testing.expect(manager.runner.current() != cleared);
}
