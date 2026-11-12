const std = @import("std");
const command = @import("command.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const program = "inca";
pub const arguments = [_][]const u8{ "people", "list", "--with-photo", "--format", "json" };
pub const unnamed = "(no name)";

const separator = " · ";
const output_format = "Inca's JSON";

pub const Embedded = struct {
    mime: []const u8,
    bytes: []const u8,
};

pub const Photo = union(enum) {
    embedded: Embedded,
    linked: []const u8,
    broken: []const u8,
};

pub const Field = enum {
    name,
    nickname,
    organization,
    job_title,
    email,
    phone,
    messaging,
    social,
    address,
    website,
    date,
    note,

    fn label(self: Field) []const u8 {
        return switch (self) {
            .name => "Name",
            .nickname => "Nickname",
            .organization => "Organization",
            .job_title => "Job title",
            .email => "Email",
            .phone => "Phone",
            .messaging => "Messaging",
            .social => "Social profile",
            .address => "Address",
            .website => "Website",
            .date => "Date",
            .note => "Note",
        };
    }
};

pub const Detail = struct {
    field: Field,
    value: []const u8,
    title: [:0]const u8,
    caption: [:0]const u8,
};

pub const Contact = struct {
    key: []const u8,
    title: [:0]const u8,
    detail: [:0]const u8,
    fields: []const []const u8,
    numbers: []const []const u8 = &.{},
    details: []const Detail = &.{},
    photo: ?Photo = null,
};

pub const Read = union(enum) {
    contacts: []const Contact,
    missing,
    failed: command.Failure,
};

const Labeled = struct {
    labels: []const []const u8 = &.{},
    value: []const u8 = "",
};

const Service = struct {
    labels: []const []const u8 = &.{},
    service: []const u8 = "",
    value: []const u8 = "",
};

const Person = struct {
    key: []const u8 = "",
    formatted_name: []const u8 = "",
    kind: []const u8 = "",
    nicknames: []const Labeled = &.{},
    organization: []const u8 = "",
    title: []const u8 = "",
    emails: []const Labeled = &.{},
    phones: []const Labeled = &.{},
    impps: []const Service = &.{},
    social_profiles: []const Service = &.{},
    addresses: []const Labeled = &.{},
    websites: []const Labeled = &.{},
    dates: []const Labeled = &.{},
    notes: []const Labeled = &.{},
    photo: ?Picture = null,
};

const Organization = struct {
    name: []const u8,
    text: []const u8,
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
    limits: command.Limits,
) error{ OutOfMemory, Canceled }!Read {
    var argv: [arguments.len + 1][]const u8 = undefined;
    argv[0] = path;
    @memcpy(argv[1..], &arguments);

    const output = switch (try command.run(gpa, arena, io, environ, &argv, limits)) {
        .printed => |output| output,
        .missing => return .missing,
        .failed => |failure| return .{ .failed = failure },
    };
    defer gpa.free(output);

    const contacts = parse(gpa, arena, output) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .failed = .{ .malformed = .{ .expected = output_format, .cause = err } } },
    };
    return .{ .contacts = contacts };
}

fn parse(gpa: Allocator, arena: Allocator, json: []const u8) ParseError![]const Contact {
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
    const spoken = trimmed(person.formatted_name);
    const named = spoken.len > 0 and !std.mem.eql(u8, spoken, unnamed);
    const organization = try organizationOf(arena, person.organization);
    const company = organization.name;

    const chosen = if (std.mem.eql(u8, person.kind, "org") and company.len > 0)
        company
    else if (named)
        spoken
    else if (company.len > 0)
        company
    else
        unnamed;
    const title = try arena.dupeSentinel(u8, chosen, 0);

    var fields: std.ArrayList([]const u8) = .empty;
    try fields.append(arena, title);
    if (named and !std.mem.eql(u8, spoken, title)) try fields.append(arena, try arena.dupe(u8, spoken));
    if (company.len > 0 and !std.mem.eql(u8, company, title)) try fields.append(arena, company);
    for (person.nicknames) |nickname| {
        const text = trimmed(nickname.value);
        if (text.len > 0) try fields.append(arena, try arena.dupe(u8, text));
    }
    for (person.emails) |email| try fields.append(arena, try arena.dupe(u8, email.value));

    var numbers: std.ArrayList([]const u8) = .empty;
    for (person.phones) |phone| {
        const text = trimmed(phone.value);
        if (text.len > 0) try numbers.append(arena, try arena.dupe(u8, text));
    }

    return .{
        .key = try arena.dupe(u8, person.key),
        .title = title,
        .detail = try detailOf(arena, person),
        .fields = fields.items,
        .numbers = numbers.items,
        .details = try detailsOf(arena, person, organization),
        .photo = try photoOf(arena, person.photo),
    };
}

