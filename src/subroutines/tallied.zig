const std = @import("std");
const list = @import("../ui/list.zig");
const rank = @import("core").rank;
const source_mod = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tally = @import("core").tally;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.tallied);

pub const Options = struct {
    max_rows: usize,
    icon: list.Icon = .none,
};

pub fn Tallied(comptime Payload: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            key: []const u8,
            title: [:0]const u8,
            detail: [:0]const u8 = "",
            icon: list.Icon = .none,
            fields: []const []const u8,
            payload: Payload,
        };

        pub const Catalog = struct {
            arena: std.heap.ArenaAllocator,
            items: []const Item = &.{},
            ids: []const u64 = &.{},
            fields: []const []const []const u8 = &.{},
            loaded: []rank.Weight = &.{},
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
                    const id = tally.id(item.key);
                    const slot = try self.places.getOrPut(arena, id);
                    if (slot.found_existing) continue;

                    slot.value_ptr.* = kept.items.len;
                    try kept.append(arena, item);
                    try ids.append(arena, id);
                }

                const fields = try arena.alloc([]const []const u8, kept.items.len);
                for (kept.items, fields) |item, *slot| slot.* = item.fields;

                const loaded = try arena.alloc(rank.Weight, kept.items.len);
                @memset(loaded, .{});

                self.items = kept.items;
                self.ids = ids.items;
                self.fields = fields;
                self.loaded = loaded;
            }
        };

        gpa: Allocator,
        io: std.Io,
        table: []const u8,
        published: source_mod.Published,
        path: ?[:0]const u8 = null,
        mutex: std.Io.Mutex = .init,
        current: *Catalog,
        retired: std.ArrayList(*Catalog) = .empty,
        added: std.AutoHashMapUnmanaged(u64, rank.Weight) = .empty,
        counting: bool = false,

        pub fn init(
            gpa: Allocator,
            io: std.Io,
            table: []const u8,
            published: source_mod.Published,
        ) Allocator.Error!Self {
            return .{
                .gpa = gpa,
                .io = io,
                .table = table,
                .published = published,
                .current = try Catalog.create(gpa),
            };
        }

        pub fn prepare(self: *Self, store: ?*store_mod.Store) void {
            const found = store orelse return;
            self.path = found.path;
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

            const counted = self.persist(catalog);

            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);

                self.retired.append(self.gpa, self.current) catch |err| {
                    catalog.destroy(self.gpa);
                    return source_mod.report(self.table, "publish", err);
                };
                self.current = catalog;
                self.counting = self.counting or counted;
            }

            self.published.call();
        }

        fn persist(self: *Self, catalog: *Catalog) bool {
            const file = self.path orelse return false;
            mirror(self.gpa, catalog, file, self.table) catch |err| {
                source_mod.report(self.table, "write", err);
                return false;
            };
            return true;
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
            const weights = try self.weighted(scratch, of);
            const matches = try rank.rankFields(scratch, of.fields, weights, query);
            if (matches.len == 0) return .nothing;

            for (matches) |match| self.bump(of.ids[match.index], .{ .shown = 1 });

            const shown = matches[0..@min(matches.len, options.max_rows)];
            return .{ .hits = try rows(scratch, of, shown, options.icon) };
        }

        pub fn picks(
            self: *Self,
            owner: *subroutines.Owner,
            limit: usize,
            icon: list.Icon,
        ) subroutines.Error!subroutines.Output {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const of = self.current;
            if (of.items.len == 0) return .nothing;

            const scratch = owner.allocator();
            const weights = try self.weighted(scratch, of);
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
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.bump(id, .{ .chosen = 1 });
        }

        pub fn retire(self: *Self, store: ?*store_mod.Store) void {
            if (store) |found| self.flush(found);

            self.added.deinit(self.gpa);
            self.current.destroy(self.gpa);
            for (self.retired.items) |old| old.destroy(self.gpa);
            self.retired.deinit(self.gpa);
        }

        fn flush(self: *Self, store: *store_mod.Store) void {
            if (!self.counting) return;

            var counts: std.ArrayList(tally.Count) = .empty;
            defer counts.deinit(self.gpa);

            var entries = self.added.iterator();
            while (entries.next()) |entry| {
                counts.append(self.gpa, .{
                    .id = entry.key_ptr.*,
                    .shown = entry.value_ptr.shown,
                    .chosen = entry.value_ptr.chosen,
                }) catch break;
            }

            tally.flush(self.gpa, store.conn, self.table, counts.items) catch |err| {
                log.warn("cannot record the {s} counters: {t}", .{ self.table, err });
            };
        }

        fn weighted(self: *Self, gpa: Allocator, of: *const Catalog) Allocator.Error![]rank.Weight {
            const found = try gpa.alloc(rank.Weight, of.items.len);
            for (of.ids, of.loaded, found) |id, base, *slot| {
                const extra = self.added.get(id) orelse rank.Weight{};
                slot.* = .{
                    .shown = base.shown +| extra.shown,
                    .chosen = base.chosen +| extra.chosen,
                };
            }
            return found;
        }

        fn bump(self: *Self, id: u64, by: rank.Weight) void {
            const slot = self.added.getOrPut(self.gpa, id) catch return;
            if (!slot.found_existing) slot.value_ptr.* = .{};
            slot.value_ptr.shown +|= by.shown;
            slot.value_ptr.chosen +|= by.chosen;
        }

        fn mirror(gpa: Allocator, catalog: *Catalog, file: [:0]const u8, table: []const u8) !void {
            const conn = try store_mod.connect(file, .{});
            defer conn.close();

            try tally.ensure(gpa, conn, table);
            try tally.mirror(gpa, conn, table, catalog.ids);

            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();

            const stored = try tally.load(scratch.allocator(), conn, table);
            for (catalog.ids, catalog.loaded) |id, *slot| slot.* = stored.get(id) orelse .{};
        }

        fn rows(
            arena: Allocator,
            of: *const Catalog,
            matches: []const rank.Match,
            icon: list.Icon,
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

        var words: Words = try .init(testing.allocator, testing.io, "words", .{});
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

    fn counts(setup: *Setup, arena: Allocator) !tally.Weights {
        return tally.load(arena, setup.store.conn, "words");
    }
};

