const std = @import("std");

const Pkg = @This();

name: []const u8,
repo: []const u8,
build_date: i64,
version: []const u8,
description: []const u8,
arch: []const u8,
license: [][]const u8,
filename: []const u8,
packager: []const u8,
checksum: []const u8,
signature: []const u8,
replaces: [][]const u8,
conflicts: [][]const u8,
provides: [][]const u8,
deps: [][]const u8,
mkdeps: [][]const u8,
optdeps: [][]const u8,
checkdeps: [][]const u8,

pub fn clone(self: Pkg, alloc: std.mem.Allocator) !Pkg {
    const deepDupe = struct {
        fn f(a: std.mem.Allocator, slices: [][]const u8) ![][]const u8 {
            const new_slices = try a.alloc([]const u8, slices.len);
            for (slices, 0..) |slice, i| {
                new_slices[i] = try a.dupe(u8, slice);
            }
            return new_slices;
        }
    }.f;

    return .{
        .name = try alloc.dupe(u8, self.name),
        .repo = try alloc.dupe(u8, self.repo),
        .build_date = self.build_date,
        .version = try alloc.dupe(u8, self.version),
        .description = try alloc.dupe(u8, self.description),
        .arch = try alloc.dupe(u8, self.arch),
        .license = try deepDupe(alloc, self.license),
        .filename = try alloc.dupe(u8, self.filename),
        .packager = try alloc.dupe(u8, self.packager),
        .checksum = try alloc.dupe(u8, self.checksum),
        .signature = try alloc.dupe(u8, self.signature),
        .replaces = try deepDupe(alloc, self.replaces),
        .conflicts = try deepDupe(alloc, self.conflicts),
        .provides = try deepDupe(alloc, self.provides),
        .deps = try deepDupe(alloc, self.deps),
        .mkdeps = try deepDupe(alloc, self.mkdeps),
        .optdeps = try deepDupe(alloc, self.optdeps),
        .checkdeps = try deepDupe(alloc, self.checkdeps),
    };
}

pub fn deinit(self: Pkg, alloc: std.mem.Allocator) void {
    const deepFree = struct {
        fn f(a: std.mem.Allocator, slices: [][]const u8) void {
            for (slices) |slice| a.free(slice);
            a.free(slices);
        }
    }.f;

    alloc.free(self.name);
    alloc.free(self.repo);
    alloc.free(self.version);
    alloc.free(self.description);
    alloc.free(self.arch);
    deepFree(alloc, self.license);
    alloc.free(self.filename);
    alloc.free(self.packager);
    alloc.free(self.checksum);
    alloc.free(self.signature);
    deepFree(alloc, self.replaces);
    deepFree(alloc, self.conflicts);
    deepFree(alloc, self.provides);
    deepFree(alloc, self.deps);
    deepFree(alloc, self.mkdeps);
    deepFree(alloc, self.optdeps);
    deepFree(alloc, self.checkdeps);
}

pub const Installed = struct {
    name: []const u8,
    repo: []const u8,
    build_date: i64,
    size: i64,
    version: []const u8,
    description: []const u8,
    url: []const u8,
    arch: []const u8,
    license: [][]const u8,
    provides: [][]const u8,
    conflicts: [][]const u8,
    packager: []const u8,
    deps: [][]const u8,
    optdeps: [][]const u8,
    checkdeps: [][]const u8,
    mkdeps: [][]const u8,

    pub fn clone(self: Pkg.Installed, alloc: std.mem.Allocator) !Pkg.Installed {
        const deepDupe = struct {
            fn f(a: std.mem.Allocator, slices: [][]const u8) ![][]const u8 {
                const new_slices = try a.alloc([]const u8, slices.len);
                for (slices, 0..) |slice, i| {
                    new_slices[i] = try a.dupe(u8, slice);
                }
                return new_slices;
            }
        }.f;

        return .{
            .name = try alloc.dupe(u8, self.name),
            .repo = try alloc.dupe(u8, self.repo),
            .build_date = self.build_date,
            .size = self.size,
            .version = try alloc.dupe(u8, self.version),
            .description = try alloc.dupe(u8, self.description),
            .url = try alloc.dupe(u8, self.url),
            .arch = try alloc.dupe(u8, self.arch),
            .license = try deepDupe(alloc, self.license),
            .packager = try alloc.dupe(u8, self.packager),
            .conflicts = try deepDupe(alloc, self.conflicts),
            .provides = try deepDupe(alloc, self.provides),
            .deps = try deepDupe(alloc, self.deps),
            .mkdeps = try deepDupe(alloc, self.mkdeps),
            .optdeps = try deepDupe(alloc, self.optdeps),
            .checkdeps = try deepDupe(alloc, self.checkdeps),
        };
    }

    pub fn deinit(self: Pkg.Installed, alloc: std.mem.Allocator) void {
        const deepFree = struct {
            fn f(a: std.mem.Allocator, slices: [][]const u8) void {
                for (slices) |slice| a.free(slice);
                a.free(slices);
            }
        }.f;

        alloc.free(self.name);
        alloc.free(self.repo);
        alloc.free(self.version);
        alloc.free(self.description);
        alloc.free(self.url);
        alloc.free(self.arch);
        deepFree(alloc, self.conflicts);
        deepFree(alloc, self.provides);
        deepFree(alloc, self.license);
        alloc.free(self.packager);
        deepFree(alloc, self.deps);
        deepFree(alloc, self.mkdeps);
        deepFree(alloc, self.optdeps);
        deepFree(alloc, self.checkdeps);
    }
};
