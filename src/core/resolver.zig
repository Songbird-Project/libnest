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

    const infos = try installer.prepareInstall(ctx, pkgs);
    try ctx.txn.update(
        ctx.alloc,
        infos,
        &.{},
        &.{},
    );
    try installer.install(ctx);
}

pub fn resolvePkg(
    ctx: *Context,
    pkg: Pkg,
) ![]Pkg {
    for (ctx.txn.installs.items) |item| {
        if (std.mem.eql(u8, item.pkg.name, pkg.name)) return &.{};
    }

    var visited = std.StringHashMap(void).init(ctx.alloc);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| ctx.alloc.free(k.*);
        visited.deinit();
    }
    var pkgs: std.ArrayList(Pkg) = .empty;

    try visited.put(try ctx.alloc.dupe(u8, pkg.name), {});
    try resolveDeps(
        ctx,
        pkg,
        &visited,
        &pkgs,
    );
    try pkgs.append(ctx.alloc, try pkg.clone(ctx.alloc));

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

        var skip = false;
        for (ctx.txn.installs.items) |item| {
            if (std.mem.eql(u8, item.pkg.name, dep.name)) skip = true;
        }
        if (skip) continue;

        const installed: []Pkg.Installed = try ctx.db.queryInstalled(
            dep.name,
            null,
        );
        defer {
            for (installed) |p| {
                p.deinit(ctx.alloc);
            }
            ctx.alloc.free(installed);
        }
        if (installed.len > 0) continue;

        const pkgs: []Pkg = try ctx.db.querySync(
            dep.name,
            null,
        );
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
            for (pkgs) |p| p.deinit(ctx.alloc);
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

        const selected_pkg = try p.clone(ctx.alloc);

        if (visited.contains(selected_pkg.name)) {
            selected_pkg.deinit(ctx.alloc);
            continue;
        }
        try visited.put(try ctx.alloc.dupe(u8, selected_pkg.name), {});
        try pkg_list.append(ctx.alloc, selected_pkg);
        try resolveDeps(
            ctx,
            selected_pkg,
            visited,
            pkg_list,
        );
    }
}
