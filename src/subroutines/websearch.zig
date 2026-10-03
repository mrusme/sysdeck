const std = @import("std");
const config_mod = @import("../config.zig");
const gio = @import("../gtk/gio.zig");
const icons = @import("core").icons;
const launch = @import("../system/launch.zig");
const model = @import("../model.zig");
const rank = @import("core").rank;
const source = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const tallied = @import("tallied.zig");
const web = @import("core").websearch;
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Provider = config_mod.Config.Sources.Websearch.Provider;
const log = std.log.scoped(.websearch);

pub const table = tables.websearch;

const max_rows = 50;
const section = "[[sources.websearch.providers]]";

const icon_names = [_][:0]const u8{ "internet-web-browser", "applications-internet", "web-browser" };

const Providers = tallied.Tallied([]const u8);

const Picture = union(enum) {
    none,
    local: [:0]const u8,
    remote: Remote,
};

const Remote = struct {
    stem: []const u8,
    url: []const u8,
};

const Entry = struct {
    name: []const u8,
    url: []const u8,
    host: []const u8,
    picture: Picture,
};

const Fetch = struct {
    name: []const u8,
    remote: Remote,
};

pub const Index = struct {
    providers: Providers,
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    cache: ?[]const u8,
    icon: [:0]const u8,
    client: std.http.Client,
    fetches: std.Io.Group = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    publishing: std.Io.Mutex = .init,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Index),
            .verb = "Search",
        };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.providers.hits(owner, text, .{ .max_rows = max_rows, .icon = .{ .name = self.icon } });
    }

    pub fn picks(
        self: *Index,
        owner: *subroutines.Owner,
        limit: usize,
    ) subroutines.Error!subroutines.Output {
        return self.providers.picks(owner, limit, .{ .name = self.icon });
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.providers.counters(id);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.providers.forget(id);
    }

    pub fn stale(_: *Index) bool {
        return true;
    }

    pub fn refresh(self: *Index) void {
        self.rebuild();
        self.request();
    }

    pub fn choose(self: *Index, gpa: Allocator, id: u64) subroutines.Outcome {
        return self.search(gpa, id, "");
    }

    pub fn chooseWith(self: *Index, gpa: Allocator, id: u64, arguments: []const u8) subroutines.Outcome {
        return self.search(gpa, id, arguments);
    }

    pub fn stop(self: *Index) void {
        self.stopping.store(true, .release);
        self.fetches.cancel(self.io);
    }

    pub fn retire(self: *Index, store: ?*store_mod.Store) void {
        self.stop();
        self.client.deinit();
        self.providers.retire(store);
        self.arena.deinit();
    }

    fn search(self: *Index, gpa: Allocator, id: u64, text: []const u8) subroutines.Outcome {
        const found = self.providers.find(id) orelse return .keep;

        if (text.len > 0 and !web.takesText(found.payload)) {
            log.warn("the url of the {s} entry \"{s}\" has no {s}, so the arguments are left out", .{
                section,
                found.title,
                web.placeholder,
            });
        }

        const url = web.fill(gpa, found.payload, text) catch return .keep;
        defer gpa.free(url);

        if (!launch.uri(gpa, self.environ, url)) return .keep;

        self.providers.note(id);
        return .close;
    }

    fn rebuild(self: *Index) void {
        self.publishing.lockUncancelable(self.io);
        defer self.publishing.unlock(self.io);

        const catalog = self.providers.begin() catch |err| return source.report(table, "read", err);
        const arena = catalog.allocator();

        const listing = self.scan(arena) catch |err| {
            self.providers.discard(catalog);
            return source.report(table, "read", err);
        };
        const items = itemsOf(catalog, self.entries, &listing) catch |err| {
            self.providers.discard(catalog);
            return source.report(table, "read", err);
        };
        self.providers.publish(catalog, items);
    }

    fn scan(self: *Index, arena: Allocator) Allocator.Error!icons.Listing {
        const dir = self.cache orelse return .{};
        return icons.scan(arena, self.io, dir);
    }

    fn request(self: *Index) void {
        if (self.cache == null) return;

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        const listing = self.scan(scratch) catch |err| return source.report(table, "read", err);
        var started: std.StringHashMapUnmanaged(void) = .empty;

        for (self.entries) |entry| {
            const remote = switch (entry.picture) {
                .remote => |found| found,
                .none, .local => continue,
            };
            if (listing.get(remote.stem) != null) continue;

            const slot = started.getOrPut(scratch, remote.stem) catch |err| {
                return source.report(table, "read", err);
            };
            if (slot.found_existing) continue;

            const wanted: Fetch = .{ .name = entry.name, .remote = remote };
            self.fetches.concurrent(self.io, fetch, .{ self, wanted }) catch |err| {
                log.warn("cannot fetch the icon of \"{s}\": {t}", .{ entry.name, err });
            };
        }
    }

    fn fetch(self: *Index, wanted: Fetch) void {
        const dir = self.cache orelse return;

        const fetched = icons.fetch(&self.client, self.gpa, wanted.remote.url, icons.max_bytes) catch |err| {
            log.warn("cannot fetch the icon of \"{s}\": {t}", .{ wanted.name, err });
            return;
        };

        switch (fetched) {
            .image => |image| {
                defer self.gpa.free(image.bytes);

                icons.store(self.gpa, self.io, dir, wanted.remote.stem, image) catch |err| {
                    if (self.stopping.load(.acquire)) return;
                    log.warn("cannot store the icon of \"{s}\" in {s}: {t}", .{ wanted.name, dir, err });
                    return;
                };
                self.rebuild();
            },
            .failed => |failure| self.fail(dir, wanted, failure),
        }
    }

    fn fail(self: *Index, dir: []const u8, wanted: Fetch, failure: icons.Failure) void {
        if (self.stopping.load(.acquire)) return;

        const marked = icons.mark(self.gpa, self.io, dir, wanted.remote.stem) catch |err| {
            if (self.stopping.load(.acquire)) return;
            log.warn("cannot fetch the icon of \"{s}\" from {s}: {f}, and cannot note that in {s}: {t}", .{
                wanted.name,
                wanted.remote.url,
                failure,
                dir,
                err,
            });
            return;
        };
        defer self.gpa.free(marked);

        log.warn("cannot fetch the icon of \"{s}\" from {s}: {f}, so it is not tried again " ++
            "until {s} is deleted", .{
            wanted.name,
            wanted.remote.url,
            failure,
            marked,
        });
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("websearch")) return null;

    const configured = context.settings.sources.websearch.providers;
    if (configured.len == 0) {
        if (context.asked("websearch")) {
            log.warn(
                "[sources.websearch] enable is true, however there is no {s} entry, " ++
                    "so there is nothing to list",
                .{section},
            );
        }
        return null;
    }

    var arena: std.heap.ArenaAllocator = .init(context.gpa);
    errdefer arena.deinit();

    const home = context.environ.get("HOME") orelse "";
    const entries = try entriesOf(arena.allocator(), context.io, home, configured);
    if (entries.len == 0) {
        arena.deinit();
        return null;
    }

    const cache = try source.cacheOf(arena.allocator(), context.environ, "icons", "icon");
    const providers: Providers = try .init(context.gpa, context.io, table, context.published);

    var self: Index = .{
        .providers = providers,
        .gpa = context.gpa,
        .io = context.io,
        .environ = context.environ,
        .arena = arena,
        .entries = entries,
        .cache = cache,
        .icon = subroutines.themedIcon(&icon_names),
        .client = .{ .allocator = context.gpa, .io = context.io },
    };
    self.providers.prepare(context.store);
    return self;
}

