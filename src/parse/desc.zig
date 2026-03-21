const std = @import("std");
const Db = @import("../core/Database.zig");
const Pkg = @import("../core/Package.zig");

const mdb = @import("../utils/mdb.zig");

pub fn index(
    alloc: std.mem.Allocator,
    db: *Db,
    desc: []const u8,
    repo: []const u8,
    stmt: anytype,
) !void {
    const pkg = try parse(alloc, repo, desc);
    defer pkg.deinit(alloc);

    _ = try db.insertPkg(
        repo,
        pkg,
        stmt,
    );
}

pub fn parse(alloc: std.mem.Allocator, repo: []const u8, src: []const u8) !Pkg {
    var lines = std.mem.splitScalar(u8, src, '\n');
    var fields = std.StringHashMap([][]const u8).init(alloc);

    defer {
        var it = fields.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |str| {
                alloc.free(str);
            }
            alloc.free(entry.value_ptr.*);
        }
        fields.deinit();
    }

    var current_field: ?[]const u8 = null;
    var current_values: std.ArrayList([]const u8) = .empty;
    defer current_values.deinit(alloc);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(
            u8,
            line,
            " \r\t",
        );
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
    if (current_field) |name| try fields.put(
        name,
        try current_values.toOwnedSlice(alloc),
    );

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

    return Pkg{
        .name = try alloc.dupe(u8, get(fields, "NAME")),
        .repo = try alloc.dupe(u8, repo),
        .version = try alloc.dupe(u8, get(fields, "VERSION")),
        .description = try alloc.dupe(u8, get(fields, "DESC")),
        .build_date = try std.fmt.parseInt(i64, get(fields, "BUILDDATE"), 10),
        .arch = try alloc.dupe(u8, get(fields, "ARCH")),
        .license = try deepDupe(alloc, fields.get("LICENSE") orelse &.{}),
        .filename = try alloc.dupe(u8, get(fields, "FILENAME")),
        .packager = try alloc.dupe(u8, get(fields, "PACKAGER")),
        .checksum = try alloc.dupe(u8, get(fields, "SHA256SUM")),
        .signature = try alloc.dupe(u8, get(fields, "PGPSIG")),
        .replaces = try deepDupe(alloc, fields.get("REPLACES") orelse &.{}),
        .conflicts = try deepDupe(alloc, fields.get("CONFLICTS") orelse &.{}),
        .provides = try deepDupe(alloc, fields.get("PROVIDES") orelse &.{}),
        .deps = try deepDupe(alloc, fields.get("DEPENDS") orelse &.{}),
        .mkdeps = try deepDupe(alloc, fields.get("MAKEDEPENDS") orelse &.{}),
        .optdeps = try deepDupe(alloc, fields.get("OPTDEPENDS") orelse &.{}),
        .checkdeps = try deepDupe(alloc, fields.get("CHECKDEPENDS") orelse &.{}),
    };
}
