const std = @import("std");
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const Context = @import("context.zig").Context;
const package = @import("package.zig");
const version = @import("../utils/version.zig");
const download = @import("../net/download.zig");
const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");

pub const Repo = struct {
    name: []const u8,
    arch: []const u8,
    mirrors: []const []const u8,
    priority: i64,
    enabled: bool = true,
};

const RepoDatabaseStmts = struct {
    sync: zqlite.Stmt,
    del_deps: zqlite.Stmt,
    del_provs: zqlite.Stmt,
    del_confs: zqlite.Stmt,
    del_reps: zqlite.Stmt,
    del_lics: zqlite.Stmt,
    ins_deps: zqlite.Stmt,
    ins_provs: zqlite.Stmt,
    ins_confs: zqlite.Stmt,
    ins_reps: zqlite.Stmt,
    ins_lics: zqlite.Stmt,

    const sql = .{
        .sync =
        \\INSERT INTO packages(name, arch, checksum, epoch, version, release)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        \\ON CONFLICT(name, arch) DO UPDATE SET
        \\  checksum = excluded.checksum,
        \\  epoch = excluded.epoch,
        \\  version = excluded.version,
        \\  release = excluded.release
        \\WHERE vercmp(excluded.epoch, excluded.version, excluded.release,
        \\             packages.epoch, packages.version, packages.release) > 0
        \\RETURNING id;
        ,
        .del_deps = "DELETE FROM depends WHERE package_id = ?1",
        .del_provs = "DELETE FROM provides WHERE package_id = ?1",
        .del_confs = "DELETE FROM conflicts WHERE package_id = ?1",
        .del_reps = "DELETE FROM replaces WHERE package_id = ?1",
        .del_lics = "DELETE FROM licenses WHERE package_id = ?1",
        .ins_deps = "INSERT INTO depends(package_id, name, kind, ver_constraint) VALUES (?1, ?2, ?3, ?4)",
        .ins_provs = "INSERT INTO provides(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)",
        .ins_confs = "INSERT INTO conflicts(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)",
        .ins_reps = "INSERT INTO replaces(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)",
        .ins_lics = "INSERT INTO licenses(package_id, name) VALUES (?1, ?2)",
    };

    pub fn init(context: Context, conn: zqlite.Conn) !RepoDatabaseStmts {
        var self: RepoDatabaseStmts = undefined;
        inline for (std.meta.fields(RepoDatabaseStmts)) |field| {
            @field(self, field.name) = try prepare(context, conn, @field(sql, field.name));
        }
        return self;
    }

    pub fn deinit(self: *RepoDatabaseStmts) void {
        inline for (std.meta.fields(RepoDatabaseStmts)) |field| {
            @field(self, field.name).deinit();
        }
    }
};

fn prepare(context: Context, conn: zqlite.Conn, sql: []const u8) !zqlite.Stmt {
    return conn.prepare(sql) catch |err| {
        try context.log(.Error, "Failed to prepare SQL statement: {s}\n", .{conn.lastError()});
        return err;
    };
}

fn bindAndExec(stmt: zqlite.Stmt, values: anytype) !void {
    try stmt.bind(values);
    try stmt.stepToCompletion();
    try stmt.reset();
}

fn persistRelations(
    id: i64,
    pkg_info: package.PackageInfo,
    stmts: RepoDatabaseStmts,
) !void {
    try bindAndExec(stmts.del_deps, .{id});
    try bindAndExec(stmts.del_provs, .{id});
    try bindAndExec(stmts.del_confs, .{id});
    try bindAndExec(stmts.del_reps, .{id});
    try bindAndExec(stmts.del_lics, .{id});

    for (pkg_info.deps) |dep|
        try bindAndExec(stmts.ins_deps, .{ id, dep.name, @intFromEnum(dep.kind), dep.constraint });
    for (pkg_info.provides) |provide|
        try bindAndExec(stmts.ins_provs, .{ id, provide.name, provide.constraint });
    for (pkg_info.conflicts) |confs|
        try bindAndExec(stmts.ins_confs, .{ id, confs.name, confs.constraint });
    for (pkg_info.replaces) |reps|
        try bindAndExec(stmts.ins_reps, .{ id, reps.name, reps.constraint });
    for (pkg_info.licenses) |license|
        try bindAndExec(stmts.ins_lics, .{ id, license });
}