test "a publish loads the counts the table holds and removes the keys that are gone" {
    var setup: Setup = try .init();
    defer setup.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try setup.publish(&.{ "alpha", "beta", "gamma" });
    try tally.flush(testing.allocator, setup.store.conn, "words", &.{
        .{ .id = tally.id("beta"), .shown = 3, .chosen = 2 },
    });

    try setup.publish(&.{ "beta", "delta" });

    const of = setup.words.current;
    try testing.expectEqual(@as(usize, 2), of.items.len);
    try testing.expectEqual(rank.Weight{ .shown = 3, .chosen = 2 }, of.loaded[0]);
    try testing.expectEqual(rank.Weight{}, of.loaded[1]);

    const stored = try setup.counts(arena.allocator());
    try testing.expectEqual(@as(usize, 2), stored.count());
    try testing.expectEqual(@as(?rank.Weight, null), stored.get(tally.id("alpha")));
}

test "hits are ranked by what was chosen and counted as shown" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "web", "webmail" });
    try tally.flush(testing.allocator, setup.store.conn, "words", &.{
        .{ .id = tally.id("webmail"), .chosen = 40 },
    });
    try setup.publish(&.{ "web", "webmail" });

    const found = try setup.words.hits(owner, "web", .{ .max_rows = 10 });
    try testing.expectEqual(@as(usize, 2), found.hits.len);
    try testing.expectEqualStrings("webmail", found.hits[0].row.title);
    try testing.expectEqual(tally.id("webmail"), found.hits[0].row.id);
    try testing.expectEqualStrings("detail", found.hits[0].row.detail);

    try testing.expectEqual(@as(u32, 1), setup.words.added.get(tally.id("web")).?.shown);

    const capped = try setup.words.hits(owner, "web", .{ .max_rows = 1 });
    try testing.expectEqual(@as(usize, 1), capped.hits.len);
}

test "an item is found through any of its fields" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", .{});
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
    setup.words.note(tally.id("alpha"));
    setup.words.note(tally.id("gamma"));
    setup.words.note(tally.id("gamma"));

    const found = try setup.words.picks(owner, 5, .none);

    try testing.expectEqual(@as(usize, 1), found.hits.len);
    try testing.expectEqualStrings("gamma", found.hits[0].row.title);
    try testing.expectEqual(@as(u32, 0), setup.words.added.get(tally.id("gamma")).?.shown);
}

test "an item is found by its id and an unknown id finds nothing" {
    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "alpha", "beta" });

    const found = setup.words.find(tally.id("beta")).?;
    try testing.expectEqualStrings("beta", found.key);
    try testing.expectEqual(@as(u8, 1), found.payload);
    try testing.expectEqual(@as(?Words.Item, null), setup.words.find(tally.id("omega")));
}

test "a pick is written to the table when the counts are flushed" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var setup: Setup = try .init();
    defer setup.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try setup.publish(&.{ "alpha", "beta" });

    setup.words.note(tally.id("beta"));
    _ = try setup.words.hits(owner, "beta", .{ .max_rows = 10 });
    setup.words.flush(setup.store);

    const stored = try setup.counts(arena.allocator());
    try testing.expectEqual(rank.Weight{ .shown = 1, .chosen = 1 }, stored.get(tally.id("beta")).?);
    try testing.expectEqual(rank.Weight{}, stored.get(tally.id("alpha")).?);
}

test "a second item with the same key is dropped" {
    var setup: Setup = try .init();
    defer setup.deinit();

    try setup.publish(&.{ "alpha", "alpha", "beta" });

    try testing.expectEqual(@as(usize, 2), setup.words.current.items.len);
    try testing.expectEqual(@as(u8, 0), setup.words.find(tally.id("alpha")).?.payload);
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
    try testing.expectEqual(@as(?Words.Item, null), setup.words.find(tally.id("alpha")));
}

test "without a store the items are listed and nothing is counted" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", .{});
    defer words.retire(null);

    const items = [_]Words.Item{
        .{ .key = "alpha", .title = "alpha", .fields = &.{"alpha"}, .payload = 0 },
    };
    words.publish(try words.begin(), &items);

    const found = try words.hits(owner, "alpha", .{ .max_rows = 10 });

    try testing.expectEqual(@as(usize, 1), found.hits.len);
    try testing.expect(!words.counting);
}

test "an item's own icon wins over the icon of the source" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var words: Words = try .init(testing.allocator, testing.io, "words", .{});
    defer words.retire(null);

    const glyph: list.Icon = .{ .glyph = "🙌" };
    const items = [_]Words.Item{
        .{ .key = "alpha", .title = "alpha", .icon = glyph, .fields = &.{"alpha"}, .payload = 0 },
        .{ .key = "alps", .title = "alps", .fields = &.{"alps"}, .payload = 1 },
    };
    words.publish(try words.begin(), &items);
    for (0..2) |_| words.note(tally.id("alpha"));

    const source: list.Icon = .{ .name = "edit-cut" };

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
