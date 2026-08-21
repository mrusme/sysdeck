const std = @import("std");
const c = @import("c.zig");
const fuzzy = @import("fuzzy.zig");
const input = @import("input.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.list);

const max_rows = 500;
const fallback_row_height = 32;

const row_margin = 6;
const row_padding = 3;

pub const Chosen = struct {
    call: *const fn (context: *anyopaque, index: usize) void,
    context: *anyopaque,
};

const Ranked = struct {
    index: usize,
    score: fuzzy.Score,

    fn before(_: void, left: Ranked, right: Ranked) bool {
        if (left.score != right.score) return left.score > right.score;
        return left.index < right.index;
    }
};

pub fn rank(gpa: Allocator, items: []const input.Item, query: []const u8) Allocator.Error![]usize {
    var scored: std.ArrayList(Ranked) = .empty;
    defer scored.deinit(gpa);

    for (items, 0..) |item, index| {
        const value = fuzzy.score(query, item.label) orelse continue;
        try scored.append(gpa, .{ .index = index, .score = value });
    }

    std.mem.sort(Ranked, scored.items, {}, Ranked.before);

    const order = try gpa.alloc(usize, scored.items.len);
    for (scored.items, 0..) |entry, at| order[at] = entry.index;
    return order;
}

pub const List = struct {
    gpa: Allocator,
    items: []const input.Item,
    chosen: Chosen,
    lines: u16,
    view: *c.GtkScrolledWindow,
    box: *c.GtkListBox,
    shown: std.ArrayList(usize) = .empty,

    pub fn create(
        gpa: Allocator,
        items: []const input.Item,
        lines: u16,
        chosen: Chosen,
    ) Allocator.Error!*List {
        const self = try gpa.create(List);
        errdefer gpa.destroy(self);

        const box = c.cast(c.GtkListBox, c.gtk_list_box_new());
        c.gtk_list_box_set_selection_mode(box, .browse);
        c.gtk_widget_set_can_focus(c.cast(c.GtkWidget, box), c.FALSE);

        const view = c.cast(c.GtkScrolledWindow, c.gtk_scrolled_window_new());
        c.gtk_scrolled_window_set_child(view, c.cast(c.GtkWidget, box));
        c.gtk_scrolled_window_set_policy(view, .never, .automatic);
        c.gtk_scrolled_window_set_propagate_natural_height(view, c.TRUE);
        c.gtk_scrolled_window_set_max_content_height(view, fallback_row_height * @as(c_int, lines));
        c.gtk_widget_set_vexpand(c.cast(c.GtkWidget, view), c.TRUE);

        self.* = .{
            .gpa = gpa,
            .items = items,
            .chosen = chosen,
            .lines = lines,
            .view = view,
            .box = box,
        };

        _ = c.connect(box, "row-activated", &onRowActivated, self);

        self.filter("");
        return self;
    }

    pub fn destroy(self: *List) void {
        self.shown.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn widget(self: *List) *c.GtkWidget {
        return c.cast(c.GtkWidget, self.view);
    }

    pub fn filter(self: *List, query: []const u8) void {
        const order = rank(self.gpa, self.items, query) catch {
            log.warn("out of memory, so the list was left as it is", .{});
            return;
        };
        defer self.gpa.free(order);

        self.shown.clearRetainingCapacity();
        self.shown.appendSlice(self.gpa, order[0..@min(order.len, max_rows)]) catch {
            log.warn("out of memory, so the list is empty", .{});
        };

        self.clearRows();
        for (self.shown.items) |index| self.addRow(self.items[index]);
        self.measure();
        self.select(0);
    }

    pub fn move(self: *List, delta: i32) void {
        if (self.shown.items.len == 0) return;

        const count: i32 = @intCast(self.shown.items.len);
        const current: i32 = if (c.gtk_list_box_get_selected_row(self.box)) |row|
            c.gtk_list_box_row_get_index(row)
        else
            0;

        self.select(@intCast(std.math.clamp(current + delta, 0, count - 1)));
    }

    pub fn accept(self: *List) void {
        const row = c.gtk_list_box_get_selected_row(self.box) orelse return;
        const index = c.gtk_list_box_row_get_index(row);
        if (index < 0) return;
        self.pick(@intCast(index));
    }

    fn pick(self: *List, at: usize) void {
        if (at >= self.shown.items.len) return;
        self.chosen.call(self.chosen.context, self.shown.items[at]);
    }

    fn clearRows(self: *List) void {
        while (c.gtk_widget_get_first_child(c.cast(c.GtkWidget, self.box))) |child| {
            c.gtk_list_box_remove(self.box, child);
        }
    }

    fn addRow(self: *List, item: input.Item) void {
        const label = c.cast(c.GtkLabel, c.gtk_label_new(item.label.ptr));
        c.gtk_label_set_ellipsize(label, .middle);
        c.gtk_label_set_xalign(label, 0);
        c.gtk_label_set_max_width_chars(label, 1);

        const widget_of = c.cast(c.GtkWidget, label);
        c.gtk_widget_set_hexpand(widget_of, c.TRUE);
        c.gtk_widget_set_margin_start(widget_of, row_margin);
        c.gtk_widget_set_margin_end(widget_of, row_margin);
        c.gtk_widget_set_margin_top(widget_of, row_padding);
        c.gtk_widget_set_margin_bottom(widget_of, row_padding);

        c.gtk_list_box_append(self.box, widget_of);
    }

    fn measure(self: *List) void {
        const row = c.gtk_list_box_get_row_at_index(self.box, 0) orelse return;
        var natural: c_int = 0;
        c.gtk_widget_measure(c.cast(c.GtkWidget, row), .vertical, -1, null, &natural, null, null);
        if (natural <= 0) return;

        c.gtk_scrolled_window_set_max_content_height(self.view, natural * @as(c_int, self.lines));
    }

    fn select(self: *List, at: usize) void {
        const row = c.gtk_list_box_get_row_at_index(self.box, @intCast(at)) orelse return;
        c.gtk_list_box_select_row(self.box, row);
        self.scrollTo(row);
    }

    fn scrollTo(self: *List, row: *c.GtkListBoxRow) void {
        var bounds: c.graphene_rect_t = undefined;
        const found = c.gtk_widget_compute_bounds(
            c.cast(c.GtkWidget, row),
            c.cast(c.GtkWidget, self.box),
            &bounds,
        );
        if (found == c.FALSE or bounds.height <= 0) return;

        const top: f64 = bounds.y;
        const height: f64 = bounds.height;

        const adjustment = c.gtk_scrolled_window_get_vadjustment(self.view);
        const page = c.gtk_adjustment_get_page_size(adjustment);
        const value = c.gtk_adjustment_get_value(adjustment);

        if (top < value) {
            c.gtk_adjustment_set_value(adjustment, top);
        } else if (top + height > value + page) {
            c.gtk_adjustment_set_value(adjustment, top + height - page);
        }
    }
};

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: c.gpointer) callconv(.c) void {
    const self: *List = @ptrCast(@alignCast(data.?));
    const index = c.gtk_list_box_row_get_index(row);
    if (index < 0) return;
    self.pick(@intCast(index));
}

const testing = std.testing;

fn testItems(comptime labels: []const [:0]const u8) [labels.len]input.Item {
    var items: [labels.len]input.Item = undefined;
    for (labels, 0..) |label, at| items[at] = .{ .text = label, .label = label };
    return items;
}

test "an empty query keeps every item in the order it was given" {
    const items = testItems(&.{ "second", "first", "third" });

    const order = try rank(testing.allocator, &items, "");
    defer testing.allocator.free(order);

    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, order);
}

test "items that do not match are left out" {
    const items = testItems(&.{ "zig release notes", "rust release notes", "zig build system" });

    const order = try rank(testing.allocator, &items, "zig");
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 2), order.len);
    try testing.expect(std.mem.indexOfScalar(usize, order, 1) == null);
}

test "the better match ranks first" {
    const items = testItems(&.{ "a note about zigzag lines", "zig 0.16 released" });

    const order = try rank(testing.allocator, &items, "zig");
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 1), order[0]);
}

test "equal scores keep the original order" {
    const items = testItems(&.{ "link one", "link two", "link six" });

    const order = try rank(testing.allocator, &items, "link");
    defer testing.allocator.free(order);

    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, order);
}

test "a query matching nothing ranks nothing" {
    const items = testItems(&.{"only this"});

    const order = try rank(testing.allocator, &items, "absent");
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 0), order.len);
}

test "ranking reads the label, not the original bytes" {
    const items = [_]input.Item{.{ .text = "a\xffb", .label = "a\u{fffd}b" }};

    const order = try rank(testing.allocator, &items, "ab");
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 1), order.len);
}
