const std = @import("std");
const Db = @import("../core/Database.zig");
const Pkg = @import("../core/Package.zig");

pub fn index(
    alloc: std.mem.Allocator,
    db: *Db,
    txn: *Db.c.MDB_txn,
    key: Db.c.MDB_val,
    desc: []const u8,
) ![]const u8 {
    var fields: std.StringHashMap([]const u8) = try parse(alloc, desc);
    defer {
        var it = fields.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        it = fields.valueIterator();
        while (it.next()) |value| alloc.free(value.*);

        fields.deinit();
    }

    const pkg: Pkg.Installed = .{
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

    try Db.insertInstalledPkg(
        alloc,
        txn,
        db.installed_db,
        key,
        pkg,
    );

    return key;
}

pub fn parse(alloc: std.mem.Allocator, src: []const u8) !std.StringHashMap([]const u8) {
    var lines = std.mem.splitScalar(u8, src, '\n');

    var current_field: ?[]const u8 = null;
    var fields: std.StringHashMap([]const u8) = .init(alloc);
    errdefer {
        if (current_field) |field| alloc.free(field);
        var it = fields.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        it = fields.valueIterator();
        while (it.next()) |value| alloc.free(value.*);

        fields.deinit();
    }

    var current_value: std.ArrayList(u8) = .empty;
    defer current_value.deinit(alloc);
    var json_value: std.io.Writer.Allocating = .init(alloc);
    defer json_value.deinit();

    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(
            u8,
            line,
            " \r\t",
        );

        if (trimmed_line.len <= 0) continue;
        if (trimmed_line[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed_line, '=')) |eql| {
            if (current_field == null) {
                current_field = try alloc.dupe(u8, trimmed_line[0..eql]);
            } else if (current_field) |field| {
                if (!std.mem.eql(u8, trimmed_line[0..eql], field)) {
                    try std.json.fmt(current_value.items, .{}).format(json_value);

                    try fields.put(
                        field,
                        json_value.written(),
                    );

                    json_value.clearRetainingCapacity();
                    current_value.clearRetainingCapacity();

                    current_field = null;
                    current_field = try alloc.dupe(u8, trimmed_line[0..eql]);
                } else {
                    try current_value.appendSlice(alloc, trimmed_line);
                }
            }
        }
    }

    if (current_field) |field| {
        try std.json.fmt(current_value.items, .{}).format(json_value);

        try fields.put(
            field,
            json_value.written(),
        );

        json_value.clearRetainingCapacity();
        current_value.clearRetainingCapacity();
    }

    return fields;
}
