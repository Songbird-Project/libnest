const std = @import("std");
const Io = std.Io;
const Context = @import("../core/context.zig").Context;
const store = @import("../store/store.zig");
const ingest = @import("../store/ingest.zig");
pub const c = @import("archive_c");

pub const ArchiveError = error{
    UnableToCreateReader,
    UnableToCreateWriter,
    WriteHeaderFailed,
    WriteFailed,
    OpenFailed,
    ReadFailed,
};

pub fn ingestFile(context: Context, reader: *Reader, path: []const u8, mode: u32) !ingest.IngestResult {
    var src: std.Random.IoSource = .{ .io = context.io };
    const rand = src.interface();

    const tmp_name = try std.fmt.allocPrint(context.alloc, ".tmp-{d}", .{rand.int(u64)});
    defer context.alloc.free(tmp_name);
    const tmp_path = try Io.Dir.path.join(context.alloc, &.{
        context.path_options.root,
        context.path_options.store,
        tmp_name,
    });
    defer context.alloc.free(tmp_path);
    errdefer Io.Dir.cwd().deleteFile(context.io, tmp_path) catch {};

    try Io.Dir.cwd().createDirPath(context.io, Io.Dir.path.dirname(tmp_path).?);
    const tmp_file = try Io.Dir.cwd().createFile(context.io, tmp_path, .{});
    defer tmp_file.close(context.io);
    var tmp_buf: [4096]u8 = undefined;
    var tmp_writer = tmp_file.writer(context.io, &tmp_buf);
    const writer = &tmp_writer.interface;

    var hasher: std.crypto.hash.Blake3 = .init(.{});
    var total_bytes: usize = 0;

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes = try reader.readData(&buf);
        if (bytes <= 0) break;
        hasher.update(buf[0..bytes]);
        try writer.writeAll(buf[0..bytes]);
        total_bytes += bytes;
    }

    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    const blob_path = try store.objectPath(context, hash);
    defer context.alloc.free(blob_path);

    var found = true;
    Io.Dir.cwd().access(context.io, blob_path, .{}) catch |e| switch (e) {
        error.FileNotFound => found = false,
        else => return e,
    };
    if (found) {
        try Io.Dir.cwd().deleteFile(context.io, tmp_path);
    } else {
        try Io.Dir.cwd().createDirPath(context.io, Io.Dir.path.dirname(blob_path).?);
        try Io.Dir.cwd().rename(
            tmp_path,
            .cwd(),
            blob_path,
            context.io,
        );
    }

    return .{
        .kind = .file,
        .path = path,
        .hash = hash,
        .size = total_bytes,
        .mode = mode,
    };
}

pub const Reader = struct {
    archive: *c.struct_archive,

    pub fn init() ArchiveError!Reader {
        const archive = c.archive_read_new() orelse
            return error.UnableToCreateReader;

        _ = c.archive_read_support_format_tar(archive);
        _ = c.archive_read_support_format_mtree(archive);
        _ = c.archive_read_support_filter_all(archive);

        return .{ .archive = archive };
    }

    pub fn deinit(self: *Reader) void {
        _ = c.archive_read_close(self.archive);
        _ = c.archive_read_free(self.archive);
    }

    pub fn openFd(self: *Reader, fd: std.Io.File.Handle) !void {
        if (c.archive_read_open_fd(self.archive, fd, 8192) != c.ARCHIVE_OK)
            return error.OpenFailed;
    }

    pub fn nextEntry(self: *Reader) !?*c.archive_entry {
        var entry: ?*c.archive_entry = null;
        const read = c.archive_read_next_header(self.archive, &entry);

        return switch (read) {
            c.ARCHIVE_EOF => null,
            c.ARCHIVE_OK => entry,
            else => error.ReadFailed,
        };
    }

    pub fn readData(self: *Reader, buf: []u8) !usize {
        const bytes = c.archive_read_data(
            self.archive,
            buf.ptr,
            buf.len,
        );

        if (bytes < 0) {
            if (bytes == c.ARCHIVE_EOF or bytes == c.ARCHIVE_WARN) return 0;
            return error.ReadFailed;
        }
        return @intCast(bytes);
    }
};
