const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = @import("../utils/mem.zig");
const RepoDatabase = @import("repo.zig").RepoDatabase;

pub const Provider = struct {
    info: *PackageInfo,
    db: *RepoDatabase,
    id: i64,

    pub fn deinit(self: Provider, alloc: Allocator) void {
        self.info.deinit(alloc);
        alloc.destroy(self.info);
    }
};

pub const PackageInfo = struct {
    name: []const u8,
    epoch: u32 = 0,
    version: []const u8,
    release: ?[]const u8 = null,
    arch: []const u8,
    repo: []const u8,
    explicit: bool = true,
    checksum: ?[32]u8 = null,
    deps: []Dependency = &.{},
    licenses: []const []const u8 = &.{},
    provides: []Constrained = &.{},
    conflicts: []Constrained = &.{},
    replaces: []Constrained = &.{},

    pub fn deinit(self: *PackageInfo, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.version);
        if (self.release) |r| alloc.free(r);
        alloc.free(self.arch);
        alloc.free(self.repo);
        for (self.deps) |*dep| dep.deinit(alloc);
        alloc.free(self.deps);
        for (self.licenses) |v| alloc.free(v);
        alloc.free(self.licenses);
        for (self.provides) |*v| v.deinit(alloc);
        alloc.free(self.provides);
        for (self.conflicts) |*v| v.deinit(alloc);
        alloc.free(self.conflicts);
        for (self.replaces) |*v| v.deinit(alloc);
        alloc.free(self.replaces);
    }
};

pub const DepKind = enum(u8) {
    Run,
    Make,
    Check,
    Optional,
};

fn splitNameConstraint(src: []const u8) !Constrained {
    if (std.mem.findAny(u8, src, "=<>")) |idx|
        return .{ .name = src[0..idx], .constraint = src[idx..] }
    else
        return .{ .name = src, .constraint = null };
}

pub const Constrained = struct {
    name: []const u8,
    constraint: ?[]const u8 = null,

    pub fn parseAlloc(alloc: Allocator, src: []const u8) !Constrained {
        const constrained = splitNameConstraint(src);

        return .{
            .name = try alloc.dupe(u8, constrained.name),
            .constraint = try alloc.dupe(u8, constrained.constraint),
        };
    }

    pub fn parse(src: []const u8) Constrained {
        return splitNameConstraint(src);
    }

    pub fn deinit(self: *Constrained, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.constraint) |c| alloc.free(c);
    }
};

pub const Dependency = struct {
    name: []const u8,
    kind: DepKind,
    constraint: ?[]const u8,

    pub fn parseAlloc(alloc: Allocator, dep: []const u8, kind: DepKind) !Dependency {
        const constrained = splitNameConstraint(dep);

        return .{
            .kind = kind,
            .name = try alloc.dupe(u8, constrained.name),
            .constraint = try alloc.dupe(u8, constrained.constraint),
        };
    }

    pub fn parse(dep: []const u8, kind: DepKind) Dependency {
        const constrained = splitNameConstraint(dep);

        return .{
            .kind = kind,
            .name = constrained.name,
            .constraint = constrained.constraint,
        };
    }

    pub fn deinit(self: *Dependency, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.constraint) |c| alloc.free(c);
    }
};

pub const Package = struct {
    info: PackageInfo,
    // hash of the package .tar.zstd
    hash: [32]u8,

    pub fn deinit(self: *Package, alloc: Allocator) void {
        self.info.deinit(alloc);
    }
};
