const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const emit_lib = b.option(bool, "emit-lib", "Emit a static library file (use -Ddynamic for a dynamic library)");
    const dynamic = b.option(bool, "dynamic", "Emit a dynamic library");
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

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("sqlite", sqlite.module("sqlite"));

    const curl = b.dependency("curl", .{ .link_vendor = false });
    module.addImport("curl", curl.module("curl"));
    module.addLibraryPath(.{
        .dependency = .{
            .dependency = curl,
            .sub_path = "/usr/lib/",
        },
    });

    const tests = b.addTest(.{
        .root_module = b.addModule("tests", .{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });

    tests.linkSystemLibrary("curl");
    tests.linkLibC();
    tests.root_module.addImport("curl", curl.module("curl"));
    tests.root_module.addImport("sqlite", sqlite.module("sqlite"));

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run libnest tests");
    test_step.dependOn(&run_tests.step);
    b.getInstallStep().dependOn(test_step);

    if ((emit_lib != null and emit_lib.?) or (dynamic != null and dynamic.?)) {
        var lib: ?*std.Build.Step.Compile = null;

        if (dynamic != null and dynamic.?) {
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
        } else {
            lib = b.addLibrary(.{
                .name = "nest",
                .root_module = module,
                .linkage = .static,
            });
        }

        if (lib) |l| {
            l.linkSystemLibrary("curl");
            l.linkLibC();
            b.installArtifact(l);
        }
    }
}
