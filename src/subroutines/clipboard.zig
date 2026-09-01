const std = @import("std");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const clipboard = @import("../clipboard/clipboard.zig");
const list = @import("../ui/list.zig");
const media = @import("core").media;
const rank = @import("core").rank;
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.clipboard);

pub const table = clipboard.table;

const title_chars = 64;

const history_rows = 100;
const max_rows = 200;
const no_limit = -1;
const copy_program: [*:0]const u8 = "wl-copy";
const text_supertype: [*:0]const u8 = "text/plain";
const fallback_icon: [:0]const u8 = "edit-paste";
const day_format: [*:0]const u8 = "%Y-%m-%d";
const time_format: [*:0]const u8 = "%H:%M";
const stamp_format: [*:0]const u8 = "%Y-%m-%d %H:%M";
const day_length = "2026-08-26".len;

pub const Index = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    limits: clipboard.Limits,
    store: ?clipboard.Store = null,
    pending: std.AutoHashMapUnmanaged(i64, rank.Weight) = .empty,

    guard: std.Io.Mutex = .init,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Search) };
    }

    pub fn history(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(History) };
    }

    fn hits(
        self: *Index,
        gpa: Allocator,
        query: []const u8,
        limit: i64,
        weighted: bool,
    ) subroutines.Error!subroutines.Output {
        const store = if (self.store) |*found| found else return .nothing;

        self.guard.lockUncancelable(self.io);
        defer self.guard.unlock(self.io);

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const scratch = arena.allocator();
        const entries = store.recent(scratch, limit) catch |err| {
            log.warn("cannot read the history: {t}", .{err});
            return .nothing;
        };
        if (entries.len == 0) return .nothing;

        const haystacks = try scratch.alloc([]const u8, entries.len);
        const weights = if (weighted) try scratch.alloc(rank.Weight, entries.len) else null;

        for (entries, 0..) |entry, at| {
            haystacks[at] = entry.preview;
            if (weights) |found| found[at] = self.weightOf(entry);
        }

        const matches = try rank.rank(gpa, haystacks, weights, query);
        defer gpa.free(matches);
        if (matches.len == 0) return .nothing;

        const shown = matches[0..@min(matches.len, max_rows)];
        for (shown) |match| self.note(entries[match.index].id, .{ .shown = 1 });

        const stamp: Stamp = .of(scratch, clipboard.now(self.io));

        const built = try gpa.alloc(subroutines.Hit, shown.len);
        errdefer gpa.free(built);

        for (shown, 0..) |match, at| {
            const entry = entries[match.index];
            built[at] = .{
                .row = .{
                    .id = @bitCast(entry.id),
                    .icon = iconOf(scratch, entry.icon),
                    .title = try titleOf(gpa, scratch, entry),
                    .detail = try detailOf(gpa, scratch, stamp, entry),
                    .media = .{
                        .mime = try gpa.dupe(u8, entry.mime),
                        .size = sizeOf(entry.bytes),
                        .id = @bitCast(entry.id),
                        .context = self,
                        .load = &loadMedia,
                    },
                },
                .score = match.score,
            };
        }

        return .{ .hits = built };
    }

    fn content(self: *Index, arena: Allocator, id: i64) ?clipboard.Content {
        const store = if (self.store) |*found| found else return null;

        self.guard.lockUncancelable(self.io);
        defer self.guard.unlock(self.io);

        return store.contentOf(arena, id) catch |err| {
            log.warn("cannot read entry {d}: {t}", .{ id, err });
            return null;
        };
    }

    fn take(self: *Index, gpa: Allocator, id: u64) ?clipboard.Content {
        const store = if (self.store) |*found| found else return null;
        const row: i64 = @bitCast(id);

        self.guard.lockUncancelable(self.io);
        defer self.guard.unlock(self.io);

        const found = store.contentOf(gpa, row) catch |err| {
            log.warn("cannot read entry {d}: {t}", .{ row, err });
            return null;
        };
        if (found != null) self.note(row, .{ .chosen = 1 });
        return found;
    }

    fn weightOf(self: *Index, entry: clipboard.Entry) rank.Weight {
        const extra = self.pending.get(entry.id) orelse rank.Weight{};
        return .{
            .shown = entry.shown +| extra.shown,
            .chosen = entry.chosen +| extra.chosen,
        };
    }

    fn note(self: *Index, id: i64, by: rank.Weight) void {
        const slot = self.pending.getOrPut(self.gpa, id) catch return;
        if (!slot.found_existing) slot.value_ptr.* = .{};
        slot.value_ptr.shown +|= by.shown;
        slot.value_ptr.chosen +|= by.chosen;
    }

    fn flush(self: *Index) void {
        const store = if (self.store) |*found| found else return;

        var deltas: std.ArrayList(clipboard.Delta) = .empty;
        defer deltas.deinit(self.gpa);

        var walker = self.pending.iterator();
        while (walker.next()) |entry| {
            deltas.append(self.gpa, .{
                .id = entry.key_ptr.*,
                .shown = entry.value_ptr.shown,
                .chosen = entry.value_ptr.chosen,
            }) catch break;
        }

        store.flush(deltas.items);
    }

    fn searchLimit(self: *Index) i64 {
        if (self.limits.max_items > 0) return self.limits.max_items;
        return no_limit;
    }

    fn wayland(self: *Index) bool {
        const display = self.environ.get("WAYLAND_DISPLAY") orelse return false;
        return display.len > 0;
    }
};

