const std = @import("std");
const modes = @import("modes.zig");

pub const dmenu_prompt: [:0]const u8 = "Filter";
pub const default_prompt: [:0]const u8 = "Search";

pub const usage =
    \\Usage: sysdeck [options]
    \\
    \\A popup that works out what you want from what you type. Without a mode
    \\it searches applications, executables, files, bookmarks, the clipboard
    \\history and more, and acts on the entry you pick. With --dmenu the list
    \\is read from standard input, one item per line, and the item you pick is
    \\printed to standard output.
    \\
    \\Options:
    \\      --dmenu        Read lines from standard input and print the picked one
    \\      --clipboard-capture
    \\                     Store standard input in the clipboard history and exit
    \\      --clipboard-clear
    \\                     Remove every entry from the clipboard history and exit
    \\      --clipboard-drop
    \\                     Delete the newest history entry if the clipboard holds
    \\                     it, empty the clipboard and exit
    \\      --clipboard-history
    \\                     Open on the clipboard history rather than the search
    \\      --llm          Open on the LLM prompt rather than the search
    \\      --disk         Open on the disk browser rather than the search
    \\      --whats        Open on the whats prompt rather than the search
    \\      --nm           Open on the NetworkManager devices and connections
    \\      --sway         Open on the Sway windows rather than the search
    \\      --phonebook    Open on the contacts rather than the search
    \\      --containers   Open on the Podman containers rather than the search
    \\      --recommendations
    \\                     Show what you pick most often while the text box is empty
    \\  -p, --prompt TEXT  Set the placeholder shown in the text box
    \\  -l, --lines N      Show at most N rows at once, overriding the config
    \\  -h, --help         Print this help and exit
    \\  -v, --version      Print the version and exit
    \\
    \\Keys:
    \\  Up, Down       Move through the list
    \\  Return         Take the selected entry
    \\  Ctrl+T         Show the open Sway windows
    \\  Ctrl+H         Show the clipboard history
    \\  Ctrl+D         Browse the configured disk locations
    \\  Ctrl+W         Calculate and convert what you type
    \\  Ctrl+K         Connect or disconnect a network device or connection
    \\  Ctrl+P         Look up the contacts that Inca synchronized
    \\  Ctrl+0         Start or stop a Podman container
    \\  Ctrl+L         Ask a configured LLM, again to step to the next provider
    \\  Ctrl+N         Start a new conversation
    \\  Ctrl+F         Go back to the search
    \\  Escape         Close without taking anything, and exit 1
    \\
    \\Examples:
    \\  ls | sysdeck --dmenu | xargs -I {} echo "I selected {}"
    \\
    \\  Keep a clipboard history on Sway, in ~/.config/sway/config:
    \\  exec wl-paste --watch sysdeck --clipboard-capture > /dev/null
    \\
    \\Configuration is read from $XDG_CONFIG_HOME/sysdeck/config.toml, or
    \\$HOME/.config/sysdeck/config.toml when XDG_CONFIG_HOME is unset.
;

pub const Mode = enum { default, dmenu, clipboard, clipboard_clear, clipboard_drop };

pub const Options = struct {
    mode: Mode,
    start: modes.Mode = .search,
    prompt: [:0]const u8,
    prompt_given: bool = false,
    lines: ?u16 = null,
    recommendations: bool = false,
};

pub const Action = union(enum) {
    run: Options,
    help,
    version,
};

pub const Error = error{
    UnknownOption,
    MissingValue,
    BadLineCount,
    ConflictingModes,
};

pub const Failure = struct {
    reason: Error,
    argument: []const u8,

    pub fn format(self: Failure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.reason) {
            error.UnknownOption => try writer.print("unknown option \"{s}\"", .{self.argument}),
            error.MissingValue => try writer.print("{s} needs a value", .{self.argument}),
            error.BadLineCount => try writer.print(
                "cannot read \"{s}\" as a row count of 1 or more",
                .{self.argument},
            ),
            error.ConflictingModes => try writer.print(
                "{s} cannot be combined with another mode",
                .{self.argument},
            ),
        }
    }
};

