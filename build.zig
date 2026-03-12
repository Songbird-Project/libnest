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
    });

    const curl = b.dependency("curl", .{ .link_vendor = false });
    module.addImport("curl", curl.module("curl"));

    const tests = b.addTest(.{
        .root_module = b.addModule("tests", .{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });

    tests.linkSystemLibrary("curl");
    tests.linkSystemLibrary("archive");
    tests.linkSystemLibrary("lmdb");
    tests.linkSystemLibrary("git2");
    tests.linkLibC();
    tests.root_module.addImport("curl", curl.module("curl"));

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

        lib.linkSystemLibrary("curl");
        lib.linkSystemLibrary("archive");
        lib.linkSystemLibrary("lmdb");
        lib.linkSystemLibrary("git2");
        lib.linkLibC();
        b.installArtifact(lib);
    }

    if (emit_static) {
        const lib = b.addLibrary(.{
            .name = "nest",
            .root_module = module,
            .linkage = .static,
        });

        lib.linkSystemLibrary("curl");
        lib.linkSystemLibrary("archive");
        lib.linkSystemLibrary("lmdb");
        lib.linkLibC();
        b.installArtifact(lib);
    }
}
