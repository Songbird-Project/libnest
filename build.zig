const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const static_lib = b.option(bool, "emit-static", "Emit a statically linked library file");
    const dynamic_lib = b.option(bool, "emit-dynamic", "Emit a dynamically linked library");
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
    });
    tests.linkSystemLibrary("curl");
    tests.linkLibC();
    tests.root_module.addImport("curl", curl.module("curl"));

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run libnest tests");
    test_step.dependOn(&run_tests.step);
    b.getInstallStep().dependOn(test_step);

    if (static_lib != null and static_lib.?) {
        const libnest_static = b.addLibrary(.{
            .name = "nest",
            .root_module = module,
            .linkage = .static,
        });
        libnest_static.linkSystemLibrary("curl");
        libnest_static.linkLibC();

        b.installArtifact(libnest_static);
    }

    if (dynamic_lib != null and dynamic_lib.?) {
        const libnest_dynamic = b.addLibrary(.{
            .name = "nest",
            .root_module = module,
            .linkage = .dynamic,
            .version = .{
                .major = 0,
                .minor = 0,
                .patch = 0,
            },
        });
        libnest_dynamic.linkSystemLibrary("curl");
        libnest_dynamic.linkLibC();

        b.installArtifact(libnest_dynamic);
    }
}