pub fn parse(arguments: []const [:0]const u8, failure: *Failure) Error!Action {
    var mode: ?Mode = null;
    var start: modes.Mode = .search;
    var prompt: ?[:0]const u8 = null;
    var lines: ?u16 = null;
    var recommendations = false;

    var at: usize = 0;
    while (at < arguments.len) : (at += 1) {
        const argument = arguments[at];
        failure.* = .{ .reason = error.UnknownOption, .argument = argument };

        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) return .help;
        if (std.mem.eql(u8, argument, "-v") or std.mem.eql(u8, argument, "--version")) return .version;

        if (std.mem.eql(u8, argument, "--dmenu")) {
            try take(&mode, .dmenu, failure);
            continue;
        }

        if (std.mem.eql(u8, argument, "--clipboard-capture")) {
            try take(&mode, .clipboard, failure);
            continue;
        }

        if (std.mem.eql(u8, argument, "--clipboard-clear")) {
            try take(&mode, .clipboard_clear, failure);
            continue;
        }

        if (std.mem.eql(u8, argument, "--clipboard-drop")) {
            try take(&mode, .clipboard_drop, failure);
            continue;
        }

        if (std.mem.eql(u8, argument, "--llm")) {
            try take(&mode, .default, failure);
            start = .llm;
            continue;
        }

        if (std.mem.eql(u8, argument, "--disk")) {
            try take(&mode, .default, failure);
            start = .disk;
            continue;
        }

        if (std.mem.eql(u8, argument, "--nm")) {
            try take(&mode, .default, failure);
            start = .nm;
            continue;
        }

        if (std.mem.eql(u8, argument, "--sway")) {
            try take(&mode, .default, failure);
            start = .windows;
            continue;
        }

        if (std.mem.eql(u8, argument, "--phonebook")) {
            try take(&mode, .default, failure);
            start = .phonebook;
            continue;
        }

        if (std.mem.eql(u8, argument, "--containers")) {
            try take(&mode, .default, failure);
            start = .containers;
            continue;
        }

        if (std.mem.eql(u8, argument, "--whats")) {
            try take(&mode, .default, failure);
            start = .whats;
            continue;
        }

        if (std.mem.eql(u8, argument, "--clipboard-history")) {
            try take(&mode, .default, failure);
            start = .history;
            continue;
        }

        if (std.mem.eql(u8, argument, "--recommendations")) {
            try take(&mode, .default, failure);
            recommendations = true;
            continue;
        }

        if (std.mem.eql(u8, argument, "-p") or std.mem.eql(u8, argument, "--prompt")) {
            failure.reason = error.MissingValue;
            at += 1;
            if (at == arguments.len) return error.MissingValue;
            prompt = arguments[at];
            continue;
        }

        if (std.mem.eql(u8, argument, "-l") or std.mem.eql(u8, argument, "--lines")) {
            failure.reason = error.MissingValue;
            at += 1;
            if (at == arguments.len) return error.MissingValue;
            failure.* = .{ .reason = error.BadLineCount, .argument = arguments[at] };
            const wanted = std.fmt.parseInt(u16, arguments[at], 10) catch return error.BadLineCount;
            if (wanted == 0) return error.BadLineCount;
            lines = wanted;
            continue;
        }

        return error.UnknownOption;
    }

    const wanted = mode orelse .default;
    return .{ .run = .{
        .mode = wanted,
        .start = start,
        .prompt = prompt orelse switch (wanted) {
            .default, .clipboard, .clipboard_clear, .clipboard_drop => default_prompt,
            .dmenu => dmenu_prompt,
        },
        .prompt_given = prompt != null,
        .lines = lines,
        .recommendations = recommendations,
    } };
}

fn take(mode: *?Mode, wanted: Mode, failure: *Failure) Error!void {
    const current = mode.* orelse {
        mode.* = wanted;
        return;
    };
    if (current == wanted) return;

    failure.reason = error.ConflictingModes;
    return error.ConflictingModes;
}

const testing = std.testing;

fn run(arguments: []const [:0]const u8) !Options {
    var failure: Failure = undefined;
    return switch (try parse(arguments, &failure)) {
        .run => |options| options,
        else => error.TestUnexpectedAction,
    };
}

test "no arguments give the default mode" {
    const options = try run(&.{});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(null, options.lines);
    try testing.expectEqualStrings(default_prompt, options.prompt);
}

test "--dmenu alone gives the dmenu defaults" {
    const options = try run(&.{"--dmenu"});

    try testing.expectEqual(Mode.dmenu, options.mode);
    try testing.expectEqual(null, options.lines);
    try testing.expectEqualStrings(dmenu_prompt, options.prompt);
}

test "the prompt and the row count are taken from the next argument" {
    const options = try run(&.{ "--dmenu", "-p", "Pick a file", "-l", "20" });

    try testing.expectEqualStrings("Pick a file", options.prompt);
    try testing.expectEqual(20, options.lines);
}

test "the long spellings work the same" {
    const options = try run(&.{ "--prompt", "Open", "--lines", "5", "--dmenu" });

    try testing.expectEqualStrings("Open", options.prompt);
    try testing.expectEqual(5, options.lines);
}