fn organizationOf(arena: Allocator, raw: []const u8) Allocator.Error!Organization {
    var parts: std.ArrayList([]const u8) = .empty;
    var part: std.ArrayList(u8) = .empty;

    var at: usize = 0;
    while (at < raw.len) : (at += 1) {
        const char = raw[at];
        if (char == ';') {
            try parts.append(arena, try finished(arena, &part));
        } else if (char == '\\' and at + 1 < raw.len and raw[at + 1] == ';') {
            try part.append(arena, ';');
            at += 1;
        } else {
            try part.append(arena, char);
        }
    }
    try parts.append(arena, try finished(arena, &part));

    var text: std.ArrayList(u8) = .empty;
    for (parts.items) |found| {
        if (found.len == 0) continue;
        if (text.items.len > 0) try text.appendSlice(arena, ", ");
        try text.appendSlice(arena, found);
    }
    return .{ .name = parts.items[0], .text = text.items };
}

fn finished(arena: Allocator, part: *std.ArrayList(u8)) Allocator.Error![]const u8 {
    return trimmed(try part.toOwnedSlice(arena));
}

fn detailOf(arena: Allocator, person: Person) Allocator.Error![:0]const u8 {
    const email = firstOf(person.emails);
    const phone = firstOf(person.phones);

    if (email.len > 0 and phone.len > 0) {
        return arena.printSentinel("{s}" ++ separator ++ "{s}", .{ email, phone }, 0);
    }
    return arena.dupeSentinel(u8, if (email.len > 0) email else phone, 0);
}

fn firstOf(values: []const Labeled) []const u8 {
    if (values.len == 0) return "";
    return trimmed(values[0].value);
}

fn detailsOf(arena: Allocator, person: Person, organization: Organization) Allocator.Error![]const Detail {
    var details: std.ArrayList(Detail) = .empty;

    const spoken = trimmed(person.formatted_name);
    const repeated = std.mem.eql(u8, spoken, organization.name) or std.mem.eql(u8, spoken, organization.text);
    if (!std.mem.eql(u8, spoken, unnamed) and !repeated) try add(arena, &details, .name, "", &.{}, spoken);

    for (person.nicknames) |found| try add(arena, &details, .nickname, "", found.labels, found.value);
    try add(arena, &details, .organization, "", &.{}, organization.text);
    try add(arena, &details, .job_title, "", &.{}, person.title);
    for (person.emails) |found| try add(arena, &details, .email, "", found.labels, found.value);
    for (person.phones) |found| try add(arena, &details, .phone, "", found.labels, found.value);
    for (person.impps) |found| try add(arena, &details, .messaging, found.service, found.labels, handleOf(found.value));
    for (person.social_profiles) |found| try add(arena, &details, .social, found.service, found.labels, found.value);
    for (person.addresses) |found| try add(arena, &details, .address, "", found.labels, found.value);
    for (person.websites) |found| try add(arena, &details, .website, "", found.labels, found.value);
    for (person.dates) |found| try add(arena, &details, .date, "", found.labels, found.value);
    for (person.notes) |found| try add(arena, &details, .note, "", found.labels, found.value);

    return details.items;
}

fn add(
    arena: Allocator,
    details: *std.ArrayList(Detail),
    field: Field,
    service: []const u8,
    labels: []const []const u8,
    raw: []const u8,
) Allocator.Error!void {
    const text = trimmed(raw);
    if (text.len == 0) return;

    const value = try arena.dupe(u8, text);
    try details.append(arena, .{
        .field = field,
        .value = value,
        .title = try lineOf(arena, value),
        .caption = try captionOf(arena, field, service, labels),
    });
}

fn captionOf(
    arena: Allocator,
    field: Field,
    service: []const u8,
    labels: []const []const u8,
) Allocator.Error![:0]const u8 {
    var caption: std.ArrayList(u8) = .empty;
    try caption.appendSlice(arena, field.label());

    var listed = false;
    const named = trimmed(service);
    if (named.len > 0) {
        try caption.appendSlice(arena, separator);
        try caption.appendSlice(arena, named);
        listed = true;
    }
    for (labels) |label| {
        const text = trimmed(label);
        if (text.len == 0) continue;
        try caption.appendSlice(arena, if (listed) ", " else separator);
        try caption.appendSlice(arena, text);
        listed = true;
    }
    return caption.toOwnedSliceSentinel(arena, 0);
}

