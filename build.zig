const std = @import("std");

const manifest = @import("build.zig.zon");

const Library = struct {
    names: []const []const u8,
    minimum: ?[]const u8 = null,
};

const system_libraries = [_]Library{
    .{ .names = &.{"gtk4-layer-shell-0"}, .minimum = "1.0" },
    .{ .names = &.{"gtk4"}, .minimum = "4.14" },
    .{ .names = &.{"gio-2.0"}, .minimum = "2.66" },
    .{ .names = &.{"gio-unix-2.0"}, .minimum = "2.66" },
    .{ .names = &.{"gobject-2.0"} },
    .{ .names = &.{"glib-2.0"} },
    .{ .names = &.{"gdk-pixbuf-2.0"}, .minimum = "2.30" },
    .{ .names = &.{"cairo"}, .minimum = "1.14" },
    .{ .names = &.{"sqlite3"}, .minimum = "3.37" },
    .{ .names = &.{ "gexiv2-0.16", "gexiv2-0.14", "gexiv2" }, .minimum = "0.14" },
    .{ .names = &.{"wayland-client"}, .minimum = "1.20" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const toml = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
        .system_sqlite3 = true,
    });

    const whats = b.dependency("whats", .{
        .target = target,
        .optimize = optimize,
    });

    const osdetect = b.dependency("osdetect", .{
        .target = target,
        .optimize = optimize,
    });

    const zenai = b.dependency("zenai", .{
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.addImport("zqlite", zqlite.module("zqlite"));

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("core", core);
    exe_module.addImport("toml", toml.module("toml"));
    exe_module.addImport("zqlite", zqlite.module("zqlite"));
    exe_module.addImport("whats", whats.module("whats"));
    exe_module.addImport("osdetect", osdetect.module("osdetect"));
    exe_module.addImport("zenai", zenai.module("zenai"));
    exe_module.addOptions("build_options", options);
    for (system_libraries) |library| {
        exe_module.linkSystemLibrary(present(b, library), .{ .use_pkg_config = .force });
    }

    const libraries = libraryCheck(b);

    const resources = b.addSystemCommand(&.{"glib-compile-resources"});
    resources.step.dependOn(libraries);
    resources.addPrefixedDirectoryArg("--sourcedir=", b.path("data"));
    const bundle = resources.addPrefixedOutputFileArg("--target=", "sysdeck.gresource");
    _ = resources.addPrefixedDepFileOutputArg("--dependency-file=", "sysdeck.gresource.d");
    resources.addFileArg(b.path("data/sysdeck.gresource.xml"));
    exe_module.addAnonymousImport("resources", .{ .root_source_file = bundle });

    const exe = b.addExecutable(.{
        .name = "sysdeck",
        .root_module = exe_module,
    });
    exe.step.dependOn(libraries);
    b.installArtifact(exe);

    const checked = b.addExecutable(.{
        .name = "sysdeck-check",
        .root_module = exe_module,
    });
    b.step("check", "Type check without installing anything").dependOn(&checked.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run sysdeck").dependOn(&run.step);

    const unit_tests = b.addTest(.{ .root_module = exe_module });
    unit_tests.step.dependOn(libraries);
    const run_tests = b.addRunArtifact(unit_tests);

    const core_tests = b.addTest(.{ .root_module = core });
    const run_core_tests = b.addRunArtifact(core_tests);

    const translated = b.addTranslateC(.{
        .root_source_file = b.path("src/wayland/bindings.h"),
        .target = target,
        .optimize = optimize,
    });
    translated.linkSystemLibrary("wayland-client", .{ .use_pkg_config = .force });

    const drift = b.createModule(.{
        .root_source_file = b.path("src/wayland/drift.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    drift.addImport("bindings", translated.createModule());

    const drift_tests = b.addTest(.{ .root_module = drift });
    drift_tests.step.dependOn(libraries);
    const run_drift_tests = b.addRunArtifact(drift_tests);

    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_drift_tests.step);

    b.step("test-bindings", "Check the bindings against the system headers")
        .dependOn(&run_drift_tests.step);

    b.step("test-core", "Run the tests that need no display").dependOn(&run_core_tests.step);

    const xml = b.dependency("xml", .{
        .target = b.graph.host,
        .optimize = optimize,
    });

    const emoji_tool = b.addExecutable(.{
        .name = "emoji",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/emoji.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    emoji_tool.root_module.addImport("xml", xml.module("xml"));

    const generate = b.addRunArtifact(emoji_tool);
    if (b.args) |args| {
        for (args) |arg| generate.addFileArg(.{ .cwd_relative = arg });
    }
    const table = generate.addOutputFileArg("emoji.tsv");

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(table, "src/core/emoji.tsv");
    b.step(
        "emoji",
        "Regenerate src/core/emoji.tsv from emoji-test.txt, the CLDR annotations and their LICENSE",
    ).dependOn(&update.step);
}

fn libraryCheck(b: *std.Build) *std.Build.Step {
    const step = b.allocator.create(std.Build.Step) catch @panic("out of memory");
    step.* = .init(.{
        .id = .custom,
        .name = "check the system libraries",
        .owner = b,
        .makeFn = makeLibraryCheck,
    });
    return step;
}

fn makeLibraryCheck(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    return checkSystemLibraries(step);
}

fn exists(b: *std.Build, name: []const u8) bool {
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";

    var code: u8 = undefined;
    _ = b.runAllowFail(&.{ pkg_config, "--exists", name }, &code, .ignore) catch return false;
    return true;
}

fn present(b: *std.Build, library: Library) []const u8 {
    if (library.names.len == 1) return library.names[0];

    for (library.names) |name| {
        if (exists(b, name)) return name;
    }
    return library.names[0];
}

fn checkSystemLibraries(step: *std.Build.Step) !void {
    const b = step.owner;
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";

    for (system_libraries) |library| {
        var code: u8 = undefined;
        const library_name = present(b, library);
        _ = b.runAllowFail(&.{ pkg_config, "--exists", library_name }, &code, .ignore) catch {
            return step.fail(
                \\sysdeck needs the development files for {s}, which {s} cannot find.
                \\
                \\  Fedora        gtk4-devel glib2-devel sqlite-devel libgexiv2-devel
                \\                cairo-devel wayland-devel gtk4-layer-shell-devel
                \\  Debian        libgtk-4-dev libglib2.0-dev libsqlite3-dev libgexiv2-dev
                \\                libcairo2-dev libwayland-dev libgtk4-layer-shell-dev
                \\  Arch          gtk4 glib2 sqlite libgexiv2 cairo wayland gtk4-layer-shell
                \\  Alpine        gtk4.0-dev glib-dev sqlite-dev gexiv2-dev cairo-dev
                \\                wayland-dev gtk4-layer-shell-dev
                \\  Gentoo        gui-libs/gtk:4 dev-libs/glib dev-db/sqlite media-libs/gexiv2
                \\                x11-libs/cairo dev-libs/wayland gui-libs/gtk4-layer-shell
                \\  Void          gtk4-devel glib-devel sqlite-devel gexiv2-devel cairo-devel
                \\                wayland-devel gtk4-layer-shell-devel
                \\  FreeBSD       gtk4 glib sqlite3 gexiv2 cairo wayland gtk4-layer-shell
                \\  OpenBSD       gtk+4 glib2 sqlite3 gexiv2 cairo wayland gtk4-layer-shell
                \\  NetBSD        gtk4 glib2 sqlite3 gexiv2 cairo wayland gtk4-layer-shell
                \\
                \\Set PKG_CONFIG if the tool is installed under another name, such as
                \\pkgconf on the BSDs.
            , .{ library_name, pkg_config });
        };

        const minimum = library.minimum orelse continue;
        _ = b.runAllowFail(
            &.{ pkg_config, "--atleast-version", minimum, library_name },
            &code,
            .ignore,
        ) catch {
            const found = b.runAllowFail(
                &.{ pkg_config, "--modversion", library_name },
                &code,
                .ignore,
            ) catch "";
            return step.fail("sysdeck needs {s} {s} or later, and this system has {s}", .{
                library_name,
                minimum,
                std.mem.trim(u8, found, " \t\r\n"),
            });
        };
    }
}
