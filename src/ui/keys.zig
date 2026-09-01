const std = @import("std");
const c = @import("../gtk/c.zig");
const gdk = @import("../gtk/gdk.zig");
const config = @import("../config.zig");

const log = std.log.scoped(.keys);

const max_key_name = 32;

pub const Family = enum { digits, function };

pub const Numbered = struct {
    modifiers: c.GdkModifierType,
    family: Family,

    pub fn numberOf(self: Numbered, keyval: c.guint, state: c.GdkModifierType) ?u8 {
        if (state & c.modifier_mask != self.modifiers) return null;
        return switch (self.family) {
            .digits => c.digitOf(keyval),
            .function => c.functionOf(keyval),
        };
    }
};

pub const Single = struct {
    modifiers: c.GdkModifierType,
    keyval: c.guint,

    pub fn matches(self: Single, keyval: c.guint, state: c.GdkModifierType) bool {
        return keyval == self.keyval and state & c.modifier_mask == self.modifiers;
    }
};

pub const Held = struct {
    left: c.guint,
    right: c.guint,

    pub fn matches(self: Held, keyval: c.guint) bool {
        return keyval == self.left or keyval == self.right;
    }
};

pub const Bindings = struct {
    manual: Numbered = .{ .modifiers = c.modifier_alt, .family = .function },
    context: Held = .{ .left = c.key_Alt_L, .right = c.key_Alt_R },
    windows: Single = .{ .modifiers = c.modifier_control, .keyval = c.key_t },
    search: Single = .{ .modifiers = c.modifier_control, .keyval = c.key_f },
    history: Single = .{ .modifiers = c.modifier_control, .keyval = c.key_h },
    llm: Single = .{ .modifiers = c.modifier_control, .keyval = c.key_l },
    reset: Single = .{ .modifiers = c.modifier_control, .keyval = c.key_n },

    pub fn from(settings: *const config.Config.Keys) Bindings {
        var wanted: Bindings = .{};
        if (numbered(settings.manual, "keys.manual")) |found| wanted.manual = found;
        if (held(settings.context, "keys.context")) |found| wanted.context = found;
        if (single(settings.windows, "keys.windows")) |found| wanted.windows = found;
        if (single(settings.search, "keys.search")) |found| wanted.search = found;
        if (single(settings.history, "keys.history")) |found| wanted.history = found;
        if (single(settings.llm, "keys.llm")) |found| wanted.llm = found;
        if (single(settings.reset, "keys.reset")) |found| wanted.reset = found;
        return wanted;
    }
};

const Key = union(enum) {
    none,
    numbered: Family,
    keyval: c.guint,
};

const Binding = struct {
    modifiers: c.GdkModifierType,
    key: Key,
};

fn numbered(text: []const u8, name: []const u8) ?Numbered {
    const found = parse(text, name) orelse return null;

    const family = switch (found.key) {
        .numbered => |wanted| wanted,
        else => {
            log.warn("{s} = \"{s}\" has no {{n}} in it, using the built-in default", .{ name, text });
            return null;
        },
    };

    if (family == .digits and found.modifiers & c.modifier_shift != 0) {
        log.warn(
            "{s} = \"{s}\" cannot use Shift with {{n}}, because the keymap gives a symbol " ++
                "rather than a number, using the built-in default",
            .{ name, text },
        );
        return null;
    }

    if (family == .digits and found.modifiers == 0) {
        log.warn(
            "{s} = \"{s}\" needs a modifier, because {{n}} on its own takes the numbers " ++
                "away from the text box, using the built-in default",
            .{ name, text },
        );
        return null;
    }

    return .{ .modifiers = found.modifiers, .family = family };
}

fn single(text: []const u8, name: []const u8) ?Single {
    const found = parse(text, name) orelse return null;

    return switch (found.key) {
        .keyval => |wanted| .{ .modifiers = found.modifiers, .keyval = wanted },
        else => {
            log.warn("{s} = \"{s}\" names no key, using the built-in default", .{ name, text });
            return null;
        },
    };
}

