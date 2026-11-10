const std = @import("std");
const glob = @import("glob.zig");
const xdg = @import("xdg.zig");

const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const log = std.log.scoped(.ssh);

pub const max_depth = 16;

const max_bytes = 1 << 20;
const blanks = " \t\r\x0c";

pub const Attribute = struct {
    keyword: []const u8,
    value: []const u8,
};

pub const Host = struct {
    name: []const u8,
    address: []const u8,
    attributes: []const Attribute,
};

pub fn parse(arena: Allocator, text: []const u8) Allocator.Error![]Host {
    var reader: Reader = .{ .arena = arena };
    try reader.lines(text, 0);
    return reader.hosts();
}

pub fn read(arena: Allocator, io: std.Io, home: []const u8, environ: *const Map) ![]Host {
    const path = try std.Io.Dir.path.join(arena, &.{ home, ".ssh", "config" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes));

    var reader: Reader = .{
        .arena = arena,
        .files = .{ .io = io, .home = home, .environ = environ },
    };
    try reader.lines(text, 0);
    return reader.hosts();
}

const Files = struct {
    io: std.Io,
    home: []const u8,
    environ: *const Map,
};

const Scope = union(enum) {
    patterns: []const []const u8,
    nothing,
};

const Kind = enum { host, match };

const Block = struct {
    kind: Kind,
    patterns: []const []const u8,
    names: []const []const u8,
};

const Setting = struct {
    block: usize,
    attribute: Attribute,
};

const Reader = struct {
    arena: Allocator,
    files: ?Files = null,
    blocks: std.ArrayList(Block) = .empty,
    settings: std.ArrayList(Setting) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    current: ?usize = null,

    fn lines(self: *Reader, text: []const u8, depth: usize) Allocator.Error!void {
        var rest = std.mem.splitScalar(u8, text, '\n');
        while (rest.next()) |raw| {
            const line = Line.of(raw) orelse continue;
            try self.take(line, depth);
        }
    }

    fn take(self: *Reader, line: Line, depth: usize) Allocator.Error!void {
        if (line.is("Host")) return self.open(.host, line.value);
        if (line.is("Match")) return self.open(.match, line.value);
        if (line.is("Include")) return self.include(line.value, depth);

        const block = self.current orelse return;
        try self.settings.append(self.arena, .{
            .block = block,
            .attribute = .{ .keyword = line.keyword, .value = line.value },
        });
    }

    fn open(self: *Reader, kind: Kind, value: []const u8) Allocator.Error!void {
        var patterns: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList([]const u8) = .empty;

        var tokens: Tokens = .{ .text = value };
        while (try tokens.next(self.arena)) |token| {
            try patterns.append(self.arena, token);

            if (kind != .host or !concrete(token)) continue;
            if (contains(names.items, token) or !self.allowed(token)) continue;
            try names.append(self.arena, token);
        }

        try self.blocks.append(self.arena, .{
            .kind = kind,
            .patterns = patterns.items,
            .names = names.items,
        });
        self.current = self.blocks.items.len - 1;
    }

    fn allowed(self: *Reader, name: []const u8) bool {
        for (self.scopes.items) |scope| {
            switch (scope) {
                .nothing => return false,
                .patterns => |patterns| if (!listed(patterns, name)) return false,
            }
        }
        return true;
    }

    fn include(self: *Reader, value: []const u8, depth: usize) Allocator.Error!void {
        const files = self.files orelse return;

        const enclosing = self.current;
        const mark = self.scopes.items.len;
        defer self.scopes.shrinkRetainingCapacity(mark);

        if (enclosing) |at| {
            if (scopeOf(self.blocks.items[at])) |scope| try self.scopes.append(self.arena, scope);
        }

        var tokens: Tokens = .{ .text = value };
        while (try tokens.next(self.arena)) |argument| {
            const pattern = (try resolve(self.arena, files, argument)) orelse continue;

            for (try glob.expand(self.arena, files.io, pattern)) |path| {
                if (depth >= max_depth) {
                    log.warn("{s} is included more than {d} levels deep, so it is left out", .{
                        path,
                        max_depth,
                    });
                    continue;
                }

                const text = std.Io.Dir.cwd().readFileAlloc(
                    files.io,
                    path,
                    self.arena,
                    .limited(max_bytes),
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.FileNotFound => continue,
                    else => {
                        log.warn("cannot read {s}: {t}, so its hosts are left out", .{ path, err });
                        continue;
                    },
                };

                try self.lines(text, depth + 1);
                self.current = enclosing;
            }
        }
    }

    fn hosts(self: *Reader) Allocator.Error![]Host {
        var merged: std.array_hash_map.String(std.ArrayList(Attribute)) = .empty;

        for (self.blocks.items) |block| {
            for (block.names) |name| {
                const slot = try merged.getOrPut(self.arena, name);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
            }
        }

        for (self.settings.items) |setting| {
            for (self.blocks.items[setting.block].names) |name| {
                try merged.getPtr(name).?.append(self.arena, setting.attribute);
            }
        }

        const found = try self.arena.alloc(Host, merged.count());
        for (merged.keys(), merged.values(), found) |name, attributes, *host| {
            host.* = .{
                .name = name,
                .address = try addressOf(self.arena, name, attributes.items),
                .attributes = attributes.items,
            };
        }
        return found;
    }
};