pub fn open(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    limits: clipboard.Limits,
) Allocator.Error!Index {
    var self: Index = .{ .gpa = gpa, .io = io, .environ = environ, .limits = limits };

    const path = (try clipboard.defaultPath(gpa, environ)) orelse return self;
    defer gpa.free(path);

    self.store = clipboard.Store.open(gpa, io, path) catch |err| {
        log.warn("cannot open {s}: {t}, so there is no history", .{ path, err });
        return self;
    };
    return self;
}

const Search = struct {
    pub const Context = Index;

    pub const choose = shared.choose;
    pub const release = shared.release;
    pub const stale = shared.stale;
    pub const refresh = shared.refresh;

    pub fn run(self: *Index, gpa: Allocator, text: []const u8) subroutines.Error!subroutines.Output {
        const query = std.mem.trim(u8, text, " \t");
        if (query.len == 0) return .nothing;

        return self.hits(gpa, query, self.searchLimit(), true);
    }

    pub fn retire(self: *Index, _: ?*store_mod.Store) void {
        self.flush();
        self.pending.deinit(self.gpa);
        if (self.store) |*found| found.close();
        self.store = null;
    }
};

const History = struct {
    pub const Context = Index;

    pub const choose = shared.choose;
    pub const release = shared.release;
    pub const stale = shared.stale;
    pub const refresh = shared.refresh;

    pub fn run(self: *Index, gpa: Allocator, text: []const u8) subroutines.Error!subroutines.Output {
        return self.hits(gpa, std.mem.trim(u8, text, " \t"), history_rows, false);
    }

    pub fn retire(_: *Index, _: ?*store_mod.Store) void {}
};

fn loadMedia(context: *anyopaque, arena: Allocator, id: u64) ?media.Payload {
    const self: *Index = @ptrCast(@alignCast(context));
    const found = self.content(arena, @bitCast(id)) orelse return null;
    return .{ .bytes = found.bytes };
}

fn sizeOf(value: i64) u64 {
    return std.math.cast(u64, value) orelse 0;
}

const shared = struct {
    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const content = self.take(arena.allocator(), id) orelse return .keep;

        const copied = if (self.wayland())
            spawnCopy(arena.allocator(), content)
        else
            handOver(arena.allocator(), content);

        return if (copied) .close else .keep;
    }

    pub fn release(_: *Index, gpa: Allocator, output: subroutines.Output) void {
        switch (output) {
            .nothing, .marks, .answer => {},
            .hits => |found| {
                for (found) |hit| {
                    gpa.free(hit.row.title);
                    gpa.free(hit.row.detail);
                    if (hit.row.media) |handle| gpa.free(handle.mime);
                    switch (hit.row.icon) {
                        .gicon => |icon| glib.g_object_unref(icon),
                        else => {},
                    }
                }
                gpa.free(found);
            },
        }
    }

    pub fn stale(_: *Index) bool {
        return false;
    }

    pub fn refresh(_: *Index) void {}
};

