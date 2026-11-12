const Deck = @import("Deck.zig");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");

const Focus = @This();

const Range = [2]c_int;

const Kept = struct {
    entry: *c.GtkEntry,
    search: Range,
    arguments: Range,
};

returning: ?*c.GtkWidget = null,
restoring: bool = false,
in_popup: bool = false,
last_entry: ?*c.GtkEntry = null,
kept: ?Kept = null,

pub fn install(self: *Focus) void {
    const deck = self.deckOf();

    const search = gtk.gtk_event_controller_focus_new();
    gtk.gtk_widget_add_controller(c.cast(c.GtkWidget, deck.entry), search);

    const arguments = gtk.gtk_event_controller_focus_new();
    gtk.gtk_widget_add_controller(deck.arguments.widget(), arguments);

    _ = c.connect(search, "enter", &onEntered, self);
    _ = c.connect(search, "leave", &onLeft, self);
    _ = c.connect(arguments, "leave", &onLeft, self);
    _ = c.connect(deck.window, "notify::focus-widget", &onMoved, self);
}

pub fn take(self: *Focus, widget: *c.GtkWidget) void {
    if (self.returning != null) return;

    self.returning = gtk.gtk_window_get_focus(self.deckOf().window);
    _ = gtk.gtk_widget_grab_focus(widget);
}

pub fn give(self: *Focus) void {
    const previous = self.returning orelse return;
    self.returning = null;

    self.restoring = true;
    defer self.restoring = false;

    if (self.entryHolding(previous)) |found| {
        _ = gtk.gtk_entry_grab_focus_without_selecting(found);
        return;
    }
    _ = gtk.gtk_widget_grab_focus(previous);
}

fn deckOf(self: *Focus) *Deck {
    return @fieldParentPtr("focus", self);
}

fn entryHolding(self: *Focus, widget: *c.GtkWidget) ?*c.GtkEntry {
    const deck = self.deckOf();
    const entry = c.cast(c.GtkWidget, deck.entry);
    if (widget == entry or gtk.gtk_widget_is_ancestor(widget, entry) != c.FALSE) return deck.entry;
    if (deck.arguments.holds(widget)) return deck.arguments.entry;
    return null;
}

fn keep(self: *Focus) ?Kept {
    const entry = self.last_entry orelse return null;
    const deck = self.deckOf();
    return .{
        .entry = entry,
        .search = rangeOf(deck.entry),
        .arguments = rangeOf(deck.arguments.entry),
    };
}

fn rangeOf(entry: *c.GtkEntry) Range {
    var range: Range = .{ 0, 0 };
    _ = gtk.gtk_editable_get_selection_bounds(c.cast(c.GtkEditable, entry), &range[0], &range[1]);
    return range;
}

fn focusFrom(data: c.gpointer) *Focus {
    return @ptrCast(@alignCast(data.?));
}

fn onEntered(_: *c.GtkEventControllerFocus, data: c.gpointer) callconv(.c) void {
    const self = focusFrom(data);
    if (self.restoring or self.in_popup) return;
    self.deckOf().selectAll();
}

fn onLeft(controller: *c.GtkEventController, data: c.gpointer) callconv(.c) void {
    const self = focusFrom(data);
    self.last_entry = c.cast(c.GtkEntry, gtk.gtk_event_controller_get_widget(controller));
}

fn onMoved(window: *c.GtkWindow, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const self = focusFrom(data);
    const focus = gtk.gtk_window_get_focus(window) orelse return;

    const popped = gtk.gtk_widget_get_native(focus) != c.cast(c.GtkNative, window);
    defer self.in_popup = popped;

    if (popped and !self.in_popup) {
        self.kept = if (self.entryHolding(focus) == null) self.keep() else null;
    } else if (!popped and self.in_popup and self.kept != null) {
        _ = glib.g_idle_add(&onRestore, self);
    }
}

fn onRestore(data: c.gpointer) callconv(.c) c.gboolean {
    const self = focusFrom(data);
    const kept = self.kept orelse return c.source_remove;
    self.kept = null;

    const deck = self.deckOf();
    if (deck.closing) return c.source_remove;

    const open = deck.arguments.isOpen();
    const target = if (kept.entry == deck.arguments.entry and !open) deck.entry else kept.entry;

    const focus = gtk.gtk_window_get_focus(deck.window);
    if (focus == null or self.entryHolding(focus.?) != target) {
        self.restoring = true;
        defer self.restoring = false;
        _ = gtk.gtk_entry_grab_focus_without_selecting(target);
    }

    gtk.gtk_editable_select_region(c.cast(c.GtkEditable, deck.entry), kept.search[0], kept.search[1]);
    if (open) {
        const editable = c.cast(c.GtkEditable, deck.arguments.entry);
        gtk.gtk_editable_select_region(editable, kept.arguments[0], kept.arguments[1]);
    }
    return c.source_remove;
}
