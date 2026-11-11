const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub const max_bytes = 1 << 20;
const max_redirects = 3;
const marker = "none";

pub const Kind = enum { png, ico, svg, jpg, gif, webp };

pub const Found = union(enum) {
    file: [:0]const u8,
    failed,
};

pub const Listing = struct {
    entries: std.StringHashMapUnmanaged(Found) = .empty,

    pub fn get(self: *const Listing, stem: []const u8) ?Found {
        return self.entries.get(stem);
    }
};

pub const Image = struct {
    kind: Kind,
    bytes: []u8,
};

pub const Failure = union(enum) {
    status: std.http.Status,
    too_large: usize,
    not_an_image,
    malformed,
    unsupported,
    expired: Io.Duration,
    cause: anyerror,

    pub fn format(self: Failure, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .status => |status| try writer.print("HTTP {d}", .{@backingInt(status)}),
            .too_large => |limit| try writer.print("it is larger than {d} bytes", .{limit}),
            .not_an_image => try writer.writeAll("it is not an image"),
            .malformed => try writer.writeAll("the URL cannot be read"),
            .unsupported => try writer.writeAll("only file, http(s) and data URLs are read"),
            .expired => |budget| try writer.print("it took longer than {d} ms", .{budget.toMilliseconds()}),
            .cause => |err| try writer.print("{t}", .{err}),
        }
    }
};

pub const Fetched = union(enum) {
    image: Image,
    failed: Failure,
};

pub fn kindOf(bytes: []const u8) ?Kind {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "\x00\x00\x01\x00")) return .ico;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpg;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return .gif;
    if (isWebp(bytes)) return .webp;
    if (isSvg(bytes)) return .svg;
    return null;
}

fn isWebp(bytes: []const u8) bool {
    if (bytes.len < 12) return false;
    return std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
}

fn isSvg(bytes: []const u8) bool {
    const bom = "\xef\xbb\xbf";
    var rest = if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes;

    while (true) {
        rest = std.mem.trimStart(u8, rest, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, rest, "<svg")) {
            return rest.len == 4 or !isNameChar(rest[4]);
        }

        const closing: []const u8 = if (std.mem.startsWith(u8, rest, "<?"))
            "?>"
        else if (std.mem.startsWith(u8, rest, "<!--"))
            "-->"
        else if (std.mem.startsWith(u8, rest, "<!"))
            ">"
        else
            return false;

        const end = std.mem.find(u8, rest, closing) orelse return false;
        rest = rest[end + closing.len ..];
    }
}

fn isNameChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == ':' or char == '.';
}

pub fn stemOf(url: []const u8) [16]u8 {
    var stem: [16]u8 = undefined;
    _ = std.mem.print(&stem, "{x:0>16}", .{std.hash.XxHash3.hash(0, url)}) catch unreachable;
    return stem;
}

pub fn scan(arena: Allocator, io: Io, dir: []const u8) Allocator.Error!Listing {
    var listing: Listing = .{};

    var opened = Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return listing;
    defer opened.close(io);

    var walker = opened.iterate();
    while (walker.next(io) catch return listing) |entry| {
        if (entry.kind != .file) continue;

        const dot = std.mem.findScalarLast(u8, entry.name, '.') orelse continue;
        const stem = entry.name[0..dot];
        const extension = entry.name[dot + 1 ..];

        if (std.mem.eql(u8, extension, marker)) {
            const slot = try listing.entries.getOrPut(arena, try arena.dupe(u8, stem));
            if (!slot.found_existing) slot.value_ptr.* = .failed;
            continue;
        }

        if (std.meta.stringToEnum(Kind, extension) == null) continue;
        const file = try std.Io.Dir.path.joinZ(arena, &.{ dir, entry.name });
        try listing.entries.put(arena, try arena.dupe(u8, stem), .{ .file = file });
    }
    return listing;
}

pub fn store(gpa: Allocator, io: Io, dir: []const u8, stem: []const u8, image: Image) !void {
    const name = try gpa.print("{s}.{t}", .{ stem, image.kind });
    defer gpa.free(name);
    try write(gpa, io, dir, name, image.bytes);
}

