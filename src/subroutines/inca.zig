const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const icons = @import("core").icons;
const inca = @import("core").inca;
const List = @import("../ui/List.zig");
const picture = @import("../system/picture.zig");
const rank = @import("core").rank;
const source = @import("source.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const tallied = @import("tallied.zig");
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.inca);

pub const table = tables.inca;

const max_rows = 50;
const photo_side = 2 * List.icon_size;
const fetch_budget: std.Io.Duration = .fromSeconds(5);
const section = "[sources.inca]";

const icon_names = [_][:0]const u8{ "avatar-default-symbolic", "x-office-contact" };

const People = tallied.Tallied(?*Portrait);

const Portrait = struct {
    photo: inca.Photo,
    state: State = .new,
    texture: ?*c.GdkTexture = null,

    const State = enum { new, fetching, done };
};

const Fetch = struct {
    portrait: *Portrait,
    title: []const u8,
    url: []const u8,
    stem: [16]u8,
};

const Typed = struct {
    mime: []const u8,

    pub fn format(self: Typed, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.mime.len > 0) try writer.print("{s} ", .{self.mime});
    }
};

pub const Index = struct {
    people: People,
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    published: ?source.Published,
    arena: std.heap.ArenaAllocator,
    program: []const u8,
    configured: bool,
    required: bool,
    icon: [:0]const u8,
    limits: inca.Limits = .{},
    loading: std.Io.Mutex = .init,
    loaded: bool = false,
    cache: ?[]const u8 = null,
    listing: icons.Listing = .{},
    drawing: std.Io.Mutex = .init,
    textures: std.ArrayList(*c.GdkTexture) = .empty,
    pending: usize = 0,
    arrived: bool = false,
    client: std.http.Client,
    fetches: std.Io.Group = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Index),
        };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        if (std.mem.trim(u8, text, " \t").len == 0) return .nothing;
        self.load();

        const found = try self.people.hits(owner, text, .{
            .max_rows = max_rows,
            .icon = .{ .name = self.icon },
            .counted = false,
        });
        const hits = switch (found) {
            .hits => |hits| hits,
            else => return found,
        };
        return .{ .hits = try self.portrayed(owner, hits) };
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.people.counters(id);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.people.forget(id);
    }

    pub fn stale(_: *Index) bool {
        return false;
    }

    pub fn refresh(_: *Index) void {}

    pub fn choose(_: *Index, _: Allocator, _: u64) subroutines.Outcome {
        return .keep;
    }

    pub fn stop(self: *Index) void {
        self.stopping.store(true, .release);
        self.fetches.cancel(self.io);
    }

    pub fn retire(self: *Index, store: ?*store_mod.Store) void {
        self.stop();
        self.client.deinit();
        for (self.textures.items) |texture| glib.g_object_unref(texture);
        self.textures.deinit(self.gpa);
        self.people.retire(store);
        self.arena.deinit();
    }

    fn load(self: *Index) void {
        self.loading.lock(self.io) catch return;
        defer self.loading.unlock(self.io);

        if (self.loaded) return;
        self.loaded = true;

        const catalog = self.people.begin() catch |err| return source.report(table, "read", err);
        const arena = catalog.allocator();

        const found = inca.read(self.gpa, arena, self.io, self.environ, self.program, self.limits) catch |err| {
            self.people.discard(catalog);
            switch (err) {
                error.Canceled => {},
                error.OutOfMemory => source.report(table, "read", err),
            }
            return;
        };

        const contacts = switch (found) {
            .contacts => |contacts| contacts,
            .missing => {
                self.people.discard(catalog);
                return self.missing();
            },
            .failed => |failure| {
                self.people.discard(catalog);
                return log.warn("\"{s}{s}\" {f}, so no contacts are listed", .{
                    self.program,
                    inca.command,
                    failure,
                });
            },
        };

        const items = itemsOf(arena, contacts) catch |err| {
            self.people.discard(catalog);
            return source.report(table, "read", err);
        };
        self.people.publish(catalog, items);

        if (!linksAny(contacts)) return;
        self.prepareCache() catch |err| source.report(table, "read the photo cache of", err);
    }

    fn missing(self: *Index) void {
        if (self.configured) {
            return log.warn("{s} exec is {s}, which does not exist, so no contacts are listed", .{
                section,
                self.program,
            });
        }
        if (self.required) {
            log.warn("{s} enable is true, however there is no {s} in $PATH, so no contacts are listed", .{
                section,
                inca.program,
            });
        }
    }

    fn prepareCache(self: *Index) Allocator.Error!void {
        const scratch = self.arena.allocator();
        const dir = try source.cacheOf(scratch, self.environ, "contacts", "photo") orelse return;
        self.listing = try icons.scan(scratch, self.io, dir);
        self.cache = dir;
    }

    fn portrayed(
        self: *Index,
        owner: *subroutines.Owner,
        hits: []const subroutines.Hit,
    ) subroutines.Error![]const subroutines.Hit {
        const scratch = owner.allocator();
        const shown = try scratch.dupe(subroutines.Hit, hits);
        const ids = try scratch.alloc(u64, hits.len);

        self.drawing.lockUncancelable(self.io);
        defer self.drawing.unlock(self.io);

        for (shown, ids) |*hit, *id| {
            id.* = hit.row.id;
            const person = self.people.find(hit.row.id) orelse continue;
            const portrait = person.payload orelse continue;
            const texture = self.textureOf(person.title, portrait) orelse continue;
            hit.row.icon = owner.keep(@ptrCast(glib.g_object_ref(texture).?));
        }
        self.people.noteShown(ids);
        return shown;
    }

    fn textureOf(self: *Index, title: []const u8, portrait: *Portrait) ?*c.GdkTexture {
        if (portrait.state != .new) return portrait.texture;
        portrait.state = .done;

        switch (portrait.photo) {
            .embedded => |embedded| portrait.texture = self.draw(title, embedded.bytes, embedded.mime),
            .broken => |mime| log.warn("the {f}photo of \"{s}\" is not valid base64, so its row shows the generic icon", .{
                Typed{ .mime = mime },
                title,
            }),
            .linked => |url| self.reach(title, portrait, url),
        }
        return portrait.texture;
    }

    fn draw(self: *Index, title: []const u8, bytes: []const u8, mime: []const u8) ?*c.GdkTexture {
        const decoded = switch (picture.square(bytes, photo_side)) {
            .picture => |found| found,
            .failed => |problem| {
                defer problem.deinit();
                log.warn("cannot decode the {f}photo of \"{s}\": {f}, so its row shows the generic icon", .{
                    Typed{ .mime = mime },
                    title,
                    problem,
                });
                return null;
            },
        };
        defer decoded.deinit();

        const texture = picture.round(self.gpa, decoded.pixbuf) catch {
            log.warn("out of memory, so the photo of \"{s}\" is left out", .{title});
            return null;
        };
        self.textures.append(self.gpa, texture) catch {
            glib.g_object_unref(texture);
            log.warn("out of memory, so the photo of \"{s}\" is left out", .{title});
            return null;
        };
        return texture;
    }

    fn reach(self: *Index, title: []const u8, portrait: *Portrait, url: []const u8) void {
        if (!icons.isRemote(url)) {
            return log.warn("the photo of \"{s}\" is linked as {s}, and only http(s) links are fetched, " ++
                "so its row shows the generic icon", .{ title, url });
        }
        if (self.cache == null) return;

        const stem = icons.stemOf(url);
        const found = self.listing.get(&stem) orelse return self.request(portrait, title, url, stem);
        switch (found) {
            .file => |path| portrait.texture = self.drawFile(title, path),
            .failed => {},
        }
    }

    fn drawFile(self: *Index, title: []const u8, path: []const u8) ?*c.GdkTexture {
        const bytes = Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(icons.max_bytes)) catch |err| {
            switch (err) {
                error.Canceled => {},
                else => log.warn("cannot read the photo of \"{s}\" at {s}: {t}, so its row shows the generic icon", .{
                    title,
                    path,
                    err,
                }),
            }
            return null;
        };
        defer self.gpa.free(bytes);
        return self.draw(title, bytes, "");
    }

    fn request(self: *Index, portrait: *Portrait, title: []const u8, url: []const u8, stem: [16]u8) void {
        if (self.stopping.load(.acquire)) return;

        portrait.state = .fetching;
        self.pending += 1;

        const wanted: Fetch = .{ .portrait = portrait, .title = title, .url = url, .stem = stem };
        self.fetches.concurrent(self.io, fetch, .{ self, wanted }) catch |err| {
            self.pending -= 1;
            portrait.state = .done;
            log.warn("cannot fetch the photo of \"{s}\": {t}", .{ title, err });
        };
    }

    fn fetch(self: *Index, wanted: Fetch) void {
        defer self.settle();
        const dir = self.cache.?;

        const fetched = icons.loadWithin(&self.client, self.gpa, self.io, wanted.url, icons.max_bytes, fetch_budget) catch |err| {
            if (!self.stopping.load(.acquire)) {
                log.warn("cannot fetch the photo of \"{s}\" from {s}: {t}", .{ wanted.title, wanted.url, err });
            }
            return self.finish(wanted, null);
        };

        switch (fetched) {
            .image => |image| {
                defer self.gpa.free(image.bytes);

                icons.store(self.gpa, self.io, dir, &wanted.stem, image) catch |err| {
                    if (!self.stopping.load(.acquire)) {
                        log.warn("cannot keep the photo of \"{s}\" in {s}: {t}", .{ wanted.title, dir, err });
                    }
                };
                self.finish(wanted, image.bytes);
            },
            .failed => |failure| {
                self.fail(dir, wanted, failure);
                self.finish(wanted, null);
            },
        }
    }

    fn finish(self: *Index, wanted: Fetch, bytes: ?[]const u8) void {
        self.drawing.lockUncancelable(self.io);
        defer self.drawing.unlock(self.io);

        if (bytes) |found| {
            if (!self.stopping.load(.acquire)) wanted.portrait.texture = self.draw(wanted.title, found, "");
        }
        if (wanted.portrait.texture != null) self.arrived = true;
        wanted.portrait.state = .done;
    }

    fn fail(self: *Index, dir: []const u8, wanted: Fetch, failure: icons.Failure) void {
        if (self.stopping.load(.acquire)) return;

        const marked = icons.mark(self.gpa, self.io, dir, &wanted.stem) catch |err| {
            if (self.stopping.load(.acquire)) return;
            log.warn("cannot fetch the photo of \"{s}\" from {s}: {f}, and cannot note that in {s}: {t}", .{
                wanted.title,
                wanted.url,
                failure,
                dir,
                err,
            });
            return;
        };
        defer self.gpa.free(marked);

        log.warn("cannot fetch the photo of \"{s}\" from {s}: {f}, so it is not tried again " ++
            "until {s} is deleted", .{
            wanted.title,
            wanted.url,
            failure,
            marked,
        });
    }

    fn settle(self: *Index) void {
        self.drawing.lockUncancelable(self.io);
        self.pending -= 1;
        const redraw = self.pending == 0 and self.arrived;
        if (redraw) self.arrived = false;
        self.drawing.unlock(self.io);

        if (!redraw or self.stopping.load(.acquire)) return;
        if (self.published) |found| found.call(.{});
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("inca")) return null;

    var arena: std.heap.ArenaAllocator = .init(context.gpa);
    errdefer arena.deinit();

    const exec = context.settings.sources.inca.exec;
    const home = context.environ.get("HOME") orelse "";
    const program = if (exec.len > 0) try xdg.expand(arena.allocator(), home, exec) else inca.program;

    var self: Index = .{
        .people = try .init(context.gpa, context.io, table, null),
        .gpa = context.gpa,
        .io = context.io,
        .environ = context.environ,
        .published = context.published,
        .arena = arena,
        .program = program,
        .configured = exec.len > 0,
        .required = context.asked("inca") or exec.len > 0,
        .icon = subroutines.themedIcon(&icon_names),
        .client = .{ .allocator = context.gpa, .io = context.io },
    };
    self.people.prepare(context.store);
    return self;
}

