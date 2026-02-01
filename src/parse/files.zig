const std = @import("std");

const Db = @import("../core/Database.zig");

pub const inputKind = enum {
    Path,
    Buf,
};

pub fn index(
    alloc: std.mem.Allocator,
    // db: *Db,
    desc: []const u8,
    id: usize,
    kind: inputKind,
    stmt: anytype,
) !void {
    const files: [][]const u8 = if (kind == .Path)
        try parse(alloc, desc)
    else
        try parseString(alloc, desc);
    defer {
        for (files) |file| alloc.free(file);
        alloc.free(files);
    }

    // const query =
    //     \\INSERT INTO files(
    //     \\ path,
    //     \\ package_id
    //     \\) VALUES(?,?)
    //     // \\ON CONFLICT(package_id, path) DO NOTHING
    // ;
    //
    // var stmt = try db.sqlite_db.prepare(query);
    // defer stmt.deinit();

    for (files) |file| {
        stmt.reset();
        try stmt.exec(.{}, .{
            .path = file,
            .package_id = id,
        });
    }
}

pub fn parse(alloc: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var file_buffer: [1024]u8 = undefined;
    var file = (try std.fs.cwd().openFile(
        path,
        .{ .mode = .read_only },
    ));
    defer file.close();
    var file_reader = file.reader(&file_buffer);
    var reader = &file_reader.interface;

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(alloc);

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

        if (trimmed_line.len == 0) continue;
        if (std.mem.eql(u8, trimmed_line, "%FILES%")) continue;

        try files.append(alloc, try alloc.dupe(u8, trimmed_line));

        _ = reader.toss(1);
        line.clearRetainingCapacity();
    }

    if (line.written().len > 0) {
        const trimmed_line = std.mem.trim(
            u8,
            line.written(),
            " \r\t",
        );

        try files.append(alloc, try alloc.dupe(u8, trimmed_line));

        _ = reader.toss(1);
        line.clearRetainingCapacity();
    }

    return files.toOwnedSlice(alloc);
}

pub fn parseString(alloc: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(alloc);

    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(
            u8,
            line,
            " \r\t",
        );
        if (trimmed_line.len == 0) continue;
        if (std.mem.eql(u8, trimmed_line, "%FILES%")) continue;

        try files.append(alloc, try alloc.dupe(u8, trimmed_line));
    }

    return try files.toOwnedSlice(alloc);
}
