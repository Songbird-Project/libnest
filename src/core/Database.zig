const std = @import("std");
const sqlite = @import("sqlite");

const Downloader = @import("../net/Downloader.zig");
const MirrorList = @import("../net/MirrorList.zig");
const Pkg = @import("Package.zig");

const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");
const pkginfo = @import("../parse/pkginfo.zig");

const DbError = error{
    RelativePathInPkg,
    RelativePathInMTREE,
    CorruptPkg,
};

const Db = @This();

alloc: std.mem.Allocator,
db: *sqlite.Db,

pub fn init(alloc: std.mem.Allocator, prefix: []const u8) !Db {
    const dbpath = try std.fs.path.joinZ(alloc, &.{ prefix, "pkgs.db" });
    defer alloc.free(dbpath);
    const db = try alloc.create(sqlite.Db);
    db.* = try sqlite.Db.init(.{
        .mode = .{ .File = dbpath },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    errdefer alloc.destroy(db);

    _ = try db.pragma(void, .{}, "foreign_keys", "ON");
    _ = try db.pragma(void, .{}, "journal_mode", "WAL");
    _ = try db.pragma(void, .{}, "cache_size", "-200000");

    try db.execMulti(
        \\CREATE TABLE IF NOT EXISTS packages(
        \\ id INTEGER PRIMARY KEY,
        \\ name TEXT NOT NULL,
        \\ repo TEXT NOT NULL,
        \\ metadata JSONB,
        \\ UNIQUE(name,repo)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS files(
        \\ pkgid INTEGER NOT NULL,
        \\ path TEXT,
        \\ FOREIGN KEY(pkgid) REFERENCES packages(id) ON DELETE CASCADE
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS installed(
        \\ id INTEGER PRIMARY KEY,
        \\ name TEXT NOT NULL,
        \\ repo TEXT NOT NULL,
        \\ metadata JSONB,
        \\ UNIQUE(name,repo)
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_install_path ON files(path);
    , .{});

    return .{
        .alloc = alloc,
        .db = db,
    };
}

pub fn deinit(self: *Db) void {
    self.db.deinit();
    self.alloc.destroy(self.db);
}

pub fn queryPkg(
    self: *Db,
    comptime T: type,
    name: []const u8,
) ![]std.json.Parsed(T) {
    const query_pkgs =
        \\SELECT json(metadata) FROM packages
        \\WHERE name = ? OR EXISTS (SELECT 1 FROM json_each(packages.metadata, '$.provides') WHERE value = ?)
    ;
    const query_inst =
        \\SELECT json(metadata) FROM installed
        \\WHERE name = ? OR EXISTS (SELECT 1 FROM json_each(installed.metadata, '$.provides') WHERE value = ?)
    ;

    var stmt = try if (T == Pkg.Installed)
        self.db.prepare(query_inst)
    else
        self.db.prepare(query_pkgs);
    defer stmt.deinit();

    var results: std.ArrayList(std.json.Parsed(T)) = .empty;
    errdefer {
        for (results.items) |r| r.deinit();
        results.deinit(self.alloc);
    }

    var iter = try stmt.iterator(struct { metadata: []const u8 }, .{ name, name });

    while (try iter.nextAlloc(self.alloc, .{})) |row| {
        const parsed = try std.json.parseFromSlice(
            T,
            self.alloc,
            row.metadata,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        try results.append(self.alloc, parsed);
        self.alloc.free(row.metadata);
    }

    return results.toOwnedSlice(self.alloc);
}

pub fn insert(
    self: *Db,
    pkgid: i64,
    path: []const u8,
) !void {
    var stmt = try self.db.prepare(
        \\INSERT INTO files (path, pkgid) VALUES (?, ?)
        ,
    );
    defer stmt.deinit();

    try stmt.exec(.{}, .{
        path,
        pkgid,
    });
}

pub fn insertPkg(
    self: *Db,
    kind: enum { Sync, Installed },
    repo: []const u8,
    val: anytype,
) !i64 {
    var writer = std.io.Writer.Allocating.init(self.alloc);
    const w = &writer.writer;
    defer writer.deinit();
    try std.json.Stringify.value(val, .{}, w);

    if (kind == .Installed) {
        var stmt = try self.db.prepare(
            \\INSERT INTO installed (name, repo, metadata) VALUES (?, ?, jsonb(?))
            ,
        );
        defer stmt.deinit();

        try stmt.exec(.{}, .{
            val.name,
            repo,
            writer.written(),
        });
    } else {
        var stmt = try self.db.prepare(
            \\ INSERT INTO packages (name, repo, metadata) VALUES (?, ?, jsonb(?))
            ,
        );
        defer stmt.deinit();

        try stmt.exec(.{}, .{
            val.name,
            repo,
            writer.written(),
        });
    }

    return self.db.getLastInsertRowID();
}

pub fn sync(
    self: *Db,
    mirrors: *MirrorList,
    dest_dir: []const u8,
    repo: []const u8,
    arch: []const u8,
    batch_size: usize,
    download_cb: ?*const Downloader.callback,
) !void {
    var in_trans = false;
    var batched: usize = 0;

    var reader = try archive.Reader.init();
    defer reader.deinit();

    const trailing_slash = if (dest_dir[dest_dir.len - 1] == '/') true else false;
    const dest = try std.fmt.allocPrint(
        self.alloc,
        "{s}{s}{s}.db",
        .{
            dest_dir,
            if (!trailing_slash) "/" else "",
            repo,
        },
    );
    defer self.alloc.free(dest);

    try mirrors.downloadDb(
        repo,
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
    while (try reader.nextEntry()) |entry| {
        const pathrepo: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        const delim = std.mem.lastIndexOfScalar(u8, pathrepo, '/');

        if (delim == null) {
            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes == 0) break;
            }
            continue;
        }

        const is_desc = std.mem.eql(u8, pathrepo[delim.? + 1 ..], "desc");

        if (!is_desc) {
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
            if (bytes <= 0) break;
            try content.appendSlice(self.alloc, buf[0..bytes]);
        }

        if (is_desc) {
            if (batched >= batch_size and in_trans) {
                try self.db.exec("COMMIT", .{}, .{});
                batched = 0;
                in_trans = false;
            }
            if (!in_trans) {
                try self.db.exec("BEGIN IMMEDIATE", .{}, .{});
                in_trans = true;
            }

            try desc.index(
                self.alloc,
                self,
                content.items,
                repo,
            );

            batched += 1;
        }
    }

    if (in_trans) {
        try self.db.exec("COMMIT", .{}, .{});
        try self.db.exec("VACUUM", .{}, .{});
        batched = 0;
        in_trans = false;
    }
}

pub fn install(
    self: *Db,
    mirrors: *MirrorList,
    pkg: Pkg,
    prefix: ?[]const u8,
    download_cb: ?*const Downloader.callback,
) !void {
    var reader = try archive.Reader.init();
    defer reader.deinit();

    var writer = try archive.Writer.init();
    defer writer.deinit();

    const cache = try std.fs.path.join(self.alloc, &.{
        prefix orelse "/",
        "var",
        "cache",
        if (std.mem.indexOf(u8, pkg.filename, ".pkg.tar.")) |i|
            pkg.filename[0..i]
        else
            pkg.checksum,
    });
    defer self.alloc.free(cache);
    try std.fs.cwd().makePath(cache);

    const dest = try std.fs.path.join(self.alloc, &.{
        cache,
        pkg.filename,
    });
    defer self.alloc.free(dest);

    try mirrors.downloadPkg(
        pkg,
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
    while (try reader.nextEntry()) |entry| {
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        if (std.mem.containsAtLeast(u8, path, 1, ".."))
            return error.RelativePathInPkg;

        const path_type = archive.c.archive_entry_mode(entry) & 0o170000;

        var rel = path;
        if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
        if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

        const install_path = if (path[0] == '.') try std.fs.path.join(self.alloc, &.{
            cache,
            rel,
        }) else try std.fs.path.join(self.alloc, &.{
            prefix orelse "/",
            rel,
        });
        defer self.alloc.free(install_path);

        try writer.writeHeader(entry, install_path);

        if (path_type == 0o100000) {
            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes <= 0) break;

                try writer.writeData(buf[0..bytes], bytes);
            }
        }

        try writer.finishEntry();
    }

    const pkginfo_path = try std.fs.path.join(self.alloc, &.{
        cache,
        ".PKGINFO",
    });
    defer self.alloc.free(pkginfo_path);
    const pkgid = try pkginfo.index(
        self.alloc,
        self,
        pkg.repo,
        pkginfo_path,
    );

    const mtree_path = try std.fs.path.join(self.alloc, &.{
        cache,
        ".MTREE",
    });
    defer self.alloc.free(mtree_path);
    try self.useMTREE(
        pkgid,
        mtree_path,
        prefix,
    );
}

fn useMTREE(
    self: *Db,
    pkgid: i64,
    mtree_path: []const u8,
    prefix: ?[]const u8,
) !void {
    var reader = try archive.Reader.init();
    defer reader.deinit();

    const writer = archive.c.archive_write_disk_new() orelse
        return error.UnableToCreateWriter;
    defer _ = archive.c.archive_write_free(writer);

    _ = archive.c.archive_write_disk_set_standard_lookup(writer);
    _ = archive.c.archive_write_disk_set_options(
        writer,
        archive.c.ARCHIVE_EXTRACT_PERM |
            archive.c.ARCHIVE_EXTRACT_TIME |
            archive.c.ARCHIVE_EXTRACT_OWNER |
            archive.c.ARCHIVE_EXTRACT_ACL |
            archive.c.ARCHIVE_EXTRACT_SECURE_NODOTDOT |
            archive.c.ARCHIVE_EXTRACT_SECURE_SYMLINKS |
            archive.c.ARCHIVE_EXTRACT_UNLINK |
            archive.c.ARCHIVE_EXTRACT_FFLAGS,
    );

    const file = std.fs.cwd().openFile(
        mtree_path,
        .{ .mode = .read_only },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    try reader.openFd(file.handle);
    while (try reader.nextEntry()) |entry| {
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        if (std.mem.startsWith(u8, path, ".")) continue;
        if (!std.fs.path.isAbsolute(path)) return error.RelativePathInMTREE;

        const install_path = try std.fs.path.join(self.alloc, &.{
            prefix orelse "/",
            path,
        });
        defer self.alloc.free(install_path);

        archive.c.archive_entry_set_pathname(entry, install_path.ptr);
        const ret = archive.c.archive_write_header(writer, entry);
        if (ret != archive.c.ARCHIVE_OK) return error.WriteHeaderFailed;
        _ = archive.c.archive_write_finish_entry(writer);

        try self.insert(pkgid, path);
    }
}

pub fn uninstall(
    self: *Db,
    pkgname: []const u8,
    repo: []const u8,
) !void {
    try self.db.exec(
        \\DELETE FROM installed WHERE name = ? AND repo = ?
    , .{}, .{ pkgname, repo });
    try self.db.exec("VACUUM;", .{}, .{});
}
