const std = @import("std");
const installer = @import("installer.zig");
const version = @import("version.zig");

const Dep = @import("Dependency.zig");
const Context = @import("Context.zig");
const Pkg = @import("Package.zig");

pub fn installWithDeps(
    ctx: *Context,
    pkg: Pkg,
) !void {
    var visited = std.StringHashMap(void).init(ctx.alloc);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| ctx.alloc.free(k.*);
        visited.deinit();
    }

    try installRecursive(
        ctx,
        pkg,
        &visited,
    );
}

fn installRecursive(
    ctx: *Context,
    pkg: Pkg,
    visited: *std.StringHashMap(void),
) !void {
    for (pkg.deps) |d| {
        const dep = Dep.parse(d);
        if (visited.contains(dep.name)) continue;

        const pkgs: []Pkg = try ctx.db.queryPkg(.Sync, dep.name);
        defer {
            for (pkgs) |p| {
                p.deinit(ctx.alloc);
            }
            ctx.alloc.free(pkgs);
        }
        const p = pkgs[0];

        var ver: ?[]const u8 = p.version;
        if (!std.mem.eql(u8, dep.name, p.name)) {
            for (p.provides) |provided| {
                const prov = Dep.parse(provided);
                if (std.mem.eql(u8, dep.name, prov.name)) {
                    ver = prov.version;
                }
            }
        }

        const cmp = version.cmp(ver, dep.version);
        if (!Dep.checkVer(dep.constraint, cmp)) return error.UnsatisfiedDependency;

        try visited.put(try ctx.alloc.dupe(u8, dep.name), {});
        try installRecursive(
            ctx,
            p,
            visited,
        );
    }

    installer.install(
        ctx,
        pkg,
    ) catch |err| switch (err) {
        error.AlreadyInstalled => {},
        else => return err,
    };
}
