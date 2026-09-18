const std = @import("std");
const c = @import("../gtk/c.zig");
const fuzzy = @import("core").fuzzy;
const gdk = @import("../gtk/gdk.zig");
const gtk = @import("../gtk/gtk.zig");
const overlay = @import("../screenshot/overlay.zig");
const store_mod = @import("core").store;
const subroutines = @import("../subroutines.zig");
const tables = @import("core").tables;

const Allocator = std.mem.Allocator;

pub const table = tables.screenshot;

const keyword = "screenshot";
const title: [:0]const u8 = "Screenshot";
const detail: [:0]const u8 = "Select a region, a window or a screen";

const icon_names = [_][:0]const u8{
    "applets-screenshooter",
    "accessories-screenshot",
    "camera-photo",
    "image-x-generic",
};

const Action = enum(u64) {
    region = 1,
    window = 2,
    screen = 3,

    fn mode(self: Action) overlay.Mode {
        return switch (self) {
            .region => .region,
            .window => .window,
            .screen => .screen,
        };
    }
};

pub const Requested = struct {
    call: *const fn (context: *anyopaque, mode: overlay.Mode) void,
    context: *anyopaque,
};

pub const Index = struct {
    icon: [:0]const u8,
    windows: bool,
    requested: Requested,

    pub fn subroutine(self: *Index) subroutines.Subroutine {
        return .{ .name = table, .context = self, .vtable = subroutines.vtableOf(Index) };
    }

    pub fn run(
        self: *Index,
        owner: *subroutines.Owner,
        text: []const u8,
    ) subroutines.Error!subroutines.Output {
        const query = std.mem.trim(u8, text, " \t");
        if (query.len == 0) return .nothing;

        const score = fuzzy.score(query, keyword) orelse return .nothing;

        const hits = try owner.allocator().alloc(subroutines.Hit, 1);
        hits[0] = .{
            .row = .{
                .id = 0,
                .icon = .{ .name = self.icon },
                .title = title,
                .detail = detail,
            },
            .score = score,
        };
        return .{ .hits = hits };
    }

    pub fn choose(self: *Index, _: Allocator, _: u64) subroutines.Outcome {
        self.requested.call(self.requested.context, .any);
        return .keep;
    }

    pub fn actions(
        self: *Index,
        arena: Allocator,
        _: u64,
    ) subroutines.Error![]const subroutines.Action {
        var found: std.ArrayList(subroutines.Action) = .empty;

        try found.append(arena, .{
            .id = @intFromEnum(Action.region),
            .title = "Region",
            .detail = "Drag a rectangle",
        });

        if (self.windows) try found.append(arena, .{
            .id = @intFromEnum(Action.window),
            .title = "Window",
            .detail = "Pick one window",
        });

        try found.append(arena, .{
            .id = @intFromEnum(Action.screen),
            .title = "Screen",
            .detail = "Pick one whole screen",
        });

        return found.items;
    }

    pub fn perform(self: *Index, _: Allocator, _: u64, action: u64) subroutines.Outcome {
        const wanted = std.enums.fromInt(Action, action) orelse return .keep;

        self.requested.call(self.requested.context, wanted.mode());
        return .keep;
    }

    pub fn stale(_: *Index) bool {
        return false;
    }

    pub fn refresh(_: *Index) void {}

    pub fn retire(_: *Index, _: ?*store_mod.Store) void {}
};

pub fn enabled(wanted: bool, environ: *const std.process.Environ.Map) bool {
    if (!wanted) return false;

    const display = environ.get("WAYLAND_DISPLAY") orelse return false;
    return display.len > 0;
}

pub fn open(windows: bool, requested: Requested) Index {
    return .{ .icon = pickIcon(), .windows = windows, .requested = requested };
}

fn pickIcon() [:0]const u8 {
    const display = gdk.gdk_display_get_default() orelse return icon_names[icon_names.len - 1];
    const theme = gtk.gtk_icon_theme_get_for_display(display);

    for (icon_names) |name| {
        if (gtk.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    }
    return icon_names[icon_names.len - 1];
}

const testing = std.testing;

test "the word screenshot is matched and a stray query is not" {
    try testing.expect(fuzzy.score("screenshot", keyword) != null);
    try testing.expect(fuzzy.score("shot", keyword) != null);
    try testing.expect(fuzzy.score("scr", keyword) != null);
    try testing.expect(fuzzy.score("zzz", keyword) == null);
}

test "an action number maps to the mode it names" {
    try testing.expectEqual(overlay.Mode.region, Action.region.mode());
    try testing.expectEqual(overlay.Mode.window, Action.window.mode());
    try testing.expectEqual(overlay.Mode.screen, Action.screen.mode());

    try testing.expectEqual(@as(?Action, null), std.enums.fromInt(Action, 0));
    try testing.expectEqual(@as(?Action, null), std.enums.fromInt(Action, 4));
}

test "the subroutine is off without a Wayland session" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try testing.expect(!enabled(true, &environ));

    try environ.put("WAYLAND_DISPLAY", "wayland-1");
    try testing.expect(enabled(true, &environ));
    try testing.expect(!enabled(false, &environ));
}