fn itemsOf(arena: Allocator, contacts: []const inca.Contact) Allocator.Error![]People.Item {
    const items = try arena.alloc(People.Item, contacts.len);
    for (contacts, items) |contact, *item| {
        item.* = .{
            .key = contact.key,
            .title = contact.title,
            .detail = contact.detail,
            .fields = contact.fields,
            .payload = try portraitOf(arena, contact.photo),
        };
    }
    return items;
}

fn portraitOf(arena: Allocator, photo: ?inca.Photo) Allocator.Error!?*Portrait {
    const found = photo orelse return null;
    const portrait = try arena.create(Portrait);
    portrait.* = .{ .photo = found };
    return portrait;
}

fn linksAny(contacts: []const inca.Contact) bool {
    for (contacts) |contact| {
        const photo = contact.photo orelse continue;
        if (photo == .linked) return true;
    }
    return false;
}

const testing = std.testing;
const config_mod = @import("../config.zig");
const gdk = @import("../gtk/gdk.zig");
const model = @import("../model.zig");

const red_png = "iVBORw0KGgoAAAANSUhEUgAAAGQAAABQCAIAAABga0e4AAAAhklEQVR42u3QgQAAAAgDsIrm/hRhpRDAhrDepPgZBbJkyZIlS5YCWbJkyZIlS4EsWbJkyZKlQJYsWbJkyVIgS5YsWbJkKZAlS5YsWbIUyJIlS5YsWQpkyZIlS5YsBbJkyZIlS5YCWbJkyZIlS4EsWbJkyZKlQJYsWbJkyVIgS5YsWbJkKfg7qrwBuHYdvQAAAAAASUVORK5CYII=";

