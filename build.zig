const std = @import("std");

const manifest = @import("build.zig.zon");

const Library = struct {
    name: []const u8,
    minimum: ?[]const u8 = null,
};

const system_libraries = [_]Library{
    .{ .name = "gtk4", .minimum = "4.10" },
    .{ .name = "gio-2.0", .minimum = "2.66" },
    .{ .name = "gio-unix-2.0", .minimum = "2.66" },
    .{ .name = "gobject-2.0" },
    .{ .name = "glib-2.0" },
    .{ .name = "sqlite3", .minimum = "3.51.2" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    checkSystemLibraries(b);

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

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("toml", toml.module("toml"));
    exe_module.addImport("zqlite", zqlite.module("zqlite"));
    exe_module.addImport("whats", whats.module("whats"));
    exe_module.addImport("osdetect", osdetect.module("osdetect"));
    exe_module.addOptions("build_options", options);
    for (system_libraries) |library| {
        exe_module.linkSystemLibrary(library.name, .{ .use_pkg_config = .force });
    }

    const exe = b.addExecutable(.{
        .name = "sysdeck",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run sysdeck").dependOn(&run.step);

    const unit_tests = b.addTest(.{ .root_module = exe_module });
    const run_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run the unit tests").dependOn(&run_tests.step);
}

fn checkSystemLibraries(b: *std.Build) void {
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";

    for (system_libraries) |library| {
        var code: u8 = undefined;
        _ = b.runAllowFail(&.{ pkg_config, "--exists", library.name }, &code, .ignore) catch {
            std.debug.print(
                \\
                \\sysdeck needs the development files for {s}, which {s} cannot find.
                \\
                \\  Fedora        gtk4-devel glib2-devel sqlite-devel
                \\  Debian        libgtk-4-dev libglib2.0-dev libsqlite3-dev
                \\  Arch          gtk4 glib2 sqlite
                \\  Alpine        gtk4.0-dev glib-dev sqlite-dev
                \\  Gentoo        gui-libs/gtk:4 dev-libs/glib dev-db/sqlite
                \\  Void          gtk4-devel glib-devel sqlite-devel
                \\  FreeBSD       gtk4 glib sqlite3
                \\  OpenBSD       gtk+4 glib2 sqlite3
                \\  NetBSD        gtk4 glib2 sqlite3
                \\
                \\Set PKG_CONFIG if the tool is installed under another name, such as
                \\pkgconf on the BSDs.
                \\
                \\
            , .{ library.name, pkg_config });
            std.process.exit(1);
        };

        const minimum = library.minimum orelse continue;
        _ = b.runAllowFail(
            &.{ pkg_config, "--atleast-version", minimum, library.name },
            &code,
            .ignore,
        ) catch {
            const found = b.runAllowFail(
                &.{ pkg_config, "--modversion", library.name },
                &code,
                .ignore,
            ) catch "";
            std.debug.print(
                \\
                \\sysdeck needs {s} {s} or later, and this system has {s}.
                \\
                \\
            , .{ library.name, minimum, std.mem.trim(u8, found, " \t\r\n") });
            std.process.exit(1);
        };
    }
}
