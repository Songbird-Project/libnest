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

name: []const u8,
version: ?[]const u8,
constraint: Constraint = .none,

pub fn parse(
    dep: []const u8,
) Dependency {
    var name = dep;
    var version: ?[]const u8 = null;
    var constraint: Constraint = .none;

    if (std.mem.indexOf(u8, dep, ">=")) |idx| {
        constraint = .gte;
        name = dep[0..idx];
        version = dep[idx + 2 ..];
    } else if (std.mem.indexOf(u8, dep, "<=")) |idx| {
        constraint = .lte;
        name = dep[0..idx];
        version = dep[idx + 2 ..];
    } else if (std.mem.indexOfScalar(u8, dep, '>')) |idx| {
        constraint = .gt;
        name = dep[0..idx];
        version = dep[idx + 1 ..];
    } else if (std.mem.indexOfScalar(u8, dep, '<')) |idx| {
        constraint = .lt;
        name = dep[0..idx];
        version = dep[idx + 1 ..];
    } else if (std.mem.indexOfScalar(u8, dep, '=')) |idx| {
        constraint = .eql;
        name = dep[0..idx];
        version = dep[idx + 1 ..];
    }

    return .{
        .name = name,
        .version = version,
        .constraint = constraint,
    };
}

pub fn checkVer(con: Constraint, cmp: i8) bool {
    return switch (con) {
        .eql => cmp == 0,
        .gt => cmp == 1,
        .lt => cmp == -1,
        .gte => cmp == 0 or cmp == 1,
        .lte => cmp == 0 or cmp == -1,
        .none => true,
    };
}
