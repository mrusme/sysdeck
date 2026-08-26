const std = @import("std");
const c = @import("../c.zig");
const launch = @import("../launch.zig");
const list = @import("../list.zig");
const rank = @import("../rank.zig");
const source = @import("../source.zig");
const store_mod = @import("../store.zig");
const subroutines = @import("../subroutines.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.apps);

pub const table = "apps";

const max_rows = 200;
const max_keywords = 32;
const fallback_icon: [:0]const u8 = "application-x-executable";
const action_group = "Desktop Action ";

pub const Index = struct {
    gpa: Allocator,
    source: source.Source,
    path: ?[:0]const u8 = null,
    published: source.Published = .{},
    stamp: i64 = 0,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = &vtable };
    }
};

const vtable: subroutines.Subroutine.VTable = .{
    .run = &run,
    .choose = &choose,
    .release = &release,
    .stale = &stale,
    .refresh = &refresh,
    .retire = &retire,
    .actions = &actions,
    .perform = &perform,
};

pub fn open(
    gpa: Allocator,
    store: ?*store_mod.Store,
    max_age_minutes: i64,
    stamp: i64,
    published: source.Published,
) Allocator.Error!Index {
    var self: Index = .{
        .gpa = gpa,
        .source = .{ .gpa = gpa, .name = table, .current = .init(try source.empty(gpa)) },
        .published = published,
        .stamp = stamp,
    };

    const found = store orelse {
        self.source.needs_refresh = true;
        return self;
    };

    found.ensure(table) catch |err| {
        source.report(table, "prepare", err);
        self.source.needs_refresh = true;
        return self;
    };

    self.path = found.path;
    self.source.needs_refresh = store_mod.stale(found.updatedAt(table), stamp, max_age_minutes);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const records = found.load(arena.allocator(), table) catch |err| {
        source.report(table, "load", err);
        return self;
    };
    if (records.len == 0) return self;

    self.source.publish(try source.build(gpa, records, &iconOf, undefined));
    return self;
}

fn refresh(context: *anyopaque) void {
    const self: *Index = @ptrCast(@alignCast(context));

    log.debug("refreshing the index", .{});

    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();

    const records = scan(arena.allocator()) catch |err| {
        return source.report(table, "scan", err);
    };

    if (self.path) |file| {
        write(self.gpa, file, records, self.stamp) catch |err| source.report(table, "write", err);
    }

    const next = source.build(self.gpa, records, &iconOf, undefined) catch |err| {
        return source.report(table, "publish", err);
    };
    self.source.publish(next);
    log.debug("published {d} entries", .{next.entries.len});
    self.published.call();
}

fn write(
    gpa: Allocator,
    file: [:0]const u8,
    records: []const store_mod.Record,
    stamp: i64,
) !void {
    const conn = try store_mod.connect(file);
    defer conn.close();

    try store_mod.create(gpa, conn, table);
    try store_mod.replace(gpa, conn, table, .all, records, stamp);
}

pub fn scan(arena: Allocator) Allocator.Error![]store_mod.Record {
    var records: std.ArrayList(store_mod.Record) = .empty;

    const all = c.g_app_info_get_all() orelse return records.toOwnedSlice(arena);
    defer c.g_list_free_full(all, @ptrCast(&c.g_object_unref));

    var node: ?*c.GList = all;
    while (node) |current| : (node = current.next) {
        const info: *c.GAppInfo = @ptrCast(current.data orelse continue);
        if (c.g_app_info_should_show(info) == c.FALSE) continue;

        const id = span(c.g_app_info_get_id(info));
        if (id.len == 0) continue;

        const name = span(c.g_app_info_get_display_name(info) orelse c.g_app_info_get_name(info));
        if (name.len == 0) continue;

        try records.append(arena, try recordOf(arena, info, id, name));
    }

    return records.toOwnedSlice(arena);
}

fn recordOf(
    arena: Allocator,
    info: *c.GAppInfo,
    id: []const u8,
    name: []const u8,
) Allocator.Error!store_mod.Record {
    const desktop: *c.GDesktopAppInfo = @ptrCast(info);
    const generic = span(c.g_desktop_app_info_get_generic_name(desktop));
    const description = span(c.g_app_info_get_description(info));

    var words: [max_keywords][]const u8 = undefined;
    const count = collectKeywords(desktop, &words);

    return .{
        .key = try arena.dupe(u8, id),
        .title = try arena.dupe(u8, name),
        .detail = try arena.dupe(u8, if (description.len > 0) description else generic),
        .icon = try iconString(arena, info),
        .program = try arena.dupe(u8, span(c.g_app_info_get_executable(info))),
        .haystack = try haystackOf(arena, name, generic, description, words[0..count]),
    };
}

fn iconString(arena: Allocator, info: *c.GAppInfo) Allocator.Error![]const u8 {
    const icon = c.g_app_info_get_icon(info) orelse return "";
    const text = c.g_icon_to_string(icon) orelse return "";
    defer c.g_free(text);
    return arena.dupe(u8, std.mem.span(text));
}

