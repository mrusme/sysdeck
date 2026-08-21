const std = @import("std");
const c = @import("c.zig");
const cli = @import("cli.zig");
const deck_mod = @import("deck.zig");
const input = @import("input.zig");
const list_mod = @import("list.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.dmenu);

const Session = struct {
    gpa: Allocator,
    items: []const input.Item,
    lines: u16,
    deck: deck_mod.Deck,
    picked: ?usize = null,
};

pub fn run(gpa: Allocator, items: []const input.Item, options: cli.Options) ?usize {
    // Non-unique, because two pipelines have to bring up their own popup
    // rather than being handed to whichever instance is already running.
    const app = c.gtk_application_new(null, c.application_non_unique);
    defer c.g_object_unref(app);

    var session: Session = .{
        .gpa = gpa,
        .items = items,
        .lines = options.lines,
        .deck = .{ .app = app, .prompt = options.prompt },
    };

    _ = c.connect(app, "activate", &onActivate, &session);
    _ = c.g_application_run(c.cast(c.GApplication, app), 0, null);

    session.deck.setBody(null);
    return session.picked;
}

fn onActivate(app: *c.GtkApplication, data: c.gpointer) callconv(.c) void {
    const self: *Session = @ptrCast(@alignCast(data.?));

    const body = list_mod.List.create(self.gpa, self.items, self.lines, .{
        .call = &onChosen,
        .context = self,
    }) catch {
        log.err("out of memory while building the list", .{});
        c.g_application_quit(c.cast(c.GApplication, app));
        return;
    };

    self.deck.present(.{ .list = body });
}

fn onChosen(context: *anyopaque, index: usize) void {
    const self: *Session = @ptrCast(@alignCast(context));

    self.picked = index;
    self.deck.close();
}
