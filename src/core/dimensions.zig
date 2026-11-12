const std = @import("std");

pub const Size = struct {
    width: u32,
    height: u32,

    pub fn pixels(self: Size) u64 {
        return @as(u64, self.width) * self.height;
    }
};

const png_signature = "\x89PNG\r\n\x1a\n";
const jxl_container = "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a";
const heif_brands = [_][]const u8{ "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis" };

pub fn of(bytes: []const u8) ?Size {
    if (std.mem.startsWith(u8, bytes, png_signature)) return png(bytes);
    if (std.mem.startsWith(u8, bytes, "\xff\xd8")) return jpeg(bytes);
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return gif(bytes);
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return webp(bytes);
    if (std.mem.startsWith(u8, bytes, "BM")) return dib(bytes, 14, false);
    if (std.mem.startsWith(u8, bytes, "II*\x00") or std.mem.startsWith(u8, bytes, "MM\x00*")) return tiff(bytes);
    if (std.mem.startsWith(u8, bytes, "qoif")) return qoi(bytes);
    if (std.mem.startsWith(u8, bytes, "DDS ")) return dds(bytes);
    if (std.mem.startsWith(u8, bytes, "\xff\x0a")) return jxl(bytes[2..]);
    if (std.mem.startsWith(u8, bytes, jxl_container)) return jxlBoxes(bytes);
    if (heifBrand(bytes)) return heif(bytes);
    if (icon(bytes)) return ico(bytes);
    if (bytes.len >= 2 and bytes[0] == 'P' and bytes[1] >= '1' and bytes[1] <= '7') return pnm(bytes);
    return targa(bytes);
}

fn sized(width: anytype, height: anytype) ?Size {
    if (width == 0 or height == 0) return null;
    return .{
        .width = std.math.cast(u32, width) orelse return null,
        .height = std.math.cast(u32, height) orelse return null,
    };
}

fn le(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@divExact(@typeInfo(T).int.bits, 8)], .little);
}

fn be(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@divExact(@typeInfo(T).int.bits, 8)], .big);
}

fn png(bytes: []const u8) ?Size {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return sized(be(u32, bytes, 16), be(u32, bytes, 20));
}

fn jpeg(bytes: []const u8) ?Size {
    var at: usize = 2;
    while (at < bytes.len) {
        if (bytes[at] != 0xff) return null;
        while (at < bytes.len and bytes[at] == 0xff) at += 1;
        if (at >= bytes.len) return null;

        const marker = bytes[at];
        at += 1;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd8)) continue;
        if (marker == 0xd9 or marker == 0xda) return null;

        if (at + 2 > bytes.len) return null;
        const length = be(u16, bytes, at);
        if (length < 2) return null;

        if (framing(marker)) {
            if (at + 7 > bytes.len) return null;
            return sized(be(u16, bytes, at + 5), be(u16, bytes, at + 3));
        }
        at += length;
    }
    return null;
}

fn framing(marker: u8) bool {
    return marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
}

fn gif(bytes: []const u8) ?Size {
    if (bytes.len < 10) return null;
    return sized(le(u16, bytes, 6), le(u16, bytes, 8));
}

fn webp(bytes: []const u8) ?Size {
    if (bytes.len < 16) return null;

    const chunk = bytes[12..16];
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        if (bytes.len < 30 or !std.mem.eql(u8, bytes[23..26], "\x9d\x01\x2a")) return null;
        return sized(le(u16, bytes, 26) & 0x3fff, le(u16, bytes, 28) & 0x3fff);
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        if (bytes.len < 25 or bytes[20] != 0x2f) return null;
        const packed_size = le(u32, bytes, 21);
        return sized((packed_size & 0x3fff) + 1, ((packed_size >> 14) & 0x3fff) + 1);
    }
    if (std.mem.eql(u8, chunk, "VP8X")) {
        if (bytes.len < 30) return null;
        return sized(@as(u32, le(u24, bytes, 24)) + 1, @as(u32, le(u24, bytes, 27)) + 1);
    }
    return null;
}

fn dib(bytes: []const u8, at: usize, masked: bool) ?Size {
    if (at + 12 > bytes.len) return null;

    const header = le(u32, bytes, at);
    if (header == 12) return sized(le(u16, bytes, at + 4), halved(le(u16, bytes, at + 6), masked));
    if (header < 16) return null;

    const width = le(i32, bytes, at + 4);
    const height = le(i32, bytes, at + 8);
    if (width <= 0) return null;
    return sized(@as(u32, @intCast(width)), halved(@abs(height), masked));
}

