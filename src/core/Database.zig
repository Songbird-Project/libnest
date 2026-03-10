const std = @import("std");

const Downloader = @import("../net/Downloader.zig");
const MirrorList = @import("../net/MirrorList.zig");
const Pkg = @import("Package.zig");

const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");
const mdb = @import("../utils/mdb.zig");

const DbError = error{
    RelativePathInPkg,
    RelativePathInMTREE,
    CorruptPkg,
} || archive.ArchiveError || mdb.MDBError;

const Db = @This();

alloc: std.mem.Allocator,
env: *mdb.c.MDB_env,
pkgs_db: mdb.c.MDB_dbi,
files_db: mdb.c.MDB_dbi,
installed_db: mdb.c.MDB_dbi,
file_lkp: mdb.c.MDB_dbi,
pkg_lkp: mdb.c.MDB_dbi,

pub fn init(alloc: std.mem.Allocator, path: []const u8) DbError!Db {
    var env: ?*mdb.c.MDB_env = null;
    try mdb.checkCode(mdb.c.mdb_env_create(&env));
    errdefer mdb.c.mdb_env_close(env.?);

    try mdb.checkCode(mdb.c.mdb_env_set_maxdbs(env.?, 7));
    try mdb.checkCode(mdb.c.mdb_env_set_mapsize(env.?, 5 * 1024 * 1024 * 1024));

    try mdb.checkCode(mdb.c.mdb_env_open(
        env.?,
        path.ptr,
        mdb.c.MDB_NOSUBDIR,
        0o644,
    ));

    var txn: ?*mdb.c.MDB_txn = undefined;
    try mdb.checkCode(mdb.c.mdb_txn_begin(env.?, null, 0, &txn));

    var pkgs_db: mdb.c.MDB_dbi = undefined;
    var files_db: mdb.c.MDB_dbi = undefined;
    var installed_db: mdb.c.MDB_dbi = undefined;
    var pkg_lkp: mdb.c.MDB_dbi = undefined;
    var file_lkp: mdb.c.MDB_dbi = undefined;

    try mdb.checkCode(mdb.c.mdb_dbi_open(
        txn.?,
        "packages",
        mdb.c.MDB_CREATE,
        &pkgs_db,
    ));
    try mdb.checkCode(mdb.c.mdb_dbi_open(
        txn.?,
        "files",
        mdb.c.MDB_CREATE,
        &files_db,
    ));
    try mdb.checkCode(mdb.c.mdb_dbi_open(
        txn.?,
        "installed",
        mdb.c.MDB_CREATE,
        &installed_db,
    ));
    try mdb.checkCode(mdb.c.mdb_dbi_open(
        txn.?,
        "package_lookup",
        mdb.c.MDB_CREATE | mdb.c.MDB_DUPSORT,
        &pkg_lkp,
    ));
    try mdb.checkCode(mdb.c.mdb_dbi_open(
        txn.?,
        "file_lookup",
        mdb.c.MDB_CREATE | mdb.c.MDB_DUPSORT,
        &file_lkp,
    ));

    try mdb.checkCode(mdb.c.mdb_txn_commit(txn.?));

    return .{
        .alloc = alloc,
        .env = env.?,
        .pkgs_db = pkgs_db,
        .files_db = files_db,
        .installed_db = installed_db,
        .pkg_lkp = pkg_lkp,
        .file_lkp = file_lkp,
    };
}

pub fn deinit(self: *Db) void {
    mdb.c.mdb_dbi_close(self.env, self.pkgs_db);
    mdb.c.mdb_dbi_close(self.env, self.files_db);
    mdb.c.mdb_dbi_close(self.env, self.installed_db);
    mdb.c.mdb_dbi_close(self.env, self.pkg_lkp);
    mdb.c.mdb_dbi_close(self.env, self.file_lkp);
    mdb.c.mdb_env_close(self.env);
}