pub fn mark(gpa: Allocator, io: Io, dir: []const u8, stem: []const u8) ![]u8 {
    const name = try gpa.print("{s}.{s}", .{ stem, marker });
    defer gpa.free(name);
    try write(gpa, io, dir, name, "");
    return std.Io.Dir.path.join(gpa, &.{ dir, name });
}

fn write(gpa: Allocator, io: Io, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const file_path = try std.Io.Dir.path.join(gpa, &.{ dir, name });
    defer gpa.free(file_path);

    var atomic = try Dir.cwd().createFileAtomic(io, file_path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

pub fn load(
    client: *std.http.Client,
    gpa: Allocator,
    io: Io,
    url: []const u8,
    limit: usize,
) Allocator.Error!Fetched {
    if (isRemote(url)) return fetch(client, gpa, url, limit);
    if (std.ascii.startsWithIgnoreCase(url, "data:")) return decoded(gpa, url, limit);
    if (std.ascii.startsWithIgnoreCase(url, "file:")) return read(gpa, io, url, limit);
    return .{ .failed = .unsupported };
}

const Race = union(enum) {
    loaded: Allocator.Error!Fetched,
    expired: Io.Cancelable!void,
};

pub fn loadWithin(
    client: *std.http.Client,
    gpa: Allocator,
    io: Io,
    url: []const u8,
    limit: usize,
    budget: Io.Duration,
) (Allocator.Error || Io.Cancelable || Io.ConcurrentError)!Fetched {
    var buffer: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &buffer);
    defer while (select.cancel()) |late| release(gpa, late);

    try select.concurrent(.loaded, load, .{ client, gpa, io, url, limit });
    try select.concurrent(.expired, Io.sleep, .{ io, budget, .awake });

    return switch (try select.await()) {
        .expired => .{ .failed = .{ .expired = budget } },
        .loaded => |result| result,
    };
}

fn release(gpa: Allocator, late: Race) void {
    switch (late) {
        .loaded => |result| {
            const fetched = result catch return;
            switch (fetched) {
                .image => |image| gpa.free(image.bytes),
                .failed => {},
            }
        },
        .expired => {},
    }
}

pub fn fetch(
    client: *std.http.Client,
    gpa: Allocator,
    url: []const u8,
    limit: usize,
) Allocator.Error!Fetched {
    return switch (try download(client, gpa, url, limit)) {
        .bytes => |bytes| sniffed(gpa, bytes),
        .failed => |failure| .{ .failed = failure },
    };
}

pub const Download = union(enum) {
    bytes: []u8,
    failed: Failure,
};

const Downloading = union(enum) {
    downloaded: Allocator.Error!Download,
    expired: Io.Cancelable!void,
};

pub fn download(
    client: *std.http.Client,
    gpa: Allocator,
    url: []const u8,
    limit: usize,
) Allocator.Error!Download {
    var status: std.http.Status = .ok;
    const bytes = get(client, gpa, url, limit, &status) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Status => .{ .failed = .{ .status = status } },
        error.StreamTooLong => .{ .failed = .{ .too_large = limit } },
        else => .{ .failed = .{ .cause = err } },
    };
    return .{ .bytes = bytes };
}

pub fn downloadWithin(
    client: *std.http.Client,
    gpa: Allocator,
    io: Io,
    url: []const u8,
    limit: usize,
    budget: Io.Duration,
) (Allocator.Error || Io.Cancelable || Io.ConcurrentError)!Download {
    var buffer: [2]Downloading = undefined;
    var select: Io.Select(Downloading) = .init(io, &buffer);
    defer while (select.cancel()) |late| drop(gpa, late);

    try select.concurrent(.downloaded, download, .{ client, gpa, url, limit });
    try select.concurrent(.expired, Io.sleep, .{ io, budget, .awake });

    return switch (try select.await()) {
        .expired => .{ .failed = .{ .expired = budget } },
        .downloaded => |result| result,
    };
}

