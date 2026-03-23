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

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_opts = .{
        .target = target,
        .optimize = optimize,
    };
    _ = dep_opts;

    const module = b.addModule("libnest", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    module.linkSystemLibrary("archive", .{});
    module.linkSystemLibrary("git2", .{});
    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("curl", curl.module("curl"));
    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("sqlite", sqlite.module("sqlite"));

    const tests = b.addTest(.{
        .root_module = b.addModule("tests", .{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
        .filters = test_filters,
    });

    tests.linkSystemLibrary("curl");
    tests.linkSystemLibrary("archive");
    tests.linkSystemLibrary("git2");
    tests.linkLibC();
    tests.root_module.addImport("curl", curl.module("curl"));
    tests.root_module.addImport("sqlite", sqlite.module("sqlite"));

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run libnest tests");
    test_step.dependOn(&run_tests.step);

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