fn entriesOf(
    arena: Allocator,
    io: std.Io,
    home: []const u8,
    configured: []const Provider,
) Allocator.Error![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var names: std.StringHashMapUnmanaged(void) = .empty;

    for (configured) |provider| {
        if (provider.name.len == 0) {
            log.warn("an {s} entry has no name, so it is left out", .{section});
            continue;
        }
        if (provider.url.len == 0) {
            log.warn("the {s} entry \"{s}\" has no url, so it is left out", .{ section, provider.name });
            continue;
        }

        const slot = try names.getOrPut(arena, provider.name);
        if (slot.found_existing) {
            log.warn("the {s} entry \"{s}\" appears twice, so the second is left out", .{
                section,
                provider.name,
            });
            continue;
        }

        const host = try web.hostOf(arena, provider.url);
        try entries.append(arena, .{
            .name = provider.name,
            .url = provider.url,
            .host = host orelse "",
            .picture = try pictureOf(arena, io, home, provider, host),
        });
    }
    return entries.items;
}

fn pictureOf(
    arena: Allocator,
    io: std.Io,
    home: []const u8,
    provider: Provider,
    host: ?[]const u8,
) Allocator.Error!Picture {
    if (provider.icon.len == 0) {
        const found = host orelse {
            log.warn("the url of the {s} entry \"{s}\" has no host, so it has no favicon", .{
                section,
                provider.name,
            });
            return .none;
        };
        return .{ .remote = .{ .stem = found, .url = try web.faviconOf(arena, found) } };
    }

    if (isRemote(provider.icon)) {
        const stem = icons.stemOf(provider.icon);
        return .{ .remote = .{ .stem = try arena.dupe(u8, &stem), .url = provider.icon } };
    }

    const path = try xdg.expand(arena, home, provider.icon);
    if (!std.fs.path.isAbsolute(path)) {
        log.warn("the icon of the {s} entry \"{s}\" is neither an absolute path nor an http(s) URL: {s}", .{
            section,
            provider.name,
            provider.icon,
        });
        return .none;
    }

    Dir.cwd().access(io, path, .{}) catch |err| {
        log.warn("cannot read the icon of the {s} entry \"{s}\" at {s}: {t}", .{
            section,
            provider.name,
            path,
            err,
        });
        return .none;
    };
    return .{ .local = try arena.dupeZ(u8, path) };
}