fn resolvePkgFilename(ctx: Context, pkg: package.PackageInfo) ![]const u8 {
    const ver = try if (pkg.epoch != 0)
        std.fmt.allocPrint(ctx.alloc, "{d}:{s}", .{ pkg.epoch, pkg.version })
    else
        std.fmt.allocPrint(ctx.alloc, "{s}", .{pkg.version});
    defer ctx.alloc.free(ver);

    const full_ver = try if (pkg.release) |rel|
        std.fmt.allocPrint(ctx.alloc, "{s}-{s}", .{ ver, rel })
    else
        std.fmt.allocPrint(ctx.alloc, "{s}", .{ver});
    defer ctx.alloc.free(full_ver);

    return std.fmt.allocPrint(ctx.alloc, "{s}-{s}-{s}.pkg.tar.zst", .{
        pkg.name,
        full_ver,
        pkg.arch,
    });
}

pub const RepoDatabase = struct {
    conn: zqlite.Conn,
    repo: *Repo,
    stmts: RepoDatabaseStmts,

    pub fn init(context: *Context, repo: Repo) !RepoDatabase {
        if (repo.mirrors.len <= 0) {
            try context.log(.Error, "Remote repos '{s}' has no mirrors listed\n", .{repo.name});
            return error.NoMirrors;
        }

        const name = try std.fmt.allocPrint(context.alloc, "{s}-{s}.db", .{ repo.name, repo.arch });
        defer context.alloc.free(name);
        const path = try std.Io.Dir.path.joinZ(context.alloc, &.{
            context.path_options.root,
            context.path_options.state,
            name,
        });
        defer context.alloc.free(path);

        if (std.Io.Dir.path.dirname(path)) |dir| {
            try std.Io.Dir.cwd().createDirPath(context.io, dir);
        }

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        const conn = zqlite.open(path, flags) catch |err| switch (err) {
            error.Busy => {
                try context.log(
                    .Error,
                    "Failed to open the '{s} {s}' repo db, another operation is probably in progress\n",
                    .{ repo.name, repo.arch },
                );
                return err;
            },
            else => return err,
        };
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
            \\  arch TEXT NOT NULL,
            \\  checksum BLOB,
            \\  epoch INTEGER NOT NULL DEFAULT 0,
            \\  version TEXT NOT NULL,
            \\  release TEXT,
            \\  UNIQUE(name, arch)
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
            try context.log(.Error, "Failed to register custom SQL function `vercmp`: {s}\n", .{conn.lastError()});
            return error.FailedToRegisterFunction;
        }

        const repo_ptr = try context.alloc.create(Repo);
        repo_ptr.* = repo;

        return .{
            .conn = conn,
            .repo = repo_ptr,
            .stmts = try .init(context, conn),
        };
    }

    pub fn deinit(self: *RepoDatabase, alloc: Allocator) void {
        self.stmts.deinit();
        self.conn.close();
        alloc.destroy(self.repo);
    }

    fn syncPackageInfo(
        self: *RepoDatabase,
        reader: *archive.Reader,
        entry: *archive.c.archive_entry,
        memory: struct {
            alloc: Allocator,
            parser_arena: *std.heap.ArenaAllocator,
            read_buffer: []u8,
            contents: *std.ArrayList(u8),
        },
    ) !void {
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(path), "desc")) return;

        while (true) {
            const read = try reader.readData(memory.read_buffer);
            if (read <= 0) break;
            try memory.contents.appendSlice(memory.alloc, memory.read_buffer[0..read]);
        }

        const pkg_info = try desc.parse(
            memory.parser_arena.allocator(),
            self.repo.name,
            memory.contents.items,
        );

        if (!std.mem.eql(u8, pkg_info.arch, self.repo.arch) and
            !std.mem.eql(u8, pkg_info.arch, "any")) return;

        try self.stmts.sync.bind(.{
            pkg_info.name,
            pkg_info.arch,
            if (pkg_info.checksum) |sum| blk: {
                var chk: [32]u8 = undefined;
                @memcpy(&chk, sum);
                break :blk &chk;
            } else null,
            pkg_info.epoch,
            pkg_info.version,
            pkg_info.release,
        });
        const row = try self.stmts.sync.step();

        if (row) {
            const id = self.stmts.sync.int(0);
            try persistRelations(id, pkg_info, self.stmts);
        }

        try self.stmts.sync.reset();
    }

    pub fn sync(self: *RepoDatabase, context: Context) !void {
        const alloc = context.alloc;
        const io = context.io;
        const repo = self.repo;

        var client = try download.CurlClient.init(context);
        defer client.deinit(context);

        const db_name = try std.fmt.allocPrint(
            alloc,
            "{s}-{s}.db",
            .{ repo.name, repo.arch },
        );
        defer alloc.free(db_name);
        const dest = try std.Io.Dir.path.join(alloc, &.{
            context.path_options.root,
            context.path_options.cache,
            "db",
            db_name,
        });
        defer alloc.free(dest);

        if (std.Io.Dir.path.dirname(dest)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);

        var db_name_buf: [128]u8 = undefined;
        const db_filename = try std.fmt.bufPrint(
            &db_name_buf,
            "{s}.db",
            .{repo.name},
        );

        client.downloadFromMirrors(context, repo.*, db_filename, dest) catch |err| switch (err) {
            error.FileNotFound => {
                try context.log(
                    .Error,
                    "Failed to download repo file for '{s}'\n",
                    .{repo.name},
                );
                return err;
            },
            else => return err,
        };

        var archive_reader = try archive.Reader.init();
        defer archive_reader.deinit();

        const db_file = try std.Io.Dir.cwd().openFile(io, dest, .{});
        defer db_file.close(io);

        var db_hasher: std.crypto.hash.Blake3 = .init(.{});
        var reader_buf: [4096]u8 = undefined;
        var db_file_reader = db_file.reader(io, &reader_buf);
        const db_reader = &db_file_reader.interface;

        var db_buf: [4096]u8 = undefined;
        while (true) {
            const bytes = try db_reader.readSliceShort(&db_buf);
            if (bytes <= 0) break;
            db_hasher.update(db_buf[0..bytes]);
        }

        var db_hash: [32]u8 = undefined;
        db_hasher.final(&db_hash);

        const existing_hash_row = try self.conn.row("SELECT hash FROM metadata", .{});
        if (existing_hash_row) |row| {
            defer row.deinit();
            if (row.nullableBlob(0)) |blob| {
                if (blob.len != 32) return error.InvalidHash;
                if (std.mem.eql(u8, blob, &db_hash)) {
                    try context.log(.Info, "{s} is up to date\n", .{repo.name});
                    return;
                }
            }
        }

        try db_reader.seekTo(0);
        try archive_reader.openFd(db_file.handle);

        try self.conn.transaction();
        errdefer self.conn.rollback();

        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();

        var contents: std.ArrayList(u8) = .empty;
        defer contents.deinit(alloc);

        var buf: [8192]u8 = undefined;
        while (try archive_reader.nextEntry()) |entry| {
            contents.clearRetainingCapacity();
            defer _ = arena.reset(.retain_capacity);
            try self.syncPackageInfo(alloc, &arena, &buf, &contents, &archive_reader, entry);
        }

        try self.conn.exec("UPDATE metadata SET last_refresh = unixepoch(), hash = ?1", .{&db_hash});
        try self.conn.commit();
    }
};

fn lessThanPriority(_: void, a: RepoDatabase, b: RepoDatabase) bool {
    return a.repo.priority < b.repo.priority;
}

pub const RepoDatabaseRegistry = struct {
    databases: []RepoDatabase,

    pub fn init(context: *Context, repos: []Repo) !RepoDatabaseRegistry {
        const alloc = context.alloc;

        var sorted: std.ArrayList(RepoDatabase) = .empty;
        errdefer sorted.deinit(alloc);
        for (repos) |repo| try sorted.append(alloc, try .init(context, repo));
        std.mem.sort(RepoDatabase, sorted.items, {}, lessThanPriority);

        return .{
            .databases = try sorted.toOwnedSlice(alloc),
        };
    }

    pub fn deinit(self: *RepoDatabaseRegistry, alloc: Allocator) void {
        for (self.databases) |*db| db.deinit(alloc);
    }
};
