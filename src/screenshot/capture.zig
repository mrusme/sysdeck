const std = @import("std");
const box = @import("box.zig");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const image = @import("image.zig");
const wl = @import("../wayland/c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.screenshot);

const screencopy = wl.screencopy;

const frame_timeout_ms = 2000;
const max_pixels: u64 = 1 << 28;

const Error = error{Unavailable};

pub const Screen = struct {
    monitor: *c.GdkMonitor,
    output: *wl.Output,
    logical: box.Box,
    transform: wl.Transform,
};

pub const Frame = struct {
    format: wl.Format,
    width: u32,
    height: u32,
    stride: u32,
    inverted: bool,
    pixels: []align(std.heap.page_size_min) u8,

    pub fn release(self: Frame) void {
        std.posix.munmap(self.pixels);
    }
};

const Pending = struct {
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    flags: u32 = 0,
    described: bool = false,
    copied: bool = false,
    broken: bool = false,

    fn ready(self: Pending) bool {
        return self.copied;
    }

    fn sized(self: Pending) bool {
        return self.described;
    }
};

fn readable(pending: Pending) bool {
    if (image.layoutOf(@fromBackingInt(pending.format)) == null) return false;
    if (pending.width == 0 or pending.height == 0) return false;
    if (@as(u64, pending.width) * pending.height > max_pixels) return false;
    if (pending.stride % 4 != 0 or pending.stride < @as(u64, pending.width) * 4) return false;
    return @as(u64, pending.stride) * pending.height <= std.math.maxInt(i32);
}

const Bound = struct {
    owner: *Capture,
    proxy: *wl.Proxy,
    name: std.ArrayList(u8) = .empty,
    transform: wl.Transform = .normal,
};

pub const Capture = struct {
    gpa: Allocator,
    io: std.Io,
    link: wl.Connection,
    registry: *wl.Proxy,
    shm: ?*wl.Proxy = null,
    manager: ?*wl.Proxy = null,
    outputs: std.ArrayList(*Bound) = .empty,
    screens: std.ArrayList(Screen) = .empty,

    pub fn open(gpa: Allocator, io: std.Io) ?*Capture {
        const display = gdk.gdk_display_get_default() orelse return null;
        const wl_display = gdk.gdk_wayland_display_get_wl_display(display) orelse {
            log.warn("a screenshot needs a Wayland session", .{});
            return null;
        };

        const self = connect(gpa, io, wl_display) orelse return null;
        self.collect(display);
        if (self.screens.items.len == 0) {
            log.warn("no monitor could be matched to a Wayland output", .{});
            self.close();
            return null;
        }
        return self;
    }

    pub fn connect(gpa: Allocator, io: std.Io, display: *wl.Display) ?*Capture {
        const link = wl.Connection.open(display) orelse return null;
        const registry = link.registry() orelse {
            link.close();
            return null;
        };

        const self = gpa.create(Capture) catch {
            wl.wl_proxy_destroy(registry);
            link.close();
            return null;
        };
        self.* = .{ .gpa = gpa, .io = io, .link = link, .registry = registry };

        _ = wl.wl_proxy_add_listener(registry, @ptrCast(&registry_listener), self);
        if (!link.roundtrip() or !link.roundtrip()) {
            self.close();
            return null;
        }

        if (self.manager == null or self.shm == null) {
            log.warn("this compositor has no wlr-screencopy, so nothing can be captured", .{});
            self.close();
            return null;
        }
        return self;
    }

    pub fn close(self: *Capture) void {
        for (self.outputs.items) |bound| {
            bound.name.deinit(self.gpa);
            wl.releaseOutput(bound.proxy);
            self.gpa.destroy(bound);
        }
        self.outputs.deinit(self.gpa);

        for (self.screens.items) |screen| glib.g_object_unref(screen.monitor);
        self.screens.deinit(self.gpa);

        if (self.manager) |found| screencopy.destroyManager(found);
        if (self.shm) |found| wl.wl_proxy_destroy(found);
        wl.wl_proxy_destroy(self.registry);
        self.link.close();
        self.gpa.destroy(self);
    }

    pub fn settle(self: *Capture) void {
        _ = self.link.roundtrip();
    }

    pub const Named = struct {
        output: *wl.Output,
        transform: wl.Transform,
    };

    pub fn outputNamed(self: *Capture, name: []const u8) ?Named {
        for (self.outputs.items) |bound| {
            if (std.mem.eql(u8, bound.name.items, name)) {
                return .{ .output = @ptrCast(bound.proxy), .transform = bound.transform };
            }
        }
        return null;
    }

    pub fn grab(self: *Capture, output: *wl.Output, cursor: bool) ?Frame {
        return self.take(output, cursor) catch null;
    }

    fn take(self: *Capture, output: *wl.Output, cursor: bool) Error!Frame {
        const manager = self.manager orelse return error.Unavailable;
        const shm = self.shm orelse return error.Unavailable;

        var pending: Pending = .{};

        const frame = screencopy.captureOutput(manager, cursor, output) orelse
            return error.Unavailable;
        defer screencopy.destroyFrame(frame);

        self.link.adopt(frame);
        _ = wl.wl_proxy_add_listener(frame, @ptrCast(&frame_listener), &pending);

        if (!self.until(&pending, Pending.sized)) return error.Unavailable;

        if (!readable(pending)) {
            log.warn("the compositor offered a {d}x{d} frame with a stride of {d} in format {x}", .{
                pending.width,
                pending.height,
                pending.stride,
                pending.format,
            });
            return error.Unavailable;
        }
        const size = @as(usize, pending.stride) * @as(usize, pending.height);

        const fd = try shareable(size);
        defer _ = std.c.close(fd);

        const pixels = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.warn("cannot map {d} bytes for a frame: {t}", .{ size, err });
            return error.Unavailable;
        };
        errdefer std.posix.munmap(pixels);

        const buffer = self.wrap(shm, fd, size, pending) orelse return error.Unavailable;
        defer wl.destroyBuffer(buffer);

        screencopy.copy(frame, buffer);
        if (!self.until(&pending, Pending.ready)) return error.Unavailable;

        return .{
            .format = @fromBackingInt(pending.format),
            .width = pending.width,
            .height = pending.height,
            .stride = pending.stride,
            .inverted = pending.flags & screencopy.y_invert != 0,
            .pixels = pixels,
        };
    }

    fn wrap(
        self: *Capture,
        shm: *wl.Proxy,
        fd: std.posix.fd_t,
        size: usize,
        pending: Pending,
    ) ?*wl.Proxy {
        const pool = wl.createPool(shm, fd, @intCast(size)) orelse return null;
        defer wl.destroyPool(pool);

        self.link.adopt(pool);
        return wl.createBuffer(
            pool,
            0,
            @intCast(pending.width),
            @intCast(pending.height),
            @intCast(pending.stride),
            pending.format,
        );
    }

    fn until(self: *Capture, pending: *Pending, done: *const fn (Pending) bool) bool {
        const clock: std.Io.Clock = .awake;
        const deadline = clock.now(self.io).addDuration(.fromMilliseconds(frame_timeout_ms));

        while (!done(pending.*) and !pending.broken) {
            const left = clock.now(self.io).durationTo(deadline).toMilliseconds();
            const outcome: wl.Ready = if (left > 0) self.link.pump(@intCast(left)) else .timeout;

            switch (outcome) {
                .arrived, .interrupted => {},
                .timeout => {
                    log.warn("the compositor sent no frame within {d}ms", .{frame_timeout_ms});
                    return false;
                },
                .broken => {
                    log.warn("the Wayland connection broke while capturing", .{});
                    return false;
                },
            }
        }

        if (pending.broken) log.warn("the compositor refused the capture", .{});
        return !pending.broken;
    }

    fn collect(self: *Capture, display: *c.GdkDisplay) void {
        const monitors = gdk.gdk_display_get_monitors(display);
        const count = gio.g_list_model_get_n_items(monitors);

        var at: c.guint = 0;
        while (at < count) : (at += 1) {
            const item = gio.g_list_model_get_item(monitors, at) orelse continue;
            const monitor: *c.GdkMonitor = @ptrCast(item);

            const output = gdk.gdk_wayland_monitor_get_wl_output(monitor) orelse {
                glib.g_object_unref(monitor);
                continue;
            };

            var area: c.GdkRectangle = undefined;
            gdk.gdk_monitor_get_geometry(monitor, &area);

            self.screens.append(self.gpa, .{
                .monitor = monitor,
                .output = output,
                .logical = .{
                    .x = area.x,
                    .y = area.y,
                    .width = area.width,
                    .height = area.height,
                },
                .transform = self.transformOf(monitor),
            }) catch {
                glib.g_object_unref(monitor);
                return;
            };
        }
    }

    fn transformOf(self: *Capture, monitor: *c.GdkMonitor) wl.Transform {
        const connector = gdk.gdk_monitor_get_connector(monitor) orelse return .normal;
        const wanted = std.mem.span(connector);
        if (self.outputNamed(wanted)) |found| return found.transform;

        log.warn("no Wayland output is named {s}, so it is taken as unrotated", .{wanted});
        return .normal;
    }
};

