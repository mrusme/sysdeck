const c = @import("../gtk/c.zig");
const gtk = @import("../gtk/gtk.zig");

const Footer = @This();

const footer_class = "sysdeck-footer";
const hint_class = "sysdeck-hint";
const keycap_class = "sysdeck-keycap";

const return_glyph = "↵";
const actions_word = "Actions";

const parts_spacing = 18;
const key_spacing = 6;

box: *c.GtkBox,
mode: *c.GtkLabel,
action: *c.GtkLabel,
acting: *c.GtkWidget,
offering: *c.GtkWidget,

pub fn create(key: [:0]const u8) Footer {
    const box = c.cast(c.GtkBox, gtk.gtk_box_new(.horizontal, parts_spacing));
    gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, box), footer_class);

    const mode = text("", hint_class);
    gtk.gtk_label_set_xalign(mode, 0);
    gtk.gtk_widget_set_hexpand(c.cast(c.GtkWidget, mode), c.TRUE);
    gtk.gtk_box_append(box, c.cast(c.GtkWidget, mode));

    const action = text("", null);
    const acting = keyed(action, return_glyph);
    gtk.gtk_box_append(box, acting);

    const offering = keyed(text(actions_word, hint_class), key);
    gtk.gtk_box_append(box, offering);

    return .{ .box = box, .mode = mode, .action = action, .acting = acting, .offering = offering };
}

pub fn widget(self: Footer) *c.GtkWidget {
    return c.cast(c.GtkWidget, self.box);
}

pub fn setMode(self: Footer, label: [:0]const u8) void {
    gtk.gtk_label_set_text(self.mode, label.ptr);
}

pub fn setAction(self: Footer, word: [:0]const u8) void {
    gtk.gtk_label_set_text(self.action, word.ptr);
    gtk.gtk_widget_set_visible(self.acting, if (word.len > 0) c.TRUE else c.FALSE);
}

pub fn setContext(self: Footer, shown: bool) void {
    gtk.gtk_widget_set_visible(self.offering, if (shown) c.TRUE else c.FALSE);
}

fn text(content: [:0]const u8, class: ?[*:0]const u8) *c.GtkLabel {
    const label = c.cast(c.GtkLabel, gtk.gtk_label_new(content.ptr));
    if (class) |found| gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, label), found);
    return label;
}

fn keyed(label: *c.GtkLabel, key: [:0]const u8) *c.GtkWidget {
    const part = c.cast(c.GtkBox, gtk.gtk_box_new(.horizontal, key_spacing));
    gtk.gtk_box_append(part, c.cast(c.GtkWidget, label));

    const cap = text(key, keycap_class);
    gtk.gtk_widget_set_valign(c.cast(c.GtkWidget, cap), .center);
    gtk.gtk_box_append(part, c.cast(c.GtkWidget, cap));

    gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, part), c.FALSE);
    return c.cast(c.GtkWidget, part);
}
