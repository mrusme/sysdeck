const std = @import("std");
const answer_mod = @import("answer.zig");
const c = @import("c.zig");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const context_mod = @import("context.zig");
const deck_mod = @import("deck.zig");
const dispatch_mod = @import("dispatch.zig");
const extensions = @import("extensions.zig");
const keys_mod = @import("keys.zig");
const list_mod = @import("list.zig");
const source_mod = @import("source.zig");
const store_mod = @import("store.zig");
const subroutines = @import("subroutines.zig");
const terminal_mod = @import("terminal.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.default);

const member_count = 6;

const search_members = 5;

const Submode = enum { search, windows };

const Session = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    settings: *const config_mod.Config,
    settings_at: ?i64,
    bindings: keys_mod.Bindings,
    lines: u16,
    deck: deck_mod.Deck,
    dispatch: dispatch_mod.Dispatch = undefined,
    members: [member_count]subroutines.Subroutine = undefined,
    arrived: [member_count]?subroutines.Output = @splat(null),
    apps: subroutines.apps.Index = undefined,
    bins: subroutines.bins.Index = undefined,
    bookmarks: subroutines.bookmarks.Index = undefined,
    markdown: subroutines.bookmarks.markdown.Adapter = undefined,
    chromium: subroutines.bookmarks.chromium.Adapter = undefined,
    firefox: subroutines.bookmarks.firefox.Adapter = undefined,
    adapters: std.ArrayList(subroutines.bookmarks.Adapter) = .empty,
    processes: subroutines.processes.Index = undefined,
    whats: subroutines.whats.Index = undefined,
    sway: ?subroutines.sway.Index = null,
    submode: Submode = .search,
    total: usize = search_members,
    terminal: ?terminal_mod.Terminal = null,
    store: ?*store_mod.Store = null,
    manager: extensions.Manager = undefined,
    panes: std.ArrayList(extensions.Extension) = .empty,
    man: extensions.man.Extension = undefined,
    refreshing: std.atomic.Value(usize) = .init(0),
    query: std.ArrayList(u8) = .empty,
    context: ?*context_mod.Context = null,
    selected: ?u64 = null,
    holding: bool = false,
    completing: bool = false,
    launched: bool = false,

    fn present(self: *Session, what: dispatch_mod.Presentation) void {
        switch (what) {
            .rows => |rows| self.setRows(rows),
            .answer => |text| self.setAnswer(text),
        }
    }

    fn setRows(self: *Session, wanted: []const list_mod.Row) void {
        if (wanted.len == 0) {
            self.selected = null;
            self.manager.select(null);
            self.deck.setBody(null);
            return self.syncContext();
        }

        defer self.syncContext();
        defer self.suggest(wanted[0].title);

        const body = self.list() orelse block: {
            const made = list_mod.List.create(self.gpa, self.lines, .{
                .call = &onChosen,
                .context = self,
            }) catch {
                log.err("out of memory while building the list", .{});
                return;
            };
            made.selected = .{ .call = &onSelected, .context = self };
            made.killed = .{ .call = &onKilled, .context = self };
            made.focused = .{ .call = &onFocused, .context = self };
            self.deck.setBody(.{ .list = made });
            break :block made;
        };

        body.setRows(wanted);
    }

    fn setAnswer(self: *Session, text: [:0]const u8) void {
        self.selected = null;
        self.manager.select(null);
        defer self.syncContext();

        const body = self.answer() orelse block: {
            const made = answer_mod.Answer.create(self.gpa, .{
                .call = &onCopied,
                .context = self,
            }) catch {
                log.err("out of memory while building the answer", .{});
                return;
            };
            self.deck.setBody(.{ .answer = made });
            break :block made;
        };

        body.setText(text);
    }

    // The context belongs to whatever the results list has selected, so it is
    // rebuilt when that changes under it.
    fn syncContext(self: *Session) void {
        const current = self.context orelse return;

        if (!self.holding or self.deck.closing) return current.close(&self.deck);

        const id = self.selected orelse return current.close(&self.deck);
        const found = self.dispatch.actions(current.begin(), id);
        if (found.len == 0) return current.close(&self.deck);

        current.open(&self.deck, id, found);
    }

    fn apply(self: *Session, outcome: subroutines.Outcome) void {
        switch (outcome) {
            .close => {
                self.launched = true;
                self.deck.close();
            },
            .keep => {},
            .query => |text| {
                defer self.gpa.free(text);
                self.deck.setText(text);
                self.dispatch.schedule(text, .now);
            },
        }
    }

    fn createAdapters(self: *Session) void {
        const index = self.settings.index;
        const home = self.environ.get("HOME") orelse "";
        const markdown = self.settings.bookmarks.markdown;
        const chromium = self.settings.bookmarks.chromium;
        const firefox = self.settings.bookmarks.firefox;

        if (markdown.files.len > 0) {
            self.markdown = .{
                .io = self.io,
                .home = home,
                .files = markdown.files,
                .max_age_minutes = index.age(markdown.max_age_minutes),
            };
            self.adapters.append(self.gpa, self.markdown.adapter()) catch {
                log.warn("out of memory, so the markdown bookmarks are left out", .{});
            };
        }

        if (chromium.files.len > 0) {
            self.chromium = .{
                .io = self.io,
                .home = home,
                .files = chromium.files,
                .max_age_minutes = index.age(chromium.max_age_minutes),
            };
            self.adapters.append(self.gpa, self.chromium.adapter()) catch {
                log.warn("out of memory, so the chromium bookmarks are left out", .{});
            };
        }

        if (firefox.files.len > 0) {
            self.firefox = .{
                .io = self.io,
                .home = home,
                .files = firefox.files,
                .max_age_minutes = index.age(firefox.max_age_minutes),
            };
            self.adapters.append(self.gpa, self.firefox.adapter()) catch {
                log.warn("out of memory, so the firefox bookmarks are left out", .{});
            };
        }
    }

    fn createPanes(self: *Session) void {
        if (self.settings.extensions.man.enable) {
            self.man = .create(self.bindings.manual);
            self.panes.append(self.gpa, self.man.extension()) catch {
                log.warn("out of memory, so the man extension is left out", .{});
            };
        }

        self.manager = .{ .gpa = self.gpa, .members = self.panes.items };
    }

    fn openStore(self: *Session) void {
        const path = store_mod.defaultPath(self.gpa, self.environ) catch null orelse return;
        defer self.gpa.free(path);

        self.store = store_mod.Store.open(self.gpa, self.io, path) catch |err| {
            log.warn("cannot open {s}: {t}, so the indexes are not kept", .{ path, err });
            return;
        };
    }

    fn startRefreshes(self: *Session) void {
        for (self.members[0..self.total], 0..) |member, at| {
            if (!member.stale()) continue;

            _ = self.refreshing.fetchAdd(1, .acquire);
            const worker = std.Thread.spawn(.{}, work, .{ self, member }) catch |err| {
                log.warn("cannot refresh member {d}: {t}", .{ at, err });
                _ = self.refreshing.fetchSub(1, .release);
                continue;
            };
            worker.detach();
        }
    }

    // Finishing what was typed only makes sense while it is being typed
    // forward.
    fn suggest(self: *Session, title: [:0]const u8) void {
        if (!self.completing) return;

        // Results arrive one subroutine at a time, so the first top row may
        // not be the one that finishes the word. Later ones still get a turn.
        const typed = self.query.items;
        if (typed.len == 0 or title.len <= typed.len) return;
        if (!std.ascii.startsWithIgnoreCase(title, typed)) return;

        self.completing = false;
        self.deck.setText(title);
        self.deck.selectRange(@intCast(typed.len), -1);
    }

    fn remember(self: *Session, text: []const u8) void {
        self.query.clearRetainingCapacity();
        self.query.appendSlice(self.gpa, text) catch self.query.clearRetainingCapacity();
    }

    fn enter(self: *Session, wanted: Submode) bool {
        if (self.sway == null or self.submode == wanted) return true;

        self.submode = wanted;
        self.manager.select(null);
        self.deck.setBody(null);

        switch (wanted) {
            .search => self.dispatch.setMembers(
                self.members[0..search_members],
                self.arrived[0..search_members],
            ),
            .windows => self.dispatch.setMembers(
                self.members[search_members..member_count],
                self.arrived[search_members..member_count],
            ),
        }

        self.deck.setText("");
        self.remember("");
        self.dispatch.schedule("", .now);
        return true;
    }

    fn list(self: *Session) ?*list_mod.List {
        return switch (self.deck.body orelse return null) {
            .list => |current| current,
            else => null,
        };
    }

    fn answer(self: *Session) ?*answer_mod.Answer {
        return switch (self.deck.body orelse return null) {
            .answer => |current| current,
            else => null,
        };
    }
};

