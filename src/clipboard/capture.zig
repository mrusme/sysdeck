const std = @import("std");
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const clipboard = @import("clipboard.zig");
const clock = @import("core").clock;
const command = @import("core").command;
const counts_mod = @import("core").counts;
const store_mod = @import("core").store;

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

const Programs = struct {
    paste: []const u8 = "wl-paste",
    copy: []const u8 = "wl-copy",
};

const Task = union(enum) {
    keep: clipboard.Record,
    forget_newest,
    forget_held: clipboard.Digest,
    forget_all,
};

const Held = union(enum) {
    digest: clipboard.Digest,
    nothing,
    missing,
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
        .clear => return withStore(gpa, init.io, init.environ_map, limits, .forget_newest),
        .data => {},
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const bytes = read(gpa, init.io, .stdin(), limits.max_size_bytes) catch |err| switch (err) {
        error.TooLarge => {
            log.warn(
                "the selection is larger than {d} bytes and was not stored, " ++
                    "raise [sources.clipboard] max_size_bytes to keep it",
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

    return withStore(gpa, init.io, init.environ_map, limits, .{ .keep = .{
        .digest = clipboard.digestOf(bytes),
        .mime = kind.mime,
        .icon = kind.icon,
        .preview = if (kind.text) try previewOf(arena.allocator(), bytes) else "",
        .content = bytes,
        .at = clock.now(init.io),
    } });
}

pub fn clear(init: std.process.Init) !u8 {
    return withStore(init.gpa, init.io, init.environ_map, .{}, .forget_all);
}

pub fn drop(init: std.process.Init, limits: clipboard.Limits) !u8 {
    return dropWith(init.gpa, init.io, init.environ_map, limits, .{});
}

fn dropWith(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    limits: clipboard.Limits,
    programs: Programs,
) !u8 {
    if (!wayland(environ)) {
        log.warn("--clipboard-drop needs wl-paste and wl-copy, which want a Wayland session", .{});
        return 1;
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const forgotten: u8 = switch (try held(gpa, arena.allocator(), io, environ, limits, programs.paste)) {
        .digest => |digest| try withStore(gpa, io, environ, limits, .{ .forget_held = digest }),
        .nothing => 0,
        .missing => 1,
    };

    const cleared = try clearSelection(gpa, arena.allocator(), io, environ, programs.copy);
    return if (forgotten == 0 and cleared) 0 else 1;
}

fn wayland(environ: *const std.process.Environ.Map) bool {
    const display = environ.get("WAYLAND_DISPLAY") orelse return false;
    return display.len > 0;
}

fn held(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    limits: clipboard.Limits,
    program: []const u8,
) error{ OutOfMemory, Canceled }!Held {
    const arguments = [_][]const u8{"--no-newline"};
    const line: command.Line = .{ .program = program, .arguments = &arguments };

    const ran = try command.run(gpa, arena, io, environ, &.{ program, arguments[0] }, .{
        .output = limits.max_size_bytes,
    });
    switch (ran) {
        .printed => |bytes| {
            defer gpa.free(bytes);
            return .{ .digest = clipboard.digestOf(bytes) };
        },
        .missing => {
            log.warn("there is no {s} in $PATH, so the clipboard history is left as it is", .{program});
            return .missing;
        },
        .failed => |failure| {
            log.info("\"{f}\" {f}, so the clipboard history is left as it is", .{ line, failure });
            return .nothing;
        },
    }
}

fn clearSelection(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    program: []const u8,
) error{ OutOfMemory, Canceled }!bool {
    const arguments = [_][]const u8{"--clear"};
    const line: command.Line = .{ .program = program, .arguments = &arguments };

    switch (try command.run(gpa, arena, io, environ, &.{ program, arguments[0] }, .{})) {
        .printed => |bytes| {
            gpa.free(bytes);
            return true;
        },
        .missing => log.warn("there is no {s} in $PATH, so the clipboard is left as it is", .{program}),
        .failed => |failure| log.warn("\"{f}\" {f}, so the clipboard is left as it is", .{ line, failure }),
    }
    return false;
}

fn withStore(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    limits: clipboard.Limits,
    task: Task,
) !u8 {
    const path = (try clipboard.defaultPath(gpa, environ)) orelse {
        log.warn("neither XDG_DATA_HOME nor HOME is set, so there is nowhere to store", .{});
        return 1;
    };
    defer gpa.free(path);

    var store = clipboard.Store.open(gpa, io, path) catch |err| {
        log.warn("cannot open {s}: {t}", .{ path, err });
        return 1;
    };
    defer store.close();

    const wanted = switch (task) {
        .forget_newest => return forgetNewest(gpa, io, environ, &store, null),
        .forget_held => |digest| return forgetNewest(gpa, io, environ, &store, digest),
        .forget_all => {
            log.info("cleared {d} entries from the clipboard history", .{store.wipe()});
            forgetCounts(gpa, io, environ);
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

fn forgetNewest(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    store: *clipboard.Store,
    expected: ?clipboard.Digest,
) u8 {
    const newest = store.newest() catch |err| {
        log.warn("cannot read the newest entry of the clipboard history: {t}", .{err});
        return 1;
    } orelse {
        log.info("the clipboard history is empty", .{});
        return 0;
    };

    if (expected) |digest| {
        if (!std.mem.eql(u8, &digest, &newest.digest)) {
            log.info("the newest entry of the clipboard history is not what the clipboard holds, so it is kept", .{});
            return 0;
        }
    }

    const removed = store.delete(newest.id) catch |err| {
        log.warn("cannot delete the newest entry of the clipboard history: {t}", .{err});
        return 1;
    } orelse return 0;

    scrubCounter(gpa, io, environ, removed);
    log.info("deleted the newest entry of the clipboard history", .{});
    return 0;
}

fn scrubCounter(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map, digest: clipboard.Digest) void {
    const path = store_mod.defaultPath(gpa, environ) catch {
        log.warn("out of memory, so the counter of the deleted entry is kept", .{});
        return;
    } orelse return;
    defer gpa.free(path);

    const found = store_mod.Store.open(gpa, io, path) catch |err| {
        log.warn("cannot open {s}: {t}, so the counter of the deleted entry is kept", .{ path, err });
        return;
    };
    defer found.close();

    counts_mod.eraseSecurely(found.conn, clipboard.table, &.{counts_mod.id(&digest)}) catch |err| {
        log.warn("cannot delete the counter of the deleted entry: {t}", .{err});
    };
}

fn forgetCounts(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map) void {
    const path = (store_mod.defaultPath(gpa, environ) catch return) orelse return;
    defer gpa.free(path);

    const found = store_mod.Store.open(gpa, io, path) catch |err| {
        log.warn("cannot open {s}: {t}, so the clipboard counters are kept", .{ path, err });
        return;
    };
    defer found.close();

    found.conn.exec("DELETE FROM counts WHERE source = ?1", .{clipboard.table}) catch |err| {
        log.warn("cannot clear the clipboard counters: {t}", .{err});
    };
}

const ReadError = Allocator.Error || error{ TooLarge, ReadFailed };

fn read(gpa: Allocator, io: std.Io, file: std.Io.File, max_bytes: usize) ReadError![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(gpa);

    var staging: [64 * 1024]u8 = undefined;
    var source = file.readerStreaming(io, &staging);
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

    const owned = try arena.dupeSentinel(u8, text, 0);
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
    const long: [clipboard.preview_bytes * 2]u8 = @splat('a');

    const found = try preview(&long);
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(usize, clipboard.preview_bytes), found.len);
}

test "the cut lands on a character boundary" {
    const filler: [clipboard.preview_bytes - 1]u8 = @splat('a');

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
    try testing.expect(std.mem.find(u8, found, "latte") != null);
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
    try testing.expect(std.mem.find(u8, kind.icon, "text-x-generic") != null);
}

test "a png is recognized as an image and not as text" {
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++ @as([32]u8, @splat(0));

    const kind = try kindOf(png);
    defer freeKind(kind);

    try testing.expectEqualStrings("image/png", kind.mime);
    try testing.expect(!kind.text);
    try testing.expect(std.mem.find(u8, kind.icon, "image-x-generic") != null);
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

test "a selection given as a file is read from where it stands, not from its start" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "given", .data = "skipped\nwanted\n" });
    const file = try tmp.dir.openFile(testing.io, "given", .{});
    defer file.close(testing.io);

    var skip: ["skipped\n".len]u8 = undefined;
    var reader = file.readerStreaming(testing.io, &.{});
    try reader.interface.readSliceAll(&skip);

    const bytes = try read(testing.allocator, testing.io, file, 1024);
    defer testing.allocator.free(bytes);

    try testing.expectEqualStrings("wanted\n", bytes);
}

const secret = "hunter2-SECRET-value";

const Drop = struct {
    tmp: testing.TmpDir,
    environ: std.process.Environ.Map,
    programs: Programs = .{},
    root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    paste_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    copy_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,

    fn init(self: *Drop, holding: []const u8) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .environ = .init(testing.allocator) };
        errdefer self.deinit();

        const length = try self.tmp.dir.realPath(testing.io, &self.root_buffer);
        const root = self.root_buffer[0..length];

        try self.environ.put("XDG_DATA_HOME", root);
        try self.environ.put("WAYLAND_DISPLAY", "wayland-test");
        try self.environ.put("PATH", "/usr/bin:/bin");

        const paste = try testing.allocator.print(
            "#!/bin/sh\necho \"$*\" >> \"$0.log\"\nprintf '%s' '{s}'\n",
            .{holding},
        );
        defer testing.allocator.free(paste);

        try self.write("wl-paste", paste);
        try self.write("wl-copy", "#!/bin/sh\necho \"$*\" >> \"$0.log\"\n");

        self.programs = .{
            .paste = try std.mem.print(&self.paste_buffer, "{s}/wl-paste", .{root}),
            .copy = try std.mem.print(&self.copy_buffer, "{s}/wl-copy", .{root}),
        };
    }

    fn deinit(self: *Drop) void {
        self.environ.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *Drop, name: []const u8, body: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = name,
            .data = body,
            .flags = .{ .permissions = .executable_file },
        });
    }

    fn history(self: *Drop) !clipboard.Store {
        const path = (try clipboard.defaultPath(testing.allocator, &self.environ)).?;
        defer testing.allocator.free(path);
        return clipboard.Store.open(testing.allocator, testing.io, path);
    }

    fn counters(self: *Drop) !*store_mod.Store {
        const path = (try store_mod.defaultPath(testing.allocator, &self.environ)).?;
        defer testing.allocator.free(path);
        return store_mod.Store.open(testing.allocator, testing.io, path);
    }

    fn run(self: *Drop) !u8 {
        return dropWith(testing.allocator, testing.io, &self.environ, .{}, self.programs);
    }

    fn occurrences(self: *Drop, name: []const u8, wanted: []const u8) !usize {
        const bytes = self.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer testing.allocator.free(bytes);
        return std.mem.count(u8, bytes, wanted);
    }

    fn logOf(self: *Drop, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited);
    }

    fn fill(self: *Drop, history_store: *clipboard.Store, counts: *store_mod.Store) !void {
        _ = self;
        for ([_][]const u8{ "kept", secret }, 0..) |body, at| {
            try history_store.put(.{
                .digest = clipboard.digestOf(body),
                .mime = "text/plain",
                .icon = "",
                .preview = body,
                .content = body,
                .at = @intCast(1000 + at),
            });
            try counts.conn.exec(
                "INSERT INTO counts(source, id, shown, chosen) VALUES(?1, ?2, 3, 2)",
                .{ clipboard.table, @as(i64, @bitCast(counts_mod.id(&clipboard.digestOf(body)))) },
            );
        }
    }
};

