const std = @import("std");
const whats = @import("whats");
const store_mod = @import("../store.zig");
const subroutines = @import("../subroutines.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.whats);

pub const table = "whats";

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
            .vtable = &vtable,
            .stage = .fallback,
        };
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

const vtable: subroutines.Subroutine.VTable = .{
    .run = &run,
    .choose = &choose,
    .release = &release,
    .stale = &stale,
    .refresh = &refresh,
    .retire = &retire,
};

fn run(context: *anyopaque, gpa: Allocator, text: []const u8) subroutines.Error!subroutines.Output {
    const self: *Index = @ptrCast(@alignCast(context));

    const query = std.mem.trim(u8, text, " \t");
    if (!answerable(query)) return .nothing;

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const registry = try self.ready();

    const result = whats.eval(gpa, registry, query) catch |err| switch (err) {
        error.OutOfMemory => |leftover| return leftover,
        else => return .nothing,
    };

    return .{ .answer = try format(gpa, result) };
}

fn answerable(query: []const u8) bool {
    if (query.len == 0) return false;
    return std.ascii.isDigit(query[0]) or query[0] == '(';
}

fn format(gpa: Allocator, result: whats.Result) Allocator.Error![:0]u8 {
    return switch (result.display) {
        .number => std.fmt.allocPrintSentinel(gpa, "{d}", .{result.value}, 0),
        .percentage => std.fmt.allocPrintSentinel(gpa, "{d}%", .{result.value}, 0),
        .percentage_change => if (result.value > 0)
            std.fmt.allocPrintSentinel(gpa, "+{d}%", .{result.value}, 0)
        else
            std.fmt.allocPrintSentinel(gpa, "{d}%", .{result.value}, 0),
    };
}

fn cachePath(gpa: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    const name = whats.rates.cache_file_name;

    if (environ.get("XDG_CACHE_HOME")) |dir| {
        if (dir.len > 0) return try std.fs.path.join(gpa, &.{ dir, name });
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) return try std.fs.path.join(gpa, &.{ home, ".cache", name });
    }
    return null;
}

fn choose(_: *anyopaque, _: Allocator, _: u64) subroutines.Outcome {
    return .keep;
}

fn release(_: *anyopaque, gpa: Allocator, output: subroutines.Output) void {
    switch (output) {
        .nothing, .hits, .marks => {},
        .answer => |text| gpa.free(text),
    }
}

fn stale(_: *anyopaque) bool {
    return true;
}

fn refresh(context: *anyopaque) void {
    const self: *Index = @ptrCast(@alignCast(context));

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    _ = self.ready() catch log.warn("out of memory while building the unit registry", .{});
}

fn retire(context: *anyopaque, _: ?*store_mod.Store) void {
    const self: *Index = @ptrCast(@alignCast(context));

    if (self.registry) |*built| built.deinit();
    self.registry = null;
}

const testing = std.testing;

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