pub fn run(
    init: std.process.Init,
    settings: *const config_mod.Config,
    settings_at: ?i64,
    options: cli.Options,
) bool {
    // Non-unique, because every invocation is its own popup rather than being
    // handed to whichever instance is already running.
    const app = c.gtk_application_new(null, c.application_non_unique);
    defer c.g_object_unref(app);

    const bindings: keys_mod.Bindings = .from(&settings.keys);

    var session: Session = .{
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .io = init.io,
        .environ = init.environ_map,
        .settings = settings,
        .settings_at = settings_at,
        .bindings = bindings,
        .lines = options.lines,
        .deck = .{ .app = app, .prompt = options.prompt, .held = bindings.context },
    };

    session.openStore();
    defer if (session.store) |found| found.close();

    _ = c.connect(app, "activate", &onActivate, &session);
    _ = c.g_application_run(c.cast(c.GApplication, app), 0, null);

    session.manager.stop();
    session.dispatch.stop();
    if (session.context) |found| found.destroy();
    while (session.refreshing.load(.acquire) != 0) std.Thread.yield() catch {};
    session.deck.setBody(null);
    for (session.members[0..session.total]) |member| member.retire(session.store);
    session.adapters.deinit(init.gpa);
    session.panes.deinit(init.gpa);
    session.query.deinit(init.gpa);
    if (session.terminal) |found| found.deinit(init.gpa);
    if (session.sway) |found| init.gpa.free(found.socket_path);
    return session.launched;
}