fn spawnCopy(arena: Allocator, content: clipboard.Content) bool {
    const mime = arena.dupeZ(u8, content.mime) catch return false;
    var argv = [_:null]?[*:0]const u8{ copy_program, "--type", mime.ptr };

    var writing: c_int = -1;
    var err: ?*c.GError = null;
    const started = glib.g_spawn_async_with_pipes(
        null,
        &argv,
        null,
        c.spawn_search_path | c.spawn_stdout_to_dev_null | c.spawn_stderr_to_dev_null,
        null,
        null,
        null,
        &writing,
        null,
        null,
        &err,
    ) != c.FALSE;

    if (!started) {
        defer if (err) |detail| glib.g_error_free(detail);
        log.warn("cannot start wl-copy: {s}", .{message(err)});
        return false;
    }

    defer _ = std.c.close(writing);
    return writeAll(writing, content.bytes);
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const wrote = std.c.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (wrote < 0) {
            if (std.c.errno(wrote) == .INTR) continue;
            log.warn("cannot hand {d} bytes to wl-copy", .{bytes.len});
            return false;
        }
        if (wrote == 0) return false;
        sent += @intCast(wrote);
    }
    return true;
}

fn handOver(arena: Allocator, content: clipboard.Content) bool {
    const mime = arena.dupeZ(u8, content.mime) catch return false;
    if (gio.g_content_type_is_a(mime.ptr, text_supertype) == c.FALSE) {
        log.warn("{s} needs wl-copy, which wants a Wayland session", .{content.mime});
        return false;
    }

    const display = gdk.gdk_display_get_default() orelse return false;
    const board = gdk.gdk_display_get_clipboard(display);

    const text = arena.dupeZ(u8, content.bytes) catch return false;
    gdk.gdk_clipboard_set_text(board, text.ptr);
    gdk.gdk_clipboard_store_async(board, c.priority_default, null, null, null);
    return true;
}

fn message(err: ?*c.GError) []const u8 {
    const detail = err orelse return "unknown reason";
    return std.mem.span(detail.message orelse return "unknown reason");
}

fn iconOf(arena: Allocator, stored: []const u8) list.Icon {
    if (stored.len == 0) return .{ .name = fallback_icon };

    const text = arena.dupeZ(u8, stored) catch return .{ .name = fallback_icon };
    const icon = gio.g_icon_new_for_string(text.ptr, null) orelse return .{ .name = fallback_icon };
    return .{ .gicon = icon };
}

fn titleOf(
    gpa: Allocator,
    arena: Allocator,
    entry: clipboard.Entry,
) Allocator.Error![:0]const u8 {
    const mime = try arena.dupeZ(u8, entry.mime);
    if (entry.preview.len > 0 and gio.g_content_type_is_a(mime.ptr, text_supertype) != c.FALSE) {
        return shortened(gpa, entry.preview);
    }

    const label = gio.g_content_type_get_description(mime.ptr) orelse {
        return gpa.dupeZ(u8, entry.mime);
    };
    defer glib.g_free(label);

    return gpa.dupeZ(u8, std.mem.span(label));
}

pub fn shortened(gpa: Allocator, text: []const u8) Allocator.Error![:0]const u8 {
    var seen: usize = 0;
    var at: usize = 0;

    while (at < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
        if (at + length > text.len) break;
        if (seen == title_chars) return std.fmt.allocPrintSentinel(gpa, "{s}...", .{text[0..at]}, 0);

        seen += 1;
        at += length;
    }

    return gpa.dupeZ(u8, text);
}

