const std = @import("std");
const whats = @import("whats");
const icons = @import("core").icons;
const source = @import("source.zig");
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.whats);

pub const table = tables.whats;

const rates_age: std.Io.Duration = .fromSeconds(24 * 60 * 60);
const rates_budget: std.Io.Duration = .fromSeconds(10);

pub const Index = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    mutex: std.Io.Mutex = .init,
    registry: ?whats.Registry = null,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{
            .name = table,
            .context = self,
            .vtable = subroutines.vtableOf(Search),
            .stage = .fallback,
        };
    }

    pub fn evaluate(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Evaluate) };
    }

    pub fn stale(_: *Index) bool {
        return true;
    }

    pub fn refresh(self: *Index) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        _ = self.ready() catch log.warn("out of memory while building the unit registry", .{});
    }

    pub fn retire(self: *Index) void {
        if (self.registry) |*built| built.deinit();
        self.registry = null;
    }

    fn answer(
        self: *Index,
        owner: *subroutines.Owner,
        query: []const u8,
    ) subroutines.Error!subroutines.Output {
        if (query.len == 0) return .nothing;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const registry = try self.ready();
        const arena = owner.allocator();

        const result = whats.eval(arena, registry, query) catch |err| switch (err) {
            error.OutOfMemory => |leftover| return leftover,
            else => return .nothing,
        };

        return .{ .answer = try format(arena, result) };
    }

    fn ready(self: *Index) Allocator.Error!*whats.Registry {
        if (self.registry == null) {
            const built: whats.Registry = try .init(self.gpa, .{});
            self.registry = built;
            self.addRates(&self.registry.?);
        }
        return &self.registry.?;
    }

    fn addRates(self: *Index, registry: *whats.Registry) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        const file = whats.rates.cache_file_name;
        const path = (xdg.path(scratch, self.environ, .cache, &.{file}) catch null) orelse return;

        const marker = source.cacheOf(scratch, self.environ, "rates-attempt", "currency rate");
        if (marker catch null) |found| {
            const fetching: Rates = .{ .file = path, .marker = found };
            fetching.update(self.gpa, self.io);
        }

        var loaded = whats.rates.load(self.gpa, self.io, path, .{ .offline = true }) catch |err| {
            log.debug("cannot load {s}: {t}, so only EUR is known", .{ path, err });
            return;
        };
        defer loaded.deinit(self.gpa);

        whats.rates.addTo(registry, loaded) catch |err| {
            log.debug("cannot add the currency rates: {t}", .{err});
        };
    }
};

pub fn open(context: subroutines.Context) Allocator.Error!?Index {
    if (!context.wanted("whats")) return null;
    return .{ .gpa = context.gpa, .io = context.io, .environ = context.environ };
}

const Search = struct {
    pub const Context = Index;

    pub const choose = shared.choose;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        const query = std.mem.trim(u8, text, " \t");
        if (!answerable(query)) return .nothing;

        return self.answer(owner, query);
    }
};

const Evaluate = struct {
    pub const Context = Index;

    pub const choose = shared.choose;

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        return self.answer(owner, std.mem.trim(u8, text, " \t"));
    }
};

const shared = struct {
    pub fn choose(_: *Index, _: Allocator, _: u64) subroutines.Outcome {
        return .keep;
    }
};

fn answerable(query: []const u8) bool {
    if (query.len == 0) return false;
    return std.ascii.isDigit(query[0]) or query[0] == '(';
}

fn format(arena: Allocator, result: whats.Result) Allocator.Error![:0]u8 {
    return switch (result.display) {
        .number => arena.printSentinel("{d}", .{result.value}, 0),
        .percentage => arena.printSentinel("{d}%", .{result.value}, 0),
        .percentage_change => if (result.value > 0)
            arena.printSentinel("+{d}%", .{result.value}, 0)
        else
            arena.printSentinel("{d}%", .{result.value}, 0),
    };
}