test "options without a mode configure the default mode" {
    const options = try run(&.{ "-p", "Go", "-l", "8" });

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqualStrings("Go", options.prompt);
    try testing.expectEqual(8, options.lines);
}

test "help and version win over everything else" {
    var failure: Failure = undefined;

    try testing.expectEqual(Action.help, try parse(&.{ "--dmenu", "-h" }, &failure));
    try testing.expectEqual(Action.version, try parse(&.{"--version"}, &failure));
    try testing.expectEqual(Action.help, try parse(&.{ "--help", "--nonsense" }, &failure));
}

test "options that make no sense are rejected" {
    var failure: Failure = undefined;

    try testing.expectError(error.UnknownOption, parse(&.{ "--dmenu", "--wat" }, &failure));
    try testing.expectError(error.UnknownOption, parse(&.{"list.txt"}, &failure));
    try testing.expectError(error.MissingValue, parse(&.{"-p"}, &failure));
    try testing.expectError(error.MissingValue, parse(&.{ "--dmenu", "-p" }, &failure));
    try testing.expectError(error.MissingValue, parse(&.{ "--dmenu", "--lines" }, &failure));
    try testing.expectError(error.BadLineCount, parse(&.{ "--dmenu", "-l", "0" }, &failure));
    try testing.expectError(error.BadLineCount, parse(&.{ "--dmenu", "-l", "many" }, &failure));
    try testing.expectError(error.BadLineCount, parse(&.{ "--dmenu", "-l", "-3" }, &failure));
}

test "--clipboard-capture is a mode of its own" {
    const options = try run(&.{"--clipboard-capture"});

    try testing.expectEqual(Mode.clipboard, options.mode);
    try testing.expectEqual(modes.Mode.search, options.start);
}

test "--clipboard-history opens the default mode on the history" {
    const options = try run(&.{"--clipboard-history"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(modes.Mode.history, options.start);
    try testing.expectEqualStrings(default_prompt, options.prompt);
}

test "the history flag still takes the other options" {
    const options = try run(&.{ "--clipboard-history", "-l", "12", "-p", "Paste" });

    try testing.expectEqual(modes.Mode.history, options.start);
    try testing.expectEqual(12, options.lines);
    try testing.expectEqualStrings("Paste", options.prompt);
}

test "--clipboard-clear is a mode of its own" {
    const options = try run(&.{"--clipboard-clear"});

    try testing.expectEqual(Mode.clipboard_clear, options.mode);
    try testing.expectEqual(modes.Mode.search, options.start);
}

test "clearing cannot be combined with capturing or with a window" {
    var failure: Failure = undefined;

    for ([_][]const [:0]const u8{
        &.{ "--clipboard-clear", "--clipboard-capture" },
        &.{ "--clipboard-capture", "--clipboard-clear" },
        &.{ "--clipboard-clear", "--clipboard-history" },
        &.{ "--clipboard-clear", "--dmenu" },
        &.{ "--dmenu", "--clipboard-clear" },
    }) |arguments| {
        try testing.expectError(
            error.ConflictingModes,
            parse(arguments, &failure),
        );
    }

    const twice = try run(&.{ "--clipboard-clear", "--clipboard-clear" });
    try testing.expectEqual(Mode.clipboard_clear, twice.mode);
}

test "--clipboard-drop is a mode of its own and combines with no other" {
    const options = try run(&.{"--clipboard-drop"});
    try testing.expectEqual(Mode.clipboard_drop, options.mode);

    var failure: Failure = undefined;
    for ([_][]const [:0]const u8{
        &.{ "--clipboard-drop", "--clipboard-clear" },
        &.{ "--clipboard-capture", "--clipboard-drop" },
        &.{ "--clipboard-drop", "--clipboard-history" },
        &.{ "--dmenu", "--clipboard-drop" },
    }) |arguments| {
        try testing.expectError(error.ConflictingModes, parse(arguments, &failure));
    }
}

test "two modes at once are rejected" {
    var failure: Failure = undefined;

    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--dmenu", "--clipboard-capture" }, &failure),
    );
    try testing.expectEqualStrings("--clipboard-capture", failure.argument);

    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--clipboard-capture", "--dmenu" }, &failure),
    );
    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--clipboard-capture", "--clipboard-history" }, &failure),
    );
    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--dmenu", "--clipboard-history" }, &failure),
    );
}

