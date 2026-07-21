const std = @import("std");
const zqlite = @import("zqlite");
const Context = @import("context.zig").Context;
const version = @import("../utils/version.zig");
const Repo = @import("repo.zig").Repo;

pub fn newInstalledConn(ctx: Context) !zqlite.Conn {
    const path = try std.Io.Dir.path.joinZ(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.state,
        "installed.db",
    });
    defer ctx.alloc.free(path);

    if (std.Io.Dir.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    }

    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    const conn = try zqlite.open(path, flags);
    errdefer conn.close();

    try conn.execNoArgs(
        \\PRAGMA foreign_keys=true;
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
        \\  arch TEXT NOT NULL,
        \\  repo TEXT NOT NULL,
        \\  kind TEXT NOT NULL check(kind IN ('binary', 'source')),
        \\  UNIQUE(name, epoch, version, release)
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
        \\CREATE INDEX IF NOT EXISTS depends_idx ON depends(name);
        \\CREATE INDEX IF NOT EXISTS provides_idx ON provides(name);
        \\CREATE INDEX IF NOT EXISTS conflicts_idx ON conflicts(name);
        \\CREATE INDEX IF NOT EXISTS replaces_idx ON replaces(name);
        \\CREATE INDEX IF NOT EXISTS licenses_idx ON licenses(name);
    );

    return conn;
}

pub fn newRepoConn(ctx: Context, repo: Repo) !zqlite.Conn {
    const name = try std.fmt.allocPrint(ctx.alloc, "{s}-{s}.db", .{ repo.name, repo.arch });
    defer ctx.alloc.free(name);
    const path = try std.Io.Dir.path.joinZ(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.state,
        name,
    });
    defer ctx.alloc.free(path);

    if (std.Io.Dir.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    }

    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    const conn = try zqlite.open(path, flags);
    errdefer conn.close();

    try conn.execNoArgs(
        \\PRAGMA foreign_keys=true;
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA cache_size=-200000;
        \\
        \\CREATE TABLE IF NOT EXISTS metadata(
        \\  last_refresh INTEGER,
        \\  name STRING NOT NULL,
        \\  architecture STRING NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS packages(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  epoch INTEGER NOT NULL DEFAULT 0,
        \\  version TEXT NOT NULL,
        \\  release TEXT,
        \\  UNIQUE(name)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS depends(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL,
        \\  ver_constraint TEXT,
        \\  kind INTEGER NOT NULL DEFAULT 0 check(kind IN (0, 1, 2, 3))
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS provides(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  ver_constraint TEXT,
        \\  name TEXT NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS conflicts(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  ver_constraint TEXT,
        \\  name TEXT NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS replaces(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  ver_constraint TEXT,
        \\  name TEXT NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS licenses(
        \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS depends_idx ON depends(name);
        \\CREATE INDEX IF NOT EXISTS provides_idx ON provides(name);
        \\CREATE INDEX IF NOT EXISTS conflicts_idx ON conflicts(name);
        \\CREATE INDEX IF NOT EXISTS replaces_idx ON replaces(name);
        \\CREATE INDEX IF NOT EXISTS licenses_idx ON licenses(name);
    );

    try conn.exec(
        "INSERT INTO metadata(name, architecture) VALUES (?1, ?2)",
        .{ repo.name, repo.arch },
    );

    const res = zqlite.c.sqlite3_create_function_v2(
        conn.conn,
        "vercmp",
        6,
        zqlite.c.SQLITE_UTF8 | zqlite.c.SQLITE_DETERMINISTIC,
        null,
        version.sqlCmp,
        null,
        null,
        null,
    );
    if (res != zqlite.c.SQLITE_OK) {
        try ctx.log(.Error, "Failed to register custom SQL function `vercmp`: {s}\n", .{conn.lastError()});
        return error.FailedToRegisterFunction;
    }

    return conn;
}
