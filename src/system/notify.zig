const std = @import("std");
const c = @import("../gtk/c.zig");
const dbus = @import("dbus.zig");
const glib = @import("../gtk/glib.zig");
const pixbuf = @import("../gtk/pixbuf.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.notify);

const app_name = "sysdeck";
const markup = "body-markup";
const pixels_type: *const c.GVariantType = @ptrCast("ay");

const service: dbus.Call = .{
    .name = "org.freedesktop.Notifications",
    .path = "/org/freedesktop/Notifications",
    .interface = "org.freedesktop.Notifications",
    .method = "Notify",
    .reply = "(u)",
    .timeout_ms = 5000,
};

pub const Urgency = enum(u8) { low = 0, normal = 1, critical = 2 };

pub const Image = struct {
    width: c_int,
    height: c_int,
    rowstride: c_int,
    alpha: bool,
    bits: c_int,
    channels: c_int,
    pixels: *c.GBytes,

    pub fn of(found: *c.GdkPixbuf) Image {
        return .{
            .width = pixbuf.gdk_pixbuf_get_width(found),
            .height = pixbuf.gdk_pixbuf_get_height(found),
            .rowstride = pixbuf.gdk_pixbuf_get_rowstride(found),
            .alpha = pixbuf.gdk_pixbuf_get_has_alpha(found) != c.FALSE,
            .bits = pixbuf.gdk_pixbuf_get_bits_per_sample(found),
            .channels = pixbuf.gdk_pixbuf_get_n_channels(found),
            .pixels = pixbuf.gdk_pixbuf_read_pixel_bytes(found),
        };
    }

    pub fn deinit(self: Image) void {
        glib.g_bytes_unref(self.pixels);
    }

    fn variant(self: Image) *c.GVariant {
        return dbus.tuple(&.{
            dbus.signed(self.width),
            dbus.signed(self.height),
            dbus.signed(self.rowstride),
            dbus.boolean(self.alpha),
            dbus.signed(self.bits),
            dbus.signed(self.channels),
            glib.g_variant_new_from_bytes(pixels_type, self.pixels, c.TRUE),
        });
    }
};

pub const Notification = struct {
    summary: []const u8,
    body: []const u8 = "",
    urgency: Urgency = .normal,
    icon: []const u8 = "",
    image: ?Image = null,
};

pub fn send(gpa: Allocator, notification: Notification) bool {
    const bus = dbus.Bus.open(.session) orelse {
        log.warn("there is no session bus, so the notification \"{s}\" is not shown", .{
            notification.summary,
        });
        return false;
    };
    defer bus.close();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var wanted = service;
    wanted.arguments = argumentsOf(arena.allocator(), notification, marksUp(bus)) catch {
        log.warn("out of memory, so the notification \"{s}\" is not shown", .{notification.summary});
        return false;
    };

    const reply = bus.call(wanted) orelse return false;
    dbus.drop(reply);
    return true;
}

fn marksUp(bus: dbus.Bus) bool {
    var asked = service;
    asked.method = "GetCapabilities";
    asked.reply = "(as)";
    asked.quiet = true;

    const reply = bus.call(asked) orelse return false;
    defer dbus.drop(reply);

    const listed = dbus.childAt(reply, 0);
    defer dbus.drop(listed);

    for (0..dbus.count(listed)) |at| {
        const capability = dbus.childAt(listed, at);
        defer dbus.drop(capability);
        if (std.mem.eql(u8, dbus.text(capability), markup)) return true;
    }
    return false;
}

fn argumentsOf(arena: Allocator, notification: Notification, marked: bool) Allocator.Error!*c.GVariant {
    const summary = try dbus.valid(arena, notification.summary);
    const plain = try dbus.valid(arena, notification.body);
    const body = if (marked) try escaped(arena, plain) else plain;
    const icon = try dbus.valid(arena, notification.icon);

    var hints: [2]*c.GVariant = undefined;
    var used: usize = 0;

    hints[used] = dbus.field("urgency", dbus.byte(@backingInt(notification.urgency)));
    used += 1;
    if (notification.image) |image| {
        hints[used] = dbus.field("image-data", image.variant());
        used += 1;
    }

    return dbus.tuple(&.{
        dbus.string(app_name),
        dbus.unsigned(0),
        dbus.string(icon),
        dbus.string(summary),
        dbus.string(body),
        dbus.array("s", &.{}),
        dbus.array("{sv}", hints[0..used]),
        dbus.signed(-1),
    });
}

fn escaped(arena: Allocator, text: []const u8) Allocator.Error![:0]const u8 {
    const made = glib.g_markup_escape_text(text.ptr, @intCast(text.len)) orelse return error.OutOfMemory;
    defer glib.g_free(made);
    return arena.dupeSentinel(u8, std.mem.span(made), 0);
}

const testing = std.testing;

fn built(notification: Notification, marked: bool) !*c.GVariant {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return glib.g_variant_ref_sink(try argumentsOf(arena.allocator(), notification, marked));
}

fn textAt(arguments: *c.GVariant, at: usize) []const u8 {
    const found = dbus.childAt(arguments, at);
    defer dbus.drop(found);
    return dbus.text(found);
}

fn hintsOf(arguments: *c.GVariant) *c.GVariant {
    return dbus.childAt(arguments, 6);
}

test "the arguments have the signature Notify takes" {
    const arguments = try built(.{ .summary = "Get Lucky", .body = "Daft Punk" }, false);
    defer dbus.drop(arguments);

    const kind = std.mem.span(glib.g_variant_get_type_string(arguments));
    try testing.expectEqualStrings("(susssasa{sv}i)", kind);
    try testing.expectEqualStrings("sysdeck", textAt(arguments, 0));
    try testing.expectEqualStrings("Get Lucky", textAt(arguments, 3));
    try testing.expectEqualStrings("Daft Punk", textAt(arguments, 4));
}

test "the body is escaped only for a server that reads markup, and the summary never" {
    const notification: Notification = .{ .summary = "Rock & Roll", .body = "Tom & Jerry <live>" };

    const marked = try built(notification, true);
    defer dbus.drop(marked);
    try testing.expectEqualStrings("Rock & Roll", textAt(marked, 3));
    try testing.expectEqualStrings("Tom &amp; Jerry &lt;live&gt;", textAt(marked, 4));

    const plain = try built(notification, false);
    defer dbus.drop(plain);
    try testing.expectEqualStrings("Tom & Jerry <live>", textAt(plain, 4));
}

test "text that isn't valid UTF-8 is sent with a replacement character in its place" {
    const notification: Notification = .{
        .summary = "Cannot start caf\xe9",
        .body = "Listen failed on /tmp/caf\xe9 & more",
        .icon = "caf\xe9",
    };

    const plain = try built(notification, false);
    defer dbus.drop(plain);
    try testing.expectEqualStrings("Cannot start caf\u{fffd}", textAt(plain, 3));
    try testing.expectEqualStrings("Listen failed on /tmp/caf\u{fffd} & more", textAt(plain, 4));
    try testing.expectEqualStrings("caf\u{fffd}", textAt(plain, 2));

    const marked = try built(notification, true);
    defer dbus.drop(marked);
    try testing.expectEqualStrings("Listen failed on /tmp/caf\u{fffd} &amp; more", textAt(marked, 4));
}

test "the urgency is a byte hint, and a picture adds image-data" {
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const made = pixbuf.gdk_pixbuf_new_from_data(&pixels, .rgb, c.FALSE, 8, 2, 2, 6, null, null).?;
    defer glib.g_object_unref(made);

    const image: Image = .of(made);
    defer image.deinit();

    const arguments = try built(.{ .summary = "Low", .urgency = .low, .image = image }, false);
    defer dbus.drop(arguments);

    const hints = hintsOf(arguments);
    defer dbus.drop(hints);

    const urgency = dbus.lookup(hints, "urgency").?;
    defer dbus.drop(urgency);
    try testing.expectEqual(0, glib.g_variant_get_byte(urgency));

    const data = dbus.lookup(hints, "image-data").?;
    defer dbus.drop(data);
    try testing.expectEqualStrings("(iiibiiay)", std.mem.span(glib.g_variant_get_type_string(data)));

    const bytes = dbus.childAt(data, 6);
    defer dbus.drop(bytes);
    try testing.expectEqual(12, dbus.count(bytes));
}

test "without a picture there is no image-data hint" {
    const arguments = try built(.{ .summary = "Plain" }, false);
    defer dbus.drop(arguments);

    const hints = hintsOf(arguments);
    defer dbus.drop(hints);

    try testing.expectEqual(1, dbus.count(hints));
    try testing.expectEqual(null, dbus.lookup(hints, "image-data"));
}

test "an image keeps the layout of the pixbuf it was read from" {
    const pixels: [3 * 4 * 2]u8 = @splat(0);
    const made = pixbuf.gdk_pixbuf_new_from_data(&pixels, .rgb, c.TRUE, 8, 3, 2, 12, null, null).?;
    defer glib.g_object_unref(made);

    const image: Image = .of(made);
    defer image.deinit();

    try testing.expectEqual(3, image.width);
    try testing.expectEqual(2, image.height);
    try testing.expectEqual(12, image.rowstride);
    try testing.expect(image.alpha);
    try testing.expectEqual(4, image.channels);
    try testing.expectEqual(8, image.bits);
}
