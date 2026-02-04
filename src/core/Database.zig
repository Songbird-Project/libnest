const std = @import("std");
pub const c = @cImport({
    @cInclude("lmdb.h");
});

const Downloader = @import("../net/Downloader.zig");
const MirrorList = @import("../net/MirrorList.zig");
const Pkg = @import("Package.zig");

const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");

pub fn checkCode(code: c_int) !void {
    if (code != 0) {
        std.debug.print(
            "LMDB ERROR: {s}\n",
            .{c.mdb_strerror(code)},
        );
        return error.Internal;
    }
}

pub fn mdbVal(bytes: []const u8) c.MDB_val {
    return .{
        .mv_size = bytes.len,
        .mv_data = @constCast(bytes.ptr),
    };
}

pub fn makeKey(buf: []u8, repo: []const u8, name: []const u8) []const u8 {
    @memmove(buf[0..name.len], name);
    buf[name.len] = 0;
    @memmove(buf[name.len + 1 ..][0..repo.len], repo);
    return buf[0 .. name.len + repo.len + 1];
}

const Db = @This();

alloc: std.mem.Allocator,
env: *c.MDB_env,
pkgs_db: c.MDB_dbi,
files_db: c.MDB_dbi,
file_lkp: c.MDB_dbi,
pkg_lkp: c.MDB_dbi,

pub fn init(alloc: std.mem.Allocator, path: []const u8) !Db {
    var env: ?*c.MDB_env = null;
    try checkCode(c.mdb_env_create(&env));
    errdefer c.mdb_env_close(env.?);

    try checkCode(c.mdb_env_set_maxdbs(env.?, 7));
    try checkCode(c.mdb_env_set_mapsize(env.?, 5 * 1024 * 1024 * 1024));

    try checkCode(c.mdb_env_open(
        env.?,
        path.ptr,
        c.MDB_NOSUBDIR,
        0o644,
    ));

    var txn: ?*c.MDB_txn = undefined;
    try checkCode(c.mdb_txn_begin(env.?, null, 0, &txn));

    var pkgs_db: c.MDB_dbi = undefined;
    var files_db: c.MDB_dbi = undefined;
    var pkg_lkp: c.MDB_dbi = undefined;
    var file_lkp: c.MDB_dbi = undefined;

    try checkCode(c.mdb_dbi_open(
        txn.?,
        "packages",
        c.MDB_CREATE,
        &pkgs_db,
    ));
    try checkCode(c.mdb_dbi_open(
        txn.?,
        "files",
        c.MDB_CREATE,
        &files_db,
    ));
    try checkCode(c.mdb_dbi_open(
        txn.?,
        "package_lookup",
        c.MDB_CREATE | c.MDB_DUPSORT,
        &pkg_lkp,
    ));
    try checkCode(c.mdb_dbi_open(
        txn.?,
        "file_lookup",
        c.MDB_CREATE | c.MDB_DUPSORT,
        &file_lkp,
    ));

    try checkCode(c.mdb_txn_commit(txn.?));

    return .{
        .alloc = alloc,
        .env = env.?,
        .pkgs_db = pkgs_db,
        .files_db = files_db,
        .pkg_lkp = pkg_lkp,
        .file_lkp = file_lkp,
    };
}

pub fn deinit(self: *Db) void {
    c.mdb_dbi_close(self.env, self.pkgs_db);
    c.mdb_dbi_close(self.env, self.files_db);
    c.mdb_dbi_close(self.env, self.pkg_lkp);
    c.mdb_dbi_close(self.env, self.file_lkp);
    c.mdb_env_close(self.env);
}

pub fn insert(
    txn: *c.MDB_txn,
    dbi: c.MDB_dbi,
    key: []const u8,
    value: []const u8,
) !void {
    var mdb_key = mdbVal(key);
    var val = mdbVal(value);

    try checkCode(c.mdb_put(
        txn,
        dbi,
        &mdb_key,
        &val,
        0,
    ));
}

