const std = @import("std");
pub const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

pub const Reader = struct {
    archive: *c.struct_archive,

    pub fn init() !Reader {
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

    pub fn openFd(self: *Reader, fd: std.posix.fd_t) !void {
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

        if (bytes < 0) return error.ReadFailed;
        return @intCast(bytes);
    }
};
