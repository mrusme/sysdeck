const std = @import("std");
const capture = @import("../clipboard/capture.zig");
const config_mod = @import("../config.zig");
const copy = @import("../system/copy.zig");
const emoji = @import("core").emoji;
const model = @import("../model.zig");
const source = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const tallied = @import("tallied.zig");
const tally = @import("core").counts;

const Allocator = std.mem.Allocator;
const Snippet = config_mod.Config.Sources.Snippets.Snippet;
const log = std.log.scoped(.snippets);

pub const table = tables.snippets;

const max_rows = 200;
const separator = ", ";

const icon_names = [_][:0]const u8{ "edit-cut", "text-x-generic" };

const Snippets = tallied.Tallied([]const emoji.Variant);

const Keywords = std.ArrayList([]const u8);

const Gathered = struct {
    name: []const u8 = "",
    keywords: Keywords = .empty,
    variants: []const emoji.Variant = &.{},
};

pub const Index = struct {
    snippets: Snippets,
    environ: *const std.process.Environ.Map,
    configured: []const Snippet,
    emoji: bool,
    icon: [:0]const u8,
    required: bool,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Index),
            .verb = "Copy",
        };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        const icon: model.Icon = .{ .name = self.icon };
        return self.snippets.hits(owner, text, .{ .max_rows = max_rows, .icon = icon });
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.snippets.picks(owner, limit, .{ .name = self.icon });
    }

    pub fn stale(_: *Index) bool {
        return true;
    }

    pub fn retire(self: *Index, store: ?*store_mod.Store) void {
        self.snippets.retire(store);
    }

    pub fn refresh(self: *Index) void {
        const catalog = self.snippets.begin() catch |err| return source.report(table, "read", err);

        const items = itemsOf(catalog.allocator(), self.configured, self.emoji) catch |err| {
            self.snippets.discard(catalog);
            return source.report(table, "read", err);
        };

        if (items.len == 0 and self.required) {
            log.warn(
                "[sources.snippets] enable is true, however emoji is false and there is " ++
                    "no [[sources.snippets.entries]] entry, so there is nothing to list",
                .{},
            );
        }

        self.snippets.publish(catalog, items);
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        const found = self.snippets.find(id) orelse return .keep;
        if (!copy.put(gpa, self.environ, .{ .bytes = found.key })) return .keep;

        self.snippets.note(id);
        return .close;
    }

    pub fn actions(
        self: *Index,
        arena: Allocator,
        id: u64,
    ) subroutines.Error![]const subroutines.Action {
        const found = self.snippets.find(id) orelse return &.{};

        const listed = try arena.alloc(subroutines.Action, found.payload.len);
        for (found.payload, listed, 0..) |variant, *action, at| {
            action.* = .{
                .id = at,
                .title = try arena.dupeZ(u8, variant.label),
                .icon = .{ .glyph = try arena.dupeZ(u8, variant.snippet) },
            };
        }
        return listed;
    }

    pub fn perform(self: *Index, gpa: Allocator, id: u64, action: u64) subroutines.Outcome {
        const variant = self.toneOf(id, action) orelse return .keep;
        if (!copy.put(gpa, self.environ, .{ .bytes = variant.snippet })) return .keep;

        self.snippets.note(id);
        return .close;
    }

    fn toneOf(self: *Index, id: u64, action: u64) ?emoji.Variant {
        const found = self.snippets.find(id) orelse return null;
        const at = std.math.cast(usize, action) orelse return null;
        if (at >= found.payload.len) return null;
        return found.payload[at];
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("snippets")) return null;

    const settings = context.settings.sources.snippets;
    var self: Index = .{
        .snippets = try .init(context.gpa, context.io, table, context.published),
        .environ = context.environ,
        .configured = settings.entries,
        .emoji = settings.emoji,
        .icon = subroutines.themedIcon(&icon_names),
        .required = context.asked("snippets"),
    };
    self.snippets.prepare(context.store);
    return self;
}

fn itemsOf(
    arena: Allocator,
    configured: []const Snippet,
    with_emoji: bool,
) Allocator.Error![]Snippets.Item {
    var gathered: std.StringArrayHashMapUnmanaged(Gathered) = .empty;

    for (configured) |one| {
        if (one.snippet.len == 0) {
            log.warn("a [[sources.snippets.entries]] entry without a snippet is left out", .{});
            continue;
        }

        const slot = try slotOf(arena, &gathered, one.snippet);
        for (one.keywords) |keyword| try add(arena, &slot.keywords, keyword);
    }

    if (with_emoji) {
        var rows = emoji.rows();
        while (rows.next()) |row| {
            const slot = try slotOf(arena, &gathered, row.snippet);
            slot.name = row.name;

            var rest = row.keywords();
            while (rest.next()) |keyword| try add(arena, &slot.keywords, keyword);

            slot.variants = try variantsOf(arena, &gathered, row);
        }
    }

    const items = try arena.alloc(Snippets.Item, gathered.count());
    for (gathered.keys(), gathered.values(), items) |text, one, *item| {
        item.* = try itemOf(arena, text, one);
    }
    return items;
}

