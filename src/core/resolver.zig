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
    const pkgs = try resolvePkg(ctx, pkg);
    defer {
        for (pkgs) |p| {
            p.deinit(ctx.alloc);
        }
        ctx.alloc.free(pkgs);
    }

    try installer.install(
        ctx,
        pkgs,
    );
}

pub fn resolvePkg(
    ctx: *Context,
    pkg: Pkg,
) ![]Pkg {
    var visited = std.StringHashMap(void).init(ctx.alloc);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| ctx.alloc.free(k.*);
        visited.deinit();
    }
    var pkgs: std.ArrayList(Pkg) = .empty;

    try resolveDeps(
        ctx,
        pkg,
        &visited,
        &pkgs,
    );
    try pkgs.append(ctx.alloc, pkg);

    return pkgs.toOwnedSlice(ctx.alloc);
}

fn resolveDeps(
    ctx: *Context,
    pkg: Pkg,
    visited: *std.StringHashMap(void),
    pkg_list: *std.ArrayList(Pkg),
) !void {
    for (pkg.deps) |d| {
        const dep = Dep.parse(d);
        if (visited.contains(dep.name)) continue;

        const installed: []Pkg.Installed = try ctx.db.queryPkg(.Installed, dep.name);
        defer {
            for (installed) |p| {
                p.deinit(ctx.alloc);
            }
            ctx.alloc.free(installed);
        }
        if (installed.len > 0) continue;

        const pkgs: []Pkg = try ctx.db.queryPkg(.Sync, dep.name);
        const selected = if (pkgs.len > 1) blk: {
            if (ctx.select_cb) |cb| {
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(ctx.alloc);
                for (pkgs) |p| {
                    try names.append(ctx.alloc, p.name);
                }
                break :blk try cb(names.items, names.items.len);
            } else break :blk 0;
        } else 0;
        if (selected <= -1) return error.AbortedInstall;
        defer {
            for (pkgs, 0..) |p, idx| {
                if (idx == selected) continue;
                p.deinit(ctx.alloc);
            }
            ctx.alloc.free(pkgs);
        }
        const p = pkgs[@intCast(selected)];

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
        try pkg_list.append(ctx.alloc, p);
        try resolveDeps(
            ctx,
            p,
            visited,
            pkg_list,
        );
    }
}
