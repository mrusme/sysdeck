const c = @import("gtk/c.zig");
const media = @import("core").media;

pub const Icon = union(enum) {
    none,
    name: [:0]const u8,
    gicon: *c.GIcon,
    glyph: [:0]const u8,
};

pub const Tone = enum { good, bad, idle };

pub const Status = struct {
    text: [:0]const u8,
    tone: Tone = .idle,
};

pub const Badge = union(enum) {
    process: i32,
    status: Status,
};

pub const Row = struct {
    id: u64,
    icon: Icon = .none,
    number: u8 = 0,
    title: [:0]const u8,
    detail: [:0]const u8 = "",
    verb: [:0]const u8 = "",
    program: []const u8 = "",
    badges: []const Badge = &.{},
    media: ?media.Handle = null,
    separated: bool = false,
};

pub const Global = enum { forget };

pub const Choice = union(enum) {
    own: u64,
    global: Global,
};

pub const Offer = struct {
    title: [:0]const u8,
    detail: [:0]const u8 = "",
    icon: Icon = .none,
    choice: Choice,
    separated: bool = false,
};
