const std = @import("std");
const Callback = @import("../callback.zig").Callback;
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const model = @import("../model.zig");

const List = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.list);

pub const icon_size = 32;
pub const row_spacing = 10;
const row_margin = 6;
const row_padding = 3;
const fallback_row_height = 32;

const badge_spacing = 4;

const list_class = "sysdeck-list";
const title_class = "sysdeck-title";
const glyph_class = "sysdeck-glyph";
const number_class = "sysdeck-number";
const badge_class = "sysdeck-badge";
const kill_class = "sysdeck-kill";
const focus_class = "sysdeck-focus";
const status_class = "sysdeck-status";
const good_class = "sysdeck-good";
const bad_class = "sysdeck-bad";
const detail_class = "sysdeck-detail";

pub const Chosen = Callback(fn (id: u64) void);
pub const Killed = Callback(fn (pid: i32) void);
pub const Focused = Callback(fn (pid: i32, id: u64) void);
pub const Selected = Callback(fn (id: ?u64) void);

gpa: Allocator,
chosen: Chosen,
selected: ?Selected = null,
killed: ?Killed = null,
focused: ?Focused = null,
lines: u16,
view: *c.GtkScrolledWindow,
box: *c.GtkListBox,
ids: std.ArrayList(u64) = .empty,
rebuilding: bool = false,
following: c.guint = 0,

pub fn create(gpa: Allocator, lines: u16, chosen: Chosen) Allocator.Error!*List {
    const self = try gpa.create(List);
    errdefer gpa.destroy(self);

    const box = c.cast(c.GtkListBox, gtk.gtk_list_box_new());
    gtk.gtk_list_box_set_selection_mode(box, .browse);
    gtk.gtk_widget_set_can_focus(c.cast(c.GtkWidget, box), c.FALSE);

    const view = c.cast(c.GtkScrolledWindow, gtk.gtk_scrolled_window_new());
    gtk.gtk_scrolled_window_set_child(view, c.cast(c.GtkWidget, box));
    gtk.gtk_scrolled_window_set_policy(view, .never, .automatic);
    gtk.gtk_scrolled_window_set_propagate_natural_height(view, c.TRUE);
    gtk.gtk_scrolled_window_set_max_content_height(view, fallback_row_height * @as(c_int, lines));
    gtk.gtk_widget_set_vexpand(c.cast(c.GtkWidget, view), c.FALSE);
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, view), list_class);

    self.* = .{
        .gpa = gpa,
        .chosen = chosen,
        .lines = lines,
        .view = view,
        .box = box,
    };

    gtk.gtk_list_box_set_header_func(box, &onHeader, null, null);
    _ = c.connect(box, "row-activated", &onRowActivated, self);
    _ = c.connect(box, "row-selected", &onRowSelected, self);
    glib.g_object_set_data_full(self.widget(), owner_key, self, &onFinalized);
    return self;
}

pub fn setFocusable(self: *List, wanted: bool) void {
    gtk.gtk_widget_set_can_focus(
        c.cast(c.GtkWidget, self.box),
        if (wanted) c.TRUE else c.FALSE,
    );
}

pub fn widget(self: *List) *c.GtkWidget {
    return c.cast(c.GtkWidget, self.view);
}

pub fn setRows(self: *List, rows: []const model.Row, at: usize) void {
    const refreshed = self.ids.items.len > 0;
    self.rebuilding = true;

    self.clearRows();
    self.ids.clearRetainingCapacity();

    if (self.ids.ensureTotalCapacity(self.gpa, rows.len)) {
        for (rows) |row| {
            self.ids.appendAssumeCapacity(row.id);
            self.addRow(row);
        }
    } else |err| {
        log.err("cannot hold {d} rows, so the list stays empty: {t}", .{ rows.len, err });
    }

    self.measure();
    self.select(@min(at, rows.len -| 1));

    self.rebuilding = false;
    self.notifySelection();
    if (refreshed) self.follow();
}

pub fn selectedAt(self: *List) ?usize {
    const row = gtk.gtk_list_box_get_selected_row(self.box) orelse return null;
    return std.math.cast(usize, gtk.gtk_list_box_row_get_index(row));
}

