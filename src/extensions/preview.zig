const std = @import("std");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const gio = @import("../gtk/gio.zig");
const glib = @import("../gtk/glib.zig");
const gtk = @import("../gtk/gtk.zig");
const exif = @import("preview/exif.zig");
const extensions = @import("../extensions.zig");
const launch = @import("../system/launch.zig");
const media = @import("core").media;
const picture_mod = @import("../system/picture.zig");
const Selection = @import("../ui/Selection.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.preview);

pub const name = "preview";

pub const default_height: i64 = 200;
pub const default_max_bytes: i64 = 10 << 20;

const animated = [_][]const u8{"image/gif"};

const max_width = 694;

const icon_size = 16;
const spacing = 6;
const caption_class = "sysdeck-caption";
const place_class = "sysdeck-place";
const reader_class = "sysdeck-reader";
const separator = " \u{00b7} ";
const map_host = "https://www.openstreetmap.org";
const map_zoom = 17;
const fallback_icon: [:0]const u8 = "image-x-generic";

pub const Extension = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    box: *c.GtkBox,
    image: *c.GtkImage,
    label: *c.GtkLabel,
    dot: *c.GtkLabel,
    place: *c.GtkLabel,
    picture: *c.GtkPicture,
    view: *c.GtkTextView,
    reader: *c.GtkScrolledWindow,
    stream: ?*c.GtkMediaStream = null,
    bounds: Bounds,
    max_bytes: usize,

    pub fn create(
        gpa: Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        height: c_int,
        max_bytes: usize,
    ) Allocator.Error!*Extension {
        const self = try gpa.create(Extension);
        errdefer gpa.destroy(self);

        exif.start();

        const box = c.cast(c.GtkBox, gtk.gtk_box_new(.vertical, spacing));

        const row = gtk.gtk_box_new(.horizontal, spacing);
        const image = c.cast(c.GtkImage, gtk.gtk_image_new());
        gtk.gtk_image_set_pixel_size(image, icon_size);
        gtk.gtk_box_append(c.cast(c.GtkBox, row), c.cast(c.GtkWidget, image));

        const line = c.cast(c.GtkBox, gtk.gtk_box_new(.horizontal, 0));
        const label = labelOf(line, caption_class);
        gtk.gtk_label_set_ellipsize(label, .middle);

        const dot = labelOf(line, caption_class);
        gtk.gtk_label_set_text(dot, separator);
        const place = labelOf(line, place_class);

        // It never scrolls. It reports the line's minimum width as its natural width,
        // so a long caption is ellipsized instead of widening the window.
        const clamp = c.cast(c.GtkScrolledWindow, gtk.gtk_scrolled_window_new());
        gtk.gtk_scrolled_window_set_policy(clamp, .never, .never);
        gtk.gtk_scrolled_window_set_child(clamp, c.cast(c.GtkWidget, line));
        gtk.gtk_widget_set_hexpand(c.cast(c.GtkWidget, clamp), c.TRUE);
        gtk.gtk_box_append(c.cast(c.GtkBox, row), c.cast(c.GtkWidget, clamp));
        gtk.gtk_box_append(box, row);

        const picture = c.cast(c.GtkPicture, gtk.gtk_picture_new());
        gtk.gtk_picture_set_content_fit(picture, .scale_down);
        gtk.gtk_picture_set_can_shrink(picture, c.TRUE);
        gtk.gtk_widget_set_size_request(c.cast(c.GtkWidget, picture), -1, height);
        gtk.gtk_box_append(box, c.cast(c.GtkWidget, picture));

        const view = c.cast(c.GtkTextView, gtk.gtk_text_view_new());
        gtk.gtk_text_view_set_editable(view, c.FALSE);
        gtk.gtk_text_view_set_cursor_visible(view, c.FALSE);
        gtk.gtk_text_view_set_monospace(view, c.TRUE);
        gtk.gtk_text_view_set_wrap_mode(view, .word_char);
        gtk.gtk_widget_set_can_focus(c.cast(c.GtkWidget, view), c.FALSE);
        Selection.attach(view);

        const reader = c.cast(c.GtkScrolledWindow, gtk.gtk_scrolled_window_new());
        gtk.gtk_scrolled_window_set_child(reader, c.cast(c.GtkWidget, view));
        gtk.gtk_scrolled_window_set_policy(reader, .never, .automatic);
        gtk.gtk_scrolled_window_set_propagate_natural_height(reader, c.TRUE);
        gtk.gtk_scrolled_window_set_max_content_height(reader, height);
        gtk.gtk_widget_add_css_class(c.cast(c.GtkWidget, reader), reader_class);
        gtk.gtk_box_append(box, c.cast(c.GtkWidget, reader));

        self.* = .{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .box = box,
            .image = image,
            .label = label,
            .dot = dot,
            .place = place,
            .picture = picture,
            .view = view,
            .reader = reader,
            .bounds = .{ .width = max_width, .height = height },
            .max_bytes = max_bytes,
        };

        _ = c.connect(place, "activate-link", &onLink, self);
        glib.g_object_set_data_full(c.cast(c.GtkWidget, box), owner_key, self, &onFinalized);
        return self;
    }

    pub fn extension(self: *Extension) extensions.Extension {
        return .{ .context = self, .vtable = extensions.vtableOf(Extension) };
    }

    fn say(self: *Extension, caption: [:0]const u8, place: ?media.Place) void {
        gtk.gtk_label_set_text(self.label, caption.ptr);

        const marked = if (place) |found| markupOf(self.gpa, found) else null;
        defer if (marked) |text| self.gpa.free(text);

        if (marked) |text| gtk.gtk_label_set_markup(self.place, text.ptr);
        gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, self.dot), on(marked != null));
        gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, self.place), on(marked != null));
    }

    fn show(self: *Extension, what: Showing) void {
        gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, self.picture), on(what == .drawing));
        gtk.gtk_widget_set_visible(c.cast(c.GtkWidget, self.reader), on(what == .reading));
    }

    fn clear(self: *Extension) void {
        self.show(.caption);
        gtk.gtk_picture_set_paintable(self.picture, null);
        const current = self.stream orelse return;
        gtk.gtk_media_file_clear(c.cast(c.GtkMediaFile, current));
        glib.g_object_unref(current);
        self.stream = null;
    }

    pub fn wants(_: ?*Extension, target: extensions.Target) bool {
        return target.media != null;
    }

    pub fn widget(self: *Extension) *c.GtkWidget {
        return c.cast(c.GtkWidget, self.box);
    }

    pub fn probe(
        self: *Extension,
        gpa: Allocator,
        target: extensions.Target,
    ) extensions.Error!extensions.Content {
        const handle = target.media orelse return .nothing;
        const kind = handle.kind();

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const scratch = arena.allocator();

        if (kind != .image and kind != .text) return try only(gpa, scratch, handle);

        if (handle.size > self.max_bytes) {
            var buffer: [32]u8 = undefined;
            log.warn(
                "\"{s}\" is {s}, more than [extensions.preview] max_bytes = {d}, " ++
                    "so the preview shows only its type and size",
                .{ target.title, media.size(&buffer, handle.size), self.max_bytes },
            );
            return try only(gpa, scratch, handle);
        }

        const payload = handle.open(scratch) orelse {
            log.warn(
                "cannot load \"{s}\" from the {s} source, so the preview shows only its type and size",
                .{ target.title, target.source },
            );
            return try only(gpa, scratch, handle);
        };
        const bytes = switch (payload) {
            .bytes => |found| found,
            .path => |found| self.read(scratch, found) orelse
                return try only(gpa, scratch, handle),
        };

        var reading = if (kind == .image) try exif.read(scratch, bytes) else exif.Reading{};

        const frame: extensions.Frame = if (kind == .text)
            .{ .text = try readable(gpa, bytes) }
        else if (moves(handle.mime) and fits(reading, self.bounds))
            .{ .motion = glib.g_bytes_new(bytes.ptr, bytes.len) }
        else if (stillOf(bytes, self.bounds, target.title)) |drawn| block: {
            reading.width = count(drawn.width);
            reading.height = count(drawn.height);
            break :block .{ .still = drawn.texture };
        } else .none;

        return .{ .preview = .{
            .kind = kind,
            .icon = try iconOf(gpa, handle.mime),
            .caption = try captionOf(gpa, scratch, handle, reading),
            .place = reading.place,
            .frame = frame,
        } };
    }

    fn read(self: *Extension, arena: Allocator, path: []const u8) ?[]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            arena,
            .limited(self.max_bytes),
        ) catch |err| {
            log.warn(
                "cannot read {s}: {t}, so the preview shows only its type and size",
                .{ path, err },
            );
            return null;
        };
    }

    pub fn update(self: *Extension, content: extensions.Content) void {
        const found = switch (content) {
            .preview => |shown| shown,
            else => return,
        };

        self.clear();
        setIcon(self.image, found.icon);
        self.say(found.caption, found.place);

        switch (found.frame) {
            .none => return,
            .text => |body| {
                gtk.gtk_text_buffer_set_text(gtk.gtk_text_view_get_buffer(self.view), body.ptr, -1);
                return self.show(.reading);
            },
            .still => |texture| gtk.gtk_picture_set_paintable(
                self.picture,
                c.cast(c.GdkPaintable, texture),
            ),
            .motion => |bytes| {
                const source = gio.g_memory_input_stream_new_from_bytes(bytes);
                defer glib.g_object_unref(source);

                const file = gtk.gtk_media_file_new_for_input_stream(c.cast(c.GInputStream, source));
                const stream = c.cast(c.GtkMediaStream, file);
                gtk.gtk_media_stream_set_loop(stream, c.TRUE);
                gtk.gtk_media_stream_play(stream);

                self.stream = stream;
                gtk.gtk_picture_set_paintable(self.picture, c.cast(c.GdkPaintable, stream));
            },
        }

        self.show(.drawing);
    }

    pub fn release(_: *Extension, gpa: Allocator, content: extensions.Content) void {
        switch (content) {
            .nothing, .pages => {},
            .preview => |found| {
                gpa.free(found.icon);
                gpa.free(found.caption);
                switch (found.frame) {
                    .none => {},
                    .text => |body| gpa.free(body),
                    .still => |texture| glib.g_object_unref(texture),
                    .motion => |bytes| glib.g_bytes_unref(bytes),
                }
            },
        }
    }

    pub fn key(_: *Extension, _: c.guint, _: c.GdkModifierType) bool {
        return false;
    }
};

