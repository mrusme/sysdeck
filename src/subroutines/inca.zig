const std = @import("std");
const c = @import("../gtk/c.zig");
const command = @import("core").command;
const copy = @import("../system/copy.zig");
const glib = @import("../gtk/glib.zig");
const icons = @import("core").icons;
const inca = @import("core").inca;
const List = @import("../ui/List.zig");
const picture = @import("../system/picture.zig");
const rank = @import("core").rank;
const source = @import("source.zig");
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const tallied = @import("tallied.zig");
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const log = std.log.scoped(.inca);

pub const table = tables.inca;

const max_rows = 50;
const max_workers = 6;
const photo_side = 2 * List.icon_size;
const fetch_budget: std.Io.Duration = .fromSeconds(5);
const section = "[sources.inca]";

const icon_names = [_][:0]const u8{ "avatar-default-symbolic", "x-office-contact" };

const People = tallied.Tallied(Person);
const Symbols = std.EnumArray(inca.Field, [:0]const u8);

const Person = struct {
    portrait: ?*Portrait,
    details: []const inca.Detail,
};

const Portrait = struct {
    photo: inca.Photo,
    state: State = .new,
    texture: ?*c.GdkTexture = null,

    const State = enum { new, queued, working, done };
};

const Work = struct {
    portrait: *Portrait,
    title: []const u8,
    origin: Origin,
};

const Origin = union(enum) {
    bytes: inca.Embedded,
    file: []const u8,
    link: Link,
};

const Link = struct {
    url: []const u8,
    stem: [16]u8,
};

