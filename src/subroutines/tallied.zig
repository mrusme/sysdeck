const std = @import("std");
const c = @import("../gtk/c.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const model = @import("../model.zig");
const fold = @import("core").fold;
const rank = @import("core").rank;
const source_mod = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const counts_mod = @import("core").counts;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.tallied);

pub const Options = struct {
    max_rows: usize,
    icon: model.Icon = .none,
    counted: bool = true,
    extra: bool = false,
    idle: Idle = .nothing,
};

pub const Idle = enum { nothing, chosen };

pub fn Tallied(comptime Payload: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            key: []const u8,
            title: [:0]const u8,
            detail: [:0]const u8 = "",
            icon: model.Icon = .none,
            verb: [:0]const u8 = "",
            badges: []const model.Badge = &.{},
            fields: []const []const u8,
            extra: []const []const u8 = &.{},
            payload: Payload,
        };

        pub const Catalog = struct {
            owner: subroutines.Owner,
            items: []const Item = &.{},
            ids: []const u64 = &.{},
            fields: []const []const fold.Folded = &.{},
            wide: []const []const fold.Folded = &.{},
            places: std.AutoHashMapUnmanaged(u64, usize) = .empty,

            fn create(gpa: Allocator) Allocator.Error!*Catalog {
                const self = try gpa.create(Catalog);
                self.* = .{ .owner = .init(gpa) };
                return self;
            }

            fn destroy(self: *Catalog, gpa: Allocator) void {
                self.owner.deinit();
                gpa.destroy(self);
            }

            fn fill(self: *Catalog, source: []const u8, items: []const Item) Allocator.Error!void {
                const arena = self.owner.allocator();

                var kept: std.ArrayList(Item) = .empty;
                var ids: std.ArrayList(u64) = .empty;

                for (items) |item| {
                    const id = counts_mod.id(item.key);
                    const slot = try self.places.getOrPut(arena, id);
                    if (slot.found_existing) {
                        log.warn("the {s} entry \"{s}\" is listed twice, so the second one is left out", .{
                            source,
                            item.key,
                        });
                        continue;
                    }

                    slot.value_ptr.* = kept.items.len;
                    try kept.append(arena, item);
                    try ids.append(arena, id);
                }

                const fields = try arena.alloc([]const fold.Folded, kept.items.len);
                const wide = try arena.alloc([]const fold.Folded, kept.items.len);
                for (kept.items, fields, wide) |item, *narrow, *broad| {
                    const all = try arena.alloc(fold.Folded, item.fields.len + item.extra.len);
                    for (item.fields, all[0..item.fields.len]) |field, *slot| slot.* = try fold.fold(arena, field);
                    for (item.extra, all[item.fields.len..]) |field, *slot| slot.* = try fold.fold(arena, field);

                    narrow.* = all[0..item.fields.len];
                    broad.* = all;
                }

                self.items = kept.items;
                self.ids = ids.items;
                self.fields = fields;
                self.wide = wide;
            }
        };

        gpa: Allocator,
        io: std.Io,
        table: []const u8,
        published: ?source_mod.Published,
        mutex: std.Io.Mutex = .init,
        current: *Catalog,
        retired: std.ArrayList(*Catalog) = .empty,
        counts: counts_mod.Counts,

        pub fn init(
            gpa: Allocator,
            io: std.Io,
            table: []const u8,
            published: ?source_mod.Published,
        ) Allocator.Error!Self {
            return .{
                .gpa = gpa,
                .io = io,
                .table = table,
                .published = published,
                .counts = .{ .gpa = gpa, .io = io, .source = table },
                .current = try Catalog.create(gpa),
            };
        }

        pub fn prepare(self: *Self, store: ?*store_mod.Store) void {
            const found = store orelse return;
            self.counts.store = found;

            counts_mod.read(self.gpa, found.conn, self.table, &self.counts.loaded) catch |err| {
                source_mod.report(self.table, "read the counters of", err);
            };
        }

        pub fn begin(self: *Self) Allocator.Error!*Catalog {
            return Catalog.create(self.gpa);
        }

        pub fn discard(self: *Self, catalog: *Catalog) void {
            catalog.destroy(self.gpa);
        }

        pub fn publish(self: *Self, catalog: *Catalog, items: []const Item) void {
            catalog.fill(self.table, items) catch |err| {
                catalog.destroy(self.gpa);
                return source_mod.report(self.table, "publish", err);
            };

            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);

                self.retired.append(self.gpa, self.current) catch |err| {
                    catalog.destroy(self.gpa);
                    return source_mod.report(self.table, "publish", err);
                };
                self.current = catalog;
            }

            if (self.published) |found| found.call(.{});

            self.counts.keep(catalog.ids) catch |err| {
                source_mod.report(self.table, "prune the counters of", err);
            };
        }

        pub fn hits(
            self: *Self,
            owner: *subroutines.Owner,
            text: []const u8,
            options: Options,
        ) subroutines.Error!subroutines.Output {
            const query = std.mem.trim(u8, text, " \t");
            if (query.len == 0 and options.idle == .nothing) return .nothing;

            const scratch = owner.allocator();
            const wanted = try fold.query(scratch, query);

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const of = self.current;
            if (of.items.len == 0) return .nothing;

            const weights = try scratch.alloc(rank.Weight, of.items.len);
            self.counts.fill(of.ids, weights);

            const matches = if (query.len == 0)
                try rank.byChosen(scratch, weights)
            else
                try rank.rankFieldsFolded(scratch, if (options.extra) of.wide else of.fields, weights, wanted);
            if (matches.len == 0) return .nothing;

            const shown = matches[0..@min(matches.len, options.max_rows)];
            if (options.counted) {
                const seen = try scratch.alloc(u64, shown.len);
                for (shown, seen) |match, *slot| slot.* = of.ids[match.index];
                self.noteShown(seen);
            }

            return .{ .hits = try rows(scratch, of, shown, options.icon) };
        }

        pub fn picks(
            self: *Self,
            owner: *subroutines.Owner,
            limit: usize,
            icon: model.Icon,
        ) subroutines.Error!subroutines.Output {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const of = self.current;
            if (of.items.len == 0) return .nothing;

            const scratch = owner.allocator();
            const weights = try scratch.alloc(rank.Weight, of.items.len);
            self.counts.fill(of.ids, weights);

            const found = try rank.picks(scratch, weights, limit);
            if (found.len == 0) return .nothing;

            return .{ .hits = try rows(scratch, of, found, icon) };
        }

        pub fn find(self: *Self, id: u64) ?Item {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const at = self.current.places.get(id) orelse return null;
            return self.current.items[at];
        }

        pub fn note(self: *Self, id: u64) void {
            self.counts.note(id, .{ .chosen = 1 });
        }

        pub fn counters(self: *Self, id: u64) ?rank.Weight {
            _ = self.find(id) orelse return null;
            return self.counts.weight(id);
        }

        pub fn forget(self: *Self, id: u64) void {
            self.counts.forget(&.{id});
        }

        pub fn noteShown(self: *Self, ids: []const u64) void {
            self.counts.noteAll(ids, .{ .shown = 1 });
        }

        pub fn retire(self: *Self) void {
            self.counts.flush();

            self.counts.deinit();
            self.current.destroy(self.gpa);
            for (self.retired.items) |old| old.destroy(self.gpa);
            self.retired.deinit(self.gpa);
        }

        fn rows(
            arena: Allocator,
            of: *const Catalog,
            matches: []const rank.Match,
            icon: model.Icon,
        ) Allocator.Error![]subroutines.Hit {
            const built = try arena.alloc(subroutines.Hit, matches.len);
            for (matches, built) |match, *hit| {
                const item = of.items[match.index];
                hit.* = .{
                    .row = .{
                        .id = of.ids[match.index],
                        .icon = if (item.icon == .none) icon else item.icon,
                        .title = item.title,
                        .detail = item.detail,
                        .verb = item.verb,
                        .badges = item.badges,
                    },
                    .score = match.score,
                };
            }
            return built;
        }
    };
}

