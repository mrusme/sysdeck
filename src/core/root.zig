pub const fuzzy = @import("fuzzy.zig");
pub const input = @import("input.zig");
pub const media = @import("media.zig");
pub const rank = @import("rank.zig");
pub const store = @import("store.zig");
pub const tables = @import("tables.zig");
pub const xdg = @import("xdg.zig");

test {
    _ = fuzzy;
    _ = input;
    _ = media;
    _ = rank;
    _ = store;
    _ = tables;
    _ = xdg;
}