const Ordered = struct {
    order: []const u8,
    item: People.Item,

    fn before(_: void, left: Ordered, right: Ordered) bool {
        return std.mem.order(u8, left.order, right.order) == .lt;
    }
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
    symbols: Symbols,
    limits: command.Limits = .{},
    loading: std.Io.Mutex = .init,
    loaded: bool = false,
    absent: bool = false,
    warned: bool = false,
    cache: ?[]const u8 = null,
    listing: icons.Listing = .{},
    drawing: std.Io.Mutex = .init,
    textures: std.ArrayList(*c.GdkTexture) = .empty,
    queue: std.ArrayList(Work) = .empty,
    next: usize = 0,
    workers: usize = 0,
    arrived: bool = false,
    client: std.http.Client,
    fetches: std.Io.Group = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Search),
        };
    }

    pub fn phonebook(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Phonebook),
        };
    }

    pub fn counters(self: *Index, id: u64) ?rank.Weight {
        return self.people.counters(id);
    }

    pub fn forget(self: *Index, id: u64) void {
        self.people.forget(id);
    }

    pub fn choose(_: *Index, _: Allocator, _: u64) subroutines.Outcome {
        return .keep;
    }

    pub fn actions(
        self: *Index,
        arena: Allocator,
        id: u64,
    ) subroutines.Error![]const subroutines.Action {
        const person = self.people.find(id) orelse return &.{};

        const listed = try arena.alloc(subroutines.Action, person.payload.details.len);
        for (person.payload.details, listed, 0..) |detail, *action, at| {
            action.* = .{
                .id = at,
                .title = detail.title,
                .detail = detail.caption,
                .icon = .{ .name = self.symbols.get(detail.field) },
            };
        }
        return listed;
    }

    pub fn perform(self: *Index, gpa: Allocator, id: u64, action: u64) subroutines.Outcome {
        const detail = self.detailAt(id, action) orelse return .keep;
        if (!copy.put(gpa, self.environ, .{ .bytes = detail.value })) return .keep;

        self.people.note(id);
        return .close;
    }

    fn detailAt(self: *Index, id: u64, action: u64) ?inca.Detail {
        const person = self.people.find(id) orelse return null;
        const at = std.math.cast(usize, action) orelse return null;
        if (at >= person.payload.details.len) return null;
        return person.payload.details[at];
    }

    pub fn stop(self: *Index) void {
        self.drawing.lockUncancelable(self.io);
        self.stopping.store(true, .release);
        self.drawing.unlock(self.io);

        self.fetches.cancel(self.io);
    }

    pub fn retire(self: *Index) void {
        self.stop();
        self.client.deinit();
        for (self.textures.items) |texture| glib.g_object_unref(texture);
        self.textures.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.people.retire();
        self.arena.deinit();
    }

    fn rows(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
        options: tallied.Options,
        noted: bool,
    ) subroutines.Error!subroutines.Output {
        const found = try self.people.hits(owner, text, options);
        const hits = switch (found) {
            .hits => |hits| hits,
            else => return found,
        };
        return .{ .hits = try self.portrayed(owner, hits, noted) };
    }

    fn load(self: *Index, asked: bool) void {
        self.loading.lock(self.io) catch return;
        defer self.loading.unlock(self.io);

        if (!self.loaded) {
            self.loaded = true;
            self.read();
        }
        if (asked and self.absent and !self.warned) {
            self.warned = true;
            log.warn("there is no {s} in $PATH, so the phonebook lists no contacts", .{inca.program});
        }
    }

    fn read(self: *Index) void {
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
                defer self.people.discard(catalog);
                return log.warn("\"{f}\" {f}, so no contacts are listed", .{
                    command.Line{ .program = self.program, .arguments = &inca.arguments },
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
        self.absent = true;
        if (self.configured) {
            self.warned = true;
            return log.warn("{s} exec is {s}, which does not exist, so no contacts are listed", .{
                section,
                self.program,
            });
        }
        if (self.required) {
            self.warned = true;
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
        noted: bool,
    ) subroutines.Error![]const subroutines.Hit {
        const scratch = owner.allocator();
        const listed = try scratch.dupe(subroutines.Hit, hits);
        const ids = try scratch.alloc(u64, hits.len);

        self.drawing.lockUncancelable(self.io);
        defer self.drawing.unlock(self.io);

        for (listed, ids, 0..) |*hit, *id, at| {
            id.* = hit.row.id;
            const person = self.people.find(hit.row.id) orelse continue;
            const portrait = person.payload.portrait orelse continue;
            const texture = self.textureOf(person.title, portrait, at < max_rows) orelse continue;
            hit.row.icon = owner.keep(@ptrCast(glib.g_object_ref(texture).?));
        }
        if (noted) self.people.noteShown(ids);
        return listed;
    }

    fn textureOf(self: *Index, title: []const u8, portrait: *Portrait, now: bool) ?*c.GdkTexture {
        switch (portrait.state) {
            .new, .queued => {},
            .working, .done => return portrait.texture,
        }

        const origin = self.originOf(title, portrait.photo) orelse {
            portrait.state = .done;
            return null;
        };
        if (now) {
            switch (origin) {
                .bytes => |embedded| return self.finish(portrait, title, self.render(title, embedded.bytes, embedded.mime)),
                .file => |path| return self.finish(portrait, title, self.renderFile(title, path)),
                .link => {},
            }
        }

        if (portrait.state == .new) self.enqueue(.{ .portrait = portrait, .title = title, .origin = origin });
        return null;
    }

    fn originOf(self: *Index, title: []const u8, photo: inca.Photo) ?Origin {
        return switch (photo) {
            .embedded => |embedded| .{ .bytes = embedded },
            .broken => |mime| {
                log.warn("the {f}photo of \"{s}\" is not valid base64, so its row shows the generic icon", .{
                    Typed{ .mime = mime },
                    title,
                });
                return null;
            },
            .linked => |url| self.linkOf(title, url),
        };
    }

    fn linkOf(self: *Index, title: []const u8, url: []const u8) ?Origin {
        if (!icons.isRemote(url)) {
            log.warn("the photo of \"{s}\" is linked as {s}, and only http(s) links are fetched, " ++
                "so its row shows the generic icon", .{ title, url });
            return null;
        }
        if (self.cache == null) return null;

        const stem = icons.stemOf(url);
        const found = self.listing.get(&stem) orelse return .{ .link = .{ .url = url, .stem = stem } };
        return switch (found) {
            .file => |path| .{ .file = path },
            .failed => null,
        };
    }

    fn finish(self: *Index, portrait: *Portrait, title: []const u8, made: ?*c.GdkTexture) ?*c.GdkTexture {
        portrait.state = .done;
        portrait.texture = self.keep(title, made);
        return portrait.texture;
    }

    fn keep(self: *Index, title: []const u8, made: ?*c.GdkTexture) ?*c.GdkTexture {
        const texture = made orelse return null;
        self.textures.append(self.gpa, texture) catch {
            glib.g_object_unref(texture);
            log.warn("out of memory, so the photo of \"{s}\" is left out", .{title});
            return null;
        };
        return texture;
    }

    fn render(self: *Index, title: []const u8, bytes: []const u8, mime: []const u8) ?*c.GdkTexture {
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

        return picture.round(self.gpa, decoded.pixbuf) catch {
            log.warn("out of memory, so the photo of \"{s}\" is left out", .{title});
            return null;
        };
    }

    fn renderFile(self: *Index, title: []const u8, path: []const u8) ?*c.GdkTexture {
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
        return self.render(title, bytes, "");
    }

    fn enqueue(self: *Index, work: Work) void {
        if (self.stopping.load(.acquire)) return;

        self.queue.append(self.gpa, work) catch {
            work.portrait.state = .done;
            return log.warn("out of memory, so the photo of \"{s}\" is left out", .{work.title});
        };
        work.portrait.state = .queued;
        if (self.workers == max_workers) return;

        self.workers += 1;
        self.fetches.concurrent(self.io, serve, .{self}) catch |err| {
            self.workers -= 1;
            log.warn("cannot draw the photo of \"{s}\" in the background: {t}", .{ work.title, err });
        };
    }

    fn serve(self: *Index) void {
        var redraw = false;
        while (self.take(&redraw)) |work| self.paint(work);

        if (!redraw or self.stopping.load(.acquire)) return;
        if (self.published) |found| found.call(.{});
    }

    fn take(self: *Index, redraw: *bool) ?Work {
        self.drawing.lockUncancelable(self.io);
        defer self.drawing.unlock(self.io);

        while (self.next < self.queue.items.len and !self.stopping.load(.acquire)) {
            const work = self.queue.items[self.next];
            self.next += 1;
            if (work.portrait.state != .queued) continue;

            work.portrait.state = .working;
            return work;
        }

        self.workers -= 1;
        if (self.workers > 0) return null;

        self.queue.clearRetainingCapacity();
        self.next = 0;
        redraw.* = self.arrived;
        self.arrived = false;
        return null;
    }

    fn paint(self: *Index, work: Work) void {
        const made = switch (work.origin) {
            .bytes => |embedded| self.render(work.title, embedded.bytes, embedded.mime),
            .file => |path| self.renderFile(work.title, path),
            .link => |link| self.download(work.title, link),
        };

        self.drawing.lockUncancelable(self.io);
        defer self.drawing.unlock(self.io);

        if (self.finish(work.portrait, work.title, made) != null) self.arrived = true;
    }

    fn download(self: *Index, title: []const u8, link: Link) ?*c.GdkTexture {
        const dir = self.cache orelse return null;

        const fetched = icons.loadWithin(&self.client, self.gpa, self.io, link.url, icons.max_bytes, fetch_budget) catch |err| {
            if (!self.stopping.load(.acquire)) {
                log.warn("cannot fetch the photo of \"{s}\" from {s}: {t}", .{ title, link.url, err });
            }
            return null;
        };

        switch (fetched) {
            .image => |image| {
                defer self.gpa.free(image.bytes);

                icons.store(self.gpa, self.io, dir, &link.stem, image) catch |err| {
                    if (!self.stopping.load(.acquire)) {
                        log.warn("cannot keep the photo of \"{s}\" in {s}: {t}", .{ title, dir, err });
                    }
                };
                if (self.stopping.load(.acquire)) return null;
                return self.render(title, image.bytes, "");
            },
            .failed => |failure| {
                self.fail(dir, title, link, failure);
                return null;
            },
        }
    }

    fn fail(self: *Index, dir: []const u8, title: []const u8, link: Link, failure: icons.Failure) void {
        if (self.stopping.load(.acquire)) return;

        const marked = icons.mark(self.gpa, self.io, dir, &link.stem) catch |err| {
            if (self.stopping.load(.acquire)) return;
            log.warn("cannot fetch the photo of \"{s}\" from {s}: {f}, and cannot note that in {s}: {t}", .{
                title,
                link.url,
                failure,
                dir,
                err,
            });
            return;
        };
        defer self.gpa.free(marked);

        log.warn("cannot fetch the photo of \"{s}\" from {s}: {f}, so it is not tried again " ++
            "until {s} is deleted", .{
            title,
            link.url,
            failure,
            marked,
        });
    }
};

const Search = struct {
    pub const Context = Index;

    pub const choose = Index.choose;
    pub const actions = Index.actions;
    pub const perform = Index.perform;
    pub const counters = Index.counters;
    pub const forget = Index.forget;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        if (std.mem.trim(u8, text, " \t").len == 0) return .nothing;
        self.load(false);

        return self.rows(owner, text, .{
            .max_rows = max_rows,
            .icon = .{ .name = self.icon },
            .counted = false,
        }, true);
    }
};

const Phonebook = struct {
    pub const Context = Index;

    pub const choose = Index.choose;
    pub const actions = Index.actions;
    pub const perform = Index.perform;
    pub const counters = Index.counters;
    pub const forget = Index.forget;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        self.load(true);

        return self.rows(owner, text, .{
            .max_rows = std.math.maxInt(usize),
            .icon = .{ .name = self.icon },
            .counted = false,
            .extra = true,
            .idle = .chosen,
        }, std.mem.trim(u8, text, " \t").len > 0);
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
        .symbols = symbolsOf(),
        .client = .{ .allocator = context.gpa, .io = context.io },
    };
    self.people.prepare(context.store);
    return self;
}

