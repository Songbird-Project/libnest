const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = @import("../utils/mem.zig");
const RepoConn = @import("repo.zig").RepoConn;

pub const Provider = struct {
    info: *PackageInfo,
    conn: RepoConn,
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

// The DB handles tracking files and blobs
// pub const PackageOutput = struct {
//     // hash of the output file
//     hash: [32]u8,
//     path: []const u8,
//     created: std.Io.Timestamp,
// };

pub const DepKind = enum(u8) {
    Run,
    Make,
    Check,
    Optional,
};

pub const Constrained = struct {
    name: []const u8,
    constraint: ?[]const u8 = null,

    pub fn parse(alloc: Allocator, src: []const u8) !Constrained {
        var parsed: Constrained = undefined;

        if (std.mem.findAny(u8, src, "=<>")) |idx| {
            parsed.name = try alloc.dupe(u8, src[0..idx]);
            parsed.constraint = try alloc.dupe(u8, src[idx..]);
        } else {
            parsed.name = try alloc.dupe(u8, src);
            parsed.constraint = null;
        }

        return parsed;
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

    pub fn parse(alloc: Allocator, dep: []const u8, kind: DepKind) !Dependency {
        var parsed: Dependency = undefined;
        parsed.kind = kind;

        if (std.mem.findAny(u8, dep, "=<>")) |idx| {
            parsed.name = try alloc.dupe(u8, dep[0..idx]);
            parsed.constraint = try alloc.dupe(u8, dep[idx..]);
        } else {
            parsed.name = try alloc.dupe(u8, dep);
            parsed.constraint = null;
        }

        return parsed;
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
