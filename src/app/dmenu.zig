const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const cli = @import("../cli.zig");
const config = @import("../config.zig");
const Backdrop = @import("../ui/Backdrop.zig");
const Deck = @import("../ui/Deck.zig");
const fold = @import("core").fold;
const input = @import("core").input;
const List = @import("../ui/List.zig");
const model = @import("../model.zig");
const rank = @import("core").rank;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.dmenu);

const max_rows = 500;
const mode_label = "dmenu";
const select_verb = "Select";

const Session = struct {
    gpa: Allocator,
    items: []const input.Item,
    folded: []const fold.Folded,
    lines: u16,
    deck: Deck,
    list: ?*List = null,
    rows: std.ArrayList(model.Row) = .empty,
    picked: ?usize = null,

    fn refresh(self: *Session, query: []const u8) void {
        const shown = self.list orelse return;

        const wanted = fold.query(self.gpa, query) catch {
            log.warn("out of memory, so the list was left as it is", .{});
            return;
        };
        defer self.gpa.free(wanted);

        const matches = rank.rankFolded(self.gpa, self.folded, null, wanted) catch {
            log.warn("out of memory, so the list was left as it is", .{});
            return;
        };
        defer self.gpa.free(matches);

        self.rows.clearRetainingCapacity();
        for (matches[0..@min(matches.len, max_rows)]) |match| {
            self.rows.append(self.gpa, .{
                .id = match.index,
                .title = self.items[match.index].label,
            }) catch break;
        }

        shown.setRows(self.rows.items, 0);
        self.deck.setAction(if (self.rows.items.len > 0) select_verb else "");
    }

    fn onChanged(self: *Session, text: []const u8) void {
        self.refresh(text);
    }

    fn onChosen(self: *Session, id: u64) void {
        if (self.deck.closing) return;
        self.picked = @intCast(id);
        self.deck.close();
    }
};

pub fn run(
    gpa: Allocator,
    items: []const input.Item,
    options: cli.Options,
    settings: config.Settings,
    backdrop: ?Backdrop.Source,
    rows: u16,
) ?usize {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const folded = arena.allocator().alloc(fold.Folded, items.len) catch return null;
    for (items, folded) |item, *slot| slot.* = fold.fold(arena.allocator(), item.label) catch return null;

    const app = gtk.gtk_application_new(null, c.application_non_unique);
    defer glib.g_object_unref(app);
    if (!Deck.register(app)) return null;

    var session: Session = .{
        .gpa = gpa,
        .items = items,
        .folded = folded,
        .lines = rows,
        .deck = .create(app, .{
            .prompt = options.prompt,
            .opacity = settings.opacity,
            .backdrop_source = backdrop,
        }),
    };

    session.deck.setMode(mode_label);
    _ = c.connect(app, "activate", &onActivate, &session);
    _ = glib.g_application_run(c.cast(c.GApplication, app), 0, null);

    session.deck.dispose();
    session.rows.deinit(gpa);
    return session.picked;
}

fn onActivate(app: *c.GtkApplication, data: c.gpointer) callconv(.c) void {
    const self: *Session = @ptrCast(@alignCast(data.?));

    const body = List.create(
        self.gpa,
        self.lines,
        .of(Session, Session.onChosen, self),
    ) catch {
        log.err("out of memory while building the list", .{});
        glib.g_application_quit(c.cast(c.GApplication, app));
        return;
    };

    self.list = body;
    self.deck.present(.of(Session, Session.onChanged, self), .{ .list = body });
    self.refresh("");
}
