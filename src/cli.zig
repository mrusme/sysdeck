const std = @import("std");

pub const dmenu_prompt: [:0]const u8 = "Filter";
pub const default_prompt: [:0]const u8 = "Search";
pub const ask_prompt: [:0]const u8 = "Ask";
pub const browse_prompt: [:0]const u8 = "Browse";
pub const focus_prompt: [:0]const u8 = "Focus";

pub const usage =
    \\Usage: sysdeck [options]
    \\
    \\A popup that works out what you want from what you type. Without a mode
    \\it searches the applications installed on the system and starts the one
    \\you pick. With --dmenu the list is read from standard input, one item per
    \\line, and the item you pick is printed to standard output.
    \\
    \\Options:
    \\      --dmenu        Read lines from standard input and print the picked one
    \\      --clipboard-capture
    \\                     Store standard input in the clipboard history and exit
    \\      --clipboard-clear
    \\                     Remove every entry from the clipboard history and exit
    \\      --clipboard-history
    \\                     Open on the clipboard history rather than the search
    \\      --llm          Open on the LLM prompt rather than the search
    \\      --disk         Open on the disk browser rather than the search
    \\  -p, --prompt TEXT  Set the placeholder shown in the text box
    \\  -l, --lines N      Show at most N rows at once, overriding the config
    \\  -h, --help         Print this help and exit
    \\  -v, --version      Print the version and exit
    \\
    \\Keys:
    \\  Up, Down       Move through the list
    \\  Return         Take the selected entry
    \\  Ctrl+H         Show the clipboard history
    \\  Ctrl+D         Browse the configured disk locations
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

pub const Mode = enum { default, dmenu, clipboard, clipboard_clear };

pub const Start = enum { search, history, llm, disk };