const testing = std.testing;
const tmpPath = @import("core").xdg.tmpPath;

const Words = Tallied(u8);

const Setup = struct {
    tmp: testing.TmpDir,
    store: *store_mod.Store,
    words: Words,

    fn init() !Setup {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try tmpPath(&tmp, &buffer, "sysdeck.db");

        const store = try store_mod.Store.open(testing.allocator, testing.io, path);
        errdefer store.close();

        var words: Words = try .init(testing.allocator, testing.io, "words", null);
        words.prepare(store);

        return .{ .tmp = tmp, .store = store, .words = words };
    }

    fn deinit(setup: *Setup) void {
        setup.words.retire();
        setup.store.close();
        setup.tmp.cleanup();
    }

    fn publish(setup: *Setup, keys: []const []const u8) !void {
        const catalog = try setup.words.begin();
        const arena = catalog.owner.allocator();

        const items = try arena.alloc(Words.Item, keys.len);
        for (keys, items, 0..) |key, *item, at| {
            item.* = .{
                .key = key,
                .title = try arena.dupeSentinel(u8, key, 0),
                .detail = "detail",
                .fields = try arena.dupe([]const u8, &.{key}),
                .payload = @intCast(at),
            };
        }
        setup.words.publish(catalog, items);
    }

    fn counts(setup: *Setup, arena: Allocator) !std.AutoHashMapUnmanaged(u64, rank.Weight) {
        var found: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty;
        try counts_mod.read(arena, setup.store.conn, "words", &found);
        return found;
    }
};

