const std = @import("std");

const Pkg = @This();

name: []const u8,
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

pub fn deinit(self: Pkg, alloc: std.mem.Allocator) void {
    const deepFree = struct {
        fn f(a: std.mem.Allocator, slices: [][]const u8) void {
            for (slices) |slice| a.free(slice);
            a.free(slices);
        }
    }.f;

    alloc.free(self.name);
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
    build_date: i64,
    size: i64,
    version: []const u8,
    description: []const u8,
    url: []const u8,
    arch: []const u8,
    license: [][]const u8,
    packager: []const u8,
    deps: [][]const u8,
    optdeps: [][]const u8,

    pub fn deinit(self: Pkg.Installed, alloc: std.mem.Allocator) void {
        const deepFree = struct {
            fn f(a: std.mem.Allocator, slices: [][]const u8) void {
                for (slices) |slice| a.free(slice);
                a.free(slices);
            }
        }.f;

        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.description);
        alloc.free(self.url);
        alloc.free(self.arch);
        deepFree(alloc, self.license);
        alloc.free(self.packager);
        deepFree(alloc, self.deps);
        deepFree(alloc, self.optdeps);
    }
};