const owner_key: [*:0]const u8 = "sysdeck-preview";

fn onFinalized(data: c.gpointer) callconv(.c) void {
    const self: *Extension = @ptrCast(@alignCast(data.?));
    self.gpa.destroy(self);
}

const Showing = enum { caption, drawing, reading };

fn on(wanted: bool) c.gboolean {
    return if (wanted) c.TRUE else c.FALSE;
}

fn labelOf(line: *c.GtkBox, class: [*:0]const u8) *c.GtkLabel {
    const made = gtk.gtk_label_new(null);
    const label = c.cast(c.GtkLabel, made);
    gtk.gtk_label_set_xalign(label, 0);
    gtk.gtk_widget_add_css_class(made, class);
    gtk.gtk_box_append(line, made);
    return label;
}

pub const Bounds = struct {
    width: c_int = max_width,
    height: c_int = @intCast(default_height),
};

fn readable(gpa: Allocator, bytes: []const u8) Allocator.Error![:0]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return gpa.dupeZ(u8, bytes);

    const owned = try gpa.dupeZ(u8, bytes);
    defer gpa.free(owned);

    const made = glib.g_utf8_make_valid(owned.ptr, @intCast(owned.len));
    defer glib.g_free(made);

    return gpa.dupeZ(u8, std.mem.span(made));
}

