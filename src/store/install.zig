const std = @import("std");
const Io = std.Io;
const download = @import("../net/download.zig");
const Context = @import("context.zig").Context;
const zqlite = @import("zqlite");
const archive = @import("../utils/archive.zig");
const package = @import("../core/package.zig");
const ingest = @import("../store/ingest.zig");
const sqlite = @import("../utils/sqlite.zig");

const RelationStmts = struct {
    package: zqlite.Stmt,
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
        .package =
        \\INSERT INTO packages(name, arch, epoch, version, release, explicit, repo)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        \\ON CONFLICT(name, arch, epoch, version, release) DO UPDATE SET
        \\  explicit = CASE WHEN packages.explicit = 1 THEN 1 ELSE excluded.explicit END
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

    pub fn init(context: Context, conn: zqlite.Conn) !RelationStmts {
        var self: RelationStmts = undefined;
        inline for (std.meta.fields(RelationStmts)) |field| {
            @field(self, field.name) = try sqlite.prepare(context, conn, @field(sql, field.name));
        }
        return self;
    }

    pub fn deinit(self: *RelationStmts) void {
        inline for (std.meta.fields(RelationStmts)) |field| {
            @field(self, field.name).deinit();
        }
    }
};

fn persistRelations(
    id: i64,
    pkg_info: package.PackageInfo,
    stmts: RelationStmts,
) !void {
    try sqlite.bindAndExec(stmts.del_deps, .{id});
    try sqlite.bindAndExec(stmts.del_provs, .{id});
    try sqlite.bindAndExec(stmts.del_confs, .{id});
    try sqlite.bindAndExec(stmts.del_reps, .{id});
    try sqlite.bindAndExec(stmts.del_lics, .{id});

    for (pkg_info.deps) |dep|
        try sqlite.bindAndExec(stmts.ins_deps, .{ id, dep.name, @intFromEnum(dep.kind), dep.constraint });
    for (pkg_info.provides) |provide|
        try sqlite.bindAndExec(stmts.ins_provs, .{ id, provide.name, provide.constraint });
    for (pkg_info.conflicts) |confs|
        try sqlite.bindAndExec(stmts.ins_confs, .{ id, confs.name, confs.constraint });
    for (pkg_info.replaces) |reps|
        try sqlite.bindAndExec(stmts.ins_reps, .{ id, reps.name, reps.constraint });
    for (pkg_info.licenses) |license|
        try sqlite.bindAndExec(stmts.ins_lics, .{ id, license });
}

pub fn installPackages(context: Context, providers: []package.Provider) !void {
    const store_conn = try context.getStore();

    var stmts: RelationStmts = try .init(context, store_conn);
    defer stmts.deinit();
    for (providers) |provider| try installPackage(
        context,
        provider,
        stmts,
    );
}

pub fn installPackage(
    context: Context,
    provider: package.Provider,
    stmts: RelationStmts,
) !void {
    const store_conn = try context.getStore();

    var client = try download.CurlClient.init(context);
    defer client.deinit(context);

    const repo = provider.db.repo;
    const pkg = provider.info;

    const pkg_filename = try resolvePkgFilename(context, pkg.*);
    defer context.alloc.free(pkg_filename);
    const dest = try Io.Dir.path.join(context.alloc, &.{
        context.path_options.root,
        context.path_options.cache,
        "pkgs",
        pkg_filename,
    });
    defer context.alloc.free(dest);

    if (Io.Dir.path.dirname(dest)) |dir| {
        try Io.Dir.cwd().createDirPath(context.io, dir);
    }

    client.downloadFromMirrors(context, repo.*, pkg_filename, dest) catch |err| switch (err) {
        error.AllMirrorsFailed => {
            try context.log(
                .Error,
                "Failed to download package archive for '{s}'\n",
                .{provider.info.name},
            );
            return err;
        },
        else => return err,
    };

    var reader = try archive.Reader.init();
    defer reader.deinit();

    const file = Io.Dir.cwd().openFile(
        context.io,
        dest,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => {
            try context.log(
                .Error,
                "Failed to download package archive for '{s}'\n",
                .{provider.info.name},
            );
            return err;
        },
        else => return err,
    };
    defer file.close(context.io);

    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});

    var reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(context.io, &reader_buf);
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

    try store_conn.transaction();
    errdefer store_conn.rollback();

    try stmts.package.bind(.{
        pkg.name,
        pkg.arch,
        pkg.epoch,
        pkg.version,
        pkg.release,
        pkg.explicit,
        pkg.repo,
    });
    defer stmts.package.reset();
    _ = try stmts.package.step();
    const store_id = stmts.package.int(0);

    try ingest.ingestPackage(context, &reader, store_id);
    try persistRelations(store_id, pkg.*, stmts);

    try store_conn.commit();
}

fn resolvePkgFilename(context: Context, pkg: package.PackageInfo) ![]const u8 {
    const ver = try if (pkg.epoch != 0)
        std.fmt.allocPrint(context.alloc, "{d}:{s}", .{ pkg.epoch, pkg.version })
    else
        std.fmt.allocPrint(context.alloc, "{s}", .{pkg.version});
    defer context.alloc.free(ver);

    const full_ver = try if (pkg.release) |rel|
        std.fmt.allocPrint(context.alloc, "{s}-{s}", .{ ver, rel })
    else
        std.fmt.allocPrint(context.alloc, "{s}", .{ver});
    defer context.alloc.free(full_ver);

    return std.fmt.allocPrint(context.alloc, "{s}-{s}-{s}.pkg.tar.zst", .{
        pkg.name,
        full_ver,
        pkg.arch,
    });
}
