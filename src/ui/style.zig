const std = @import("std");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const List = @import("List.zig");

pub const radius = 14;

pub const sheet =
    \\window.sysdeck {
    \\  background: transparent;
    \\}
    \\.sysdeck-panel {
    \\  margin: 28px 48px 64px 48px;
    \\  border: 1px solid alpha(currentColor, 0.16);
    \\
++ std.fmt.comptimePrint("  border-radius: {d}px;\n", .{radius}) ++
    \\  box-shadow: 0 16px 36px alpha(black, 0.45);
    \\}
    \\.sysdeck-top {
    \\  min-height: 58px;
    \\  padding: 0 16px;
    \\}
    \\.sysdeck-input {
    \\  background: transparent;
    \\  border: none;
    \\  box-shadow: none;
    \\  outline: none;
    \\  padding: 0;
    \\  font-size: 1.4em;
    \\}
    \\.sysdeck-input > image {
    \\  color: inherit;
    \\  padding: 0;
    \\
++ std.fmt.comptimePrint("  min-width: {d}px;\n  margin: 0 {d}px 0 0;\n", .{ List.icon_size, List.row_spacing }) ++
    \\  -gtk-icon-size: 1.4em;
    \\  -gtk-icon-shadow: 0 1px 1px black;
    \\}
    \\.sysdeck-arguments {
    \\  border-left: 1px solid alpha(currentColor, 0.1);
    \\  padding-left: 16px;
    \\}
    \\.sysdeck-deck popover {
    \\  font-family: initial;
    \\  font-size: initial;
    \\}
    \\.sysdeck-rule {
    \\  background: alpha(currentColor, 0.1);
    \\  min-height: 1px;
    \\}
    \\.sysdeck-deck scrolledwindow,
    \\.sysdeck-deck list,
    \\.sysdeck-deck notebook,
    \\.sysdeck-deck notebook > header,
    \\.sysdeck-deck notebook > stack,
    \\.sysdeck-deck textview,
    \\.sysdeck-deck textview text {
    \\  background: transparent;
    \\}
    \\.sysdeck-list {
    \\  margin: 6px 0 8px 0;
    \\}
    \\.sysdeck-context {
    \\  border-top: 1px solid alpha(currentColor, 0.1);
    \\  margin-top: 0;
    \\  padding-top: 6px;
    \\}
    \\.sysdeck-deck row {
    \\  border-radius: 9px;
    \\  margin: 0 8px;
    \\}
    \\.sysdeck-deck row:not(:selected) {
    \\  background: transparent;
    \\}
    \\.sysdeck-deck row:hover:not(:selected) {
    \\  background: alpha(currentColor, 0.06);
    \\}
    \\.sysdeck-extras {
    \\  border-top: 1px solid alpha(currentColor, 0.1);
    \\  padding: 8px;
    \\}
    \\.sysdeck-footer {
    \\  min-height: 34px;
    \\  padding: 0 14px 0 16px;
    \\  font-size: 0.85em;
    \\}
    \\.sysdeck-footer label,
    \\.sysdeck-input placeholder,
    \\.sysdeck-caption {
    \\  text-shadow: 0 1px 1px black;
    \\}
    \\.sysdeck-hint,
    \\.sysdeck-input placeholder,
    \\.sysdeck-input > image {
    \\  opacity: 0.6;
    \\}
    \\.sysdeck-keycap {
    \\  background: alpha(currentColor, 0.12);
    \\  border-radius: 5px;
    \\  padding: 0 6px;
    \\  min-width: 10px;
    \\}
    \\.sysdeck-title {
    \\  font-weight: bold;
    \\}
    \\.sysdeck-glyph {
    \\  font-size: 24px;
    \\}
    \\.sysdeck-detail {
    \\  font-size: 0.85em;
    \\  opacity: 0.6;
    \\}
    \\.sysdeck-number {
    \\  opacity: 0.45;
    \\}
    \\.sysdeck-answer {
    \\  font-size: 1.6em;
    \\  padding: 8px 16px 10px 16px;
    \\}
    \\.sysdeck-man {
    \\  font-size: 0.85em;
    \\}
    \\.sysdeck-man textview {
    \\  font-family: monospace;
    \\  padding: 8px;
    \\}
    \\.sysdeck-caption,
    \\.sysdeck-place {
    \\  font-size: 0.85em;
    \\  opacity: 0.6;
    \\}
    \\.sysdeck-reader {
    \\  font-size: 0.9em;
    \\}
    \\.sysdeck-reply {
    \\  font-size: 0.95em;
    \\  margin: 8px 8px 8px 16px;
    \\}
    \\.sysdeck-badge {
    \\  background: alpha(currentColor, 0.15);
    \\  border-radius: 5px;
    \\  font-size: 0.75em;
    \\  padding: 0 2px;
    \\}
    \\.sysdeck-badge button.sysdeck-focus {
    \\  min-height: 14px;
    \\  padding: 0 2px;
    \\}
    \\.sysdeck-badge button.sysdeck-kill {
    \\  min-height: 14px;
    \\  min-width: 14px;
    \\  padding: 0;
    \\  opacity: 0.6;
    \\}
    \\.sysdeck-badge button.sysdeck-kill:hover {
    \\  opacity: 1;
    \\}
    \\.sysdeck-badge label.sysdeck-status {
    \\  padding: 0 3px;
    \\}
    \\.sysdeck-badge.sysdeck-good {
    \\  background: alpha(#2ec27e, 0.4);
    \\}
    \\.sysdeck-badge.sysdeck-bad {
    \\  background: alpha(#e01b24, 0.4);
    \\}
;

pub const blurred =
    \\.sysdeck-panel {
    \\  backdrop-filter: blur(16px);
    \\}
;

pub fn load(text: [*:0]const u8) void {
    const display = gdk.gdk_display_get_default() orelse return;

    const provider = gtk.gtk_css_provider_new();
    defer glib.g_object_unref(provider);

    gtk.gtk_css_provider_load_from_string(provider, text);
    gtk.gtk_style_context_add_provider_for_display(
        display,
        c.cast(c.GtkStyleProvider, provider),
        c.style_provider_priority_application,
    );
}

const testing = std.testing;

test "the stylesheet names no color, because a theme that lacks the name draws nothing" {
    try testing.expectEqual(null, std.mem.findScalar(u8, sheet, '@'));
}