fn isRemote(icon: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(icon, "https://") or
        std.ascii.startsWithIgnoreCase(icon, "http://");
}

fn itemsOf(
    catalog: *Providers.Catalog,
    entries: []const Entry,
    listing: *const icons.Listing,
) Allocator.Error![]Providers.Item {
    const arena = catalog.allocator();

    const items = try arena.alloc(Providers.Item, entries.len);
    for (entries, items) |entry, *item| {
        item.* = .{
            .key = entry.name,
            .title = try arena.dupeZ(u8, entry.name),
            .detail = try arena.dupeZ(u8, entry.host),
            .icon = iconOf(catalog, entry.picture, listing),
            .fields = try arena.dupe([]const u8, &.{ entry.name, entry.url }),
            .payload = entry.url,
        };
    }
    return items;
}

fn iconOf(catalog: *Providers.Catalog, picture: Picture, listing: *const icons.Listing) model.Icon {
    const path: [:0]const u8 = switch (picture) {
        .none => return .none,
        .local => |found| found,
        .remote => |remote| switch (listing.get(remote.stem) orelse return .none) {
            .file => |found| found,
            .failed => return .none,
        },
    };

    const icon = gio.g_icon_new_for_string(path.ptr, null) orelse return .none;
    return catalog.keep(icon);
}

const testing = std.testing;

const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";

const Published = struct {
    count: std.atomic.Value(u32) = .init(0),

    fn onPublished(self: *Published) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }
};

const Rig = struct {
    tmp: testing.TmpDir,
    buffer: [std.fs.max_path_bytes]u8 = undefined,
    cache: []const u8 = "",
    environ: std.process.Environ.Map,
    settings: config_mod.Config = .{},
    published: Published = .{},

    fn init(self: *Rig) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .environ = .init(testing.allocator) };
        errdefer self.deinit();

        const length = try self.tmp.dir.realPath(testing.io, &self.buffer);
        try self.environ.put("XDG_CACHE_HOME", self.buffer[0..length]);
        const home = self.buffer[0..length];
        self.cache = try std.fmt.bufPrint(self.buffer[length..], "{s}/sysdeck/icons", .{home});
    }

    fn deinit(self: *Rig) void {
        self.environ.deinit();
        self.tmp.cleanup();
    }

    fn open(self: *Rig, providers: []const Provider) !?Index {
        self.settings = .{ .sources = .{ .websearch = .{ .providers = providers } } };
        return websearch.open(.{
            .gpa = testing.allocator,
            .io = testing.io,
            .environ = &self.environ,
            .settings = &self.settings,
            .published = .of(Published, Published.onPublished, &self.published),
        });
    }

    fn listing(self: *Rig, arena: Allocator) !icons.Listing {
        return icons.scan(arena, testing.io, self.cache);
    }
};

const websearch = @This();

fn rowOf(index: *Index, owner: *subroutines.Owner, query: []const u8) !model.Row {
    const found = try index.run(owner, query);
    try testing.expectEqual(@as(usize, 1), found.hits.len);
    return found.hits[0].row;
}

test "an entry without a name or a url and a repeated name are left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const configured = [_]Provider{
        .{ .name = "", .url = "https://e.org/?q=%s" },
        .{ .name = "Empty" },
        .{ .name = "Brave", .url = "https://search.brave.com/search?q=%s" },
        .{ .name = "Brave", .url = "https://other.example/?q=%s" },
        .{ .name = "Manual", .url = "man:%s" },
    };
    const entries = try entriesOf(arena.allocator(), testing.io, "/home/m", &configured);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("search.brave.com", entries[0].host);
    try testing.expectEqualStrings("search.brave.com", entries[0].picture.remote.stem);
    try testing.expectEqualStrings(
        "https://icons.duckduckgo.com/ip3/search.brave.com.ico",
        entries[0].picture.remote.url,
    );
    try testing.expectEqualStrings("", entries[1].host);
    try testing.expect(entries[1].picture == .none);
}