pub const Options = struct {
    mode: Mode,
    start: Start = .search,
    prompt: [:0]const u8,
    prompt_given: bool = false,
    lines: u16,
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

pub fn parse(arguments: []const [:0]const u8, rows: u16, failure: *Failure) Error!Action {
    var mode: ?Mode = null;
    var start: Start = .search;
    var prompt: ?[:0]const u8 = null;
    var lines: u16 = rows;

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

        if (std.mem.eql(u8, argument, "--clipboard-history")) {
            try take(&mode, .default, failure);
            start = .history;
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
            lines = std.fmt.parseInt(u16, arguments[at], 10) catch return error.BadLineCount;
            if (lines == 0) return error.BadLineCount;
            continue;
        }

        return error.UnknownOption;
    }

    const wanted = mode orelse .default;
    return .{ .run = .{
        .mode = wanted,
        .start = start,
        .prompt = prompt orelse switch (wanted) {
            .default, .clipboard, .clipboard_clear => default_prompt,
            .dmenu => dmenu_prompt,
        },
        .prompt_given = prompt != null,
        .lines = lines,
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

const test_lines: u16 = 8;

fn run(arguments: []const [:0]const u8) !Options {
    var failure: Failure = undefined;
    return switch (try parse(arguments, test_lines, &failure)) {
        .run => |options| options,
        else => error.TestUnexpectedAction,
    };
}

test "no arguments give the default mode" {
    const options = try run(&.{});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(test_lines, options.lines);
    try testing.expectEqualStrings(default_prompt, options.prompt);
}

test "--dmenu alone gives the dmenu defaults" {
    const options = try run(&.{"--dmenu"});

    try testing.expectEqual(Mode.dmenu, options.mode);
    try testing.expectEqual(test_lines, options.lines);
    try testing.expectEqualStrings(dmenu_prompt, options.prompt);
}

test "the prompt and the row count are taken from the next argument" {
    const options = try run(&.{ "--dmenu", "-p", "Pick a file", "-l", "20" });

    try testing.expectEqualStrings("Pick a file", options.prompt);
    try testing.expectEqual(@as(u16, 20), options.lines);
}

test "the long spellings work the same" {
    const options = try run(&.{ "--prompt", "Open", "--lines", "5", "--dmenu" });

    try testing.expectEqualStrings("Open", options.prompt);
    try testing.expectEqual(@as(u16, 5), options.lines);
}

test "options without a mode configure the default mode" {
    const options = try run(&.{ "-p", "Go", "-l", "8" });

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqualStrings("Go", options.prompt);
    try testing.expectEqual(@as(u16, 8), options.lines);
}

test "help and version win over everything else" {
    var failure: Failure = undefined;

    try testing.expectEqual(Action.help, try parse(&.{ "--dmenu", "-h" }, test_lines, &failure));
    try testing.expectEqual(Action.version, try parse(&.{"--version"}, test_lines, &failure));
    try testing.expectEqual(Action.help, try parse(&.{ "--help", "--nonsense" }, test_lines, &failure));
}

test "options that make no sense are rejected" {
    var failure: Failure = undefined;

    try testing.expectError(error.UnknownOption, parse(&.{ "--dmenu", "--wat" }, test_lines, &failure));
    try testing.expectError(error.UnknownOption, parse(&.{"list.txt"}, test_lines, &failure));
    try testing.expectError(error.MissingValue, parse(&.{"-p"}, test_lines, &failure));
    try testing.expectError(error.MissingValue, parse(&.{ "--dmenu", "-p" }, test_lines, &failure));
    try testing.expectError(error.MissingValue, parse(&.{ "--dmenu", "--lines" }, test_lines, &failure));
    try testing.expectError(error.BadLineCount, parse(&.{ "--dmenu", "-l", "0" }, test_lines, &failure));
    try testing.expectError(error.BadLineCount, parse(&.{ "--dmenu", "-l", "many" }, test_lines, &failure));
    try testing.expectError(error.BadLineCount, parse(&.{ "--dmenu", "-l", "-3" }, test_lines, &failure));
}

test "--clipboard-capture is a mode of its own" {
    const options = try run(&.{"--clipboard-capture"});

    try testing.expectEqual(Mode.clipboard, options.mode);
    try testing.expectEqual(Start.search, options.start);
}

test "--clipboard-history opens the default mode on the history" {
    const options = try run(&.{"--clipboard-history"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(Start.history, options.start);
    try testing.expectEqualStrings(default_prompt, options.prompt);
}

test "the history flag still takes the other options" {
    const options = try run(&.{ "--clipboard-history", "-l", "12", "-p", "Paste" });

    try testing.expectEqual(Start.history, options.start);
    try testing.expectEqual(@as(u16, 12), options.lines);
    try testing.expectEqualStrings("Paste", options.prompt);
}

test "--clipboard-clear is a mode of its own" {
    const options = try run(&.{"--clipboard-clear"});

    try testing.expectEqual(Mode.clipboard_clear, options.mode);
    try testing.expectEqual(Start.search, options.start);
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
            parse(arguments, test_lines, &failure),
        );
    }

    const twice = try run(&.{ "--clipboard-clear", "--clipboard-clear" });
    try testing.expectEqual(Mode.clipboard_clear, twice.mode);
}

test "two modes at once are rejected" {
    var failure: Failure = undefined;

    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--dmenu", "--clipboard-capture" }, test_lines, &failure),
    );
    try testing.expectEqualStrings("--clipboard-capture", failure.argument);

    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--clipboard-capture", "--dmenu" }, test_lines, &failure),
    );
    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--clipboard-capture", "--clipboard-history" }, test_lines, &failure),
    );
    try testing.expectError(
        error.ConflictingModes,
        parse(&.{ "--dmenu", "--clipboard-history" }, test_lines, &failure),
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
    try testing.expectError(error.UnknownOption, parse(&.{ "--dmenu", "--wat" }, test_lines, &failure));
    try testing.expectEqualStrings("--wat", failure.argument);

    try testing.expectError(error.BadLineCount, parse(&.{ "--dmenu", "-l", "many" }, test_lines, &failure));
    try testing.expectEqualStrings("many", failure.argument);
}

test "--llm starts on the LLM prompt and leaves the placeholder to the session" {
    const options = try run(&.{"--llm"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(Start.llm, options.start);
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
    try testing.expectError(error.ConflictingModes, parse(&.{ "--dmenu", "--llm" }, 8, &failure));
}

test "--disk opens the default mode on the disk browser" {
    const options = try run(&.{"--disk"});

    try testing.expectEqual(Mode.default, options.mode);
    try testing.expectEqual(Start.disk, options.start);
    try testing.expectEqualStrings(default_prompt, options.prompt);
    try testing.expect(!options.prompt_given);

    const sized = try run(&.{ "--disk", "-l", "12", "-p", "Pick" });
    try testing.expectEqual(Start.disk, sized.start);
    try testing.expectEqual(@as(u16, 12), sized.lines);
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
        try testing.expectError(error.ConflictingModes, parse(arguments, test_lines, &failure));
    }

    const both = try run(&.{ "--llm", "--disk" });
    try testing.expectEqual(Start.disk, both.start);
}