fn only(
    gpa: Allocator,
    arena: Allocator,
    handle: media.Handle,
) extensions.Error!extensions.Content {
    return .{ .preview = .{
        .kind = handle.kind(),
        .icon = try iconOf(gpa, handle.mime),
        .caption = try captionOf(gpa, arena, handle, .{}),
        .frame = .none,
    } };
}

fn moves(mime: []const u8) bool {
    for (animated) |kind| {
        if (std.mem.eql(u8, mime, kind)) return true;
    }
    return false;
}

fn count(value: c_int) u32 {
    return std.math.cast(u32, value) orelse 0;
}

fn fits(reading: exif.Reading, bounds: Bounds) bool {
    if (reading.width == 0 or reading.height == 0) return true;
    return reading.width <= count(bounds.width) and reading.height <= count(bounds.height);
}

const Drawn = struct {
    texture: *c.GdkTexture,
    width: c_int,
    height: c_int,
};

fn stillOf(bytes: []const u8, bounds: Bounds, title: []const u8) ?Drawn {
    const decoded = switch (picture_mod.decode(bytes, .{ .width = bounds.width, .height = bounds.height })) {
        .picture => |found| found,
        .failed => |problem| {
            defer problem.deinit();
            log.warn("cannot decode \"{s}\": {f}, so the preview shows no picture", .{ title, problem });
            return null;
        },
    };
    defer decoded.deinit();

    return .{
        .texture = gdk.gdk_texture_new_for_pixbuf(decoded.pixbuf),
        .width = decoded.width,
        .height = decoded.height,
    };
}

