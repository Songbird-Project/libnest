const std = @import("std");

pub const Constraint = enum {
    eql,
    gt,
    lt,
    gte,
    lte,
    none,
};

const Dependency = @This();

alloc: std.mem.Allocator,
name: []const u8,
version: ?[]const u8,
constraint: Constraint = .none,

pub fn new(
    dep: []const u8,
) Dependency {
    var name = dep;
    var version: ?[]const u8 = null;
    var constraint: Constraint = .none;

    if (std.mem.indexOf(u8, version, '>')) |idx| {
        constraint = .gt;
        version = name[idx + 1 ..];
        name = name[0..idx];

        if (std.mem.indexOf(u8, version, '=')) {
            constraint = .gte;
            version = version[1..];
        }
    } else if (std.mem.indexOf(u8, version, '<')) |idx| {
        constraint = .lt;
        version = name[idx + 1 ..];
        name = name[0..idx];

        if (std.mem.indexOf(u8, version, '=')) {
            constraint = .lte;
            version = version[1..];
        }
    } else if (std.mem.indexOf(u8, version, '=')) |idx| {
        constraint = .eq;
        version = name[idx + 1 ..];
        name = name[0..idx];
    }

    return .{
        .name = name,
        .version = version,
        .constraint = constraint,
    };
}

pub fn deinit(self: Dependency) void {
    _ = self;
    return;
}