pub fn queryLkpRepo(
    self: *Db,
    txn: *mdb.c.MDB_txn,
    dbi: mdb.c.MDB_dbi,
    name: []const u8,
) DbError![][]u8 {
    var cursor: ?*mdb.c.MDB_cursor = null;
    try mdb.checkCode(
        mdb.c.mdb_cursor_open(txn, dbi, &cursor),
    );
    defer mdb.c.mdb_cursor_close(cursor);

    var pkgs: std.ArrayList([]u8) = .empty;
    defer pkgs.deinit(self.alloc);

    var key: mdb.c.MDB_val = mdb.mdbVal(name);
    var mdb_val: mdb.c.MDB_val = undefined;

    mdb.checkCode(mdb.c.mdb_cursor_get(
        cursor.?,
        &key,
        &mdb_val,
        mdb.c.MDB_SET,
    )) catch |err| switch (err) {
        error.NotFound => return &[_]u8{},
        else => {},
    };

    while (true) {
        const data = @as([*]const u8, @ptrCast(mdb_val.mv_data))[0..mdb_val.mv_size];
        const val = try self.alloc.dupe(u8, data);
        try pkgs.append(
            self.alloc,
            val,
        );

        mdb.checkCode(mdb.c.mdb_cursor_get(
            cursor.?,
            &key,
            &mdb_val,
            mdb.c.MDB_NEXT_DUP,
        )) catch |err| switch (err) {
            error.Success => {},
            else => break,
        };
    }

    return pkgs.toOwnedSlice(self.alloc);
}

pub fn queryPkg(self: *Db, alloc: std.mem.Allocator, txn: *mdb.c.MDB_txn, key: []const u8) DbError!Pkg {
    var val: mdb.c.MDB_val = undefined;
    const mdb_key = mdb.mdbVal(key);
    try mdb.checkCode(mdb.c.mdb_get(
        txn,
        self.pkgs_db,
        &mdb_key,
        &val,
    ));

    return try mdb.readPkg(alloc, val);
}

pub fn insertInstalledPkg(
    alloc: std.mem.Allocator,
    txn: *mdb.c.MDB_txn,
    dbi: mdb.c.MDB_dbi,
    key: mdb.c.MDB_val,
    fields: Pkg.Installed,
) DbError!void {
    const pkg_len =
        @sizeOf(Pkg.Installed.Header) +
        fields.version.len +
        fields.description.len +
        fields.url.len +
        fields.arch.len +
        fields.license.len +
        fields.packager.len +
        fields.deps.len +
        fields.optdeps.len;
    var buf = try alloc.alloc(u8, pkg_len);
    defer alloc.free(buf);
    var w: usize = 0;

    const header: Pkg.Installed.Header = .{
        .build_date = fields.build_date,
        .size = fields.size,
        .version_len = @intCast(fields.version.len),
        .description_len = @intCast(fields.description.len),
        .url_len = @intCast(fields.url.len),
        .arch_len = @intCast(fields.arch.len),
        .license_len = @intCast(fields.license.len),
        .packager_len = @intCast(fields.packager.len),
        .deps_len = @intCast(fields.deps.len),
        .optdeps_len = @intCast(fields.optdeps.len),
    };

    @memmove(
        buf[0..@sizeOf(Pkg.Installed.Header)],
        std.mem.asBytes(&header),
    );
    w += @sizeOf(Pkg.Installed.Header);

    inline for ([_][]const u8{
        fields.version,
        fields.description,
        fields.url,
        fields.arch,
        fields.license,
        fields.packager,
        fields.deps,
        fields.optdeps,
    }) |field| {
        @memmove(buf[w..][0..field.len], field);
        w += field.len;
    }

    var val = mdb.mdbVal(buf[0..w]);

    try mdb.checkCode(mdb.c.mdb_put(
        txn,
        dbi,
        &key,
        &val,
        0,
    ));
}