fn iconOf(_: *anyopaque, arena: Allocator, record: store_mod.Record) list.Icon {
    if (record.icon.len == 0) return .{ .name = fallback_icon };

    const text = arena.dupeZ(u8, record.icon) catch return .{ .name = fallback_icon };
    const icon = c.g_icon_new_for_string(text.ptr, null) orelse return .{ .name = fallback_icon };
    return .{ .gicon = icon };
}

fn collectKeywords(desktop: *c.GDesktopAppInfo, out: *[max_keywords][]const u8) usize {
    const found = c.g_desktop_app_info_get_keywords(desktop) orelse return 0;

    var count: usize = 0;
    while (count < out.len) : (count += 1) {
        const word = found[count] orelse break;
        out[count] = std.mem.span(word);
    }
    return count;
}

fn haystackOf(
    arena: Allocator,
    name: []const u8,
    generic: []const u8,
    description: []const u8,
    words: []const []const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    try append(arena, &out, name);
    try append(arena, &out, generic);
    try append(arena, &out, description);
    for (words) |word| try append(arena, &out, word);

    return out.toOwnedSlice(arena);
}

fn append(arena: Allocator, out: *std.ArrayList(u8), part: []const u8) Allocator.Error!void {
    if (part.len == 0) return;
    if (out.items.len > 0) try out.append(arena, ' ');
    try out.appendSlice(arena, part);
}

fn span(text: ?[*:0]const u8) []const u8 {
    return std.mem.span(text orelse return "");
}

fn run(context: *anyopaque, gpa: Allocator, text: []const u8) subroutines.Error!subroutines.Output {
    const self: *Index = @ptrCast(@alignCast(context));

    const query = std.mem.trim(u8, text, " \t");
    if (query.len == 0) return .nothing;

    const of = self.source.snapshot();
    if (of.entries.len == 0) return .nothing;

    const weights = try of.weights(gpa);
    defer gpa.free(weights);

    const matches = try rank.rank(gpa, of.haystacks, weights, query);
    defer gpa.free(matches);
    if (matches.len == 0) return .nothing;

    of.noteShown(matches);

    const shown = matches[0..@min(matches.len, max_rows)];
    const hits = try gpa.alloc(subroutines.Hit, shown.len);
    for (shown, 0..) |match, at| {
        const entry = of.entries[match.index];
        hits[at] = .{
            .row = .{
                .id = match.index,
                .icon = entry.icon,
                .title = entry.title,
                .detail = entry.detail,
                .program = entry.program,
            },
            .score = match.score,
        };
    }

    return .{ .hits = hits };
}

fn choose(context: *anyopaque, _: Allocator, id: u64) subroutines.Outcome {
    const self: *Index = @ptrCast(@alignCast(context));

    const of = self.source.snapshot();
    const index: usize = @intCast(id);
    if (index >= of.entries.len) return .keep;

    const entry = of.entries[index];
    const key = self.gpa.dupeZ(u8, entry.key) catch return .keep;
    defer self.gpa.free(key);

    const info = c.g_desktop_app_info_new(key.ptr) orelse {
        log.warn("{s} is no longer installed", .{entry.title});
        return .keep;
    };
    defer c.g_object_unref(info);

    if (!launch.desktop(info)) return .keep;

    of.noteChosen(index);
    return .close;
}

fn actions(
    context: *anyopaque,
    arena: Allocator,
    id: u64,
) subroutines.Error![]const subroutines.Action {
    const self: *Index = @ptrCast(@alignCast(context));

    const info = (infoOf(self, arena, id) catch return &.{}) orelse return &.{};
    defer c.g_object_unref(info);

    const keys = keyFileOf(info);
    defer if (keys) |file| c.g_key_file_free(file);

    var found: std.ArrayList(subroutines.Action) = .empty;
    const names = c.g_desktop_app_info_list_actions(info);

    var at: usize = 0;
    while (names[at]) |name| : (at += 1) {
        const label = c.g_desktop_app_info_get_action_name(info, name) orelse continue;
        defer c.g_free(label);

        try found.append(arena, .{
            .id = at,
            .title = try arena.dupeZ(u8, std.mem.span(label)),
            .detail = try execOf(arena, keys, std.mem.span(name)),
        });
    }

    return found.toOwnedSlice(arena);
}

fn perform(context: *anyopaque, gpa: Allocator, id: u64, action: u64) subroutines.Outcome {
    const self: *Index = @ptrCast(@alignCast(context));

    const info = (infoOf(self, gpa, id) catch return .keep) orelse return .keep;
    defer c.g_object_unref(info);

    const names = c.g_desktop_app_info_list_actions(info);
    const at: usize = @intCast(action);

    var seen: usize = 0;
    while (names[seen]) |name| : (seen += 1) {
        if (seen != at) continue;

        launch.action(info, name);
        self.source.snapshot().noteChosen(@intCast(id));
        return .close;
    }

    return .keep;
}