const Line = struct {
    keyword: []const u8,
    value: []const u8,

    fn of(raw: []const u8) ?Line {
        const text = std.mem.trim(u8, raw, blanks);
        if (text.len == 0 or text[0] == '#') return null;

        const end = std.mem.findAny(u8, text, blanks ++ "=") orelse text.len;

        var rest = std.mem.trimStart(u8, text[end..], blanks);
        if (rest.len > 0 and rest[0] == '=') rest = std.mem.trimStart(u8, rest[1..], blanks);

        return .{ .keyword = text[0..end], .value = uncommented(rest) };
    }

    fn is(self: Line, keyword: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.keyword, keyword);
    }
};

const Tokens = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Tokens, arena: Allocator) Allocator.Error!?[]const u8 {
        while (self.at < self.text.len and blank(self.text[self.at])) self.at += 1;
        if (self.at >= self.text.len) return null;

        var out: std.ArrayList(u8) = .empty;
        var quoted = false;

        while (self.at < self.text.len) : (self.at += 1) {
            const byte = self.text[self.at];
            if (byte == '"') {
                quoted = !quoted;
                continue;
            }
            if (!quoted and blank(byte)) break;
            try out.append(arena, byte);
        }

        return try out.toOwnedSlice(arena);
    }
};

fn uncommented(text: []const u8) []const u8 {
    var quoted = false;
    var fresh = true;

    for (text, 0..) |byte, at| {
        if (!quoted and fresh and byte == '#') return std.mem.trimEnd(u8, text[0..at], blanks);
        if (byte == '"') quoted = !quoted;
        fresh = !quoted and blank(byte);
    }
    return text;
}

fn blank(byte: u8) bool {
    return std.mem.findScalar(u8, blanks, byte) != null;
}

fn concrete(pattern: []const u8) bool {
    if (pattern.len == 0 or pattern[0] == '!') return false;
    return std.mem.findAny(u8, pattern, "*?") == null;
}

fn contains(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

fn scopeOf(block: Block) ?Scope {
    return switch (block.kind) {
        .host => .{ .patterns = block.patterns },
        .match => if (block.patterns.len == 1 and std.ascii.eqlIgnoreCase(block.patterns[0], "all"))
            null
        else
            .nothing,
    };
}

fn listed(patterns: []const []const u8, name: []const u8) bool {
    var found = false;
    for (patterns) |pattern| {
        const negated = pattern.len > 0 and pattern[0] == '!';
        if (!wildcard(if (negated) pattern[1..] else pattern, name)) continue;
        if (negated) return false;
        found = true;
    }
    return found;
}

fn wildcard(pattern: []const u8, text: []const u8) bool {
    var wanted: usize = 0;
    var at: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;

    while (at < text.len) {
        if (wanted < pattern.len and pattern[wanted] == '*') {
            wanted += 1;
            star = wanted;
            mark = at;
            continue;
        }

        if (wanted < pattern.len and (pattern[wanted] == '?' or pattern[wanted] == text[at])) {
            wanted += 1;
            at += 1;
            continue;
        }

        wanted = star orelse return false;
        mark += 1;
        at = mark;
    }

    while (wanted < pattern.len and pattern[wanted] == '*') wanted += 1;
    return wanted == pattern.len;
}

fn resolve(arena: Allocator, files: Files, argument: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.findScalar(u8, argument, '%') != null) {
        log.warn(
            "the ssh Include of \"{s}\" uses a % token, which sysdeck does not expand, " ++
                "so it is left out",
            .{argument},
        );
        return null;
    }

    const expanded = (try variables(arena, files.environ, argument)) orelse return null;
    const path = try xdg.expand(arena, files.home, expanded);
    if (std.Io.Dir.path.isAbsolute(path)) return path;

    return try std.Io.Dir.path.join(arena, &.{ files.home, ".ssh", path });
}

