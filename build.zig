const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const emit_library = b.option(bool, "emit-lib", "Whether to build library files") orelse false;

    const name = b.option([]const u8, "name", "The name of the frontend") orelse "libnest";
    const options = b.addOptions();
    options.addOption([]const u8, "name", name);

    const archive_c = b.addTranslateC(.{
        .root_source_file = b.path("lib/archive.h"),
        .target = target,
        .optimize = optimize,
    });
    archive_c.linkSystemLibrary("archive", .{});

    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = false,
    });
    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const ini = b.dependency("ini", .{
        .target = target,
        .optimize = optimize,
    });

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

    module.addImport("curl", curl.module("curl"));
    module.addImport("zqlite", zqlite.module("zqlite"));
    module.addImport("ini", ini.module("ini"));

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