fn variantsOf(
    arena: Allocator,
    gathered: *std.StringArrayHashMapUnmanaged(Gathered),
    row: emoji.Row,
) Allocator.Error![]const emoji.Variant {
    var found: std.ArrayList(emoji.Variant) = .empty;

    var all = row.variants();
    while (all.next()) |variant| {
        try found.append(arena, variant);

        const configured = gathered.getPtr(variant.snippet) orelse continue;
        configured.name = variant.name;

        var rest = variant.keywords();
        while (rest.next()) |keyword| try add(arena, &configured.keywords, keyword);
    }
    return found.items;
}

fn itemOf(arena: Allocator, text: []const u8, one: Gathered) Allocator.Error!Snippets.Item {
    var keywords: Keywords = .empty;
    for (one.keywords.items) |keyword| {
        if (!std.mem.eql(u8, keyword, one.name)) try keywords.append(arena, keyword);
    }

    const named = one.name.len > 0;
    const title = if (named)
        try arena.dupeZ(u8, one.name)
    else
        try arena.dupeZ(u8, try capture.previewOf(arena, text));

    const fields = try arena.alloc([]const u8, keywords.items.len + 1);
    fields[0] = title;
    @memcpy(fields[1..], keywords.items);

    return .{
        .key = text,
        .title = title,
        .detail = try std.mem.joinZ(arena, separator, keywords.items),
        .icon = if (named) .{ .glyph = try arena.dupeZ(u8, text) } else .none,
        .fields = fields,
        .payload = one.variants,
    };
}

fn slotOf(
    arena: Allocator,
    gathered: *std.StringArrayHashMapUnmanaged(Gathered),
    text: []const u8,
) Allocator.Error!*Gathered {
    const slot = try gathered.getOrPut(arena, text);
    if (!slot.found_existing) slot.value_ptr.* = .{};
    return slot.value_ptr;
}

fn add(arena: Allocator, keywords: *Keywords, keyword: []const u8) Allocator.Error!void {
    if (keyword.len == 0) return;
    for (keywords.items) |existing| {
        if (std.mem.eql(u8, existing, keyword)) return;
    }
    try keywords.append(arena, keyword);
}

const testing = std.testing;

fn glyphs(found: subroutines.Output) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    for (found.hits) |hit| {
        switch (hit.row.icon) {
            .glyph => |text| try joined.appendSlice(testing.allocator, text),
            else => continue,
        }
        try joined.append(testing.allocator, ' ');
    }
    return joined.toOwnedSlice(testing.allocator);
}

fn fill(snippets: *Snippets, configured: []const Snippet, with_emoji: bool) !void {
    const catalog = try snippets.begin();
    snippets.publish(catalog, try itemsOf(catalog.allocator(), configured, with_emoji));
}

test "configured snippets come before the emoji" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const configured = [_]Snippet{.{ .snippet = "Kind regards", .keywords = &.{"signature"} }};
    const items = try itemsOf(arena.allocator(), &configured, true);

    try testing.expectEqual(@as(usize, 1915), items.len);
    try testing.expectEqualStrings("Kind regards", items[0].key);
    try testing.expectEqualStrings("😀", items[1].key);
}

test "a text given twice is one snippet whose keywords merge without repeats" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const configured = [_]Snippet{
        .{ .snippet = "🙌", .keywords = &.{ "high ten", "praise" } },
        .{ .snippet = "🙌", .keywords = &.{ "high ten", "yay" } },
    };
    const items = try itemsOf(arena.allocator(), &configured, true);

    try testing.expectEqual(@as(usize, 1914), items.len);
    try testing.expectEqualStrings("🙌", items[0].key);
    try testing.expectEqual(@as(usize, 5), items[0].payload.len);
    try testing.expectEqualStrings(
        "high ten, praise, yay, celebration, gesture, hand, hands, hooray, raised, raising",
        items[0].detail,
    );
}

test "a multi-line snippet gets a one-line title and keeps its exact text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const text = "Kind regards,\n\n  The team\n";
    const configured = [_]Snippet{.{ .snippet = text, .keywords = &.{} }};
    const items = try itemsOf(arena.allocator(), &configured, false);

    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("Kind regards, The team", items[0].title);
    try testing.expectEqualStrings(text, items[0].key);
    try testing.expectEqualStrings("", items[0].detail);
    try testing.expectEqual(@as(usize, 1), items[0].fields.len);
}

test "an empty snippet is left out, and without emoji only the configured ones are listed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const configured = [_]Snippet{
        .{ .snippet = "", .keywords = &.{"nothing"} },
        .{ .snippet = "¯\\_(ツ)_/¯", .keywords = &.{"shrug"} },
    };
    const items = try itemsOf(arena.allocator(), &configured, false);

    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("shrug", items[0].detail);
}

