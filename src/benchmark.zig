const std = @import("std");

pub const Mark = enum {
    main,
    config_loaded,
    gtk_registered,
    deck_created,
    activated,
    session_built,
    presenting,
    realized,
    presented,
    blur_delivered,
    panel_shown,
    rerun,
};

pub const Phase = enum { open, refresh, picks, query, list, blur };

pub const Event = enum { spawn, deliver, publish, layout };

const Span = struct {
    phase: Phase,
    name: []const u8,
    count: ?usize = null,
};

const Count = struct {
    what: Event,
    name: []const u8,
    count: usize,
};

const Record = union(enum) {
    mark: Mark,
    begin: Span,
    end: Span,
    event: Count,
};

const line_bytes = 256;

var enabled: std.atomic.Value(bool) = .init(false);

pub fn enable() void {
    enabled.store(true, .monotonic);
}

pub fn mark(what: Mark) void {
    emit(.{ .mark = what });
}

pub fn begin(phase: Phase, name: []const u8) void {
    emit(.{ .begin = .{ .phase = phase, .name = name } });
}

pub fn end(phase: Phase, name: []const u8, count: ?usize) void {
    emit(.{ .end = .{ .phase = phase, .name = name, .count = count } });
}

pub fn event(what: Event, name: []const u8, count: usize) void {
    emit(.{ .event = .{ .what = what, .name = name, .count = count } });
}

fn emit(record: Record) void {
    if (!enabled.load(.monotonic)) return;

    var buffer: [line_bytes]u8 = undefined;
    const line = render(&buffer, now(), record) catch return;
    _ = std.c.write(std.posix.STDERR_FILENO, line.ptr, line.len);
}

fn render(buffer: []u8, stamp: f64, record: Record) std.Io.Writer.Error![]u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("benchmark {d:.3} ", .{stamp});
    switch (record) {
        .mark => |what| try writer.print("mark {t}", .{what}),
        .begin => |span| try writer.print("begin {t} {s}", .{ span.phase, span.name }),
        .end => |span| {
            try writer.print("end {t} {s}", .{ span.phase, span.name });
            if (span.count) |count| try writer.print(" {d}", .{count});
        },
        .event => |found| try writer.print("{t} {s} {d}", .{ found.what, found.name, found.count }),
    }
    try writer.writeByte('\n');
    return writer.buffered();
}

fn now() f64 {
    var spec: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &spec);
    const nanoseconds = @as(i128, spec.sec) * std.time.ns_per_s + spec.nsec;
    const elapsed: f64 = @floatFromInt(nanoseconds);
    return elapsed / std.time.ns_per_ms;
}

const testing = std.testing;

test "a line holds the stamp, the kind and its fields" {
    var buffer: [line_bytes]u8 = undefined;

    try testing.expectEqualStrings(
        "benchmark 12.500 mark panel_shown\n",
        try render(&buffer, 12.5, .{ .mark = .panel_shown }),
    );
    try testing.expectEqualStrings(
        "benchmark 0.250 begin open apps\n",
        try render(&buffer, 0.25, .{ .begin = .{ .phase = .open, .name = "apps" } }),
    );
    try testing.expectEqualStrings(
        "benchmark 3.000 end picks bins 6\n",
        try render(&buffer, 3, .{ .end = .{ .phase = .picks, .name = "bins", .count = 6 } }),
    );
    try testing.expectEqualStrings(
        "benchmark 3.000 end refresh ssh\n",
        try render(&buffer, 3, .{ .end = .{ .phase = .refresh, .name = "ssh" } }),
    );
    try testing.expectEqualStrings(
        "benchmark 1024.125 layout window 548\n",
        try render(&buffer, 1024.125, .{ .event = .{ .what = .layout, .name = "window", .count = 548 } }),
    );
}
