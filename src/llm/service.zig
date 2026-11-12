const std = @import("std");
const chat = @import("chat.zig");
const config_mod = @import("../config.zig");
const zenai = @import("zenai");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.llm);

const local_key: [:0]const u8 = "none";

pub const Kind = config_mod.Config.Sources.Llm.Kind;
pub const Provider = config_mod.Config.Sources.Llm.Provider;

fn tagOf(kind: Kind) zenai.provider.Tag {
    return switch (kind) {
        .gemini => .gemini,
        .openai => .openai,
        .anthropic => .anthropic,
    };
}

fn variableOf(kind: Kind) []const u8 {
    return switch (kind) {
        .gemini => "GOOGLE_API_KEY",
        .openai => "OPENAI_API_KEY",
        .anthropic => "ANTHROPIC_API_KEY",
    };
}

pub const Service = struct {
    kind: Kind,
    name: [:0]const u8,
    model: []const u8,
    base_url: ?[:0]const u8,
    key: [:0]const u8,
    variable: []const u8,
    max_tokens: i32,

    fn ready(self: Service) bool {
        return self.key.len > 0;
    }
};

pub const Error = error{ MissingKey, Refused, OutOfMemory };

pub const Delta = struct {
    call: *const fn (context: *anyopaque, text: []const u8) void,
    context: *anyopaque,

    fn push(self: Delta, text: ?[]const u8) void {
        const found = text orelse return;
        if (found.len == 0) return;
        self.call(self.context, found);
    }
};

pub fn collect(
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    entries: []const Provider,
) Allocator.Error![]Service {
    var found: std.ArrayList(Service) = .empty;
    errdefer {
        for (found.items) |service| free(gpa, service);
        found.deinit(gpa);
    }

    for (entries) |entry| {
        const made = build(gpa, environ, entry) catch |err| switch (err) {
            error.OutOfMemory => |leftover| return leftover,
            error.Incomplete => continue,
        };
        found.append(gpa, made) catch |err| {
            free(gpa, made);
            return err;
        };
    }

    return found.toOwnedSlice(gpa);
}

fn build(
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    entry: Provider,
) (Allocator.Error || error{Incomplete})!Service {
    const kind = std.meta.stringToEnum(Kind, entry.kind) orelse {
        log.warn(
            "an [[sources.llm.providers]] entry has kind = \"{s}\", which is not " ++
                "gemini, openai or anthropic, so it is left out",
            .{entry.kind},
        );
        return error.Incomplete;
    };
    if (entry.name.len == 0) {
        log.warn("an [[sources.llm.providers]] entry has no name, so it is left out", .{});
        return error.Incomplete;
    }
    if (entry.model.len == 0) {
        log.warn("the [[sources.llm.providers]] entry \"{s}\" has no model, so it is left out", .{
            entry.name,
        });
        return error.Incomplete;
    }

    const wanted = if (entry.api_key_env.len > 0) entry.api_key_env else variableOf(kind);
    const base_url = if (entry.base_url.len > 0) try gpa.dupeSentinel(u8, entry.base_url, 0) else null;
    errdefer if (base_url) |owned| gpa.free(owned);

    const name = try gpa.dupeSentinel(u8, entry.name, 0);
    errdefer gpa.free(name);

    const model = try gpa.dupe(u8, entry.model);
    errdefer gpa.free(model);

    const key = try keyFor(gpa, environ, kind, entry.api_key_env, base_url != null);
    errdefer gpa.free(key);

    return .{
        .kind = kind,
        .name = name,
        .model = model,
        .base_url = base_url,
        .key = key,
        .variable = try gpa.dupe(u8, wanted),
        .max_tokens = tokensOf(entry),
    };
}

fn tokensOf(entry: Provider) i32 {
    if (entry.max_tokens >= 1) {
        if (std.math.cast(i32, entry.max_tokens)) |wanted| return wanted;
    }

    const fallback: i32 = @intCast(config_mod.default_max_tokens);
    log.warn("the [[sources.llm.providers]] entry \"{s}\" has max_tokens = {d}, which is not " ++
        "between 1 and {d}, so {d} is used", .{ entry.name, entry.max_tokens, std.math.maxInt(i32), fallback });
    return fallback;
}

fn keyFor(
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    kind: Kind,
    named: []const u8,
    hosted: bool,
) Allocator.Error![:0]const u8 {
    if (hosted and named.len == 0) return gpa.dupeSentinel(u8, local_key, 0);

    const wanted = if (named.len > 0) named else variableOf(kind);
    if (environ.get(wanted)) |found| {
        if (found.len > 0) return gpa.dupeSentinel(u8, found, 0);
    }
    if (kind == .openai and hosted) return gpa.dupeSentinel(u8, local_key, 0);
    return gpa.dupeSentinel(u8, "", 0);
}

pub fn release(gpa: Allocator, services: []const Service) void {
    for (services) |service| free(gpa, service);
    gpa.free(services);
}