pub fn readInstalledPkg(alloc: std.mem.Allocator, val: mdb.c.MDB_val) DbError!Pkg.Installed {
    const raw = @as([*]const u8, @ptrCast(val.mv_data));
    if (val.mv_size < @sizeOf(Pkg.Installed.Header)) return error.CorruptPkg;

    var header: Pkg.Installed.Header = undefined;
    @memcpy(
        std.mem.asBytes(&header),
        raw[0..@sizeOf(Pkg.Installed.Header)],
    );
    const expected = @sizeOf(Pkg.Installed.Header) +
        header.version_len +
        header.description_len +
        header.url_len +
        header.arch_len +
        header.license_len +
        header.packager_len +
        header.deps_len +
        header.optdeps_len;
    if (expected > val.mv_size) return error.CorruptPkg;

    var ptr: usize = @sizeOf(Pkg.Installed.Header);
    return .{
        .build_date = header.build_date,

        .version = alloc.dupe(u8, Pkg.Installed.Header.nextField(raw, header.version_len, &ptr)),
        .description = alloc.dupe(u8, Pkg.Installed.Header.nextField(raw, header.description_len, &ptr)),
        .url = alloc.dupe(u8, Pkg.Installed.Header.nextField(raw, header.url_len, &ptr)),
        .arch = alloc.dupe(u8, Pkg.Installed.Header.nextField(raw, header.arch_len, &ptr)),
        .license = alloc.dupe(u8, Pkg.Installed.Header.nextField(raw, header.license_len, &ptr)),
        .packager = alloc.dupe(u8, Pkg.Installed.Header.nextField(raw, header.packager_len, &ptr)),
        .deps = alloc.dupe(u8, Pkg.Installed.Header.nextField(raw, header.deps_len, &ptr)),
        .optdeps = alloc.dupe(u8, Pkg.Installed.Header.nextField(raw, header.optdeps_len, &ptr)),
    };
}

pub fn queryInstalledPkg(
    self: *Db,
    alloc: std.mem.Allocator,
    txn: *mdb.c.MDB_txn,
    key: []const u8,
) DbError!Pkg.Installed {
    var val: mdb.c.MDB_val = undefined;
    const mdb_key = mdb.mdbVal(key);
    try mdb.checkCode(mdb.c.mdb_get(
        txn,
        self.installed_db,
        &mdb_key,
        &val,
    ));

    return try readInstalledPkg(alloc, val);
}

pub fn sync(
    self: *Db,
    mirrors: *MirrorList,
    dest_dir: []const u8,
    repo: []const u8,
    arch: []const u8,
    batch_size: usize,
    download_cb: ?*const Downloader.callback,
) DbError!void {
    var batched: usize = 0;
    var txn: ?*mdb.c.MDB_txn = null;

    errdefer if (txn) |t| mdb.c.mdb_txn_abort(t);

    var reader = try archive.Reader.init();
    defer reader.deinit();

    const trailing_slash = if (dest_dir[dest_dir.len - 1] == '/') true else false;
    const dest = try std.fmt.allocPrint(
        self.alloc,
        "{s}{s}{s}.db",
        .{
            dest_dir,
            if (!trailing_slash) "/" else "",
            repo,
        },
    );
    defer self.alloc.free(dest);

    try mirrors.downloadDb(
        repo,
        arch,
        dest,
        download_cb,
    );

    const file = try std.fs.cwd().openFile(
        dest,
        .{ .mode = .read_only },
    );
    defer file.close();

    try reader.openFd(file.handle);
    var buf: [8192]u8 = undefined;
    while (try reader.nextEntry()) |entry| {
        const pathrepo: []const u8 = std.mem.span(archive.mdb.c.archive_entry_pathname(entry));
        const delim = std.mem.lastIndexOfScalar(u8, pathrepo, '/');

        if (delim == null) {
            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes == 0) break;
            }
            continue;
        }

        const is_desc = std.mem.eql(u8, pathrepo[delim.? + 1 ..], "desc");

        if (!is_desc) {
            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes == 0) break;
            }
            continue;
        }

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.alloc);

        while (true) {
            const bytes = try reader.readData(&buf);
            if (bytes <= 0) break;
            try content.appendSlice(self.alloc, buf[0..bytes]);
        }

        if (is_desc) {
            if (batched >= batch_size and txn != null) {
                try mdb.checkCode(mdb.c.mdb_txn_commit(txn.?));
                batched = 0;
                txn = null;
            }
            if (txn == null) {
                try mdb.checkCode(mdb.c.mdb_txn_begin(
                    self.env,
                    null,
                    0,
                    &txn,
                ));
            }

            try desc.index(
                self.alloc,
                self,
                txn.?,
                content.items,
                repo,
            );

            batched += 1;
        }
    }

    if (txn != null) {
        try mdb.checkCode(mdb.c.mdb_txn_commit(txn.?));
    }
}

