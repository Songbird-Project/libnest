const std = @import("std");
const package = @import("../core/package.zig");
const Context = @import("../core/context.zig").Context;
const zqlite = @import("zqlite");

pub const profile = @import("profile.zig");
pub const ingest = @import("ingest.zig");
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
        \\CREATE TABLE IF NOT EXISTS objects(
        \\  id INTEGER PRIMARY KEY,
        \\  path TEXT NOT NULL UNIQUE,
        \\  hash BLOB NOT NULL,
        \\  package_id INTEGER REFERENCES packages(id) ON DELETE SET NULL,
        \\  size INTEGER NOT NULL,
        \\  created INTEGER NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS refs(
        \\  referrer INTEGER NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
        \\  referent INTEGER NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
        \\  PRIMARY KEY (referrer, referent)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS gc_roots(
        \\  id INTEGER PRIMARY KEY,
        \\  obj_id INTEGER NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
        \\  label TEXT NOT NULL,
        \\  created INTEGER NOT NULL
        \\);
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
        \\  UNIQUE(profile_id, number)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS gen_entries(
        \\  gen_id INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
        \\  obj_id INTEGER NOT NULL REFERENCES  objects(id) ON DELETE RESTRICT,
        \\  PRIMARY KEY (gen_id, obj_id)
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS gen_entries_obj ON gen_entries(obj_id);
        \\CREATE INDEX IF NOT EXISTS referent_idx ON refs(referent);
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

pub fn addObject(
    store_db: StoreConn,
    path: []const u8,
    hash: [32]u8,
    size: i64,
    package_id: ?i64,
) !i64 {
    const row = try store_db.row(
        \\INSERT INTO objects(path, hash, size, package_id, created)
        \\VALUES (?1, ?2, ?3, ?4, unixepoch())
        \\ON CONFLICT(path) DO UPDATE SET size = excluded.size
        \\RETURNING ID;
    , .{ path, &hash, size, package_id });
    defer row.?.deinit();

    return row.?.int(0);
}

pub fn addRef(store_db: StoreConn, referrer: i64, referent: i64) !void {
    try store_db.exec("INSERT INTO refs(referrer, referent) VALUES (?1, ?2)", .{
        referrer, referent,
    });
}

pub fn addRoot(store_db: StoreConn, obj_id: i64, label: []const u8) !void {
    try store_db.exec("INSERT INTO gc_roots(obj_id, label, created) VALUES (?1, ?2, unixepoch())", .{
        obj_id, label,
    });
}