fn halved(height: anytype, masked: bool) @TypeOf(height) {
    return if (masked) height / 2 else height;
}

fn tiff(bytes: []const u8) ?Size {
    if (bytes.len < 8) return null;

    const endian: std.builtin.Endian = if (bytes[0] == 'I') .little else .big;
    const first: usize = std.mem.readInt(u32, bytes[4..8], endian);
    if (first + 2 > bytes.len) return null;

    var width: ?u32 = null;
    var height: ?u32 = null;

    const count = std.mem.readInt(u16, bytes[first..][0..2], endian);
    for (0..count) |index| {
        const entry = first + 2 + index * 12;
        if (entry + 12 > bytes.len) return null;

        const tag = std.mem.readInt(u16, bytes[entry..][0..2], endian);
        const value: ?u32 = switch (std.mem.readInt(u16, bytes[entry + 2 ..][0..2], endian)) {
            3 => std.mem.readInt(u16, bytes[entry + 8 ..][0..2], endian),
            4 => std.mem.readInt(u32, bytes[entry + 8 ..][0..4], endian),
            else => null,
        };
        switch (tag) {
            256 => width = value,
            257 => height = value,
            else => {},
        }
    }

    return sized(width orelse return null, height orelse return null);
}

fn qoi(bytes: []const u8) ?Size {
    if (bytes.len < 12) return null;
    return sized(be(u32, bytes, 4), be(u32, bytes, 8));
}

fn dds(bytes: []const u8) ?Size {
    if (bytes.len < 20) return null;
    return sized(le(u32, bytes, 16), le(u32, bytes, 12));
}

const Bits = struct {
    bytes: []const u8,
    at: usize = 0,

    fn read(self: *Bits, count: u5) ?u32 {
        var value: u32 = 0;
        for (0..count) |index| {
            const byte = self.at >> 3;
            if (byte >= self.bytes.len) return null;

            const bit = (self.bytes[byte] >> @intCast(self.at & 7)) & 1;
            value |= @as(u32, bit) << @intCast(index);
            self.at += 1;
        }
        return value;
    }

    fn extent(self: *Bits, small: bool) ?u64 {
        if (small) return (@as(u64, self.read(5) orelse return null) + 1) * 8;

        const count: u5 = switch (self.read(2) orelse return null) {
            0 => 9,
            1 => 13,
            2 => 18,
            else => 30,
        };
        return @as(u64, self.read(count) orelse return null) + 1;
    }
};

fn jxl(stream: []const u8) ?Size {
    var bits: Bits = .{ .bytes = stream };

    const small = (bits.read(1) orelse return null) == 1;
    const height = bits.extent(small) orelse return null;
    const width: u64 = switch (bits.read(3) orelse return null) {
        0 => bits.extent(small) orelse return null,
        1 => height,
        2 => height * 12 / 10,
        3 => height * 4 / 3,
        4 => height * 3 / 2,
        5 => height * 16 / 9,
        6 => height * 5 / 4,
        else => height * 2,
    };
    return sized(width, height);
}

const Box = struct {
    kind: []const u8,
    body: []const u8,
    end: usize,
};

fn boxAt(bytes: []const u8, at: usize) ?Box {
    if (at + 8 > bytes.len) return null;

    var size: u64 = be(u32, bytes, at);
    var header: usize = 8;
    if (size == 1) {
        if (at + 16 > bytes.len) return null;
        size = be(u64, bytes, at + 8);
        header = 16;
    } else if (size == 0) {
        size = bytes.len - at;
    }
    if (size < header or size > bytes.len - at) return null;

    const end = at + @as(usize, @intCast(size));
    return .{ .kind = bytes[at + 4 .. at + 8], .body = bytes[at + header .. end], .end = end };
}

fn find(bytes: []const u8, from: usize, kind: []const u8) ?Box {
    var at = from;
    while (boxAt(bytes, at)) |found| : (at = found.end) {
        if (std.mem.eql(u8, found.kind, kind)) return found;
    }
    return null;
}

fn jxlBoxes(bytes: []const u8) ?Size {
    var at: usize = 0;
    while (boxAt(bytes, at)) |found| : (at = found.end) {
        if (std.mem.eql(u8, found.kind, "jxlc")) return codestream(found.body);
        if (std.mem.eql(u8, found.kind, "jxlp") and found.body.len > 4) return codestream(found.body[4..]);
    }
    return null;
}

