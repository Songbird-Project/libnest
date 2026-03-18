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
    const delim = std.mem.indexOfScalar(u8, key, '@');
    const repo: []const u8 = if (delim) |d| key[d + 1 ..] else "aur";

    const pkg = try parse(alloc, repo, path);
    defer pkg.deinit(alloc);

    try mdb.insertJSON(
        alloc,
        txn,
        db.installed_db,
        key,
        pkg,
    );

    for (pkg.provides) |p| {
        try mdb.insertRaw(
            txn,
            db.virt_installed_db,
            p,
            key,
        );
    }
}

pub fn parse(alloc: std.mem.Allocator, repo: []const u8, path: []const u8) !Pkg.Installed {
    const pkginfo = try std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(pkginfo);

    var fields = std.StringHashMap([][]const u8).init(alloc);
    defer {
        var it = fields.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
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
            const key = std.mem.trim(u8, trimmed[0..eql], " \t\r");
            const val = std.mem.trim(u8, trimmed[eql + 1 ..], " \t\r");

            var parts = std.mem.splitScalar(u8, val, ',');
            while (parts.next()) |p| {
                try current_values.append(alloc, std.mem.trim(u8, p, " \t\r"));
            }

            if (fields.getPtr(key)) |existing_values| {
                const old_slice = existing_values.*;
                const new_slice = try alloc.alloc([]const u8, old_slice.len + current_values.items.len);

                @memcpy(new_slice[0..old_slice.len], old_slice);
                @memcpy(new_slice[old_slice.len..], current_values.items);

                alloc.free(old_slice); // Free the old slice container
                existing_values.* = new_slice;
                current_values.clearRetainingCapacity();
            } else {
                try fields.put(
                    try alloc.dupe(u8, key),
                    try current_values.toOwnedSlice(alloc),
                );
            }
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
        .repo = try alloc.dupe(u8, repo),
        .version = try alloc.dupe(u8, get(fields, "pkgver")),
        .description = try alloc.dupe(u8, get(fields, "pkgdesc")),
        .url = try alloc.dupe(u8, get(fields, "url")),
        .arch = try alloc.dupe(u8, get(fields, "arch")),
        .packager = try alloc.dupe(u8, get(fields, "packager")),
        .build_date = try std.fmt.parseInt(i64, get(fields, "builddate"), 10),
        .size = try std.fmt.parseInt(i64, get(fields, "size"), 10),
        .license = try deepDupe(alloc, fields.get("license") orelse &.{}),
        .conflicts = try deepDupe(alloc, fields.get("conflicts") orelse &.{}),
        .provides = try deepDupe(alloc, fields.get("provides") orelse &.{}),
        .deps = try deepDupe(alloc, fields.get("depend") orelse &.{}),
        .mkdeps = try deepDupe(alloc, fields.get("makedepend") orelse &.{}),
        .optdeps = try deepDupe(alloc, fields.get("optdepend") orelse &.{}),
        .checkdeps = try deepDupe(alloc, fields.get("checkdepend") orelse &.{}),
    };
}