fn infoOf(self: *Index, gpa: Allocator, id: u64) Allocator.Error!?*c.GDesktopAppInfo {
    const of = self.source.snapshot();
    const index: usize = @intCast(id);
    if (index >= of.entries.len) return null;

    const key = try gpa.dupeZ(u8, of.entries[index].key);
    defer gpa.free(key);

    return c.g_desktop_app_info_new(key.ptr);
}

fn keyFileOf(info: *c.GDesktopAppInfo) ?*c.GKeyFile {
    const path = c.g_desktop_app_info_get_filename(info) orelse return null;

    const file = c.g_key_file_new();
    if (c.g_key_file_load_from_file(file, path, c.key_file_none, null) != c.FALSE) return file;

    c.g_key_file_free(file);
    return null;
}

fn execOf(arena: Allocator, keys: ?*c.GKeyFile, name: []const u8) Allocator.Error![:0]const u8 {
    const file = keys orelse return "";

    const group = try std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ action_group, name }, 0);
    const value = c.g_key_file_get_string(file, group.ptr, "Exec", null) orelse return "";
    defer c.g_free(value);

    return arena.dupeZ(u8, std.mem.span(value));
}

fn release(_: *anyopaque, gpa: Allocator, output: subroutines.Output) void {
    switch (output) {
        .nothing, .marks, .answer => {},
        .hits => |hits| gpa.free(hits),
    }
}

fn stale(context: *anyopaque) bool {
    const self: *Index = @ptrCast(@alignCast(context));
    return self.source.needs_refresh;
}

fn retire(context: *anyopaque, store: ?*store_mod.Store) void {
    const self: *Index = @ptrCast(@alignCast(context));
    if (store) |found| self.source.flush(found);
    self.source.deinit();
}

const testing = std.testing;

fn loaded(text: [:0]const u8) *c.GKeyFile {
    const file = c.g_key_file_new();
    _ = c.g_key_file_load_from_data(file, text.ptr, text.len, c.key_file_none, null);
    return file;
}

test "an action's exec comes from its own group" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const file = loaded(
        \\[Desktop Entry]
        \\Name=Firefox
        \\Exec=firefox %u
        \\Actions=new-window;new-private-window;
        \\
        \\[Desktop Action new-window]
        \\Name=Open a New Window
        \\Exec=firefox --new-window %u
        \\
        \\[Desktop Action new-private-window]
        \\Name=Open a New Private Window
        \\Exec=firefox --private-window %u
    );
    defer c.g_key_file_free(file);

    try testing.expectEqualStrings(
        "firefox --new-window %u",
        try execOf(arena.allocator(), file, "new-window"),
    );
    try testing.expectEqualStrings(
        "firefox --private-window %u",
        try execOf(arena.allocator(), file, "new-private-window"),
    );
}

test "an action without an exec or a file leaves the detail empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const file = loaded(
        \\[Desktop Entry]
        \\Name=Ark
        \\
        \\[Desktop Action extract]
        \\Name=Extract
    );
    defer c.g_key_file_free(file);

    try testing.expectEqualStrings("", try execOf(arena.allocator(), file, "extract"));
    try testing.expectEqualStrings("", try execOf(arena.allocator(), file, "missing"));
    try testing.expectEqualStrings("", try execOf(arena.allocator(), null, "extract"));
}

test "the haystack joins every field it was given" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const built = try haystackOf(
        arena.allocator(),
        "Firefox",
        "Web Browser",
        "Browse the World Wide Web",
        &.{ "Internet", "WWW", "Browser" },
    );

    try testing.expectEqualStrings(
        "Firefox Web Browser Browse the World Wide Web Internet WWW Browser",
        built,
    );
}

test "empty fields leave no stray spaces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const built = try haystackOf(arena.allocator(), "Ark", "", "Archiving Tool", &.{});
    try testing.expectEqualStrings("Ark Archiving Tool", built);

    const bare = try haystackOf(arena.allocator(), "Xterm", "", "", &.{});
    try testing.expectEqualStrings("Xterm", bare);
}

test "a query finds an app through any of its fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const haystacks = [_][]const u8{
        try haystackOf(
            arena.allocator(),
            "Firefox",
            "Web Browser",
            "Browse the World Wide Web",
            &.{ "Internet", "Browser" },
        ),
        try haystackOf(arena.allocator(), "Ark", "", "Archiving Tool", &.{}),
    };

    for ([_][]const u8{ "fi", "web", "browser", "internet" }) |query| {
        const matches = try rank.rank(testing.allocator, &haystacks, null, query);
        defer testing.allocator.free(matches);

        try testing.expect(matches.len > 0);
        try testing.expectEqual(@as(usize, 0), matches[0].index);
    }
}