pub fn install(
    self: *Db,
    mirrors: *MirrorList,
    key: mdb.c.MDB_val,
    pkg: Pkg,
    txn: *mdb.c.MDB_txn,
    prefix: ?[]const u8,
    download_cb: ?*const Downloader.callback,
) DbError!void {
    var reader = try archive.Reader.init();
    defer reader.deinit();

    const writer = try archive.Writer.init();
    defer writer.deinit();

    const pkg_key = @as([*]const u8, @ptrCast(key.mv_data))[0..key.mv_size];

    const cache = try std.fs.path.join(self.alloc, &.{
        prefix orelse "/",
        "var",
        "cache",
        if (std.mem.indexOf(u8, pkg.filename, ".pkg.tar.")) |i|
            pkg.filename[0..i]
        else
            pkg.checksum,
    });
    defer self.alloc.free(cache);
    try std.fs.cwd().makePath(cache);

    const tmp_path = try std.fs.path.join(self.alloc, &.{
        prefix orelse "/",
        "tmp",
        if (std.mem.indexOf(u8, pkg.filename, ".pkg.tar.")) |i|
            pkg.filename[0..i]
        else
            pkg.checksum,
    });
    defer self.alloc.free(tmp_path);
    try std.fs.cwd().makePath(tmp_path);

    const dest = try std.fs.path.join(self.alloc, &.{
        cache,
        pkg.filename,
    });
    defer self.alloc.free(dest);

    try mirrors.downloadPkg(
        key,
        pkg,
        dest,
        download_cb,
    );

    const file = try std.fs.cwd().openFile(
        dest,
        .{ .mode = .read_only },
    );
    defer file.close();

    try reader.openFd(file.handle);
    var buf: [8192]u8 = undefined;
    while (try reader.nextEntry()) |entry| {
        const path: []const u8 = std.mem.span(archive.mdb.c.archive_entry_pathname(entry));
        if (!std.fs.path.isAbsolute(path)) return error.RelativePathInPkg;

        const path_type = archive.mdb.c.archive_entry_mode(entry) & 0o170000;
        const tmp_install_path = if (path.len > 0 and path[0] == '.' and
            !std.mem.startsWith(u8, path, "./") and
            !std.mem.startsWith(u8, path, "../"))
            try std.fs.path.join(self.alloc, &.{
                cache,
                path,
            })
        else
            try std.fs.path.join(self.alloc, &.{
                tmp_path,
                path,
            });
        defer self.alloc.free(tmp_install_path);

        try writer.writeHeader(entry, tmp_install_path);

        if (path_type == 0o100000) {
            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes <= 0) break;

                try writer.writeData(buf[0..bytes], bytes);
            }
        }

        try writer.finishEntry();
    }

    const tmp_dir = try std.fs.cwd().openDir(tmp_path, .{
        .iterate = true,
    });
    defer tmp_dir.close();
    try moveTree(
        self.alloc,
        tmp_dir,
        prefix orelse "/",
    );

    const mtree_path = try std.fs.path.join(self.alloc, &.{
        cache,
        ".MTREE",
    });
    defer self.alloc.free(mtree_path);
    try parseMTREE(
        self,
        txn,
        pkg_key,
        mtree_path,
        prefix,
    );
}

