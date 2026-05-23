const std = @import("std");
const mem = @import("../utils/mem.zig");

const Pkg = @This();

name: []const u8 = "",
repo: []const u8 = "",
build_date: i64 = 0,
version: []const u8 = "",
description: []const u8 = "",
arch: []const u8 = "",
license: [][]const u8 = &.{},
filename: []const u8 = "",
packager: []const u8 = "",
checksum: []const u8 = "",
signature: []const u8 = "",
replaces: [][]const u8 = &.{},
conflicts: [][]const u8 = &.{},
provides: [][]const u8 = &.{},
deps: [][]const u8 = &.{},
mkdeps: [][]const u8 = &.{},
optdeps: [][]const u8 = &.{},
checkdeps: [][]const u8 = &.{},

pub fn clone(self: Pkg, alloc: std.mem.Allocator) !Pkg {
    var pkg = Pkg{};
    errdefer pkg.deinit(alloc);

    pkg.name = try alloc.dupe(u8, self.name);
    pkg.repo = try alloc.dupe(u8, self.repo);
    pkg.build_date = self.build_date;
    pkg.version = try alloc.dupe(u8, self.version);
    pkg.description = try alloc.dupe(u8, self.description);
    pkg.arch = try alloc.dupe(u8, self.arch);
    pkg.license = try mem.dupeSlice([]const u8, alloc, self.license);
    pkg.filename = try alloc.dupe(u8, self.filename);
    pkg.packager = try alloc.dupe(u8, self.packager);
    pkg.checksum = try alloc.dupe(u8, self.checksum);
    pkg.signature = try alloc.dupe(u8, self.signature);
    pkg.replaces = try mem.dupeSlice([]const u8, alloc, self.replaces);
    pkg.conflicts = try mem.dupeSlice([]const u8, alloc, self.conflicts);
    pkg.provides = try mem.dupeSlice([]const u8, alloc, self.provides);
    pkg.deps = try mem.dupeSlice([]const u8, alloc, self.deps);
    pkg.mkdeps = try mem.dupeSlice([]const u8, alloc, self.mkdeps);
    pkg.optdeps = try mem.dupeSlice([]const u8, alloc, self.optdeps);
    pkg.checkdeps = try mem.dupeSlice([]const u8, alloc, self.checkdeps);

    return pkg;
}

pub fn deinit(self: Pkg, alloc: std.mem.Allocator) void {
    alloc.free(self.name);
    alloc.free(self.repo);
    alloc.free(self.version);
    alloc.free(self.description);
    alloc.free(self.arch);
    mem.freeSlice(alloc, self.license);
    alloc.free(self.filename);
    alloc.free(self.packager);
    alloc.free(self.checksum);
    alloc.free(self.signature);
    mem.freeSlice(alloc, self.replaces);
    mem.freeSlice(alloc, self.conflicts);
    mem.freeSlice(alloc, self.provides);
    mem.freeSlice(alloc, self.deps);
    mem.freeSlice(alloc, self.mkdeps);
    mem.freeSlice(alloc, self.optdeps);
    mem.freeSlice(alloc, self.checkdeps);
}

pub const Installed = struct {
    name: []const u8 = "",
    repo: []const u8 = "",
    build_date: i64 = 0,
    size: i64 = 0,
    version: []const u8 = "",
    description: []const u8 = "",
    url: []const u8 = "",
    arch: []const u8 = "",
    license: [][]const u8 = &.{},
    provides: [][]const u8 = &.{},
    conflicts: [][]const u8 = &.{},
    packager: []const u8 = "",
    deps: [][]const u8 = &.{},
    optdeps: [][]const u8 = &.{},
    checkdeps: [][]const u8 = &.{},
    mkdeps: [][]const u8 = &.{},

    pub fn clone(self: Pkg.Installed, alloc: std.mem.Allocator) !Pkg.Installed {
        var pkg = Pkg.Installed{};
        errdefer pkg.deinit(alloc);

        pkg.name = try alloc.dupe(u8, self.name);
        pkg.repo = try alloc.dupe(u8, self.repo);
        pkg.build_date = self.build_date;
        pkg.size = self.size;
        pkg.version = try alloc.dupe(u8, self.version);
        pkg.description = try alloc.dupe(u8, self.description);
        pkg.url = try alloc.dupe(u8, self.url);
        pkg.arch = try alloc.dupe(u8, self.arch);
        pkg.license = try mem.dupeSlice([]const u8, alloc, self.license);
        pkg.packager = try alloc.dupe(u8, self.packager);
        pkg.conflicts = try mem.dupeSlice([]const u8, alloc, self.conflicts);
        pkg.provides = try mem.dupeSlice([]const u8, alloc, self.provides);
        pkg.deps = try mem.dupeSlice([]const u8, alloc, self.deps);
        pkg.mkdeps = try mem.dupeSlice([]const u8, alloc, self.mkdeps);
        pkg.optdeps = try mem.dupeSlice([]const u8, alloc, self.optdeps);
        pkg.checkdeps = try mem.dupeSlice([]const u8, alloc, self.checkdeps);

        return pkg;
    }

    pub fn deinit(self: Pkg.Installed, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.repo);
        alloc.free(self.version);
        alloc.free(self.description);
        alloc.free(self.url);
        alloc.free(self.arch);
        mem.freeSlice(alloc, self.conflicts);
        mem.freeSlice(alloc, self.provides);
        mem.freeSlice(alloc, self.license);
        alloc.free(self.packager);
        mem.freeSlice(alloc, self.deps);
        mem.freeSlice(alloc, self.mkdeps);
        mem.freeSlice(alloc, self.optdeps);
        mem.freeSlice(alloc, self.checkdeps);
    }
};