pub fn insertPkg(
    alloc: std.mem.Allocator,
    txn: *c.MDB_txn,
    dbi: c.MDB_dbi,
    repo: []const u8,
    pkg_name: []const u8,
    fields: Pkg,
) !void {
    const pkg_len =
        @sizeOf(Pkg.Header) +
        fields.version.len +
        fields.description.len +
        fields.arch.len +
        fields.license.len +
        fields.filename.len +
        fields.packager.len +
        fields.checksum.len +
        fields.signature.len +
        fields.replaces.len +
        fields.conflicts.len +
        fields.provides.len +
        fields.deps.len +
        fields.mkdeps.len +
        fields.optdeps.len +
        fields.checkdeps.len;
    var buf = try alloc.alloc(u8, pkg_len);
    defer alloc.free(buf);
    var w: usize = 0;

    const header: Pkg.Header = .{
        .build_date = fields.build_date,
        .version_len = @intCast(fields.version.len),
        .description_len = @intCast(fields.description.len),
        .arch_len = @intCast(fields.arch.len),
        .license_len = @intCast(fields.license.len),
        .filename_len = @intCast(fields.filename.len),
        .packager_len = @intCast(fields.packager.len),
        .checksum_len = @intCast(fields.checksum.len),
        .signature_len = @intCast(fields.signature.len),
        .replaces_len = @intCast(fields.replaces.len),
        .conflicts_len = @intCast(fields.conflicts.len),
        .provides_len = @intCast(fields.provides.len),
        .deps_len = @intCast(fields.deps.len),
        .mkdeps_len = @intCast(fields.mkdeps.len),
        .optdeps_len = @intCast(fields.optdeps.len),
        .checkdeps_len = @intCast(fields.checkdeps.len),
    };

    @memmove(
        buf[0..@sizeOf(Pkg.Header)],
        std.mem.asBytes(&header),
    );
    w += @sizeOf(Pkg.Header);

    inline for ([_][]const u8{
        fields.version,
        fields.description,
        fields.arch,
        fields.license,
        fields.filename,
        fields.packager,
        fields.checksum,
        fields.signature,
        fields.replaces,
        fields.conflicts,
        fields.provides,
        fields.deps,
        fields.mkdeps,
        fields.optdeps,
        fields.checkdeps,
    }) |field| {
        @memmove(buf[w..][0..field.len], field);
        w += field.len;
    }

    var key_buf: [256]u8 = undefined;
    var key = mdbVal(makeKey(
        &key_buf,
        repo,
        pkg_name,
    ));
    var val = mdbVal(buf[0..w]);

    try checkCode(c.mdb_put(
        txn,
        dbi,
        &key,
        &val,
        0,
    ));
}

pub fn readPkg(val: c.MDB_val) Pkg {
    const raw = @as([*]const u8, @ptrCast(val.mv_data));

    var header: Pkg.Header = undefined;
    @memcpy(
        std.mem.asBytes(&header),
        raw[0..@sizeOf(Pkg.Header)],
    );

    var ptr: usize = @sizeOf(Pkg.Header);
    return .{
        .build_date = header.build_date,

        .version = Pkg.Header.nextField(raw, header.version_len, &ptr),
        .description = Pkg.Header.nextField(raw, header.description_len, &ptr),
        .arch = Pkg.Header.nextField(raw, header.arch_len, &ptr),
        .license = Pkg.Header.nextField(raw, header.license_len, &ptr),
        .filename = Pkg.Header.nextField(raw, header.filename_len, &ptr),
        .packager = Pkg.Header.nextField(raw, header.packager_len, &ptr),
        .checksum = Pkg.Header.nextField(raw, header.checksum_len, &ptr),
        .signature = Pkg.Header.nextField(raw, header.signature_len, &ptr),
        .replaces = Pkg.Header.nextField(raw, header.replaces_len, &ptr),
        .conflicts = Pkg.Header.nextField(raw, header.conflicts_len, &ptr),
        .provides = Pkg.Header.nextField(raw, header.provides_len, &ptr),
        .deps = Pkg.Header.nextField(raw, header.deps_len, &ptr),
        .mkdeps = Pkg.Header.nextField(raw, header.mkdeps_len, &ptr),
        .optdeps = Pkg.Header.nextField(raw, header.optdeps_len, &ptr),
        .checkdeps = Pkg.Header.nextField(raw, header.checkdeps_len, &ptr),
    };
}

