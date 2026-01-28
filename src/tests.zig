const std = @import("std");

const Downloader = @import("net/Downloader.zig");
const MirrorList = @import("net/MirrorList.zig");
const Pkg = @import("core/Package.zig");
const Db = @import("core/Database.zig");

const desc = @import("parse/desc.zig");

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

    var db = try Db.init(alloc, PKG_DB, true);
    defer db.deinit();

    try db.sync(
        MIRRORS,
        "./tests/",
        &[_][]const u8{"core"},
        "x86_64",
        &cb,
    );
}

test "Package Download" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try Db.init(alloc, PKG_DB, false);
    defer db.deinit();

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    try mirrors.downloadPkg(
        &db,
        "binutils",
        "core",
        "./tests/binutils.pkg.tar.zst",
        &cb,
    );
}
