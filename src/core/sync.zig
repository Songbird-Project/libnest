const std = @import("std");
const Io = std.Io;
const r = @import("repo.zig");
const RepoConn = r.RepoConn;
const StoreConn = @import("../store/store.zig").StoreConn;
const download = @import("../net/download.zig");
const Context = @import("context.zig").Context;
const zqlite = @import("zqlite");
const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");
const package = @import("package.zig");
const ingest = @import("../store/ingest.zig");

const RelationStmts = struct {
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

    pub fn init(ctx: Context, conn: zqlite.Conn) !RelationStmts {
        return .{
            .del_deps = try prepare(ctx, conn, "DELETE FROM depends WHERE package_id = ?1"),
            .del_provs = try prepare(ctx, conn, "DELETE FROM provides WHERE package_id = ?1"),
            .del_confs = try prepare(ctx, conn, "DELETE FROM conflicts WHERE package_id = ?1"),
            .del_reps = try prepare(ctx, conn, "DELETE FROM replaces WHERE package_id = ?1"),
            .del_lics = try prepare(ctx, conn, "DELETE FROM licenses WHERE package_id = ?1"),
            .ins_deps = try prepare(ctx, conn, "INSERT INTO depends(package_id, name, kind, ver_constraint) VALUES (?1, ?2, ?3, ?4)"),
            .ins_provs = try prepare(ctx, conn, "INSERT INTO provides(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)"),
            .ins_confs = try prepare(ctx, conn, "INSERT INTO conflicts(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)"),
            .ins_reps = try prepare(ctx, conn, "INSERT INTO replaces(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)"),
            .ins_lics = try prepare(ctx, conn, "INSERT INTO licenses(package_id, name) VALUES (?1, ?2)"),
        };
    }

    pub fn deinit(self: *RelationStmts) void {
        self.del_deps.deinit();
        self.del_provs.deinit();
        self.del_confs.deinit();
        self.del_reps.deinit();
        self.del_lics.deinit();
        self.ins_deps.deinit();
        self.ins_provs.deinit();
        self.ins_confs.deinit();
        self.ins_reps.deinit();
        self.ins_lics.deinit();
    }
};

const PackageInsertStmt = zqlite.Stmt;

pub fn initPackageInsertStmt(ctx: Context, conn: zqlite.Conn) !PackageInsertStmt {
    return try prepare(
        ctx,
        conn,
        \\INSERT INTO packages(name, epoch, version, release, explicit, arch, repo)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        \\ON CONFLICT(name) DO UPDATE SET
        \\  epoch = excluded.epoch,
        \\  version = excluded.version,
        \\  release = excluded.release,
        \\  explicit = excluded.explicit
        \\RETURNING id;
        ,
    );
}

pub fn syncAllRepos(ctx: Context) !void {
    var it = ctx.repos.valueIterator();
    while (it.next()) |conn| {
        try syncRepo(ctx, conn);
    }
}

pub fn syncRepo(ctx: Context, conn: RepoConn) !void {
    const repo = conn.repo;

    var client = try download.CurlClient.init(ctx);
    defer client.deinit(ctx);

    const db_name = try std.fmt.allocPrint(
        ctx.alloc,
        "{s}-{s}.db",
        .{ repo.name, repo.arch },
    );
    defer ctx.alloc.free(db_name);
    const dest = try std.Io.Dir.path.join(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.cache,
        "db",
        db_name,
    });
    defer ctx.alloc.free(dest);

    if (std.Io.Dir.path.dirname(dest)) |dir| {
        try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    }

    var db_name_buf: [128]u8 = undefined;
    const db_filename = try std.fmt.bufPrint(
        &db_name_buf,
        "{s}.db",
        .{repo.name},
    );
    client.downloadFromMirror(ctx, conn, db_filename, dest) catch |err| switch (err) {
        error.AllMirrorsFailed => {},
        else => return err,
    };

    var reader = try archive.Reader.init();
    defer reader.deinit();

    const db_file = std.Io.Dir.cwd().openFile(
        ctx.io,
        dest,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.log(
                .Error,
                "Failed to download repo file for '{s}'\n",
                .{repo.name},
            );
            return err;
        },
        else => return err,
    };
    defer db_file.close(ctx.io);

    var db_hasher: std.crypto.hash.Blake3 = .init(.{});
    var reader_buf: [4096]u8 = undefined;
    var db_reader = db_file.reader(ctx.io, &reader_buf);
    const io_reader = &db_reader.interface;

    var db_buf: [4096]u8 = undefined;
    while (true) {
        const bytes = try io_reader.readSliceShort(&db_buf);
        if (bytes <= 0) break;
        db_hasher.update(db_buf[0..bytes]);
    }

    var db_hash: [32]u8 = undefined;
    db_hasher.final(&db_hash);

    const existing_hash_row = try conn.conn.row("SELECT hash FROM metadata", .{});
    if (existing_hash_row) |row| {
        defer row.deinit();
        if (row.get(?[]const u8, 0)) |blob| {
            if (blob.len != 32) return error.InvalidHash;
            if (std.mem.eql(u8, blob, &db_hash)) {
                try ctx.log(.Info, "{s} is up to date", .{conn.repo.name});
                return;
            }
        }
    }

    try db_reader.seekTo(0);
    try reader.openFd(db_file.handle);
    var buf: [16384]u8 = undefined;

    const sync_stmt = try prepare(
        ctx,
        conn.conn,
        \\INSERT INTO packages(name, checksum, epoch, version, release)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
        \\ON CONFLICT(name) DO UPDATE SET
        \\  checksum = excluded.checksum,
        \\  epoch = excluded.epoch,
        \\  version = excluded.version,
        \\  release = excluded.release
        \\WHERE vercmp(excluded.epoch, excluded.version, excluded.release,
        \\             packages.epoch, packages.version, packages.release) > 0
        \\RETURNING id;
        ,
    );

    var stmts: RelationStmts = try .init(ctx, conn.conn);
    defer stmts.deinit();

    try conn.conn.transaction();
    errdefer conn.conn.rollback();

    var arena: std.heap.ArenaAllocator = .init(ctx.alloc);
    defer arena.deinit();

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(ctx.alloc);

    while (try reader.nextEntry()) |entry| {
        contents.clearRetainingCapacity();
        defer _ = arena.reset(.retain_capacity);

        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(path), "desc")) continue;

        while (true) {
            const read = try reader.readData(&buf);
            if (read <= 0) break;
            try contents.appendSlice(ctx.alloc, buf[0..read]);
        }

        const pkg_info = try desc.parse(
            arena.allocator(),
            repo.name,
            contents.items,
        );

        if (!std.mem.eql(u8, pkg_info.arch, repo.arch) and
            !std.mem.eql(u8, pkg_info.arch, "any")) continue;

        try sync_stmt.bind(.{
            pkg_info.name,
            if (pkg_info.checksum) |sum| &sum else null,
            pkg_info.epoch,
            pkg_info.version,
            pkg_info.release,
        });
        const row = try sync_stmt.step();

        if (row) {
            const id = sync_stmt.int(0);
            try persistRelations(id, pkg_info, stmts);
        }

        try sync_stmt.reset();
    }

    try conn.conn.exec("UPDATE metadata SET last_refresh = unixepoch(), hash = ?1", .{&db_hash});
    try conn.conn.commit();
}