pub fn queryPkgRepo(self: *Db, txn: *c.MDB_txn, name: []const u8) ![]c.MDB_val {
    var cursor: ?*c.MDB_cursor = null;
    try checkCode(
        c.mdb_cursor_open(txn, self.pkg_lkp, &cursor),
    );
    defer c.mdb_cursor_close(cursor);

    var pkgs: std.ArrayList(c.MDB_val) = .empty;
    defer pkgs.deinit(self.alloc);

    var key: c.MDB_val = mdbVal(name);
    var val: c.MDB_val = undefined;

    try checkCode(c.mdb_cursor_get(
        cursor.?,
        &key,
        &val,
        c.MDB_SET,
    ));

    var ret: c_int = 0;
    while (ret == 0) {
        try pkgs.append(self.alloc, val);

        ret = c.mdb_cursor_get(
            cursor.?,
            &key,
            &val,
            c.MDB_NEXT_DUP,
        );
    }

    return pkgs.toOwnedSlice(self.alloc);
}

pub fn queryPkg(self: *Db, txn: *c.MDB_txn, key: *c.MDB_val) !Pkg {
    var cursor: ?*c.MDB_cursor = null;
    try checkCode(c.mdb_cursor_open(
        txn,
        self.pkgs_db,
        &cursor,
    ));
    defer c.mdb_cursor_close(cursor);

    var val: c.MDB_val = undefined;

    try checkCode(c.mdb_cursor_get(
        cursor.?,
        key,
        &val,
        c.MDB_SET,
    ));

    return readPkg(val);
}

pub fn sync(
    self: *Db,
    mirror_path: []const u8,
    dest_dir: []const u8,
    repo: []const u8,
    arch: []const u8,
    batch_size: usize,
    download_cb: ?*const Downloader.callback,
) !void {
    var mirrors = try MirrorList.init(self.alloc, mirror_path);
    defer mirrors.deinit();

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

    var in_trans: bool = false;
    var batched: usize = 0;
    var txn: ?*c.MDB_txn = null;

    const file = try std.fs.cwd().openFile(
        dest,
        .{ .mode = .read_only },
    );
    defer file.close();

    try reader.openFd(file.handle);
    var pkg_key: ?[]const u8 = null;
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
        // const is_files = std.mem.eql(u8, pathrepo[delim.? + 1 ..], "files");

        if (!is_desc
        // and !is_files
        ) {
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
            if (bytes == 0) break;
            try content.appendSlice(self.alloc, buf[0..bytes]);
        }

        if (is_desc) {
            if (batched >= batch_size and in_trans) {
                try checkCode(c.mdb_txn_commit(txn.?));
                in_trans = false;
            }
            if (!in_trans) {
                try checkCode(c.mdb_txn_begin(
                    self.env,
                    null,
                    0,
                    &txn,
                ));
                in_trans = true;
            }

            pkg_key = try desc.index(
                self.alloc,
                self,
                txn.?,
                content.items,
                repo,
            );

            batched += 1;
        }
        // else if (is_files) {
        //     if (pkg_key) |pkg| {
        //         try files.index(
        //             self.alloc,
        //             self,
        //             txn.?,
        //             content.items,
        //             pkg,
        //         );
        //     }
        // }

        content.clearRetainingCapacity();
    }

    if (in_trans) {
        try checkCode(c.mdb_txn_commit(txn.?));
    }
}