test "a publish drops the counters of the keys that are gone" {
    var setup: Setup = try .init();
    defer setup.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try setup.publish(&.{ "alpha", "beta", "gamma" });

    setup.words.note(counts_mod.id("alpha"));
    setup.words.note(counts_mod.id("beta"));
    setup.words.counts.flush();

    try setup.publish(&.{ "beta", "delta" });

    const stored = try setup.counts(arena.allocator());
    try testing.expectEqual(1, stored.count());
    try testing.expectEqual(null, stored.get(counts_mod.id("alpha")));
    try testing.expectEqual(rank.Weight{ .chosen = 1 }, stored.get(counts_mod.id("beta")).?);
}

test "hits are ranked by what was chosen and counted as shown" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "web", "webmail" });
    setup.words.counts.note(counts_mod.id("webmail"), .{ .chosen = 40 });
    try setup.publish(&.{ "web", "webmail" });

    const found = try setup.words.hits(owner, "web", .{ .max_rows = 10 });
    try testing.expectEqual(2, found.hits.len);
    try testing.expectEqualStrings("webmail", found.hits[0].row.title);
    try testing.expectEqual(counts_mod.id("webmail"), found.hits[0].row.id);
    try testing.expectEqualStrings("detail", found.hits[0].row.detail);

    try testing.expectEqual(1, setup.words.counts.added.get(counts_mod.id("web")).?.shown);

    const capped = try setup.words.hits(owner, "web", .{ .max_rows = 1 });
    try testing.expectEqual(1, capped.hits.len);
}

test "of 300 matches only the listed rows are counted as shown" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire();

    const catalog = try words.begin();
    const arena = catalog.owner.allocator();

    const items = try arena.alloc(Words.Item, 300);
    for (items, 0..) |*item, at| {
        const key = try arena.print("word {d}", .{at});
        item.* = .{
            .key = key,
            .title = try arena.dupeSentinel(u8, key, 0),
            .fields = try arena.dupe([]const u8, &.{key}),
            .payload = 0,
        };
    }
    words.publish(catalog, items);

    for ([_][]const u8{ "word", "" }) |text| {
        const found = try words.hits(owner, text, .{ .max_rows = 200, .idle = .chosen });
        try testing.expectEqual(200, found.hits.len);
    }

    var shown: usize = 0;
    for (items) |item| shown += words.counts.weight(counts_mod.id(item.key)).shown;
    try testing.expectEqual(400, shown);
}