const Published = struct {
    count: std.atomic.Value(u32) = .init(0),

    fn onPublished(self: *Published) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }
};

const Rig = struct {
    tmp: testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8 = undefined,
    script_buffer: [std.fs.max_path_bytes]u8 = undefined,
    cache_buffer: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    script: []const u8 = "",
    cache: []const u8 = "",
    environ: std.process.Environ.Map,
    settings: config_mod.Config = .{},
    published: Published = .{},
    owner: *subroutines.Owner = undefined,

    fn init(self: *Rig, json: []const u8) !void {
        try self.initWith(json, "cat \"$0.json\"");
    }

    fn initWith(self: *Rig, json: []const u8, body: []const u8) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .environ = .init(testing.allocator) };
        errdefer self.environ.deinit();
        errdefer self.tmp.cleanup();

        const length = try self.tmp.dir.realPath(testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..length];
        self.script = try std.fmt.bufPrint(&self.script_buffer, "{s}/inca", .{self.root});
        self.cache = try std.fmt.bufPrint(&self.cache_buffer, "{s}/sysdeck/contacts", .{self.root});

        try self.environ.put("PATH", "/usr/bin:/bin");
        try self.environ.put("XDG_CACHE_HOME", self.root);

        const script = try std.fmt.allocPrint(testing.allocator, "#!/bin/sh\necho start >> \"$0.log\"\n{s}\n", .{body});
        defer testing.allocator.free(script);
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "inca",
            .data = script,
            .flags = .{ .permissions = .executable_file },
        });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "inca.json", .data = json });

        self.owner = try subroutines.Owner.create(testing.allocator);
    }

    fn deinit(self: *Rig) void {
        self.owner.destroy(testing.allocator);
        self.environ.deinit();
        self.tmp.cleanup();
    }

    fn open(self: *Rig) !Index {
        self.settings = .{ .sources = .{ .inca = .{ .exec = self.script } } };
        return (try inca_source.open(.{
            .gpa = testing.allocator,
            .io = testing.io,
            .environ = &self.environ,
            .settings = &self.settings,
            .published = .of(Published, Published.onPublished, &self.published),
        })).?;
    }

    fn starts(self: *Rig) !usize {
        const text = self.tmp.dir.readFileAlloc(testing.io, "inca.log", testing.allocator, .limited(4096)) catch |err| {
            return switch (err) {
                error.FileNotFound => 0,
                else => err,
            };
        };
        defer testing.allocator.free(text);
        return std.mem.count(u8, text, "start");
    }

    fn rows(self: *Rig, index: *Index, query: []const u8) ![]const subroutines.Hit {
        return switch (try index.run(self.owner, query)) {
            .hits => |hits| hits,
            else => &.{},
        };
    }

    fn rowOf(self: *Rig, index: *Index, query: []const u8) !model.Row {
        const found = try self.rows(index, query);
        try testing.expectEqual(@as(usize, 1), found.len);
        return found[0].row;
    }

    fn listing(self: *Rig, arena: Allocator) !icons.Listing {
        return icons.scan(arena, testing.io, self.cache);
    }
};