fn onLink(_: *c.GtkLabel, uri: [*:0]const u8, data: c.gpointer) callconv(.c) c.gboolean {
    const self: *Extension = @ptrCast(@alignCast(data.?));
    _ = launch.uri(self.gpa, self.environ, std.mem.span(uri));
    return c.TRUE;
}

fn markupOf(gpa: Allocator, place: media.Place) ?[:0]u8 {
    var link: [160]u8 = undefined;
    const href = mapUrl(&link, place) orelse return null;

    var shown: [48]u8 = undefined;
    const where = coordinates(&shown, place) orelse return null;

    const target = escaped(href) orelse return null;
    defer glib.g_free(target);

    return std.fmt.allocPrintSentinel(gpa, "<a href=\"{s}\">{s}</a>", .{
        std.mem.span(target),
        where,
    }, 0) catch null;
}

fn escaped(text: []const u8) ?[*:0]u8 {
    return glib.g_markup_escape_text(text.ptr, @intCast(text.len));
}

pub fn mapUrl(buffer: []u8, place: media.Place) ?[]const u8 {
    return std.fmt.bufPrint(
        buffer,
        map_host ++ "/?mlat={d:.6}&mlon={d:.6}#map={d}/{d:.6}/{d:.6}",
        .{ place.latitude, place.longitude, map_zoom, place.latitude, place.longitude },
    ) catch null;
}

pub fn coordinates(buffer: []u8, place: media.Place) ?[]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{d:.4}, {d:.4}",
        .{ place.latitude, place.longitude },
    ) catch null;
}

fn setIcon(image: *c.GtkImage, text: [:0]const u8) void {
    const icon = gio.g_icon_new_for_string(text.ptr, null) orelse {
        return gtk.gtk_image_set_from_icon_name(image, fallback_icon.ptr);
    };
    defer glib.g_object_unref(icon);
    gtk.gtk_image_set_from_gicon(image, icon);
}

fn iconOf(gpa: Allocator, mime: []const u8) Allocator.Error![:0]const u8 {
    const wanted = try gpa.dupeZ(u8, mime);
    defer gpa.free(wanted);

    const icon = gio.g_content_type_get_icon(wanted.ptr) orelse return gpa.dupeZ(u8, fallback_icon);
    defer glib.g_object_unref(icon);

    const text = gio.g_icon_to_string(icon) orelse return gpa.dupeZ(u8, fallback_icon);
    defer glib.g_free(text);

    return gpa.dupeZ(u8, std.mem.span(text));
}