pub fn syncPackages(ctx: Context, store_conn: StoreConn, providers: []package.Provider) !void {
    try store_conn.transaction();
    errdefer store_conn.rollback();
    var stmts: RelationStmts = try .init(ctx, store_conn);
    defer stmts.deinit();
    const ins = try initPackageInsertStmt(ctx, store_conn);
    defer ins.deinit();
    for (providers) |provider| try syncPackage(
        ctx,
        store_conn,
        provider,
        stmts,
        ins,
    );
    try store_conn.commit();
}

/// `syncPackage` requires that a valid transaction is already active
pub fn syncPackage(
    ctx: Context,
    store_conn: StoreConn,
    provider: package.Provider,
    stmts: RelationStmts,
    insert_stmt: PackageInsertStmt,
) !void {
    var client = try download.CurlClient.init(ctx);
    defer client.deinit(ctx);

    const repo = provider.conn;
    var pkg = provider.info;

    const pkg_filename = try resolvePkgFilename(ctx, pkg);
    defer ctx.alloc.free(pkg_filename);
    const dest = try Io.Dir.path.join(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.cache,
        "pkgs",
        pkg_filename,
    });
    defer ctx.alloc.free(dest);

    if (std.Io.Dir.path.dirname(dest)) |dir| {
        try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    }

    client.downloadFromMirror(ctx, repo, pkg_filename, dest) catch |err| switch (err) {
        error.AllMirrorsFailed => {},
        else => return err,
    };

    var reader = try archive.Reader.init();
    defer reader.deinit();

    const file = std.Io.Dir.cwd().openFile(
        ctx.io,
        dest,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.log(
                .Error,
                "Failed to download package archive for '{s}'\n",
                .{provider.info.name},
            );
            return err;
        },
        else => return err,
    };
    defer file.close(ctx.io);

    var hasher: std.crypto.hash.sha2.Sha256 = .init();

    var reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(ctx.io, &reader_buf);
    const io_reader = &file_reader.interface;

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes = try io_reader.readSliceShort(&buf);
        if (bytes <= 0) break;
        hasher.update(buf[0..bytes]);
    }

    var sum: [32]u8 = undefined;
    hasher.final(&sum);
    if (pkg.checksum != null and !std.mem.eql(u8, &sum, &pkg.checksum.?)) return error.CorruptFile;

    try file_reader.seekTo(0);
    try reader.openFd(file.handle);

    const existing = try store_conn.row("SELECT explicit FROM packages WHERE name = ?1", .{pkg.name});
    if (existing) |er| {
        defer er.deinit();
        pkg.explicit = if (er.int(0) != 0) true else pkg.explicit;
    }

    try insert_stmt.bind(.{
        pkg.name,
        pkg.epoch,
        pkg.version,
        pkg.release,
        pkg.explicit,
        pkg.arch,
        pkg.repo,
    });
    _ = try insert_stmt.step();
    const store_id = insert_stmt.?.int(0);

    try ingest.ingestPackage(ctx, store_conn, reader, store_id);
    try persistRelations(store_id, pkg, stmts);

    try insert_stmt.reset();
}

fn prepare(ctx: Context, conn: zqlite.Conn, sql: []const u8) !zqlite.Stmt {
    return conn.prepare(sql) catch |err| {
        try ctx.log(.Error, "Failed to prepare SQL statement: {s}\n", .{conn.lastError()});
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
    stmts: RelationStmts,
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