fn itemsOf(arena: Allocator, contacts: []const inca.Contact) Allocator.Error![]People.Item {
    const ordered = try arena.alloc(Ordered, contacts.len);
    for (contacts, ordered) |contact, *slot| {
        slot.* = .{
            .order = try orderOf(arena, contact.title),
            .item = .{
                .key = contact.key,
                .title = contact.title,
                .detail = contact.detail,
                .fields = contact.fields,
                .extra = contact.numbers,
                .payload = .{
                    .portrait = try portraitOf(arena, contact.photo),
                    .details = contact.details,
                },
            },
        };
    }
    std.mem.sort(Ordered, ordered, {}, Ordered.before);

    const items = try arena.alloc(People.Item, ordered.len);
    for (ordered, items) |one, *item| item.* = one.item;
    return items;
}

fn orderOf(arena: Allocator, title: [:0]const u8) Allocator.Error![]const u8 {
    const folded = glib.g_utf8_casefold(title.ptr, -1);
    defer glib.g_free(folded);
    const key = glib.g_utf8_collate_key(folded, -1);
    defer glib.g_free(key);
    return arena.dupe(u8, std.mem.span(key));
}

fn symbolsOf() Symbols {
    var symbols: Symbols = .initUndefined();
    for (std.enums.values(inca.Field)) |field| symbols.set(field, subroutines.themedIcon(symbolNames(field)));
    return symbols;
}

