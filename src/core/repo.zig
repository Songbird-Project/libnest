const std = @import("std");
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const Ctx = @import("context.zig").Context;
const package = @import("package.zig");
const version = @import("../utils/version.zig");
const mem = @import("../utils/mem.zig");

pub const Repo = struct {
    name: []const u8,
    arch: []const u8,
    mirrors: []const []const u8,
    priority: i32,
    enabled: bool = true,
};

pub const RepoConn = struct {
    conn: zqlite.Conn,
    repo: *Repo,

    pub fn open(ctx: Ctx, repo: Repo) !void {
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
            \\PRAGMA foreign_keys=ON;
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
            \\  checksum BLOB,
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

        const repo_ptr = try ctx.alloc.create(Repo);
        repo_ptr.* = repo;
        const r: RepoConn = .{
            .conn = conn,
            .repo = repo_ptr,
        };

        try ctx.repos.put(repo.name, r);
    }

    pub fn deinit(self: *RepoConn, ctx: Ctx) void {
        self.conn.close();
        ctx.alloc.destroy(self.repo);
    }

    pub fn getPkg(self: RepoConn, ctx: Ctx, name: []const u8) !package.PackageInfo {
        const pkg_row = try self.conn.row("SELECT * from packages WHERE name = ?1", .{name});
        defer if (pkg_row) |r| r.deinit();
        if (pkg_row == null) {
            try ctx.log(.Error, "Couldn't find package '{s}:{s}'\n", .{ self.repo.name, name });
            return error.PackageNotFound;
        }

        const row = pkg_row.?;
        const id = row.int(0);
        var pkg: package.PackageInfo = .{
            .name = try ctx.alloc.dupe(u8, row.cString(1)),
            .arch = try ctx.alloc.dupe(u8, self.repo.arch),
            .checksum = row.get(?[32]u8, 2),
            .repo = try ctx.alloc.dupe(u8, self.repo.name),
            .epoch = @intCast(row.int(3)),
            .version = try ctx.alloc.dupe(u8, row.cString(4)),
            .release = if (row.get(?[]const u8, 5)) |sum| try ctx.alloc.dupe(u8, sum) else null,
        };

        var depends: std.ArrayList(package.DepKind) = .empty;
        errdefer {
            for (depends.items) |dep| dep.deinit(ctx.alloc);
            depends.deinit(ctx.alloc);
        }
        const depend_rows = try self.conn.rows("SELECT * from depends WHERE package_id = ?1", .{id});
        while (depend_rows.next()) |dep| {
            try depends.append(ctx.alloc, .{
                .name = try ctx.alloc.dupe(u8, dep.cString(1)),
                .constraint = if (dep.get(?[]const u8, 2)) |constraint|
                    try ctx.alloc.dupe(u8, constraint),
                .kind = switch (dep.int(3)) {
                    0 => .Run,
                    1 => .Make,
                    2 => .Check,
                    3 => .Optional,
                    else => {
                        try ctx.log(.Error, "Invalid dependency kind\n", .{});
                        return error.InvalidDependency;
                    },
                },
            });
        }
        pkg.deps = try depends.toOwnedSlice(ctx.alloc);

        var provides: std.ArrayList(package.Constrained) = .empty;
        errdefer {
            for (provides.items) |constraint| constraint.deinit(ctx.alloc);
            provides.deinit(ctx.alloc);
        }
        const provide_rows = try self.conn.rows("SELECT * from provides WHERE package_id = ?1", .{id});
        while (provide_rows.next()) |r| {
            try provides.append(ctx.alloc, .{
                .name = try ctx.alloc.dupe(u8, r.cString(1)),
                .constraint = if (r.get(?[]const u8, 2)) |constraint|
                    try ctx.alloc.dupe(u8, constraint),
            });
        }
        pkg.provides = try provides.toOwnedSlice(ctx.alloc);

        var conflicts: std.ArrayList(package.Constrained) = .empty;
        errdefer {
            for (conflicts.items) |constraint| constraint.deinit(ctx.alloc);
            conflicts.deinit(ctx.alloc);
        }
        const conflict_rows = try self.conn.rows("SELECT * from conflicts WHERE package_id = ?1", .{id});
        while (conflict_rows.next()) |r| {
            try conflicts.append(ctx.alloc, .{
                .name = try ctx.alloc.dupe(u8, r.cString(1)),
                .constraint = if (r.get(?[]const u8, 2)) |constraint|
                    try ctx.alloc.dupe(u8, constraint),
            });
        }
        pkg.conflicts = try conflicts.toOwnedSlice(ctx.alloc);

        var replaces: std.ArrayList(package.Constrained) = .empty;
        errdefer {
            for (replaces.items) |constraint| constraint.deinit(ctx.alloc);
            replaces.deinit(ctx.alloc);
        }
        const replace_rows = try self.conn.rows("SELECT * from replaces WHERE package_id = ?1", .{id});
        while (replace_rows.next()) |r| {
            try replaces.append(ctx.alloc, .{
                .name = try ctx.alloc.dupe(u8, r.cString(1)),
                .constraint = if (r.get(?[]const u8, 2)) |constraint|
                    try ctx.alloc.dupe(u8, constraint),
            });
        }
        pkg.replaces = try replaces.toOwnedSlice(ctx.alloc);

        var licenses: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (licenses.items) |license| ctx.alloc.free(license);
            licenses.deinit(ctx.alloc);
        }
        const license_rows = try self.conn.rows("SELECT * from licenses WHERE package_id = ?1", .{id});
        while (license_rows.next()) |r| {
            try licenses.append(
                ctx.alloc,
                try ctx.alloc.dupe(u8, r.cString(1)),
            );
        }
        pkg.licenses = try licenses.toOwnedSlice(ctx.alloc);

        return pkg;
    }
};