fn detailOf(
    gpa: Allocator,
    arena: Allocator,
    stamp: Stamp,
    entry: clipboard.Entry,
) Allocator.Error![:0]const u8 {
    const when = stamp.describe(arena, entry.updated_at);
    if (entry.copied <= 1) return gpa.dupeZ(u8, when);

    return std.fmt.allocPrintSentinel(gpa, "{s} \u{00b7} copied {d} times", .{ when, entry.copied }, 0);
}

pub const Stamp = struct {
    at: i64,
    today: [day_length]u8 = @splat(0),
    yesterday: [day_length]u8 = @splat(0),

    pub fn of(arena: Allocator, at: i64) Stamp {
        var self: Stamp = .{ .at = at };

        const local = glib.g_date_time_new_from_unix_local(@divFloor(at, std.time.ms_per_s)) orelse {
            return self;
        };
        defer glib.g_date_time_unref(local);

        copyDay(&self.today, formatted(arena, local, day_format));

        const before = glib.g_date_time_add_days(local, -1) orelse return self;
        defer glib.g_date_time_unref(before);

        copyDay(&self.yesterday, formatted(arena, before, day_format));
        return self;
    }

    pub fn describe(self: Stamp, arena: Allocator, updated_at: i64) []const u8 {
        const elapsed = @max(self.at - updated_at, 0);

        if (elapsed < std.time.ms_per_min) return "just now";
        if (elapsed < std.time.ms_per_hour) return plural(arena, "minute", elapsed / std.time.ms_per_min);
        if (elapsed < std.time.ms_per_day) return plural(arena, "hour", elapsed / std.time.ms_per_hour);

        const local = glib.g_date_time_new_from_unix_local(@divFloor(updated_at, std.time.ms_per_s)) orelse {
            return plural(arena, "day", elapsed / std.time.ms_per_day);
        };
        defer glib.g_date_time_unref(local);

        const day = formatted(arena, local, day_format);
        if (std.mem.eql(u8, day, &self.yesterday)) {
            const clock = formatted(arena, local, time_format);
            return std.fmt.allocPrint(arena, "yesterday {s}", .{clock}) catch clock;
        }

        if (elapsed < std.time.ms_per_week) {
            return plural(arena, "day", elapsed / std.time.ms_per_day);
        }
        return formatted(arena, local, stamp_format);
    }
};

fn copyDay(out: *[day_length]u8, text: []const u8) void {
    if (text.len != out.len) return;
    @memcpy(out, text);
}

fn formatted(arena: Allocator, local: *c.GDateTime, format: [*:0]const u8) []const u8 {
    const text = glib.g_date_time_format(local, format) orelse return "";
    defer glib.g_free(text);
    return arena.dupe(u8, std.mem.span(text)) catch "";
}

fn plural(arena: Allocator, unit: []const u8, count: i64) []const u8 {
    const suffix: []const u8 = if (count == 1) "" else "s";
    return std.fmt.allocPrint(arena, "{d} {s}{s} ago", .{ count, unit, suffix }) catch unit;
}

const testing = std.testing;

fn stampAt(arena: Allocator, at: i64) Stamp {
    return .of(arena, at);
}

fn described(at: i64, updated_at: i64) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const stamp = stampAt(arena.allocator(), at);
    return testing.allocator.dupe(u8, stamp.describe(arena.allocator(), updated_at));
}

fn expectDescribed(wanted: []const u8, at: i64, updated_at: i64) !void {
    const found = try described(at, updated_at);
    defer testing.allocator.free(found);
    try testing.expectEqualStrings(wanted, found);
}

const noon = 1787_000_000_000;

test "a fresh entry reads as just now" {
    try expectDescribed("just now", noon, noon);
    try expectDescribed("just now", noon, noon - std.time.ms_per_s * 59);
}

test "an entry in the last hour reads in minutes" {
    try expectDescribed("1 minute ago", noon, noon - std.time.ms_per_min);
    try expectDescribed("5 minutes ago", noon, noon - 5 * std.time.ms_per_min);
    try expectDescribed("59 minutes ago", noon, noon - 59 * std.time.ms_per_min);
}