const inca_source = @This();

fn textureOfRow(row: model.Row) *c.GdkTexture {
    return @ptrCast(row.icon.gicon);
}

test "nothing runs until a query has text, and the contacts are read once" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "Jane Doe", "kind": "individual", "emails": ["jane@example.com"]},
        \\ {"key": "b", "formatted_name": "Max Mustermann", "kind": "individual"}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "")).len);
    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "  ")).len);
    try testing.expectEqual(@as(usize, 0), try rig.starts());

    const jane = try rig.rowOf(&index, "jane");
    try testing.expectEqualStrings("Jane Doe", jane.title);
    try testing.expectEqualStrings("jane@example.com", jane.detail);
    _ = try rig.rowOf(&index, "max");
    try testing.expectEqual(@as(usize, 1), try rig.starts());
}

test "a failed listing is not retried and lists nothing" {
    var rig: Rig = undefined;
    try rig.initWith("[]", "echo 'level=ERROR msg=\"locked\"' >&2\nexit 1");
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "jane")).len);
    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "max")).len);
    try testing.expectEqual(@as(usize, 1), try rig.starts());
}

test "an embedded photo becomes a round texture of 64 pixels at most" {
    const json = try std.fmt.allocPrint(testing.allocator,
        \\[{{"key": "a", "formatted_name": "Jane Doe", "kind": "individual",
        \\  "photo": {{"media_type": "image/png", "data": "{s}"}}}}]
    , .{red_png});
    defer testing.allocator.free(json);

    var rig: Rig = undefined;
    try rig.init(json);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    const texture = textureOfRow(try rig.rowOf(&index, "jane"));
    try testing.expectEqual(@as(c_int, 64), gdk.gdk_texture_get_width(texture));
    try testing.expectEqual(@as(c_int, 64), gdk.gdk_texture_get_height(texture));

    var downloaded: [64 * 64 * 4]u8 = undefined;
    gdk.gdk_texture_download(texture, &downloaded, 64 * 4);
    try testing.expectEqual(@as(u8, 0), downloaded[3]);
    try testing.expectEqual(@as(u8, 255), downloaded[(32 * 64 + 32) * 4 + 3]);

    try testing.expectEqual(texture, textureOfRow(try rig.rowOf(&index, "doe")));
    try testing.expectEqual(@as(usize, 1), index.textures.items.len);
}

