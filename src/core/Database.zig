const std = @import("std");
const zqlite = @import("zqlite");

const Context = @import("../core/Context.zig");
const Downloader = @import("../net/Downloader.zig");
const Pkg = @import("Package.zig");

const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");

const DbError = error{
    RelativePathInPkg,
    RelativePathInMTREE,
    CorruptDatabase,
    InvalidDatabase,
};

const Db = @This();

alloc: std.mem.Allocator,
conn: zqlite.Conn,

pub fn init(
    alloc: std.mem.Allocator,
    db_path: []const u8,
) !Db {
    const dbpath = try std.Io.Dir.path.joinZ(alloc, &.{
        db_path,
        "pkgs.db",
    });
    defer alloc.free(dbpath);
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    const conn = try zqlite.open(dbpath, flags);
    errdefer conn.close();

    try conn.execNoArgs(
        \\PRAGMA foreign_keys=true;
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA cache_size=-200000;
        \\
        \\CREATE TABLE IF NOT EXISTS sync(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  repo TEXT NOT NULL,
        \\  version TEXT NOT NULL,
        \\  desc_hash BLOB,
        \\  metadata JSONB,
        \\  UNIQUE(name,repo)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS files(
        \\  pkgid INTEGER NOT NULL,
        \\  path TEXT,
        \\  FOREIGN KEY(pkgid) REFERENCES installed(id) ON DELETE CASCADE
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS installed(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  repo TEXT NOT NULL,
        \\  version TEXT NOT NULL,
        \\  explicit BOOL,
        \\  metadata JSONB,
        \\  UNIQUE(name,repo)
        \\);
    );

    return .{
        .alloc = alloc,
        .conn = conn,
    };
}

pub fn deinit(self: *Db) void {
    self.conn.close();
}

pub fn queryPkgId(self: *Db, pkg: []const u8) !i64 {
    const pkgid_row = try self.conn.row(
        "SELECT id FROM installed WHERE name = ?1 AND (?2 is NULL OR repo = ?2)",
        .{ pkg, null },
    );
    defer if (pkgid_row) |r| r.deinit();
    if (pkgid_row == null) return error.FailedToGetTarget;

    return pkgid_row.?.int(0);
}

pub fn queryPaths(self: *Db, pkgid: i64) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| self.alloc.free(f);
        files.deinit(self.alloc);
    }

    var rows = try self.conn.rows(
        "SELECT path FROM files WHERE pkgid = ?1",
        .{pkgid},
    );
    defer rows.deinit();
    while (rows.next()) |row| try files.append(
        self.alloc,
        try self.alloc.dupe(u8, row.text(0)),
    );
    if (rows.err) |err| return err;

    return files.toOwnedSlice(self.alloc);
}

pub fn querySync(
    self: *Db,
    name: []const u8,
    repo: ?[]const u8,
) ![]Pkg {
    var results: std.ArrayList(Pkg) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(self.alloc);
        results.deinit(self.alloc);
    }

    var rows = try self.conn.rows(
        \\SELECT json(metadata) FROM sync
        \\WHERE (
        \\  name = ?1
        \\  OR EXISTS (
        \\  SELECT * FROM json_each(sync.metadata, '$.provides')
        \\  WHERE SUBSTR(value, 1,
        \\      CASE
        \\          WHEN INSTR(value, '>') > 0 THEN INSTR(value, '>') - 1
        \\          WHEN INSTR(value, '<') > 0 THEN INSTR(value, '<') - 1
        \\          WHEN INSTR(value, '=') > 0 THEN INSTR(value, '=') - 1
        \\          ELSE LENGTH(value)
        \\      END) = ?1
        \\      )
        \\  )
        \\AND (?2 is NULL OR repo = ?2)
    , .{ name, repo });
    defer rows.deinit();

    while (rows.next()) |row| {
        const metadata = row.text(0);
        const parsed = try std.json.parseFromSlice(
            Pkg,
            self.alloc,
            metadata,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();
        try results.append(self.alloc, try parsed.value.clone(self.alloc));
    }
    if (rows.err) |err| return err;

    if (repo != null and results.items.len > 1) return error.InvalidDatabase;
    return results.toOwnedSlice(self.alloc);
}

pub fn queryInstalled(
    self: *Db,
    name: []const u8,
    repo: ?[]const u8,
) ![]Pkg.Installed {
    var results: std.ArrayList(Pkg.Installed) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(self.alloc);
        results.deinit(self.alloc);
    }

    var rows = try self.conn.rows(
        \\SELECT json(metadata) FROM installed
        \\WHERE (
        \\  name = ?1
        \\  OR EXISTS (
        \\  SELECT * FROM json_each(installed.metadata, '$.provides')
        \\  WHERE SUBSTR(value, 1,
        \\      CASE
        \\          WHEN INSTR(value, '>') > 0 THEN INSTR(value, '>') - 1
        \\          WHEN INSTR(value, '<') > 0 THEN INSTR(value, '<') - 1
        \\          WHEN INSTR(value, '=') > 0 THEN INSTR(value, '=') - 1
        \\          ELSE LENGTH(value)
        \\      END) = ?1
        \\      )
        \\  )
        \\AND (?2 is NULL OR repo = ?2)
    , .{ name, repo });
    defer rows.deinit();

    while (rows.next()) |row| {
        const metadata = row.text(0);
        const parsed = try std.json.parseFromSlice(
            Pkg.Installed,
            self.alloc,
            metadata,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();
        try results.append(self.alloc, try parsed.value.clone(self.alloc));
    }
    if (rows.err) |err| return err;

    if (repo != null and results.items.len > 1) return error.InvalidDatabase;
    return results.toOwnedSlice(self.alloc);
}