fn symbolNames(field: inca.Field) []const [:0]const u8 {
    return switch (field) {
        .name, .nickname => &.{"avatar-default-symbolic"},
        .organization => &.{"system-users-symbolic"},
        .job_title => &.{ "identity-symbolic", "user-info-symbolic", "system-users-symbolic" },
        .email => &.{"mail-unread-symbolic"},
        .phone => &.{"call-start-symbolic"},
        .messaging => &.{ "dialog-messages-symbolic", "chat-message-new-symbolic", "mail-send-symbolic" },
        .social => &.{ "emblem-shared-symbolic", "web-browser-symbolic", "internet-web-browser-symbolic" },
        .address => &.{"mark-location-symbolic"},
        .website => &.{ "web-browser-symbolic", "internet-web-browser-symbolic", "applications-internet-symbolic" },
        .date => &.{ "x-office-calendar-symbolic", "view-calendar-symbolic", "appointment-new-symbolic" },
        .note => &.{ "note-symbolic", "text-x-generic-symbolic", "document-edit-symbolic" },
    };
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
    root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    script_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    cache_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
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
        self.script = try std.mem.print(&self.script_buffer, "{s}/inca", .{self.root});
        self.cache = try std.mem.print(&self.cache_buffer, "{s}/sysdeck/contacts", .{self.root});

        try self.environ.put("PATH", "/usr/bin:/bin");
        try self.environ.put("XDG_CACHE_HOME", self.root);

        const script = try testing.allocator.print("#!/bin/sh\necho start >> \"$0.log\"\n{s}\n", .{body});
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
        return switch (try Search.run(index, self.owner, query)) {
            .hits => |hits| hits,
            else => &.{},
        };
    }

    fn lookUp(self: *Rig, index: *Index, query: []const u8) ![]const subroutines.Hit {
        return switch (try Phonebook.run(index, self.owner, query)) {
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
        \\[{"key": "a", "formatted_name": "Jane Doe", "kind": "individual",
        \\  "emails": [{"labels": [], "value": "jane@example.com"}]},
        \\ {"key": "b", "formatted_name": "Max Mustermann", "kind": "individual"}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

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
    defer index.retire();

    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "jane")).len);
    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "max")).len);
    try testing.expectEqual(@as(usize, 1), try rig.starts());
}