fn lineOf(arena: Allocator, value: []const u8) Allocator.Error![:0]const u8 {
    var line: std.ArrayList(u8) = .empty;

    var at: usize = 0;
    while (at < value.len) {
        var end = at;
        while (end < value.len and std.ascii.isWhitespace(value[end])) end += 1;
        if (end == at) {
            try line.append(arena, value[at]);
            at += 1;
            continue;
        }

        const run = value[at..end];
        if (std.mem.findAny(u8, run, "\r\n") != null) {
            try line.append(arena, ' ');
        } else {
            try line.appendSlice(arena, run);
        }
        at = end;
    }
    return line.toOwnedSliceSentinel(arena, 0);
}

fn handleOf(value: []const u8) []const u8 {
    const colon = std.mem.findScalar(u8, value, ':') orelse return value;
    if (!isScheme(value[0..colon])) return value;

    var rest = value[colon + 1 ..];
    if (std.mem.startsWith(u8, rest, "//")) rest = rest[2..];
    if (trimmed(rest).len == 0) return value;
    return rest;
}

fn isScheme(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '+' and char != '-' and char != '.') return false;
    }
    return true;
}

fn trimmed(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, &std.ascii.whitespace);
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

const testing = std.testing;

fn parsed(arena: Allocator, json: []const u8) ![]const Contact {
    return parse(testing.allocator, arena, json);
}

fn only(arena: Allocator, json: []const u8) !Contact {
    const contacts = try parsed(arena, json);
    try testing.expectEqual(1, contacts.len);
    return contacts[0];
}

test "a contact is titled by its name and described by its first address and number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "Pref Second", "kind": "individual",
        \\   "emails": [{"labels": ["work"], "value": "second@example.com"},
        \\              {"labels": ["home"], "value": "first@example.com"}],
        \\   "phones": [{"labels": ["cell"], "value": "+1 555 0002"},
        \\              {"labels": ["home"], "value": "+1 555 0001"}]},
        \\  {"key": "b", "formatted_name": "Max Mustermann", "kind": "individual",
        \\   "emails": [{"labels": [], "value": "max@example.de"}]},
        \\  {"key": "c", "formatted_name": "Wide Photo", "kind": "individual",
        \\   "phones": [{"labels": [], "value": "+44 20 7946 0000"}]},
        \\  {"key": "d", "formatted_name": "Bad Base64", "kind": "individual"}
        \\]
    );

    try testing.expectEqual(4, contacts.len);
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
        \\   "organization": "Apple Inc.;Retail", "emails": [{"labels": [], "value": "john@apple.example"}]},
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
        \\   "organization": "Initech;Engineering", "emails": [{"labels": [], "value": "hr@initech.example"}]},
        \\  {"key": "b", "formatted_name": "(no name)", "kind": "individual",
        \\   "emails": [{"labels": [], "value": "anon@example.net"}]},
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

    try testing.expectEqual(1, contacts.len);
    try testing.expectEqualStrings("Device", contacts[0].title);
}

test "a word is matched against the name, the organization, the nicknames and every address, never a number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "John Appleseed", "kind": "org",
        \\   "organization": "Apple Inc.;Retail",
        \\   "nicknames": [{"labels": [], "value": "Johnny"}, {"labels": ["work"], "value": " "}],
        \\   "emails": [{"labels": ["work"], "value": "john@apple.example"},
        \\              {"labels": ["home"], "value": "j@home.example"}],
        \\   "phones": [{"labels": ["cell"], "value": "+1 555 0100"}]},
        \\  {"key": "b", "formatted_name": "Acme Inc.", "kind": "org", "organization": "Acme Inc.;"},
        \\  {"key": "c", "formatted_name": "(no name)", "kind": "individual",
        \\   "phones": [{"labels": [], "value": "+1 555 0101"}]}
        \\]
    );

    const wanted = [_][]const u8{ "Apple Inc.", "John Appleseed", "Johnny", "john@apple.example", "j@home.example" };
    try testing.expectEqual(wanted.len, contacts[0].fields.len);
    for (wanted, contacts[0].fields) |expected, field| try testing.expectEqualStrings(expected, field);

    try testing.expectEqual(1, contacts[1].fields.len);
    try testing.expectEqual(1, contacts[2].fields.len);
    try testing.expectEqualStrings(unnamed, contacts[2].fields[0]);
}

