const std = @import("std");
const version = @import("version.zig");
const installer = @import("installer.zig");

const Pkg = @import("Package.zig");
const Context = @import("Context.zig");

pub const PkgUpgradeInfo = struct {
    name: []const u8,
    repo: []const u8,

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
    var stmt = try ctx.db.db.prepare(
        \\SELECT 
        \\  installed.name AS name,
        \\  intalled.repo as repo,
        \\  installed.version AS installed_ver,
        \\  packages.version AS sync_ver
        \\FROM installed
        \\JOIN packages
        \\  ON packages.name = installed.name
        \\ AND packages.repo = installed.name
    );
    defer stmt.deinit();

    var results: std.ArrayList(PkgUpgradeInfo) = .empty;
    for (results.items) |r| r.deinit(ctx.alloc);
    results.deinit(ctx.alloc);

    var it = try stmt.iterator(
        struct {
            name: []const u8,
            repo: []const u8,
            installed_ver: []const u8,
            sync_ver: []const u8,
        },
        .{},
    );

    while (try it.nextAlloc(ctx.alloc, .{})) |row| {
        defer ctx.alloc.free(row.name);
        defer ctx.alloc.free(row.repo);
        defer ctx.alloc.free(row.installed_ver);
        defer ctx.alloc.free(row.sync_ver);

        const cmp = version.cmp(row.installed_ver, row.sync_ver);
        const info = PkgUpgradeInfo{
            .name = row.name,
            .repo = row.repo,
        };

        switch (cmp) {
            -1 => try results.append(
                ctx.alloc,
                try info.clone(ctx.alloc),
            ),
            1 => {
                const detail = try std.fmt.allocPrint(
                    ctx.alloc,
                    "Local {s}({s}) is newer than synced {s}({s})",
                    .{
                        row.name,
                        row.installed_ver,
                        row.name,
                        row.sync_ver,
                    },
                );
                defer ctx.alloc.free(detail);
                ctx.log(
                    .Warn,
                    .Upgrade,
                    detail,
                );
            },
            0, _ => {},
        }
    }

    var pkgs: std.ArrayList(Pkg) = .empty;

    for (results.items) |up| {
        try pkgs.append(ctx.alloc, try ctx.db.queryPkg(
            .Sync,
            up.name,
            up.repo,
        )[0]);
    }

    return pkgs.toOwnedSlice(ctx.alloc);
}