test "an icon URL is fetched under its hash, and a local icon must be readable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "brave.png", .data = png });

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &buffer);
    const home = buffer[0..length];

    const configured = [_]Provider{
        .{ .name = "Remote", .url = "https://e.org/?q=%s", .icon = "HTTPS://e.org/icon.svg" },
        .{ .name = "Local", .url = "https://e.org/?q=%s", .icon = "~/brave.png" },
        .{ .name = "Missing", .url = "https://e.org/?q=%s", .icon = "~/gone.png" },
        .{ .name = "Relative", .url = "https://e.org/?q=%s", .icon = "build.zig" },
    };
    const entries = try entriesOf(arena.allocator(), testing.io, home, &configured);

    try testing.expectEqual(@as(usize, 4), entries.len);
    const stem = icons.stemOf("HTTPS://e.org/icon.svg");
    try testing.expectEqualStrings(&stem, entries[0].picture.remote.stem);
    try testing.expectEqualStrings("HTTPS://e.org/icon.svg", entries[0].picture.remote.url);
    try testing.expect(std.mem.endsWith(u8, entries[1].picture.local, "/brave.png"));
    try testing.expect(std.fs.path.isAbsolute(entries[1].picture.local));
    try testing.expect(entries[2].picture == .none);
    try testing.expect(entries[3].picture == .none);
}

test "no provider means no source at all" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    try testing.expectEqual(@as(?Index, null), try rig.open(&.{}));
    try testing.expectEqual(@as(?Index, null), try rig.open(&.{.{ .name = "Unnamed" }}));
}

test "a fetched icon is stored, shown and published, and a failure leaves a marker" {
    const routes = [_]icons.Route{.{ .path = "/icon.png", .body = png }};
    var local: icons.Local = undefined;
    try local.start(testing.io, &routes);
    defer local.stop();

    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    const found = try local.url(testing.allocator, "/icon.png");
    defer testing.allocator.free(found);
    const gone = try local.url(testing.allocator, "/gone.png");
    defer testing.allocator.free(gone);

    const providers = [_]Provider{
        .{ .name = "Found", .url = "https://found.example/?q=%s", .icon = found },
        .{ .name = "Again", .url = "https://again.example/?q=%s", .icon = found },
        .{ .name = "Gone", .url = "https://gone.example/?q=%s", .icon = gone },
    };
    var index = (try rig.open(&providers)).?;
    defer index.retire(null);

    index.refresh();
    try index.fetches.await(testing.io);

    try testing.expectEqual(@as(u32, 2), local.served.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), rig.published.count.load(.monotonic));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const listing = try rig.listing(arena.allocator());
    try testing.expect(listing.get(&icons.stemOf(found)).? == .file);
    try testing.expect(listing.get(&icons.stemOf(gone)).? == .failed);

    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    const shown = try rowOf(&index, owner, "Found");
    try testing.expect(shown.icon == .gicon);
    try testing.expectEqualStrings("found.example", shown.detail);
    try testing.expect((try rowOf(&index, owner, "Gone")).icon == .name);
}

test "a cached icon or marker is not fetched again" {
    const routes = [_]icons.Route{.{ .path = "/icon.png", .body = png }};
    var local: icons.Local = undefined;
    try local.start(testing.io, &routes);
    defer local.stop();

    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    const found = try local.url(testing.allocator, "/icon.png");
    defer testing.allocator.free(found);
    const gone = try local.url(testing.allocator, "/gone.png");
    defer testing.allocator.free(gone);

    var bytes = png.*;
    const image: icons.Image = .{ .kind = .png, .bytes = &bytes };
    try icons.store(testing.allocator, testing.io, rig.cache, &icons.stemOf(found), image);
    testing.allocator.free(try icons.mark(testing.allocator, testing.io, rig.cache, &icons.stemOf(gone)));

    const providers = [_]Provider{
        .{ .name = "Found", .url = "https://found.example/?q=%s", .icon = found },
        .{ .name = "Gone", .url = "https://gone.example/?q=%s", .icon = gone },
    };
    var index = (try rig.open(&providers)).?;
    defer index.retire(null);

    index.refresh();
    try index.fetches.await(testing.io);

    try testing.expectEqual(@as(u32, 0), local.served.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), rig.published.count.load(.monotonic));
}

test "stopping a fetch that hangs returns at once and leaves no marker" {
    const address: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var silent = try address.listen(testing.io, .{ .reuse_address = true });
    defer silent.deinit(testing.io);

    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    const hung = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/icon.png", .{
        silent.socket.address.getPort(),
    });
    defer testing.allocator.free(hung);

    const providers = [_]Provider{.{ .name = "Hung", .url = "https://hung.example/?q=%s", .icon = hung }};
    var index = (try rig.open(&providers)).?;
    defer index.retire(null);

    index.refresh();
    try testing.io.sleep(.fromMilliseconds(200), .awake);

    const started = std.Io.Clock.awake.now(testing.io);
    index.stop();
    const took = started.durationTo(std.Io.Clock.awake.now(testing.io));

    try testing.expect(took.toMilliseconds() < 500);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(u32, 0), (try rig.listing(arena.allocator())).entries.count());
    try testing.expectEqual(@as(u32, 1), rig.published.count.load(.monotonic));
}
