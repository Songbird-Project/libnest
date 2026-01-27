const std = @import("std");
const sqlite = @import("sqlite");
const archive = @import("../utils/archive.zig");

const Downloader = @import("../net/Downloader.zig");
const MirrorList = @import("../net/MirrorList.zig");

const Db = @This();

alloc: std.mem.Allocator,
sqlite_db: *sqlite.Db,

pub fn init(alloc: std.mem.Allocator, path: [:0]const u8) !Db {
    const sqlite_db = try alloc.create(sqlite.Db);
    sqlite_db.* = try sqlite.Db.init(.{
        .mode = .{ .File = path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });

    try sqlite_db.exec(
        \\CREATE TABLE IF NOT EXISTS packages(
        \\ id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\ name TEXT NOT NULL,
        \\ repo TEXT NOT NULL,
        \\ version TEXT NOT NULL,
        \\ description TEXT,
        \\ arch TEXT,
        \\ license TEXT,
        \\ filename TEXT,
        \\ packager TEXT,
        \\ build_date INTEGER,
        \\ checksum TEXT,
        \\ signature TEXT,
        \\ replaces TEXT,
        \\ conflicts TEXT,
        \\ provides TEXT,
        \\ deps TEXT,
        \\ mkdeps TEXT,
        \\ optdeps TEXT,
        \\ checkdeps TEXT,
        \\ UNIQUE(name, repo)
        \\)
    , .{}, .{});

    return Db{
        .alloc = alloc,
        .sqlite_db = sqlite_db,
    };
}

pub fn deinit(self: *Db) void {
    self.sqlite_db.deinit();
    self.alloc.destroy(self.sqlite_db);
}

pub fn sync(
    self: *Db,
    mirror_path: []const u8,
    dest_dir: []const u8,
    names: []const []const u8,
    arch: []const u8,
    download_cb: ?*const Downloader.callback,
) !void {
    var mirrors = try MirrorList.init(self.alloc, mirror_path);
    defer mirrors.deinit();

    var reader = try archive.Reader.init();
    defer reader.deinit();

    for (names) |name| {
        const trailing_slash = if (dest_dir[dest_dir.len - 1] == '/') true else false;
        const dest = try std.fmt.allocPrint(
            self.alloc,
            "{s}{s}{s}",
            .{
                dest_dir,
                if (!trailing_slash) "/" else "",
                name,
            },
        );
        defer self.alloc.free(dest);

        try mirrors.downloadDb(
            name,
            arch,
            dest,
            download_cb,
        );

        const file = try std.fs.cwd().openFile(
            dest,
            .{ .mode = .read_only },
        );

        try reader.openFd(file.handle);
        var buf: [4096]u8 = undefined;

        while (try reader.nextEntry()) |entry| {
            const pathname = archive.c.archive_entry_pathname(entry);
            _ = pathname;

            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes == 0) break;
            }
        }
    }
}
