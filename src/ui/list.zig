const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const media = @import("core").media;

const Allocator = std.mem.Allocator;

const icon_size = 32;
const row_spacing = 10;
const row_margin = 6;
const row_padding = 3;
const fallback_row_height = 32;

const badge_spacing = 4;

const title_class = "sysdeck-title";
const number_class = "sysdeck-number";
const badge_class = "sysdeck-badge";
const kill_class = "sysdeck-kill";
const focus_class = "sysdeck-focus";
const status_class = "sysdeck-status";
const good_class = "sysdeck-good";
const bad_class = "sysdeck-bad";
const detail_class = "sysdeck-detail";

pub const Icon = union(enum) {
    none,
    name: [:0]const u8,
    gicon: *c.GIcon,
};

pub const Tone = enum { good, bad, idle };

pub const Status = struct {
    text: [:0]const u8,
    tone: Tone = .idle,
};

pub const Badge = union(enum) {
    process: i32,
    status: Status,
};

pub const Row = struct {
    id: u64,
    icon: Icon = .none,
    number: u8 = 0,
    title: [:0]const u8,
    detail: [:0]const u8 = "",
    program: []const u8 = "",
    badges: []const Badge = &.{},
    media: ?media.Handle = null,
};

pub const Chosen = struct {
    call: *const fn (context: *anyopaque, id: u64) void,
    context: *anyopaque,
};

pub const Killed = struct {
    call: *const fn (context: *anyopaque, pid: i32) void,
    context: *anyopaque,
};

pub const Focused = struct {
    call: *const fn (context: *anyopaque, pid: i32, id: u64) void,
    context: *anyopaque,
};

pub const Selected = struct {
    call: *const fn (context: *anyopaque, id: ?u64) void,
    context: *anyopaque,
};

pub const List = struct {
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

        self.* = .{
            .gpa = gpa,
            .chosen = chosen,
            .lines = lines,
            .view = view,
            .box = box,
        };

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

    pub fn setRows(self: *List, rows: []const Row) void {
        self.rebuilding = true;

        self.clearRows();
        self.ids.clearRetainingCapacity();

        for (rows) |row| {
            self.ids.append(self.gpa, row.id) catch break;
            self.addRow(row);
        }

        self.measure();
        self.select(0);

        self.rebuilding = false;
        self.notifySelection();
    }

    fn notifySelection(self: *List) void {
        const selected = self.selected orelse return;

        const row = gtk.gtk_list_box_get_selected_row(self.box) orelse {
            return selected.call(selected.context, null);
        };
        const index = gtk.gtk_list_box_row_get_index(row);
        if (index < 0 or @as(usize, @intCast(index)) >= self.ids.items.len) {
            return selected.call(selected.context, null);
        }
        selected.call(selected.context, self.ids.items[@intCast(index)]);
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
        self.chosen.call(self.chosen.context, self.ids.items[at]);
    }

    fn clearRows(self: *List) void {
        while (gtk.gtk_widget_get_first_child(c.cast(c.GtkWidget, self.box))) |child| {
            gtk.gtk_list_box_remove(self.box, child);
        }
    }

    fn addRow(self: *List, row: Row) void {
        const outer = gtk.gtk_box_new(.horizontal, row_spacing);
        gtk.gtk_widget_set_margin_start(outer, row_margin);
        gtk.gtk_widget_set_margin_end(outer, row_margin);
        gtk.gtk_widget_set_margin_top(outer, row_padding);
        gtk.gtk_widget_set_margin_bottom(outer, row_padding);

        if (row.icon != .none) gtk.gtk_box_append(c.cast(c.GtkBox, outer), image(row.icon));

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

        gtk.gtk_list_box_append(self.box, outer);
    }

    fn badge(self: *List, worn: Badge, id: u64) *c.GtkWidget {
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

    fn statusBadge(shown: Status) *c.GtkWidget {
        const box = gtk.gtk_box_new(.horizontal, 0);
        gtk.gtk_widget_add_css_class(box, badge_class);
        gtk.gtk_widget_set_valign(box, .center);

        const text = gtk.gtk_label_new(shown.text.ptr);
        gtk.gtk_widget_add_css_class(text, status_class);
        if (toneClass(shown.tone)) |name| gtk.gtk_widget_add_css_class(text, name);
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
        self.scrollTo(row);
    }

    fn scrollTo(self: *List, row: *c.GtkListBoxRow) void {
        var bounds: c.graphene_rect_t = undefined;
        const found = gtk.gtk_widget_compute_bounds(
            c.cast(c.GtkWidget, row),
            c.cast(c.GtkWidget, self.box),
            &bounds,
        );
        if (found == c.FALSE or bounds.height <= 0) return;

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
    }
};

fn image(icon: Icon) *c.GtkWidget {
    const widget = gtk.gtk_image_new();
    const self = c.cast(c.GtkImage, widget);
    gtk.gtk_image_set_pixel_size(self, icon_size);
    switch (icon) {
        .none => {},
        .name => |name| gtk.gtk_image_set_from_icon_name(self, name.ptr),
        .gicon => |gicon| gtk.gtk_image_set_from_gicon(self, gicon),
    }
    return widget;
}

fn toneClass(tone: Tone) ?[*:0]const u8 {
    return switch (tone) {
        .good => good_class,
        .bad => bad_class,
        .idle => null,
    };
}

fn shortcut(value: u8) *c.GtkWidget {
    var text: [4]u8 = undefined;
    const printed = std.fmt.bufPrintZ(&text, "{d}", .{value}) catch "?";

    const widget = gtk.gtk_label_new(printed.ptr);
    gtk.gtk_widget_add_css_class(widget, number_class);
    gtk.gtk_widget_set_valign(widget, .center);
    return widget;
}

fn label(text: [:0]const u8, class: [:0]const u8) *c.GtkWidget {
    const widget = gtk.gtk_label_new(text.ptr);
    const self = c.cast(c.GtkLabel, widget);
    gtk.gtk_label_set_ellipsize(self, .middle);
    gtk.gtk_label_set_xalign(self, 0);
    gtk.gtk_label_set_max_width_chars(self, 1);
    gtk.gtk_widget_set_hexpand(widget, c.TRUE);
    gtk.gtk_widget_add_css_class(widget, class.ptr);
    return widget;
}

const owner_key: [*:0]const u8 = "sysdeck-list";
const pid_key: [*:0]const u8 = "sysdeck-pid";
const row_key: [*:0]const u8 = "sysdeck-row";

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
    focused.call(focused.context, @intCast(@intFromPtr(held)), @intFromPtr(row) - 1);
}

fn onKillClicked(button: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *List = @ptrCast(@alignCast(data.?));
    const killed = self.killed orelse return;

    const held = glib.g_object_get_data(button, pid_key) orelse return;
    killed.call(killed.context, @intCast(@intFromPtr(held)));
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