fn variables(arena: Allocator, environ: *const Map, text: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.find(u8, text, "${") == null) return text;

    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;

    while (at < text.len) {
        if (!std.mem.startsWith(u8, text[at..], "${")) {
            try out.append(arena, text[at]);
            at += 1;
            continue;
        }

        const close = std.mem.findScalarPos(u8, text, at + 2, '}') orelse {
            log.warn("the ssh Include of \"{s}\" has an unclosed ${{, so it is left out", .{text});
            return null;
        };

        const name = text[at + 2 .. close];
        const value = environ.get(name) orelse {
            log.warn(
                "the ssh Include of \"{s}\" reads ${{{s}}}, which is not set, so it is left out",
                .{ text, name },
            );
            return null;
        };

        try out.appendSlice(arena, value);
        at = close + 1;
    }

    return try out.toOwnedSlice(arena);
}

fn addressOf(
    arena: Allocator,
    name: []const u8,
    attributes: []const Attribute,
) Allocator.Error![]const u8 {
    for (attributes) |attribute| {
        if (!std.ascii.eqlIgnoreCase(attribute.keyword, "HostName")) continue;

        var tokens: Tokens = .{ .text = attribute.value };
        const value = (try tokens.next(arena)) orelse return name;
        return tokensOf(arena, value, name);
    }
    return name;
}

fn tokensOf(arena: Allocator, value: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.findScalar(u8, value, '%') == null) return value;

    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;

    while (at < value.len) : (at += 1) {
        if (value[at] == '%' and at + 1 < value.len) {
            switch (value[at + 1]) {
                'h' => {
                    try out.appendSlice(arena, name);
                    at += 1;
                    continue;
                },
                '%' => {
                    try out.append(arena, '%');
                    at += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(arena, value[at]);
    }

    return try out.toOwnedSlice(arena);
}

const testing = std.testing;

const gitlab =
    \\Host gitlab.com
    \\  HostName gitlab.com
    \\  Port 22
    \\  User git
    \\  ClearAllForwardings yes
    \\  PreferredAuthentications publickey
    \\  PubkeyAuthentication yes
    \\  IdentityFile ~/.ssh/f0g6-sk2
    \\  IdentityFile ~/.ssh/f0g6-sk3
;

fn expectNames(expected: []const u8, found: []const Host) !void {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);

    for (found, 0..) |host, at| {
        if (at > 0) try joined.append(testing.allocator, ' ');
        try joined.appendSlice(testing.allocator, host.name);
    }
    try testing.expectEqualStrings(expected, joined.items);
}

fn expectAttribute(host: Host, at: usize, keyword: []const u8, value: []const u8) !void {
    try testing.expectEqualStrings(keyword, host.attributes[at].keyword);
    try testing.expectEqualStrings(value, host.attributes[at].value);
}

test "every attribute of a host is kept in the order it was written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try parse(arena.allocator(), gitlab);
    try testing.expectEqual(@as(usize, 1), found.len);

    const host = found[0];
    try testing.expectEqualStrings("gitlab.com", host.name);
    try testing.expectEqualStrings("gitlab.com", host.address);
    try testing.expectEqual(@as(usize, 8), host.attributes.len);
    try expectAttribute(host, 0, "HostName", "gitlab.com");
    try expectAttribute(host, 1, "Port", "22");
    try expectAttribute(host, 2, "User", "git");
    try expectAttribute(host, 3, "ClearAllForwardings", "yes");
    try expectAttribute(host, 4, "PreferredAuthentications", "publickey");
    try expectAttribute(host, 5, "PubkeyAuthentication", "yes");
    try expectAttribute(host, 6, "IdentityFile", "~/.ssh/f0g6-sk2");
    try expectAttribute(host, 7, "IdentityFile", "~/.ssh/f0g6-sk3");
}

