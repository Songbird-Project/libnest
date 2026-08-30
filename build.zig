const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const emit_library = b.option(
        bool,
        "emit-lib",
        "Whether to build dynamic and static library files",
    ) orelse false;
    const test_filters = b.option(
        [][]const u8,
        "test",
        "Test to run",
    ) orelse &.{};
    const skip_tests = b.option(
        bool,
        "skip-tests",
        "Skip testing and just build",
    ) orelse false;
    const name = b.option(
        []const u8,
        "name",
        "The name of the frontend",
    ) orelse "libnest";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "name", name);

    const archive_c = b.addTranslateC(.{
        .root_source_file = b.path("lib/archive.h"),
        .target = target,
        .optimize = optimize,
    });
    archive_c.linkSystemLibrary("archive", .{});

    const module = b.addModule("libnest", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "archive_c",
                .module = archive_c.createModule(),
            },
        },
    });
    module.addOptions("config", options);

    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = false,
    });
    module.addImport("curl", curl.module("curl"));

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("zqlite", zqlite.module("zqlite"));

    const ini = b.dependency("ini", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("ini", ini.module("ini"));

    if (!skip_tests) {
        const tests = b.addTest(.{
            .root_module = b.addModule("tests", .{
                .root_source_file = b.path("src/tests.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{
                        .name = "archive_c",
                        .module = archive_c.createModule(),
                    },
                },
            }),
            .use_llvm = true,
            .filters = test_filters,
        });

        tests.root_module.linkSystemLibrary("curl", .{});
        tests.root_module.addImport("curl", curl.module("curl"));
        tests.root_module.addImport("zqlite", zqlite.module("zqlite"));

        const run_tests = b.addRunArtifact(tests);

        const test_step = b.step("test", "Run libnest tests");
        test_step.dependOn(&run_tests.step);
    }

    if (emit_library) {
        var lib = b.addLibrary(.{
            .name = "nest",
            .root_module = module,
            .linkage = .static,
        });

        b.installArtifact(lib);

        lib = b.addLibrary(.{
            .name = "nest",
            .root_module = module,
            .linkage = .dynamic,
            .version = .{
                .major = 0,
                .minor = 1,
                .patch = 0,
            },
        });
        b.installArtifact(lib);
    }
}