test "an embedded photo becomes a round texture of 64 pixels at most" {
    const json = try testing.allocator.print(
        \\[{{"key": "a", "formatted_name": "Jane Doe", "kind": "individual",
        \\  "photo": {{"media_type": "image/png", "data": "{s}"}}}}]
    , .{red_png});
    defer testing.allocator.free(json);

    var rig: Rig = undefined;
    try rig.init(json);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

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
    defer index.retire();

    for ([_][]const u8{ "bare", "broken", "unknown" }) |query| {
        const row = try rig.rowOf(&index, query);
        try testing.expectEqualStrings(index.icon, row.icon.name);
    }
    try testing.expectEqual(@as(usize, 0), index.textures.items.len);
}

fn linkedJson(found: []const u8, gone: []const u8) ![]u8 {
    return testing.allocator.print(
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
    defer index.retire();

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
    defer index.retire();

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
    defer index.retire();

    _ = try rig.rows(&index, "person");
    try index.fetches.await(testing.io);

    try testing.expectEqual(@as(u32, 2), local.served.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), rig.published.count.load(.monotonic));
}

test "stopping a fetch that hangs returns at once and leaves no marker" {
    const address: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var silent = try address.listen(testing.io, .{ .reuse_address = true });
    defer silent.deinit(testing.io);

    const hung = try testing.allocator.print("http://127.0.0.1:{d}/photo.png", .{
        silent.socket.address.getPort(),
    });
    defer testing.allocator.free(hung);
    const json = try testing.allocator.print(
        \\[{{"key": "a", "formatted_name": "Hung Person", "kind": "individual", "photo": {{"uri": "{s}"}}}}]
    , .{hung});
    defer testing.allocator.free(json);

    var rig: Rig = undefined;
    try rig.init(json);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

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
    defer index.retire();

    try testing.expectEqualStrings(index.icon, (try rig.rowOf(&index, "local")).icon.name);
    try index.fetches.await(testing.io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(u32, 0), (try rig.listing(arena.allocator())).entries.count());
    try testing.expectEqual(@as(usize, 0), index.workers);
    try testing.expectEqual(@as(usize, 0), index.queue.items.len);
}

test "choosing a contact does nothing and counts nothing" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "Jane Doe", "kind": "individual"}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const jane = try rig.rowOf(&index, "jane");
    try testing.expectEqual(subroutines.Outcome.keep, index.choose(testing.allocator, jane.id));
    try testing.expectEqual(rank.Weight{ .shown = 1 }, index.counters(jane.id).?);
    try testing.expectEqualStrings("", index.subroutine().verb);
}

