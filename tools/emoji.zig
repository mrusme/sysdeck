const std = @import("std");
const xml = @import("xml");

const Allocator = std.mem.Allocator;

const max_bytes = 8 << 20;
const variation_selector = 0xfe0f;
const first_tone = 0x1f3fb;
const last_tone = 0x1f3ff;

const usage =
    \\Usage: emoji <emoji-test.txt> <annotations/en.xml> <annotationsDerived/en.xml> <LICENSE> <output>
    \\
;

const Annotation = struct {
    name: []const u8 = "",
    keywords: []const []const u8 = &.{},
};

const Annotations = std.StringHashMapUnmanaged(Annotation);

const Entry = struct {
    emoji: []const u8,
    bare: []const u8,
    toned: bool,
    annotation: Annotation,
};

const Tones = [last_tone - first_tone + 1][]const u8;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var arguments = init.minimal.args.iterate();
    _ = arguments.skip();

    var paths: [5][]const u8 = undefined;
    for (&paths) |*slot| {
        slot.* = arguments.next() orelse {
            std.debug.print(usage, .{});
            return 2;
        };
    }

    var annotations: Annotations = .empty;
    try annotate(arena, io, &annotations, paths[1]);
    try annotate(arena, io, &annotations, paths[2]);

    const entries = try collect(arena, &annotations, try load(arena, io, paths[0])) orelse return 1;
    const tones = try toneNames(arena, &annotations) orelse return 1;
    const variants = try group(arena, entries, tones) orelse return 1;

    var out: std.Io.Writer.Allocating = .init(arena);
    try notice(&out.writer, try load(arena, io, paths[3]));
    try write(arena, &out.writer, entries, variants, tones);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = paths[4], .data = out.written() });
    return 0;
}

fn load(arena: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| {
        std.debug.print("cannot read {s}: {t}\n", .{ path, err });
        return err;
    };
}

fn annotate(arena: Allocator, io: std.Io, annotations: *Annotations, path: []const u8) !void {
    const source = try undeclared(arena, try load(arena, io, path));
    var static: xml.Reader.Static = .init(arena, source, .{});
    const reader = &static.interface;

    while (true) {
        const node = reader.read() catch |err| {
            const at = reader.errorLocation();
            std.debug.print("cannot parse {s} at line {d} column {d}: {t}\n", .{
                path,
                at.line,
                at.column,
                reader.errorCode(),
            });
            return err;
        };

        switch (node) {
            .eof => return,
            .element_start => {},
            else => continue,
        }
        if (!std.mem.eql(u8, reader.elementName(), "annotation")) continue;

        const point = reader.attributeIndex("cp") orelse continue;
        const cp = try arena.dupe(u8, try reader.attributeValue(point));

        const spoken = if (reader.attributeIndex("type")) |kind|
            std.mem.eql(u8, try reader.attributeValue(kind), "tts")
        else
            false;

        const text = try arena.dupe(u8, try reader.readElementText());

        const slot = try annotations.getOrPut(arena, cp);
        if (!slot.found_existing) slot.value_ptr.* = .{};

        if (spoken) {
            if (slot.value_ptr.name.len == 0) slot.value_ptr.name = std.mem.trim(u8, text, " ");
        } else if (slot.value_ptr.keywords.len == 0) {
            slot.value_ptr.keywords = try split(arena, text);
        }
    }
}

fn undeclared(arena: Allocator, source: []const u8) Allocator.Error![]const u8 {
    const start = std.mem.find(u8, source, "<!DOCTYPE") orelse return source;
    const end = std.mem.findScalarPos(u8, source, start, '>') orelse return source;
    return std.mem.concat(arena, u8, &.{ source[0..start], source[end + 1 ..] });
}

fn split(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, '|');
    while (parts.next()) |part| {
        const keyword = std.mem.trim(u8, part, " ");
        if (keyword.len > 0) try found.append(arena, keyword);
    }
    return found.items;
}

fn notice(writer: *std.Io.Writer, license: []const u8) !void {
    for (license) |byte| try writer.writeByte(if (byte == '\t') ' ' else byte);
    if (!std.mem.endsWith(u8, license, "\n")) try writer.writeByte('\n');
    try writer.writeByte('\n');
}

fn collect(arena: Allocator, annotations: *const Annotations, tests: []const u8) !?[]const Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var missing: usize = 0;

    var lines = std.mem.splitScalar(u8, tests, '\n');
    while (lines.next()) |line| {
        const points = qualified(line) orelse continue;

        const emoji = try encode(arena, points, .{});
        const found = annotations.get(try encode(arena, points, .{ .variation = true })) orelse
            Annotation{};
        if (found.name.len == 0) {
            const codes = std.mem.trim(u8, points, " ");
            std.debug.print("{s} ({s}) has no annotation\n", .{ emoji, codes });
            missing += 1;
            continue;
        }

        const bare = try encode(arena, points, .{ .variation = true, .tones = true });
        try entries.append(arena, .{
            .emoji = emoji,
            .bare = bare,
            .toned = bare.len != (try encode(arena, points, .{ .variation = true })).len,
            .annotation = found,
        });
    }

    if (missing > 0) {
        std.debug.print("{d} emoji have no annotation\n", .{missing});
        return null;
    }
    return entries.items;
}