pub fn insertSync(
    self: *Db,
    hash: []const u8,
    pkg: Pkg,
) !void {
    var writer = std.Io.Writer.Allocating.init(self.alloc);
    const w = &writer.writer;
    defer writer.deinit();
    try std.json.Stringify.value(pkg, .{}, w);

    try self.conn.exec(
        \\INSERT INTO sync (name, repo, version, desc_hash, metadata)
        \\VALUES (?1, ?2, ?3, ?4, jsonb(?5))
        \\ON CONFLICT(name, repo) DO UPDATE SET
        \\metadata = excluded.metadata
        \\WHERE metadata != excluded.metadata
    , .{ pkg.name, pkg.repo, pkg.version, hash, writer.written() });
}

pub fn insertInstalled(
    self: *Db,
    explicit: bool,
    pkg: Pkg.Installed,
) !i64 {
    var writer = std.Io.Writer.Allocating.init(self.alloc);
    const w = &writer.writer;
    defer writer.deinit();
    try std.json.Stringify.value(pkg, .{}, w);

    try self.conn.exec(
        \\INSERT INTO installed (name, repo, version, explicit, metadata)
        \\VALUES (?1, ?2, ?3, ?4, jsonb(?5))
        \\ON CONFLICT(name, repo) DO UPDATE SET
        \\metadata = excluded.metadata
        \\WHERE metadata != excluded.metadata
    , .{ pkg.name, pkg.repo, pkg.version, explicit, writer.written() });

    return self.conn.lastInsertedRowId();
}

pub fn sync(
    self: *Db,
    ctx: *Context,
    repo: []const u8,
    batch_size: usize,
) !void {
    var in_trans = false;
    var batched: usize = 0;

    var reader = try archive.Reader.init();
    defer reader.deinit();

    const repodb = try std.fmt.allocPrint(
        self.alloc,
        "{s}.db",
        .{repo},
    );
    defer self.alloc.free(repodb);
    const dest = try std.Io.Dir.path.join(self.alloc, &.{
        ctx.paths.cache,
        repodb,
    });
    defer self.alloc.free(dest);

    std.Io.Dir.cwd().deleteFile(ctx.io, dest) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try ctx.mirrors.downloadDb(
        ctx,
        repo,
        dest,
    );

    const file = try std.Io.Dir.cwd().openFile(
        ctx.io,
        dest,
        .{ .mode = .read_only },
    );
    defer file.close(ctx.io);

    try reader.openFd(file.handle);
    var buf: [8192]u8 = undefined;
    while (try reader.nextEntry()) |entry| {
        errdefer self.conn.rollback();

        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        const delim = std.mem.findScalarLast(u8, path, '/');

        if (delim == null) {
            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes == 0) break;
            }
            continue;
        }

        const is_desc = std.mem.eql(u8, std.Io.Dir.path.basename(path), "desc");
        if (!is_desc) continue;

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.alloc);

        while (true) {
            const bytes = try reader.readData(&buf);
            if (bytes <= 0) break;
            try content.appendSlice(self.alloc, buf[0..bytes]);
        }

        const ver_rel_delim = std.mem.findScalarLast(
            u8,
            path,
            '-',
        ) orelse unreachable;
        const name_ver = path[0..ver_rel_delim];
        const name_ver_delim = std.mem.findScalarLast(
            u8,
            name_ver,
            '-',
        ) orelse unreachable;
        const name = name_ver[0..name_ver_delim];
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(
            content.items,
            &hash,
            .{},
        );
        const hash_row = try self.conn.row(
            "SELECT desc_hash FROM sync WHERE name=?1 AND repo=?2",
            .{ name, repo },
        );
        defer if (hash_row) |r| r.deinit();
        const pkg_hash = if (hash_row) |r| r.blob(0) else null;
        if (pkg_hash != null and std.mem.eql(u8, &hash, pkg_hash.?)) continue;

        if (batched >= batch_size and in_trans) {
            try self.conn.commit();
            batched = 0;
            in_trans = false;
        }
        if (!in_trans) {
            try self.conn.transaction();
            in_trans = true;
        }

        try desc.index(
            ctx,
            content.items,
            repo,
            &hash,
        );

        batched += 1;
    }

    if (in_trans) {
        try self.conn.commit();
        try self.conn.execNoArgs("VACUUM");
        batched = 0;
        in_trans = false;
    }
}