fn codestream(body: []const u8) ?Size {
    if (!std.mem.startsWith(u8, body, "\xff\x0a")) return null;
    return jxl(body[2..]);
}

fn heifBrand(bytes: []const u8) bool {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[4..8], "ftyp")) return false;
    for (heif_brands) |brand| {
        if (std.mem.eql(u8, bytes[8..12], brand)) return true;
    }
    return false;
}

fn heif(bytes: []const u8) ?Size {
    const meta = find(bytes, 0, "meta") orelse return null;
    if (meta.body.len < 4) return null;

    const properties = find(meta.body, 4, "iprp") orelse return null;
    const container = find(properties.body, 0, "ipco") orelse return null;

    var largest: ?Size = null;
    var at: usize = 0;
    while (boxAt(container.body, at)) |found| : (at = found.end) {
        if (!std.mem.eql(u8, found.kind, "ispe") or found.body.len < 12) continue;

        const size = sized(be(u32, found.body, 4), be(u32, found.body, 8)) orelse continue;
        if (largest == null or size.pixels() > largest.?.pixels()) largest = size;
    }
    return largest;
}

fn icon(bytes: []const u8) bool {
    if (bytes.len < 6 or bytes[0] != 0 or bytes[1] != 0 or bytes[3] != 0) return false;
    return (bytes[2] == 1 or bytes[2] == 2) and le(u16, bytes, 4) > 0;
}

fn ico(bytes: []const u8) ?Size {
    var largest: ?Size = null;

    for (0..le(u16, bytes, 4)) |index| {
        const entry = 6 + index * 16;
        if (entry + 16 > bytes.len) return null;

        const offset: usize = le(u32, bytes, entry + 12);
        if (offset >= bytes.len) return null;

        const image = bytes[offset..];
        const size = (if (std.mem.startsWith(u8, image, png_signature)) png(image) else dib(image, 0, true)) orelse return null;
        if (largest == null or size.pixels() > largest.?.pixels()) largest = size;
    }
    return largest;
}

const Tokens = struct {
    bytes: []const u8,
    at: usize,

    fn next(self: *Tokens) ?[]const u8 {
        while (self.at < self.bytes.len) {
            const byte = self.bytes[self.at];
            if (byte == '#') {
                while (self.at < self.bytes.len and self.bytes[self.at] != '\n') self.at += 1;
            } else if (std.ascii.isWhitespace(byte)) {
                self.at += 1;
            } else break;
        }

        const start = self.at;
        while (self.at < self.bytes.len and !std.ascii.isWhitespace(self.bytes[self.at])) self.at += 1;
        if (start == self.at) return null;
        return self.bytes[start..self.at];
    }

    fn number(self: *Tokens) ?u32 {
        return std.fmt.parseInt(u32, self.next() orelse return null, 10) catch null;
    }
};

fn pnm(bytes: []const u8) ?Size {
    var tokens: Tokens = .{ .bytes = bytes, .at = 2 };
    if (bytes[1] != '7') return sized(tokens.number() orelse return null, tokens.number() orelse return null);

    var width: ?u32 = null;
    var height: ?u32 = null;
    while (tokens.next()) |word| {
        if (std.mem.eql(u8, word, "ENDHDR")) break;
        if (std.mem.eql(u8, word, "WIDTH")) width = tokens.number();
        if (std.mem.eql(u8, word, "HEIGHT")) height = tokens.number();
    }
    return sized(width orelse return null, height orelse return null);
}

fn targa(bytes: []const u8) ?Size {
    if (bytes.len < 18) return null;

    const known = switch (bytes[1]) {
        0 => bytes[2] == 2 or bytes[2] == 3 or bytes[2] == 10 or bytes[2] == 11,
        1 => bytes[2] == 1 or bytes[2] == 9,
        else => false,
    };
    const depth = switch (bytes[16]) {
        8, 15, 16, 24, 32 => true,
        else => false,
    };
    if (!known or !depth) return null;
    return sized(le(u16, bytes, 12), le(u16, bytes, 14));
}

const testing = std.testing;

fn expectSize(width: u32, height: u32, bytes: []const u8) !void {
    try testing.expectEqual(Size{ .width = width, .height = height }, of(bytes).?);
}