test "a contact's phone numbers are kept apart from the fields the search matches" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "Tom Ato", "kind": "individual",
        \\   "emails": [{"labels": [], "value": "tom@example.com"}],
        \\   "phones": [{"labels": ["cell"], "value": " +1-555-0101 "}, {"labels": [], "value": " "},
        \\              {"labels": ["work"], "value": "+49 170 1234567"}]},
        \\  {"key": "b", "formatted_name": "Max Mustermann", "kind": "individual"}
        \\]
    );

    const wanted = [_][]const u8{ "+1-555-0101", "+49 170 1234567" };
    try testing.expectEqual(wanted.len, contacts[0].numbers.len);
    for (wanted, contacts[0].numbers) |expected, number| try testing.expectEqualStrings(expected, number);
    for (contacts[0].fields) |field| try testing.expect(std.mem.findScalar(u8, field, '5') == null);

    try testing.expectEqual(0, contacts[1].numbers.len);
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
    try testing.expectEqual(null, contacts[4].photo);
    try testing.expectEqualStrings("image/png", contacts[5].photo.?.broken);
}

test "unknown fields are ignored and escaped characters are read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try only(arena.allocator(),
        \\[{"key": "addressobject:9c", "account_name": "personal", "uid": "esc",
        \\  "formatted_name": "Smith \u0026 Wesson \u003cSales\u003e", "kind": "individual",
        \\  "title": "Seller", "emails": [{"labels": [], "value": "sales@sw.example"}],
        \\  "comment": {"nested": [1, 2]}}]
    );

    try testing.expectEqualStrings("Smith & Wesson <Sales>", found.title);
    try testing.expectEqualStrings("addressobject:9c", found.key);
}

test "a contact's details come in the menu's order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try only(arena.allocator(),
        \\[{"key": "a", "formatted_name": "Tom Ato", "kind": "individual",
        \\  "nicknames": [{"labels": [], "value": "Tommy"}],
        \\  "organization": "Vegetable Corp;Produce", "title": "Gardener",
        \\  "emails": [{"labels": ["home"], "value": "tom.ato@example.com"}],
        \\  "phones": [{"labels": ["cell"], "value": "+1-555-0100"}],
        \\  "impps": [{"labels": ["home"], "service": "skype", "value": "skype:tom.ato"}],
        \\  "social_profiles": [{"labels": [], "service": "twitter", "value": "https://twitter.com/tomato"}],
        \\  "addresses": [{"labels": ["work", "postal"], "value": "PO Box 9, 1 Market Sq, Springfield"}],
        \\  "websites": [{"labels": ["homepage"], "value": "https://tom.example.com"}],
        \\  "dates": [{"labels": ["birthday"], "value": "--04-12"}],
        \\  "notes": [{"labels": [], "value": "Prefers calls after 6 pm.\nAllergic to cats."}]}]
    );

    const Expected = struct { field: Field, title: []const u8, caption: []const u8 };
    const wanted = [_]Expected{
        .{ .field = .name, .title = "Tom Ato", .caption = "Name" },
        .{ .field = .nickname, .title = "Tommy", .caption = "Nickname" },
        .{ .field = .organization, .title = "Vegetable Corp, Produce", .caption = "Organization" },
        .{ .field = .job_title, .title = "Gardener", .caption = "Job title" },
        .{ .field = .email, .title = "tom.ato@example.com", .caption = "Email · home" },
        .{ .field = .phone, .title = "+1-555-0100", .caption = "Phone · cell" },
        .{ .field = .messaging, .title = "tom.ato", .caption = "Messaging · skype, home" },
        .{ .field = .social, .title = "https://twitter.com/tomato", .caption = "Social profile · twitter" },
        .{ .field = .address, .title = "PO Box 9, 1 Market Sq, Springfield", .caption = "Address · work, postal" },
        .{ .field = .website, .title = "https://tom.example.com", .caption = "Website · homepage" },
        .{ .field = .date, .title = "--04-12", .caption = "Date · birthday" },
        .{ .field = .note, .title = "Prefers calls after 6 pm. Allergic to cats.", .caption = "Note" },
    };

    try testing.expectEqual(wanted.len, found.details.len);
    for (wanted, found.details) |expected, detail| {
        try testing.expectEqual(expected.field, detail.field);
        try testing.expectEqualStrings(expected.title, detail.title);
        try testing.expectEqualStrings(expected.caption, detail.caption);
    }
    try testing.expectEqualStrings("tom.ato@example.com · +1-555-0100", found.detail);
}

test "a caption is the kind and the labels, with the service first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try testing.expectEqualStrings("Note", try captionOf(scratch, .note, "", &.{}));
    try testing.expectEqualStrings("Phone · iphone, cell", try captionOf(scratch, .phone, "", &.{ "iphone", "cell" }));
    try testing.expectEqualStrings("Social profile · linkedin", try captionOf(scratch, .social, "linkedin", &.{}));
    try testing.expectEqualStrings("Messaging · jabber, other", try captionOf(scratch, .messaging, "jabber", &.{"other"}));
    try testing.expectEqualStrings("Date · First met", try captionOf(scratch, .date, " ", &.{ "", "First met" }));
}