test "a contact's details are its actions, with an icon for each kind" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "Tom Ato", "kind": "individual",
        \\  "organization": "Vegetable Corp;Produce",
        \\  "emails": [{"labels": ["home"], "value": "tom.ato@example.com"}],
        \\  "phones": [{"labels": ["iphone", "cell"], "value": "+1-555-0101"}],
        \\  "impps": [{"labels": ["home"], "service": "skype", "value": "skype:tom.ato"}],
        \\  "notes": [{"labels": [], "value": "Prefers calls after 6 pm.\nAllergic to cats."}]}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const tom = try rig.rowOf(&index, "tom");
    const listed = try index.actions(arena.allocator(), tom.id);

    const Expected = struct { field: inca.Field, title: []const u8, detail: []const u8 };
    const wanted = [_]Expected{
        .{ .field = .name, .title = "Tom Ato", .detail = "Name" },
        .{ .field = .organization, .title = "Vegetable Corp, Produce", .detail = "Organization" },
        .{ .field = .email, .title = "tom.ato@example.com", .detail = "Email · home" },
        .{ .field = .phone, .title = "+1-555-0101", .detail = "Phone · iphone, cell" },
        .{ .field = .messaging, .title = "tom.ato", .detail = "Messaging · skype, home" },
        .{ .field = .note, .title = "Prefers calls after 6 pm. Allergic to cats.", .detail = "Note" },
    };

    try testing.expectEqual(wanted.len, listed.len);
    for (wanted, listed, 0..) |expected, action, at| {
        try testing.expectEqual(@as(u64, at), action.id);
        try testing.expectEqualStrings(expected.title, action.title);
        try testing.expectEqualStrings(expected.detail, action.detail);
        try testing.expectEqualStrings(index.symbols.get(expected.field), action.icon.name);
    }
    for (listed, 0..) |one, at| {
        for (listed[at + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, one.icon.name, other.icon.name));
    }
    try testing.expectEqualStrings("Prefers calls after 6 pm.\nAllergic to cats.", index.detailAt(tom.id, 5).?.value);
}

test "an unknown contact or action has nothing to copy" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "Jane Doe", "kind": "individual",
        \\  "emails": [{"labels": [], "value": "jane@example.com"}]}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const jane = try rig.rowOf(&index, "jane");
    try testing.expectEqualStrings("jane@example.com", index.detailAt(jane.id, 1).?.value);
    try testing.expectEqual(@as(?inca.Detail, null), index.detailAt(jane.id, 2));
    try testing.expectEqual(@as(?inca.Detail, null), index.detailAt(jane.id + 1, 0));

    try testing.expectEqual(@as(usize, 0), (try index.actions(arena.allocator(), jane.id + 1)).len);
    try testing.expectEqual(subroutines.Outcome.keep, index.perform(testing.allocator, jane.id, 2));
    try testing.expectEqual(@as(u32, 0), index.counters(jane.id).?.chosen);
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
    defer index.retire();

    const listed = try rig.rows(&index, "person");
    try testing.expectEqual(@as(usize, 50), listed.len);

    var counted: usize = 0;
    for (0..60) |at| {
        var key: [8]u8 = undefined;
        const id = @import("core").counts.id(try std.mem.print(&key, "k{d}", .{at}));
        counted += index.counters(id).?.shown;
    }
    try testing.expectEqual(@as(usize, 50), counted);
}

fn crowdJson(count: usize, photo: ?[]const u8) ![]u8 {
    var json: std.ArrayList(u8) = .empty;
    errdefer json.deinit(testing.allocator);

    try json.append(testing.allocator, '[');
    for (0..count) |at| {
        if (at > 0) try json.append(testing.allocator, ',');
        try json.print(testing.allocator, "{{\"key\": \"k{d}\", \"formatted_name\": \"Person {d:0>2}\"", .{ at, at });
        if (photo) |data| {
            try json.print(testing.allocator, ", \"photo\": {{\"media_type\": \"image/png\", \"data\": \"{s}\"}}", .{data});
        }
        try json.append(testing.allocator, '}');
    }
    try json.append(testing.allocator, ']');
    return json.toOwnedSlice(testing.allocator);
}