const Rates = struct {
    url: []const u8 = whats.rates.source_url,
    file: []const u8,
    marker: []const u8,
    budget: std.Io.Duration = rates_budget,

    fn update(self: Rates, gpa: Allocator, io: std.Io) void {
        if (recent(io, self.file) or recent(io, self.marker)) return;

        save(io, self.marker, "") catch |err| {
            return log.warn("cannot write {s}: {t}, so the currency rates are not fetched", .{
                self.marker,
                err,
            });
        };

        const bytes = self.fetch(gpa, io) orelse return;
        defer gpa.free(bytes);

        var parsed = whats.rates.parse(gpa, bytes) catch |err| {
            return log.warn("{s} returned no currency rates: {t}, so the next try is in 24 hours", .{
                self.url,
                err,
            });
        };
        defer parsed.deinit(gpa);

        if (parsed.entries.len == 0) {
            return log.warn("{s} returned no currency rates, so the next try is in 24 hours", .{self.url});
        }

        save(io, self.file, bytes) catch |err| log.warn("cannot write {s}: {t}", .{ self.file, err });
    }

    fn fetch(self: Rates, gpa: Allocator, io: std.Io) ?[]u8 {
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();

        const limit = whats.rates.max_document_bytes;
        const fetched = icons.downloadWithin(&client, gpa, io, self.url, limit, self.budget) catch |err| {
            log.warn("cannot fetch the currency rates: {t}, so the next try is in 24 hours", .{err});
            return null;
        };

        return switch (fetched) {
            .bytes => |found| found,
            .failed => |failure| {
                log.warn("cannot fetch the currency rates from {s}: {f}, so the next try is in 24 hours", .{
                    self.url,
                    failure,
                });
                return null;
            },
        };
    }
};

fn recent(io: std.Io, path: []const u8) bool {
    const info = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return info.mtime.untilNow(io, .real).nanoseconds < rates_age.nanoseconds;
}

fn save(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

const testing = std.testing;

fn testIndex(environ: *const std.process.Environ.Map) Index {
    return .{ .gpa = testing.allocator, .io = testing.io, .environ = environ };
}

test "the whats prompt answers what the search gate leaves out" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self = testIndex(&environ);
    defer self.retire();

    for ([_][]const u8{ "-5 + 3", " +5 ", ".5 * 2" }, [_][]const u8{ "-2", "5", "1" }) |query, wanted| {
        try testing.expectEqual(subroutines.Output.nothing, try Search.run(&self, owner, query));

        const found = try Evaluate.run(&self, owner, query);
        try testing.expectEqualStrings(wanted, found.answer);
    }
}

test "the whats prompt shows nothing for text that does not evaluate" {
    const owner = try subroutines.Owner.create(testing.allocator);
    defer owner.destroy(testing.allocator);

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self = testIndex(&environ);
    defer self.retire();

    for ([_][]const u8{ "", " \t ", "firefox", "2m in", "2 m in kg" }) |query| {
        try testing.expectEqual(subroutines.Output.nothing, try Evaluate.run(&self, owner, query));
    }
}

const daily =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
    \\  <Cube>
    \\    <Cube time="2026-11-10">
    \\      <Cube currency="USD" rate="1.0873"/>
    \\    </Cube>
    \\  </Cube>
    \\</gesmes:Envelope>
;

const Cache = struct {
    tmp: testing.TmpDir,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    arena: std.heap.ArenaAllocator,

    fn init(self: *Cache) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator) };
        errdefer self.deinit();

        self.root = self.buffer[0..try self.tmp.dir.realPath(testing.io, &self.buffer)];
    }

    fn deinit(self: *Cache) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn rates(self: *Cache, local: *const icons.Local) !Rates {
        const arena = self.arena.allocator();
        return .{
            .url = try local.url(arena, "/rates"),
            .file = try std.Io.Dir.path.join(arena, &.{ self.root, whats.rates.cache_file_name }),
            .marker = try std.Io.Dir.path.join(arena, &.{ self.root, "sysdeck", "rates-attempt" }),
        };
    }
};

fn exists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(testing.io, path, .{}) catch return false;
    return true;
}

test "a failed attempt to fetch the rates is not repeated within 24 hours" {
    var local: icons.Local = undefined;
    try local.start(testing.io, &.{.{ .path = "/rates", .status = .internal_server_error }});
    defer local.stop();

    var cache: Cache = undefined;
    try cache.init();
    defer cache.deinit();

    const rates = try cache.rates(&local);
    rates.update(testing.allocator, testing.io);
    rates.update(testing.allocator, testing.io);

    try testing.expectEqual(1, local.served.load(.monotonic));
    try testing.expect(exists(rates.marker));
    try testing.expect(!exists(rates.file));
}

test "fetched rates are kept, and rates younger than 24 hours send no request" {
    var local: icons.Local = undefined;
    try local.start(testing.io, &.{.{ .path = "/rates", .body = daily }});
    defer local.stop();

    var cache: Cache = undefined;
    try cache.init();
    defer cache.deinit();

    const rates = try cache.rates(&local);
    rates.update(testing.allocator, testing.io);

    var loaded = try whats.rates.load(testing.allocator, testing.io, rates.file, .{ .offline = true });
    defer loaded.deinit(testing.allocator);
    try testing.expectApproxEqRel(1.0873, loaded.get("USD").?, 1e-12);

    try cache.tmp.dir.deleteFile(testing.io, "sysdeck/rates-attempt");
    rates.update(testing.allocator, testing.io);
    try testing.expectEqual(1, local.served.load(.monotonic));
}

