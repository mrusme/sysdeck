const std = @import("std");
const c = @import("../c.zig");
const extensions = @import("../extensions.zig");
const keys = @import("../keys.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.man);

pub const name = "man";

const source = "bins";
const max_sections = 16;
const max_output = 1 << 20;
const page_height = 300;
const man_width = "78";

pub const Extension = struct {
    notebook: *c.GtkNotebook,
    binding: keys.Numbered,

    pub fn create(binding: keys.Numbered) Extension {
        const notebook = c.cast(c.GtkNotebook, c.gtk_notebook_new());
        c.gtk_notebook_set_scrollable(notebook, c.TRUE);

        const pane = c.cast(c.GtkWidget, notebook);
        c.gtk_widget_set_size_request(pane, -1, page_height);
        c.gtk_widget_add_css_class(pane, "sysdeck-man");

        return .{ .notebook = notebook, .binding = binding };
    }

    pub fn extension(self: *Extension) extensions.Extension {
        return .{ .context = self, .vtable = &vtable };
    }
};

const vtable: extensions.Extension.VTable = .{
    .wants = &wants,
    .probe = &probe,
    .widget = &widget,
    .update = &update,
    .release = &release,
    .key = &key,
};

fn wants(_: *anyopaque, from: []const u8) bool {
    return std.mem.eql(u8, from, source);
}

fn widget(context: *anyopaque) *c.GtkWidget {
    const self: *Extension = @ptrCast(@alignCast(context));
    return c.cast(c.GtkWidget, self.notebook);
}

fn probe(
    _: *anyopaque,
    gpa: Allocator,
    target: extensions.Target,
) extensions.Error!extensions.Content {
    if (target.title.len == 0) return .nothing;

    const paths = capture(gpa, &.{ "man", "-aw", target.title }) catch return .nothing;
    defer if (paths) |text| gpa.free(text);

    var found: [max_sections]u8 = undefined;
    const count = sectionsOf(paths orelse "", &found);
    if (count == 0) return .nothing;

    var pages: std.ArrayList(extensions.Page) = .empty;
    errdefer freePages(gpa, &pages);

    for (found[0..count]) |section| {
        const label = try std.fmt.allocPrintSentinel(gpa, "{c}", .{section}, 0);
        errdefer gpa.free(label);

        const rendered = capture(gpa, &.{ "man", label, target.title }) catch null;
        const raw = rendered orelse {
            gpa.free(label);
            continue;
        };
        defer gpa.free(raw);

        try pages.append(gpa, .{ .label = label, .text = try plain(gpa, raw) });
    }

    if (pages.items.len == 0) {
        pages.deinit(gpa);
        return .nothing;
    }

    return .{ .pages = try pages.toOwnedSlice(gpa) };
}

fn update(context: *anyopaque, content: extensions.Content) void {
    const self: *Extension = @ptrCast(@alignCast(context));

    while (c.gtk_notebook_get_n_pages(self.notebook) > 0) {
        c.gtk_notebook_remove_page(self.notebook, 0);
    }

    const pages = switch (content) {
        .nothing => return,
        .pages => |found| found,
    };

    for (pages) |page| {
        const view = c.cast(c.GtkTextView, c.gtk_text_view_new());
        c.gtk_text_view_set_editable(view, c.FALSE);
        c.gtk_text_view_set_cursor_visible(view, c.FALSE);
        c.gtk_text_view_set_monospace(view, c.TRUE);
        c.gtk_text_view_set_wrap_mode(view, .none);
        c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(view), page.text.ptr, -1);

        const scroller = c.cast(c.GtkScrolledWindow, c.gtk_scrolled_window_new());
        c.gtk_scrolled_window_set_child(scroller, c.cast(c.GtkWidget, view));
        c.gtk_scrolled_window_set_policy(scroller, .automatic, .automatic);

        _ = c.gtk_notebook_append_page(
            self.notebook,
            c.cast(c.GtkWidget, scroller),
            c.gtk_label_new(page.label.ptr),
        );
    }

    c.gtk_notebook_set_current_page(self.notebook, 0);
}

