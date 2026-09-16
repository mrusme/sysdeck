pub const emoji = @import("emoji.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const glob = @import("glob.zig");
pub const input = @import("input.zig");
pub const media = @import("media.zig");
pub const rank = @import("rank.zig");
pub const ssh = @import("ssh.zig");
pub const store = @import("store.zig");
pub const tables = @import("tables.zig");
pub const tally = @import("tally.zig");
pub const xdg = @import("xdg.zig");

test {
    _ = emoji;
    _ = fuzzy;
    _ = glob;
    _ = input;
    _ = media;
    _ = rank;
    _ = ssh;
    _ = store;
    _ = tables;
    _ = tally;
    _ = xdg;
}