fn free(gpa: Allocator, service: Service) void {
    gpa.free(service.name);
    gpa.free(service.model);
    gpa.free(service.key);
    gpa.free(service.variable);
    if (service.base_url) |owned| gpa.free(owned);
}

pub fn run(
    io: std.Io,
    gpa: Allocator,
    service: Service,
    turns: []const chat.Turn,
    interrupt: *zenai.http.Interrupt,
    delta: Delta,
) Error!void {
    if (!service.ready()) return error.MissingKey;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const client = zenai.provider.Client.init(io, gpa, tagOf(service.kind), service.key, .{
        .base_url = service.base_url,
    }) catch |err| {
        log.warn("cannot reach {s}: {t}", .{ service.name, err });
        return error.Refused;
    };
    defer client.deinit(gpa);

    client.setInterrupt(interrupt);
    stream(client, arena.allocator(), service, turns, delta) catch |err| {
        if (interrupt.isFired()) return;

        const detail = client.lastError();
        if (detail.message) |message| {
            log.warn("{s} refused the prompt: {t}: {s}", .{ service.name, err, message });
        } else {
            log.warn("{s} refused the prompt: {t}", .{ service.name, err });
        }
        return error.Refused;
    };
}

fn stream(
    client: zenai.provider.Client,
    arena: Allocator,
    service: Service,
    turns: []const chat.Turn,
    delta: Delta,
) !void {
    try client.generateContentStream(
        service.model,
        try messagesOf(arena, turns),
        .{ .max_tokens = service.max_tokens },
        delta,
        &onDelta,
    );
}

fn onDelta(delta: Delta, result: zenai.provider.GenerateResult) void {
    delta.push(result.text);
}

fn messagesOf(
    arena: Allocator,
    turns: []const chat.Turn,
) Allocator.Error![]zenai.provider.Message {
    const out = try arena.alloc(zenai.provider.Message, turns.len);
    for (turns, out) |turn, *slot| {
        slot.* = .{
            .role = switch (turn.role) {
                .user => .user,
                .assistant => .assistant,
            },
            .content = turn.text,
        };
    }
    return out;
}

const testing = std.testing;
const mapOf = @import("core").xdg.mapOf;

const sample = [_]chat.Turn{
    .{ .role = .user, .text = "one" },
    .{ .role = .assistant, .text = "two" },
    .{ .role = .user, .text = "three" },
};

fn encoded(arena: Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer);
    return out.written();
}

test "a request carries the turns as roles and content" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const messages = try messagesOf(gpa, &sample);

    try testing.expectEqualStrings(
        \\[{"role":"user","content":"one"},{"role":"assistant","content":"two"},{"role":"user","content":"three"}]
    , try encoded(gpa, messages));
}

test "an empty conversation maps to an empty request" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(0, (try messagesOf(arena.allocator(), &.{})).len);
}

test "entries are collected in configuration order and named" {
    var environ = try mapOf(&.{.{ "ANTHROPIC_API_KEY", "secret" }});
    defer environ.deinit();

    const entries = [_]Provider{
        .{ .kind = "gemini", .name = "flash", .model = "gemini-2.5-flash" },
        .{ .kind = "openai", .name = "local", .model = "qwen", .base_url = "http://host/v1" },
        .{ .kind = "anthropic", .name = "sonnet", .model = "claude" },
    };

    const services = try collect(testing.allocator, &environ, &entries);
    defer release(testing.allocator, services);

    try testing.expectEqual(3, services.len);
    try testing.expectEqualStrings("flash", services[0].name);
    try testing.expectEqualStrings("local", services[1].name);
    try testing.expectEqualStrings("sonnet", services[2].name);
    try testing.expectEqual(Kind.anthropic, services[2].kind);
}

test "an entry with no name or no model is left out" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const entries = [_]Provider{
        .{ .kind = "openai", .name = "", .model = "qwen" },
        .{ .kind = "openai", .name = "nameless", .model = "" },
        .{ .kind = "openai", .name = "good", .model = "qwen", .base_url = "http://host/v1" },
    };

    const services = try collect(testing.allocator, &environ, &entries);
    defer release(testing.allocator, services);

    try testing.expectEqual(1, services.len);
    try testing.expectEqualStrings("good", services[0].name);
}

test "a local openai server needs no key and a hosted one does" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const entries = [_]Provider{
        .{ .kind = "gemini", .name = "flash", .model = "gemini-2.5-flash" },
        .{ .kind = "openai", .name = "local", .model = "qwen", .base_url = "http://host/v1" },
        .{ .kind = "openai", .name = "cloud", .model = "gpt-4o" },
    };

    const services = try collect(testing.allocator, &environ, &entries);
    defer release(testing.allocator, services);

    try testing.expectEqualStrings("flash", services[0].name);
    try testing.expect(!services[0].ready());
    try testing.expectEqualStrings("GOOGLE_API_KEY", services[0].variable);

    try testing.expectEqualStrings("local", services[1].name);
    try testing.expect(services[1].ready());

    try testing.expectEqualStrings("cloud", services[2].name);
    try testing.expect(!services[2].ready());
    try testing.expectEqualStrings("OPENAI_API_KEY", services[2].variable);
}

