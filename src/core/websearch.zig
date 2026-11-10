const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const placeholder = "%s";

const service = "https://icons.duckduckgo.com/ip3/";

pub fn fill(gpa: Allocator, template: []const u8, text: []const u8) Allocator.Error![]u8 {
    var filled: Writer.Allocating = .init(gpa);
    defer filled.deinit();

    write(&filled.writer, template, text) catch return error.OutOfMemory;
    return filled.toOwnedSlice();
}

pub fn takesText(template: []const u8) bool {
    return std.mem.find(u8, template, placeholder) != null;
}

pub fn hostOf(gpa: Allocator, template: []const u8) Allocator.Error!?[]u8 {
    const bare = try fill(gpa, template, "");
    defer gpa.free(bare);

    const uri = std.Uri.parse(bare) catch return null;
    const component = uri.host orelse return null;

    var buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = component.toRaw(&buffer) catch return null;
    if (host.len == 0) return null;
    return try std.ascii.allocLowerString(gpa, host);
}

pub fn faviconOf(gpa: Allocator, host: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ service, host, ".ico" });
}

fn write(w: *Writer, template: []const u8, text: []const u8) Writer.Error!void {
    var rest = template;
    while (std.mem.find(u8, rest, placeholder)) |at| {
        try w.writeAll(rest[0..at]);
        try std.Uri.Component.percentEncode(w, text, unreserved);
        rest = rest[at + placeholder.len ..];
    }
    try w.writeAll(rest);
}

fn unreserved(char: u8) bool {
    return switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

const testing = std.testing;

fn expectFilled(expected: []const u8, template: []const u8, text: []const u8) !void {
    const filled = try fill(testing.allocator, template, text);
    defer testing.allocator.free(filled);
    try testing.expectEqualStrings(expected, filled);
}

fn expectHost(expected: ?[]const u8, template: []const u8) !void {
    const host = try hostOf(testing.allocator, template);
    defer if (host) |found| testing.allocator.free(found);

    if (expected) |wanted| {
        try testing.expectEqualStrings(wanted, host orelse return error.TestExpectedHost);
    } else {
        try testing.expectEqual(@as(?[]u8, null), host);
    }
}

test "a space becomes %20 and every reserved character is encoded" {
    try expectFilled(
        "https://search.brave.com/search?q=zig%20std%26more%2Fx%3Fy%3D1%2B2",
        "https://search.brave.com/search?q=%s",
        "zig std&more/x?y=1+2",
    );
}

test "letters, digits and -._~ stay as they are" {
    try expectFilled("https://e.org/?q=Az09-._~", "https://e.org/?q=%s", "Az09-._~");
}

test "the bytes of UTF-8 are encoded one by one" {
    try expectFilled("https://e.org/?q=%C3%BCber", "https://e.org/?q=%s", "über");
}

test "every %s is filled, not only the first" {
    try expectFilled("https://e.org/a%20b/?q=a%20b", "https://e.org/%s/?q=%s", "a b");
}

test "empty text leaves the placeholder empty" {
    try expectFilled("https://search.brave.com/search?q=", "https://search.brave.com/search?q=%s", "");
}

test "a template without %s is left as written" {
    try expectFilled("https://e.org/start", "https://e.org/start", "ignored");
    try testing.expect(!takesText("https://e.org/start"));
    try testing.expect(takesText("https://e.org/?q=%s"));
}

test "parentheses are encoded too, so a path keeps them literal" {
    try expectFilled(
        "https://en.wikipedia.org/wiki/Zig%20%28programming%20language%29",
        "https://en.wikipedia.org/wiki/%s",
        "Zig (programming language)",
    );
}

test "the host is read in lowercase without its port" {
    try expectHost("search.brave.com", "https://Search.Brave.COM/search?q=%s");
    try expectHost("localhost", "http://localhost:8080/?q=%s");
    try expectHost("en.wikipedia.org", "https://en.wikipedia.org/wiki/%s");
}

test "a URL without a host has none" {
    try expectHost(null, "man:%s");
    try expectHost(null, "not a url %s");
}

test "the favicon is asked of the service by host" {
    const url = try faviconOf(testing.allocator, "search.brave.com");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://icons.duckduckgo.com/ip3/search.brave.com.ico", url);
}
