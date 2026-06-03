const std = @import("std");
const version = @import("version.zig");
const installer = @import("installer.zig");

const Pkg = @import("Package.zig");
const Context = @import("Context.zig");

pub const PkgUpgradeInfo = struct {
    name: []const u8,
    repo: []const u8,

    pub fn deinit(self: *PkgUpgradeInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.repo);
    }

    pub fn clone(self: *PkgUpgradeInfo, alloc: std.mem.Allocator) !PkgUpgradeInfo {
        return .{
            .name = try alloc.dupe(u8, self.name),
            .repo = try alloc.dupe(u8, self.repo),
        };
    }
};

pub fn prepareUpgrade(
    ctx: *Context,
) ![]PkgUpgradeInfo {
    var rows = try ctx.db.conn.rows(
        \\SELECT
        \\  installed.name AS name,
        \\  installed.repo AS repo,
        \\  installed.version AS installed_ver,
        \\  packages.version AS sync_ver
        \\FROM installed
        \\JOIN packages
        \\  ON packages.name = installed.name
        \\ AND packages.repo = installed.repo
    , .{});
    defer rows.deinit();

    var results: std.ArrayList(PkgUpgradeInfo) = .empty;
    defer {
        for (results.items) |*r| r.deinit(ctx.alloc);
        results.deinit(ctx.alloc);
    }

    while (rows.next()) |row| {
        defer ctx.alloc.free(row.name);
        defer ctx.alloc.free(row.repo);
        defer ctx.alloc.free(row.installed_ver);
        defer ctx.alloc.free(row.sync_ver);
        const iname = row.text(0);
        const irepo = row.text(1);
        const iver = row.text(2);
        const sver = row.text(3);

        const cmp = version.cmp(iver, sver);
        switch (cmp) {
            -1 => try results.append(
                ctx.alloc,
                .{
                    .name = try ctx.alloc.dupe(u8, iname),
                    .repo = try ctx.alloc.dupe(u8, irepo),
                },
            ),
            1 => {
                const msg = try std.fmt.allocPrint(
                    ctx.alloc,
                    "Local {s}({s}) is newer than synced {s}({s})",
                    .{
                        iname,
                        iver,
                        iname,
                        sver,
                    },
                );
                defer ctx.alloc.free(msg);
                try ctx.log(
                    .Warn,
                    msg,
                );
            },
            0, _ => {},
        }
    }

    var pkgs: std.ArrayList(Pkg) = .empty;
    errdefer {
        for (pkgs.items) |p| p.deinit(ctx.alloc);
        pkgs.deinit(ctx.alloc);
    }

    for (results.items) |up| {
        const sync = try ctx.db.querySync(
            up.name,
            up.repo,
        );
        defer {
            for (sync) |p| p.deinit(ctx.alloc);
            ctx.alloc.free(sync);
        }

        if (sync.len == 0) return error.FailedToGetTarget;
        if (sync.len > 1) return error.CorruptedDatabase;
        try pkgs.append(ctx.alloc, try sync[0].clone(ctx.alloc));
    }

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| f.deinit(ctx.alloc);
        files.deinit(ctx.alloc);
    }

    for (pkgs.items) |p| {
        var file_rows = try ctx.db.conn.rows(
            "SELECT path FROM files WHERE name=?1 AND repo=?2",
            .{ p.name, p.repo },
        );
        defer file_rows.deinit();

        while (file_rows.next()) |row| {
            const path = row.text(0);
            try files.append(
                ctx.alloc,
                try ctx.alloc.dupe(u8, path),
            );
        }

        if (file_rows.err) |err| return err;
    }

    try ctx.txn.updateFiles(ctx.alloc, files.items);

    return pkgs.toOwnedSlice(ctx.alloc);
}
