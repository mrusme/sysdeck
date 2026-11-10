const std = @import("std");
const Translator = @import("translate_c").Translator;

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
    .{ .names = &.{"gdk-pixbuf-2.0"}, .minimum = "2.32" },
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

    const libraries_tool = b.addExecutable(.{
        .name = "libraries",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/libraries.zig"),
            .target = b.graph.host,
        }),
    });

    const check_libraries = b.addRunArtifact(libraries_tool);
    check_libraries.setName("check the system libraries");
    for (system_libraries) |library| {
        const name = present(b, library);
        exe_module.linkSystemLibrary(name, .{});
        check_libraries.addArg(if (library.minimum) |minimum|
            b.fmt("{s} >= {s}", .{ name, minimum })
        else
            name);
    }
    const libraries = &check_libraries.step;

    const resources = b.addSystemCommand(&.{"glib-compile-resources"});
    resources.step.dependOn(libraries);
    resources.addDirectoryArg2(b.path("data"), .{ .prefix = "--sourcedir=" });
    const bundle = resources.addOutputFileArg2("sysdeck.gresource", .{ .prefix = "--target=" });
    _ = resources.addDepFileOutputArg2("sysdeck.gresource.d", .{ .prefix = "--dependency-file=" });
    resources.addFileArg2(b.path("data/sysdeck.gresource.xml"), .{});
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
    run.addPassthruArgs();
    b.step("run", "Build and run sysdeck").dependOn(&run.step);

    const unit_tests = b.addTest(.{ .root_module = exe_module });
    unit_tests.step.dependOn(libraries);
    const run_tests = b.addRunArtifact(unit_tests);

    const core_tests = b.addTest(.{ .root_module = core });
    const run_core_tests = b.addRunArtifact(core_tests);

    const translator: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/wayland/bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{
            .{ .name = "wayland-client" },
        },
    });
    translator.run.step.dependOn(libraries);

    const drift = b.createModule(.{
        .root_source_file = b.path("src/wayland/drift.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    drift.addImport("bindings", translator.mod);

    const drift_tests = b.addTest(.{ .root_module = drift });
    drift_tests.step.dependOn(libraries);
    const run_drift_tests = b.addRunArtifact(drift_tests);

    const tool_tests = b.addTest(.{ .root_module = libraries_tool.root_module });
    const run_tool_tests = b.addRunArtifact(tool_tests);

    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_drift_tests.step);
    test_step.dependOn(&run_tool_tests.step);

    b.step("test-bindings", "Check the bindings against the system headers")
        .dependOn(&run_drift_tests.step);

    b.step("test-core", "Run the tests that need no display").dependOn(&run_core_tests.step);

    emojiStep(b, optimize);
}

fn emojiStep(b: *std.Build, optimize: std.lang.Optimize) void {
    const xml = b.dependency("xml", .{
        .target = b.graph.host,
        .optimize = optimize,
    });

    const tool = b.addExecutable(.{
        .name = "emoji",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/emoji.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    tool.root_module.addImport("xml", xml.module("xml"));

    const step = b.step(
        "emoji",
        "Regenerate src/core/emoji.tsv from emoji-test.txt, the CLDR annotations and their LICENSE",
    );
    const inputs = [_]?std.Build.LazyPath{
        b.option(std.Build.LazyPath, "emoji-test", "Unicode's emoji-test.txt, for the emoji step"),
        b.option(std.Build.LazyPath, "annotations", "CLDR's annotations/en.xml, for the emoji step"),
        b.option(std.Build.LazyPath, "annotations-derived", "CLDR's annotationsDerived/en.xml, for the emoji step"),
        b.option(std.Build.LazyPath, "cldr-license", "CLDR's LICENSE, for the emoji step"),
    };

    const generate = b.addRunArtifact(tool);
    for (inputs) |input| {
        generate.addFileArg2(input orelse {
            step.dependOn(&b.addFail(
                "the emoji step needs -Demoji-test=, -Dannotations=, -Dannotations-derived= and -Dcldr-license=",
            ).step);
            return;
        }, .{});
    }
    const table = generate.addOutputFileArg2("emoji.tsv", .{});

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(table, "src/core/emoji.tsv");
    step.dependOn(&update.step);
}

fn present(b: *std.Build, library: Library) []const u8 {
    if (library.names.len == 1) return library.names[0];

    b.graph.poisonCache();
    const pkg_config = std.zig.PkgConfig.exe(&b.graph.environ_map);
    for (library.names) |name| {
        switch (b.runFallible(&.{ pkg_config, "--exists", name }, .{ .stderr_behavior = .ignore })) {
            .success => return name,
            .spawn_failed, .bad_exit_code, .crashed => {},
        }
    }
    return library.names[0];
}
