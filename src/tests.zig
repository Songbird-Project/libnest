const std = @import("std");

const Downloader = @import("net/Downloader.zig");
const MirrorList = @import("net/MirrorList.zig");
const Pkg = @import("core/Package.zig");
const Db = @import("core/Database.zig");

const desc = @import("parse/desc.zig");

fn cb(dlnow: f64, dltotal: f64) !void {
    const bar_width: usize = 10;
    const filled: u8 = @min(bar_width, @as(u8, @intFromFloat((dlnow / dltotal) * 10)));

    var bar: [bar_width]u8 = undefined;
    @memset(bar[0..filled], '#');
    @memset(bar[filled..], ' ');

    std.debug.print("\r[{s}]", .{bar});
}

test "Package Download" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try Db.init(alloc, "./tests/core.db");
    defer db.deinit();

    var mirrors = try MirrorList.init(alloc, "./tests/mirrors");
    defer mirrors.deinit();

    try mirrors.downloadPkg(
        &db,
        "binutils",
        "core",
        "./tests/binutils.pkg.tar.zst",
        &cb,
    );
}

test "Sync Mirrors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try Db.init(alloc, "./tests/core.db");
    defer db.deinit();

    try db.sync(
        "./tests/mirrors",
        "./tests/core.arch.db",
        "core",
        "x86_64",
        &cb,
    );
}

test "DB Indexing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try Db.init(alloc, "./tests/core.db");
    defer db.deinit();

    try desc.index(alloc, &db, "./tests/desc", "core");
}
