const std = @import("std");

const Dependency = @import("Dependency.zig");

const Pkg = @This();

alloc: std.mem.Allocator,
name: []const u8,
version: []const u8,
desc: []const u8,
arch: []const u8,
repo: []const u8,
filename: []const u8,
provides: [][]const u8,
conflicts: [][]const u8,
replaces: [][]const u8,
deps: []Dependency,
mkdeps: []Dependency,
optdeps: []Dependency,

pub fn init(
    alloc: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
) !Pkg {
    return Pkg{
        .alloc = alloc,
        .name = try alloc.dupe(u8, name),
        .version = try alloc.dupe(u8, version),
        .desc = &.{},
        .arch = &.{},
        .repo = &.{},
        .filename = &.{},
        .provides = &.{},
        .conflicts = &.{},
        .replaces = &.{},
        .deps = &.{},
        .mkdeps = &.{},
        .optdeps = &.{},
    };
}

pub fn deinit(self: *Pkg) void {
    self.alloc.free(self.name);

    self.alloc.free(self.desc);
    self.alloc.free(self.arch);
    self.alloc.free(self.repo);
    self.alloc.free(self.filename);
    self.alloc.free(self.version);

    for (self.provides) |item| self.alloc.free(item);
    self.alloc.free(self.provides);

    for (self.conflicts) |item| self.alloc.free(item);
    self.alloc.free(self.conflicts);

    for (self.replaces) |item| self.alloc.free(item);
    self.alloc.free(self.replaces);

    for (self.deps) |*dep| dep.deinit();
    self.alloc.free(self.deps);

    for (self.mkdeps) |*dep| dep.deinit();
    self.alloc.free(self.mkdeps);

    for (self.optdeps) |*dep| dep.deinit();
    self.alloc.free(self.optdeps);
}

pub fn format(
    alloc: std.mem.Allocator,
    comptime fmt: []const u8,
    opts: anytype,
) ![]const u8 {
    const str = try std.fmt.allocPrint(alloc, fmt, opts);
    return str;
}

pub fn equals(
    self: Pkg,
    comp: Pkg,
) bool {
    return if (self == comp) true else false;
}
