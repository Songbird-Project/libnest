const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const emit_static = b.option(
        bool,
        "emit-static",
        "Emit a static library",
    ) orelse false;
    const emit_dynamic = b.option(
        bool,
        "emit-dynamic",
        "Emit a dynamic library",
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

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_opts = .{
        .target = target,
        .optimize = optimize,
    };
    _ = dep_opts;

    const archive_c = b.addTranslateC(.{
        .root_source_file = b.path("lib/archive.h"),
        .target = target,
        .optimize = optimize,
    });
    archive_c.linkSystemLibrary("archive", .{});

    const git2_c = b.addTranslateC(.{
        .root_source_file = b.path("lib/git.h"),
        .target = target,
        .optimize = optimize,
    });
    git2_c.linkSystemLibrary("git2", .{});

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
            .{
                .name = "git2_c",
                .module = git2_c.createModule(),
            },
        },
    });

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
    module.linkSystemLibrary("sqlite3", .{});
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
                    .{
                        .name = "git2_c",
                        .module = git2_c.createModule(),
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

    if (emit_dynamic) {
        const lib = b.addLibrary(.{
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

    if (emit_static) {
        const lib = b.addLibrary(.{
            .name = "nest",
            .root_module = module,
            .linkage = .static,
        });

        b.installArtifact(lib);
    }
}
