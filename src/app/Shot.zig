const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const box = @import("../screenshot/box.zig");
const c = @import("../gtk/c.zig");
const cairo = @import("../gtk/cairo.zig");
const capture_mod = @import("../screenshot/capture.zig");
const config_mod = @import("../config.zig");
const copy = @import("../system/copy.zig");
const Deck = @import("../ui/Deck.zig");
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const image = @import("../screenshot/image.zig");
const overlay_mod = @import("../screenshot/overlay.zig");
const save = @import("../screenshot/save.zig");
const sway_mod = @import("../subroutines/sway.zig");

const Shot = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.screenshot);

pub const Finished = Callback(fn (taken: bool) void);

gpa: Allocator,
io: std.Io,
environ: *const std.process.Environ.Map,
settings: config_mod.Config.Sources.Screenshot,
destination: config_mod.Config.Sources.Screenshot.Destination,
deck: *Deck,
sway: ?*sway_mod.Index,
finished: Finished,
overlay: ?*overlay_mod.Overlay = null,
boxes: std.ArrayList(box.Box) = .empty,

pub fn create(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    settings: config_mod.Config.Sources.Screenshot,
    destination: config_mod.Config.Sources.Screenshot.Destination,
    deck: *Deck,
    sway: ?*sway_mod.Index,
    finished: Finished,
) Allocator.Error!*Shot {
    const self = try gpa.create(Shot);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .settings = settings,
        .destination = destination,
        .deck = deck,
        .sway = sway,
        .finished = finished,
    };
    return self;
}

pub fn destroy(self: *Shot) void {
    if (self.overlay) |found| found.destroy();
    self.boxes.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn begin(self: *Shot, mode: overlay_mod.Mode) void {
    if (self.overlay != null) return;

    self.deck.conceal();
    self.gather(mode);

    const made = overlay_mod.Overlay.create(
        self.gpa,
        mode,
        self.boxes.items,
        .of(Shot, Shot.onPicked, self),
    ) catch null;

    self.overlay = made orelse {
        log.warn("cannot raise the selection overlay", .{});
        return self.give(false);
    };
}

fn gather(self: *Shot, mode: overlay_mod.Mode) void {
    self.boxes.clearRetainingCapacity();

    if (mode == .any or mode == .window) {
        if (self.sway) |found| found.boxes(self.gpa, std.c.getpid(), &self.boxes);
    }
    if (mode == .any or mode == .screen) self.screens();
}

fn screens(self: *Shot) void {
    const display = gdk.gdk_display_get_default() orelse return;
    const monitors = gdk.gdk_display_get_monitors(display);
    const count = gio.g_list_model_get_n_items(monitors);

    var at: c.guint = 0;
    while (at < count) : (at += 1) {
        const item = gio.g_list_model_get_item(monitors, at) orelse continue;
        const monitor: *c.GdkMonitor = @ptrCast(item);
        defer glib.g_object_unref(monitor);

        var area: c.GdkRectangle = undefined;
        gdk.gdk_monitor_get_geometry(monitor, &area);

        self.boxes.append(self.gpa, .{
            .x = area.x,
            .y = area.y,
            .width = area.width,
            .height = area.height,
        }) catch return;
    }
}

fn picked(self: *Shot, chosen: ?box.Box) void {
    if (self.overlay) |found| found.destroy();
    self.overlay = null;

    const wanted = chosen orelse return self.give(false);
    self.give(self.take(wanted));
}

fn give(self: *Shot, taken: bool) void {
    if (!taken) self.deck.reveal();
    self.finished.call(.{taken});
}

fn take(self: *Shot, wanted: box.Box) bool {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();

    const capture = capture_mod.Capture.open(self.gpa) orelse return false;
    defer capture.close();

    capture.settle();

    var pieces: std.ArrayList(image.Piece) = .empty;
    defer {
        for (pieces.items) |piece| piece.frame.release();
        pieces.deinit(self.gpa);
    }

    for (capture.screens.items) |screen| {
        if (!screen.logical.meets(wanted)) continue;

        const frame = capture.grab(screen, self.settings.cursor) orelse continue;
        pieces.append(self.gpa, .{ .screen = screen, .frame = frame }) catch {
            frame.release();
            break;
        };
    }

    if (pieces.items.len == 0) {
        log.warn("nothing could be captured for the chosen area", .{});
        return false;
    }

    const surface = image.compose(wanted, pieces.items) orelse return false;
    defer cairo.cairo_surface_destroy(surface);

    const scratch = arena.allocator();
    const name = save.nameOf(scratch, self.settings.filename) catch return false;
    const kind: image.Kind = .of(name);

    const bytes = image.encode(self.gpa, surface, kind) orelse return false;
    defer self.gpa.free(bytes);

    const folder = save.folderOf(scratch, self.environ, self.settings.directory) catch
        return false;
    const path = save.store(scratch, self.io, folder, name, bytes) orelse return false;

    self.handOver(scratch, kind, path, bytes);
    return true;
}

fn handOver(
    self: *Shot,
    arena: Allocator,
    kind: image.Kind,
    path: []const u8,
    bytes: []const u8,
) void {
    const content: copy.Content = switch (self.destination) {
        .none => return,
        .image => .{ .mime = kind.mime(), .bytes = bytes },
        .path => .{ .bytes = path },
    };

    if (!copy.put(arena, self.environ, content)) {
        log.warn("the screenshot was saved to {s} but not copied", .{path});
    }
}

fn onPicked(self: *Shot, chosen: ?box.Box) void {
    self.picked(chosen);
}
