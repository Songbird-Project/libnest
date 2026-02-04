const std = @import("std");

const MirrorList = @import("net/MirrorList.zig");
const Db = @import("core/Database.zig");

const PKG_DB: []const u8 = "./tests/pkgs.db";
const MIRRORS: []const u8 = "./tests/mirrors";

fn cb(dlnow: f64, dltotal: f64) !void {
    const bar_width: usize = 10;
    const filled: u8 = @min(bar_width, @as(u8, @intFromFloat((dlnow / dltotal) * 10)));

    var bar: [bar_width]u8 = undefined;
    @memset(bar[0..filled], '#');
    @memset(bar[filled..], ' ');

    std.debug.print("\r[{s}]", .{bar});
}

test "Sync Mirrors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const repos = [_][]const u8{ "core", "multilib", "extra" };

    var db = try Db.init(alloc, PKG_DB);
    defer db.deinit();

    for (repos) |repo| {
        try db.sync(
            MIRRORS,
            "./tests/",
            repo,
            "x86_64",
            50_000,
            &cb,
        );
    }
}

test "Package Download" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try Db.init(alloc, PKG_DB);
    defer db.deinit();

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    const txn = try db.newTxn();
    const pkgs = try db.queryPkgRepo(
        txn,
        "binutils",
    );
    defer alloc.free(pkgs);
    if (pkgs.len > 1) {
        @panic("unhandled :/");
    }

    const pkg = try db.queryPkg(txn, &pkgs[0]);

    try mirrors.downloadPkg(
        pkgs[0],
        pkg,
        "./tests/binutils.pkg.tar.zst",
        &cb,
    );
}