fn held(text: []const u8, name: []const u8) ?Held {
    const found = parse(text, name) orelse return null;

    if (found.key != .none) {
        log.warn("{s} = \"{s}\" is held, so it takes a modifier on its own, using the built-in default", .{ name, text });
        return null;
    }

    return switch (found.modifiers) {
        c.modifier_shift => .{ .left = c.key_Shift_L, .right = c.key_Shift_R },
        c.modifier_control => .{ .left = c.key_Control_L, .right = c.key_Control_R },
        c.modifier_alt => .{ .left = c.key_Alt_L, .right = c.key_Alt_R },
        c.modifier_super => .{ .left = c.key_Super_L, .right = c.key_Super_R },
        else => {
            log.warn("{s} = \"{s}\" takes exactly one modifier, using the built-in default", .{ name, text });
            return null;
        },
    };
}

fn parse(text: []const u8, name: []const u8) ?Binding {
    var modifiers: c.GdkModifierType = 0;
    var key: Key = .none;

    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (token.len == 0) {
            log.warn("{s} = \"{s}\" is not a key binding, using the built-in default", .{ name, text });
            return null;
        }

        if (modifierOf(token)) |bit| {
            if (key != .none) {
                log.warn("{s} = \"{s}\" puts a modifier after the key, using the built-in default", .{ name, text });
                return null;
            }
            modifiers |= bit;
            continue;
        }

        if (key != .none) {
            log.warn("{s} = \"{s}\" names more than one key, using the built-in default", .{ name, text });
            return null;
        }

        key = keyOf(token) orelse {
            log.warn("{s} = \"{s}\" has no key called {s}, using the built-in default", .{ name, text, token });
            return null;
        };
    }

    return .{ .modifiers = modifiers, .key = key };
}

fn modifierOf(token: []const u8) ?c.GdkModifierType {
    const known = .{
        .{ "shift", c.modifier_shift },
        .{ "ctrl", c.modifier_control },
        .{ "control", c.modifier_control },
        .{ "alt", c.modifier_alt },
        .{ "super", c.modifier_super },
    };

    inline for (known) |entry| {
        if (std.ascii.eqlIgnoreCase(token, entry[0])) return entry[1];
    }
    return null;
}

fn keyOf(token: []const u8) ?Key {
    if (std.mem.eql(u8, token, "{n}")) return .{ .numbered = .digits };
    if (token.len == 4 and std.ascii.toLower(token[0]) == 'f' and std.mem.eql(u8, token[1..], "{n}")) {
        return .{ .numbered = .function };
    }

    var buffer: [max_key_name:0]u8 = undefined;
    if (token.len > buffer.len) return null;

    @memcpy(buffer[0..token.len], token);
    buffer[token.len] = 0;
    if (token.len == 1) buffer[0] = std.ascii.toLower(buffer[0]);

    const keyval = gdk.gdk_keyval_from_name(buffer[0..token.len :0]);
    if (keyval == c.key_void) return null;
    return .{ .keyval = keyval };
}

const testing = std.testing;

test "the built-in bindings are Alt and the function keys" {
    const bindings: Bindings = .from(&.{});

    try testing.expectEqual(Family.function, bindings.manual.family);
    try testing.expectEqual(@as(?u8, 3), bindings.manual.numberOf(c.key_F1 + 2, c.modifier_alt));
    try testing.expect(bindings.context.matches(c.key_Alt_R));
    try testing.expect(bindings.windows.matches(c.key_t, c.modifier_control));
    try testing.expect(bindings.search.matches(c.key_f, c.modifier_control));
    try testing.expect(bindings.history.matches(c.key_h, c.modifier_control));
}

