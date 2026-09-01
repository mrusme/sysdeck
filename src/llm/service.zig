const std = @import("std");
const chat = @import("chat.zig");
const config_mod = @import("../config.zig");
const zenai = @import("zenai");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.llm);

const local_key: [:0]const u8 = "none";

pub const Kind = config_mod.Config.Llm.Kind;

pub fn tagOf(kind: Kind) zenai.provider.Tag {
    return switch (kind) {
        .gemini => .gemini,
        .openai => .openai,
        .anthropic => .anthropic,
    };
}

pub fn variableOf(kind: Kind) []const u8 {
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

    pub fn ready(self: Service) bool {
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
    settings: config_mod.Config.Llm,
    order: []const Kind,
) Allocator.Error![]Service {
    var found: std.ArrayList(Service) = .empty;
    errdefer release(gpa, found.items);

    if (order.len == 0) {
        for ([_]Kind{ .gemini, .openai, .anthropic }) |kind| {
            for (settings.entries(kind)) |entry| try push(gpa, environ, &found, kind, entry);
        }
        return found.toOwnedSlice(gpa);
    }

    var taken: std.EnumArray(Kind, usize) = .initFill(0);
    for (order) |kind| {
        const entries = settings.entries(kind);
        const at = taken.get(kind);
        if (at >= entries.len) continue;

        taken.set(kind, at + 1);
        try push(gpa, environ, &found, kind, entries[at]);
    }

    for ([_]Kind{ .gemini, .openai, .anthropic }) |kind| {
        const entries = settings.entries(kind);
        var at = taken.get(kind);
        while (at < entries.len) : (at += 1) {
            try push(gpa, environ, &found, kind, entries[at]);
        }
    }

    return found.toOwnedSlice(gpa);
}

fn push(
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    out: *std.ArrayList(Service),
    kind: Kind,
    entry: config_mod.Config.Llm.Service,
) Allocator.Error!void {
    const made = build(gpa, environ, kind, entry) catch |err| switch (err) {
        error.OutOfMemory => |leftover| return leftover,
        error.Incomplete => return,
    };
    out.append(gpa, made) catch |err| {
        free(gpa, made);
        return err;
    };
}

fn build(
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    kind: Kind,
    entry: config_mod.Config.Llm.Service,
) (Allocator.Error || error{Incomplete})!Service {
    if (entry.name.len == 0) {
        log.warn("an [[llm.{t}]] entry has no name, so it is left out", .{kind});
        return error.Incomplete;
    }
    if (entry.model.len == 0) {
        log.warn("[[llm.{t}]] \"{s}\" has no model, so it is left out", .{ kind, entry.name });
        return error.Incomplete;
    }

    const wanted = if (entry.api_key_env.len > 0) entry.api_key_env else variableOf(kind);
    const base_url = if (entry.base_url.len > 0) try gpa.dupeZ(u8, entry.base_url) else null;
    errdefer if (base_url) |owned| gpa.free(owned);

    const name = try gpa.dupeZ(u8, entry.name);
    errdefer gpa.free(name);

    const model = try gpa.dupe(u8, entry.model);
    errdefer gpa.free(model);

    return .{
        .kind = kind,
        .name = name,
        .model = model,
        .base_url = base_url,
        .key = try keyFor(gpa, environ, kind, wanted, base_url != null),
        .variable = try gpa.dupe(u8, wanted),
        .max_tokens = std.math.cast(i32, entry.max_tokens) orelse
            @intCast(config_mod.default_max_tokens),
    };
}

fn keyFor(
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    kind: Kind,
    wanted: []const u8,
    hosted: bool,
) Allocator.Error![:0]const u8 {
    if (environ.get(wanted)) |found| {
        if (found.len > 0) return gpa.dupeZ(u8, found);
    }
    if (kind == .openai and hosted) return gpa.dupeZ(u8, local_key);
    return gpa.dupeZ(u8, "");
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
    switch (client) {
        .gemini, .vertex => |gemini| try gemini.generateContentStream(
            service.model,
            try geminiContents(arena, turns),
            null,
            .{},
            delta,
            &onGemini,
        ),
        .anthropic => |anthropic| try anthropic.createMessageStream(
            service.model,
            try anthropicMessages(arena, turns),
            service.max_tokens,
            .{},
            delta,
            &onAnthropic,
        ),
        .codex => return error.UnsupportedByBackend,
        inline else => |openai| try openai.chatCompletionStream(
            service.model,
            try openAiMessages(arena, turns),
            .{},
            delta,
            &onOpenAi,
        ),
    }
}

fn onOpenAi(delta: Delta, response: zenai.openai.types.ChatCompletionResponse) void {
    delta.push(response.text());
}

fn onGemini(delta: Delta, response: zenai.gemini.types.GenerateContentResponse) void {
    delta.push(response.text());
}

fn onAnthropic(delta: Delta, event: zenai.anthropic.types.StreamEvent) void {
    const found = event.delta orelse return;
    delta.push(found.text);
}

pub fn openAiMessages(
    arena: Allocator,
    turns: []const chat.Turn,
) Allocator.Error![]zenai.openai.types.Message {
    const out = try arena.alloc(zenai.openai.types.Message, turns.len);
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

pub fn geminiContents(
    arena: Allocator,
    turns: []const chat.Turn,
) Allocator.Error![]zenai.gemini.types.Content {
    const out = try arena.alloc(zenai.gemini.types.Content, turns.len);
    for (turns, out) |turn, *slot| {
        const parts = try arena.alloc(zenai.gemini.types.Part, 1);
        parts[0] = .{ .text = turn.text };

        slot.* = .{
            .role = switch (turn.role) {
                .user => "user",
                .assistant => "model",
            },
            .parts = parts,
        };
    }
    return out;
}

pub fn anthropicMessages(
    arena: Allocator,
    turns: []const chat.Turn,
) Allocator.Error![]zenai.anthropic.types.MessageParam {
    const out = try arena.alloc(zenai.anthropic.types.MessageParam, turns.len);
    for (turns, out) |turn, *slot| {
        const blocks = try arena.alloc(zenai.anthropic.types.ContentBlockParam, 1);
        blocks[0] = .{ .type = "text", .text = turn.text };

        slot.* = .{
            .role = switch (turn.role) {
                .user => .user,
                .assistant => .assistant,
            },
            .content = blocks,
        };
    }
    return out;
}

const testing = std.testing;

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

test "an openai request carries the turns as roles and content" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const messages = try openAiMessages(gpa, &sample);

    try testing.expectEqualStrings(
        \\[{"role":"user","content":"one"},{"role":"assistant","content":"two"},{"role":"user","content":"three"}]
    , try encoded(gpa, messages));
}

test "a gemini request uses model for the assistant and wraps text in parts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const contents = try geminiContents(gpa, &sample);

    try testing.expectEqualStrings(
        \\[{"role":"user","parts":[{"text":"one"}]},{"role":"model","parts":[{"text":"two"}]},{"role":"user","parts":[{"text":"three"}]}]
    , try encoded(gpa, contents));
}

