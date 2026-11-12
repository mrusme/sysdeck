const std = @import("std");
const Answer = @import("../ui/Answer.zig");
const Bench = @import("Bench.zig");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const cli = @import("../cli.zig");
const config_mod = @import("../config.zig");
const Context = @import("../ui/Context.zig");
const copy = @import("../system/copy.zig");
const Deck = @import("../ui/Deck.zig");
const Dispatch = @import("Dispatch.zig");
const keys_mod = @import("../ui/keys.zig");
const List = @import("../ui/List.zig");
const model = @import("../model.zig");
const modes = @import("../modes.zig");
const Ask = @import("Ask.zig");
const overlay_mod = @import("../screenshot/overlay.zig");
const Panes = @import("Panes.zig");
const Shot = @import("Shot.zig");
const source_mod = @import("../subroutines/source.zig");
const subroutines = @import("../subroutines.zig");
const fuzzy = @import("core").fuzzy;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.session);

const copy_verb = "Copy";
const send_verb = "Send";

const Session = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    settings: *const config_mod.Config,
    settings_at: ?i64,
    resolved: config_mod.Settings,
    source: []const u8,
    read: bool,
    bindings: keys_mod.Bindings,
    lines: u16,
    prompt: [:0]const u8,
    options_prompt: bool,
    picks: ?usize,
    deck: Deck,
    dispatch: Dispatch,
    bench: ?*Bench = null,
    panes: ?*Panes = null,
    shot: ?*Shot = null,
    ask: ?*Ask = null,
    submode: modes.Mode = .search,
    query: std.ArrayList(u8) = .empty,
    context: ?*Context = null,
    selected: ?u64 = null,
    holding: bool = false,
    completing: bool = false,
    launched: bool = false,
    rerun_posted: std.atomic.Value(bool) = .init(false),
    settled_next: std.atomic.Value(subroutines.Next) = .init(.close),

    fn build(self: *Session) !void {
        const published: source_mod.Published = .of(Session, Session.onPublished, self);

        self.bench = try Bench.create(.{
            .gpa = self.gpa,
            .io = self.io,
            .environ = self.environ,
            .settings = self.settings,
            .resolved = self.resolved,
            .settings_at = self.settings_at,
            .published = published,
            .settled = .of(Session, Session.onSettled, self),
            .requested = .of(Session, Session.onShotRequested, self),
            .streamed = .of(Session, Session.onStreamed, self),
        });

        if (self.bench.?.llm) |*found| {
            self.ask = try Ask.create(
                self.gpa,
                &self.deck,
                found,
                self.resolved.reply_height,
            );
        }

        self.shot = try Shot.create(
            self.gpa,
            self.io,
            self.environ,
            self.settings.sources.screenshot,
            self.resolved.destination,
            &self.deck,
            if (self.bench.?.sway) |*found| found else null,
            .of(Session, Session.onShotFinished, self),
        );

        self.panes = try Panes.create(
            self.gpa,
            self.io,
            self.environ,
            self.settings,
            self.resolved,
            self.bindings,
        );
    }

    fn teardown(self: *Session) void {
        if (self.bench) |found| found.waitRefreshes();
        self.dispatch.stop();
        if (self.bench) |found| found.stop();
        if (self.ask) |found| found.destroy();
        self.ask = null;
        if (self.shot) |found| found.destroy();
        self.shot = null;
        if (self.panes) |found| found.destroy();
        self.panes = null;
        if (self.bench) |found| found.destroy();
        self.bench = null;
        self.deck.dispose();
        self.query.deinit(self.gpa);
    }

    fn select(self: *Session, target: ?Dispatch.Target) void {
        const found = self.panes orelse return;
        found.select(target);
    }

    fn present(self: *Session, what: Dispatch.Presentation) void {
        switch (what) {
            .rows => |rows| self.setRows(rows.all, rows.selected),
            .answer => |text| self.setAnswer(text),
        }
    }

    fn setRows(self: *Session, wanted: []const model.Row, at: usize) void {
        if (wanted.len == 0) {
            self.selected = null;
            self.select(null);
            self.describe(null);
            self.deck.setBody(null);
            return self.syncContext();
        }

        defer self.syncContext();
        defer self.suggest(wanted[0].title);

        const body = self.list() orelse block: {
            const made = List.create(
                self.gpa,
                self.lines,
                .of(Session, Session.onChosen, self),
            ) catch {
                log.err("out of memory while building the list", .{});
                return;
            };
            made.selected = .of(Session, Session.onSelected, self);
            made.killed = .of(Session, Session.onKilled, self);
            made.focused = .of(Session, Session.onFocused, self);
            self.deck.setBody(.{ .list = made });
            break :block made;
        };

        body.setRows(wanted, at);
    }

    fn setAnswer(self: *Session, text: [:0]const u8) void {
        self.selected = null;
        self.select(null);
        self.deck.setAction(copy_verb);
        self.deck.setContext(false);
        self.deck.offerArguments(false);
        defer self.syncContext();

        const body = self.answer() orelse block: {
            const made = Answer.create(
                self.gpa,
                .of(Session, Session.onCopyRequested, self),
            ) catch {
                log.err("out of memory while building the answer", .{});
                return;
            };
            self.deck.setBody(.{ .answer = made });
            break :block made;
        };

        body.setText(text);
    }

    fn describe(self: *Session, id: ?u64) void {
        const found = id orelse {
            self.deck.setAction(self.idleVerb());
            self.deck.offerArguments(false);
            return self.deck.setContext(false);
        };
        const row = self.dispatch.rowOf(found) orelse return;
        self.deck.setAction(row.verb);
        self.deck.offerArguments(self.dispatch.takesArguments(found));

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        self.deck.setContext(self.dispatch.actions(arena.allocator(), found).len > 0);
    }

    fn idleVerb(self: *Session) [:0]const u8 {
        return if (self.submode == .llm) send_verb else "";
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
            .busy => self.deck.disableInput(),
            .refresh => self.dispatch.rerun(self.selected),
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

    fn show(self: *Session, wanted: modes.Mode) void {
        const found = self.bench orelse return;
        const range = found.rangeOf(wanted);

        self.submode = wanted;
        self.deck.setMode(wanted.label());
        self.deck.setAction(self.idleVerb());
        self.deck.setContext(false);
        self.deck.offerArguments(false);
        self.dispatch.setMembers(
            found.membersOf(range),
            found.arrivedOf(range),
            if (wanted == .search) self.picks else null,
            wanted.capped(),
        );
    }

    fn enter(self: *Session, wanted: modes.Mode) bool {
        const found = self.bench orelse return false;
        if (found.rangeOf(wanted).empty()) {
            self.explain(wanted);
            return true;
        }

        if (self.submode == wanted) return true;
        self.switchTo(wanted);

        self.deck.setText("");
        self.remember("");

        if (wanted == .llm) {
            if (self.ask) |current| current.enter();
            return true;
        }

        self.dispatch.schedule("", .now);
        return true;
    }

    fn switchTo(self: *Session, wanted: modes.Mode) void {
        if (self.submode == .llm) {
            if (self.ask) |current| current.leave();
        }

        self.select(null);
        self.deck.setBody(null);
        self.show(wanted);

        if (!self.options_prompt) self.deck.setPrompt(self.promptOf(wanted));
    }

    fn promptOf(self: *Session, wanted: modes.Mode) [:0]const u8 {
        return wanted.prompt() orelse self.prompt;
    }

    fn list(self: *Session) ?*List {
        return switch (self.deck.body orelse return null) {
            .list => |current| current,
            else => null,
        };
    }

    fn explain(self: *Session, wanted: modes.Mode) void {
        const missing = wanted.missing();
        if (missing.len == 0) return;

        if (self.switchedOff(wanted)) |name| {
            log.warn("{s}, because {s} sets [sources.{s}] enable to false", .{
                missing,
                self.source,
                name,
            });
            return;
        }

        switch (wanted) {
            .windows => return log.warn("{s}, because $SWAYSOCK is not set", .{missing}),
            .llm, .disk => {},
            else => return,
        }

        if (!self.read) {
            log.warn("{s}, because {s} was not read", .{ missing, self.source });
            return;
        }

        const needed: []const u8 = switch (wanted) {
            .llm => "no usable [[sources.llm.gemini]], [[sources.llm.openai]] or " ++
                "[[sources.llm.anthropic]] entry",
            else => "no usable [sources.disk] locations entry",
        };
        log.warn("{s}, because {s} has {s}", .{ missing, self.source, needed });
    }

    fn switchedOff(self: *Session, wanted: modes.Mode) ?[]const u8 {
        const name = wanted.source() orelse return null;
        return if (self.settings.sources.enableOf(name) == false) name else null;
    }

    fn asking(self: *Session) ?*Ask {
        if (self.submode != .llm) return null;
        return self.ask;
    }

    fn answer(self: *Session) ?*Answer {
        return switch (self.deck.body orelse return null) {
            .answer => |current| current,
            else => null,
        };
    }

    fn onChanged(self: *Session, text: []const u8) void {
        if (self.submode == .llm) return self.remember(text);

        const previous = self.query.items;
        self.completing = text.len > previous.len and std.mem.startsWith(u8, text, previous);

        self.remember(text);
        self.dispatch.schedule(text, .debounced);
    }

    fn onDisplay(self: *Session, what: Dispatch.Presentation) void {
        self.present(what);
    }

    fn onCopyRequested(self: *Session, text: [:0]const u8) void {
        if (self.deck.closing) return;
        if (copy.put(self.gpa, self.environ, .{ .bytes = text })) self.apply(.close);
    }

    fn onSearchRequested(self: *Session, text: [:0]const u8) void {
        if (self.deck.closing) return;
        const found = self.bench orelse return;
        if (found.rangeOf(.search).empty()) return self.explain(.search);

        const query = fuzzy.queryOf(self.gpa, text) catch {
            log.err("out of memory while searching for the selection", .{});
            return;
        };
        defer self.gpa.free(query);

        if (self.submode != .search) self.switchTo(.search);

        self.deck.offerArguments(false);
        self.completing = false;
        self.deck.setQuery(query);
        self.remember(query);
        self.dispatch.schedule(query, .now);
    }

    fn onSelected(self: *Session, id: ?u64) void {
        if (self.deck.closing) return;
        self.selected = id;
        self.describe(id);

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

    fn onKey(self: *Session, keyval: c.guint, state: c.GdkModifierType) bool {
        if (keyval == c.key_Tab and state & c.modifier_mask == 0) return self.deck.openArguments();

        if (self.bindings.llm.matches(keyval, state)) {
            if (self.submode != .llm) return self.enter(.llm);

            if (self.asking()) |found| found.cycle();
            return true;
        }

        if (self.submode == .llm) {
            if (self.asking()) |found| {
                if (self.bindings.reset.matches(keyval, state)) {
                    found.reset();
                    return true;
                }
                switch (keyval) {
                    c.key_Return, c.key_KP_Enter, c.key_ISO_Enter => {
                        found.submit(self.deck.typed());
                        return true;
                    },
                    c.key_Escape => if (found.cancel()) return true,
                    else => {},
                }
            }
        }

        if (self.bindings.windows.matches(keyval, state)) return self.enter(.windows);
        if (self.bindings.search.matches(keyval, state)) return self.enter(.search);
        if (self.bindings.history.matches(keyval, state)) return self.enter(.history);
        if (self.bindings.disk.matches(keyval, state)) return self.enter(.disk);
        if (self.bindings.whats.matches(keyval, state)) return self.enter(.whats);
        if (self.bindings.network.matches(keyval, state)) return self.enter(.nm);
        if (self.bindings.phonebook.matches(keyval, state)) return self.enter(.phonebook);
        if (self.bindings.containers.matches(keyval, state)) return self.enter(.containers);

        if (self.context) |found| {
            if (found.key(keyval)) return true;
        }

        const panes = self.panes orelse return false;
        return panes.key(keyval, state);
    }

    fn onHolding(self: *Session, held: bool) void {
        if (held == self.holding) return;

        self.holding = held;
        self.syncContext();
    }

    fn onPerformed(self: *Session, row: u64, choice: model.Choice) void {
        if (self.deck.closing) return;
        self.apply(self.dispatch.perform(row, choice));
    }

    fn onFocused(self: *Session, pid: i32, id: u64) void {
        if (self.deck.closing) return;
        const bench = self.bench orelse return;
        const sway = if (bench.sway) |*found| found else return;

        var pids: std.ArrayList(i32) = .empty;
        defer pids.deinit(self.gpa);

        pids.append(self.gpa, pid) catch return;
        if (self.dispatch.rowOf(id)) |row| {
            for (row.badges) |worn| {
                const held = switch (worn) {
                    .process => |found| found,
                    .status => continue,
                };
                if (held != pid) pids.append(self.gpa, held) catch break;
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

    fn onKilled(self: *Session, pid: i32) void {
        if (self.deck.closing) return;
        const target = std.math.cast(u64, pid) orelse return;

        const bench = self.bench orelse return;
        const processes = if (bench.processes) |*found| found else return;
        _ = processes.subroutine().choose(self.gpa, target);
        self.dispatch.rerun(self.selected);
    }

    fn onChosen(self: *Session, id: u64) void {
        if (self.deck.closing) return;
        const arguments = std.mem.trim(u8, self.deck.argumentsText(), &std.ascii.whitespace);
        if (arguments.len > 0 and self.dispatch.takesArguments(id)) {
            return self.apply(self.dispatch.chooseWith(id, arguments));
        }
        self.apply(self.dispatch.choose(id));
    }

    fn onShotRequested(self: *Session, mode: overlay_mod.Mode) void {
        const found = self.shot orelse return;
        found.begin(mode);
    }

    fn onShotFinished(self: *Session, taken: bool) void {
        if (taken) self.apply(.close);
    }

    fn onPublished(self: *Session) void {
        if (self.rerun_posted.swap(true, .acq_rel)) return;
        _ = glib.g_idle_add(&onIdlePublished, self);
    }

    fn onSettled(self: *Session, next: subroutines.Next) void {
        self.settled_next.store(next, .release);
        _ = glib.g_idle_add(&onIdleSettled, self);
    }

    fn onStreamed(self: *Session) void {
        const found = self.ask orelse return;
        if (!self.deck.closing) found.arrived();
    }
};

pub fn run(
    init: std.process.Init,
    loaded: *const config_mod.Loaded,
    options: cli.Options,
    rows: u16,
) bool {
    const settings = &loaded.value;
    const app = gtk.gtk_application_new(null, c.application_non_unique);
    defer glib.g_object_unref(app);
    if (!Deck.register(app)) return false;

    const bindings: keys_mod.Bindings = .from(&settings.keys);

    var session: Session = .{
        .gpa = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
        .settings = settings,
        .settings_at = loaded.changed_at,
        .resolved = loaded.settings,
        .source = loaded.describe(),
        .read = loaded.read,
        .bindings = bindings,
        .lines = rows,
        .prompt = options.prompt,
        .options_prompt = options.prompt_given,
        .picks = if (options.recommendations) loaded.settings.picks else null,
        .deck = .create(app, .{
            .prompt = options.prompt,
            .opacity = loaded.settings.opacity,
            .backdrop_source = .of(init.gpa, init.io, init.environ_map, loaded.settings.static_blur),
            .held = bindings.context,
        }),
        .dispatch = .init(init.gpa, init.io, loaded.settings.debounce_ms),
        .submode = options.start,
    };
    session.dispatch.display = .of(Session, Session.onDisplay, &session);

    _ = c.connect(app, "activate", &onActivate, &session);
    _ = glib.g_application_run(c.cast(c.GApplication, app), 0, null);

    session.teardown();
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

    if (bench.rangeOf(self.submode).empty()) {
        self.explain(self.submode);
        self.submode = .search;
    }
    self.show(self.submode);

    self.context = Context.create(
        self.gpa,
        self.lines,
        .of(Session, Session.onPerformed, self),
    ) catch |err| block: {
        log.warn("cannot build the context list: {t}", .{err});
        break :block null;
    };

    bench.startRefreshes();
    self.deck.keys = .of(Session, Session.onKey, self);
    self.deck.holding = .of(Session, Session.onHolding, self);
    self.deck.selection = .{
        .copied = .of(Session, Session.onCopyRequested, self),
        .searched = .of(Session, Session.onSearchRequested, self),
    };
    self.deck.present(.of(Session, Session.onChanged, self), null);
    panes.attach(self.deck.extras);
    if (self.ask) |found| found.attach();
    if (self.context) |found| self.deck.attachContext(found.widget());

    if (self.submode != .search and !self.options_prompt) {
        self.deck.setPrompt(self.promptOf(self.submode));
    }

    if (self.submode == .llm) {
        if (self.ask) |found| found.enter();
    } else if (self.submode != .search or self.picks != null) {
        self.dispatch.schedule("", .now);
    }
}

fn onIdleSettled(data: c.gpointer) callconv(.c) c.gboolean {
    const self: *Session = @ptrCast(@alignCast(data.?));
    if (self.deck.closing) return c.source_remove;

    switch (self.settled_next.load(.acquire)) {
        .close => self.apply(.close),
        .refresh => {
            self.deck.enableInput();
            self.apply(.refresh);
        },
    }
    return c.source_remove;
}

fn onIdlePublished(data: c.gpointer) callconv(.c) c.gboolean {
    const self: *Session = @ptrCast(@alignCast(data.?));
    self.rerun_posted.store(false, .release);
    if (!self.deck.closing) self.dispatch.rerun(self.selected);
    return c.source_remove;
}

const testing = std.testing;
const globals = @import("globals.zig");
const jobs = @import("../jobs.zig");
const llm_mod = @import("../subroutines/llm.zig");

const Fixture = struct {
    environ: std.process.Environ.Map,
    settings: config_mod.Config,
    session: Session,

    fn init(self: *Fixture) !void {
        const app = try Deck.sharedApplication();

        self.environ = .init(testing.allocator);
        self.settings = .{
            .extensions = .{ .man = .{ .enable = false }, .preview = .{ .enable = false } },
        };
        self.session = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .environ = &self.environ,
            .settings = &self.settings,
            .settings_at = null,
            .resolved = config_mod.resolve(self.settings),
            .source = "test.toml",
            .read = false,
            .bindings = .{},
            .lines = config_mod.default_lines,
            .prompt = cli.default_prompt,
            .options_prompt = false,
            .picks = null,
            .deck = .create(app, .{ .prompt = cli.default_prompt }),
            .dispatch = .init(testing.allocator, testing.io, config_mod.default_debounce_ms),
        };
    }

    fn deinit(self: *Fixture) void {
        self.environ.deinit();
    }
};

test "teardown forgets what it destroyed, so the last selection of the dying list reaches nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const session = &fixture.session;

    var index: llm_mod.Index = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .services = &.{},
        .store = null,
        .chat = .{ .gpa = testing.allocator },
    };
    session.ask = try Ask.create(testing.allocator, &session.deck, &index, config_mod.default_reply_height);
    session.shot = try Shot.create(
        testing.allocator,
        testing.io,
        &fixture.environ,
        fixture.settings.sources.screenshot,
        session.resolved.destination,
        &session.deck,
        null,
        .of(Session, Session.onShotFinished, session),
    );
    session.panes = try Panes.create(
        testing.allocator,
        testing.io,
        &fixture.environ,
        &fixture.settings,
        session.resolved,
        session.bindings,
    );

    session.teardown();

    try testing.expect(session.ask == null);
    try testing.expect(session.shot == null);
    try testing.expect(session.panes == null);
    session.onSelected(null);
}

test "a row chosen or acted on once the deck is closing reaches no subroutine" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const session = &fixture.session;
    defer session.teardown();

    var picked: globals.Fake = .{};
    const members = [_]subroutines.Subroutine{picked.subroutine()};
    session.dispatch.members = &members;
    try session.dispatch.sources.append(testing.allocator, .{ .member = 0, .id = 7 });

    session.deck.closing = true;
    session.onChosen(0);
    session.onPerformed(0, .{ .own = 3 });
    try testing.expect(!session.launched);
    try testing.expectEqual(null, picked.performed);

    session.deck.closing = false;
    session.onChosen(0);
    try testing.expect(session.launched);

    session.deck.closing = false;
    session.onPerformed(0, .{ .own = 3 });
    try testing.expectEqual(3, picked.performed);
}

test "publishes before the main loop runs start one rerun, and a later one starts another" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const session = &fixture.session;
    defer session.teardown();

    session.dispatch.query = try testing.allocator.dupeSentinel(u8, "zig", 0);
    const before = session.dispatch.runner.current();

    session.onPublished();
    session.onPublished();
    jobs.dispatchPending();
    try testing.expectEqual(before + 1, session.dispatch.runner.current());

    session.onPublished();
    jobs.dispatchPending();
    try testing.expectEqual(before + 2, session.dispatch.runner.current());
}