test "an entry in the last day reads in hours" {
    try expectDescribed("1 hour ago", noon, noon - std.time.ms_per_hour);
    try expectDescribed("3 hours ago", noon, noon - 3 * std.time.ms_per_hour);
    try expectDescribed("23 hours ago", noon, noon - 23 * std.time.ms_per_hour);
}

test "an entry within the week reads in days" {
    const found = try described(noon, noon - 4 * std.time.ms_per_day);
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("4 days ago", found);
}

test "the day before reads as yesterday and a clock time" {
    const found = try described(noon, noon - std.time.ms_per_day);
    defer testing.allocator.free(found);

    try testing.expect(std.mem.startsWith(u8, found, "yesterday "));
    try testing.expectEqual(@as(usize, "yesterday 00:00".len), found.len);
}

test "an old entry reads as a date and a clock time" {
    const found = try described(noon, noon - 30 * std.time.ms_per_day);
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(usize, "2026-08-26 14:02".len), found.len);
    try testing.expectEqual(@as(u8, '-'), found[4]);
    try testing.expectEqual(@as(u8, ':'), found[13]);
}

test "a clock that runs backwards still reads as just now" {
    try expectDescribed("just now", noon, noon + std.time.ms_per_hour);
}

test "the unit is singular at one and plural everywhere else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("1 hour ago", plural(arena.allocator(), "hour", 1));
    try testing.expectEqualStrings("2 hours ago", plural(arena.allocator(), "hour", 2));
    try testing.expectEqualStrings("0 days ago", plural(arena.allocator(), "day", 0));
}

fn cut(text: []const u8) ![:0]const u8 {
    return shortened(testing.allocator, text);
}

test "a short entry is titled with every character of it" {
    const found = try cut("the quick brown fox");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("the quick brown fox", found);
}

test "an entry of exactly the limit is left whole" {
    const exact = "a" ** title_chars;

    const found = try cut(exact);
    defer testing.allocator.free(found);

    try testing.expectEqualStrings(exact, found);
}

test "a longer entry is cut and told about with an ellipsis" {
    const long = "b" ** (title_chars + 40);

    const found = try cut(long);
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(usize, title_chars + 3), found.len);
    try testing.expect(std.mem.endsWith(u8, found, "..."));
    try testing.expectEqualStrings("b" ** title_chars, found[0..title_chars]);
}

test "the cut counts characters, not bytes" {
    const wide = "\u{00e4}" ** (title_chars + 10);

    const found = try cut(wide);
    defer testing.allocator.free(found);

    try testing.expect(std.unicode.utf8ValidateSlice(found));
    try testing.expectEqual(@as(usize, title_chars), try std.unicode.utf8CountCodepoints(found[0 .. found.len - 3]));
}

test "nothing at all is still nothing" {
    const found = try cut("");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("", found);
}

fn title(entry: clipboard.Entry) ![:0]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return titleOf(testing.allocator, arena.allocator(), entry);
}

const blank: clipboard.Entry = .{
    .id = 1,
    .mime = "",
    .icon = "",
    .preview = "",
    .bytes = 0,
    .created_at = 0,
    .updated_at = 0,
    .copied = 1,
    .shown = 0,
    .chosen = 0,
};

test "a text entry is titled with what was copied" {
    var entry = blank;
    entry.mime = "text/plain";
    entry.preview = "the quick brown fox";

    const found = try title(entry);
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("the quick brown fox", found);
}

test "a binary entry is titled with what kind of thing it is" {
    var entry = blank;
    entry.mime = "image/png";

    const found = try title(entry);
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("PNG image", found);
}

test "an audio entry says so too" {
    var entry = blank;
    entry.mime = "audio/mpeg";

    const found = try title(entry);
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("MP3 audio", found);
}

test "a type nothing knows falls back to the type itself" {
    var entry = blank;
    entry.mime = "application/x-nothing-knows-this";

    const found = try title(entry);
    defer testing.allocator.free(found);

    try testing.expect(found.len > 0);
}

test "an entry with no icon still gets one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("edit-paste", iconOf(arena.allocator(), "").name);
    try testing.expect(iconOf(arena.allocator(), ". GThemedIcon image-png image-x-generic") == .gicon);
}