test "a messaging detail keeps only the handle" {
    try testing.expectEqualStrings("tom.ato", handleOf("skype:tom.ato"));
    try testing.expectEqualStrings("tom@example.com", handleOf("xmpp:tom@example.com"));
    try testing.expectEqualStrings("alice@example.com", handleOf("sip://alice@example.com"));
    try testing.expectEqualStrings("goim?screenname=tom", handleOf("aim:goim?screenname=tom"));
    try testing.expectEqualStrings("tom@vegetable.example.com", handleOf("tom@vegetable.example.com"));
    try testing.expectEqualStrings("skype:", handleOf("skype:"));
    try testing.expectEqualStrings("1x:tom", handleOf("1x:tom"));
    try testing.expectEqualStrings("my handle:tom", handleOf("my handle:tom"));
}

test "a note is shown on one line and copied whole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try testing.expectEqualStrings("one two", try lineOf(scratch, "one \n\n two"));
    try testing.expectEqualStrings("one two", try lineOf(scratch, "one\r\ntwo"));
    try testing.expectEqualStrings("one  two", try lineOf(scratch, "one  two"));

    const found = try only(scratch,
        \\[{"key": "a", "formatted_name": "Tom Ato",
        \\  "notes": [{"labels": [], "value": "Line one\nLine two; with semicolon"}]}]
    );
    const note = found.details[found.details.len - 1];
    try testing.expectEqualStrings("Line one Line two; with semicolon", note.title);
    try testing.expectEqualStrings("Line one\nLine two; with semicolon", note.value);
}

test "the name is left out when it is (no name) or the organization" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const contacts = try parsed(arena.allocator(),
        \\[
        \\  {"key": "a", "formatted_name": "(no name)", "organization": "Initech;Engineering"},
        \\  {"key": "b", "formatted_name": "Acme Inc.", "kind": "org", "organization": "Acme Inc.;"},
        \\  {"key": "c", "formatted_name": "Acme Inc.", "kind": "org", "organization": "Acme Inc.;Sales"},
        \\  {"key": "d", "formatted_name": "Jane Doe", "organization": "Acme Inc.;"}
        \\]
    );

    for (contacts[0..3]) |contact| {
        try testing.expectEqual(1, contact.details.len);
        try testing.expectEqual(Field.organization, contact.details[0].field);
    }
    try testing.expectEqualStrings("Acme Inc., Sales", contacts[2].details[0].value);
    try testing.expectEqual(Field.name, contacts[3].details[0].field);
    try testing.expectEqual(Field.organization, contacts[3].details[1].field);
}

test "the organization lists every component" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const escaped = try organizationOf(scratch, "Smith\\; Wesson, Ltd;Sales");
    try testing.expectEqualStrings("Smith; Wesson, Ltd", escaped.name);
    try testing.expectEqualStrings("Smith; Wesson, Ltd, Sales", escaped.text);

    try testing.expectEqualStrings("Acme Inc.", (try organizationOf(scratch, "Acme Inc.;")).text);

    const unit = try organizationOf(scratch, " ;Sales");
    try testing.expectEqualStrings("", unit.name);
    try testing.expectEqualStrings("Sales", unit.text);

    const empty = try organizationOf(scratch, "");
    try testing.expectEqualStrings("", empty.name);
    try testing.expectEqualStrings("", empty.text);
}

const Script = struct {
    tmp: testing.TmpDir,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
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
        self.path = try std.mem.print(self.buffer[length..], "{s}/inca", .{self.buffer[0..length]});
    }

    fn deinit(self: *Script) void {
        self.arena.deinit();
        self.environ.deinit();
        self.tmp.cleanup();
    }

    fn run(self: *Script) !Read {
        return read(testing.allocator, self.arena.allocator(), testing.io, &self.environ, self.path, .{});
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

    const found = (try script.run()).contacts;
    try testing.expectEqual(1, found.len);
    try testing.expectEqualStrings("people list --with-photo --format json", found[0].title);
}

test "output that isn't Inca's JSON is malformed" {
    var script: Script = undefined;
    try script.init("#!/bin/sh\necho 'No contacts found'\n");
    defer script.deinit();

    const failure = (try script.run()).failed;
    try testing.expect(failure == .malformed);

    var buffer: [128]u8 = undefined;
    const text = try std.mem.print(&buffer, "{f}", .{failure});
    try testing.expect(std.mem.startsWith(u8, text, "printed what isn't Inca's JSON: "));
}