fn drop(gpa: Allocator, late: Downloading) void {
    switch (late) {
        .downloaded => |result| {
            const found = result catch return;
            switch (found) {
                .bytes => |bytes| gpa.free(bytes),
                .failed => {},
            }
        },
        .expired => {},
    }
}

pub fn isRemote(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://");
}

fn sniffed(gpa: Allocator, bytes: []u8) Fetched {
    const kind = kindOf(bytes) orelse {
        gpa.free(bytes);
        return .{ .failed = .not_an_image };
    };
    return .{ .image = .{ .kind = kind, .bytes = bytes } };
}

fn decoded(gpa: Allocator, url: []const u8, limit: usize) Allocator.Error!Fetched {
    const comma = std.mem.findScalar(u8, url, ',') orelse return .{ .failed = .malformed };
    if (!std.ascii.endsWithIgnoreCase(url[0..comma], ";base64")) return .{ .failed = .malformed };

    const encoded = url[comma + 1 ..];
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return .{ .failed = .malformed };
    if (size > limit) return .{ .failed = .{ .too_large = limit } };

    const bytes = try gpa.alloc(u8, size);
    decoder.decode(bytes, encoded) catch {
        gpa.free(bytes);
        return .{ .failed = .malformed };
    };
    return sniffed(gpa, bytes);
}

fn read(gpa: Allocator, io: Io, url: []const u8, limit: usize) Allocator.Error!Fetched {
    const uri = std.Uri.parse(url) catch return .{ .failed = .malformed };
    if (uri.host) |host| {
        var named: [std.Io.net.HostName.max_len]u8 = undefined;
        const local = host.toRaw(&named) catch return .{ .failed = .malformed };
        if (local.len > 0 and !std.ascii.eqlIgnoreCase(local, "localhost")) return .{ .failed = .malformed };
    }

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = uri.path.toRaw(&buffer) catch return .{ .failed = .malformed };

    const bytes = Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => .{ .failed = .{ .too_large = limit } },
        else => .{ .failed = .{ .cause = err } },
    };
    return sniffed(gpa, bytes);
}

fn get(
    client: *std.http.Client,
    gpa: Allocator,
    url: []const u8,
    limit: usize,
    status: *std.http.Status,
) ![]u8 {
    const uri = try std.Uri.parse(url);

    var request = try client.request(.GET, uri, .{
        .keep_alive = false,
        .redirect_behavior = .init(max_redirects),
    });
    defer request.deinit();

    try request.sendBodiless();

    var redirects: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirects);
    status.* = response.head.status;
    if (response.head.status.class() != .success) return error.Status;

    var transfer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, &window);

    return reader.allocRemaining(gpa, .limited(limit)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse err,
        else => return err,
    };
}

const testing = std.testing;

const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
const ico = "\x00\x00\x01\x00\x01\x00\x10\x10";

test "each image type is told by its first bytes" {
    try testing.expectEqual(Kind.png, kindOf(png).?);
    try testing.expectEqual(Kind.ico, kindOf(ico).?);
    try testing.expectEqual(Kind.jpg, kindOf("\xff\xd8\xff\xe0\x00\x10JFIF").?);
    try testing.expectEqual(Kind.gif, kindOf("GIF89a\x10\x00").?);
    try testing.expectEqual(Kind.webp, kindOf("RIFF\x24\x00\x00\x00WEBPVP8 ").?);
    try testing.expectEqual(Kind.svg, kindOf("<svg xmlns=\"http://www.w3.org/2000/svg\"/>").?);
}

test "an SVG is found behind a BOM, a prolog, a comment and a doctype" {
    const svg =
        "\xef\xbb\xbf  <?xml version=\"1.0\"?>\n<!-- made by hand, <g> before <svg> -->\n" ++
        "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\">\n<svg>";
    try testing.expectEqual(Kind.svg, kindOf(svg).?);
}

test "HTML, an empty answer and a lookalike tag are no image" {
    try testing.expectEqual(@as(?Kind, null), kindOf("<!DOCTYPE html><html><head>"));
    try testing.expectEqual(@as(?Kind, null), kindOf(""));
    try testing.expectEqual(@as(?Kind, null), kindOf("<svgfoo>"));
    try testing.expectEqual(@as(?Kind, null), kindOf("<!-- never closed"));
    try testing.expectEqual(@as(?Kind, null), kindOf("RIFF\x24\x00\x00\x00WAVE"));
}