test "a png gives its size from the header chunk, and a cut one gives none" {
    const header = png_signature ++ "\x00\x00\x00\x0dIHDR\x00\x00\x2e\xe0\x00\x00\x2e\xe0\x08\x02\x00\x00\x00";
    try expectSize(12000, 12000, header);
    try testing.expectEqual(null, of(header[0..20]));
    try testing.expectEqual(null, of(png_signature ++ "\x00\x00\x00\x0dIHDR\x00\x00\x00\x00\x00\x00\x00\x07"));
}

test "a jpeg gives its size from the first frame header after the other segments" {
    const app0 = "\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00";
    const frame = "\xff\xc2\x00\x11\x08\x01\xa3\x04\xd5\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01";
    const tables = "\xff\xc4\x00\x04\x00\x00";
    try expectSize(1237, 419, "\xff\xd8" ++ app0 ++ tables ++ "\xff\xff" ++ frame);
    try testing.expectEqual(null, of("\xff\xd8" ++ app0 ++ "\xff\xda\x00\x08"));
    try testing.expectEqual(null, of("\xff\xd8" ++ app0[0..8]));
}

test "a gif gives the size of its logical screen" {
    try expectSize(1237, 419, "GIF89a\xd5\x04\xa3\x01\xf7\x00\x00");
    try expectSize(1, 2, "GIF87a\x01\x00\x02\x00");
}

test "a webp gives its size in each of its three chunk layouts" {
    const lossy = "RIFF\xc8\x0a\x00\x00WEBPVP8 \xbc\x0a\x00\x00\xf0\xc9\x00\x9d\x01\x2a\xd5\x04\xa3\x01";
    try expectSize(1237, 419, lossy);
    try expectSize(1237, 419, lossy[0..27] ++ "\x44\xa3\x81");
    try expectSize(1237, 419, "RIFF\xd0\x03\x00\x00WEBPVP8L\xc3\x03\x00\x00\x2f\xd4\x84\x68\x00");
    try expectSize(1237, 419, "RIFF\x08\x0b\x00\x00WEBPVP8X\x0a\x00\x00\x00\x10\x00\x00\x00\xd4\x04\x00\xa2\x01\x00");
    try testing.expectEqual(null, of(lossy[0..28]));
}

test "a bitmap gives its size for top-down and bottom-up rows" {
    const file_header = "BM\x00\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00";
    try expectSize(1237, 419, file_header ++ "\x28\x00\x00\x00\xd5\x04\x00\x00\x5d\xfe\xff\xff\x01\x00\x18\x00");
    try expectSize(1237, 419, file_header ++ "\x28\x00\x00\x00\xd5\x04\x00\x00\xa3\x01\x00\x00\x01\x00\x18\x00");
    try expectSize(1237, 419, file_header ++ "\x0c\x00\x00\x00\xd5\x04\xa3\x01\x01\x00\x18\x00");
}

test "a tiff gives its size from the first directory in either byte order" {
    const little = "II*\x00\x08\x00\x00\x00\x02\x00" ++
        "\x00\x01\x03\x00\x01\x00\x00\x00\xd5\x04\x00\x00" ++
        "\x01\x01\x04\x00\x01\x00\x00\x00\xa3\x01\x00\x00";
    try expectSize(1237, 419, little);

    const big = "MM\x00*\x00\x00\x00\x08\x00\x02" ++
        "\x01\x00\x00\x04\x00\x00\x00\x01\x00\x00\x04\xd5" ++
        "\x01\x01\x00\x03\x00\x00\x00\x01\x01\xa3\x00\x00";
    try expectSize(1237, 419, big);
    try testing.expectEqual(null, of(little[0..20]));
}

test "a qoi and a dds give their sizes" {
    try expectSize(1237, 419, "qoif\x00\x00\x04\xd5\x00\x00\x01\xa3\x04\x00");
    try expectSize(1237, 419, "DDS \x7c\x00\x00\x00\x07\x10\x00\x00\xa3\x01\x00\x00\xd5\x04\x00\x00");
}

test "a tga is told by the header fields shared-mime-info matches" {
    try expectSize(1237, 419, "\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\xd5\x04\xa3\x01\x18\x20");
    try expectSize(1237, 419, "\x00\x01\x01\x00\x00\x00\x01\x18\x00\x00\x00\x00\xd5\x04\xa3\x01\x08\x00");
    try testing.expectEqual(null, of("\x00\x01\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\xd5\x04\xa3\x01\x18\x20"));
    try testing.expectEqual(null, of("\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\xd5\x04\xa3\x01\x07\x20"));
}