test "an anthropic request wraps text in a content block" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const messages = try anthropicMessages(gpa, &sample);

    try testing.expectEqualStrings(
        \\[{"role":"user","content":[{"type":"text","text":"one"}]},{"role":"assistant","content":[{"type":"text","text":"two"}]},{"role":"user","content":[{"type":"text","text":"three"}]}]
    , try encoded(gpa, messages));
}

test "an empty conversation maps to an empty request" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try openAiMessages(gpa, &.{})).len);
    try testing.expectEqual(@as(usize, 0), (try geminiContents(gpa, &.{})).len);
    try testing.expectEqual(@as(usize, 0), (try anthropicMessages(gpa, &.{})).len);
}

fn mapOf(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(testing.allocator);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "entries are collected in configuration order and named" {
    var environ = try mapOf(&.{.{ "ANTHROPIC_API_KEY", "secret" }});
    defer environ.deinit();

    const services = try collect(testing.allocator, &environ, .{
        .gemini = &.{.{ .name = "flash", .model = "gemini-2.5-flash" }},
        .openai = &.{.{ .name = "local", .model = "qwen", .base_url = "http://host/v1" }},
        .anthropic = &.{.{ .name = "sonnet", .model = "claude" }},
    }, &.{});
    defer release(testing.allocator, services);

    try testing.expectEqual(@as(usize, 3), services.len);
    try testing.expectEqualStrings("flash", services[0].name);
    try testing.expectEqualStrings("local", services[1].name);
    try testing.expectEqualStrings("sonnet", services[2].name);
    try testing.expectEqual(Kind.anthropic, services[2].kind);
}

test "an entry with no name or no model is left out" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const services = try collect(testing.allocator, &environ, .{
        .openai = &.{
            .{ .name = "", .model = "qwen" },
            .{ .name = "nameless", .model = "" },
            .{ .name = "good", .model = "qwen", .base_url = "http://host/v1" },
        },
    }, &.{});
    defer release(testing.allocator, services);

    try testing.expectEqual(@as(usize, 1), services.len);
    try testing.expectEqualStrings("good", services[0].name);
}