test "the stem of a URL is sixteen hex digits and stable" {
    const stem = stemOf("https://example.org/icon.png");
    try testing.expectEqualStrings(&stem, &stemOf("https://example.org/icon.png"));
    try testing.expect(!std.mem.eql(u8, &stem, &stemOf("https://example.org/other.png")));
    for (stem) |char| try testing.expect(std.ascii.isHex(char));
}

fn tmpPath(tmp: *testing.TmpDir, buffer: []u8) ![]const u8 {
    return std.mem.print(buffer, ".zig-cache/tmp/{s}/icons", .{tmp.sub_path});
}

test "a scan finds stored icons and markers by stem, also for dotted hosts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buffer);

    var bytes = png.*;
    try store(testing.allocator, testing.io, dir, "search.brave.com", .{ .kind = .png, .bytes = &bytes });
    const marked = try mark(testing.allocator, testing.io, dir, "search.nixos.org");
    defer testing.allocator.free(marked);
    try testing.expect(std.mem.endsWith(u8, marked, "/icons/search.nixos.org.none"));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "icons/notes.txt", .data = "" });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const listing = try scan(arena.allocator(), testing.io, dir);

    try testing.expectEqual(@as(u32, 2), listing.entries.count());
    const brave = listing.get("search.brave.com").?;
    try testing.expect(std.mem.endsWith(u8, brave.file, "/icons/search.brave.com.png"));
    try testing.expectEqual(Found.failed, listing.get("search.nixos.org").?);
    try testing.expectEqual(@as(?Found, null), listing.get("notes"));
}

test "a stored icon wins over a marker of the same stem" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &buffer);

    const marked = try mark(testing.allocator, testing.io, dir, "duckduckgo.com");
    testing.allocator.free(marked);
    var bytes = ico.*;
    try store(testing.allocator, testing.io, dir, "duckduckgo.com", .{ .kind = .ico, .bytes = &bytes });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const listing = try scan(arena.allocator(), testing.io, dir);
    try testing.expect(listing.get("duckduckgo.com").? == .file);
}

test "a missing directory scans as empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const listing = try scan(arena.allocator(), testing.io, "/nonexistent/sysdeck/icons");
    try testing.expectEqual(@as(u32, 0), listing.entries.count());
}

pub const Route = struct {
    path: []const u8,
    status: std.http.Status = .ok,
    body: []const u8 = "",
    location: ?[]const u8 = null,
};

pub const Local = struct {
    io: Io,
    listener: std.Io.net.Server,
    routes: []const Route,
    group: Io.Group = .init,
    served: std.atomic.Value(u32) = .init(0),

    pub fn start(self: *Local, io: Io, routes: []const Route) !void {
        const address: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
        const listener = try address.listen(io, .{ .reuse_address = true });
        self.* = .{ .io = io, .listener = listener, .routes = routes };
        try self.group.concurrent(io, serve, .{self});
    }

    pub fn stop(self: *Local) void {
        self.group.cancel(self.io);
        self.listener.deinit(self.io);
    }

    pub fn url(self: *const Local, gpa: Allocator, path: []const u8) ![]u8 {
        const port = self.listener.socket.address.getPort();
        return gpa.print("http://127.0.0.1:{d}{s}", .{ port, path });
    }

    fn serve(self: *Local) void {
        while (true) {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            self.answer(stream) catch {};
        }
    }

    fn answer(self: *Local, stream: std.Io.net.Stream) !void {
        var in: [4096]u8 = undefined;
        var out: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &in);
        var writer = stream.writer(self.io, &out);

        var server: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        _ = self.served.fetchAdd(1, .monotonic);

        for (self.routes) |route| {
            if (!std.mem.eql(u8, route.path, request.head.target)) continue;
            if (route.location) |location| {
                return request.respond("", .{
                    .status = route.status,
                    .keep_alive = false,
                    .extra_headers = &.{.{ .name = "location", .value = location }},
                });
            }
            return request.respond(route.body, .{ .status = route.status, .keep_alive = false });
        }
        try request.respond("", .{ .status = .not_found, .keep_alive = false });
    }
};

