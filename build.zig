const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const emit_lib = b.option(bool, "emit-lib", "Emit a linked library file (use -Ddynamic for a dynamic library)");
    const dynamic = b.option(bool, "dynamic", "Emit a dynamically linked library");
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

    const tests = b.addTest(.{
        .root_module = b.addModule("tests", .{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

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
                    .minor = 0,
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

        if (lib != null) {
            b.installArtifact(lib.?);
        }
    }
}