test "a local openai server needs no key and a hosted one does" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const services = try collect(testing.allocator, &environ, .{
        .openai = &.{
            .{ .name = "local", .model = "qwen", .base_url = "http://host/v1" },
            .{ .name = "cloud", .model = "gpt-4o" },
        },
        .gemini = &.{.{ .name = "flash", .model = "gemini-2.5-flash" }},
    }, &.{});
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

test "a configured variable overrides the standard one" {
    var environ = try mapOf(&.{ .{ "MY_KEY", "secret" }, .{ "OPENAI_API_KEY", "wrong" } });
    defer environ.deinit();

    const services = try collect(testing.allocator, &environ, .{
        .openai = &.{.{ .name = "cloud", .model = "gpt-4o", .api_key_env = "MY_KEY" }},
    }, &.{});
    defer release(testing.allocator, services);

    try testing.expectEqualStrings("secret", services[0].key);
    try testing.expectEqualStrings("MY_KEY", services[0].variable);
}

test "the file order decides the dropdown order" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const settings: config_mod.Config.Llm = .{
        .gemini = &.{.{ .name = "flash", .model = "g" }},
        .openai = &.{
            .{ .name = "local", .model = "q", .base_url = "http://host/v1" },
            .{ .name = "cloud", .model = "gpt" },
        },
        .anthropic = &.{.{ .name = "sonnet", .model = "c" }},
    };

    const order = [_]Kind{ .openai, .anthropic, .openai, .gemini };
    const services = try collect(testing.allocator, &environ, settings, &order);
    defer release(testing.allocator, services);

    try testing.expectEqual(@as(usize, 4), services.len);
    try testing.expectEqualStrings("local", services[0].name);
    try testing.expectEqualStrings("sonnet", services[1].name);
    try testing.expectEqualStrings("cloud", services[2].name);
    try testing.expectEqualStrings("flash", services[3].name);
}

test "an entry the order missed is still listed at the end" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const settings: config_mod.Config.Llm = .{
        .openai = &.{
            .{ .name = "first", .model = "q", .base_url = "http://host/v1" },
            .{ .name = "second", .model = "q", .base_url = "http://host/v1" },
        },
    };

    const order = [_]Kind{.openai};
    const services = try collect(testing.allocator, &environ, settings, &order);
    defer release(testing.allocator, services);

    try testing.expectEqual(@as(usize, 2), services.len);
    try testing.expectEqualStrings("first", services[0].name);
    try testing.expectEqualStrings("second", services[1].name);
}

test "no order at all falls back to grouping by kind" {
    var environ = try mapOf(&.{});
    defer environ.deinit();

    const services = try collect(testing.allocator, &environ, .{
        .openai = &.{.{ .name = "local", .model = "q", .base_url = "http://host/v1" }},
        .gemini = &.{.{ .name = "flash", .model = "g" }},
    }, &.{});
    defer release(testing.allocator, services);

    try testing.expectEqualStrings("flash", services[0].name);
    try testing.expectEqualStrings("local", services[1].name);
}
