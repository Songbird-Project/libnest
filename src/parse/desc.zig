const std = @import("std");
const Db = @import("../core/Database.zig");
const Pkg = @import("../core/Package.zig");

const mdb = @import("../utils/mdb.zig");

pub fn index(
    alloc: std.mem.Allocator,
    db: *Db,
    txn: *mdb.c.MDB_txn,
    desc: []const u8,
    repo: []const u8,
) !void {
    const pkg = try parse(alloc, desc);

    const key = try mdb.makeKey(
        alloc,
        repo,
        pkg.name,
    );
    defer alloc.free(key);
    try mdb.insert(
        alloc,
        txn,
        db.pkgs_db,
        key,
        pkg,
    );
}

pub fn parse(alloc: std.mem.Allocator, src: []const u8) !Pkg {
    var lines = std.mem.splitScalar(u8, src, '\n');
    var fields = std.StringHashMap([][]const u8).init(alloc);
    defer {
        defer {
            var it = fields.keyIterator();
            while (it.next()) |key| alloc.free(key.*);
            it = fields.valueIterator();
            while (it.next()) |value| alloc.free(value.*);

            fields.deinit();
        }
    }

    var current_field: ?[]const u8 = null;
    var current_values: std.ArrayList([]const u8) = .empty;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        if (trimmed.len > 2 and trimmed[0] == '%' and trimmed[trimmed.len - 1] == '%') {
            if (current_field) |name| {
                try fields.put(name, try current_values.toOwnedSlice(alloc));
            }
            current_field = try alloc.dupe(u8, trimmed[1 .. trimmed.len - 1]);
        } else if (current_field != null) {
            try current_values.append(alloc, try alloc.dupe(u8, trimmed));
        }
    }
    if (current_field) |name| try fields.put(name, try current_values.toOwnedSlice(alloc));

    const getS = struct {
        fn f(m: anytype, k: []const u8) []const u8 {
            return if (m.get(k)) |v| (if (v.len > 0) v[0] else "") else "";
        }
    }.f;

    return Pkg{
        .name = getS(fields, "NAME"),
        .version = getS(fields, "VERSION"),
        .description = getS(fields, "DESC"),
        .build_date = try std.fmt.parseInt(i64, getS(fields, "BUILDDATE"), 10),
        .arch = getS(fields, "ARCH"),
        .license = fields.get("LICENSE") orelse &.{},
        .filename = getS(fields, "FILENAME"),
        .packager = getS(fields, "PACKAGER"),
        .checksum = getS(fields, "SHA256SUM"),
        .signature = getS(fields, "PGPSIG"),
        .replaces = fields.get("REPLACES") orelse &.{},
        .conflicts = fields.get("CONFLICTS") orelse &.{},
        .provides = fields.get("PROVIDES") orelse &.{},
        .deps = fields.get("DEPENDS") orelse &.{},
        .mkdeps = fields.get("MAKEDEPENDS") orelse &.{},
        .optdeps = fields.get("OPTDEPENDS") orelse &.{},
        .checkdeps = fields.get("CHECKDEPENDS") orelse &.{},
    };
}
