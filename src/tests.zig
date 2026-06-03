const std = @import("std");
const version = @import("core/version.zig");

const Pkg = @import("core/Package.zig");
const MirrorList = @import("net/MirrorList.zig");
const Downloader = @import("net/Downloader.zig");
const Dep = @import("core/Dependency.zig");
const Db = @import("core/Database.zig");
const AUR = struct {
    const Client = @import("aur/Client.zig");
    const Builder = @import("aur/Builder.zig");
};

const PREFIX: []const u8 = "./tests";
const MIRRORS: []const u8 = "./tests/mirrors";
const ARCH: []const u8 = "x86_64";

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
    const json_res = try aur_client.search("trashy", .NameDesc);
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

test "AUR Build" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var aur_client = try AUR.Client.init(alloc);
    defer aur_client.deinit();
    const json_res = try aur_client.search("trashy", .NameDesc);
    defer json_res.deinit();
    const res = json_res.value;

    var b = try AUR.Builder.init(
        alloc,
        "/home/dds/Desktop/Projects/Zig/libs/libnest/scripts/makepkg",
    );
    defer b.deinit();

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    var db = try Db.init(
        alloc,
        "/home/dds/Desktop/Projects/Zig/nest/tests",
        ARCH,
    );
    defer db.deinit();
    db.download_cb = &cb;

    for (res.results) |result| {
        if (std.mem.eql(u8, result.Name, "trashy")) try b.build(
            &db,
            &mirrors,
            "/home/dds/Desktop/Projects/Zig/nest/tests",
            result,
            true,
        );
    }
}

test "Sync Databases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const repos = [_][]const u8{ "core", "multilib", "extra" };

    var db = try Db.init(
        alloc,
        PREFIX,
        ARCH,
    );
    defer db.deinit();
    db.download_cb = &cb;

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    for (repos) |repo| {
        try db.sync(
            &mirrors,
            PREFIX,
            repo,
            50_000,
        );
    }
}

test "Package Install" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try Db.init(
        alloc,
        PREFIX,
        ARCH,
    );
    defer db.deinit();
    db.download_cb = &cb;

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    const pkg_name: []const u8 = "cargo";

    const pkgs = try db.queryPkg(
        Pkg,
        pkg_name,
    );
    defer {
        for (pkgs) |pkg| {
            pkg.deinit();
        }
        alloc.free(pkgs);
    }

    const pkg = pkgs[0].value;

    var installed = std.StringHashMap(void).init(db.alloc);
    defer {
        var it = installed.keyIterator();
        while (it.next()) |k| {
            db.alloc.free(k.*);
        }
        installed.deinit();
    }

    try db.installWithDeps(
        &mirrors,
        pkg,
        &installed,
        PREFIX,
    );
}