fn onActivate(app: *c.GtkApplication, data: c.gpointer) callconv(.c) void {
    const self: *Session = @ptrCast(@alignCast(data.?));

    self.terminal = terminal_mod.resolve(
        self.gpa,
        self.environ,
        self.settings.terminal.command,
    ) catch null;

    const index = self.settings.index;
    const stamp = store_mod.now(self.io);
    const published: source_mod.Published = .{ .notify = &onPublished, .context = self };

    self.apps = subroutines.apps.open(
        self.gpa,
        self.store,
        index.maxAge(index.apps),
        stamp,
        published,
    ) catch {
        log.err("out of memory while opening the apps index", .{});
        c.g_application_quit(c.cast(c.GApplication, app));
        return;
    };

    self.bins = subroutines.bins.open(
        self.gpa,
        self.io,
        self.environ,
        self.terminal,
        self.store,
        index.maxAge(index.bins),
        stamp,
        published,
    ) catch {
        log.err("out of memory while opening the executables index", .{});
        c.g_application_quit(c.cast(c.GApplication, app));
        return;
    };

    self.createAdapters();
    self.bookmarks = subroutines.bookmarks.open(
        self.gpa,
        self.environ,
        self.adapters.items,
        self.store,
        stamp,
        self.settings_at,
        published,
    ) catch {
        log.err("out of memory while opening the bookmarks index", .{});
        c.g_application_quit(c.cast(c.GApplication, app));
        return;
    };

    self.processes = .{ .io = self.io };
    self.whats = .{ .gpa = self.gpa, .io = self.io, .environ = self.environ };

    if (subroutines.sway.enabled(self.settings.sources.sway.enable, self.environ)) {
        self.sway = subroutines.sway.open(self.gpa, self.environ) catch null;
    }

    self.members[0] = self.apps.subroutine();
    self.members[1] = self.bins.subroutine();
    self.members[2] = self.bookmarks.subroutine();
    self.members[3] = self.processes.subroutine();
    self.members[4] = self.whats.subroutine();
    if (self.sway) |*found| {
        self.members[5] = found.subroutine();
        self.total = member_count;
    }
    self.dispatch = .{
        .gpa = self.gpa,
        .members = self.members[0..search_members],
        .arrived = self.arrived[0..search_members],
        .display = .{ .call = &onDisplay, .context = self },
    };

    self.context = context_mod.Context.create(self.gpa, self.lines, .{
        .call = &onPerformed,
        .context = self,
    }) catch |err| block: {
        log.warn("cannot build the context list: {t}", .{err});
        break :block null;
    };

    self.createPanes();
    self.startRefreshes();
    self.deck.keys = .{ .call = &onKey, .context = self };
    self.deck.holding = .{ .call = &onHolding, .context = self };
    self.deck.present(.{ .call = &onChanged, .context = self }, null);
    self.manager.attach(self.deck.extras);
    if (self.context) |found| self.deck.attachContext(found.widget());
}

