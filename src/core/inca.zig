const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const program = "inca";
pub const arguments = [_][]const u8{ "people", "list", "--with-photo", "--format", "json" };
pub const command = joined: {
    var text: []const u8 = "";
    for (arguments) |argument| text = text ++ " " ++ argument;
    break :joined text;
};
pub const unnamed = "(no name)";

const separator = " · ";
const max_message = 64 << 10;
const reserve = 64 << 10;

pub const Limits = struct {
    timeout: Io.Duration = .fromSeconds(10),
    output: usize = 256 << 20,
};

pub const Embedded = struct {
    mime: []const u8,
    bytes: []const u8,
};

pub const Photo = union(enum) {
    embedded: Embedded,
    linked: []const u8,
    broken: []const u8,
};

pub const Contact = struct {
    key: []const u8,
    title: [:0]const u8,
    detail: [:0]const u8,
    fields: []const []const u8,
    photo: ?Photo = null,
};

pub const Exit = struct {
    code: u8,
    message: []const u8,
};

pub const Failure = union(enum) {
    exited: Exit,
    signal: u32,
    timeout: Io.Duration,
    too_large: usize,
    malformed: anyerror,
    cause: anyerror,

    pub fn format(self: Failure, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .exited => |exit| {
                try writer.print("exited with {d}", .{exit.code});
                if (exit.message.len > 0) try writer.print(": {s}", .{exit.message});
            },
            .signal => |number| try writer.print("was ended by signal {d}", .{number}),
            .timeout => |limit| try writer.print("took longer than {d} ms", .{limit.toMilliseconds()}),
            .too_large => |limit| try writer.print("printed more than {d} bytes", .{limit}),
            .malformed => |err| try writer.print("printed what isn't Inca's JSON: {t}", .{err}),
            .cause => |err| try writer.print("could not be started: {t}", .{err}),
        }
    }
};

pub const Read = union(enum) {
    contacts: []const Contact,
    missing,
    failed: Failure,
};

const Person = struct {
    key: []const u8 = "",
    formatted_name: []const u8 = "",
    kind: []const u8 = "",
    organization: []const u8 = "",
    emails: []const []const u8 = &.{},
    phones: []const []const u8 = &.{},
    photo: ?Picture = null,
};

const Picture = struct {
    media_type: []const u8 = "",
    data: []const u8 = "",
    uri: []const u8 = "",
};

pub const ParseError = std.json.ParseError(std.json.Scanner);

pub fn read(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
    limits: Limits,
) error{ OutOfMemory, Canceled }!Read {
    var argv: [arguments.len + 1][]const u8 = undefined;
    argv[0] = path;
    @memcpy(argv[1..], &arguments);

    const budget: Io.Timeout = .{ .duration = .{ .raw = limits.timeout, .clock = .awake } };
    const ran = std.process.run(gpa, io, .{
        .argv = &argv,
        .environ_map = environ,
        .stdout_limit = .limited(limits.output),
        .stderr_limit = .limited(max_message),
        .reserve_amount = reserve,
        .timeout = budget.toDeadline(io),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.FileNotFound => .missing,
        error.Timeout => .{ .failed = .{ .timeout = limits.timeout } },
        error.StreamTooLong => .{ .failed = .{ .too_large = limits.output } },
        else => .{ .failed = .{ .cause = err } },
    };
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);

    switch (ran.term) {
        .exited => |code| if (code != 0) {
            const message = try arena.dupe(u8, lastLine(ran.stderr, ran.stdout));
            return .{ .failed = .{ .exited = .{ .code = code, .message = message } } };
        },
        .signal => |number| return .{ .failed = .{ .signal = @intFromEnum(number) } },
        .stopped, .unknown => return .{ .failed = .{ .cause = error.Unexpected } },
    }

    const contacts = parse(gpa, arena, ran.stdout) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .failed = .{ .malformed = err } },
    };
    return .{ .contacts = contacts };
}

