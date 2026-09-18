const std = @import("std");
const whats = @import("whats");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;
const xdg = @import("core").xdg;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.whats);

pub const table = tables.whats;

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
        const path = cachePath(self.gpa, self.environ) catch return orelse return;
        defer self.gpa.free(path);

        var rates = whats.rates.load(self.gpa, self.io, path, .{}) catch |err| {
            log.debug("cannot load {s}: {t}, so only EUR is known", .{ path, err });
            return;
        };
        defer rates.deinit(self.gpa);

        whats.rates.addTo(registry, rates) catch |err| {
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

    pub fn stale(_: *Index) bool {
        return true;
    }

    pub fn refresh(self: *Index) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        _ = self.ready() catch log.warn("out of memory while building the unit registry", .{});
    }

    pub fn retire(self: *Index, _: ?*store_mod.Store) void {
        if (self.registry) |*built| built.deinit();
        self.registry = null;
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

    pub fn stale(_: *Index) bool {
        return false;
    }

    pub fn refresh(_: *Index) void {}

    pub fn retire(_: *Index, _: ?*store_mod.Store) void {}
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
        .number => std.fmt.allocPrintSentinel(arena, "{d}", .{result.value}, 0),
        .percentage => std.fmt.allocPrintSentinel(arena, "{d}%", .{result.value}, 0),
        .percentage_change => if (result.value > 0)
            std.fmt.allocPrintSentinel(arena, "+{d}%", .{result.value}, 0)
        else
            std.fmt.allocPrintSentinel(arena, "{d}%", .{result.value}, 0),
    };
}

fn cachePath(gpa: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    return xdg.path(gpa, environ, .cache, &.{whats.rates.cache_file_name});
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
    defer Search.retire(&self, null);

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
    defer Search.retire(&self, null);

    for ([_][]const u8{ "", " \t ", "firefox", "2m in", "2 m in kg" }) |query| {
        try testing.expectEqual(subroutines.Output.nothing, try Evaluate.run(&self, owner, query));
    }
}

test "only the search is stale, and only the prompt runs straight away" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var self = testIndex(&environ);
    defer Search.retire(&self, null);

    const search = self.subroutine();
    const prompt = self.evaluate();

    try testing.expectEqual(subroutines.Stage.fallback, search.stage);
    try testing.expectEqual(subroutines.Stage.immediate, prompt.stage);
    try testing.expect(search.stale());
    try testing.expect(!prompt.stale());
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