fn follow(self: *List) void {
    if (self.following != 0) return;
    self.following = gtk.gtk_widget_add_tick_callback(self.widget(), &onTick, self, null);
}

fn notifySelection(self: *List) void {
    const selected = self.selected orelse return;

    const row = gtk.gtk_list_box_get_selected_row(self.box) orelse {
        return selected.call(.{null});
    };
    const index = gtk.gtk_list_box_row_get_index(row);
    if (index < 0 or @as(usize, @intCast(index)) >= self.ids.items.len) {
        return selected.call(.{null});
    }
    selected.call(.{self.ids.items[@intCast(index)]});
}

pub fn move(self: *List, delta: i32) void {
    if (self.ids.items.len == 0) return;

    const count: i32 = @intCast(self.ids.items.len);
    const current: i32 = if (gtk.gtk_list_box_get_selected_row(self.box)) |row|
        gtk.gtk_list_box_row_get_index(row)
    else
        0;

    self.select(@intCast(std.math.clamp(current + delta, 0, count - 1)));
}

pub fn accept(self: *List) void {
    const row = gtk.gtk_list_box_get_selected_row(self.box) orelse return;
    const index = gtk.gtk_list_box_row_get_index(row);
    if (index < 0) return;
    self.pick(@intCast(index));
}

pub fn pick(self: *List, at: usize) void {
    if (at >= self.ids.items.len) return;
    self.chosen.call(.{self.ids.items[at]});
}

fn clearRows(self: *List) void {
    while (gtk.gtk_widget_get_first_child(c.cast(c.GtkWidget, self.box))) |child| {
        gtk.gtk_list_box_remove(self.box, child);
    }
}

fn addRow(self: *List, row: model.Row) void {
    const outer = gtk.gtk_box_new(.horizontal, row_spacing);
    gtk.gtk_widget_set_margin_start(outer, row_margin);
    gtk.gtk_widget_set_margin_end(outer, row_margin);
    gtk.gtk_widget_set_margin_top(outer, row_padding);
    gtk.gtk_widget_set_margin_bottom(outer, row_padding);

    if (row.icon != .none) gtk.gtk_box_append(c.cast(c.GtkBox, outer), iconOf(row.icon));

    const inner = gtk.gtk_box_new(.vertical, 0);
    gtk.gtk_widget_set_hexpand(inner, c.TRUE);

    const heading = gtk.gtk_box_new(.horizontal, badge_spacing);
    gtk.gtk_box_append(c.cast(c.GtkBox, heading), label(row.title, title_class));
    for (row.badges) |worn| gtk.gtk_box_append(c.cast(c.GtkBox, heading), self.badge(worn, row.id));
    gtk.gtk_box_append(c.cast(c.GtkBox, inner), heading);
    if (row.detail.len > 0) {
        gtk.gtk_box_append(c.cast(c.GtkBox, inner), label(row.detail, detail_class));
    }
    gtk.gtk_box_append(c.cast(c.GtkBox, outer), inner);
    if (row.number > 0) gtk.gtk_box_append(c.cast(c.GtkBox, outer), shortcut(row.number));
    if (row.separated) glib.g_object_set_data(outer, separated_key, outer);

    gtk.gtk_list_box_append(self.box, outer);
}

fn onHeader(row: *c.GtkListBoxRow, _: ?*c.GtkListBoxRow, _: c.gpointer) callconv(.c) void {
    const child = gtk.gtk_list_box_row_get_child(row) orelse return;
    const wanted = glib.g_object_get_data(child, separated_key) != null;
    const current = gtk.gtk_list_box_row_get_header(row);

    if (wanted and current == null) {
        gtk.gtk_list_box_row_set_header(row, gtk.gtk_separator_new(.horizontal));
    } else if (!wanted and current != null) {
        gtk.gtk_list_box_row_set_header(row, null);
    }
}

fn badge(self: *List, worn: model.Badge, id: u64) *c.GtkWidget {
    return switch (worn) {
        .process => |pid| self.processBadge(pid, id),
        .status => |shown| statusBadge(shown),
    };
}

