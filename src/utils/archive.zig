const std = @import("std");
const installer = @import("../core/installer.zig");
pub const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

const Context = @import("../core/Context.zig");

pub const ArchiveError = error{
    UnableToCreateReader,
    UnableToCreateWriter,
    WriteHeaderFailed,
    WriteFailed,
    OpenFailed,
    ReadFailed,
};

pub const Writer = struct {
    writer: *c.struct_archive,

    pub fn init() ArchiveError!Writer {
        const writer = c.archive_write_disk_new() orelse
            return error.UnableToCreateWriter;

        _ = c.archive_write_disk_set_options(
            writer,
            c.ARCHIVE_EXTRACT_PERM |
                c.ARCHIVE_EXTRACT_TIME |
                c.ARCHIVE_EXTRACT_OWNER |
                c.ARCHIVE_EXTRACT_ACL |
                c.ARCHIVE_EXTRACT_SECURE_NODOTDOT |
                c.ARCHIVE_EXTRACT_SECURE_SYMLINKS |
                c.ARCHIVE_EXTRACT_SAFE_WRITES |
                c.ARCHIVE_EXTRACT_UNLINK |
                c.ARCHIVE_EXTRACT_FFLAGS,
        );

        return .{ .writer = writer };
    }

    pub fn deinit(self: *Writer) void {
        _ = c.archive_write_free(self.writer);
    }

    pub fn writeHeader(
        self: *Writer,
        ctx: *Context,
        info: installer.PkgInstallInfo,
        entry: *c.archive_entry,
        path: []const u8,
    ) !void {
        const cpath = try ctx.alloc.dupeZ(u8, path);
        defer ctx.alloc.free(cpath);

        const cloned = c.archive_entry_clone(entry) orelse
            return error.OutOfMemory;
        defer c.archive_entry_free(cloned);

        c.archive_entry_set_pathname(cloned, cpath.ptr);

        if (c.archive_entry_hardlink(cloned)) |target_ptr| {
            const target: []const u8 = std.mem.span(target_ptr);

            var rel = target;
            if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
            if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

            const basename = std.fs.path.basename(rel);
            const target_path = if (basename.len > 0 and basename[0] == '.')
                try std.fs.path.join(ctx.alloc, &.{
                    info.cache,
                    rel,
                })
            else if (std.mem.startsWith(u8, path, "/usr/share/libalpm/hooks/"))
                try std.fs.path.join(ctx.alloc, &.{
                    ctx.paths.hook,
                    rel[25..],
                })
            else
                try std.fs.path.join(ctx.alloc, &.{
                    ctx.paths.root,
                    rel,
                });
            defer ctx.alloc.free(target_path);

            const c_target_path = try ctx.alloc.dupeZ(u8, target_path);
            defer ctx.alloc.free(c_target_path);

            c.archive_entry_set_hardlink(cloned, c_target_path.ptr);
        }

        const ret = c.archive_write_header(self.writer, cloned);
        if (ret != c.ARCHIVE_OK) {
            std.debug.print("{s}\n", .{c.archive_error_string(self.writer)});
            return error.WriteHeaderFailed;
        }
    }

    pub fn writeData(
        self: *Writer,
        data: []const u8,
        bytes: usize,
    ) ArchiveError!void {
        const ret = c.archive_write_data(
            self.writer,
            data.ptr,
            bytes,
        );

        if (ret < 0) {
            std.debug.print("{s}\n", .{c.archive_error_string(self.writer)});
            return error.WriteFailed;
        }
    }

    pub fn finishEntry(self: *Writer) ArchiveError!void {
        _ = c.archive_write_finish_entry(self.writer);
    }
};

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
