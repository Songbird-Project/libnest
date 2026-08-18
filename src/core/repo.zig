const std = @import("std");
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const Context = @import("context.zig").Context;
const package = @import("package.zig");
const version = @import("../utils/version.zig");
const mem = @import("../utils/mem.zig");

const comps: std.StaticStringMap(u8) = .initComptime(.{
    .{ ">", 0 },
    .{ "<", 1 },
    .{ ">=", 2 },
    .{ "<=", 3 },
});

pub const Repo = struct {
    name: []const u8,
    arch: []const u8,
    mirrors: []const []const u8,
    enabled: bool = true,
};

pub const RepoConn = struct {
    conn: zqlite.Conn,
    repo: *Repo,

    pub fn open(ctx: *Context, repo: Repo) !void {
        if (repo.mirrors.len <= 0) {
            try ctx.log(.Error, "Remote repos '{s}' has no mirrors listed\n", .{repo.name});
            return error.NoMirrors;
        }

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
            \\PRAGMA synchronous=NORMAL;
            \\
            \\CREATE TABLE IF NOT EXISTS metadata(
            \\  last_refresh INTEGER,
            \\  name STRING NOT NULL,
            \\  architecture STRING NOT NULL,
            \\  hash BLOB,
            \\  UNIQUE(name)
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
            \\INSERT INTO metadata(name, architecture) VALUES (?1, ?2)
            \\ON CONFLICT(name) DO NOTHING
        , .{ repo.name, repo.arch });

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

    pub fn deinit(self: *RepoConn, ctx: Context) void {
        self.conn.close();
        ctx.alloc.destroy(self.repo);
    }
};

pub fn getProvider(ctx: Context, name: []const u8, explicit: bool) !package.Provider {
    var providers: std.ArrayList(struct { conn: *RepoConn, name: []const u8, id: i64 }) = .empty;
    defer {
        for (providers.items) |item| ctx.alloc.free(item.name);
        providers.deinit(ctx.alloc);
    }

    var repo_it = ctx.repos.valueIterator();
    while (repo_it.next()) |repo| {
        const pkg_row = try repo.conn.row("SELECT name,id FROM packages WHERE name = ?1", .{name});
        if (pkg_row) |r| {
            defer r.deinit();
            try providers.append(ctx.alloc, .{
                .conn = repo,
                .name = try ctx.alloc.dupe(u8, r.cString(0)),
                .id = r.int(1),
            });
        }

        var provider_rows = try repo.conn.rows("SELECT package_id FROM provides WHERE name = ?1", .{name});
        defer provider_rows.deinit();

        blk: while (provider_rows.next()) |r| {
            for (providers.items) |p| {
                if (p.id == r.int(0)) continue :blk;
            }

            defer r.deinit();
            const p = try repo.conn.row("SELECT name FROM packages WHERE id = ?1", .{r.int(0)});
            if (p) |pr| {
                defer pr.deinit();
                try providers.append(ctx.alloc, .{
                    .conn = repo,
                    .name = try ctx.alloc.dupe(u8, pr.cString(0)),
                    .id = r.int(0),
                });
            }
        }
    }

    if (providers.items.len == 0) return error.ProviderNotFound;

    for (providers.items, 1..) |pkg, idx| {
        try ctx.log(.None, "{d:>3}: {s}", .{ idx, pkg.name });
    }
    const selected = if (providers.items.len == 1) 0 else try ctx.select(providers.items.len);
    const provider = providers.items[selected];

    var row = (try provider.conn.conn.row("SELECT * FROM packages WHERE id = ?1", .{provider.id})).?;
    defer row.deinit();
    const conn = provider.conn.conn;

    const id = row.int(0);
    const pkg = try ctx.alloc.create(package.PackageInfo);

    const blob = row.blob(2);
    if (blob.len != 32) return error.InvalidHash;
    var hash: [32]u8 = undefined;
    @memcpy(&hash, blob);

    pkg.* = .{
        .name = try ctx.alloc.dupe(u8, row.cString(1)),
        .arch = try ctx.alloc.dupe(u8, provider.conn.repo.arch),
        .checksum = hash,
        .repo = try ctx.alloc.dupe(u8, provider.conn.repo.name),
        .epoch = @intCast(row.int(3)),
        .version = try ctx.alloc.dupe(u8, row.cString(4)),
        .release = if (row.get(?[]const u8, 5)) |sum| try ctx.alloc.dupe(u8, sum) else null,
        .explicit = explicit,
    };

    var depends: std.ArrayList(package.Dependency) = .empty;
    errdefer {
        for (depends.items) |*dep| dep.deinit(ctx.alloc);
        depends.deinit(ctx.alloc);
    }
    var depend_rows = try conn.rows("SELECT * FROM depends WHERE package_id = ?1", .{id});
    defer depend_rows.deinit();
    while (depend_rows.next()) |dep| {
        defer dep.deinit();

        try depends.append(ctx.alloc, .{
            .name = try ctx.alloc.dupe(u8, dep.cString(1)),
            .constraint = if (dep.get(?[]const u8, 2)) |constraint|
                try ctx.alloc.dupe(u8, constraint)
            else
                null,
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
        for (provides.items) |*constraint| constraint.deinit(ctx.alloc);
        provides.deinit(ctx.alloc);
    }
    var provide_rows = try conn.rows("SELECT * FROM provides WHERE package_id = ?1", .{id});
    defer provide_rows.deinit();
    while (provide_rows.next()) |r| {
        defer r.deinit();
        try provides.append(ctx.alloc, .{
            .name = try ctx.alloc.dupe(u8, r.cString(1)),
            .constraint = if (r.get(?[]const u8, 2)) |constraint|
                try ctx.alloc.dupe(u8, constraint)
            else
                null,
        });
    }
    pkg.provides = try provides.toOwnedSlice(ctx.alloc);

    var conflicts: std.ArrayList(package.Constrained) = .empty;
    errdefer {
        for (conflicts.items) |*constraint| constraint.deinit(ctx.alloc);
        conflicts.deinit(ctx.alloc);
    }
    var conflict_rows = try conn.rows("SELECT * FROM conflicts WHERE package_id = ?1", .{id});
    defer conflict_rows.deinit();
    while (conflict_rows.next()) |r| {
        defer r.deinit();
        try conflicts.append(ctx.alloc, .{
            .name = try ctx.alloc.dupe(u8, r.cString(1)),
            .constraint = if (r.get(?[]const u8, 2)) |constraint|
                try ctx.alloc.dupe(u8, constraint)
            else
                null,
        });
    }
    pkg.conflicts = try conflicts.toOwnedSlice(ctx.alloc);

    var replaces: std.ArrayList(package.Constrained) = .empty;
    errdefer {
        for (replaces.items) |*constraint| constraint.deinit(ctx.alloc);
        replaces.deinit(ctx.alloc);
    }
    var replace_rows = try conn.rows("SELECT * FROM replaces WHERE package_id = ?1", .{id});
    defer replace_rows.deinit();
    while (replace_rows.next()) |r| {
        defer r.deinit();
        try replaces.append(ctx.alloc, .{
            .name = try ctx.alloc.dupe(u8, r.cString(1)),
            .constraint = if (r.get(?[]const u8, 2)) |constraint|
                try ctx.alloc.dupe(u8, constraint)
            else
                null,
        });
    }
    pkg.replaces = try replaces.toOwnedSlice(ctx.alloc);

    var licenses: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (licenses.items) |license| ctx.alloc.free(license);
        licenses.deinit(ctx.alloc);
    }
    var license_rows = try conn.rows("SELECT * FROM licenses WHERE package_id = ?1", .{id});
    defer license_rows.deinit();
    while (license_rows.next()) |r| {
        defer r.deinit();
        try licenses.append(
            ctx.alloc,
            try ctx.alloc.dupe(u8, r.cString(1)),
        );
    }
    pkg.licenses = try licenses.toOwnedSlice(ctx.alloc);

    return .{ .info = pkg, .conn = provider.conn.*, .id = id };
}

pub fn getProviderWithDeps(ctx: Context, name: []const u8, constraint: ?[]const u8) ![]package.Provider {
    var seen: std.AutoHashMap(i64, []const u8) = .init(ctx.alloc);
    defer {
        var it = seen.valueIterator();
        while (it.next()) |n| ctx.alloc.free(n.*);
        seen.deinit();
    }

    return try getProviderWithDepsRecursive(ctx, name, true, &seen, constraint);
}

fn getProviderWithDepsRecursive(
    ctx: Context,
    name: []const u8,
    first: bool,
    seen: *std.AutoHashMap(i64, []const u8),
    constraint: ?[]const u8,
) ![]package.Provider {
    const current = try getProvider(ctx, name, first);
    errdefer current.deinit(ctx.alloc);

    if (seen.get(current.id)) |existing| {
        if (constraint) |c| {
            if (!try satisfiesConstraint(existing, c))
                return error.ConflictingDependencies;
        }

        current.deinit(ctx.alloc);
        return &.{};
    }

    if (constraint) |c| {
        if (!try satisfiesConstraint(current.info.version, c))
            return error.ConflictingDependencies;
    }

    const current_version = try ctx.alloc.dupe(u8, current.info.version);
    errdefer ctx.alloc.free(current_version);
    try seen.put(current.id, current_version);

    var providers: std.ArrayList(package.Provider) = .empty;
    errdefer {
        for (providers.items) |provider| provider.deinit(ctx.alloc);
        providers.deinit(ctx.alloc);
    }

    try providers.append(ctx.alloc, current);
    for (current.info.deps) |dep| {
        const children = try getProviderWithDepsRecursive(
            ctx,
            dep.name,
            false,
            seen,
            dep.constraint,
        );
        defer ctx.alloc.free(children);
        try providers.appendSlice(ctx.alloc, children);
    }

    return try providers.toOwnedSlice(ctx.alloc);
}

fn satisfiesConstraint(local: []const u8, constraint: []const u8) !bool {
    var comp: u8 = undefined;
    var op_len: u8 = undefined;

    if (constraint.len >= 2) {
        if (comps.get(constraint[0..2])) |c| {
            comp = c;
            op_len = 2;
        } else if (comps.get(constraint[0..1])) |c| {
            comp = c;
            op_len = 1;
        } else return error.InvalidDependencyConstraint;
    } else {
        comp = comps.get(constraint[0..1]) orelse return error.InvalidDependencyConstraint;
        op_len = 1;
    }

    const res = version.cmp(local, constraint[op_len..]);
    return switch (comp) {
        0 => res == 1,
        1 => res == -1,
        2 => res >= 0,
        3 => res <= 0,
        else => unreachable,
    };
}