pub fn parse(gpa: Allocator, arena: Allocator, json: []const u8) ParseError![]const Contact {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    const people = try std.json.parseFromSliceLeaky([]const Person, scratch.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    var contacts: std.ArrayList(Contact) = .empty;
    try contacts.ensureTotalCapacity(arena, people.len);
    for (people) |person| {
        if (person.key.len == 0 or std.mem.eql(u8, person.kind, "group")) continue;
        contacts.appendAssumeCapacity(try contactOf(arena, person));
    }
    return contacts.items;
}

fn contactOf(arena: Allocator, person: Person) Allocator.Error!Contact {
    const spoken = std.mem.trim(u8, person.formatted_name, &std.ascii.whitespace);
    const named = spoken.len > 0 and !std.mem.eql(u8, spoken, unnamed);
    const company = try organizationOf(arena, person.organization);

    const chosen = if (std.mem.eql(u8, person.kind, "org") and company.len > 0)
        company
    else if (named)
        spoken
    else if (company.len > 0)
        company
    else
        unnamed;
    const title = try arena.dupeZ(u8, chosen);

    var fields: std.ArrayList([]const u8) = .empty;
    try fields.append(arena, title);
    if (named and !std.mem.eql(u8, spoken, title)) try fields.append(arena, try arena.dupe(u8, spoken));
    if (company.len > 0 and !std.mem.eql(u8, company, title)) try fields.append(arena, company);
    for (person.emails) |email| try fields.append(arena, try arena.dupe(u8, email));

    return .{
        .key = try arena.dupe(u8, person.key),
        .title = title,
        .detail = try detailOf(arena, person),
        .fields = fields.items,
        .photo = try photoOf(arena, person.photo),
    };
}

fn organizationOf(arena: Allocator, organization: []const u8) Allocator.Error![]const u8 {
    var name: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < organization.len) : (at += 1) {
        const char = organization[at];
        if (char == ';') break;
        if (char == '\\' and at + 1 < organization.len and organization[at + 1] == ';') {
            try name.append(arena, ';');
            at += 1;
            continue;
        }
        try name.append(arena, char);
    }
    return std.mem.trim(u8, name.items, &std.ascii.whitespace);
}

fn detailOf(arena: Allocator, person: Person) Allocator.Error![:0]const u8 {
    const email = firstOf(person.emails);
    const phone = firstOf(person.phones);

    if (email.len > 0 and phone.len > 0) {
        return std.fmt.allocPrintSentinel(arena, "{s}" ++ separator ++ "{s}", .{ email, phone }, 0);
    }
    return arena.dupeZ(u8, if (email.len > 0) email else phone);
}

fn firstOf(values: []const []const u8) []const u8 {
    if (values.len == 0) return "";
    return std.mem.trim(u8, values[0], &std.ascii.whitespace);
}

fn photoOf(arena: Allocator, found: ?Picture) Allocator.Error!?Photo {
    const picture = found orelse return null;

    if (picture.data.len > 0) {
        const mime = try arena.dupe(u8, picture.media_type);
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(picture.data) catch return .{ .broken = mime };
        const bytes = try arena.alloc(u8, size);
        decoder.decode(bytes, picture.data) catch return .{ .broken = mime };
        return .{ .embedded = .{ .mime = mime, .bytes = bytes } };
    }
    if (picture.uri.len > 0) return .{ .linked = try arena.dupe(u8, picture.uri) };
    return null;
}

fn lastLine(primary: []const u8, fallback: []const u8) []const u8 {
    const found = lastLineOf(primary);
    if (found.len > 0) return found;
    return lastLineOf(fallback);
}

fn lastLineOf(text: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, &std.ascii.whitespace), '\n');
    return std.mem.trim(u8, lines.first(), &std.ascii.whitespace);
}

const testing = std.testing;

fn parsed(arena: Allocator, json: []const u8) ![]const Contact {
    return parse(testing.allocator, arena, json);
}

fn only(arena: Allocator, json: []const u8) !Contact {
    const contacts = try parsed(arena, json);
    try testing.expectEqual(@as(usize, 1), contacts.len);
    return contacts[0];
}

test "a contact is titled by its name and described by its first address and number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "Pref Second", "kind": "individual",
        \\   "emails": ["second@example.com", "first@example.com"],
        \\   "phones": ["+1 555 0002", "+1 555 0001"]},
        \\  {"key": "b", "formatted_name": "Max Mustermann", "kind": "individual",
        \\   "emails": ["max@example.de"]},
        \\  {"key": "c", "formatted_name": "Wide Photo", "kind": "individual",
        \\   "phones": ["+44 20 7946 0000"]},
        \\  {"key": "d", "formatted_name": "Bad Base64", "kind": "individual"}
        \\]
    );

    try testing.expectEqual(@as(usize, 4), contacts.len);
    try testing.expectEqualStrings("Pref Second", contacts[0].title);
    try testing.expectEqualStrings("second@example.com · +1 555 0002", contacts[0].detail);
    try testing.expectEqualStrings("max@example.de", contacts[1].detail);
    try testing.expectEqualStrings("+44 20 7946 0000", contacts[2].detail);
    try testing.expectEqualStrings("", contacts[3].detail);
    try testing.expectEqualStrings("a", contacts[0].key);
}