fn fetchFrom(local: *const Local, path: []const u8) !Fetched {
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const url = try local.url(testing.allocator, path);
    defer testing.allocator.free(url);
    return fetch(&client, testing.allocator, url, max_bytes);
}

test "a fetch keeps an image, follows a redirect and reports the rest" {
    const large = try testing.allocator.alloc(u8, max_bytes + 1);
    defer testing.allocator.free(large);
    @memcpy(large[0..png.len], png);

    const routes = [_]Route{
        .{ .path = "/icon.ico", .body = ico },
        .{ .path = "/moved", .status = .moved_permanently, .location = "/icon.ico" },
        .{ .path = "/page", .body = "<!DOCTYPE html><html>" },
        .{ .path = "/large", .body = large },
    };
    var local: Local = undefined;
    try local.start(testing.io, &routes);
    defer local.stop();

    for ([_][]const u8{ "/icon.ico", "/moved" }) |path| {
        const fetched = try fetchFrom(&local, path);
        try testing.expectEqual(Kind.ico, fetched.image.kind);
        try testing.expectEqualStrings(ico, fetched.image.bytes);
        testing.allocator.free(fetched.image.bytes);
    }

    try testing.expectEqual(Failure{ .status = .not_found }, (try fetchFrom(&local, "/gone")).failed);
    try testing.expectEqual(Failure.not_an_image, (try fetchFrom(&local, "/page")).failed);
    try testing.expectEqual(Failure{ .too_large = max_bytes }, (try fetchFrom(&local, "/large")).failed);
}

test "a failure reads as the reason it happened" {
    var buffer: [64]u8 = undefined;
    const missing: Failure = .{ .status = .not_found };
    try testing.expectEqualStrings("HTTP 404", try std.mem.print(&buffer, "{f}", .{missing}));
    try testing.expectEqualStrings(
        "ConnectionRefused",
        try std.mem.print(&buffer, "{f}", .{Failure{ .cause = error.ConnectionRefused }}),
    );
}

fn loadFrom(url: []const u8, limit: usize) !Fetched {
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    return load(&client, testing.allocator, testing.io, url, limit);
}

fn failureOf(url: []const u8, limit: usize) !Failure {
    return (try loadFrom(url, limit)).failed;
}

test "a file URL is read with its escapes undone, and only on this host" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cover art.png", .data = png });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &buffer);

    const dir = buffer[0..length];

    const local = try testing.allocator.print("file://{s}/cover%20art.png", .{dir});
    defer testing.allocator.free(local);
    const loaded = try loadFrom(local, max_bytes);
    defer testing.allocator.free(loaded.image.bytes);
    try testing.expectEqualStrings(png, loaded.image.bytes);

    const named = try testing.allocator.print("file://localhost{s}/cover%20art.png", .{dir});
    defer testing.allocator.free(named);
    const again = try loadFrom(named, max_bytes);
    defer testing.allocator.free(again.image.bytes);
    try testing.expectEqual(Kind.png, again.image.kind);

    try testing.expectEqual(Failure.malformed, try failureOf("file://elsewhere/cover.png", max_bytes));
    try testing.expectEqual(Failure{ .too_large = 4 }, try failureOf(local, 4));
    const gone: Failure = .{ .cause = error.FileNotFound };
    try testing.expectEqual(gone, try failureOf("file:///nonexistent/art.png", max_bytes));
}

