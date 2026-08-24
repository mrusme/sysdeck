const std = @import("std");

pub const dmenu_prompt: [:0]const u8 = "Filter";
pub const default_prompt: [:0]const u8 = "Search";

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
    \\  -p, --prompt TEXT  Set the placeholder shown in the text box
    \\  -l, --lines N      Show at most N rows at once, overriding the config
    \\  -h, --help         Print this help and exit
    \\  -v, --version      Print the version and exit
    \\
    \\Keys:
    \\  Up, Down       Move through the list
    \\  Return         Take the selected entry
    \\  Escape         Close without taking anything, and exit 1
    \\
    \\Example:
    \\  ls | sysdeck --dmenu | xargs -I {} echo "I selected {}"
    \\
    \\Configuration is read from $XDG_CONFIG_HOME/sysdeck/config.toml, or
    \\$HOME/.config/sysdeck/config.toml when XDG_CONFIG_HOME is unset.
;

pub const Mode = enum { default, dmenu };

pub const Options = struct {
    mode: Mode,
    prompt: [:0]const u8,
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
        }
    }
};

pub fn parse(arguments: []const [:0]const u8, rows: u16, failure: *Failure) Error!Action {
    var mode: Mode = .default;
    var prompt: ?[:0]const u8 = null;
    var lines: u16 = rows;

    var at: usize = 0;
    while (at < arguments.len) : (at += 1) {
        const argument = arguments[at];
        failure.* = .{ .reason = error.UnknownOption, .argument = argument };

        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) return .help;
        if (std.mem.eql(u8, argument, "-v") or std.mem.eql(u8, argument, "--version")) return .version;

        if (std.mem.eql(u8, argument, "--dmenu")) {
            mode = .dmenu;
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

    return .{ .run = .{
        .mode = mode,
        .prompt = prompt orelse switch (mode) {
            .default => default_prompt,
            .dmenu => dmenu_prompt,
        },
        .lines = lines,
    } };
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

test "the failure carries the argument that was wrong" {
    var failure: Failure = undefined;
    try testing.expectError(error.UnknownOption, parse(&.{ "--dmenu", "--wat" }, test_lines, &failure));
    try testing.expectEqualStrings("--wat", failure.argument);

    try testing.expectError(error.BadLineCount, parse(&.{ "--dmenu", "-l", "many" }, test_lines, &failure));
    try testing.expectEqualStrings("many", failure.argument);
}
