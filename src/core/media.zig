const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Kind = enum { image, audio, video, text, other };

pub const Payload = union(enum) {
    bytes: []const u8,
    path: []const u8,
};

pub const Place = struct {
    latitude: f64,
    longitude: f64,
};

pub const Loader = *const fn (context: ?*anyopaque, arena: Allocator, id: u64) ?Payload;

pub const Handle = struct {
    mime: []const u8,
    size: u64,
    id: u64,
    context: ?*anyopaque,
    load: Loader,

    pub fn open(self: Handle, arena: Allocator) ?Payload {
        return self.load(self.context, arena, self.id);
    }

    pub fn kind(self: Handle) Kind {
        return kindOf(self.mime);
    }
};

pub fn kindOf(mime: []const u8) Kind {
    if (std.mem.startsWith(u8, mime, "image/")) return .image;
    if (std.mem.startsWith(u8, mime, "audio/")) return .audio;
    if (std.mem.startsWith(u8, mime, "video/")) return .video;
    if (std.mem.startsWith(u8, mime, "text/")) return .text;
    return .other;
}

pub fn size(buffer: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "bytes", "kB", "MB", "GB", "TB" };

    var value: f64 = @floatFromInt(bytes);
    var at: usize = 0;
    while (value >= 1000 and at + 1 < units.len) : (at += 1) value /= 1000;

    const printed = if (at == 0)
        std.mem.print(buffer, "{d} {s}", .{ bytes, units[at] })
    else
        std.mem.print(buffer, "{d:.1} {s}", .{ value, units[at] });

    return printed catch buffer[0..0];
}

const testing = std.testing;

test "a kind is read from the mime prefix" {
    try testing.expectEqual(Kind.image, kindOf("image/png"));
    try testing.expectEqual(Kind.image, kindOf("image/svg+xml"));
    try testing.expectEqual(Kind.image, kindOf("image/x-nothing-known"));
    try testing.expectEqual(Kind.audio, kindOf("audio/mpeg"));
    try testing.expectEqual(Kind.audio, kindOf("audio/vnd.wave"));
    try testing.expectEqual(Kind.video, kindOf("video/mp4"));
    try testing.expectEqual(Kind.text, kindOf("text/plain"));
    try testing.expectEqual(Kind.text, kindOf("text/html"));
}

test "anything else is other, which includes the documents" {
    try testing.expectEqual(Kind.other, kindOf("application/pdf"));
    try testing.expectEqual(Kind.other, kindOf("application/zip"));
    try testing.expectEqual(Kind.other, kindOf("application/x-shellscript"));
    try testing.expectEqual(Kind.other, kindOf("application/octet-stream"));
    try testing.expectEqual(Kind.other, kindOf(""));
    try testing.expectEqual(Kind.other, kindOf("image"));
    try testing.expectEqual(Kind.other, kindOf("nonsense"));
}

fn sized(bytes: u64) []const u8 {
    const held = struct {
        var buffer: [32]u8 = undefined;
    };
    return size(&held.buffer, bytes);
}

test "a size reads in the largest unit that fits" {
    try testing.expectEqualStrings("0 bytes", sized(0));
    try testing.expectEqualStrings("1 bytes", sized(1));
    try testing.expectEqualStrings("999 bytes", sized(999));
    try testing.expectEqualStrings("1.0 kB", sized(1000));
    try testing.expectEqualStrings("240.5 kB", sized(240_500));
    try testing.expectEqualStrings("5.2 MB", sized(5_242_880));
    try testing.expectEqualStrings("1.5 GB", sized(1_500_000_000));
}

test "a handle answers with its own kind" {
    const self: Handle = .{
        .mime = "image/png",
        .size = 312,
        .id = 7,
        .context = null,
        .load = &nothing,
    };

    try testing.expectEqual(Kind.image, self.kind());
    try testing.expectEqual(@as(u64, 312), self.size);
}

fn nothing(_: ?*anyopaque, _: Allocator, _: u64) ?Payload {
    return null;
}
