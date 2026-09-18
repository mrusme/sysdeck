const std = @import("std");
const c = @import("../gtk/c.zig");
const config_mod = @import("../config.zig");
const extensions = @import("../extensions.zig");
const keys_mod = @import("../ui/keys.zig");

const Panes = @This();

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.panes);

gpa: Allocator,
manager: extensions.Manager,
members: std.ArrayList(extensions.Extension) = .empty,

pub fn create(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    settings: *const config_mod.Config,
    resolved: config_mod.Settings,
    bindings: keys_mod.Bindings,
) Allocator.Error!*Panes {
    const self = try gpa.create(Panes);
    errdefer gpa.destroy(self);

    self.* = .{ .gpa = gpa, .manager = .init(gpa, io) };

    if (settings.extensions.man.enable) {
        const made = try extensions.man.Extension.create(gpa, bindings.manual);
        self.append(made.extension(), "man");
    }

    const wanted = settings.extensions.preview;
    if (wanted.enable) {
        const made = try extensions.preview.Extension.create(
            gpa,
            io,
            environ,
            resolved.preview_height,
            resolved.preview_limit,
        );
        self.append(made.extension(), "preview");
    }

    self.manager.members = self.members.items;
    return self;
}

pub fn destroy(self: *Panes) void {
    self.manager.stop();
    self.members.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn attach(self: *Panes, box: *c.GtkBox) void {
    self.manager.attach(box);
}

pub fn select(self: *Panes, target: ?extensions.Target) void {
    self.manager.select(target);
}

pub fn key(self: *Panes, keyval: c.guint, state: c.GdkModifierType) bool {
    return self.manager.key(keyval, state);
}

fn append(self: *Panes, member: extensions.Extension, name: []const u8) void {
    self.members.append(self.gpa, member) catch {
        log.warn("out of memory, so the {s} extension is left out", .{name});
        c.discard(member.widget());
    };
}