test "an item is found through any of its fields" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire();

    const hand = [_][]const u8{ "raised hand", "five", "high" };
    const monkey = [_][]const u8{ "see-no-evil monkey", "hide" };
    const items = [_]Words.Item{
        .{ .key = "hand", .title = "hand", .fields = &hand, .payload = 0 },
        .{ .key = "monkey", .title = "monkey", .fields = &monkey, .payload = 1 },
    };
    words.publish(try words.begin(), &items);

    const found = try words.hits(owner, "high five", .{ .max_rows = 10 });

    try testing.expectEqual(1, found.hits.len);
    try testing.expectEqualStrings("hand", found.hits[0].row.title);
}

test "a blank query and an empty catalog give nothing" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var setup: Setup = try .init();
    defer setup.deinit();

    const nothing = subroutines.Output.nothing;
    try testing.expectEqual(nothing, try setup.words.hits(owner, "web", .{ .max_rows = 10 }));

    try setup.publish(&.{"web"});
    try testing.expectEqual(nothing, try setup.words.hits(owner, "  ", .{ .max_rows = 10 }));
}

test "an idle query can list every item, the most chosen first" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "alpha", "beta", "gamma", "delta" });
    setup.words.note(counts_mod.id("gamma"));
    setup.words.note(counts_mod.id("gamma"));
    setup.words.note(counts_mod.id("beta"));
    setup.words.counts.note(counts_mod.id("delta"), .{ .shown = 40 });

    const found = try setup.words.hits(owner, " ", .{ .max_rows = 10, .idle = .chosen, .counted = false });
    try testing.expectEqual(4, found.hits.len);
    for ([_][]const u8{ "gamma", "beta", "alpha", "delta" }, found.hits) |title, hit| {
        try testing.expectEqualStrings(title, hit.row.title);
    }
    try testing.expectEqual(null, setup.words.counts.added.get(counts_mod.id("alpha")));

    const capped = try setup.words.hits(owner, "", .{ .max_rows = 2, .idle = .chosen });
    try testing.expectEqual(2, capped.hits.len);
    try testing.expectEqualStrings("beta", capped.hits[1].row.title);
}

test "extra fields are matched only when a query asks for them" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire();

    const items = [_]Words.Item{
        .{ .key = "tom", .title = "Tom Ato", .fields = &.{"Tom Ato"}, .extra = &.{"+1-555-0101"}, .payload = 0 },
        .{ .key = "max", .title = "Max", .fields = &.{"Max"}, .payload = 1 },
    };
    words.publish(try words.begin(), &items);

    try testing.expectEqual(subroutines.Output.nothing, try words.hits(owner, "0101", .{ .max_rows = 10 }));

    const numbered = try words.hits(owner, "0101", .{ .max_rows = 10, .extra = true });
    try testing.expectEqual(1, numbered.hits.len);
    try testing.expectEqualStrings("Tom Ato", numbered.hits[0].row.title);

    const named = try words.hits(owner, "tom 555", .{ .max_rows = 10, .extra = true });
    try testing.expectEqual(1, named.hits.len);
    try testing.expectEqualStrings("Max", (try words.hits(owner, "max", .{ .max_rows = 10, .extra = true })).hits[0].row.title);
}

test "the picks are the items chosen twice and nothing is counted as shown" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "alpha", "beta", "gamma" });
    setup.words.note(counts_mod.id("alpha"));
    setup.words.note(counts_mod.id("gamma"));
    setup.words.note(counts_mod.id("gamma"));

    const found = try setup.words.picks(owner, 5, .none);

    try testing.expectEqual(1, found.hits.len);
    try testing.expectEqualStrings("gamma", found.hits[0].row.title);
    try testing.expectEqual(0, setup.words.counts.added.get(counts_mod.id("gamma")).?.shown);
}

test "an item is found by its id and an unknown id finds nothing" {
    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "alpha", "beta" });

    const found = setup.words.find(counts_mod.id("beta")).?;
    try testing.expectEqualStrings("beta", found.key);
    try testing.expectEqual(1, found.payload);
    try testing.expectEqual(null, setup.words.find(counts_mod.id("omega")));
}

