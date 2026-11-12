const std = @import("std");
const blur = @import("core").blur;
const box = @import("../screenshot/box.zig");
const c = @import("../gtk/c.zig");
const capture = @import("../screenshot/capture.zig");
const gdk = @import("../gtk/gdk.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const image = @import("../screenshot/image.zig");
const sway = @import("../subroutines/sway.zig");
const wl = @import("../wayland/c.zig");

const Backdrop = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.backdrop);

const backdrop_class = "sysdeck-backdrop";
const shrink_factor = 4;

pub const Source = struct {
    gpa: Allocator,
    io: std.Io,
    socket: ?[]const u8,

    pub fn of(
        gpa: Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        wanted: bool,
    ) ?Source {
        if (!wanted) return null;

        const socket = environ.get("SWAYSOCK") orelse "";
        return .{ .gpa = gpa, .io = io, .socket = if (socket.len > 0) socket else null };
    }
};

pub const Blurred = struct {
    output: box.Box,
    width: usize,
    height: usize,
    bytes: []u8,

    pub fn deinit(self: Blurred, gpa: Allocator) void {
        gpa.free(self.bytes);
    }
};

source: Source,
socket: []const u8,
output: box.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
ready: bool = false,
awaited: bool = false,
fixed: *c.GtkFixed = undefined,
picture: *c.GtkWidget = undefined,

pub fn prepare(source: Source) ?Backdrop {
    const socket = source.socket orelse {
        log.warn(
            "[window] static_blur needs sway, however $SWAYSOCK is not set, " ++
                "so the window has no blurred background",
            .{},
        );
        return null;
    };
    if (c.waylandDisplay() == null) {
        log.warn("[window] static_blur needs a Wayland session, so the window has no blurred background", .{});
        return null;
    }
    return .{ .source = source, .socket = socket };
}

pub fn widget(self: *Backdrop) *c.GtkWidget {
    const picture = gtk.gtk_picture_new();
    gtk.gtk_picture_set_content_fit(c.cast(c.GtkPicture, picture), .fill);
    gtk.gtk_widget_add_css_class(picture, backdrop_class);

    const fixed = c.cast(c.GtkFixed, gtk.gtk_fixed_new());
    gtk.gtk_fixed_put(fixed, picture, 0, 0);
    gtk.gtk_widget_set_can_target(c.cast(c.GtkWidget, fixed), c.FALSE);

    self.fixed = fixed;
    self.picture = picture;
    return c.cast(c.GtkWidget, fixed);
}

pub fn show(self: *Backdrop, blurred: Blurred) void {
    const shared = glib.g_bytes_new(blurred.bytes.ptr, blurred.bytes.len);
    defer glib.g_bytes_unref(shared);

    const texture = gdk.gdk_memory_texture_new(
        @intCast(blurred.width),
        @intCast(blurred.height),
        .r8g8b8,
        shared,
        blurred.width * 3,
    );
    gtk.gtk_picture_set_paintable(c.cast(c.GtkPicture, self.picture), c.cast(c.GdkPaintable, texture));
    glib.g_object_unref(texture);

    gtk.gtk_widget_set_size_request(self.picture, blurred.output.width, blurred.output.height);
    self.output = blurred.output;
    self.ready = true;
}

pub const Placement = enum { placed, missing, failed };

pub fn place(self: *Backdrop, origin_x: f64, origin_y: f64) Placement {
    const window = self.ownWindow() catch return .failed;
    const found = window orelse return .missing;

    const x = @as(f64, @floatFromInt(self.output.x - found.x)) - origin_x;
    const y = @as(f64, @floatFromInt(self.output.y - found.y)) - origin_y;
    gtk.gtk_fixed_move(self.fixed, self.picture, x, y);
    return .placed;
}

pub fn hide(self: *Backdrop) void {
    gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, self.fixed), c.FALSE);
}

fn ownWindow(self: *Backdrop) error{Unreadable}!?box.Box {
    const gpa = self.source.gpa;
    const reply = sway.request(gpa, self.source.io, self.socket, .get_tree, "") catch |err| {
        log.warn("cannot read the sway tree: {t}, so the window has no blurred background", .{err});
        return error.Unreadable;
    };
    defer gpa.free(reply);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), reply, .{}) catch {
        log.warn("sway answered the tree query with something other than JSON", .{});
        return error.Unreadable;
    };

    var found: std.ArrayList(sway.Window) = .empty;
    sway.collect(arena.allocator(), parsed.value, &found) catch return error.Unreadable;
    return sway.rectOfPid(found.items, std.c.getpid());
}

pub fn blurredScreen(gpa: Allocator, io: std.Io, socket: []const u8) ?Blurred {
    const reply = sway.request(gpa, io, socket, .get_outputs, "") catch |err| {
        log.warn("cannot ask sway for its outputs: {t}, so the window has no blurred background", .{err});
        return null;
    };
    defer gpa.free(reply);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, reply, .{}) catch {
        log.warn("sway answered the output query with something other than JSON", .{});
        return null;
    };
    defer parsed.deinit();

    const focused = sway.focusedOutput(parsed.value) orelse {
        log.warn("sway reports no focused output, so the window has no blurred background", .{});
        return null;
    };

    const display = wl.wl_display_connect(null) orelse {
        log.warn("cannot open a Wayland connection for [window] static_blur, so the window has no blurred background", .{});
        return null;
    };
    defer wl.wl_display_disconnect(display);

    const shot = capture.Capture.connect(gpa, io, display) orelse return null;
    defer shot.close();

    const output = shot.outputNamed(focused.name) orelse {
        log.warn("no Wayland output is named {s}, so the window has no blurred background", .{focused.name});
        return null;
    };

    const frame = shot.grab(output.output, false) orelse return null;
    defer frame.release();

    return blurredFrame(gpa, frame, output.transform, focused.rect);
}