fn processBadge(self: *List, held: i32, id: u64) *c.GtkWidget {
    const box = gtk.gtk_box_new(.horizontal, 2);
    gtk.gtk_widget_add_css_class(box, badge_class);
    gtk.gtk_widget_set_valign(box, .center);

    var text: [16]u8 = undefined;
    const pid = std.fmt.bufPrintZ(&text, "{d}", .{held}) catch "?";

    const jump = gtk.gtk_button_new_with_label(pid.ptr);
    gtk.gtk_button_set_has_frame(c.cast(c.GtkButton, jump), c.FALSE);
    gtk.gtk_widget_add_css_class(jump, focus_class);
    gtk.gtk_widget_set_can_focus(jump, c.FALSE);
    glib.g_object_set_data(jump, pid_key, @ptrFromInt(@as(usize, @intCast(held))));
    glib.g_object_set_data(jump, row_key, @ptrFromInt(@as(usize, @intCast(id)) + 1));
    _ = c.connect(jump, "clicked", &onFocusClicked, self);
    gtk.gtk_box_append(c.cast(c.GtkBox, box), jump);

    const button = gtk.gtk_button_new_with_label("\u{00d7}");
    gtk.gtk_button_set_has_frame(c.cast(c.GtkButton, button), c.FALSE);
    gtk.gtk_widget_add_css_class(button, kill_class);
    gtk.gtk_widget_set_can_focus(button, c.FALSE);
    glib.g_object_set_data(button, pid_key, @ptrFromInt(@as(usize, @intCast(held))));
    _ = c.connect(button, "clicked", &onKillClicked, self);
    gtk.gtk_box_append(c.cast(c.GtkBox, box), button);

    return box;
}

fn statusBadge(shown: model.Status) *c.GtkWidget {
    const box = gtk.gtk_box_new(.horizontal, 0);
    gtk.gtk_widget_add_css_class(box, badge_class);
    if (toneClass(shown.tone)) |name| gtk.gtk_widget_add_css_class(box, name);
    gtk.gtk_widget_set_valign(box, .center);

    const text = gtk.gtk_label_new(shown.text.ptr);
    gtk.gtk_widget_add_css_class(text, status_class);
    gtk.gtk_box_append(c.cast(c.GtkBox, box), text);

    return box;
}

fn measure(self: *List) void {
    const row = gtk.gtk_list_box_get_row_at_index(self.box, 0) orelse return;
    var natural: c_int = 0;
    gtk.gtk_widget_measure(c.cast(c.GtkWidget, row), .vertical, -1, null, &natural, null, null);
    if (natural <= 0) return;

    gtk.gtk_scrolled_window_set_max_content_height(self.view, natural * @as(c_int, self.lines));
}

fn select(self: *List, at: usize) void {
    const row = gtk.gtk_list_box_get_row_at_index(self.box, @intCast(at)) orelse return;
    gtk.gtk_list_box_select_row(self.box, row);
    _ = self.scrollTo(row);
}

fn scrollTo(self: *List, row: *c.GtkListBoxRow) bool {
    if (gtk.gtk_widget_get_height(c.cast(c.GtkWidget, row)) <= 0) return false;

    var bounds: c.graphene_rect_t = undefined;
    const found = gtk.gtk_widget_compute_bounds(
        c.cast(c.GtkWidget, row),
        c.cast(c.GtkWidget, self.box),
        &bounds,
    );
    if (found == c.FALSE or bounds.height <= 0) return false;

    const top: f64 = bounds.y;
    const height: f64 = bounds.height;

    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(self.view);
    const page = gtk.gtk_adjustment_get_page_size(adjustment);
    const value = gtk.gtk_adjustment_get_value(adjustment);

    if (top < value) {
        gtk.gtk_adjustment_set_value(adjustment, top);
    } else if (top + height > value + page) {
        gtk.gtk_adjustment_set_value(adjustment, top + height - page);
    }
    return true;
}

fn iconOf(icon: model.Icon) *c.GtkWidget {
    return switch (icon) {
        .glyph => |text| glyph(text),
        else => image(icon),
    };
}

