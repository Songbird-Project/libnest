const std = @import("std");
const mdb = @import("utils/mdb.zig");

const Pkg = @import("core/Package.zig");
const MirrorList = @import("net/MirrorList.zig");
const Db = @import("core/Database.zig");
const AUR = struct {
    const Client = @import("aur/Client.zig");
    const Builder = @import("aur/Builder.zig");
};

const PREFIX: []const u8 = "./tests";
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

    var b = try AUR.Builder.init(alloc);
    defer b.deinit();

    for (res.results) |result| {
        if (std.mem.eql(u8, result.Name, "trashy")) try b.build("tests", result);
    }
}

test "Sync Mirrors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const repos = [_][]const u8{ "core", "multilib", "extra" };

    var db = try Db.init(alloc, PREFIX);
    defer db.deinit();

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    for (repos) |repo| {
        try db.sync(
            &mirrors,
            PREFIX,
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

    var db = try Db.init(alloc, PREFIX);
    defer db.deinit();

    var mirrors = try MirrorList.init(alloc, MIRRORS);
    defer mirrors.deinit();

    const pkg_name: []const u8 = "gcc-libs";

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

    try db.install(
        &mirrors,
        pkg,
        PREFIX,
        &cb,
    );
}
