const std = @import("std");

const Dependency = @import("Dependency.zig");
const Version = @import("Version.zig");

const Package = @This();

alloc: std.mem.Allocator,
name: []const u8,
version: Version,
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
    version: Version,
) !Package {
    return Package{
        .alloc = alloc,
        .name = try alloc.dupe(u8, name),
        .version = version,
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

pub fn deinit(self: *Package) void {
    self.alloc.free(self.name);

    self.alloc.free(self.desc);
    self.alloc.free(self.arch);
    self.alloc.free(self.repo);
    self.alloc.free(self.filename);

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
    self: Package,
    comptime fmt: []const u8,
    opts: std.fmt.FormatOptions,
) ![]const u8 {
    return try std.fmt.allocPrint(self.alloc, fmt, opts);
}

pub fn equals(
    self: Package,
    comp: Package,
) bool {
    return if (self == comp) true else false;
}

pub fn fromDesc(
    alloc: std.mem.Allocator,
    desc: []const u8,
) !Package {}