test "the fallback for every host is not a host" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try parse(arena.allocator(), gitlab ++ "\n\nHost *\n  ServerAliveInterval 60\n");
    try expectNames("gitlab.com", found);
    try testing.expectEqual(@as(usize, 8), found[0].attributes.len);
}

test "a line naming several hosts gives each of them the block" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try parse(arena.allocator(), "Host web db\n  User deploy\n");
    try expectNames("web db", found);
    for (found) |host| try expectAttribute(host, 0, "User", "deploy");
}

test "patterns are left out and the names beside them stay" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try parse(arena.allocator(), "Host *.corp db 10.0.0.? !bad web db\n  User me\n");
    try expectNames("db web", found);
    try testing.expectEqual(@as(usize, 1), found[0].attributes.len);
}

test "a match ends the block before it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try parse(arena.allocator(), "Host web\n  User me\nMatch all\n  Port 2222\n");
    try expectNames("web", found);
    try testing.expectEqual(@as(usize, 1), found[0].attributes.len);
}

test "the settings before the first host belong to no host" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source = "# defaults\nUser nobody\n\nHost web\n  Port 2222\n";
    const found = try parse(arena.allocator(), source);
    try expectNames("web", found);
    try testing.expectEqual(@as(usize, 1), found[0].attributes.len);
    try expectAttribute(found[0], 0, "Port", "2222");
}

test "every way of separating a keyword from its value is read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        "host=web\r\n" ++
        "\tHostName=10.0.0.5\r\n" ++
        "  user = deploy # who logs in\n" ++
        "  Port\t2222\n" ++
        "  ProxyJump bastion#1\n";

    const found = try parse(arena.allocator(), source);
    try expectNames("web", found);
    try testing.expectEqualStrings("10.0.0.5", found[0].address);
    try expectAttribute(found[0], 0, "HostName", "10.0.0.5");
    try expectAttribute(found[0], 1, "user", "deploy");
    try expectAttribute(found[0], 2, "Port", "2222");
    try expectAttribute(found[0], 3, "ProxyJump", "bastion#1");
}

test "quotes are kept in the value and removed from the name and address" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try parse(
        arena.allocator(),
        "Host \"web\"\n  HostName \"web.example.com\"\n  IdentityFile \"~/.ssh/my key\" # a\n",
    );
    try expectNames("web", found);
    try testing.expectEqualStrings("web.example.com", found[0].address);
    try expectAttribute(found[0], 1, "IdentityFile", "\"~/.ssh/my key\"");
}

test "the address expands the host token and a doubled percent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try parse(arena.allocator(), "Host web\n  HostName %h.example.com%%\n");
    try testing.expectEqualStrings("web.example.com%", found[0].address);
    try expectAttribute(found[0], 0, "HostName", "%h.example.com%%");
}

test "a host without a hostname is reached by its own name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try parse(arena.allocator(), "Host web\n  User me\n");
    try testing.expectEqualStrings("web", found[0].address);
}

test "a host named twice keeps both blocks and the first hostname" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\Host web
        \\  HostName first.example.com
        \\Host db web
        \\  HostName second.example.com
        \\  User deploy
    ;

    const found = try parse(arena.allocator(), source);
    try expectNames("web db", found);
    try testing.expectEqualStrings("first.example.com", found[0].address);
    try testing.expectEqual(@as(usize, 3), found[0].attributes.len);
    try expectAttribute(found[0], 2, "User", "deploy");
    try testing.expectEqualStrings("second.example.com", found[1].address);
}