test "a contact without a photo, or with one that can't be decoded, shows the generic icon" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "Bare Person", "kind": "individual"},
        \\ {"key": "b", "formatted_name": "Broken Person", "kind": "individual",
        \\  "photo": {"media_type": "image/jpeg", "data": "not!base64"}},
        \\ {"key": "c", "formatted_name": "Unknown Person", "kind": "individual", "photo": {"data": "AAECAwQ="}}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    for ([_][]const u8{ "bare", "broken", "unknown" }) |query| {
        const row = try rig.rowOf(&index, query);
        try testing.expectEqualStrings(index.icon, row.icon.name);
    }
    try testing.expectEqual(@as(usize, 0), index.textures.items.len);
}

fn linkedJson(found: []const u8, gone: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator,
        \\[{{"key": "a", "formatted_name": "Remote Person", "kind": "individual", "photo": {{"uri": "{s}"}}}},
        \\ {{"key": "b", "formatted_name": "Gone Person", "kind": "individual", "photo": {{"uri": "{s}"}}}}]
    , .{ found, gone });
}

test "a linked photo is fetched once into the contacts cache and redrawn, a failure leaves a marker" {
    const bytes = try bytesOf(red_png);
    defer testing.allocator.free(bytes);

    const routes = [_]icons.Route{.{ .path = "/photo.png", .body = bytes }};
    var local: icons.Local = undefined;
    try local.start(testing.io, &routes);
    defer local.stop();

    const found = try local.url(testing.allocator, "/photo.png");
    defer testing.allocator.free(found);
    const gone = try local.url(testing.allocator, "/gone.png");
    defer testing.allocator.free(gone);
    const json = try linkedJson(found, gone);
    defer testing.allocator.free(json);

    var rig: Rig = undefined;
    try rig.init(json);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    const listed = try rig.rows(&index, "person");
    try testing.expectEqual(@as(usize, 2), listed.len);
    for (listed) |hit| try testing.expectEqualStrings(index.icon, hit.row.icon.name);

    try index.fetches.await(testing.io);
    try testing.expectEqual(@as(u32, 2), local.served.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), rig.published.count.load(.monotonic));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cached = try rig.listing(arena.allocator());
    try testing.expect(cached.get(&icons.stemOf(found)).? == .file);
    try testing.expect(cached.get(&icons.stemOf(gone)).? == .failed);

    try testing.expectEqual(@as(c_int, 64), gdk.gdk_texture_get_width(textureOfRow(try rig.rowOf(&index, "remote"))));
    try testing.expectEqualStrings(index.icon, (try rig.rowOf(&index, "gone")).icon.name);

    _ = try rig.rows(&index, "person");
    try index.fetches.await(testing.io);
    try testing.expectEqual(@as(u32, 2), local.served.load(.monotonic));
}