fn work(self: *Session, member: subroutines.Subroutine) void {
    defer _ = self.refreshing.fetchSub(1, .release);
    member.refresh();
}

fn onPublished(context: *anyopaque) void {
    _ = c.g_idle_add(&onIdlePublished, context);
}

fn onIdlePublished(data: c.gpointer) callconv(.c) c.gboolean {
    const self: *Session = @ptrCast(@alignCast(data.?));
    if (!self.deck.closing) self.dispatch.schedule(self.deck.typed(), .now);
    return c.source_remove;
}

fn onChanged(context: *anyopaque, text: []const u8) void {
    const self: *Session = @ptrCast(@alignCast(context));

    const previous = self.query.items;
    self.completing = text.len > previous.len and std.mem.startsWith(u8, text, previous);

    self.remember(text);
    self.dispatch.schedule(text, .debounced);
}

fn onDisplay(context: *anyopaque, what: dispatch_mod.Presentation) void {
    const self: *Session = @ptrCast(@alignCast(context));
    self.present(what);
}

fn onCopied(context: *anyopaque) void {
    const self: *Session = @ptrCast(@alignCast(context));
    self.launched = true;
    self.deck.close();
}

fn onSelected(context: *anyopaque, id: ?u64) void {
    const self: *Session = @ptrCast(@alignCast(context));

    self.selected = id;

    const found = id orelse return self.manager.select(null);

    if (self.deck.navigating) {
        if (self.dispatch.rowOf(found)) |row| {
            self.deck.setText(row.title);
            self.deck.selectAll();
            self.remember(row.title);
        }
    }

    self.manager.select(self.dispatch.target(found));
}

fn onKey(context: *anyopaque, keyval: c.guint, state: c.GdkModifierType) bool {
    const self: *Session = @ptrCast(@alignCast(context));

    if (self.bindings.windows.matches(keyval, state)) return self.enter(.windows);
    if (self.bindings.search.matches(keyval, state)) return self.enter(.search);

    if (self.context) |found| {
        if (found.key(keyval)) return true;
    }

    return self.manager.key(keyval, state);
}

fn onHolding(context: *anyopaque, held: bool) void {
    const self: *Session = @ptrCast(@alignCast(context));
    if (held == self.holding) return;

    self.holding = held;
    self.syncContext();
}

fn onPerformed(context: *anyopaque, row: u64, action: u64) void {
    const self: *Session = @ptrCast(@alignCast(context));
    self.apply(self.dispatch.perform(row, action));
}

fn onFocused(context: *anyopaque, pid: i32, id: u64) void {
    const self: *Session = @ptrCast(@alignCast(context));

    const sway = if (self.sway) |*found| found else return;

    // The pid that was clicked may not be the one holding the window, so the
    // other pids on the same row get a turn before giving up.
    var pids: std.ArrayList(i32) = .empty;
    defer pids.deinit(self.gpa);

    pids.append(self.gpa, pid) catch return;
    if (self.dispatch.rowOf(id)) |row| {
        for (row.badges) |worn| {
            if (worn.pid != pid) pids.append(self.gpa, worn.pid) catch break;
        }
    }

    const con = sway.windowFor(self.gpa, pids.items) orelse {
        log.warn("no sway window belongs to {d}", .{pid});
        return;
    };
    if (!sway.focusWindow(self.gpa, con)) return;

    self.launched = true;
    self.deck.close();
}

fn onKilled(context: *anyopaque, pid: i32) void {
    const self: *Session = @ptrCast(@alignCast(context));

    _ = self.processes.subroutine().choose(self.gpa, @intCast(pid));
    self.dispatch.schedule(self.deck.typed(), .now);
}

fn onChosen(context: *anyopaque, id: u64) void {
    const self: *Session = @ptrCast(@alignCast(context));
    self.apply(self.dispatch.choose(id));
}