fn describe(arena: Allocator, mime: []const u8) Allocator.Error![]const u8 {
    const wanted = try arena.dupeZ(u8, mime);

    const text = gio.g_content_type_get_description(wanted.ptr) orelse return mime;
    defer glib.g_free(text);

    return arena.dupe(u8, std.mem.span(text));
}

fn captionOf(
    gpa: Allocator,
    arena: Allocator,
    handle: media.Handle,
    reading: exif.Reading,
) Allocator.Error![:0]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;

    try parts.append(arena, try describe(arena, handle.mime));

    if (reading.width > 0 and reading.height > 0) {
        try parts.append(arena, try std.fmt.allocPrint(
            arena,
            "{d}\u{00d7}{d}",
            .{ reading.width, reading.height },
        ));
    }

    var buffer: [32]u8 = undefined;
    if (handle.size > 0) {
        try parts.append(arena, try arena.dupe(u8, media.size(&buffer, handle.size)));
    }

    for (reading.fields) |field| try parts.append(arena, field);

    const joined = try std.mem.join(arena, separator, parts.items);
    return gpa.dupeZ(u8, joined);
}

const testing = std.testing;

fn handleOf(mime: []const u8, size: u64) media.Handle {
    return .{
        .mime = mime,
        .size = size,
        .id = 1,
        .context = null,
        .load = &nothing,
    };
}

fn nothing(_: ?*anyopaque, _: Allocator, _: u64) ?media.Payload {
    return null;
}

fn captioned(handle: media.Handle, reading: exif.Reading) ![:0]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return captionOf(testing.allocator, arena.allocator(), handle, reading);
}

test "a caption carries the type, the size and the dimensions" {
    const found = try captioned(
        handleOf("image/png", 246_016),
        .{ .width = 1920, .height = 1080 },
    );
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("PNG image \u{00b7} 1920\u{00d7}1080 \u{00b7} 246.0 kB", found);
}

test "an image with no dimensions leaves them out rather than showing zeroes" {
    const found = try captioned(handleOf("image/svg+xml", 1_024), .{});
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("SVG image \u{00b7} 1.0 kB", found);
}

test "the exif fields follow the size in the order they were read" {
    const found = try captioned(handleOf("image/jpeg", 2_400_000), .{
        .width = 6240,
        .height = 4160,
        .fields = &.{ "FUJIFILM", "X100V", "1/250 s", "f/2.0", "320" },
    });
    defer testing.allocator.free(found);

    try testing.expectEqualStrings(
        "JPEG image \u{00b7} 6240\u{00d7}4160 \u{00b7} 2.4 MB \u{00b7} FUJIFILM \u{00b7} X100V \u{00b7} 1/250 s \u{00b7} f/2.0 \u{00b7} 320",
        found,
    );
}

fn mapped(latitude: f64, longitude: f64) []const u8 {
    const held = struct {
        var buffer: [160]u8 = undefined;
    };
    return mapUrl(&held.buffer, .{ .latitude = latitude, .longitude = longitude }) orelse "";
}

fn shownAt(latitude: f64, longitude: f64) []const u8 {
    const held = struct {
        var buffer: [48]u8 = undefined;
    };
    return coordinates(&held.buffer, .{ .latitude = latitude, .longitude = longitude }) orelse "";
}

test "a coordinate becomes a map link with a pin on it" {
    try testing.expectEqualStrings(
        "https://www.openstreetmap.org/?mlat=52.516300&mlon=13.377700" ++
            "#map=17/52.516300/13.377700",
        mapped(52.5163, 13.3777),
    );
}