test "an org card is titled by the first component of its organization" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "John Appleseed", "kind": "org",
        \\   "organization": "Apple Inc.;Retail", "emails": ["john@apple.example"]},
        \\  {"key": "b", "formatted_name": "Acme Inc.", "kind": "org", "organization": "Acme Inc.;"},
        \\  {"key": "c", "formatted_name": "Globex Corporation", "kind": "org"},
        \\  {"key": "d", "formatted_name": "Jane Doe", "kind": "individual", "organization": "Acme Inc.;"}
        \\]
    );

    try testing.expectEqualStrings("Apple Inc.", contacts[0].title);
    try testing.expectEqualStrings("Acme Inc.", contacts[1].title);
    try testing.expectEqualStrings("Globex Corporation", contacts[2].title);
    try testing.expectEqualStrings("Jane Doe", contacts[3].title);
}

test "a card without a name takes its organization, otherwise Inca's (no name)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "(no name)", "kind": "individual",
        \\   "organization": "Initech;Engineering", "emails": ["hr@initech.example"]},
        \\  {"key": "b", "formatted_name": "(no name)", "kind": "individual", "emails": ["anon@example.net"]},
        \\  {"key": "c", "formatted_name": "", "organization": " Hooli ", "kind": "location"}
        \\]
    );

    try testing.expectEqualStrings("Initech", contacts[0].title);
    try testing.expectEqualStrings(unnamed, contacts[1].title);
    try testing.expectEqualStrings("anon@example.net", contacts[1].detail);
    try testing.expectEqualStrings("Hooli", contacts[2].title);
}

test "an escaped semicolon belongs to the organization name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try only(arena.allocator(),
        \\[{"key": "a", "formatted_name": "(no name)", "kind": "individual",
        \\  "organization": "Smith\\; Wesson, Ltd;Sales"}]
    );

    try testing.expectEqualStrings("Smith; Wesson, Ltd", found.title);
}

test "groups and entries without a key are left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "Book Club", "kind": "group"},
        \\  {"formatted_name": "Keyless", "kind": "individual"},
        \\  {"key": "b", "formatted_name": "Device", "kind": "device"}
        \\]
    );

    try testing.expectEqual(@as(usize, 1), contacts.len);
    try testing.expectEqualStrings("Device", contacts[0].title);
}

test "a word is matched against the name, the organization and every address, never a number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "John Appleseed", "kind": "org",
        \\   "organization": "Apple Inc.;Retail",
        \\   "emails": ["john@apple.example", "j@home.example"], "phones": ["+1 555 0100"]},
        \\  {"key": "b", "formatted_name": "Acme Inc.", "kind": "org", "organization": "Acme Inc.;"},
        \\  {"key": "c", "formatted_name": "(no name)", "kind": "individual", "phones": ["+1 555 0101"]}
        \\]
    );

    const wanted = [_][]const u8{ "Apple Inc.", "John Appleseed", "john@apple.example", "j@home.example" };
    try testing.expectEqual(wanted.len, contacts[0].fields.len);
    for (wanted, contacts[0].fields) |expected, field| try testing.expectEqualStrings(expected, field);

    try testing.expectEqual(@as(usize, 1), contacts[1].fields.len);
    try testing.expectEqual(@as(usize, 1), contacts[2].fields.len);
    try testing.expectEqualStrings(unnamed, contacts[2].fields[0]);
}

test "an embedded photo is decoded from base64, a link is kept and broken base64 is noted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "Gif", "photo": {"media_type": "image/gif", "data": "R0lGODdh"}},
        \\  {"key": "b", "formatted_name": "Unknown", "photo": {"data": "AAECAwQ="}},
        \\  {"key": "c", "formatted_name": "Remote", "photo": {"uri": "https://example.com/photo.jpg"}},
        \\  {"key": "d", "formatted_name": "Broken", "photo": {"media_type": "image/jpeg", "data": "not!base64"}},
        \\  {"key": "e", "formatted_name": "Bare"},
        \\  {"key": "f", "formatted_name": "Invalid", "photo": {"media_type": "image/png", "data": "abc!defg"}}
        \\]
    );

    try testing.expectEqualStrings("image/gif", contacts[0].photo.?.embedded.mime);
    try testing.expectEqualStrings("GIF87a", contacts[0].photo.?.embedded.bytes);
    try testing.expectEqualStrings("", contacts[1].photo.?.embedded.mime);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4 }, contacts[1].photo.?.embedded.bytes);
    try testing.expectEqualStrings("https://example.com/photo.jpg", contacts[2].photo.?.linked);
    try testing.expectEqualStrings("image/jpeg", contacts[3].photo.?.broken);
    try testing.expectEqual(@as(?Photo, null), contacts[4].photo);
    try testing.expectEqualStrings("image/png", contacts[5].photo.?.broken);
}

