const std = @import("std");
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const clipboard = @import("clipboard.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.capture);

const unknown_mime = "application/octet-stream";
const text_supertype = "text/plain";

pub const State = enum { data, nil, clear, sensitive };

pub const Kind = struct {
    mime: []const u8,
    icon: []const u8,
    text: bool,
};

const Task = union(enum) {
    keep: clipboard.Record,
    forget_newest,
    forget_all,
};

pub fn stateOf(value: ?[]const u8) State {
    const text = value orelse return .data;

    if (std.mem.eql(u8, text, "nil")) return .nil;
    if (std.mem.eql(u8, text, "clear")) return .clear;
    if (std.mem.eql(u8, text, "sensitive")) return .sensitive;
    return .data;
}

pub fn run(init: std.process.Init, limits: clipboard.Limits) !u8 {
    const gpa = init.gpa;

    switch (stateOf(init.environ_map.get("CLIPBOARD_STATE"))) {
        .nil => return 0,
        .sensitive => {
            log.debug("the selection is marked sensitive, so it is not stored", .{});
            return 0;
        },
        .clear => return withStore(init, limits, .forget_newest),
        .data => {},
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const bytes = read(gpa, init.io, limits.max_size_bytes) catch |err| switch (err) {
        error.TooLarge => {
            log.warn(
                "the selection is larger than {d} bytes and was not stored, " ++
                    "raise [clipboard] max_size_bytes to keep it",
                .{limits.max_size_bytes},
            );
            return 0;
        },
        error.ReadFailed => {
            log.warn("cannot read the selection from standard input", .{});
            return 1;
        },
        error.OutOfMemory => |leftover| return leftover,
    };
    defer gpa.free(bytes);

    if (std.mem.trim(u8, bytes, &std.ascii.whitespace).len == 0) return 0;
    if (bytes.len < limits.min_length) return 0;

    const kind = try classify(arena.allocator(), bytes);

    return withStore(init, limits, .{ .keep = .{
        .digest = clipboard.digestOf(bytes),
        .mime = kind.mime,
        .icon = kind.icon,
        .preview = if (kind.text) try previewOf(arena.allocator(), bytes) else "",
        .content = bytes,
        .at = clipboard.now(init.io),
    } });
}

pub fn clear(init: std.process.Init) !u8 {
    return withStore(init, .{}, .forget_all);
}

fn withStore(init: std.process.Init, limits: clipboard.Limits, task: Task) !u8 {
    const path = (try clipboard.defaultPath(init.gpa, init.environ_map)) orelse {
        log.warn("neither XDG_DATA_HOME nor HOME is set, so there is nowhere to store", .{});
        return 1;
    };
    defer init.gpa.free(path);

    var store = clipboard.Store.open(init.gpa, init.io, path) catch |err| {
        log.warn("cannot open {s}: {t}", .{ path, err });
        return 1;
    };
    defer store.close();

    const wanted = switch (task) {
        .forget_newest => {
            store.deleteNewest();
            return 0;
        },
        .forget_all => {
            log.info("cleared {d} entries from the clipboard history", .{store.wipe()});
            return 0;
        },
        .keep => |record| record,
    };

    store.put(wanted) catch |err| {
        log.warn("cannot store the selection: {t}", .{err});
        return 1;
    };
    store.trim(limits, wanted.at);
    return 0;
}

const ReadError = Allocator.Error || error{ TooLarge, ReadFailed };

fn read(gpa: Allocator, io: std.Io, max_bytes: usize) ReadError![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(gpa);

    var staging: [64 * 1024]u8 = undefined;
    var source = std.Io.File.stdin().reader(io, &staging);
    source.interface.appendRemaining(gpa, &raw, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.TooLarge,
        error.ReadFailed => return error.ReadFailed,
        error.OutOfMemory => |leftover| return leftover,
    };

    return raw.toOwnedSlice(gpa);
}

pub fn classify(arena: Allocator, bytes: []const u8) Allocator.Error!Kind {
    const guessed = gio.g_content_type_guess(null, bytes.ptr, bytes.len, null) orelse {
        return .{ .mime = unknown_mime, .icon = "", .text = false };
    };
    defer glib.g_free(guessed);

    const mime = mimeOf(guessed);
    defer if (mime != guessed) glib.g_free(mime);

    return .{
        .mime = try arena.dupe(u8, std.mem.span(mime)),
        .icon = try iconOf(arena, mime),
        .text = gio.g_content_type_is_a(mime, text_supertype) != c.FALSE,
    };
}

fn mimeOf(guessed: [*:0]u8) [*:0]u8 {
    const found = gio.g_content_type_get_mime_type(guessed) orelse return guessed;
    if (found[0] == 0) {
        glib.g_free(found);
        return guessed;
    }
    return found;
}

fn iconOf(arena: Allocator, mime: [*:0]const u8) Allocator.Error![]const u8 {
    const icon = gio.g_content_type_get_icon(mime) orelse return "";
    defer glib.g_object_unref(icon);

    const text = gio.g_icon_to_string(icon) orelse return "";
    defer glib.g_free(text);

    return arena.dupe(u8, std.mem.span(text));
}

pub fn previewOf(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    var pending = false;
    for (bytes) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending = out.items.len > 0;
            continue;
        }
        if (pending) {
            if (out.items.len >= clipboard.preview_bytes) break;
            try out.append(arena, ' ');
            pending = false;
        }
        if (out.items.len >= clipboard.preview_bytes) break;
        try out.append(arena, byte);
    }

    return valid(arena, whole(out.items));
}