test "a data URL is decoded from base64, and anything else is refused" {
    const encoder = std.base64.standard.Encoder;
    var encoded: [encoder.calcSize(png.len)]u8 = undefined;
    const payload = encoder.encode(&encoded, png);
    const url = try testing.allocator.print("data:image/png;base64,{s}", .{payload});
    defer testing.allocator.free(url);

    const loaded = try loadFrom(url, max_bytes);
    defer testing.allocator.free(loaded.image.bytes);
    try testing.expectEqualStrings(png, loaded.image.bytes);

    try testing.expectEqual(Failure{ .too_large = 4 }, try failureOf(url, 4));
    try testing.expectEqual(Failure.malformed, try failureOf("data:image/png,iVBORw0KGgo=", max_bytes));
    try testing.expectEqual(Failure.malformed, try failureOf("data:image/png;base64,!!!!", max_bytes));
    const text = "data:text/plain;base64,aGVsbG8=";
    try testing.expectEqual(Failure.not_an_image, try failureOf(text, max_bytes));
    try testing.expectEqual(Failure.unsupported, try failureOf("ftp://example.org/art.png", max_bytes));
}

test "an http URL is fetched with the limit it is given" {
    const routes = [_]Route{.{ .path = "/art.png", .body = png }};
    var local: Local = undefined;
    try local.start(testing.io, &routes);
    defer local.stop();

    const url = try local.url(testing.allocator, "/art.png");
    defer testing.allocator.free(url);

    const loaded = try loadFrom(url, max_bytes);
    defer testing.allocator.free(loaded.image.bytes);
    try testing.expectEqualStrings(png, loaded.image.bytes);

    try testing.expectEqual(Failure{ .too_large = 4 }, (try loadFrom(url, 4)).failed);
}

test "a load within its budget returns the image, one past it expires" {
    const routes = [_]Route{.{ .path = "/art.png", .body = png }};
    var local: Local = undefined;
    try local.start(testing.io, &routes);
    defer local.stop();

    const address: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var silent = try address.listen(testing.io, .{ .reuse_address = true });
    defer silent.deinit(testing.io);

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const url = try local.url(testing.allocator, "/art.png");
    defer testing.allocator.free(url);
    const budget: Io.Duration = .fromMilliseconds(300);

    const loaded = try loadWithin(&client, testing.allocator, testing.io, url, max_bytes, budget);
    defer testing.allocator.free(loaded.image.bytes);
    try testing.expectEqualStrings(png, loaded.image.bytes);

    const hung = try testing.allocator.print("http://127.0.0.1:{d}/art.png", .{
        silent.socket.address.getPort(),
    });
    defer testing.allocator.free(hung);

    const started = Io.Clock.awake.now(testing.io);
    const expired = try loadWithin(&client, testing.allocator, testing.io, hung, max_bytes, budget);
    const took = started.durationTo(Io.Clock.awake.now(testing.io));

    try testing.expectEqual(Failure{ .expired = budget }, expired.failed);
    try testing.expect(took.toMilliseconds() < 1500);

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "it took longer than 300 ms",
        try std.mem.print(&buffer, "{f}", .{expired.failed}),
    );
}

test "a download within its budget returns the bytes as they are, one past it expires" {
    const routes = [_]Route{.{ .path = "/rates.xml", .body = "<Cube currency=\"USD\"/>" }};
    var local: Local = undefined;
    try local.start(testing.io, &routes);
    defer local.stop();

    const address: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var silent = try address.listen(testing.io, .{ .reuse_address = true });
    defer silent.deinit(testing.io);

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const url = try local.url(testing.allocator, "/rates.xml");
    defer testing.allocator.free(url);
    const budget: Io.Duration = .fromMilliseconds(300);

    const downloaded = try downloadWithin(&client, testing.allocator, testing.io, url, max_bytes, budget);
    defer testing.allocator.free(downloaded.bytes);
    try testing.expectEqualStrings("<Cube currency=\"USD\"/>", downloaded.bytes);

    const hung = try testing.allocator.print("http://127.0.0.1:{d}/rates.xml", .{
        silent.socket.address.getPort(),
    });
    defer testing.allocator.free(hung);

    const started = Io.Clock.awake.now(testing.io);
    const expired = try downloadWithin(&client, testing.allocator, testing.io, hung, max_bytes, budget);
    const took = started.durationTo(Io.Clock.awake.now(testing.io));

    try testing.expectEqual(Failure{ .expired = budget }, expired.failed);
    try testing.expect(took.toMilliseconds() < 1500);
}