test "typing high five finds the hands CLDR tags with both words" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var snippets: Snippets = try .init(testing.allocator, testing.io, table, null);
    defer snippets.retire(null);

    try fill(&snippets, &.{}, true);

    const found = try snippets.hits(owner, "high five", .{ .max_rows = max_rows });

    const joined = try glyphs(found);
    defer testing.allocator.free(joined);

    for ([_][]const u8{ "✋", "🫷", "🫸", "🙏" }) |wanted| {
        try testing.expect(std.mem.indexOf(u8, joined, wanted) != null);
    }
    try testing.expect(std.mem.indexOf(u8, joined, "🙌") == null);
    try testing.expect(std.mem.indexOf(u8, joined, "✋🏽") == null);
}

test "an emoji shows itself as the icon and its name as the title" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const items = try itemsOf(arena.allocator(), &.{}, true);
    const raising = for (items) |item| {
        if (std.mem.eql(u8, item.key, "🙌")) break item;
    } else return error.TestExpectedEqual;

    try testing.expectEqualStrings("🙌", raising.icon.glyph);
    try testing.expectEqualStrings("raising hands", raising.title);
    try testing.expectEqualStrings(
        "celebration, gesture, hand, hands, hooray, praise, raised, raising",
        raising.detail,
    );
}

test "a snippet the emoji table doesn't have keeps its text and the source icon" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const configured = [_]Snippet{
        .{ .snippet = "Kind regards", .keywords = &.{"signature"} },
        .{ .snippet = "🙌", .keywords = &.{"high ten"} },
    };

    const with_emoji = try itemsOf(arena.allocator(), &configured, true);
    try testing.expectEqual(model.Icon.none, with_emoji[0].icon);
    try testing.expectEqualStrings("Kind regards", with_emoji[0].title);
    try testing.expectEqualStrings("raising hands", with_emoji[1].title);

    const without = try itemsOf(arena.allocator(), &configured, false);
    try testing.expectEqual(model.Icon.none, without[1].icon);
    try testing.expectEqualStrings("🙌", without[1].title);
    try testing.expectEqualStrings("high ten", without[1].detail);
}

test "typing the name finds the emoji" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var snippets: Snippets = try .init(testing.allocator, testing.io, table, null);
    defer snippets.retire(null);

    try fill(&snippets, &.{}, true);

    const found = try snippets.hits(owner, "raising hands", .{ .max_rows = max_rows });

    try testing.expectEqualStrings("🙌", found.hits[0].row.icon.glyph);
    try testing.expectEqualStrings("raising hands", found.hits[0].row.title);
}

fn testIndex() !Index {
    var self: Index = .{
        .snippets = try .init(testing.allocator, testing.io, table, null),
        .environ = undefined,
        .configured = &.{},
        .emoji = true,
        .icon = icon_names[0],
        .required = false,
    };
    errdefer self.retire(null);

    const configured = [_]Snippet{
        .{ .snippet = "👍🏽", .keywords = &.{"approve"} },
        .{ .snippet = "🙌", .keywords = &.{"high ten"} },
    };
    try fill(&self.snippets, &configured, true);
    return self;
}

test "the skin tones of an emoji are its actions" {
    var self = try testIndex();
    defer self.retire(null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const waving = try self.actions(arena.allocator(), tally.id("👋"));
    try testing.expectEqual(@as(usize, 5), waving.len);
    try testing.expectEqualStrings("light skin tone", waving[0].title);
    try testing.expectEqualStrings("👋🏻", waving[0].icon.glyph);
    try testing.expectEqualStrings("dark skin tone", waving[4].title);
    try testing.expectEqualStrings("👋🏿", waving[4].icon.glyph);

    try testing.expectEqualStrings("👋🏽", self.toneOf(tally.id("👋"), 2).?.snippet);
    try testing.expectEqual(@as(?emoji.Variant, null), self.toneOf(tally.id("👋"), 5));

    const raising = try self.actions(arena.allocator(), tally.id("🙌"));
    try testing.expectEqual(@as(usize, 5), raising.len);

    const handshake = try self.actions(arena.allocator(), tally.id("🤝"));
    try testing.expectEqual(@as(usize, 25), handshake.len);
}

test "a configured skin tone is a row of its own" {
    var self = try testIndex();
    defer self.retire(null);

    const found = self.snippets.find(tally.id("👍🏽")).?;
    try testing.expectEqualStrings("thumbs up: medium skin tone", found.title);
    try testing.expectEqualStrings("👍🏽", found.icon.glyph);
    try testing.expect(std.mem.startsWith(u8, found.detail, "approve, "));
    try testing.expect(std.mem.indexOf(u8, found.detail, "thumbs up: medium skin tone") == null);
    try testing.expectEqual(@as(usize, 0), found.payload.len);

    const base = self.snippets.find(tally.id("👍")).?;
    try testing.expectEqual(@as(usize, 5), base.payload.len);
    try testing.expectEqualStrings("thumbs up", base.title);
}
