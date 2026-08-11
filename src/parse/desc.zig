const std = @import("std");
const package = @import("../core/package.zig");
const Context = @import("../core/context.zig").Context;
const ver = @import("../utils/version.zig");

pub const Field = enum {
    none,
    name,
    version,
    arch,
    checksum,
    licenses,
    replaces,
    conflicts,
    provides,
    depends,
    makedeps,
    optdeps,
    checkdeps,

    pub fn parse(name: []const u8) Field {
        if (std.mem.eql(u8, name, "NAME")) return .name;
        if (std.mem.eql(u8, name, "VERSION")) return .version;
        if (std.mem.eql(u8, name, "ARCH")) return .arch;
        if (std.mem.eql(u8, name, "SHA256SUM")) return .checksum;
        if (std.mem.eql(u8, name, "LICENSE")) return .licenses;
        if (std.mem.eql(u8, name, "REPLACES")) return .replaces;
        if (std.mem.eql(u8, name, "CONFLICTS")) return .conflicts;
        if (std.mem.eql(u8, name, "PROVIDES")) return .provides;
        if (std.mem.eql(u8, name, "DEPENDS")) return .depends;
        if (std.mem.eql(u8, name, "MAKEDEPENDS")) return .makedeps;
        if (std.mem.eql(u8, name, "OPTDEPENDS")) return .optdeps;
        if (std.mem.eql(u8, name, "CHECKDEPENDS")) return .checkdeps;

        return .none;
    }
};

pub fn parse(alloc: std.mem.Allocator, repo: []const u8, src: []const u8) !package.PackageInfo {
    var pkg = package.PackageInfo{
        .name = &.{},
        .repo = try alloc.dupe(u8, repo),
        .epoch = 0,
        .version = &.{},
        .release = null,
        .arch = &.{},
        .checksum = null,
        .licenses = &.{},
        .replaces = &.{},
        .conflicts = &.{},
        .provides = &.{},
        .deps = &.{},
    };

    var licenses: std.ArrayList([]const u8) = .empty;
    var replaces: std.ArrayList(package.Constrained) = .empty;
    var conflicts: std.ArrayList(package.Constrained) = .empty;
    var provides: std.ArrayList(package.Constrained) = .empty;
    var deps: std.ArrayList(package.Dependency) = .empty;

    var lines = std.mem.splitScalar(u8, src, '\n');

    errdefer {
        for (licenses.items) |i| alloc.free(i);
        licenses.deinit(alloc);
        for (replaces.items) |*i| i.deinit(alloc);
        replaces.deinit(alloc);
        for (conflicts.items) |*i| i.deinit(alloc);
        conflicts.deinit(alloc);
        for (provides.items) |*i| i.deinit(alloc);
        provides.deinit(alloc);
        for (deps.items) |*i| i.deinit(alloc);
        deps.deinit(alloc);
    }

    var field: Field = .none;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(
            u8,
            line,
            " \r\t",
        );
        if (trimmed.len == 0) continue;

        if (trimmed.len > 2 and trimmed[0] == '%' and trimmed[trimmed.len - 1] == '%') {
            field = Field.parse(trimmed[1 .. trimmed.len - 1]);
            continue;
        }

        switch (field) {
            .name => pkg.name = try alloc.dupe(u8, trimmed),
            .version => {
                const evr = ver.parseEVR(trimmed);
                pkg.epoch = try std.fmt.parseUnsigned(u32, evr.epoch, 10);
                pkg.version = try alloc.dupe(u8, evr.version);
                pkg.release = if (evr.release) |r| try alloc.dupe(u8, r) else null;
            },
            .arch => pkg.arch = try alloc.dupe(u8, trimmed),
            .checksum => {
                var decoded: [32]u8 = undefined;
                _ = try std.fmt.hexToBytes(&decoded, trimmed);
                pkg.checksum = decoded;
            },

            .licenses => try licenses.append(
                alloc,
                try alloc.dupe(u8, trimmed),
            ),
            .replaces => try replaces.append(
                alloc,
                try package.Constrained.parse(alloc, trimmed),
            ),
            .conflicts => try conflicts.append(
                alloc,
                try package.Constrained.parse(alloc, trimmed),
            ),
            .provides => try provides.append(
                alloc,
                try package.Constrained.parse(alloc, trimmed),
            ),
            .depends => try deps.append(
                alloc,
                try package.Dependency.parse(alloc, trimmed, .Run),
            ),
            .makedeps => try deps.append(
                alloc,
                try package.Dependency.parse(alloc, trimmed, .Make),
            ),
            .checkdeps => try deps.append(
                alloc,
                try package.Dependency.parse(alloc, trimmed, .Check),
            ),
            .optdeps => try deps.append(
                alloc,
                try package.Dependency.parse(alloc, trimmed, .Optional),
            ),

            .none => {},
        }
    }

    pkg.licenses = try licenses.toOwnedSlice(alloc);
    pkg.replaces = try replaces.toOwnedSlice(alloc);
    pkg.conflicts = try conflicts.toOwnedSlice(alloc);
    pkg.provides = try provides.toOwnedSlice(alloc);
    pkg.deps = try deps.toOwnedSlice(alloc);

    return pkg;
}