fn counted(counts: *store_mod.Store, body: []const u8) !bool {
    const id: i64 = @bitCast(counts_mod.id(&clipboard.digestOf(body)));
    const found = try counts.conn.row("SELECT 1 FROM counts WHERE source = ?1 AND id = ?2", .{ clipboard.table, id });
    const row = found orelse return false;
    row.deinit();
    return true;
}

test "a drop deletes the newest entry and its counter when the clipboard holds it, and empties the clipboard" {
    var rig: Drop = undefined;
    try rig.init(secret);
    defer rig.deinit();

    var history_store = try rig.history();
    defer history_store.close();
    const counts = try rig.counters();
    defer counts.close();

    try rig.fill(&history_store, counts);
    try history_store.conn.execNoArgs("PRAGMA wal_checkpoint(TRUNCATE)");
    try testing.expect(try rig.occurrences("sysdeck/clipboard.db", secret) > 0);

    try testing.expectEqual(0, try rig.run());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const left = try history_store.recent(arena.allocator(), 10);
    try testing.expectEqual(1, left.len);
    try testing.expectEqualStrings("kept", left[0].preview);

    try testing.expect(!try counted(counts, secret));
    try testing.expect(try counted(counts, "kept"));

    try testing.expectEqual(0, try rig.occurrences("sysdeck/clipboard.db", secret));
    try testing.expectEqual(0, try rig.occurrences("sysdeck/clipboard.db-wal", secret));

    const pasted = try rig.logOf("wl-paste.log");
    defer testing.allocator.free(pasted);
    try testing.expectEqualStrings("--no-newline\n", pasted);

    const cleared = try rig.logOf("wl-copy.log");
    defer testing.allocator.free(cleared);
    try testing.expectEqualStrings("--clear\n", cleared);
}