test "a pick is written to the table when the counts are flushed" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var setup: Setup = try .init();
    defer setup.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try setup.publish(&.{ "alpha", "beta" });

    setup.words.note(counts_mod.id("beta"));
    _ = try setup.words.hits(owner, "beta", .{ .max_rows = 10 });
    setup.words.counts.flush();

    const stored = try setup.counts(arena.allocator());
    try testing.expectEqual(rank.Weight{ .shown = 1, .chosen = 1 }, stored.get(counts_mod.id("beta")).?);
    try testing.expectEqual(null, stored.get(counts_mod.id("alpha")));
}

test "an item's counters are read and forgotten, also in the table" {
    var setup: Setup = try .init();
    defer setup.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try setup.publish(&.{ "alpha", "beta" });
    setup.words.note(counts_mod.id("alpha"));
    setup.words.note(counts_mod.id("beta"));
    setup.words.counts.flush();
    setup.words.note(counts_mod.id("alpha"));

    try testing.expectEqual(rank.Weight{ .chosen = 2 }, setup.words.counters(counts_mod.id("alpha")).?);
    try testing.expectEqual(null, setup.words.counters(counts_mod.id("gone")));

    setup.words.forget(counts_mod.id("alpha"));
    try testing.expectEqual(rank.Weight{}, setup.words.counters(counts_mod.id("alpha")).?);

    const stored = try setup.counts(arena.allocator());
    try testing.expectEqual(null, stored.get(counts_mod.id("alpha")));
    try testing.expectEqual(rank.Weight{ .chosen = 1 }, stored.get(counts_mod.id("beta")).?);
}

test "a second item with the same key is dropped" {
    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "alpha", "alpha", "beta" });

    try testing.expectEqual(2, setup.words.current.items.len);
    try testing.expectEqual(0, setup.words.find(counts_mod.id("alpha")).?.payload);
}

test "rows from a replaced catalog stay readable until the source retires" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{"alpha"});

    const found = try setup.words.hits(owner, "alpha", .{ .max_rows = 10 });

    try setup.publish(&.{"beta"});

    try testing.expectEqualStrings("alpha", found.hits[0].row.title);
    try testing.expectEqual(null, setup.words.find(counts_mod.id("alpha")));
}

test "without a store the items are listed and nothing is counted" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire();

    const items = [_]Words.Item{
        .{ .key = "alpha", .title = "alpha", .fields = &.{"alpha"}, .payload = 0 },
    };
    words.publish(try words.begin(), &items);

    const found = try words.hits(owner, "alpha", .{ .max_rows = 10 });

    try testing.expectEqual(1, found.hits.len);

    words.counts.flush();
    try testing.expectEqual(1, words.counts.weight(counts_mod.id("alpha")).shown);
}

test "an item's own icon wins over the icon of the source" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire();

    const glyph: model.Icon = .{ .glyph = "🙌" };
    const items = [_]Words.Item{
        .{ .key = "alpha", .title = "alpha", .icon = glyph, .fields = &.{"alpha"}, .payload = 0 },
        .{ .key = "alps", .title = "alps", .fields = &.{"alps"}, .payload = 1 },
    };
    words.publish(try words.begin(), &items);
    for (0..2) |_| words.note(counts_mod.id("alpha"));

    const source: model.Icon = .{ .name = "edit-cut" };

    const found = try words.hits(owner, "alp", .{ .max_rows = 10, .icon = source });

    try testing.expectEqual(2, found.hits.len);
    try testing.expectEqualStrings("alpha", found.hits[0].row.title);
    try testing.expectEqualStrings("🙌", found.hits[0].row.icon.glyph);
    try testing.expectEqualStrings("edit-cut", found.hits[1].row.icon.name);

    const picked = try words.picks(owner, 5, source);

    try testing.expectEqual(1, picked.hits.len);
    try testing.expectEqualStrings("🙌", picked.hits[0].row.icon.glyph);
}

