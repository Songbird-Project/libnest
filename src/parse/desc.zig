const std = @import("std");

const Db = @import("../core/Database.zig");

pub const inputKind = enum {
    Path,
    Buf,
};

pub fn index(alloc: std.mem.Allocator, db: *Db, desc: []const u8, repo: []const u8, kind: inputKind) ![]const u8 {
    var fields: std.StringHashMap([]const u8) = if (kind == .Path)
        try parse(alloc, desc)
    else
        try parseString(alloc, desc);

    defer {
        var it = fields.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        it = fields.valueIterator();
        while (it.next()) |value| alloc.free(value.*);

        fields.deinit();
    }

    const query =
        \\INSERT INTO packages(
        \\ name,
        \\ repo,
        \\ version,
        \\ description,
        \\ arch,
        \\ license,
        \\ filename,
        \\ packager,
        \\ build_date,
        \\ checksum,
        \\ signature,
        \\ replaces,
        \\ conflicts,
        \\ provides,
        \\ deps,
        \\ mkdeps,
        \\ optdeps,
        \\ checkdeps
        \\) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        \\ON CONFLICT(name, repo) DO UPDATE SET
        \\ version = excluded.version,
        \\ description = excluded.description,
        \\ arch = excluded.arch,
        \\ license = excluded.license,
        \\ filename = excluded.filename,
        \\ packager = excluded.packager,
        \\ build_date = excluded.build_date,
        \\ checksum = excluded.checksum,
        \\ signature = excluded.signature,
        \\ replaces = excluded.replaces,
        \\ conflicts = excluded.conflicts,
        \\ provides = excluded.provides,
        \\ deps = excluded.deps,
        \\ mkdeps = excluded.mkdeps,
        \\ optdeps = excluded.optdeps,
        \\ checkdeps = excluded.checkdeps
        \\WHERE packages.version != excluded.version
    ;

    var stmt = try db.sqlite_db.prepare(query);
    defer stmt.deinit();

    try stmt.exec(.{}, .{
        .name = fields.get("NAME") orelse unreachable,
        .repo = repo,
        .version = fields.get("VERSION") orelse unreachable,
        .description = fields.get("DESC") orelse unreachable,
        .arch = fields.get("ARCH") orelse unreachable,
        .license = fields.get("LICENSE") orelse unreachable,
        .filename = fields.get("FILENAME") orelse unreachable,
        .packager = fields.get("PACKAGER") orelse unreachable,
        .build_date = try std.fmt.parseInt(i64, fields.get("BUILDDATE") orelse unreachable, 10),
        .checksum = fields.get("SHA256SUM") orelse unreachable,
        .signature = fields.get("PGPSIG") orelse unreachable,
        .replaces = fields.get("REPLACES") orelse "[]",
        .conflicts = fields.get("CONFLICTS") orelse "[]",
        .provides = fields.get("PROVIDES") orelse "[]",
        .deps = fields.get("DEPENDS") orelse "[]",
        .mkdeps = fields.get("MAKEDEPENDS") orelse "[]",
        .optdeps = fields.get("OPTDEPENDS") orelse "[]",
        .checkdeps = fields.get("CHECKDEPENDS") orelse "[]",
    });

    const ret_delim = std.mem.lastIndexOfScalar(
        u8,
        fields.get("FILENAME") orelse unreachable,
        '-',
    ).?;
    return try alloc.dupe(u8, (fields.get("FILENAME") orelse unreachable)[0..ret_delim]);
}

pub fn parse(alloc: std.mem.Allocator, path: []const u8) !std.StringHashMap([]const u8) {
    var file_buffer: [1024]u8 = undefined;
    var file = (try std.fs.cwd().openFile(
        path,
        .{ .mode = .read_only },
    ));
    defer file.close();
    var file_reader = file.reader(&file_buffer);
    var reader = &file_reader.interface;

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

    var line: std.io.Writer.Allocating = .init(alloc);
    defer line.deinit();

    while (true) {
        _ = reader.streamDelimiter(&line.writer, '\n') catch |err| {
            if (err == error.EndOfStream) break else return err;
        };

        const trimmed_line = std.mem.trim(
            u8,
            line.written(),
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

        _ = reader.toss(1);
        line.clearRetainingCapacity();
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

pub fn parseString(alloc: std.mem.Allocator, src: []const u8) !std.StringHashMap([]const u8) {
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
