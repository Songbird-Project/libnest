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

fn installWithDeps(
    alloc: std.mem.Allocator,
    db: *Db,
    mirrors: *MirrorList,
    pkg: Pkg,
    installed: *std.StringHashMap(void),
    prefix: ?[]const u8,
    download_cb: ?*const Downloader.callback,
) !void {
    for (pkg.deps) |d| {
        const dep = Dep.parse(d);
        if (installed.contains(dep.name)) continue;

        const pkgs = try db.queryPkg(Pkg, dep.name);
        defer {
            for (pkgs) |p| {
                p.deinit();
            }
            db.alloc.free(pkgs);
        }
        const p = pkgs[0].value;

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

        try installed.put(try alloc.dupe(u8, dep.name), {});
        try installWithDeps(
            alloc,
            db,
            mirrors,
            p,
            installed,
            prefix,
            download_cb,
        );
    }

    db.install(
        mirrors,
        pkg,
        prefix,
        download_cb,
    ) catch |err| switch (err) {
        error.AlreadyInstalled => {},
        else => return err,
    };
}

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

    var db = try Db.init(
        alloc,
        "/home/dds/Desktop/Projects/Zig/nest/tests",
        "x86_64",
    );
    defer db.deinit();

    for (res.results) |result| {
        if (std.mem.eql(u8, result.Name, "trashy")) try b.build(
            &db,
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

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    for (repos) |repo| {
        try db.sync(
            &mirrors,
            PREFIX,
            repo,
            50_000,
            &cb,
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

    try installWithDeps(
        alloc,
        &db,
        &mirrors,
        pkg,
        &installed,
        PREFIX,
        &cb,
    );
}