fn image(icon: model.Icon) *c.GtkWidget {
    const made = gtk.gtk_image_new();
    const self = c.cast(c.GtkImage, made);
    gtk.gtk_image_set_pixel_size(self, icon_size);
    switch (icon) {
        .none, .glyph => {},
        .name => |name| gtk.gtk_image_set_from_icon_name(self, name.ptr),
        .gicon => |gicon| gtk.gtk_image_set_from_gicon(self, gicon),
    }
    return made;
}

fn glyph(text: [:0]const u8) *c.GtkWidget {
    const made = gtk.gtk_label_new(text.ptr);
    const self = c.cast(c.GtkLabel, made);
    gtk.gtk_label_set_ellipsize(self, .end);
    gtk.gtk_label_set_max_width_chars(self, 1);
    gtk.gtk_label_set_xalign(self, 0.5);
    gtk.gtk_widget_set_size_request(made, icon_size, icon_size);
    gtk.gtk_widget_add_css_class(made, glyph_class);
    return made;
}

fn toneClass(tone: model.Tone) ?[*:0]const u8 {
    return switch (tone) {
        .good => good_class,
        .bad => bad_class,
        .idle => null,
    };
}

fn shortcut(value: u8) *c.GtkWidget {
    var text: [4]u8 = undefined;
    const printed = std.fmt.bufPrintZ(&text, "{d}", .{value}) catch "?";

    const made = gtk.gtk_label_new(printed.ptr);
    gtk.gtk_widget_add_css_class(made, number_class);
    gtk.gtk_widget_set_valign(made, .center);
    return made;
}

fn label(text: [:0]const u8, class: [:0]const u8) *c.GtkWidget {
    const made = gtk.gtk_label_new(text.ptr);
    const self = c.cast(c.GtkLabel, made);
    gtk.gtk_label_set_ellipsize(self, .middle);
    gtk.gtk_label_set_xalign(self, 0);
    gtk.gtk_label_set_max_width_chars(self, 1);
    gtk.gtk_widget_set_hexpand(made, c.TRUE);
    gtk.gtk_widget_add_css_class(made, class.ptr);
    return made;
}

const owner_key: [*:0]const u8 = "sysdeck-list";
const pid_key: [*:0]const u8 = "sysdeck-pid";
const row_key: [*:0]const u8 = "sysdeck-row";
const separated_key: [*:0]const u8 = "sysdeck-separated";

fn onFinalized(data: c.gpointer) callconv(.c) void {
    const self: *List = @ptrCast(@alignCast(data.?));
    self.ids.deinit(self.gpa);
    self.gpa.destroy(self);
}

fn onFocusClicked(button: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *List = @ptrCast(@alignCast(data.?));
    const focused = self.focused orelse return;

    const held = glib.g_object_get_data(button, pid_key) orelse return;
    const row = glib.g_object_get_data(button, row_key) orelse return;
    focused.call(.{ @intCast(@intFromPtr(held)), @intFromPtr(row) - 1 });
}

fn onKillClicked(button: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *List = @ptrCast(@alignCast(data.?));
    const killed = self.killed orelse return;

    const held = glib.g_object_get_data(button, pid_key) orelse return;
    killed.call(.{@intCast(@intFromPtr(held))});
}

fn onTick(_: *c.GtkWidget, _: *c.GdkFrameClock, data: c.gpointer) callconv(.c) c.gboolean {
    const self: *List = @ptrCast(@alignCast(data.?));

    if (gtk.gtk_list_box_get_selected_row(self.box)) |row| {
        const shown = gtk.gtk_widget_get_mapped(c.cast(c.GtkWidget, row)) != c.FALSE;
        if (shown and !self.scrollTo(row)) return c.source_continue;
    }

    self.following = 0;
    return c.source_remove;
}

fn onRowSelected(_: *c.GtkListBox, _: ?*c.GtkListBoxRow, data: c.gpointer) callconv(.c) void {
    const self: *List = @ptrCast(@alignCast(data.?));
    if (self.rebuilding) return;
    self.notifySelection();
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: c.gpointer) callconv(.c) void {
    const self: *List = @ptrCast(@alignCast(data.?));
    const index = gtk.gtk_list_box_row_get_index(row);
    if (index < 0) return;
    self.pick(@intCast(index));
}