fn blurredFrame(gpa: Allocator, frame: capture.Frame, transform: wl.Transform, output: box.Box) ?Blurred {
    const input = frameOf(frame, transform) orelse {
        log.warn("this compositor uses a pixel format sysdeck cannot read: 0x{x}", .{@backingInt(frame.format)});
        return null;
    };

    const across: usize = if (transform.turned()) frame.height else frame.width;
    const scale = @as(f64, @floatFromInt(across)) / @as(f64, @floatFromInt(@max(output.width, 1)));
    const factor: usize = @intFromFloat(@max(1, @round(shrink_factor * scale)));

    const shrunk = blur.shrink(gpa, input, factor) catch {
        log.warn("out of memory while shrinking the screen", .{});
        return null;
    };
    defer shrunk.deinit(gpa);

    blur.blur(gpa, shrunk) catch {
        log.warn("out of memory while blurring the screen", .{});
        return null;
    };

    const bytes = gpa.alloc(u8, shrunk.values.len) catch {
        log.warn("out of memory while packing the blurred screen", .{});
        return null;
    };
    blur.pack(shrunk, bytes);

    return .{ .output = output, .width = shrunk.width, .height = shrunk.height, .bytes = bytes };
}

fn frameOf(frame: capture.Frame, transform: wl.Transform) ?blur.Frame {
    const layout = image.layoutOf(frame.format) orelse return null;
    return .{
        .pixels = frame.pixels,
        .width = frame.width,
        .height = frame.height,
        .stride = frame.stride,
        .swapped = layout.swapped,
        .inverted = frame.inverted,
        .quarters = transform.quarters(),
        .flipped = transform.flipped_over(),
    };
}

const testing = std.testing;
const cairo = @import("../gtk/cairo.zig");

fn surfaceFrame(surface: *c.cairo_surface_t) blur.Frame {
    const width: usize = @intCast(cairo.cairo_image_surface_get_width(surface));
    const height: usize = @intCast(cairo.cairo_image_surface_get_height(surface));
    const stride: usize = @intCast(cairo.cairo_image_surface_get_stride(surface));
    const data = cairo.cairo_image_surface_get_data(surface).?;
    return .{ .pixels = data[0 .. stride * height], .width = width, .height = height, .stride = stride };
}

test "the static blur shrinks a frame the way a screenshot composes it, in every orientation" {
    const gpa = testing.allocator;
    const page = comptime std.mem.Alignment.fromByteUnits(std.heap.page_size_min);
    var random: std.Random.DefaultPrng = .init(0x0b1e);

    const transforms = [_]wl.Transform{
        .normal,  .rotate_90,  .rotate_180,  .rotate_270,
        .flipped, .flipped_90, .flipped_180, .flipped_270,
    };
    const sizes = [_][2]u32{ .{ 23, 13 }, .{ 3, 2 } };

    for (sizes) |size| {
        const width = size[0];
        const height = size[1];
        const stride = width * 4 + 8;

        const original = try gpa.alignedAlloc(u8, page, stride * height);
        defer gpa.free(original);
        random.random().bytes(original);
        const pixels = try gpa.alignedAlloc(u8, page, stride * height);
        defer gpa.free(pixels);

        for (transforms) |transform| {
            for ([_]bool{ false, true }) |inverted| {
                for ([_]wl.Format{ .xrgb8888, .xbgr8888 }) |format| {
                    for ([_]usize{ 1, 4, 5 }) |factor| {
                        @memcpy(pixels, original);
                        const frame: capture.Frame = .{
                            .format = format,
                            .width = width,
                            .height = height,
                            .stride = stride,
                            .inverted = inverted,
                            .pixels = pixels,
                        };

                        const direct = try blur.shrink(gpa, frameOf(frame, transform).?, factor);
                        defer direct.deinit(gpa);

                        const turned = transform.turned();
                        const screen: capture.Screen = .{
                            .monitor = undefined,
                            .output = undefined,
                            .logical = .{
                                .x = 0,
                                .y = 0,
                                .width = @intCast(if (turned) height else width),
                                .height = @intCast(if (turned) width else height),
                            },
                            .transform = transform,
                        };
                        const surface = image.compose(screen.logical, &.{.{ .screen = screen, .frame = frame }}) orelse
                            return error.NotComposed;
                        defer cairo.cairo_surface_destroy(surface);

                        const composed = try blur.shrink(gpa, surfaceFrame(surface), factor);
                        defer composed.deinit(gpa);

                        try testing.expectEqual(composed.width, direct.width);
                        try testing.expectEqual(composed.height, direct.height);
                        try testing.expectEqualSlices(f32, composed.values, direct.values);
                    }
                }
            }
        }
    }
}
