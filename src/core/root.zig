pub const clock = @import("clock.zig");
pub const counts = @import("counts.zig");
pub const emoji = @import("emoji.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const glob = @import("glob.zig");
pub const input = @import("input.zig");
pub const media = @import("media.zig");
pub const rank = @import("rank.zig");
pub const ssh = @import("ssh.zig");
pub const store = @import("store.zig");
pub const tables = @import("tables.zig");
pub const xdg = @import("xdg.zig");

test {
    _ = clock;
    _ = counts;
    _ = emoji;
    _ = fuzzy;
    _ = glob;
    _ = input;
    _ = media;
    _ = rank;
    _ = ssh;
    _ = store;
    _ = tables;
    _ = xdg;
}