test "a cached photo or marker is not fetched again" {
    const bytes = try bytesOf(red_png);
    defer testing.allocator.free(bytes);

    const routes = [_]icons.Route{.{ .path = "/photo.png", .body = bytes }};
    var local: icons.Local = undefined;
    try local.start(testing.io, &routes);
    defer local.stop();

    const found = try local.url(testing.allocator, "/photo.png");
    defer testing.allocator.free(found);
    const gone = try local.url(testing.allocator, "/gone.png");
    defer testing.allocator.free(gone);
    const json = try linkedJson(found, gone);
    defer testing.allocator.free(json);

    var rig: Rig = undefined;
    try rig.init(json);
    defer rig.deinit();

    try icons.store(testing.allocator, testing.io, rig.cache, &icons.stemOf(found), .{ .kind = .png, .bytes = bytes });
    testing.allocator.free(try icons.mark(testing.allocator, testing.io, rig.cache, &icons.stemOf(gone)));

    var index = try rig.open();
    defer index.retire(null);

    try testing.expectEqual(@as(c_int, 64), gdk.gdk_texture_get_width(textureOfRow(try rig.rowOf(&index, "remote"))));
    try testing.expectEqualStrings(index.icon, (try rig.rowOf(&index, "gone")).icon.name);

    try index.fetches.await(testing.io);
    try testing.expectEqual(@as(u32, 0), local.served.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), rig.published.count.load(.monotonic));
}

