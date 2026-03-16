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
    var fields: std.StringHashMap([]const u8) = try parse(alloc, path);
    defer {
        var it = fields.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        it = fields.valueIterator();
        while (it.next()) |value| alloc.free(value.*);

        fields.deinit();
    }

    const pkg: Pkg.Installed = .{
        .name = fields.get("name") orelse unreachable,
        .build_date = try std.fmt.parseInt(i64, fields.get("builddate") orelse unreachable, 10),
        .size = try std.fmt.parseInt(i64, fields.get("size") orelse unreachable, 10),
        .version = fields.get("pkgver") orelse unreachable,
        .description = fields.get("pkgdesc") orelse unreachable,
        .url = fields.get("url") orelse unreachable,
        .arch = fields.get("arch") orelse unreachable,
        .license = fields.get("license") orelse unreachable,
        .packager = fields.get("packager") orelse unreachable,
        .deps = fields.get("depend") orelse "[]",
        .optdeps = fields.get("optdepend") orelse "[]",
    };

    try mdb.insert(
        alloc,
        txn,
        db.installed_db,
        key,
        pkg,
    );
}

pub fn parse(alloc: std.mem.Allocator, path: []const u8) !std.StringHashMap([]const u8) {
    const pkginfo = try std.fs.cwd().readFileAlloc(
        alloc,
        path,
        1024 * 1024,
    );
    defer alloc.free(pkginfo);
    var lines = std.mem.splitScalar(u8, pkginfo, '\n');

    var fields: std.StringHashMap([]const u8) = .init(alloc);
    errdefer {
        var it = fields.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        it = fields.valueIterator();
        while (it.next()) |value| alloc.free(value.*);

        fields.deinit();
    }

    var current_value: std.ArrayList(u8) = .empty;
    defer current_value.deinit(alloc);

    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(
            u8,
            line,
            " \r\t",
        );

        if (trimmed_line.len <= 0) continue;
        if (trimmed_line[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed_line, '=')) |eql| {
            const raw_key = trimmed_line[0..eql];
            const raw_val = trimmed_line[eql + 1 ..];

            const key = std.mem.trim(
                u8,
                raw_key,
                " \t\r",
            );
            var val = std.mem.trim(
                u8,
                raw_val,
                " \t\r",
            );

            if (std.mem.indexOfScalar(u8, val, ',') != null or
                std.mem.eql(u8, "depend", key) or
                std.mem.eql(u8, "optdepend", key))
            {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(alloc);

                try buf.append(alloc, '[');

                var first = true;
                var parts = std.mem.splitScalar(
                    u8,
                    val,
                    ',',
                );
                while (parts.next()) |p| {
                    const trimmed = std.mem.trim(
                        u8,
                        p,
                        " \t\r",
                    );
                    if (!first) try buf.append(alloc, ',');

                    try buf.append(alloc, '"');
                    try buf.appendSlice(alloc, trimmed);
                    try buf.append(alloc, '"');

                    first = false;
                }

                try buf.append(alloc, ']');

                val = try buf.toOwnedSlice(alloc);
            }

            try fields.put(
                try alloc.dupe(u8, key),
                try alloc.dupe(u8, val),
            );
        }
    }

    return fields;
}
