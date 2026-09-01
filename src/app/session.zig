const std = @import("std");
const answer_mod = @import("../ui/answer.zig");
const bench_mod = @import("bench.zig");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const cli = @import("../cli.zig");
const config_mod = @import("../config.zig");
const context_mod = @import("../ui/context.zig");
const deck_mod = @import("../ui/deck.zig");
const dispatch_mod = @import("dispatch.zig");
const keys_mod = @import("../ui/keys.zig");
const list_mod = @import("../ui/list.zig");
const overlay_mod = @import("../screenshot/overlay.zig");
const panes_mod = @import("panes.zig");
const shot_mod = @import("shot.zig");
const source_mod = @import("../subroutines/source.zig");
const subroutines = @import("../subroutines.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.default);

const Submode = bench_mod.Submode;

const Session = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    settings: *const config_mod.Config,
    settings_at: ?i64,
    bindings: keys_mod.Bindings,
    lines: u16,
    deck: deck_mod.Deck,
    dispatch: dispatch_mod.Dispatch,
    bench: ?*bench_mod.Bench = null,
    panes: ?*panes_mod.Panes = null,
    shot: ?*shot_mod.Shot = null,
    submode: Submode = .search,
    query: std.ArrayList(u8) = .empty,
    context: ?*context_mod.Context = null,
    selected: ?u64 = null,
    holding: bool = false,
    completing: bool = false,
    launched: bool = false,

    fn build(self: *Session) !void {
        const published: source_mod.Published = .{ .notify = &onPublished, .context = self };

        self.bench = try bench_mod.Bench.create(
            self.gpa,
            self.io,
            self.environ,
            self.settings,
            self.settings_at,
            published,
            .{ .call = &onShotRequested, .context = self },
        );

        self.shot = try shot_mod.Shot.create(
            self.gpa,
            self.io,
            self.environ,
            self.settings.screenshot,
            &self.deck,
            if (self.bench.?.sway) |*found| found else null,
            .{ .call = &onShotFinished, .context = self },
        );

        self.panes = try panes_mod.Panes.create(
            self.gpa,
            self.io,
            self.environ,
            self.settings,
            self.bindings,
        );
    }

    fn teardown(self: *Session) void {
        if (self.bench) |found| found.waitRefreshes();
        self.dispatch.stop();
        if (self.shot) |found| found.destroy();
        if (self.panes) |found| found.destroy();
        if (self.bench) |found| found.destroy();
        self.query.deinit(self.gpa);
    }

    fn select(self: *Session, target: ?dispatch_mod.Target) void {
        const found = self.panes orelse return;
        found.select(target);
    }

    fn present(self: *Session, what: dispatch_mod.Presentation) void {
        switch (what) {
            .rows => |rows| self.setRows(rows),
            .answer => |text| self.setAnswer(text),
        }
    }

    fn setRows(self: *Session, wanted: []const list_mod.Row) void {
        if (wanted.len == 0) {
            self.selected = null;
            self.select(null);
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
        self.select(null);
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

    fn suggest(self: *Session, title: [:0]const u8) void {
        if (!self.completing) return;

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

    fn show(self: *Session, wanted: Submode) void {
        const found = self.bench orelse return;
        const range = found.rangeOf(wanted);

        self.submode = wanted;
        self.dispatch.setMembers(found.membersOf(range), found.arrivedOf(range));
    }

    fn enter(self: *Session, wanted: Submode) bool {
        const found = self.bench orelse return false;
        if (found.rangeOf(wanted).empty() or self.submode == wanted) return true;

        self.select(null);
        self.deck.setBody(null);
        self.show(wanted);

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
    const app = gtk.gtk_application_new(null, c.application_non_unique);
    defer glib.g_object_unref(app);

    const bindings: keys_mod.Bindings = .from(&settings.keys);

    var session: Session = .{
        .gpa = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
        .settings = settings,
        .settings_at = settings_at,
        .bindings = bindings,
        .lines = options.lines,
        .deck = .{ .app = app, .prompt = options.prompt, .held = bindings.context },
        .dispatch = .init(init.gpa, init.io),
        .submode = switch (options.start) {
            .search => .search,
            .history => .history,
        },
    };
    session.dispatch.display = .{ .call = &onDisplay, .context = &session };
    defer session.teardown();

    _ = c.connect(app, "activate", &onActivate, &session);
    _ = glib.g_application_run(c.cast(c.GApplication, app), 0, null);

    return session.launched;
}

fn onActivate(app: *c.GtkApplication, data: c.gpointer) callconv(.c) void {
    const self: *Session = @ptrCast(@alignCast(data.?));

    self.build() catch |err| {
        log.err("cannot build the session: {t}", .{err});
        glib.g_application_quit(c.cast(c.GApplication, app));
        return;
    };

    const bench = self.bench.?;
    const panes = self.panes.?;

    if (bench.rangeOf(self.submode).empty()) self.submode = .search;
    self.show(self.submode);

    self.context = context_mod.Context.create(self.gpa, self.lines, .{
        .call = &onPerformed,
        .context = self,
    }) catch |err| block: {
        log.warn("cannot build the context list: {t}", .{err});
        break :block null;
    };

    bench.startRefreshes();
    self.deck.keys = .{ .call = &onKey, .context = self };
    self.deck.holding = .{ .call = &onHolding, .context = self };
    self.deck.present(.{ .call = &onChanged, .context = self }, null);
    panes.attach(self.deck.extras);
    if (self.context) |found| self.deck.attachContext(found.widget());

    if (self.submode != .search) self.dispatch.schedule("", .now);
}

fn onPublished(context: *anyopaque) void {
    _ = glib.g_idle_add(&onIdlePublished, context);
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

    const found = id orelse return self.select(null);

    if (self.deck.navigating) {
        if (self.dispatch.rowOf(found)) |row| {
            self.deck.setText(row.title);
            self.deck.selectAll();
            self.remember(row.title);
        }
    }

    self.select(self.dispatch.target(found));
}

fn onKey(context: *anyopaque, keyval: c.guint, state: c.GdkModifierType) bool {
    const self: *Session = @ptrCast(@alignCast(context));

    if (self.bindings.windows.matches(keyval, state)) return self.enter(.windows);
    if (self.bindings.search.matches(keyval, state)) return self.enter(.search);
    if (self.bindings.history.matches(keyval, state)) return self.enter(.history);

    if (self.context) |found| {
        if (found.key(keyval)) return true;
    }

    const panes = self.panes orelse return false;
    return panes.key(keyval, state);
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

    const bench = self.bench orelse return;
    const sway = if (bench.sway) |*found| found else return;

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

    const bench = self.bench orelse return;
    _ = bench.processes.subroutine().choose(self.gpa, @intCast(pid));
    self.dispatch.schedule(self.deck.typed(), .now);
}

fn onChosen(context: *anyopaque, id: u64) void {
    const self: *Session = @ptrCast(@alignCast(context));
    self.apply(self.dispatch.choose(id));
}

fn onShotRequested(context: *anyopaque, mode: overlay_mod.Mode) void {
    const self: *Session = @ptrCast(@alignCast(context));

    const found = self.shot orelse return;
    found.begin(mode);
}

fn onShotFinished(context: *anyopaque, taken: bool) void {
    const self: *Session = @ptrCast(@alignCast(context));
    if (taken) self.apply(.close);
}