test "a binding is read from the modifiers and the key" {
    const bindings: Bindings = .from(&.{
        .manual = "ctrl+shift+F{n}",
        .context = "Super",
        .windows = "Ctrl+W",
        .search = "Alt+space",
        .history = "Super+v",
    });

    const wanted = c.modifier_control | c.modifier_shift;
    try testing.expectEqual(@as(?u8, 7), bindings.manual.numberOf(c.key_F1 + 6, wanted));
    try testing.expect(bindings.context.matches(c.key_Super_L));
    try testing.expect(bindings.windows.matches(gdk.gdk_keyval_from_name("w"), c.modifier_control));
    try testing.expect(bindings.search.matches(gdk.gdk_keyval_from_name("space"), c.modifier_alt));
    try testing.expect(bindings.history.matches(gdk.gdk_keyval_from_name("v"), c.modifier_super));
}

test "the digits are a family of their own" {
    const bindings: Bindings = .from(&.{ .manual = "Alt+{n}" });

    try testing.expectEqual(Family.digits, bindings.manual.family);
    try testing.expectEqual(@as(?u8, 5), bindings.manual.numberOf(c.key_0 + 5, c.modifier_alt));
    try testing.expectEqual(@as(?u8, 5), bindings.manual.numberOf(c.key_KP_0 + 5, c.modifier_alt));
    try testing.expectEqual(@as(?u8, null), bindings.manual.numberOf(c.key_F1, c.modifier_alt));
}

test "modifiers are matched exactly, and the lock bits are ignored" {
    const bindings: Bindings = .from(&.{});
    const num_lock: c.GdkModifierType = 1 << 4;

    try testing.expectEqual(@as(?u8, 1), bindings.manual.numberOf(c.key_F1, c.modifier_alt | num_lock));
    try testing.expect(bindings.windows.matches(c.key_t, c.modifier_control | num_lock));

    const both = c.modifier_alt | c.modifier_control;
    try testing.expectEqual(@as(?u8, null), bindings.manual.numberOf(c.key_F1, both));
    try testing.expectEqual(@as(?u8, null), bindings.manual.numberOf(c.key_F1, 0));
    try testing.expect(!bindings.windows.matches(c.key_t, both));
}

test "a binding that cannot work keeps the default" {
    const shifted: Bindings = .from(&.{ .manual = "Alt+Shift+{n}" });
    try testing.expectEqual(Family.function, shifted.manual.family);

    const bare: Bindings = .from(&.{ .manual = "{n}" });
    try testing.expectEqual(Family.function, bare.manual.family);

    const unknown: Bindings = .from(&.{ .windows = "Ctrl+nosuchkey" });
    try testing.expect(unknown.windows.matches(c.key_t, c.modifier_control));

    const empty: Bindings = .from(&.{ .search = "Ctrl+" });
    try testing.expect(empty.search.matches(c.key_f, c.modifier_control));

    const numberless: Bindings = .from(&.{ .manual = "Alt+F3" });
    try testing.expectEqual(@as(?u8, 1), numberless.manual.numberOf(c.key_F1, c.modifier_alt));

    const two: Bindings = .from(&.{ .context = "Alt+Super" });
    try testing.expect(two.context.matches(c.key_Alt_L));

    const keyed: Bindings = .from(&.{ .context = "Alt+t" });
    try testing.expect(keyed.context.matches(c.key_Alt_L));
}

test "a held modifier is matched on either side" {
    const bindings: Bindings = .from(&.{ .context = "control" });

    try testing.expect(bindings.context.matches(c.key_Control_L));
    try testing.expect(bindings.context.matches(c.key_Control_R));
    try testing.expect(!bindings.context.matches(c.key_Alt_L));
}

test "the LLM and reset bindings default and can be set" {
    const bare: Bindings = .from(&.{});

    try testing.expect(bare.llm.matches(c.key_l, c.modifier_control));
    try testing.expect(bare.reset.matches(c.key_n, c.modifier_control));
    try testing.expect(!bare.llm.matches(c.key_l, c.modifier_alt));

    const set: Bindings = .from(&.{ .llm = "Ctrl+j", .reset = "Alt+k" });

    try testing.expect(set.llm.matches(gdk.gdk_keyval_from_name("j"), c.modifier_control));
    try testing.expect(set.reset.matches(gdk.gdk_keyval_from_name("k"), c.modifier_alt));
}