test "a drop keeps the newest entry when the clipboard holds something else, and still empties the clipboard" {
    var rig: Drop = undefined;
    try rig.init("a copy that was never stored");
    defer rig.deinit();

    var history_store = try rig.history();
    defer history_store.close();
    const counts = try rig.counters();
    defer counts.close();

    try rig.fill(&history_store, counts);

    try testing.expectEqual(0, try rig.run());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(2, (try history_store.recent(arena.allocator(), 10)).len);
    try testing.expect(try counted(counts, secret));
    try testing.expect(try counted(counts, "kept"));

    const cleared = try rig.logOf("wl-copy.log");
    defer testing.allocator.free(cleared);
    try testing.expectEqualStrings("--clear\n", cleared);
}

test "a drop without wl-paste keeps the history, still empties the clipboard and reports the failure" {
    var rig: Drop = undefined;
    try rig.init(secret);
    defer rig.deinit();

    var history_store = try rig.history();
    defer history_store.close();
    const counts = try rig.counters();
    defer counts.close();

    try rig.fill(&history_store, counts);
    rig.programs.paste = "/nonexistent/wl-paste";

    try testing.expectEqual(1, try rig.run());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(2, (try history_store.recent(arena.allocator(), 10)).len);

    const cleared = try rig.logOf("wl-copy.log");
    defer testing.allocator.free(cleared);
    try testing.expectEqualStrings("--clear\n", cleared);
}

test "a drop outside a Wayland session touches neither the history nor the clipboard" {
    var rig: Drop = undefined;
    try rig.init(secret);
    defer rig.deinit();

    var history_store = try rig.history();
    defer history_store.close();
    const counts = try rig.counters();
    defer counts.close();

    try rig.fill(&history_store, counts);
    _ = rig.environ.swapRemove("WAYLAND_DISPLAY");

    try testing.expectEqual(1, try rig.run());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(2, (try history_store.recent(arena.allocator(), 10)).len);
    try testing.expectError(error.FileNotFound, rig.logOf("wl-paste.log"));
    try testing.expectError(error.FileNotFound, rig.logOf("wl-copy.log"));
}
