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
    var stmt = try ctx.db.db.prepare(
        \\SELECT
        \\  installed.name AS name,
        \\  installed.repo AS repo,
        \\  installed.version AS installed_ver,
        \\  packages.version AS sync_ver
        \\FROM installed
        \\JOIN packages
        \\  ON packages.name = installed.name
        \\ AND packages.repo = installed.repo
    );
    defer stmt.deinit();

    var results: std.ArrayList(PkgUpgradeInfo) = .empty;
    defer {
        for (results.items) |*r| r.deinit(ctx.alloc);
        results.deinit(ctx.alloc);
    }

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
        switch (cmp) {
            -1 => try results.append(
                ctx.alloc,
                .{
                    .name = try ctx.alloc.dupe(u8, row.name),
                    .repo = try ctx.alloc.dupe(u8, row.repo),
                },
            ),
            1 => {
                const msg = try std.fmt.allocPrint(
                    ctx.alloc,
                    "Local {s}({s}) is newer than synced {s}({s})",
                    .{
                        row.name,
                        row.installed_ver,
                        row.name,
                        row.sync_ver,
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

    return pkgs.toOwnedSlice(ctx.alloc);
}