fn shareable(size: usize) Error!std.posix.fd_t {
    const fd = std.posix.memfd_create("sysdeck-screenshot", 0) catch |err| {
        log.warn("cannot create a shared buffer: {t}", .{err});
        return error.Unavailable;
    };
    errdefer _ = std.c.close(fd);

    if (std.c.ftruncate(fd, @intCast(size)) != 0) {
        log.warn("cannot size a shared buffer to {d} bytes", .{size});
        return error.Unavailable;
    }
    return fd;
}

fn onGlobal(
    data: ?*anyopaque,
    registry: *wl.Proxy,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    const self: *Capture = @ptrCast(@alignCast(data.?));
    const offered = std.mem.span(interface);

    if (std.mem.eql(u8, offered, "wl_shm")) {
        self.shm = wl.bind(registry, name, &wl.wl_shm_interface, 1);
        return;
    }

    if (std.mem.eql(u8, offered, std.mem.span(screencopy.manager_interface.name))) {
        self.manager = wl.bind(registry, name, &screencopy.manager_interface, 1);
        return;
    }

    if (!std.mem.eql(u8, offered, "wl_output")) return;

    const proxy = wl.bind(registry, name, &wl.wl_output_interface, @min(version, 4)) orelse return;
    const bound = self.gpa.create(Bound) catch {
        wl.releaseOutput(proxy);
        return;
    };
    bound.* = .{ .owner = self, .proxy = proxy };

    self.outputs.append(self.gpa, bound) catch {
        self.gpa.destroy(bound);
        wl.releaseOutput(proxy);
        return;
    };
    _ = wl.wl_proxy_add_listener(proxy, @ptrCast(&output_listener), bound);
}

