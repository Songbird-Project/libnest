const std = @import("std");
const mdb = @import("../utils/mdb.zig");

const Db = @import("../core/Database.zig");
const Pkg = @import("../core/Package.zig");

pub fn index(
    alloc: std.mem.Allocator,
    db: *Db,
    txn: *mdb.c.MDB_txn,
    key: []const u8,
    path: []const u8,
) !void {
    const pkg = try parse(alloc, path);
    defer pkg.deinit(alloc);

    try mdb.insert(
        alloc,
        txn,
        db.installed_db,
        key,
        pkg,
    );
}

pub fn parse(alloc: std.mem.Allocator, path: []const u8) !Pkg.Installed {
    const pkginfo = try std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(pkginfo);

    var fields = std.StringHashMap([][]const u8).init(alloc);
    defer {
        var it = fields.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |str| alloc.free(str);
            alloc.free(entry.value_ptr.*);
        }
        fields.deinit();
    }

    var lines = std.mem.splitScalar(u8, pkginfo, '\n');
    var current_values: std.ArrayList([]const u8) = .empty;
    defer current_values.deinit(alloc);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eql| {
            const key = std.mem.trim(
                u8,
                trimmed[0..eql],
                " \t\r",
            );
            const val = std.mem.trim(
                u8,
                trimmed[eql + 1 ..],
                " \t\r",
            );

            var parts = std.mem.splitScalar(u8, val, ',');
            while (parts.next()) |p| {
                try current_values.append(alloc, try alloc.dupe(u8, std.mem.trim(
                    u8,
                    p,
                    " \t\r",
                )));
            }

            try fields.put(
                try alloc.dupe(u8, key),
                try current_values.toOwnedSlice(alloc),
            );
        }
    }

    const get = struct {
        fn f(m: anytype, k: []const u8) []const u8 {
            return if (m.get(k)) |v| (if (v.len > 0) v[0] else "") else "";
        }
    }.f;

    const deepDupe = struct {
        fn f(a: std.mem.Allocator, slices: [][]const u8) ![][]const u8 {
            const new_slices = try a.alloc([]const u8, slices.len);
            for (slices, 0..) |slice, i| {
                new_slices[i] = try a.dupe(u8, slice);
            }
            return new_slices;
        }
    }.f;

    return Pkg.Installed{
        .name = try alloc.dupe(u8, get(fields, "pkgname")),
        .version = try alloc.dupe(u8, get(fields, "pkgver")),
        .description = try alloc.dupe(u8, get(fields, "pkgdesc")),
        .url = try alloc.dupe(u8, get(fields, "url")),
        .arch = try alloc.dupe(u8, get(fields, "arch")),
        .packager = try alloc.dupe(u8, get(fields, "packager")),
        .build_date = try std.fmt.parseInt(i64, get(fields, "builddate"), 10),
        .size = try std.fmt.parseInt(i64, get(fields, "size"), 10),
        .license = try deepDupe(alloc, fields.get("license") orelse &.{}),
        .deps = try deepDupe(alloc, fields.get("depend") orelse &.{}),
        .optdeps = try deepDupe(alloc, fields.get("optdepend") orelse &.{}),
    };
}
