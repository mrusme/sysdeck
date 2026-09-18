const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const cli = @import("../cli.zig");
const deck_mod = @import("../ui/deck.zig");
const input = @import("core").input;
const list_mod = @import("../ui/list.zig");
const model = @import("../model.zig");
const rank = @import("core").rank;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.dmenu);

const max_rows = 500;

const Session = struct {
    gpa: Allocator,
    items: []const input.Item,
    haystacks: []const []const u8,
    lines: u16,
    deck: deck_mod.Deck,
    list: ?*list_mod.List = null,
    rows: std.ArrayList(model.Row) = .empty,
    picked: ?usize = null,

    fn refresh(self: *Session, query: []const u8) void {
        const shown = self.list orelse return;

        const matches = rank.rank(self.gpa, self.haystacks, null, query) catch {
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

        shown.setRows(self.rows.items);
    }
};

pub fn run(gpa: Allocator, items: []const input.Item, options: cli.Options) ?usize {
    var haystacks: std.ArrayList([]const u8) = .empty;
    defer haystacks.deinit(gpa);
    haystacks.ensureTotalCapacityPrecise(gpa, items.len) catch return null;
    for (items) |item| haystacks.appendAssumeCapacity(item.label);

    const app = gtk.gtk_application_new(null, c.application_non_unique);
    defer glib.g_object_unref(app);

    var session: Session = .{
        .gpa = gpa,
        .items = items,
        .haystacks = haystacks.items,
        .lines = options.lines,
        .deck = .{ .app = app, .prompt = options.prompt },
    };

    _ = c.connect(app, "activate", &onActivate, &session);
    _ = glib.g_application_run(c.cast(c.GApplication, app), 0, null);

    session.deck.setBody(null);
    session.rows.deinit(gpa);
    return session.picked;
}

fn onActivate(app: *c.GtkApplication, data: c.gpointer) callconv(.c) void {
    const self: *Session = @ptrCast(@alignCast(data.?));

    const body = list_mod.List.create(self.gpa, self.lines, .{
        .call = &onChosen,
        .context = self,
    }) catch {
        log.err("out of memory while building the list", .{});
        glib.g_application_quit(c.cast(c.GApplication, app));
        return;
    };

    self.list = body;
    self.deck.present(.{ .call = &onChanged, .context = self }, .{ .list = body });
    self.refresh("");
}

fn onChanged(context: *anyopaque, text: []const u8) void {
    const self: *Session = @ptrCast(@alignCast(context));
    self.refresh(text);
}

fn onChosen(context: *anyopaque, id: u64) void {
    const self: *Session = @ptrCast(@alignCast(context));

    self.picked = @intCast(id);
    self.deck.close();
}