test "an include is ignored when there are no files to read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const found = try parse(arena.allocator(), "Include config.d/*\nHost web\n");
    try expectNames("web", found);
}

const Fixture = struct {
    tmp: testing.TmpDir,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    environ: Map,
    arena: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{
            .tmp = testing.tmpDir(.{}),
            .environ = .init(testing.allocator),
            .arena = .init(testing.allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.environ.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, path: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(testing.io, parent);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn home(self: *Fixture) ![]const u8 {
        const length = try self.tmp.dir.realPath(testing.io, &self.buffer);
        return self.buffer[0..length];
    }

    fn hosts(self: *Fixture) ![]Host {
        return read(self.arena.allocator(), testing.io, try self.home(), &self.environ);
    }
};

test "an include is read below ~/.ssh in byte order" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.write(".ssh/config", "Include config.d/*.conf\nHost last\n");
    try fixture.write(".ssh/config.d/b.conf", "Host bravo\n  User b\n");
    try fixture.write(".ssh/config.d/a.conf", "Host alpha\n  User a\n");
    try fixture.write(".ssh/config.d/C.conf", "Host charlie\n  User c\n");

    try expectNames("charlie alpha bravo last", try fixture.hosts());
}

test "the block around an include is current again after it" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.write(".ssh/config", "Host web\n  Include inner\n  User after\n");
    try fixture.write(".ssh/inner", "Port 2222\nHost web\n  User inner\n");

    const found = try fixture.hosts();
    try expectNames("web", found);
    try testing.expectEqual(@as(usize, 3), found[0].attributes.len);
    try expectAttribute(found[0], 0, "Port", "2222");
    try expectAttribute(found[0], 1, "User", "inner");
    try expectAttribute(found[0], 2, "User", "after");
}

test "an included host is left out unless the host around the include matches it" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.write(".ssh/config", "Host t\n  Include inner\n  HostName outer\n");
    try fixture.write(".ssh/inner", "Host t\n  HostName inner\nHost other\n  Port 3333\n");

    const found = try fixture.hosts();
    try expectNames("t", found);
    try testing.expectEqualStrings("inner", found[0].address);
}

test "a wildcard around an include lets through what it matches" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.write(
        ".ssh/config",
        "Host * !other\n  Include inner\nHost oth*\n  Include inner\n",
    );
    try fixture.write(".ssh/inner", "Host other\n  Port 3333\nHost web\n");

    const found = try fixture.hosts();
    try expectNames("web other", found);
    try testing.expectEqual(@as(usize, 1), found[1].attributes.len);
}

test "an include under a match counts only for match all" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.write(
        ".ssh/config",
        "Match exec \"test -f ~/.vpn-up\"\n  Include corp\nMatch ALL\n  Include home\n",
    );
    try fixture.write(".ssh/corp", "Host corphost\n  HostName 10.1.2.3\n");
    try fixture.write(".ssh/home", "Host nas\n  HostName 192.168.1.2\n");

    try expectNames("nas", try fixture.hosts());
}

test "a nested include has to pass every host around it" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.write(".ssh/config", "Host web*\n  Include outer\n");
    try fixture.write(".ssh/outer", "Host *1\n  Include inner\n");
    try fixture.write(".ssh/inner", "Host web1 web2 db1\n");

    try expectNames("web1", try fixture.hosts());
}

test "an include expands the environment and home, and skips what it cannot expand" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    const home = try fixture.home();
    const absolute = try fixture.arena.allocator().print("{s}/elsewhere", .{home});
    try fixture.environ.put("SSH_EXTRA", absolute);

    try fixture.write(
        ".ssh/config",
        "Include ${SSH_EXTRA}/extra ${SSH_UNSET}/gone %d/.ssh/tokens\nHost web\n",
    );
    try fixture.write("elsewhere/extra", "Host extra\n");
    try fixture.write(".ssh/tokens", "Host tokens\n");

    try expectNames("extra web", try fixture.hosts());
}

test "an include that includes itself stops at the depth ssh allows" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.write(".ssh/config", "Include loop\n");
    try fixture.write(".ssh/loop", "Host looped\n  User me\n  Include loop\n");

    const found = try fixture.hosts();
    try expectNames("looped", found);
    try testing.expectEqual(@as(usize, max_depth), found[0].attributes.len);
}

test "an include of a file that is not there is passed over" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.write(".ssh/config", "Include missing ~/.ssh/missing.d/*\nHost web\n");

    try expectNames("web", try fixture.hosts());
}

test "a config that is not there is reported as missing" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try testing.expectError(error.FileNotFound, fixture.hosts());
}