test "a base_url without api_key_env never gets the vendor's key" {
    var environ = try mapOf(&.{
        .{ "OPENAI_API_KEY", "openai-secret" },
        .{ "ANTHROPIC_API_KEY", "anthropic-secret" },
        .{ "LOCAL_KEY", "local-secret" },
    });
    defer environ.deinit();

    const entries = [_]Provider{
        .{ .kind = "openai", .name = "local", .model = "qwen", .base_url = "http://host/v1" },
        .{ .kind = "anthropic", .name = "proxy", .model = "claude", .base_url = "http://proxy/v1" },
        .{ .kind = "openai", .name = "named", .model = "qwen", .base_url = "http://host/v1", .api_key_env = "LOCAL_KEY" },
        .{ .kind = "openai", .name = "cloud", .model = "gpt-4o" },
    };

    const services = try collect(testing.allocator, &environ, &entries);
    defer release(testing.allocator, services);

    try testing.expectEqualStrings("none", services[0].key);
    try testing.expectEqualStrings("none", services[1].key);
    try testing.expectEqualStrings("local-secret", services[2].key);
    try testing.expectEqualStrings("openai-secret", services[3].key);
}

test "a configured variable overrides the standard one" {
    var environ = try mapOf(&.{ .{ "MY_KEY", "secret" }, .{ "OPENAI_API_KEY", "wrong" } });
    defer environ.deinit();

    const entries = [_]Provider{
        .{ .kind = "openai", .name = "cloud", .model = "gpt-4o", .api_key_env = "MY_KEY" },
    };

    const services = try collect(testing.allocator, &environ, &entries);
    defer release(testing.allocator, services);

    try testing.expectEqualStrings("secret", services[0].key);
    try testing.expectEqualStrings("MY_KEY", services[0].variable);
}

test "an answer limit below 1 or beyond 32 bits falls back to the default" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const entries = [_]Provider{
        .{ .kind = "gemini", .name = "negative", .model = "m", .max_tokens = -5 },
        .{ .kind = "gemini", .name = "huge", .model = "m", .max_tokens = 1 << 40 },
        .{ .kind = "gemini", .name = "small", .model = "m", .max_tokens = 1 },
    };

    const services = try collect(testing.allocator, &environ, &entries);
    defer release(testing.allocator, services);

    try testing.expectEqual(4096, services[0].max_tokens);
    try testing.expectEqual(4096, services[1].max_tokens);
    try testing.expectEqual(1, services[2].max_tokens);
}

test "the providers are listed in the order the file gives them" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const entries = [_]Provider{
        .{ .kind = "openai", .name = "local", .model = "q", .base_url = "http://host/v1" },
        .{ .kind = "anthropic", .name = "sonnet", .model = "c" },
        .{ .kind = "openai", .name = "cloud", .model = "gpt" },
        .{ .kind = "gemini", .name = "flash", .model = "g" },
    };

    const services = try collect(testing.allocator, &environ, &entries);
    defer release(testing.allocator, services);

    try testing.expectEqual(4, services.len);
    try testing.expectEqualStrings("local", services[0].name);
    try testing.expectEqualStrings("sonnet", services[1].name);
    try testing.expectEqualStrings("cloud", services[2].name);
    try testing.expectEqualStrings("flash", services[3].name);

    try testing.expectEqual(Kind.openai, services[0].kind);
    try testing.expectEqual(Kind.anthropic, services[1].kind);
}

test "an entry with a kind nothing knows is left out" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const entries = [_]Provider{
        .{ .kind = "openai", .name = "local", .model = "q", .base_url = "http://host/v1" },
        .{ .kind = "llama", .name = "wrong", .model = "q" },
        .{ .kind = "", .name = "empty", .model = "q" },
    };

    const services = try collect(testing.allocator, &environ, &entries);
    defer release(testing.allocator, services);

    try testing.expectEqual(1, services.len);
    try testing.expectEqualStrings("local", services[0].name);
}

const providers = [_]Provider{
    .{ .kind = "openai", .name = "local", .model = "qwen3", .base_url = "http://127.0.0.1:8080/v1" },
    .{ .kind = "openai", .name = "cloud", .model = "gpt-5" },
    .{ .kind = "anthropic", .name = "sonnet", .model = "claude-sonnet-5" },
};

fn gathered(gpa: Allocator) !void {
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();

    try environ.put("OPENAI_API_KEY", "secret");

    const services = try collect(gpa, &environ, &providers);
    release(gpa, services);
}

test "a service list that runs out of memory leaves nothing behind" {
    try testing.checkAllAllocationFailures(testing.allocator, gathered, .{});
}