test "unknown fields are ignored and escaped characters are read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try only(arena.allocator(),
        \\[{"key": "addressobject:9c", "account_name": "personal", "uid": "esc",
        \\  "formatted_name": "Smith \u0026 Wesson \u003cSales\u003e", "kind": "individual",
        \\  "title": "Seller", "emails": ["sales@sw.example"], "comment": {"nested": [1, 2]}}]
    );

    try testing.expectEqualStrings("Smith & Wesson <Sales>", found.title);
    try testing.expectEqualStrings("addressobject:9c", found.key);
}

const Script = struct {
    tmp: testing.TmpDir,
    buffer: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",
    environ: std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Script, body: []const u8) !void {
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .environ = .init(testing.allocator),
            .arena = .init(testing.allocator),
        };
        errdefer self.deinit();

        try self.environ.put("PATH", "/usr/bin:/bin");
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "inca",
            .data = body,
            .flags = .{ .permissions = .executable_file },
        });
        const length = try self.tmp.dir.realPath(testing.io, &self.buffer);
        self.path = try std.fmt.bufPrint(self.buffer[length..], "{s}/inca", .{self.buffer[0..length]});
    }

    fn deinit(self: *Script) void {
        self.arena.deinit();
        self.environ.deinit();
        self.tmp.cleanup();
    }

    fn run(self: *Script, limits: Limits) !Read {
        return read(testing.allocator, self.arena.allocator(), testing.io, &self.environ, self.path, limits);
    }
};

test "the program is run with the people list arguments" {
    var script: Script = undefined;
    try script.init(
        \\#!/bin/sh
        \\printf '[{"key": "k", "formatted_name": "%s", "kind": "individual"}]\n' "$*"
        \\
    );
    defer script.deinit();

    const found = (try script.run(.{})).contacts;
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("people list --with-photo --format json", found[0].title);
}

test "a program that isn't there is missing" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\n");
    defer script.deinit();

    script.path = "/nonexistent/sysdeck-test/inca";
    try testing.expectEqual(Read.missing, try script.run(.{}));
}

test "a failing program reports its exit code and the last line of its error output" {
    var script: Script = undefined;
    try script.init(
        \\#!/bin/sh
        \\echo 'starting' >&2
        \\echo 'level=ERROR msg="Could not open the database"' >&2
        \\exit 3
        \\
    );
    defer script.deinit();

    const failure = (try script.run(.{})).failed;
    try testing.expectEqual(@as(u8, 3), failure.exited.code);
    try testing.expectEqualStrings("level=ERROR msg=\"Could not open the database\"", failure.exited.message);

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "exited with 3: level=ERROR msg=\"Could not open the database\"",
        try std.fmt.bufPrint(&buffer, "{f}", .{failure}),
    );
}

test "without error output the last line of the output explains the exit" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\necho 'first'\necho 'broken database'\nexit 1\n");
    defer script.deinit();

    const failure = (try script.run(.{})).failed;
    try testing.expectEqualStrings("broken database", failure.exited.message);
}

test "a program past its deadline is killed and reported" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\nexec sleep 5\n");
    defer script.deinit();

    const started = Io.Clock.awake.now(testing.io);
    const failure = (try script.run(.{ .timeout = .fromMilliseconds(200) })).failed;
    const took = started.durationTo(Io.Clock.awake.now(testing.io));

    try testing.expectEqual(@as(i64, 200), failure.timeout.toMilliseconds());
    try testing.expect(took.toMilliseconds() < 2000);
}

test "output beyond the limit is too large" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\nprintf '%0100d' 0\n");
    defer script.deinit();

    const failure = (try script.run(.{ .output = 16 })).failed;
    try testing.expectEqual(@as(usize, 16), failure.too_large);
}

test "output that isn't Inca's JSON is malformed" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\necho 'No contacts found'\n");
    defer script.deinit();

    const failure = (try script.run(.{})).failed;
    try testing.expect(failure == .malformed);
}