test "an item's verb and badges reach its row" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire();

    const running = [_]model.Badge{.{ .status = .{ .text = "running", .tone = .good } }};
    const items = [_]Words.Item{
        .{ .key = "alpha", .title = "alpha", .verb = "Stop", .badges = &running, .fields = &.{"alpha"}, .payload = 0 },
        .{ .key = "alps", .title = "alps", .fields = &.{"alps"}, .payload = 1 },
    };
    words.publish(try words.begin(), &items);
    for (0..2) |_| words.note(counts_mod.id("alpha"));

    const found = try words.hits(owner, "alp", .{ .max_rows = 10 });

    try testing.expectEqual(2, found.hits.len);
    try testing.expectEqualStrings("Stop", found.hits[0].row.verb);
    try testing.expectEqual(1, found.hits[0].row.badges.len);
    try testing.expectEqualStrings("running", found.hits[0].row.badges[0].status.text);
    try testing.expectEqual(model.Tone.good, found.hits[0].row.badges[0].status.tone);
    try testing.expectEqualStrings("", found.hits[1].row.verb);
    try testing.expectEqual(0, found.hits[1].row.badges.len);

    const picked = try words.picks(owner, 5, .none);

    try testing.expectEqual(1, picked.hits.len);
    try testing.expectEqualStrings("Stop", picked.hits[0].row.verb);
}

test "uncounted hits leave the shown count to the caller" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire();

    const items = [_]Words.Item{
        .{ .key = "alpha", .title = "alpha", .fields = &.{"alpha"}, .payload = 0 },
        .{ .key = "alps", .title = "alps", .fields = &.{"alps"}, .payload = 1 },
    };
    words.publish(try words.begin(), &items);

    const found = try words.hits(owner, "alp", .{ .max_rows = 10, .counted = false });
    try testing.expectEqual(2, found.hits.len);
    try testing.expectEqual(0, words.counts.weight(counts_mod.id("alpha")).shown);

    words.noteShown(&.{counts_mod.id("alps")});
    try testing.expectEqual(0, words.counts.weight(counts_mod.id("alpha")).shown);
    try testing.expectEqual(1, words.counts.weight(counts_mod.id("alps")).shown);
}

fn watched(alive: *?*anyopaque) *c.GIcon {
    const icon = gio.g_icon_new_for_string("image-png", null).?;
    alive.* = icon;
    glib.g_object_add_weak_pointer(c.cast(c.GObject, icon), alive);
    return icon;
}

test "a kept icon goes with its catalog, discarded or retired" {
    var words: Words = try .init(testing.allocator, testing.io, "words", null);

    var discarded: ?*anyopaque = null;
    const dropped = try words.begin();
    _ = dropped.owner.keep(watched(&discarded));
    words.discard(dropped);
    try testing.expectEqual(null, discarded);

    var published: ?*anyopaque = null;
    const catalog = try words.begin();
    const items = [_]Words.Item{.{
        .key = "alpha",
        .title = "alpha",
        .icon = catalog.owner.keep(watched(&published)),
        .fields = &.{"alpha"},
        .payload = 0,
    }};
    words.publish(catalog, &items);
    words.publish(try words.begin(), &.{});
    try testing.expect(published != null);

    words.retire();
    try testing.expectEqual(null, published);
}

fn gathered(gpa: Allocator) !void {
    const catalog = try Words.Catalog.create(gpa);
    defer catalog.destroy(gpa);

    try catalog.fill("words", &.{
        .{ .key = "alpha", .title = "Alpha", .fields = &.{"alpha"}, .payload = 1 },
        .{ .key = "beta", .title = "Beta", .fields = &.{ "beta", "second" }, .payload = 2 },
        .{ .key = "alpha", .title = "Repeated", .fields = &.{"alpha"}, .payload = 3 },
    });
}

test "a catalog that runs out of memory leaves nothing behind" {
    try testing.checkAllAllocationFailures(testing.allocator, gathered, .{});
}
