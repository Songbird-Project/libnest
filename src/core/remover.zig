const std = @import("std");
const mem = @import("../utils/mem.zig");

const Context = @import("Context.zig");

pub fn prepareRemoval(
    ctx: *Context,
    pkgs: []const []const u8,
) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| ctx.alloc.free(f);
        files.deinit(ctx.alloc);
    }
    for (pkgs) |pkg| {
        const pkgid = try ctx.db.queryPkgId(pkg);
        const paths = try ctx.db.queryPaths(pkgid);
        defer {
            for (paths) |p| ctx.alloc.free(p);
            ctx.alloc.free(paths);
        }
        for (paths) |p| {
            try files.append(ctx.alloc, try ctx.alloc.dupe(u8, p));
        }
    }

    try ctx.txn.updateFiles(ctx.alloc, files.items);

    return try mem.dupeSlice([]const u8, ctx.alloc, pkgs);
}

pub fn remove(
    ctx: *Context,
) !void {
    for (ctx.txn.removes.items) |pkg| {
        const pkgid = try ctx.db.queryPkgId(pkg);
        const paths = try ctx.db.queryPaths(pkgid);
        defer {
            for (paths) |p| ctx.alloc.free(p);
            ctx.alloc.free(paths);
        }
        for (paths) |path| {
            std.Io.Dir.cwd().deleteFile(ctx.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        try ctx.db.conn.exec("DELETE FROM installed WHERE id = ?", .{pkgid});
    }
}
