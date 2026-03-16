const std = @import("std");

const Downloader = @import("../net/Downloader.zig");
const MirrorList = @import("../net/MirrorList.zig");
const Pkg = @import("Package.zig");

const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");
const pkginfo = @import("../parse/pkginfo.zig");
const mdb = @import("../utils/mdb.zig");

const DbError = error{
    RelativePathInPkg,
    RelativePathInMTREE,
    CorruptPkg,
};

const Db = @This();

alloc: std.mem.Allocator,
env: *mdb.c.MDB_env,
pkgs_db: mdb.c.MDB_dbi,
files_db: mdb.c.MDB_dbi,
installed_db: mdb.c.MDB_dbi,
file_lkp: mdb.c.MDB_dbi,

pub fn init(alloc: std.mem.Allocator, path: []const u8) !Db {
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
        .file_lkp = file_lkp,
    };
}

pub fn deinit(self: *Db) void {
    mdb.c.mdb_dbi_close(self.env, self.pkgs_db);
    mdb.c.mdb_dbi_close(self.env, self.files_db);
    mdb.c.mdb_dbi_close(self.env, self.installed_db);
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
            mdb.c.MDB_NEXT,
        )) catch break;
    }

    return pkgs.toOwnedSlice(self.alloc);
}

pub fn query(
    self: *Db,
    T: anytype,
    dbi: mdb.c.MDB_dbi,
    txn: *mdb.c.MDB_txn,
    name: []const u8,
) ![]mdb.Response(T) {
    var cursor: ?*mdb.c.MDB_cursor = null;
    try mdb.checkCode(
        mdb.c.mdb_cursor_open(txn, dbi, &cursor),
    );
    defer mdb.c.mdb_cursor_close(cursor);

    var pkgs: std.ArrayList(mdb.Response(T)) = .empty;
    defer pkgs.deinit(self.alloc);

    const name_delim = try std.fmt.allocPrint(
        self.alloc,
        "{s}@",
        .{name},
    );
    defer self.alloc.free(name_delim);
    var key: mdb.c.MDB_val = mdb.mdbVal(name_delim);
    var mdb_val: mdb.c.MDB_val = undefined;

    mdb.checkCode(mdb.c.mdb_cursor_get(
        cursor.?,
        &key,
        &mdb_val,
        mdb.c.MDB_SET_RANGE,
    )) catch |err| switch (err) {
        error.NotFound => return &[_]mdb.Response(T){},
        else => {},
    };

    while (true) {
        const data = @as(
            [*]const u8,
            @ptrCast(mdb_val.mv_data),
        )[0..mdb_val.mv_size];
        const pkg_key = @as(
            [*]const u8,
            @ptrCast(key.mv_data),
        )[0..key.mv_size];
        if (!std.mem.startsWith(u8, pkg_key, name_delim)) break;

        const val = try std.json.parseFromSlice(
            T,
            self.alloc,
            data,
            .{},
        );

        try pkgs.append(self.alloc, .{
            .key = pkg_key,
            .val = val.value,
        });

        mdb.checkCode(mdb.c.mdb_cursor_get(
            cursor.?,
            &key,
            &mdb_val,
            mdb.c.MDB_NEXT,
        )) catch break;
    }

    return pkgs.toOwnedSlice(self.alloc);
}

pub fn sync(
    self: *Db,
    mirrors: *MirrorList,
    dest_dir: []const u8,
    repo: []const u8,
    arch: []const u8,
    batch_size: usize,
    download_cb: ?*const Downloader.callback,
) !void {
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
        const pathrepo: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
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
    key: []const u8,
    pkg: Pkg,
    txn: *mdb.c.MDB_txn,
    prefix: ?[]const u8,
    download_cb: ?*const Downloader.callback,
) !void {
    var reader = try archive.Reader.init();
    defer reader.deinit();

    var writer = try archive.Writer.init();
    defer writer.deinit();

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
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        if (std.mem.containsAtLeast(u8, path, 1, ".."))
            return error.RelativePathInPkg;

        const path_type = archive.c.archive_entry_mode(entry) & 0o170000;

        var rel = path;
        if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
        if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

        const install_path = if (path[0] == '.') try std.fs.path.join(self.alloc, &.{
            cache,
            rel,
        }) else try std.fs.path.join(self.alloc, &.{
            prefix orelse "/",
            rel,
        });
        defer self.alloc.free(install_path);

        try writer.writeHeader(entry, install_path);

        if (path_type == 0o100000) {
            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes <= 0) break;

                try writer.writeData(buf[0..bytes], bytes);
            }
        }

        try writer.finishEntry();
    }

    const mtree_path = try std.fs.path.join(self.alloc, &.{
        cache,
        ".MTREE",
    });
    defer self.alloc.free(mtree_path);
    try useMTREE(
        self,
        txn,
        key,
        mtree_path,
        prefix,
    );

    const pkginfo_path = try std.fs.path.join(self.alloc, &.{
        cache,
        ".PKGINFO",
    });
    defer self.alloc.free(pkginfo_path);
    try pkginfo.index(
        self.alloc,
        self,
        txn,
        key,
        pkginfo_path,
    );
}

fn useMTREE(
    self: *Db,
    txn: *mdb.c.MDB_txn,
    key: []const u8,
    mtree_path: []const u8,
    prefix: ?[]const u8,
) !void {
    var reader = try archive.Reader.init();
    defer reader.deinit();

    const writer = archive.c.archive_write_disk_new() orelse
        return error.UnableToCreateWriter;
    defer _ = archive.c.archive_write_free(writer);

    _ = archive.c.archive_write_disk_set_standard_lookup(writer);
    _ = archive.c.archive_write_disk_set_options(
        writer,
        archive.c.ARCHIVE_EXTRACT_PERM |
            archive.c.ARCHIVE_EXTRACT_TIME |
            archive.c.ARCHIVE_EXTRACT_OWNER |
            archive.c.ARCHIVE_EXTRACT_ACL |
            archive.c.ARCHIVE_EXTRACT_SECURE_NODOTDOT |
            archive.c.ARCHIVE_EXTRACT_SECURE_SYMLINKS |
            archive.c.ARCHIVE_EXTRACT_UNLINK |
            archive.c.ARCHIVE_EXTRACT_FFLAGS,
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
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        if (std.mem.startsWith(u8, path, ".")) continue;
        if (!std.fs.path.isAbsolute(path)) return error.RelativePathInMTREE;

        const install_path = try std.fs.path.join(self.alloc, &.{
            prefix orelse "/",
            path,
        });
        defer self.alloc.free(install_path);

        archive.c.archive_entry_set_pathname(entry, install_path.ptr);
        const ret = archive.c.archive_write_header(writer, entry);
        if (ret != archive.c.ARCHIVE_OK) return error.WriteHeaderFailed;
        _ = archive.c.archive_write_finish_entry(writer);

        try mdb.insert(self.alloc, txn, self.file_lkp, key, install_path);
        try mdb.insert(self.alloc, txn, self.files_db, install_path, key);
    }
}

pub fn uninstall(
    self: *Db,
    txn: *mdb.c.MDB_txn,
    pkg: mdb.c.MDB_val,
) !void {
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