fn whole(text: []const u8) []const u8 {
    var at = text.len;
    while (at > 0) : (at -= 1) {
        const byte = text[at - 1];
        if (byte & 0xc0 == 0x80) continue;

        const length = std.unicode.utf8ByteSequenceLength(byte) catch return text[0 .. at - 1];
        return if (at - 1 + length <= text.len) text else text[0 .. at - 1];
    }
    return text[0..0];
}

fn valid(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;

    const owned = try arena.dupeZ(u8, text);
    const made = glib.g_utf8_make_valid(owned.ptr, @intCast(owned.len));
    defer glib.g_free(made);

    return arena.dupe(u8, std.mem.span(made));
}

const testing = std.testing;

test "the clipboard state is read, and anything unknown counts as data" {
    try testing.expectEqual(State.data, stateOf(null));
    try testing.expectEqual(State.data, stateOf("data"));
    try testing.expectEqual(State.data, stateOf("something-later"));
    try testing.expectEqual(State.data, stateOf(""));
    try testing.expectEqual(State.nil, stateOf("nil"));
    try testing.expectEqual(State.clear, stateOf("clear"));
    try testing.expectEqual(State.sensitive, stateOf("sensitive"));
}

fn preview(text: []const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return testing.allocator.dupe(u8, try previewOf(arena.allocator(), text));
}

test "a preview is one line with single spaces" {
    const found = try preview("first line\nsecond\tline\r\n\r\nthird");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("first line second line third", found);
}

test "a preview has no leading or trailing whitespace" {
    const found = try preview("   \n  padded  \n   ");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("padded", found);
}

test "whitespace on its own previews as nothing" {
    const found = try preview(" \t\n\r ");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("", found);
}

test "a long selection is cut at the preview size" {
    const long = "a" ** (clipboard.preview_bytes * 2);

    const found = try preview(long);
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(usize, clipboard.preview_bytes), found.len);
}

test "the cut lands on a character boundary" {
    const filler = "a" ** (clipboard.preview_bytes - 1);

    const found = try preview(filler ++ "ä");
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(usize, clipboard.preview_bytes - 1), found.len);
    try testing.expect(std.unicode.utf8ValidateSlice(found));
}

test "a multi byte character that fits is kept whole" {
    const found = try preview("héllo wörld");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("héllo wörld", found);
    try testing.expect(std.unicode.utf8ValidateSlice(found));
}

test "bytes that are not utf-8 still preview as something valid" {
    const found = try preview("caf\xe9 latte");
    defer testing.allocator.free(found);

    try testing.expect(std.unicode.utf8ValidateSlice(found));
    try testing.expect(std.mem.indexOf(u8, found, "latte") != null);
}

test "an incomplete trailing sequence is dropped" {
    try testing.expectEqualStrings("ab", whole("ab\xc3"));
    try testing.expectEqualStrings("ab", whole("ab\xe2\x82"));
    try testing.expectEqualStrings("ab\xc3\xa4", whole("ab\xc3\xa4"));
    try testing.expectEqualStrings("", whole("\xc3"));
    try testing.expectEqualStrings("", whole(""));
}

fn kindOf(bytes: []const u8) !Kind {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try classify(arena.allocator(), bytes);
    return .{
        .mime = try testing.allocator.dupe(u8, found.mime),
        .icon = try testing.allocator.dupe(u8, found.icon),
        .text = found.text,
    };
}

fn freeKind(kind: Kind) void {
    testing.allocator.free(kind.mime);
    testing.allocator.free(kind.icon);
}

test "plain text is recognized as text" {
    const kind = try kindOf("just some words in a sentence\n");
    defer freeKind(kind);

    try testing.expectEqualStrings("text/plain", kind.mime);
    try testing.expect(kind.text);
    try testing.expect(std.mem.indexOf(u8, kind.icon, "text-x-generic") != null);
}

test "a png is recognized as an image and not as text" {
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++ ("\x00" ** 32);

    const kind = try kindOf(png);
    defer freeKind(kind);

    try testing.expectEqualStrings("image/png", kind.mime);
    try testing.expect(!kind.text);
    try testing.expect(std.mem.indexOf(u8, kind.icon, "image-x-generic") != null);
}

test "a pdf is recognized as a document and not as text" {
    const pdf = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n";

    const kind = try kindOf(pdf);
    defer freeKind(kind);

    try testing.expectEqualStrings("application/pdf", kind.mime);
    try testing.expect(!kind.text);
}

test "a shell script counts as text, so its own lines are the title" {
    const kind = try kindOf("#!/bin/sh\necho hello\n");
    defer freeKind(kind);

    try testing.expectEqualStrings("application/x-shellscript", kind.mime);
    try testing.expect(kind.text);
}
