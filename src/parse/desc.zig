const std = @import("std");
const Db = @import("../core/Database.zig");
const Pkg = @import("../core/Package.zig");

pub fn index(
    alloc: std.mem.Allocator,
    db: *Db,
    txn: *Db.c.MDB_txn,
    desc: []const u8,
    repo: []const u8,
) !void {
    var fields: std.StringHashMap([]const u8) = try parse(alloc, desc);
    defer {
        var it = fields.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        it = fields.valueIterator();
        while (it.next()) |value| alloc.free(value.*);

        fields.deinit();
    }

    const pkg: Pkg = .{
        .build_date = try std.fmt.parseInt(i64, fields.get("BUILDDATE") orelse unreachable, 10),
        .version = fields.get("VERSION") orelse unreachable,
        .description = fields.get("DESC") orelse unreachable,
        .arch = fields.get("ARCH") orelse unreachable,
        .license = fields.get("LICENSE") orelse unreachable,
        .filename = fields.get("FILENAME") orelse unreachable,
        .packager = fields.get("PACKAGER") orelse unreachable,
        .checksum = fields.get("SHA256SUM") orelse unreachable,
        .signature = fields.get("PGPSIG") orelse unreachable,
        .replaces = fields.get("REPLACES") orelse "[]",
        .conflicts = fields.get("CONFLICTS") orelse "[]",
        .provides = fields.get("PROVIDES") orelse "[]",
        .deps = fields.get("DEPENDS") orelse "[]",
        .mkdeps = fields.get("MAKEDEPENDS") orelse "[]",
        .optdeps = fields.get("OPTDEPENDS") orelse "[]",
        .checkdeps = fields.get("CHECKDEPENDS") orelse "[]",
    };

    const key = Db.makeKey(
        alloc,
        repo,
        fields.get("NAME") orelse unreachable,
    );
    defer alloc.free(key);
    try Db.insertPkg(
        alloc,
        txn,
        db.pkgs_db,
        repo,
        fields.get("NAME") orelse unreachable,
        pkg,
    );
    try Db.insert(
        txn,
        db.pkg_lkp,
        fields.get("NAME") orelse unreachable,
        key,
    );
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

    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(
            u8,
            line,
            " \r\t",
        );

        if (trimmed_line.len > 0) {
            if (trimmed_line.len > 2 and trimmed_line[0] == '%' and trimmed_line[trimmed_line.len - 1] == '%') {
                if (current_field) |field| {
                    if (current_value.items.len > 0) {
                        if (current_value.items[0] == '[') {
                            try current_value.insert(alloc, current_value.items.len - 1, ']');
                            _ = current_value.pop();
                        }
                    }

                    try fields.put(
                        field,
                        try current_value.toOwnedSlice(alloc),
                    );
                    current_value.clearRetainingCapacity();
                }

                current_field = null;
                current_field = try alloc.dupe(u8, trimmed_line[1 .. trimmed_line.len - 1]);
            } else if (current_field) |_| {
                if (current_value.items.len > 0) {
                    if (current_value.items[0] != '[')
                        try current_value.insert(alloc, 0, '[');

                    try current_value.append(alloc, ',');
                }

                try current_value.appendSlice(alloc, trimmed_line);
            }
        }
    }

    if (current_field) |field| {
        if (current_value.items[0] == '[') {
            try current_value.insert(alloc, current_value.items.len - 1, ']');
            _ = current_value.pop();
        }

        try fields.put(
            field,
            try current_value.toOwnedSlice(alloc),
        );
        current_value.clearRetainingCapacity();
    }

    return fields;
}