test "the southern and western hemispheres keep their sign" {
    try testing.expectEqualStrings(
        "https://www.openstreetmap.org/?mlat=-33.856800&mlon=151.215200" ++
            "#map=17/-33.856800/151.215200",
        mapped(-33.8568, 151.2152),
    );
    try testing.expect(std.mem.indexOf(u8, mapped(-1.5, -78.25), "mlat=-1.500000") != null);
    try testing.expect(std.mem.indexOf(u8, mapped(-1.5, -78.25), "mlon=-78.250000") != null);
}

test "the coordinates read shorter than the link they point at" {
    try testing.expectEqualStrings("52.5163, 13.3777", shownAt(52.5163, 13.3777));
    try testing.expectEqualStrings("-33.8568, 151.2152", shownAt(-33.8568, 151.2152));
    try testing.expectEqualStrings("0.0000, 0.0000", shownAt(0, 0));
}

test "a place becomes an anchor on its coordinates" {
    const marked = markupOf(testing.allocator, .{ .latitude = 52.5163, .longitude = 13.3777 }).?;
    defer testing.allocator.free(marked);

    try testing.expect(std.mem.startsWith(u8, marked, "<a href=\"https://www.openstreetmap.org/"));
    try testing.expect(std.mem.endsWith(u8, marked, "\">52.5163, 13.3777</a>"));

    // Pango parses the href as XML, so a bare ampersand there loses the link.
    try testing.expect(std.mem.indexOf(u8, marked, "mlat=52.516300&amp;mlon=") != null);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, marked, "&mlon"));
}

test "an entry that is not an image still gets a caption" {
    const found = try captioned(handleOf("audio/mpeg", 2_107), .{});
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("MP3 audio \u{00b7} 2.1 kB", found);
}

fn targetOf(handle: ?media.Handle) extensions.Target {
    return .{ .source = "clipboard", .title = "", .detail = "", .media = handle };
}

test "a row with nothing to preview is not wanted" {
    try testing.expect(!Extension.wants(null, targetOf(null)));
}

test "anything with content behind it is taken" {
    try testing.expect(Extension.wants(null, targetOf(handleOf("text/plain", 10))));
    try testing.expect(Extension.wants(null, targetOf(handleOf("text/html", 10))));
    try testing.expect(Extension.wants(null, targetOf(handleOf("image/png", 10))));
    try testing.expect(Extension.wants(null, targetOf(handleOf("audio/mpeg", 10))));
    try testing.expect(Extension.wants(null, targetOf(handleOf("video/mp4", 10))));
    try testing.expect(Extension.wants(null, targetOf(handleOf("application/pdf", 10))));
}

fn readableText(bytes: []const u8) ![:0]const u8 {
    return readable(testing.allocator, bytes);
}

test "text that is already utf-8 goes through untouched" {
    const found = try readableText("hello \u{00e4}\u{00f6}\u{00fc} \u{4e16}\u{754c}");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("hello \u{00e4}\u{00f6}\u{00fc} \u{4e16}\u{754c}", found);
}

test "newlines and tabs survive, since the pane shows the text as it was copied" {
    const found = try readableText("first\n\tsecond\n\nthird\n");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("first\n\tsecond\n\nthird\n", found);
}

test "bytes that are not utf-8 are made into something the buffer accepts" {
    const found = try readableText("caf\xe9 latte\xff");
    defer testing.allocator.free(found);

    try testing.expect(std.unicode.utf8ValidateSlice(found));
    try testing.expect(std.mem.indexOf(u8, found, "latte") != null);
}

test "an empty selection reads as empty" {
    const found = try readableText("");
    defer testing.allocator.free(found);

    try testing.expectEqualStrings("", found);
}

test "an icon is resolved for a known type and falls back for a broken one" {
    const png = try iconOf(testing.allocator, "image/png");
    defer testing.allocator.free(png);
    try testing.expect(std.mem.indexOf(u8, png, "image-x-generic") != null);

    const broken = try iconOf(testing.allocator, "");
    defer testing.allocator.free(broken);
    try testing.expect(broken.len > 0);
}
