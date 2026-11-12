const std = @import("std");
const c = @import("../gtk/c.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const extensions = @import("../extensions.zig");
const keys = @import("../ui/keys.zig");
const launch = @import("../system/launch.zig");
const Selection = @import("../ui/Selection.zig");
const tables = @import("core").tables;

const Allocator = std.mem.Allocator;

pub const name = "man";

const max_sections = 16;
const max_paths = 1 << 20;
const max_page = 8 << 20;
const page_height = 300;
const man_width = "78";

pub const Extension = struct {
    gpa: Allocator,
    notebook: *c.GtkNotebook,
    binding: keys.Numbered,

    pub fn create(gpa: Allocator, binding: keys.Numbered) Allocator.Error!*Extension {
        const self = try gpa.create(Extension);
        errdefer gpa.destroy(self);

        const notebook = c.cast(c.GtkNotebook, gtk.gtk_notebook_new());
        gtk.gtk_notebook_set_scrollable(notebook, c.TRUE);

        const pane = c.cast(c.GtkWidget, notebook);
        gtk.gtk_widget_set_size_request(pane, -1, page_height);
        gtk.gtk_widget_add_css_class(pane, "sysdeck-man");

        self.* = .{ .gpa = gpa, .notebook = notebook, .binding = binding };
        glib.g_object_set_data_full(c.cast(c.GObject, pane), owner_key, self, &onFinalized);
        return self;
    }

    pub fn extension(self: *Extension) extensions.Extension {
        return .{ .context = self, .vtable = extensions.vtableOf(Extension) };
    }

    pub fn wants(_: ?*Extension, target: extensions.Target) bool {
        return std.mem.eql(u8, target.source, tables.bins);
    }

    pub fn widget(self: *Extension) *c.GtkWidget {
        return c.cast(c.GtkWidget, self.notebook);
    }

    pub fn probe(
        _: *Extension,
        gpa: Allocator,
        target: extensions.Target,
    ) extensions.Error!extensions.Content {
        return pagesOf(gpa, "man", target.title);
    }

    pub fn update(self: *Extension, content: extensions.Content) void {
        while (gtk.gtk_notebook_get_n_pages(self.notebook) > 0) {
            gtk.gtk_notebook_remove_page(self.notebook, 0);
        }

        const pages = switch (content) {
            .pages => |found| found,
            else => return,
        };

        for (pages) |page| {
            const view = c.cast(c.GtkTextView, gtk.gtk_text_view_new());
            gtk.gtk_text_view_set_editable(view, c.FALSE);
            gtk.gtk_text_view_set_cursor_visible(view, c.FALSE);
            gtk.gtk_text_view_set_monospace(view, c.TRUE);
            gtk.gtk_text_view_set_wrap_mode(view, .none);
            gtk.gtk_text_buffer_set_text(gtk.gtk_text_view_get_buffer(view), page.text.ptr, -1);
            Selection.attach(view);

            const scroller = c.cast(c.GtkScrolledWindow, gtk.gtk_scrolled_window_new());
            gtk.gtk_scrolled_window_set_child(scroller, c.cast(c.GtkWidget, view));
            gtk.gtk_scrolled_window_set_policy(scroller, .automatic, .automatic);

            _ = gtk.gtk_notebook_append_page(
                self.notebook,
                c.cast(c.GtkWidget, scroller),
                gtk.gtk_label_new(page.label.ptr),
            );
        }

        gtk.gtk_notebook_set_current_page(self.notebook, 0);
    }

    pub fn release(_: ?*Extension, gpa: Allocator, content: extensions.Content) void {
        switch (content) {
            .nothing, .preview => {},
            .pages => |pages| {
                for (pages) |page| {
                    gpa.free(page.label);
                    gpa.free(page.text);
                }
                gpa.free(pages);
            },
        }
    }

    pub fn key(self: *Extension, keyval: c.guint, state: c.GdkModifierType) bool {
        switch (keyval) {
            c.key_Page_Up, c.key_KP_Page_Up => return scroll(self, -1),
            c.key_Page_Down, c.key_KP_Page_Down => return scroll(self, 1),
            else => {},
        }

        const section = self.binding.numberOf(keyval, state) orelse return false;
        const at = pageOf(self, section) orelse return false;

        gtk.gtk_notebook_set_current_page(self.notebook, at);
        return true;
    }
};

const owner_key: [*:0]const u8 = "sysdeck-man";

fn onFinalized(data: c.gpointer) callconv(.c) void {
    const self: *Extension = @ptrCast(@alignCast(data.?));
    self.gpa.destroy(self);
}

fn scroll(self: *const Extension, pages: f64) bool {
    const at = gtk.gtk_notebook_get_current_page(self.notebook);
    if (at < 0) return false;

    const child = gtk.gtk_notebook_get_nth_page(self.notebook, at) orelse return false;
    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(c.cast(c.GtkScrolledWindow, child));

    const step = gtk.gtk_adjustment_get_page_size(adjustment) * pages;
    gtk.gtk_adjustment_set_value(adjustment, gtk.gtk_adjustment_get_value(adjustment) + step);
    return true;
}

fn pageOf(self: *const Extension, section: u8) ?c_int {
    var buffer: [2]u8 = undefined;
    const wanted = std.mem.print(&buffer, "{d}", .{section}) catch return null;

    var at: c_int = 0;
    while (at < gtk.gtk_notebook_get_n_pages(self.notebook)) : (at += 1) {
        const child = gtk.gtk_notebook_get_nth_page(self.notebook, at) orelse continue;
        const label = gtk.gtk_notebook_get_tab_label_text(self.notebook, child) orelse continue;
        if (std.mem.eql(u8, std.mem.span(label), wanted)) return at;
    }
    return null;
}

fn pagesOf(gpa: Allocator, program: [:0]const u8, title: []const u8) extensions.Error!extensions.Content {
    if (!askable(title)) return .nothing;

    const environ = environment();
    defer glib.g_strfreev(environ);

    const paths = try launch.capture(gpa, &.{ program, "-aw", title }, environ, max_paths);
    defer if (paths) |text| gpa.free(text);

    var found: [max_sections]u8 = undefined;
    const count = sectionsOf(paths orelse "", &found);
    if (count == 0) return .nothing;

    var pages: std.ArrayList(extensions.Page) = .empty;
    errdefer freePages(gpa, &pages);

    for (found[0..count]) |section| {
        const label = try gpa.printSentinel("{c}", .{section}, 0);
        errdefer gpa.free(label);

        const raw = try launch.capture(gpa, &.{ program, label, title }, environ, max_page) orelse {
            gpa.free(label);
            continue;
        };
        defer gpa.free(raw);

        const text = try plain(gpa, raw);
        errdefer gpa.free(text);

        try pages.append(gpa, .{ .label = label, .text = text });
    }

    if (pages.items.len == 0) {
        pages.deinit(gpa);
        return .nothing;
    }

    return .{ .pages = try pages.toOwnedSlice(gpa) };
}

fn freePages(gpa: Allocator, pages: *std.ArrayList(extensions.Page)) void {
    for (pages.items) |page| {
        gpa.free(page.label);
        gpa.free(page.text);
    }
    pages.deinit(gpa);
}

fn environment() [*:null]?[*:0]u8 {
    var environ = glib.g_get_environ();
    environ = glib.g_environ_setenv(environ, "MANWIDTH", man_width, c.TRUE);
    environ = glib.g_environ_setenv(environ, "MANPAGER", "cat", c.TRUE);
    environ = glib.g_environ_setenv(environ, "PAGER", "cat", c.TRUE);
    return environ;
}

fn sectionsOf(paths: []const u8, out: *[max_sections]u8) usize {
    var count: usize = 0;

    var lines = std.mem.tokenizeScalar(u8, paths, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const section = sectionOf(trimmed) orelse continue;
        if (std.mem.findScalar(u8, out[0..count], section) != null) continue;

        out[count] = section;
        count += 1;
        if (count == out.len) break;
    }

    std.mem.sort(u8, out[0..count], {}, std.sort.asc(u8));
    return count;
}

fn sectionOf(path: []const u8) ?u8 {
    const directory = std.Io.Dir.path.dirname(path) orelse return null;
    const folder = std.Io.Dir.path.basename(directory);
    if (!std.mem.startsWith(u8, folder, "man")) return null;

    const rest = folder["man".len..];
    if (rest.len == 0 or !std.ascii.isDigit(rest[0])) return null;
    return rest[0];
}

fn askable(title: []const u8) bool {
    return title.len > 0 and title[0] != '-';
}

fn plain(gpa: Allocator, text: []const u8) Allocator.Error![:0]u8 {
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
const tmpPath = @import("core").xdg.tmpPath;

fn sections(paths: []const u8) []const u8 {
    const held = struct {
        var buffer: [max_sections]u8 = undefined;
    };
    return held.buffer[0..sectionsOf(paths, &held.buffer)];
}

test "the section comes from the containing directory" {
    try testing.expectEqual('1', sectionOf("/usr/share/man/man1/sway.1.gz"));
    try testing.expectEqual('5', sectionOf("/usr/share/man/man5/sway.5.gz"));
    try testing.expectEqual('3', sectionOf("/usr/share/man/man3/Git.3pm.gz"));
    try testing.expectEqual('1', sectionOf("/usr/share/man/man1/openssl-cmds.1ossl.gz"));
    try testing.expectEqual('8', sectionOf("/usr/local/man/man8/rc.8"));
}

test "a path that is not a manual page yields no section" {
    try testing.expectEqual(null, sectionOf("/usr/share/doc/readme"));
    try testing.expectEqual(null, sectionOf("/usr/share/man/mann/tcl.n.gz"));
    try testing.expectEqual(null, sectionOf("sway.1.gz"));
    try testing.expectEqual(null, sectionOf(""));
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

fn from(origin: []const u8) extensions.Target {
    return .{ .source = origin, .title = "", .detail = "" };
}

test "this extension only registers for bins" {
    try testing.expect(Extension.wants(null, from("bins")));
    try testing.expect(!Extension.wants(null, from("apps")));
    try testing.expect(!Extension.wants(null, from("")));
}

test askable {
    try testing.expect(askable("ls"));
    try testing.expect(askable("clang-19"));
    try testing.expect(!askable(""));
    try testing.expect(!askable("-oProxyCommand=id"));
    try testing.expect(!askable("--help"));
}

const fake_man =
    \\#!/bin/sh
    \\case "$1" in
    \\  -aw) printf '/usr/share/man/man1/%s.1.gz\n/usr/share/man/man5/%s.5.gz\n' "$2" "$2" ;;
    \\  *) printf 'N\bNA\bAM\bME\bE\n  %s(%s)\n' "$2" "$1" ;;
    \\esac
    \\
;

fn probed(gpa: Allocator, program: [:0]const u8) !void {
    const content = try pagesOf(gpa, program, "fake");
    defer Extension.release(null, gpa, content);

    const pages = switch (content) {
        .pages => |found| found,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(2, pages.len);
    try testing.expectEqualStrings("1", pages[0].label);
    try testing.expectEqualStrings("5", pages[1].label);
    try testing.expect(std.mem.startsWith(u8, pages[0].text, "NAME\n"));
    try testing.expect(std.mem.find(u8, pages[1].text, "fake(5)") != null);
}

test "a page is read for every section, and running out of memory leaves nothing behind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "man",
        .data = fake_man,
        .flags = .{ .permissions = .executable_file },
    });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const program = try tmpPath(&tmp, &buffer, "man");

    try testing.checkAllAllocationFailures(testing.allocator, probed, .{program});
}