fn toneNames(arena: Allocator, annotations: *const Annotations) !?Tones {
    var tones: Tones = undefined;
    for (&tones, first_tone..) |*slot, point| {
        var buffer: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(point), &buffer);

        const found = annotations.get(buffer[0..length]) orelse Annotation{};
        if (found.name.len == 0) {
            std.debug.print("U+{X} has no annotation\n", .{point});
            return null;
        }
        slot.* = try arena.dupe(u8, found.name);
    }
    return tones;
}

fn group(arena: Allocator, entries: []const Entry, tones: Tones) !?[]std.ArrayList(usize) {
    var sequences: std.StringHashMapUnmanaged(usize) = .empty;
    var names: std.StringHashMapUnmanaged(usize) = .empty;

    for (entries, 0..) |entry, at| {
        if (entry.toned) continue;
        try sequences.put(arena, entry.bare, at);
        try names.put(arena, entry.annotation.name, at);
    }

    const variants = try arena.alloc(std.ArrayList(usize), entries.len);
    @memset(variants, .empty);

    var unplaced: usize = 0;
    for (entries, 0..) |entry, at| {
        if (!entry.toned) continue;

        const parts = try Name.of(arena, entry.annotation.name, tones);
        const base = sequences.get(entry.bare) orelse
            names.get(parts.untoned) orelse
            names.get(parts.head) orelse {
            std.debug.print("{s} ({s}) belongs to no base emoji\n", .{
                entry.emoji,
                entry.annotation.name,
            });
            unplaced += 1;
            continue;
        };
        try variants[base].append(arena, at);
    }

    if (unplaced > 0) {
        std.debug.print("{d} skin tones belong to no base emoji\n", .{unplaced});
        return null;
    }
    return variants;
}

const Name = struct {
    head: []const u8,
    untoned: []const u8,
    label: []const u8,

    fn of(arena: Allocator, name: []const u8, tones: Tones) Allocator.Error!Name {
        const colon = std.mem.find(u8, name, ": ") orelse {
            return .{ .head = name, .untoned = name, .label = "" };
        };
        const head = name[0..colon];

        var kept: std.ArrayList([]const u8) = .empty;
        var toned: std.ArrayList([]const u8) = .empty;

        var items = std.mem.splitSequence(u8, name[colon + 2 ..], ", ");
        while (items.next()) |item| {
            if (contains(&tones, item)) {
                try toned.append(arena, item);
            } else {
                try kept.append(arena, item);
            }
        }

        const rest = try std.mem.join(arena, ", ", kept.items);
        const untoned = if (rest.len == 0)
            head
        else
            try std.mem.concat(arena, u8, &.{ head, ": ", rest });
        return .{
            .head = head,
            .untoned = untoned,
            .label = try std.mem.join(arena, ", ", toned.items),
        };
    }
};

fn write(
    arena: Allocator,
    writer: *std.Io.Writer,
    entries: []const Entry,
    variants: []const std.ArrayList(usize),
    tones: Tones,
) !void {
    for (entries, variants) |entry, placed| {
        if (entry.toned) continue;

        try writer.print("{s}\t{s}", .{ entry.emoji, entry.annotation.name });
        try keywords(writer, entry.annotation);

        for (placed.items) |at| {
            const variant = entries[at];
            const parts = try Name.of(arena, variant.annotation.name, tones);
            const name = variant.annotation.name;
            try writer.print("\t{s}\t{s}\t{s}", .{ variant.emoji, parts.label, name });
            try keywords(writer, variant.annotation);
        }
    }
}

fn keywords(writer: *std.Io.Writer, annotation: Annotation) !void {
    for (annotation.keywords, 0..) |keyword, at| {
        if (std.mem.eql(u8, keyword, annotation.name)) continue;
        if (contains(annotation.keywords[0..at], keyword)) continue;
        try writer.print("\t{s}", .{keyword});
    }
    try writer.writeByte('\n');
}

fn qualified(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] == '#') return null;

    const separator = std.mem.findScalar(u8, line, ';') orelse return null;
    const status = std.mem.trimStart(u8, line[separator + 1 ..], " ");
    if (!std.mem.startsWith(u8, status, "fully-qualified ")) return null;

    return line[0..separator];
}

const Without = struct {
    variation: bool = false,
    tones: bool = false,
};

fn encode(arena: Allocator, points: []const u8, without: Without) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buffer: [4]u8 = undefined;

    var hexes = std.mem.tokenizeScalar(u8, points, ' ');
    while (hexes.next()) |hex| {
        const point = try std.fmt.parseInt(u21, hex, 16);
        if (without.variation and point == variation_selector) continue;
        if (without.tones and point >= first_tone and point <= last_tone) continue;

        const length = try std.unicode.utf8Encode(point, &buffer);
        try out.appendSlice(arena, buffer[0..length]);
    }
    return out.items;
}

fn contains(items: []const []const u8, wanted: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, wanted)) return true;
    }
    return false;
}