test "a portable anymap gives its size past comments, also as a pam" {
    try expectSize(1237, 419, "P6\n# made by hand\n1237 419\n255\n");
    try expectSize(1237, 419, "P1 1237\t419 ");
    try expectSize(1237, 419, "P7\nWIDTH 1237\nHEIGHT 419\nDEPTH 3\nMAXVAL 255\nENDHDR\n");
    try testing.expectEqual(null, of("P5\n1237"));
}

test "an icon gives the largest of its images, a png inside one included" {
    const directory = "\x00\x00\x01\x00\x02\x00" ++
        "\x10\x10\x00\x00\x01\x00\x20\x00\x30\x00\x00\x00\x26\x00\x00\x00" ++
        "\x00\x00\x00\x00\x01\x00\x20\x00\x18\x00\x00\x00\x3e\x00\x00\x00";
    const bitmap = "\x28\x00\x00\x00\x10\x00\x00\x00\x20\x00\x00\x00\x01\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const embedded = png_signature ++ "\x00\x00\x00\x0dIHDR\x00\x00\x04\xd5\x00\x00\x01\xa3";
    try expectSize(1237, 419, directory ++ bitmap ++ embedded);

    const cursor = "\x00\x00\x02\x00\x01\x00" ++
        "\x30\x30\x00\x00\x01\x00\x20\x00\x30\x00\x00\x00\x16\x00\x00\x00" ++
        "\x28\x00\x00\x00\x30\x00\x00\x00\x60\x00\x00\x00\x01\x00\x20\x00";
    try expectSize(48, 48, cursor);
}

fn box(comptime kind: []const u8, comptime body: []const u8) []const u8 {
    const length = comptime std.mem.toBytes(std.mem.nativeToBig(u32, body.len + 8));
    return length ++ kind ++ body;
}

test "a heif or avif gives the largest of its spatial extents" {
    const small = comptime box("ispe", "\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\xc0");
    const large = comptime box("ispe", "\x00\x00\x00\x00\x00\x00\x04\xd5\x00\x00\x01\xa3");
    const meta = comptime box("meta", "\x00\x00\x00\x00" ++ box("hdlr", &@as([24]u8, @splat(0))) ++ box("iprp", box("ipco", small ++ large)));
    try expectSize(1237, 419, comptime box("ftyp", "avif\x00\x00\x00\x00mif1") ++ meta);
    try expectSize(1237, 419, comptime box("ftyp", "heic\x00\x00\x00\x00") ++ meta);
    try testing.expectEqual(null, of(comptime box("ftyp", "isom\x00\x00\x00\x00") ++ meta));
}

test "a jpeg xl gives its size in each form of its header" {
    try expectSize(1237, 419, "\xff\x0a\x10\x8d\xa8\x09");
    try expectSize(256, 256, "\xff\x0a\x7f\xf0");
    try expectSize(800, 600, "\xff\x0a\xba\x12\xc3\x4f");
    try expectSize(1920, 1080, "\xff\x0a\xba\x21\xc5\x4f");
    try expectSize(12000, 12000, "\xff\x0a\xfc\x76\x21\xf8\x49\x8a");
    try testing.expectEqual(null, of("\xff\x0a\x10\x8d"));
}

test "a jpeg xl in a container gives the size of its codestream, whole or in parts" {
    const kind = comptime jxl_container ++ box("ftyp", "jxl \x00\x00\x00\x00jxl ");
    try expectSize(1237, 419, comptime kind ++ box("jxlp", "\x00\x00\x00\x00\xff\x0a\x10\x8d\xa8\x09"));
    try expectSize(1237, 419, comptime kind ++ box("Exif", "\x00\x00\x00\x06") ++ box("jxlc", "\xff\x0a\x10\x8d\xa8\x09"));
    try testing.expectEqual(null, of(comptime kind ++ box("jxlc", "\x10\x8d\xa8\x09")));
}

test "a format without a size it can read gives none" {
    try testing.expectEqual(null, of("<svg width=\"12000\" height=\"12000\"/>"));
    try testing.expectEqual(null, of("v/1\x01\x02\x00\x00"));
    try testing.expectEqual(null, of(""));
    try testing.expectEqual(null, of("\xff"));
}
