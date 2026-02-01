const std = @import("std");
const sqlite = @import("sqlite");
const archive = @import("../utils/archive.zig");

const Downloader = @import("../net/Downloader.zig");
const MirrorList = @import("../net/MirrorList.zig");

const desc = @import("../parse/desc.zig");
const files = @import("../parse/files.zig");

const Db = @This();

alloc: std.mem.Allocator,
sqlite_db: *sqlite.Db,

pub fn init(alloc: std.mem.Allocator, path: []const u8, reset: bool) !Db {
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    if (reset) {
        try std.fs.cwd().deleteFile(path);
    }

    const sqlite_db = try alloc.create(sqlite.Db);
    sqlite_db.* = try sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    errdefer alloc.destroy(sqlite_db);

    _ = try sqlite_db.pragma(void, .{}, "journal_mode", "WAL");
    _ = try sqlite_db.pragma(void, .{}, "cache_size", "-200000");
    _ = try sqlite_db.pragma(void, .{}, "temp_store", "MEMORY");
    _ = try sqlite_db.pragma(void, .{}, "locking_mode", "EXCLUSIVE");
    _ = try sqlite_db.pragma(void, .{}, "synchronous", "OFF");

    // if (reset) {
    //     try sqlite_db.execMulti(
    //         \\ DROP TABLE IF EXISTS packages;
    //         \\ DROP TABLE IF EXISTS files;
    //     , .{});
    // }

    try sqlite_db.execMulti(
        \\BEGIN IMMEDIATE;
        \\
        \\CREATE TABLE IF NOT EXISTS packages(
        \\ id INTEGER PRIMARY KEY,
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
        // \\ UNIQUE(name, repo)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS files(
        \\ path TEXT NOT NULL,
        \\ package_id INTEGER NOT NULL,
        // \\ UNIQUE(package_id, path)
        \\);
        \\
        \\COMMIT;
    , .{});

    return Db{
        .alloc = alloc,
        .sqlite_db = sqlite_db,
    };
}

pub fn deinit(self: *Db) void {
    _ = self.sqlite_db.pragma(struct { i32, i32, i32 }, .{}, "wal_checkpoint", "TRUNCATE") catch {};

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
    const batch_size: usize = 50000;
    var batched: usize = 0;
    var in_trans: bool = false;

    var mirrors = try MirrorList.init(self.alloc, mirror_path);
    defer mirrors.deinit();

    var files_stmt = try self.sqlite_db.prepare(
        \\INSERT INTO files(
        \\ path,
        \\ package_id
        \\) VALUES(?,?)
    );
    defer files_stmt.deinit();

    var pkg_stmt = try self.sqlite_db.prepare(
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
        // \\ON CONFLICT(name, repo) DO UPDATE SET
        // \\ version = excluded.version,
        // \\ description = excluded.description,
        // \\ arch = excluded.arch,
        // \\ license = excluded.license,
        // \\ filename = excluded.filename,
        // \\ packager = excluded.packager,
        // \\ build_date = excluded.build_date,
        // \\ checksum = excluded.checksum,
        // \\ signature = excluded.signature,
        // \\ replaces = excluded.replaces,
        // \\ conflicts = excluded.conflicts,
        // \\ provides = excluded.provides,
        // \\ deps = excluded.deps,
        // \\ mkdeps = excluded.mkdeps,
        // \\ optdeps = excluded.optdeps,
        // \\ checkdeps = excluded.checkdeps
        // \\WHERE packages.version != excluded.version
        \\RETURNING id
    );
    defer pkg_stmt.deinit();

    for (names) |name| {
        var reader = try archive.Reader.init();
        defer reader.deinit();

        const trailing_slash = if (dest_dir[dest_dir.len - 1] == '/') true else false;
        const dest = try std.fmt.allocPrint(
            self.alloc,
            "{s}{s}{s}.files",
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
        defer file.close();

        try reader.openFd(file.handle);
        var buf: [8192]u8 = undefined;

        var pkg_id: ?usize = null;

        // try self.sqlite_db.exec(
        //     \\BEGIN TRANSACTION;
        // , .{}, .{});

        while (try reader.nextEntry()) |entry| {
            const c_pathname = archive.c.archive_entry_pathname(entry);
            const pathname: []const u8 = std.mem.span(c_pathname);
            const delim = std.mem.lastIndexOfScalar(u8, pathname, '/');

            if (delim == null) {
                while (true) {
                    const bytes = try reader.readData(&buf);
                    if (bytes == 0) break;
                }
                continue;
            }

            const is_desc = std.mem.eql(u8, pathname[delim.? + 1 ..], "desc");
            const is_files = std.mem.eql(u8, pathname[delim.? + 1 ..], "files");

            if (!is_desc and !is_files) {
                while (true) {
                    const bytes = try reader.readData(&buf);
                    if (bytes == 0) break;
                }
                continue;
            }

            var content: std.ArrayList(u8) = .empty;
            defer content.deinit(self.alloc);

            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes == 0) break;
                try content.appendSlice(self.alloc, buf[0..bytes]);
            }

            if (is_desc) {
                if (batched >= batch_size and in_trans) {
                    try self.sqlite_db.exec("COMMIT", .{}, .{});
                    // _ = try self.sqlite_db.pragma(
                    //     struct { i32, i32, i32 },
                    //     .{},
                    //     "wal_checkpoint",
                    //     "RESTART",
                    // );
                    // try self.sqlite_db.execMulti(
                    //     \\END TRANSACTION;
                    //     // \\VACUUM;
                    // , .{});

                    in_trans = false;
                    batched = 0;
                }

                if (!in_trans) {
                    // try self.sqlite_db.exec(
                    //     \\BEGIN TRANSACTION;
                    // , .{}, .{});
                    try self.sqlite_db.exec("BEGIN", .{}, .{});
                    in_trans = true;
                }

                pkg_id = try desc.index(
                    self.alloc,
                    // self,
                    content.items,
                    name,
                    .Buf,
                    &pkg_stmt,
                );

                batched += 1;
            } else if (is_files) {
                if (pkg_id) |id| {
                    try files.index(
                        self.alloc,
                        // self,
                        content.items,
                        id,
                        .Buf,
                        &files_stmt,
                    );
                } else break;
            }

            content.clearRetainingCapacity();
        }

        // try self.sqlite_db.exec(
        //     \\END TRANSACTION;
        // , .{}, .{});
    }

    if (in_trans) {
        try self.sqlite_db.exec("COMMIT", .{}, .{});
        // try self.sqlite_db.exec(
        //     \\END TRANSACTION;
        // , .{}, .{});
    }

    try self.sqlite_db.execMulti(
        \\DELETE FROM files
        \\WHERE rowid NOT IN (
        \\  SELECT MIN(rowid)
        \\  FROM files
        \\  GROUP BY package_id, path
        \\);
        \\
        \\DELETE FROM packages
        \\WHERE id NOT IN (
        \\  SELECT MAX(id)
        \\  FROM packages
        \\  GROUP BY name, repo
        \\);
        \\
        \\CREATE UNIQUE INDEX IF NOT EXISTS unique_files
        \\ON files(package_id, path);
        \\
        \\CREATE UNIQUE INDEX IF NOT EXISTS unique_packages
        \\ON packages(name, repo);
        \\
        \\VACUUM;
    , .{});

    _ = try self.sqlite_db.pragma(
        struct { i32, i32, i32 },
        .{},
        "wal_checkpoint",
        "TRUNCATE",
    );
}
