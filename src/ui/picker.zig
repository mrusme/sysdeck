const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");

const Allocator = std.mem.Allocator;

const picker_class = "sysdeck-picker";

pub const Picked = struct {
    call: *const fn (context: *anyopaque, at: usize) void,
    context: *anyopaque,
};

pub const Picker = struct {
    gpa: Allocator,
    picked: Picked,
    drop: *c.GtkDropDown,
    count: usize,
    echoing: bool = false,

    pub fn create(
        gpa: Allocator,
        names: []const [:0]const u8,
        picked: Picked,
    ) Allocator.Error!*Picker {
        const self = try gpa.create(Picker);
        errdefer gpa.destroy(self);

        const listed = try gpa.allocSentinel(?[*:0]const u8, names.len, null);
        defer gpa.free(listed);
        for (names, listed[0..names.len]) |name, *slot| slot.* = name.ptr;

        const drop = c.cast(c.GtkDropDown, gtk.gtk_drop_down_new_from_strings(listed.ptr));
        gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, drop), picker_class);

        self.* = .{ .gpa = gpa, .picked = picked, .drop = drop, .count = names.len };
        glib.g_object_set_data_full(self.widget(), owner_key, self, &onFinalized);
        _ = c.connect(drop, "notify::selected", &onSelected, self);
        return self;
    }

    pub fn widget(self: *Picker) *c.GtkWidget {
        return c.cast(c.GtkWidget, self.drop);
    }

    pub fn select(self: *Picker, at: usize) void {
        if (at >= self.count) return;

        self.echoing = true;
        defer self.echoing = false;
        gtk.gtk_drop_down_set_selected(self.drop, @intCast(at));
    }

    pub fn cycle(self: *Picker) void {
        if (self.count < 2) return;

        const current = gtk.gtk_drop_down_get_selected(self.drop);
        const next = if (current == c.invalid_list_position)
            0
        else
            (current + 1) % @as(c.guint, @intCast(self.count));

        gtk.gtk_drop_down_set_selected(self.drop, next);
    }
};

const owner_key: [*:0]const u8 = "sysdeck-picker";

fn onFinalized(data: c.gpointer) callconv(.c) void {
    const self: *Picker = @ptrCast(@alignCast(data.?));
    self.gpa.destroy(self);
}

fn onSelected(drop: *c.GtkDropDown, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const self: *Picker = @ptrCast(@alignCast(data.?));
    if (self.echoing) return;

    const at = gtk.gtk_drop_down_get_selected(drop);
    if (at == c.invalid_list_position) return;

    self.picked.call(self.picked.context, @intCast(at));
}