fn onGlobalRemove(_: ?*anyopaque, _: *wl.Proxy, _: u32) callconv(.c) void {}

const registry_listener: wl.RegistryListener = .{
    .global = &onGlobal,
    .global_remove = &onGlobalRemove,
};

fn onOutputGeometry(
    data: ?*anyopaque,
    _: *wl.Proxy,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: [*:0]const u8,
    _: [*:0]const u8,
    transform: i32,
) callconv(.c) void {
    const self: *Bound = @ptrCast(@alignCast(data.?));
    self.transform = .of(transform);
}

fn onOutputMode(_: ?*anyopaque, _: *wl.Proxy, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}

fn onOutputDone(_: ?*anyopaque, _: *wl.Proxy) callconv(.c) void {}

fn onOutputScale(_: ?*anyopaque, _: *wl.Proxy, _: i32) callconv(.c) void {}

fn onOutputName(data: ?*anyopaque, _: *wl.Proxy, name: [*:0]const u8) callconv(.c) void {
    const self: *Bound = @ptrCast(@alignCast(data.?));

    self.name.clearRetainingCapacity();
    self.name.appendSlice(self.owner.gpa, std.mem.span(name)) catch |err| {
        log.warn("cannot keep the screenshot file name: {t}", .{err});
    };
}

fn onOutputDescription(_: ?*anyopaque, _: *wl.Proxy, _: [*:0]const u8) callconv(.c) void {}

const output_listener: wl.OutputListener = .{
    .geometry = &onOutputGeometry,
    .mode = &onOutputMode,
    .done = &onOutputDone,
    .scale = &onOutputScale,
    .name = &onOutputName,
    .description = &onOutputDescription,
};

fn onFrameBuffer(
    data: ?*anyopaque,
    _: *wl.Proxy,
    format: u32,
    width: u32,
    height: u32,
    stride: u32,
) callconv(.c) void {
    const self: *Pending = @ptrCast(@alignCast(data.?));
    self.format = format;
    self.width = width;
    self.height = height;
    self.stride = stride;
    self.described = true;
}

fn onFrameFlags(data: ?*anyopaque, _: *wl.Proxy, flags: u32) callconv(.c) void {
    const self: *Pending = @ptrCast(@alignCast(data.?));
    self.flags = flags;
}

fn onFrameReady(data: ?*anyopaque, _: *wl.Proxy, _: u32, _: u32, _: u32) callconv(.c) void {
    const self: *Pending = @ptrCast(@alignCast(data.?));
    self.copied = true;
}

fn onFrameFailed(data: ?*anyopaque, _: *wl.Proxy) callconv(.c) void {
    const self: *Pending = @ptrCast(@alignCast(data.?));
    self.broken = true;
}

const frame_listener: screencopy.FrameListener = .{
    .buffer = &onFrameBuffer,
    .flags = &onFrameFlags,
    .ready = &onFrameReady,
    .failed = &onFrameFailed,
};

const testing = std.testing;

test "a frame is read only in a known format, with room for every pixel of a row" {
    const fine: Pending = .{
        .format = @backingInt(wl.Format.xrgb8888),
        .width = 1920,
        .height = 1080,
        .stride = 7680,
    };
    try testing.expect(readable(fine));

    var narrow = fine;
    narrow.stride = 7676;
    try testing.expect(!readable(narrow));

    var uneven = fine;
    uneven.stride = 7682;
    try testing.expect(!readable(uneven));

    var unknown = fine;
    unknown.format = 0x34325258;
    try testing.expect(!readable(unknown));

    var empty = fine;
    empty.height = 0;
    try testing.expect(!readable(empty));

    const padded: Pending = .{
        .format = @backingInt(wl.Format.argb8888),
        .width = 16,
        .height = 1_000_000,
        .stride = 4096,
    };
    try testing.expect(!readable(padded));
}
