const std = @import("std");
const Io = std.Io;
const r = @import("repo.zig");
const RepoConn = r.RepoConn;
const StoreConn = @import("../store/store.zig").StoreConn;
const download = @import("../net/download.zig");
const Ctx = @import("context.zig").Context;
const zqlite = @import("zqlite");
const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");
const package = @import("package.zig");
const ingest = @import("../store/ingest.zig");

pub fn syncAllRepos(ctx: Ctx) !void {
    var it = ctx.repos.valueIterator();
    while (it.next()) |conn| {
        try syncRepo(ctx, conn);
    }
}

pub fn syncRepo(ctx: Ctx, conn: RepoConn) !void {
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

    try reader.openFd(db_file.handle);
    var buf: [8192]u8 = undefined;

    const sync_stmt = conn.conn.prepare(
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
    ) catch |err| {
        try ctx.log(.Error, "Failed to prepare SQL statement: {s}\n", .{conn.conn.lastError()});
        return err;
    };

    try conn.conn.transaction();

    while (try reader.nextEntry()) |entry| {
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(path), "desc")) continue;

        var contents: std.ArrayList(u8) = .empty;
        defer contents.deinit(ctx.alloc);

        while (true) {
            const read = try reader.readData(&buf);
            if (read <= 0) break;
            try contents.appendSlice(ctx.alloc, buf[0..read]);
        }

        var pkg_info = try desc.parse(
            ctx.alloc,
            repo.name,
            contents.items,
        );
        defer pkg_info.deinit(ctx.alloc);

        if (!std.mem.eql(u8, pkg_info.arch, repo.arch) and
            !std.mem.eql(u8, pkg_info.arch, "any")) continue;

        try conn.conn.execNoArgs("SAVEPOINT pkg");
        errdefer conn.conn.execNoArgs("ROLLBACK TO pkg") catch {};

        try sync_stmt.bind(.{
            pkg_info.name,
            pkg_info.checksum,
            pkg_info.epoch,
            pkg_info.version,
            pkg_info.release,
        });
        const row = try sync_stmt.step();

        if (row) {
            const id = sync_stmt.int(0);
            try persistRelations(conn.conn, id, pkg_info);
        }

        try sync_stmt.reset();
        try conn.conn.execNoArgs("RELEASE pkg");
    }
    try conn.conn.commit();
}

pub fn syncPkg(ctx: Ctx, store_conn: StoreConn, name: []const u8) !void {
    var client = try download.CurlClient.init(ctx);
    defer client.deinit(ctx);

    const provider = r.getProvider(ctx, name) catch |err| switch (err) {
        error.ProviderNotFound => {
            try ctx.log(.Error, "Failed to find provider for '{s}'\n", .{name});
            return error.ProviderNotFound;
        },
        else => return err,
    };

    const id = provider.id;
    const repo = provider.conn;
    var pkg = provider.info;
    defer pkg.deinit(ctx.alloc);

    const pkg_filename = try resolvePkgFilename(ctx, pkg);
    defer ctx.alloc.free(pkg_filename);
    const dest = try Io.Dir.path.join(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.cache,
        "pkgs",
        pkg_filename,
    });

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
                .{name},
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

    file_reader.seekTo(0);
    try reader.openFd(file.handle);

    try store_conn.transaction();
    errdefer store_conn.rollback();

    try ingest.ingestPackage(ctx, store_conn, reader, id);
    try persistRelations(store_conn, id, pkg);

    try store_conn.commit();
}

fn persistRelations(conn: zqlite.Conn, id: i64, pkg_info: package.PackageInfo) !void {
    try conn.exec("DELETE FROM depends WHERE package_id = ?1;", .{id});
    try conn.exec("DELETE FROM provides WHERE package_id = ?1;", .{id});
    try conn.exec("DELETE FROM conflicts WHERE package_id = ?1;", .{id});
    try conn.exec("DELETE FROM replaces WHERE package_id = ?1;", .{id});
    try conn.exec("DELETE FROM licenses WHERE package_id = ?1;", .{id});
    for (pkg_info.deps) |dep| {
        try conn.exec(
            \\INSERT INTO depends(package_id, name, kind, ver_constraint) VALUES (?1, ?2, ?3, ?4)
        , .{ id, dep.name, @intFromEnum(dep.kind), dep.constraint });
    }
    for (pkg_info.provides) |provide| {
        try conn.exec(
            \\INSERT INTO provides(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)
        , .{ id, provide.name, provide.constraint });
    }

    for (pkg_info.conflicts) |confs| {
        try conn.exec(
            \\INSERT INTO conflicts(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)
        , .{ id, confs.name, confs.constraint });
    }
    for (pkg_info.replaces) |reps| {
        try conn.exec(
            \\INSERT INTO replaces(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)
        , .{ id, reps.name, reps.constraint });
    }
    for (pkg_info.licenses) |license| {
        try conn.exec(
            \\INSERT INTO licenses(package_id, name) VALUES (?1, ?2)
        , .{ id, license });
    }
}

fn resolvePkgFilename(ctx: Ctx, pkg: package.PackageInfo) ![]const u8 {
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
