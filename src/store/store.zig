const std = @import("std");
const Io = std.Io;
const package = @import("../core/package.zig");
const Context = @import("../core/context.zig").Context;
const zqlite = @import("zqlite");

pub const profile = @import("profile.zig");
pub const ingest = @import("ingest.zig");
pub const generation = @import("generation.zig");
pub const StoreConn = zqlite.Conn;

const BuildStatus = enum {
    Pending,
    Building,
    Unpacking,
    Completed,
    Failed,
};

const DepGraph = struct {
    nodes: std.StringHashMap(DepNode),
    edges: std.StringHashMap([][]const u8),
};

const DepNode = struct {
    path: []const u8,
    pkg: *package.Package,
    status: BuildStatus,
};

const StoreObject = struct {
    path: []const u8,
    hash: [32]u8,
    size: i32,
    refs: [][]const u8,
    created: std.Io.Timestamp,
};

pub fn newConn(ctx: Context) !StoreConn {
    const path = try std.Io.Dir.path.joinZ(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.state,
        "store.db",
    });
    defer ctx.alloc.free(path);

    if (std.Io.Dir.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    }

    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    const conn = try zqlite.open(path, flags);
    errdefer conn.close();

    try conn.execNoArgs(
        \\PRAGMA foreign_keys=ON;
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA cache_size=-200000;
        \\
        \\CREATE TABLE IF NOT EXISTS metadata(
        \\  last_install TEXT,
        \\  installed INTEGER DEFAULT 0
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS packages(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  version TEXT NOT NULL,
        \\  epoch INTEGER NOT NULL DEFAULT 0,
        \\  release TEXT NOT NULL,
        \\  explicit INTEGER NOT NULL DEFAULT 1 check(explicit IN (0, 1)),
        \\  arch TEXT NOT NULL,
        \\  repo TEXT NOT NULL,
        \\  UNIQUE(name, epoch, version, release)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS blobs(
        \\  hash BLOB PRIMARY KEY,
        \\  size INTEGER NOT NULL,
        \\  created INTEGER NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS files(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  path TEXT NOT NULL,
        \\  hash BLOB REFERENCES blobs(hash) ON DELETE RESTRICT,
        \\  target TEXT DEFAULT NULL,
        \\  mode INTEGER NOT NULL,
        \\  PRIMARY KEY (package_id, path)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS depends(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL,
        \\  kind INTEGER NOT NULL DEFAULT 0 check(kind IN (0, 1, 2, 3))
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS provides(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS conflicts(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS replaces(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS licenses(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS file_idx ON files(hash);
        \\CREATE INDEX IF NOT EXISTS depends_idx ON depends(name);
        \\CREATE INDEX IF NOT EXISTS provides_idx ON provides(name);
        \\CREATE INDEX IF NOT EXISTS conflicts_idx ON conflicts(name);
        \\CREATE INDEX IF NOT EXISTS replaces_idx ON replaces(name);
        \\CREATE INDEX IF NOT EXISTS licenses_idx ON licenses(name);
        \\
        \\CREATE TABLE IF NOT EXISTS profiles(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL UNIQUE,
        \\  generation INTEGER
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS generations(
        \\  id INTEGER PRIMARY KEY,
        \\  profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
        \\  number INTEGER NOT NULL,
        \\  created INTEGER NOT NULL,
        \\  protected INTEGER NOT NULL DEFAULT 0 CHECK(protected IN (0, 1)),
        \\  UNIQUE(profile_id, number)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS gen_entries(
        \\  gen_id INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE RESTRICT,
        \\  PRIMARY KEY (gen_id, package_id)
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS gen_entries_package ON gen_entries(package_id);
    );

    return conn;
}

pub fn objectPath(ctx: Context, hash: [32]u8) ![]u8 {
    var buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&buf, "{x}", .{hash}) catch unreachable;
    return try std.Io.Dir.path.join(ctx.alloc, &.{
        ctx.path_options.store,
        "blobs",
        hex[0..3],
        hex,
    });
}

pub fn clean(ctx: Context, store_conn: StoreConn) !struct { package_rows: usize, blobs: usize, bytes: i64 } {
    try store_conn.transaction();
    errdefer store_conn.rollback();

    var pkg_rows = try store_conn.rows(
        \\SELECT p.id FROM packages p
        \\LEFT JOIN gen_entries g ON g.package_id = p.id
        \\WHERE g.package_id IS NULL
    , .{});
    defer pkg_rows.deinit();

    var removed_packages: usize = 0;
    while (pkg_rows.next()) |row| {
        defer row.deinit();
        try store_conn.execNoArgs("SAVEPOINT stale_package_rows");
        errdefer store_conn.execNoArgs("ROLLBACK TO stale_package_rows") catch {};

        try store_conn.exec("DELETE FROM packages WHERE id = ?1", .{row.int(0)});
        removed_packages += 1;

        try store_conn.execNoArgs("RELEASE stale_package_rows");
    }

    var live: std.AutoHashMap([32]u8, void) = .init(ctx.alloc);
    defer live.deinit();

    var rows = try store_conn.rows(
        \\SELECT DISTINCT f.hash FROM files f
        \\JOIN gen_entries g ON g.package_id = f.package_id
        \\WHERE f.hash IS NOT NULL
    , .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        defer row.deinit();
        const blob = row.blob(0);
        if (blob.len != 32) return error.InvalidHash;
        var hash: [32]u8 = undefined;
        @memcpy(&hash, blob);
        try live.put(hash, {});
    }

    var removed: usize = 0;
    var freed_bytes: i64 = 0;

    var blob_rows = try store_conn.rows("SELECT hash, size FROM blobs", .{});
    defer blob_rows.deinit();

    var to_delete: std.ArrayList([32]u8) = .empty;
    defer to_delete.deinit(ctx.alloc);

    while (blob_rows.next()) |row| {
        defer row.deinit();
        const blob = row.blob(0);
        if (blob.len != 32) return error.InvalidHash;
        var hash: [32]u8 = undefined;
        @memcpy(&hash, blob);

        if (live.contains(hash)) continue;

        try to_delete.append(ctx.alloc, hash);
        freed_bytes += row.int(1);
    }

    for (to_delete.items) |hash| {
        try store_conn.execNoArgs("SAVEPOINT deletion");
        errdefer store_conn.execNoArgs("ROLLBACK TO deletion") catch {};

        try store_conn.exec("DELETE FROM blobs WHERE hash = ?1", .{&hash});

        const blob_path = try objectPath(ctx, hash);
        defer ctx.alloc.free(blob_path);
        Io.Dir.cwd().deleteFile(ctx.io, blob_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        removed += 1;
        try store_conn.execNoArgs("RELEASE deletion");
    }

    try store_conn.commit();

    try ctx.log(.Info, "Cleaned {d} blobs, {d} bytes freed", .{ removed, freed_bytes });
    return .{ .package_rows = removed_packages, .blobs = removed, .bytes = freed_bytes };
}
