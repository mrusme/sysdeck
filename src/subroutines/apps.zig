const std = @import("std");
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const indexed = @import("indexed.zig");
const launch = @import("../system/launch.zig");
const model = @import("../model.zig");
const rank = @import("core").rank;
const source = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.apps);

pub const table = tables.apps;

const max_rows = 200;
const max_keywords = 32;
const fallback_icon: [:0]const u8 = "application-x-executable";
const action_group = "Desktop Action ";

pub const Index = struct {
    indexed: indexed.Indexed,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Index),
            .verb = "Open",
        };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.indexed.hits(owner, text, .{ .max_rows = max_rows });
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.indexed.picks(owner, .{ .limit = limit });
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.indexed.counters(id);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.indexed.forget(id);
    }

    pub fn stale(self: *Index) bool {
        return self.indexed.stale();
    }

    pub fn retire(self: *Index) void {
        self.indexed.retire();
    }

    pub fn refresh(self: *Index) void {
        log.debug("refreshing the index", .{});

        var arena: std.heap.ArenaAllocator = .init(self.indexed.gpa);
        defer arena.deinit();

        const scanned = scan(arena.allocator()) catch |err| {
            return source.report(table, "scan", err);
        };

        const records = self.indexed.write(arena.allocator(), scanned);
        self.indexed.republish(records, &iconOf, null);
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        return self.start(gpa, id, null);
    }

    pub fn chooseWith(self: *Index, gpa: Allocator, id: u64, arguments: []const u8) subroutines.Outcome {
        return self.start(gpa, id, arguments);
    }

    fn start(self: *Index, gpa: Allocator, id: u64, arguments: ?[]const u8) subroutines.Outcome {
        const of = self.indexed.source.snapshot();
        const index = of.find(id) orelse return .keep;

        const info = (infoOf(gpa, of, index) catch return .keep) orelse {
            log.warn("{s} is no longer installed", .{of.entries[index].title});
            return .keep;
        };
        defer glib.g_object_unref(info);

        const started = if (arguments) |text| launch.desktopWith(gpa, info, text) else launch.desktop(info);
        if (!started) return .keep;

        self.indexed.noteChosen(id);
        return .close;
    }

    pub fn actions(
        self: *Index,
        arena: Allocator,
        id: u64,
    ) subroutines.Error![]const subroutines.Action {
        const of = self.indexed.source.snapshot();
        const index = of.find(id) orelse return &.{};

        const info = (infoOf(arena, of, index) catch return &.{}) orelse return &.{};
        defer glib.g_object_unref(info);

        const keys = launch.keyFileOf(info);
        defer if (keys) |file| glib.g_key_file_free(file);

        var found: std.ArrayList(subroutines.Action) = .empty;
        const names = gio.g_desktop_app_info_list_actions(info);

        var at: usize = 0;
        while (names[at]) |name| : (at += 1) {
            const label = gio.g_desktop_app_info_get_action_name(info, name) orelse continue;
            defer glib.g_free(label);

            try found.append(arena, .{
                .id = at,
                .title = try arena.dupeSentinel(u8, std.mem.span(label), 0),
                .detail = try execOf(arena, keys, std.mem.span(name)),
            });
        }

        return found.toOwnedSlice(arena);
    }

    pub fn perform(self: *Index, gpa: Allocator, id: u64, action: u64) subroutines.Outcome {
        const of = self.indexed.source.snapshot();
        const index = of.find(id) orelse return .keep;

        const info = (infoOf(gpa, of, index) catch return .keep) orelse return .keep;
        defer glib.g_object_unref(info);

        const names = gio.g_desktop_app_info_list_actions(info);
        const at: usize = @intCast(action);

        var seen: usize = 0;
        while (names[seen]) |name| : (seen += 1) {
            if (seen != at) continue;

            launch.action(info, name);
            self.indexed.noteChosen(id);
            return .close;
        }

        return .keep;
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("apps")) return null;

    var self: Index = .{
        .indexed = try .init(context.gpa, context.io, table, context.stamp, context.published),
    };
    errdefer self.indexed.retire();

    const found = self.indexed.prepare(context.store) orelse return self;
    self.indexed.source.needs_refresh = store_mod.stale(
        found.updatedAt(table),
        context.stamp,
        context.age(context.settings.sources.apps.max_age_minutes),
    );

    var arena: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena.deinit();

    const records = self.indexed.stored(found, arena.allocator()) orelse return self;
    if (records.len == 0) return self;

    try self.indexed.adopt(records, &iconOf, null);
    return self;
}