test "a document without rates leaves the rates fetched before" {
    var local: icons.Local = undefined;
    try local.start(testing.io, &.{.{ .path = "/rates", .body = "<html>busy</html>" }});
    defer local.stop();

    var cache: Cache = undefined;
    try cache.init();
    defer cache.deinit();

    const rates = try cache.rates(&local);
    try cache.tmp.dir.writeFile(testing.io, .{ .sub_path = whats.rates.cache_file_name, .data = daily });
    try cache.tmp.dir.setTimestamps(testing.io, whats.rates.cache_file_name, .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } },
    });

    rates.update(testing.allocator, testing.io);

    try testing.expectEqual(1, local.served.load(.monotonic));
    var loaded = try whats.rates.load(testing.allocator, testing.io, rates.file, .{ .offline = true });
    defer loaded.deinit(testing.allocator);
    try testing.expectApproxEqRel(1.0873, loaded.get("USD").?, 1e-12);
}

test "the index is due at every start, and only the prompt runs straight away" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self = testIndex(&environ);
    defer self.retire();

    const search = self.subroutine();
    const prompt = self.evaluate();

    try testing.expectEqual(subroutines.Stage.fallback, search.stage);
    try testing.expectEqual(subroutines.Stage.immediate, prompt.stage);
    try testing.expect(self.stale());
}

test "a digit or an opening parenthesis is answered" {
    try testing.expect(answerable("1 + 2"));
    try testing.expect(answerable("2 meters in feet"));
    try testing.expect(answerable("0"));
    try testing.expect(answerable("(2 + 1) * 3"));

    try testing.expect(!answerable(""));
    try testing.expect(!answerable("firefox"));
    try testing.expect(!answerable("-5 + 3"));
    try testing.expect(!answerable("--help"));
}

fn expectFormatted(result: whats.Result, expected: []const u8) !void {
    const text = try format(testing.allocator, result);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "a result reads the way the whats command prints it" {
    try expectFormatted(.{ .value = 6.561679790026246 }, "6.561679790026246");
    try expectFormatted(.{ .value = 20, .display = .percentage }, "20%");
    try expectFormatted(.{ .value = 100, .display = .percentage_change }, "+100%");
    try expectFormatted(.{ .value = -50, .display = .percentage_change }, "-50%");
    try expectFormatted(.{ .value = 0, .display = .percentage_change }, "0%");
}

fn expectEvaluated(registry: *whats.Registry, query: []const u8, want: f64) !void {
    const result = try whats.eval(testing.allocator, registry, query);
    try testing.expectApproxEqRel(want, result.value, 1e-12);
}

test "conversions and calculations are evaluated" {
    var registry: whats.Registry = try .init(testing.allocator, .{});
    defer registry.deinit();

    try expectEvaluated(&registry, "2 meters in feet", 6.561679790026246);
    try expectEvaluated(&registry, "1 + 2", 3);
    try expectEvaluated(&registry, "1024 KiB in MiB", 1);
}

test "units take part in arithmetic" {
    var registry: whats.Registry = try .init(testing.allocator, .{});
    defer registry.deinit();

    try expectEvaluated(&registry, "2 m + 30 cm in ft", 7.545931758530183);
    try expectEvaluated(&registry, "(1 GB + 500 MB) in MB", 1500);
    try expectEvaluated(&registry, "(2 + 1) * 3 ^ 2", 27);
    try expectEvaluated(&registry, "2 + 2 * 4", 10);
    try expectEvaluated(&registry, "100 + 10%", 110);
    try expectEvaluated(&registry, "100 km/h x 2", 200);
}

test "input that is not an expression is rejected" {
    var registry: whats.Registry = try .init(testing.allocator, .{});
    defer registry.deinit();

    for ([_][]const u8{ "1p", "1password", "2 flurbles in ft" }) |query| {
        try testing.expectError(
            error.UnexpectedToken,
            whats.eval(testing.allocator, &registry, query),
        );
    }

    try testing.expectError(
        error.UnexpectedEnd,
        whats.eval(testing.allocator, &registry, "1 +"),
    );
    try testing.expectError(
        error.IncompatibleUnits,
        whats.eval(testing.allocator, &registry, "2 m in kg"),
    );
}