fn shownOf(index: *Index, count: usize) !u32 {
    var total: u32 = 0;
    for (0..count) |at| {
        var key: [8]u8 = undefined;
        const id = @import("core").counts.id(try std.mem.print(&key, "k{d}", .{at}));
        total += index.counters(id).?.shown;
    }
    return total;
}

test "the phonebook lists every contact, the most picked first, then by name" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "z", "formatted_name": "Zoe Zed", "kind": "individual"},
        \\ {"key": "a", "formatted_name": "adam ant", "kind": "individual"},
        \\ {"key": "b", "formatted_name": "Bert Bo", "kind": "individual"},
        \\ {"key": "c", "formatted_name": "Carl Cox", "kind": "individual"}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const counts = @import("core").counts;
    index.people.note(counts.id("c"));
    index.people.note(counts.id("c"));
    index.people.note(counts.id("z"));

    const listed = try rig.lookUp(&index, "");
    const wanted = [_][]const u8{ "Carl Cox", "Zoe Zed", "adam ant", "Bert Bo" };
    try testing.expectEqual(wanted.len, listed.len);
    for (wanted, listed) |title, hit| try testing.expectEqualStrings(title, hit.row.title);

    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "")).len);
}

test "contacts are sorted by name, ignoring case" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "zed", "kind": "individual"},
        \\ {"key": "b", "formatted_name": "Bert", "kind": "individual"},
        \\ {"key": "c", "formatted_name": "(no name)", "kind": "individual", "organization": "acme;Sales"},
        \\ {"key": "d", "formatted_name": "Anna", "kind": "individual"}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    _ = try rig.rows(&index, "x");

    const wanted = [_][]const u8{ "acme", "Anna", "Bert", "zed" };
    const items = index.people.current.items;
    try testing.expectEqual(wanted.len, items.len);
    for (wanted, items) |title, item| try testing.expectEqualStrings(title, item.title);
}

test "contacts are sorted by the locale's collation" {
    const categories = [_]std.c.LC{ .CTYPE, .COLLATE };
    var buffers: [categories.len][64]u8 = undefined;
    var previous: [categories.len][:0]const u8 = undefined;
    for (categories, &buffers, &previous) |category, *buffer, *slot| {
        const current = std.c.setlocale(category, null) orelse return error.SkipZigTest;
        slot.* = try std.mem.printSentinel(buffer, "{s}", .{std.mem.span(current)}, 0);
    }
    defer for (categories, previous) |category, name| {
        _ = std.c.setlocale(category, name);
    };

    const available = for ([_][:0]const u8{ "en_US.UTF-8", "de_DE.UTF-8" }) |name| {
        if (std.c.setlocale(.COLLATE, name) == null) continue;
        if (std.c.setlocale(.CTYPE, name) != null) break true;
    } else false;
    if (!available) return error.SkipZigTest;

    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "Zoe", "kind": "individual"},
        \\ {"key": "b", "formatted_name": "Émile", "kind": "individual"},
        \\ {"key": "c", "formatted_name": "adam", "kind": "individual"}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const wanted = [_][]const u8{ "adam", "Émile", "Zoe" };
    const listed = try rig.lookUp(&index, "");
    try testing.expectEqual(wanted.len, listed.len);
    for (wanted, listed) |title, hit| try testing.expectEqualStrings(title, hit.row.title);
}

test "a typed number finds a contact in the phonebook and not in the search" {
    var rig: Rig = undefined;
    try rig.init(
        \\[{"key": "a", "formatted_name": "Tom Ato", "kind": "individual",
        \\  "phones": [{"labels": ["cell"], "value": "+1-555-0101"}]},
        \\ {"key": "b", "formatted_name": "Max Mustermann", "kind": "individual"}]
    );
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    try testing.expectEqual(@as(usize, 0), (try rig.rows(&index, "0101")).len);

    const found = try rig.lookUp(&index, "0101");
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("Tom Ato", found[0].row.title);
}

test "the overview counts nothing as shown, a typed query counts what it lists" {
    const json = try crowdJson(60, null);
    defer testing.allocator.free(json);

    var rig: Rig = undefined;
    try rig.init(json);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    try testing.expectEqual(@as(usize, 60), (try rig.lookUp(&index, "")).len);
    try testing.expectEqual(@as(u32, 0), try shownOf(&index, 60));

    try testing.expectEqual(@as(usize, 60), (try rig.lookUp(&index, "person")).len);
    try testing.expectEqual(@as(u32, 60), try shownOf(&index, 60));
}