fn release(_: *anyopaque, gpa: Allocator, content: extensions.Content) void {
    switch (content) {
        .nothing => {},
        .pages => |pages| {
            for (pages) |page| {
                gpa.free(page.label);
                gpa.free(page.text);
            }
            gpa.free(pages);
        },
    }
}

fn key(context: *anyopaque, keyval: c.guint, state: c.GdkModifierType) bool {
    const self: *Extension = @ptrCast(@alignCast(context));

    switch (keyval) {
        c.key_Page_Up, c.key_KP_Page_Up => return scroll(self, -1),
        c.key_Page_Down, c.key_KP_Page_Down => return scroll(self, 1),
        else => {},
    }

    const section = self.binding.numberOf(keyval, state) orelse return false;
    const at = pageOf(self, section) orelse return false;

    c.gtk_notebook_set_current_page(self.notebook, at);
    return true;
}

fn scroll(self: *const Extension, pages: f64) bool {
    const at = c.gtk_notebook_get_current_page(self.notebook);
    if (at < 0) return false;

    const child = c.gtk_notebook_get_nth_page(self.notebook, at) orelse return false;
    const adjustment = c.gtk_scrolled_window_get_vadjustment(c.cast(c.GtkScrolledWindow, child));

    const step = c.gtk_adjustment_get_page_size(adjustment) * pages;
    c.gtk_adjustment_set_value(adjustment, c.gtk_adjustment_get_value(adjustment) + step);
    return true;
}

fn pageOf(self: *const Extension, section: u8) ?c_int {
    var buffer: [2]u8 = undefined;
    const wanted = std.fmt.bufPrint(&buffer, "{d}", .{section}) catch return null;

    var at: c_int = 0;
    while (at < c.gtk_notebook_get_n_pages(self.notebook)) : (at += 1) {
        const child = c.gtk_notebook_get_nth_page(self.notebook, at) orelse continue;
        const label = c.gtk_notebook_get_tab_label_text(self.notebook, child) orelse continue;
        if (std.mem.eql(u8, std.mem.span(label), wanted)) return at;
    }
    return null;
}

fn freePages(gpa: Allocator, pages: *std.ArrayList(extensions.Page)) void {
    for (pages.items) |page| {
        gpa.free(page.label);
        gpa.free(page.text);
    }
    pages.deinit(gpa);
}

fn capture(gpa: Allocator, argv: []const []const u8) !?[]u8 {
    const parts = try gpa.allocSentinel(?[*:0]const u8, argv.len, null);
    defer {
        for (parts) |part| {
            if (part) |text| gpa.free(std.mem.span(text));
        }
        gpa.free(parts);
    }
    for (parts) |*part| part.* = null;
    for (argv, 0..) |part, at| parts[at] = (try gpa.dupeZ(u8, part)).ptr;

    const environ = environment();
    defer c.g_strfreev(environ);

    var out: ?[*:0]u8 = null;
    var status: c_int = 0;
    var err: ?*c.GError = null;

    const ran = c.g_spawn_sync(
        null,
        parts.ptr,
        @ptrCast(environ),
        c.spawn_search_path | c.spawn_stderr_to_dev_null,
        null,
        null,
        &out,
        null,
        &status,
        &err,
    ) != c.FALSE;

    if (!ran) {
        defer if (err) |detail| c.g_error_free(detail);
        return null;
    }

    const text = out orelse return null;
    defer c.g_free(text);

    if (status != 0) return null;

    const span = std.mem.span(text);
    if (span.len == 0 or span.len > max_output) return null;

    const valid = c.g_utf8_make_valid(text, @intCast(span.len));
    defer c.g_free(valid);

    return try gpa.dupe(u8, std.mem.span(valid));
}

fn environment() [*:null]?[*:0]u8 {
    var environ = c.g_get_environ();
    environ = c.g_environ_setenv(environ, "MANWIDTH", man_width, c.TRUE);
    environ = c.g_environ_setenv(environ, "MANPAGER", "cat", c.TRUE);
    environ = c.g_environ_setenv(environ, "PAGER", "cat", c.TRUE);
    return environ;
}