test "the same mode twice is not a conflict" {
    const options = try run(&.{ "--clipboard-capture", "--clipboard-capture" });
    try testing.expectEqual(Mode.clipboard, options.mode);

    const dmenu = try run(&.{ "--dmenu", "--dmenu" });
    try testing.expectEqual(Mode.dmenu, dmenu.mode);
}

test "the failure carries the argument that was wrong" {
    var failure: Failure = undefined;
    try testing.expectError(error.UnknownOption, parse(&.{ "--dmenu", "--wat" }, &failure));
    try testing.expectEqualStrings("--wat", failure.argument);

    try testing.expectError(error.BadLineCount, parse(&.{ "--dmenu", "-l", "many" }, &failure));
    try testing.expectEqualStrings("many", failure.argument);
}

test "--llm starts on the LLM prompt and leaves the placeholder to the session" {
    const options = try run(&.{"--llm"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(modes.Mode.llm, options.start);
    try testing.expectEqualStrings(default_prompt, options.prompt);
    try testing.expect(!options.prompt_given);
}

test "an explicit prompt is remembered so the LLM mode leaves it alone" {
    const options = try run(&.{ "--llm", "-p", "Question" });

    try testing.expectEqualStrings("Question", options.prompt);
    try testing.expect(options.prompt_given);
}

test "--llm cannot be combined with --dmenu" {
    var failure: Failure = undefined;
    try testing.expectError(error.ConflictingModes, parse(&.{ "--dmenu", "--llm" }, &failure));
}

test "--disk opens the default mode on the disk browser" {
    const options = try run(&.{"--disk"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(modes.Mode.disk, options.start);
    try testing.expectEqualStrings(default_prompt, options.prompt);
    try testing.expect(!options.prompt_given);

    const sized = try run(&.{ "--disk", "-l", "12", "-p", "Pick" });
    try testing.expectEqual(modes.Mode.disk, sized.start);
    try testing.expectEqual(12, sized.lines);
    try testing.expectEqualStrings("Pick", sized.prompt);
    try testing.expect(sized.prompt_given);
}

test "--disk cannot be combined with another mode" {
    var failure: Failure = undefined;

    for ([_][]const [:0]const u8{
        &.{ "--dmenu", "--disk" },
        &.{ "--disk", "--dmenu" },
        &.{ "--disk", "--clipboard-capture" },
        &.{ "--clipboard-clear", "--disk" },
    }) |arguments| {
        try testing.expectError(error.ConflictingModes, parse(arguments, &failure));
    }

    const both = try run(&.{ "--llm", "--disk" });
    try testing.expectEqual(modes.Mode.disk, both.start);
}

test "--whats opens the default mode on the whats prompt" {
    const options = try run(&.{"--whats"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(modes.Mode.whats, options.start);
    try testing.expectEqualStrings(default_prompt, options.prompt);
    try testing.expect(!options.prompt_given);

    const sized = try run(&.{ "--whats", "-l", "3", "-p", "Sum" });
    try testing.expectEqual(modes.Mode.whats, sized.start);
    try testing.expectEqual(3, sized.lines);
    try testing.expectEqualStrings("Sum", sized.prompt);
    try testing.expect(sized.prompt_given);

    const picking = try run(&.{ "--whats", "--recommendations" });
    try testing.expectEqual(modes.Mode.whats, picking.start);
    try testing.expect(picking.recommendations);

    try testing.expectEqual(modes.Mode.disk, (try run(&.{ "--whats", "--disk" })).start);
    try testing.expectEqual(modes.Mode.whats, (try run(&.{ "--disk", "--whats" })).start);
}

test "--whats cannot be combined with a mode that has no search" {
    var failure: Failure = undefined;

    for ([_][]const [:0]const u8{
        &.{ "--whats", "--dmenu" },
        &.{ "--dmenu", "--whats" },
        &.{ "--whats", "--clipboard-capture" },
        &.{ "--clipboard-capture", "--whats" },
        &.{ "--whats", "--clipboard-clear" },
        &.{ "--clipboard-clear", "--whats" },
    }) |arguments| {
        try testing.expectError(error.ConflictingModes, parse(arguments, &failure));
        try testing.expectEqualStrings(arguments[1], failure.argument);
    }
}

test "--recommendations opens the default mode on the search" {
    const options = try run(&.{"--recommendations"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(modes.Mode.search, options.start);
    try testing.expect(options.recommendations);
    try testing.expect(!(try run(&.{})).recommendations);

    const sized = try run(&.{ "--recommendations", "-l", "12", "-p", "Go" });
    try testing.expect(sized.recommendations);
    try testing.expectEqual(12, sized.lines);
    try testing.expectEqualStrings("Go", sized.prompt);
}

test "--recommendations keeps the place another flag opens on" {
    const asking = try run(&.{ "--llm", "--recommendations" });
    try testing.expectEqual(modes.Mode.llm, asking.start);
    try testing.expect(asking.recommendations);

    const browsing = try run(&.{ "--recommendations", "--disk" });
    try testing.expectEqual(modes.Mode.disk, browsing.start);
    try testing.expect(browsing.recommendations);

    const pasting = try run(&.{ "--clipboard-history", "--recommendations" });
    try testing.expectEqual(modes.Mode.history, pasting.start);
    try testing.expect(pasting.recommendations);
}

test "--recommendations cannot be combined with a mode that has no search" {
    var failure: Failure = undefined;

    for ([_][]const [:0]const u8{
        &.{ "--recommendations", "--dmenu" },
        &.{ "--dmenu", "--recommendations" },
        &.{ "--recommendations", "--clipboard-capture" },
        &.{ "--clipboard-capture", "--recommendations" },
        &.{ "--recommendations", "--clipboard-clear" },
        &.{ "--clipboard-clear", "--recommendations" },
    }) |arguments| {
        try testing.expectError(error.ConflictingModes, parse(arguments, &failure));
        try testing.expectEqualStrings(arguments[1], failure.argument);
    }
}

test "--nm opens the default mode on the network list" {
    const options = try run(&.{"--nm"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(modes.Mode.nm, options.start);
}

test "--nm cannot be combined with another mode" {
    var failure: Failure = undefined;
    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--nm", "--dmenu" }, &failure),
    );
}

test "--sway opens the default mode on the Sway windows" {
    const options = try run(&.{"--sway"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(modes.Mode.windows, options.start);
}

test "--sway cannot be combined with another mode" {
    var failure: Failure = undefined;
    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--sway", "--dmenu" }, &failure),
    );
}

test "--phonebook opens the default mode on the contacts" {
    const options = try run(&.{"--phonebook"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(modes.Mode.phonebook, options.start);
    try testing.expectEqualStrings(default_prompt, options.prompt);
    try testing.expect(!options.prompt_given);

    const sized = try run(&.{ "--phonebook", "-l", "12", "-p", "Who" });
    try testing.expectEqual(modes.Mode.phonebook, sized.start);
    try testing.expectEqual(12, sized.lines);
    try testing.expectEqualStrings("Who", sized.prompt);
    try testing.expect(sized.prompt_given);

    try testing.expectEqual(modes.Mode.disk, (try run(&.{ "--phonebook", "--disk" })).start);
    try testing.expectEqual(modes.Mode.phonebook, (try run(&.{ "--disk", "--phonebook" })).start);
}

test "--phonebook cannot be combined with a mode that has no search" {
    var failure: Failure = undefined;

    for ([_][]const [:0]const u8{
        &.{ "--phonebook", "--dmenu" },
        &.{ "--dmenu", "--phonebook" },
        &.{ "--phonebook", "--clipboard-capture" },
        &.{ "--clipboard-clear", "--phonebook" },
    }) |arguments| {
        try testing.expectError(error.ConflictingModes, parse(arguments, &failure));
        try testing.expectEqualStrings(arguments[1], failure.argument);
    }
}

test "--containers opens the default mode on the containers" {
    const options = try run(&.{"--containers"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(modes.Mode.containers, options.start);
    try testing.expectEqualStrings(default_prompt, options.prompt);
    try testing.expect(!options.prompt_given);

    const sized = try run(&.{ "--containers", "-l", "12", "-p", "Which" });
    try testing.expectEqual(modes.Mode.containers, sized.start);
    try testing.expectEqual(12, sized.lines);
    try testing.expectEqualStrings("Which", sized.prompt);
    try testing.expect(sized.prompt_given);

    try testing.expectEqual(modes.Mode.phonebook, (try run(&.{ "--containers", "--phonebook" })).start);
    try testing.expectEqual(modes.Mode.containers, (try run(&.{ "--phonebook", "--containers" })).start);
}

test "--containers cannot be combined with a mode that has no search" {
    var failure: Failure = undefined;

    for ([_][]const [:0]const u8{
        &.{ "--containers", "--dmenu" },
        &.{ "--dmenu", "--containers" },
        &.{ "--containers", "--clipboard-capture" },
        &.{ "--clipboard-clear", "--containers" },
    }) |arguments| {
        try testing.expectError(error.ConflictingModes, parse(arguments, &failure));
        try testing.expectEqualStrings(arguments[1], failure.argument);
    }
}
