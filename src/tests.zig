const std = @import("std");
const mdb = @import("utils/mdb.zig");

const Pkg = @import("core/Package.zig");
const MirrorList = @import("net/MirrorList.zig");
const Db = @import("core/Database.zig");
const AUR = struct {
    pub const Client = @import("aur/Client.zig");
};

const PKG_DB: []const u8 = "./tests/pkgs.db";
const MIRRORS: []const u8 = "./tests/mirrors";

fn cb(dlnow: f64, dltotal: f64) !void {
    const bar_width: usize = 10;
    const filled: u8 = if (dltotal == 0)
        0
    else
        @min(bar_width, @as(u8, @intFromFloat((dlnow / dltotal) * 10)));

    var bar: [bar_width]u8 = undefined;
    if (filled > 0) @memset(bar[0..filled], '#');
    @memset(bar[filled..], ' ');

    std.debug.print("\r[{s}]", .{bar});
}

test "AUR Query" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var aur_client = try AUR.Client.init(alloc);
    defer aur_client.deinit();
    const json_res = try aur_client.search("balatro", .NameDesc);
    defer json_res.deinit();
    const res = json_res.value;

    for (res.results) |result| {
        std.debug.print(
            "Name => {s}\nDesc => {s}\n\n",
            .{
                result.Name,
                result.Description orelse "No description provided.",
            },
        );
    }
}

test "Sync Mirrors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const repos = [_][]const u8{ "core", "multilib", "extra" };

    var db = try Db.init(alloc, PKG_DB);
    defer db.deinit();

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    for (repos) |repo| {
        try db.sync(
            &mirrors,
            "./tests/",
            repo,
            "x86_64",
            50_000,
            &cb,
        );
    }
}

test "Package Install" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try Db.init(alloc, PKG_DB);
    defer db.deinit();

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    const pkg_name: []const u8 = "tree";
    const repo: ?[]const u8 = "extra";

    const txn = try mdb.startTxn();

    var pkg: ?Pkg = null;
    defer if (pkg) |p| alloc.free(p);
    if (repo) |r| {
        const key = mdb.makeKey(alloc, r, pkg_name);
        defer alloc.free(key);
        pkg = try db.queryPkg(alloc, txn, key);
    } else {
        const pkgs = try db.queryLkpRepo(
            txn,
            db.pkg_lkp,
            "tree",
        );
        defer alloc.free(pkgs);
        if (pkgs.len > 1) {
            @panic("TODO: Handle more than 1 pkg");
        }

        pkg = try db.queryPkg(alloc, txn, pkgs[0]);
    }

    if (pkg) |p|
        try db.install(
            &mirrors,
            p,
            pkg,
            txn,
            "./tests",
            &cb,
        );
    try mdb.endTxn(txn);
}