test "fetches that only fail draw nothing again" {
    const routes = [_]icons.Route{};
    var local: icons.Local = undefined;
    try local.start(testing.io, &routes);
    defer local.stop();

    const first = try local.url(testing.allocator, "/first.png");
    defer testing.allocator.free(first);
    const second = try local.url(testing.allocator, "/second.png");
    defer testing.allocator.free(second);
    const json = try linkedJson(first, second);
    defer testing.allocator.free(json);

    var rig: Rig = undefined;
    try rig.init(json);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    _ = try rig.rows(&index, "person");
    try index.fetches.await(testing.io);

    try testing.expectEqual(@as(u32, 2), local.served.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), rig.published.count.load(.monotonic));
}

test "stopping a fetch that hangs returns at once and leaves no marker" {
    const address: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var silent = try address.listen(testing.io, .{ .reuse_address = true });
    defer silent.deinit(testing.io);

    const hung = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/photo.png", .{
        silent.socket.address.getPort(),
    });
    defer testing.allocator.free(hung);
    const json = try std.fmt.allocPrint(testing.allocator,
        \\[{{"key": "a", "formatted_name": "Hung Person", "kind": "individual", "photo": {{"uri": "{s}"}}}}]
    , .{hung});
    defer testing.allocator.free(json);

    var rig: Rig = undefined;
    try rig.init(json);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    _ = try rig.rowOf(&index, "hung");
    try testing.io.sleep(.fromMilliseconds(200), .awake);

    const started = std.Io.Clock.awake.now(testing.io);
    index.stop();
    const took = started.durationTo(std.Io.Clock.awake.now(testing.io));

    try testing.expect(took.toMilliseconds() < 500);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(u32, 0), (try rig.listing(arena.allocator())).entries.count());
    try testing.expectEqual(@as(u32, 0), rig.published.count.load(.monotonic));
}

test "a link that isn't http(s) is not fetched" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "Local Person", "kind": "individual",
        \\  "photo": {"uri": "file:///etc/passwd"}}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    try testing.expectEqualStrings(index.icon, (try rig.rowOf(&index, "local")).icon.name);
    try index.fetches.await(testing.io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(u32, 0), (try rig.listing(arena.allocator())).entries.count());
    try testing.expectEqual(@as(usize, 0), index.pending);
}

test "choosing a contact does nothing and counts nothing" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "Jane Doe", "kind": "individual"}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    const jane = try rig.rowOf(&index, "jane");
    try testing.expectEqual(subroutines.Outcome.keep, index.choose(testing.allocator, jane.id));
    try testing.expectEqual(rank.Weight{ .shown = 1 }, index.counters(jane.id).?);
    try testing.expectEqualStrings("", index.subroutine().verb);
}

test "only the returned rows count as shown" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(testing.allocator);
    try json.append(testing.allocator, '[');
    for (0..60) |at| {
        if (at > 0) try json.append(testing.allocator, ',');
        try json.print(testing.allocator, "{{\"key\": \"k{d}\", \"formatted_name\": \"Person {d}\"}}", .{ at, at });
    }
    try json.append(testing.allocator, ']');

    var rig: Rig = undefined;
    try rig.init(json.items);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire(null);

    const listed = try rig.rows(&index, "person");
    try testing.expectEqual(@as(usize, 50), listed.len);

    var counted: usize = 0;
    for (0..60) |at| {
        var key: [8]u8 = undefined;
        const id = @import("core").counts.id(try std.fmt.bufPrint(&key, "k{d}", .{at}));
        counted += index.counters(id).?.shown;
    }
    try testing.expectEqual(@as(usize, 50), counted);
}

fn bytesOf(text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const bytes = try testing.allocator.alloc(u8, try decoder.calcSizeForSlice(text));
    try decoder.decode(bytes, text);
    return bytes;
}