test "the first 50 photos are drawn at once, the rest in the background, then one redraw" {
    const json = try crowdJson(52, red_png);
    defer testing.allocator.free(json);

    var rig: Rig = undefined;
    try rig.init(json);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const first = try rig.lookUp(&index, "");
    try testing.expectEqual(@as(usize, 52), first.len);
    for (first, 0..) |hit, at| try testing.expectEqual(at < max_rows, hit.row.icon == .gicon);

    try index.fetches.await(testing.io);
    try testing.expectEqual(@as(u32, 1), rig.published.count.load(.monotonic));
    try testing.expectEqual(@as(usize, 52), index.textures.items.len);

    for (try rig.lookUp(&index, "")) |hit| try testing.expect(hit.row.icon == .gicon);
}

test "linked photos are fetched by six workers at most" {
    const address: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var silent = try address.listen(testing.io, .{ .reuse_address = true });
    defer silent.deinit(testing.io);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(testing.allocator);
    try json.append(testing.allocator, '[');
    for (0..10) |at| {
        if (at > 0) try json.append(testing.allocator, ',');
        try json.print(testing.allocator,
            \\{{"key": "k{d}", "formatted_name": "Person {d}", "photo": {{"uri": "http://127.0.0.1:{d}/p{d}.png"}}}}
        , .{ at, at, silent.socket.address.getPort(), at });
    }
    try json.append(testing.allocator, ']');

    var rig: Rig = undefined;
    try rig.init(json.items);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    _ = try rig.lookUp(&index, "");
    try testing.io.sleep(.fromMilliseconds(200), .awake);

    {
        index.drawing.lockUncancelable(testing.io);
        defer index.drawing.unlock(testing.io);

        try testing.expectEqual(@as(usize, max_workers), index.workers);
        try testing.expectEqual(@as(usize, max_workers), index.next);
        try testing.expectEqual(@as(usize, 10), index.queue.items.len);
    }

    index.stop();
    try testing.expectEqual(@as(u32, 0), rig.published.count.load(.monotonic));
}

test "a typed query draws a photo still waiting in the queue at once" {
    const address: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var silent = try address.listen(testing.io, .{ .reuse_address = true });
    defer silent.deinit(testing.io);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(testing.allocator);
    try json.append(testing.allocator, '[');
    for (0..max_workers) |at| {
        try json.print(testing.allocator,
            \\{{"key": "a{d}", "formatted_name": "Aaron {d}", "photo": {{"uri": "http://127.0.0.1:{d}/a{d}.png"}}}},
        , .{ at, at, silent.socket.address.getPort(), at });
    }
    for (0..max_rows) |at| try json.print(testing.allocator, "{{\"key\": \"b{d}\", \"formatted_name\": \"Bob {d:0>2}\"}},", .{ at, at });
    try json.print(testing.allocator,
        \\{{"key": "z", "formatted_name": "Zed", "photo": {{"media_type": "image/png", "data": "{s}"}}}}]
    , .{red_png});

    var rig: Rig = undefined;
    try rig.init(json.items);
    defer rig.deinit();

    var index = try rig.open();
    defer index.retire();

    const overview = try rig.lookUp(&index, "");
    try testing.expectEqualStrings("Zed", overview[overview.len - 1].row.title);
    try testing.expectEqualStrings(index.icon, overview[overview.len - 1].row.icon.name);
    try testing.io.sleep(.fromMilliseconds(200), .awake);

    const typed = try rig.lookUp(&index, "zed");
    try testing.expectEqual(@as(usize, 1), typed.len);
    try testing.expectEqual(@as(c_int, 64), gdk.gdk_texture_get_width(textureOfRow(typed[0].row)));

    index.stop();
}

fn bytesOf(text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const bytes = try testing.allocator.alloc(u8, try decoder.calcSizeForSlice(text));
    try decoder.decode(bytes, text);
    return bytes;
}
