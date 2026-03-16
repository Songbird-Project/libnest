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
    alloc.free(self.version);
    alloc.free(self.description);
    alloc.free(self.arch);
    alloc.free(self.license);
    alloc.free(self.filename);
    alloc.free(self.packager);
    alloc.free(self.checksum);
    alloc.free(self.signature);
    alloc.free(self.replaces);
    alloc.free(self.conflicts);
    alloc.free(self.provides);
    alloc.free(self.deps);
    alloc.free(self.mkdeps);
    alloc.free(self.optdeps);
    alloc.free(self.checkdeps);
}

pub const Installed = struct {
    name: []const u8,
    build_date: i64,
    size: i64,
    version: []const u8,
    description: []const u8,
    url: []const u8,
    arch: []const u8,
    license: []const u8,
    packager: []const u8,
    deps: []const u8,
    optdeps: []const u8,
};