pub fn sectionsOf(paths: []const u8, out: *[max_sections]u8) usize {
    var count: usize = 0;

    var lines = std.mem.tokenizeScalar(u8, paths, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const section = sectionOf(trimmed) orelse continue;
        if (std.mem.indexOfScalar(u8, out[0..count], section) != null) continue;

        out[count] = section;
        count += 1;
        if (count == out.len) break;
    }

    std.mem.sort(u8, out[0..count], {}, std.sort.asc(u8));
    return count;
}

fn sectionOf(path: []const u8) ?u8 {
    const directory = std.fs.path.dirname(path) orelse return null;
    const folder = std.fs.path.basename(directory);
    if (!std.mem.startsWith(u8, folder, "man")) return null;

    const rest = folder["man".len..];
    if (rest.len == 0 or !std.ascii.isDigit(rest[0])) return null;
    return rest[0];
}

pub fn plain(gpa: Allocator, text: []const u8) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len + 1);

    var at: usize = 0;
    while (at < text.len) {
        if (at + 2 < text.len and text[at + 1] == 0x08) {
            at += 2;
            continue;
        }
        out.appendAssumeCapacity(text[at]);
        at += 1;
    }

    return out.toOwnedSliceSentinel(gpa, 0);
}

const testing = std.testing;

fn sections(paths: []const u8) []const u8 {
    const held = struct {
        var buffer: [max_sections]u8 = undefined;
    };
    return held.buffer[0..sectionsOf(paths, &held.buffer)];
}

test "the section comes from the containing directory" {
    try testing.expectEqual(@as(?u8, '1'), sectionOf("/usr/share/man/man1/sway.1.gz"));
    try testing.expectEqual(@as(?u8, '5'), sectionOf("/usr/share/man/man5/sway.5.gz"));
    try testing.expectEqual(@as(?u8, '3'), sectionOf("/usr/share/man/man3/Git.3pm.gz"));
    try testing.expectEqual(@as(?u8, '1'), sectionOf("/usr/share/man/man1/openssl-cmds.1ossl.gz"));
    try testing.expectEqual(@as(?u8, '8'), sectionOf("/usr/local/man/man8/rc.8"));
}

test "a path that is not a manual page yields no section" {
    try testing.expectEqual(@as(?u8, null), sectionOf("/usr/share/doc/readme"));
    try testing.expectEqual(@as(?u8, null), sectionOf("/usr/share/man/mann/tcl.n.gz"));
    try testing.expectEqual(@as(?u8, null), sectionOf("sway.1.gz"));
    try testing.expectEqual(@as(?u8, null), sectionOf(""));
}

test "sections are deduplicated and ordered" {
    try testing.expectEqualStrings("15", sections(
        \\/usr/share/man/man5/sway.5.gz
        \\/usr/share/man/man1/sway.1.gz
    ));

    try testing.expectEqualStrings("13", sections(
        \\/usr/share/man/man1/git.1.gz
        \\/usr/share/man/man3/Git.3pm.gz
    ));

    try testing.expectEqualStrings("15", sections(
        \\/usr/share/man/man1/passwd.1.gz
        \\/usr/share/man/man1/openssl-cmds.1ossl.gz
        \\/usr/share/man/man5/passwd.5.gz
    ));
}

test "nothing to read yields no sections" {
    try testing.expectEqualStrings("", sections(""));
    try testing.expectEqualStrings("", sections("No manual entry for definitelynotacommand\n"));
}

test "overstrike is stripped in both forms" {
    const gpa = testing.allocator;

    const bold = try plain(gpa, "N\x08NA\x08AM\x08ME\x08E");
    defer gpa.free(bold);
    try testing.expectEqualStrings("NAME", bold);

    const under = try plain(gpa, "_\x08f_\x08i_\x08l_\x08e");
    defer gpa.free(under);
    try testing.expectEqualStrings("file", under);
}

test "text without overstrike is left alone" {
    const gpa = testing.allocator;

    const kept = try plain(gpa, "ls - list directory contents\n");
    defer gpa.free(kept);
    try testing.expectEqualStrings("ls - list directory contents\n", kept);
}

test "this extension only registers for bins" {
    try testing.expect(wants(undefined, "bins"));
    try testing.expect(!wants(undefined, "apps"));
    try testing.expect(!wants(undefined, ""));
}
