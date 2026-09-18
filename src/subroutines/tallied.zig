const std = @import("std");
const model = @import("../model.zig");
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
};

pub fn Tallied(comptime Payload: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            key: []const u8,
            title: [:0]const u8,
            detail: [:0]const u8 = "",
            icon: model.Icon = .none,
            fields: []const []const u8,
            payload: Payload,
        };

        pub const Catalog = struct {
            arena: std.heap.ArenaAllocator,
            items: []const Item = &.{},
            ids: []const u64 = &.{},
            fields: []const []const []const u8 = &.{},
            places: std.AutoHashMapUnmanaged(u64, usize) = .empty,

            pub fn allocator(self: *Catalog) Allocator {
                return self.arena.allocator();
            }

            fn create(gpa: Allocator) Allocator.Error!*Catalog {
                const self = try gpa.create(Catalog);
                self.* = .{ .arena = .init(gpa) };
                return self;
            }

            fn destroy(self: *Catalog, gpa: Allocator) void {
                self.arena.deinit();
                gpa.destroy(self);
            }

            fn fill(self: *Catalog, items: []const Item) Allocator.Error!void {
                const arena = self.allocator();

                var kept: std.ArrayList(Item) = .empty;
                var ids: std.ArrayList(u64) = .empty;

                for (items) |item| {
                    const id = counts_mod.id(item.key);
                    const slot = try self.places.getOrPut(arena, id);
                    if (slot.found_existing) continue;

                    slot.value_ptr.* = kept.items.len;
                    try kept.append(arena, item);
                    try ids.append(arena, id);
                }

                const fields = try arena.alloc([]const []const u8, kept.items.len);
                for (kept.items, fields) |item, *slot| slot.* = item.fields;

                self.items = kept.items;
                self.ids = ids.items;
                self.fields = fields;
            }
        };

        gpa: Allocator,
        io: std.Io,
        table: []const u8,
        published: ?source_mod.Published,
        path: ?[:0]const u8 = null,
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
            self.path = found.path;

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
            catalog.fill(items) catch |err| {
                catalog.destroy(self.gpa);
                return source_mod.report(self.table, "publish", err);
            };

            self.persist(catalog);

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
        }

        fn persist(self: *Self, catalog: *Catalog) void {
            const file = self.path orelse return;
            prune(self.gpa, catalog, file, self.table) catch |err| {
                source_mod.report(self.table, "write", err);
            };
        }

        pub fn hits(
            self: *Self,
            owner: *subroutines.Owner,
            text: []const u8,
            options: Options,
        ) subroutines.Error!subroutines.Output {
            const query = std.mem.trim(u8, text, " \t");
            if (query.len == 0) return .nothing;

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const of = self.current;
            if (of.items.len == 0) return .nothing;

            const scratch = owner.allocator();
            const weights = try scratch.alloc(rank.Weight, of.items.len);
            self.counts.fill(of.ids, weights);

            const matches = try rank.rankFields(scratch, of.fields, weights, query);
            if (matches.len == 0) return .nothing;

            const seen = try scratch.alloc(u64, matches.len);
            for (matches, seen) |match, *slot| slot.* = of.ids[match.index];
            self.counts.noteAll(seen, .{ .shown = 1 });

            const shown = matches[0..@min(matches.len, options.max_rows)];
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

        pub fn retire(self: *Self, store: ?*store_mod.Store) void {
            self.counts.flush(store);

            self.counts.deinit();
            self.current.destroy(self.gpa);
            for (self.retired.items) |old| old.destroy(self.gpa);
            self.retired.deinit(self.gpa);
        }

        fn prune(gpa: Allocator, catalog: *Catalog, file: [:0]const u8, table: []const u8) !void {
            const conn = try store_mod.connect(file, .{});
            defer conn.close();

            try counts_mod.keep(gpa, conn, table, catalog.ids);
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
                    },
                    .score = match.score,
                };
            }
            return built;
        }
    };
}

const testing = std.testing;

const Words = Tallied(u8);