fn moveTree(alloc: std.mem.Allocator, src: std.fs.Dir, dest: []const u8) !void {
    var it = src.iterate();
    while (try it.next()) |entry| {
        const src_path = entry.name;
        const dest_path = try std.fs.path.join(alloc, &.{
            dest,
            src_path,
        });
        defer alloc.free(dest_path);

        switch (entry.kind) {
            .directory => {
                try std.fs.cwd().makePath(dest_path);
                const child = try src.openDir(src_path, .{
                    .iterate = true,
                });
                defer child.close();

                try moveTree(
                    alloc,
                    child,
                    dest_path,
                );
            },
            else => {
                try src.rename(
                    src_path,
                    dest_path,
                );
            },
        }
    }
}

fn parseMTREE(
    self: *Db,
    txn: *mdb.c.MDB_txn,
    key: []const u8,
    mtree_path: []const u8,
    prefix: ?[]const u8,
) DbError!void {
    var reader = try archive.Reader.init();
    defer reader.deinit();

    const writer = archive.mdb.c.archive_write_disk_new() orelse
        return error.UnableToCreateWriter;
    defer _ = archive.mdb.c.archive_write_free(writer);

    _ = archive.mdb.c.archive_write_disk_set_standard_lookup(writer);
    _ = archive.mdb.c.archive_write_disk_set_options(
        writer,
        archive.mdb.c.ARCHIVE_EXTRACT_PERM |
            archive.mdb.c.ARCHIVE_EXTRACT_TIME |
            archive.mdb.c.ARCHIVE_EXTRACT_OWNER |
            archive.mdb.c.ARCHIVE_EXTRACT_ACL |
            archive.mdb.c.ARCHIVE_EXTRACT_SECURE_NODOTDOT |
            archive.mdb.c.ARCHIVE_EXTRACT_SECURE_SYMLINKS |
            archive.mdb.c.ARCHIVE_EXTRACT_UNLINK |
            archive.mdb.c.ARCHIVE_EXTRACT_FFLAGS,
    );

    const file = std.fs.cwd().openFile(
        mtree_path,
        .{ .mode = .read_only },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    try reader.openFd(file.handle);
    while (try reader.nextEntry()) |entry| {
        const path: []const u8 = std.mem.span(archive.mdb.c.archive_entry_pathname(entry));
        if (std.mem.startsWith(u8, path, ".")) continue;
        if (!std.fs.path.isAbsolute(path)) return error.RelativePathInMTREE;

        const install_path = try std.fs.path.join(self.alloc, &.{
            prefix orelse "/",
            path,
        });
        defer self.alloc.free(install_path);

        archive.mdb.c.archive_entry_set_pathname(entry, install_path.ptr);
        const ret = archive.mdb.c.archive_write_header(writer, entry);
        if (ret != archive.mdb.c.ARCHIVE_OK) return error.WriteHeaderFailed;
        _ = archive.mdb.c.archive_write_finish_entry(writer);

        try mdb.insert(txn, self.file_lkp, key, install_path);
        try mdb.insert(txn, self.files_db, install_path, key);
    }
}

pub fn uninstall(
    self: *Db,
    txn: *mdb.c.MDB_txn,
    pkg: mdb.c.MDB_val,
) DbError!void {
    const name = @as([*]const u8, @ptrCast(pkg.mv_data))[0..pkg.mv_size];
    const pkg_files = try self.queryLkpRepo(
        txn,
        self.file_lkp,
        name,
    );
    defer {
        for (pkg_files) |f| {
            self.alloc.free(f);
        }
        self.alloc.free(pkg_files);
    }

    for (pkg_files) |path| {
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.IsDir => try std.fs.cwd().deleteTree(path),
            error.FileNotFound => {},
            else => return err,
        };

        mdb.checkCode(mdb.c.mdb_del(
            txn,
            self.files_db,
            &mdb.mdbVal(path),
            null,
        )) catch |err| switch (err) {
            error.NotFound => {},
            else => return err,
        };
    }

    mdb.checkCode(mdb.c.mdb_del(
        txn,
        self.file_lkp,
        &pkg,
        null,
    )) catch |err| switch (err) {
        error.NotFound => {},
        else => return err,
    };

    mdb.checkCode(mdb.c.mdb_del(
        txn,
        self.installed_db,
        &pkg,
        null,
    )) catch |err| switch (err) {
        error.NotFound => {},
        else => return err,
    };
}