pub fn scan(arena: Allocator) Allocator.Error![]store_mod.Record {
    var records: std.ArrayList(store_mod.Record) = .empty;

    const all = gio.g_app_info_get_all() orelse return records.toOwnedSlice(arena);
    defer glib.g_list_free_full(all, @ptrCast(&glib.g_object_unref));

    var node: ?*c.GList = all;
    while (node) |current| : (node = current.next) {
        const info: *c.GAppInfo = @ptrCast(current.data orelse continue);
        if (gio.g_app_info_should_show(info) == c.FALSE) continue;

        const id = span(gio.g_app_info_get_id(info));
        if (id.len == 0) continue;

        const name = span(gio.g_app_info_get_display_name(info) orelse gio.g_app_info_get_name(info));
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
    const desktop = c.cast(c.GDesktopAppInfo, info);
    const generic = span(gio.g_desktop_app_info_get_generic_name(desktop));
    const description = span(gio.g_app_info_get_description(info));

    var words: [max_keywords][]const u8 = undefined;
    const count = collectKeywords(desktop, &words);

    return .{
        .key = try arena.dupe(u8, id),
        .title = try arena.dupe(u8, name),
        .detail = try arena.dupe(u8, if (description.len > 0) description else generic),
        .icon = try iconString(arena, info),
        .program = try arena.dupe(u8, span(gio.g_app_info_get_executable(info))),
        .haystack = try haystackOf(arena, name, generic, description, words[0..count]),
    };
}

fn iconString(arena: Allocator, info: *c.GAppInfo) Allocator.Error![]const u8 {
    const icon = gio.g_app_info_get_icon(info) orelse return "";
    const text = gio.g_icon_to_string(icon) orelse return "";
    defer glib.g_free(text);
    return arena.dupe(u8, std.mem.span(text));
}

fn iconOf(_: ?*anyopaque, arena: Allocator, record: store_mod.Record) model.Icon {
    if (record.icon.len == 0) return .{ .name = fallback_icon };

    const text = arena.dupeSentinel(u8, record.icon, 0) catch return .{ .name = fallback_icon };
    const icon = gio.g_icon_new_for_string(text.ptr, null) orelse return .{ .name = fallback_icon };
    return .{ .gicon = icon };
}

fn collectKeywords(desktop: *c.GDesktopAppInfo, out: *[max_keywords][]const u8) usize {
    const found = gio.g_desktop_app_info_get_keywords(desktop) orelse return 0;

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

fn infoOf(
    gpa: Allocator,
    of: *source.Snapshot,
    index: usize,
) Allocator.Error!?*c.GDesktopAppInfo {
    const key = try gpa.dupeSentinel(u8, of.entries[index].key, 0);
    defer gpa.free(key);

    return gio.g_desktop_app_info_new(key.ptr);
}

fn execOf(arena: Allocator, keys: ?*c.GKeyFile, name: []const u8) Allocator.Error![:0]const u8 {
    const file = keys orelse return "";

    const group = try arena.printSentinel("{s}{s}", .{ action_group, name }, 0);
    const value = glib.g_key_file_get_string(file, group.ptr, "Exec", null) orelse return "";
    defer glib.g_free(value);

    return arena.dupeSentinel(u8, std.mem.span(value), 0);
}

const testing = std.testing;

fn loaded(text: [:0]const u8) *c.GKeyFile {
    const file = glib.g_key_file_new();
    _ = glib.g_key_file_load_from_data(file, text.ptr, text.len, c.key_file_none, null);
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
    defer glib.g_key_file_free(file);

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
    defer glib.g_key_file_free(file);

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