const Setup = struct {
    tmp: testing.TmpDir,
    store: *store_mod.Store,
    words: Words,

    fn init() !Setup {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &buffer,
            ".zig-cache/tmp/{s}/sysdeck.db",
            .{tmp.sub_path},
        );

        const store = try store_mod.Store.open(testing.allocator, testing.io, path);
        errdefer store.close();

        var words: Words = try .init(testing.allocator, testing.io, "words", null);
        words.prepare(store);

        return .{ .tmp = tmp, .store = store, .words = words };
    }

    fn deinit(setup: *Setup) void {
        setup.words.retire(setup.store);
        setup.store.close();
        setup.tmp.cleanup();
    }

    fn publish(setup: *Setup, keys: []const []const u8) !void {
        const catalog = try setup.words.begin();
        const arena = catalog.allocator();

        const items = try arena.alloc(Words.Item, keys.len);
        for (keys, items, 0..) |key, *item, at| {
            item.* = .{
                .key = key,
                .title = try arena.dupeZ(u8, key),
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
    setup.words.counts.flush(setup.store);

    try setup.publish(&.{ "beta", "delta" });

    const stored = try setup.counts(arena.allocator());
    try testing.expectEqual(@as(usize, 1), stored.count());
    try testing.expectEqual(@as(?rank.Weight, null), stored.get(counts_mod.id("alpha")));
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
    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("webmail", found.hits[0].row.title);
    try testing.expectEqual(counts_mod.id("webmail"), found.hits[0].row.id);
    try testing.expectEqualStrings("detail", found.hits[0].row.detail);

    try testing.expectEqual(@as(u32, 1), setup.words.counts.added.get(counts_mod.id("web")).?.shown);

    const capped = try setup.words.hits(owner, "web", .{ .max_rows = 1 });
    try testing.expectEqual(@as(usize, 1), capped.hits.len);
}

test "an item is found through any of its fields" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire(null);

    const hand = [_][]const u8{ "raised hand", "five", "high" };
    const monkey = [_][]const u8{ "see-no-evil monkey", "hide" };
    const items = [_]Words.Item{
        .{ .key = "hand", .title = "hand", .fields = &hand, .payload = 0 },
        .{ .key = "monkey", .title = "monkey", .fields = &monkey, .payload = 1 },
    };
    words.publish(try words.begin(), &items);

    const found = try words.hits(owner, "high five", .{ .max_rows = 10 });

    try testing.expectEqual(@as(usize, 1), found.hits.len);
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

    try testing.expectEqual(@as(usize, 1), found.hits.len);
    try testing.expectEqualStrings("gamma", found.hits[0].row.title);
    try testing.expectEqual(@as(u32, 0), setup.words.counts.added.get(counts_mod.id("gamma")).?.shown);
}

test "an item is found by its id and an unknown id finds nothing" {
    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "alpha", "beta" });

    const found = setup.words.find(counts_mod.id("beta")).?;
    try testing.expectEqualStrings("beta", found.key);
    try testing.expectEqual(@as(u8, 1), found.payload);
    try testing.expectEqual(@as(?Words.Item, null), setup.words.find(counts_mod.id("omega")));
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
    setup.words.counts.flush(setup.store);

    const stored = try setup.counts(arena.allocator());
    try testing.expectEqual(rank.Weight{ .shown = 1, .chosen = 1 }, stored.get(counts_mod.id("beta")).?);
    try testing.expectEqual(@as(?rank.Weight, null), stored.get(counts_mod.id("alpha")));
}

test "a second item with the same key is dropped" {
    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "alpha", "alpha", "beta" });

    try testing.expectEqual(@as(usize, 2), setup.words.current.items.len);
    try testing.expectEqual(@as(u8, 0), setup.words.find(counts_mod.id("alpha")).?.payload);
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
    try testing.expectEqual(@as(?Words.Item, null), setup.words.find(counts_mod.id("alpha")));
}

test "without a store the items are listed and nothing is counted" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire(null);

    const items = [_]Words.Item{
        .{ .key = "alpha", .title = "alpha", .fields = &.{"alpha"}, .payload = 0 },
    };
    words.publish(try words.begin(), &items);

    const found = try words.hits(owner, "alpha", .{ .max_rows = 10 });

    try testing.expectEqual(@as(usize, 1), found.hits.len);

    words.counts.flush(null);
    try testing.expectEqual(@as(u32, 1), words.counts.weight(counts_mod.id("alpha")).shown);
}

test "an item's own icon wins over the icon of the source" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", null);
    defer words.retire(null);

    const glyph: model.Icon = .{ .glyph = "🙌" };
    const items = [_]Words.Item{
        .{ .key = "alpha", .title = "alpha", .icon = glyph, .fields = &.{"alpha"}, .payload = 0 },
        .{ .key = "alps", .title = "alps", .fields = &.{"alps"}, .payload = 1 },
    };
    words.publish(try words.begin(), &items);
    for (0..2) |_| words.note(counts_mod.id("alpha"));

    const source: model.Icon = .{ .name = "edit-cut" };

    const found = try words.hits(owner, "alp", .{ .max_rows = 10, .icon = source });

    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("alpha", found.hits[0].row.title);
    try testing.expectEqualStrings("🙌", found.hits[0].row.icon.glyph);
    try testing.expectEqualStrings("edit-cut", found.hits[1].row.icon.name);

    const picked = try words.picks(owner, 5, source);

    try testing.expectEqual(@as(usize, 1), picked.hits.len);
    try testing.expectEqualStrings("🙌", picked.hits[0].row.icon.glyph);
}

fn gathered(gpa: Allocator) !void {
    const catalog = try Words.Catalog.create(gpa);
    defer catalog.destroy(gpa);

    try catalog.fill(&.{
        .{ .key = "alpha", .title = "Alpha", .fields = &.{"alpha"}, .payload = 1 },
        .{ .key = "beta", .title = "Beta", .fields = &.{ "beta", "second" }, .payload = 2 },
        .{ .key = "alpha", .title = "Repeated", .fields = &.{"alpha"}, .payload = 3 },
    });
}

test "a catalog that runs out of memory leaves nothing behind" {
    try testing.checkAllAllocationFailures(testing.allocator, gathered, .{});
}
