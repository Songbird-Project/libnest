const std = @import("std");
pub const c = @cImport({
    @cInclude("lmdb.h");
});

const Pkg = @import("../core/Package.zig");
const Db = @import("../core/Database.zig");

pub const MDBError = error{
    Success,
    KeyExist,
    NotFound,
    PagNotFound,
    Corrupted,
    Panic,
    VersionMismatch,
    Invalid,
    MapFull,
    DbsFull,
    ReadersFull,
    TlsFull,
    TxnFull,
    CursorFull,
    PageFull,
    MapResized,
    Incompatible,
    BadRslot,
    BadTxn,
    BadValsize,
    BadDbi,
    Unexpected,
};

pub fn checkCode(code: c_int) MDBError!void {
    if (code != 0) {
        std.debug.print(
            "LMDB ERROR: {s}\n",
            .{c.mdb_strerror(code)},
        );
    }

    return switch (code) {
        0 => {},
        -30799 => error.KeyExist,
        -30798 => error.NotFound,
        -30797 => error.PagNotFound,
        -30796 => error.Corrupted,
        -30795 => error.Panic,
        -30794 => error.Invalid,
        -30793 => error.VersionMismatch,
        -30792 => error.MapFull,
        -30791 => error.DbsFull,
        -30790 => error.ReadersFull,
        -30789 => error.TlsFull,
        -30788 => error.TxnFull,
        -30787 => error.CursorFull,
        -30786 => error.PageFull,
        -30785 => error.MapResized,
        -30784 => error.Incompatible,
        -30783 => error.BadRslot,
        -30782 => error.BadTxn,
        -30781 => error.BadValsize,
        -30780 => error.BadDbi,
        else => error.Unexpected,
    };
}

pub fn mdbVal(bytes: []const u8) c.MDB_val {
    return .{
        .mv_size = bytes.len,
        .mv_data = @constCast(bytes.ptr),
    };
}

pub fn makeKey(
    alloc: std.mem.Allocator,
    repo: []const u8,
    name: []const u8,
) ![]u8 {
    return try std.mem.concat(alloc, u8, &.{ name, "@", repo });
}

pub fn startTxn(db: *Db) !*c.MDB_txn {
    var txn: ?*c.MDB_txn = null;
    try checkCode(c.mdb_txn_begin(
        db.env,
        null,
        0,
        &txn,
    ));

    return txn.?;
}

pub fn endTxn(txn: *c.MDB_txn) !void {
    try checkCode(c.mdb_txn_commit(txn));
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

    const key_str = try makeKey(
        alloc,
        repo,
        pkg_name,
    );
    defer alloc.free(key_str);
    var key = mdbVal(key_str);
    var val = mdbVal(buf[0..w]);

    try checkCode(c.mdb_put(
        txn,
        dbi,
        &key,
        &val,
        0,
    ));
}

pub fn readPkg(alloc: std.mem.Allocator, val: []const u8) !Pkg {
    const raw = @as([*]const u8, @ptrCast(val));
    if (val.len < @sizeOf(Pkg.Header)) return error.CorruptPkg;

    var header: Pkg.Header = undefined;
    @memcpy(
        std.mem.asBytes(&header),
        raw[0..@sizeOf(Pkg.Header)],
    );

    const expected = @sizeOf(Pkg.Header) +
        header.version_len +
        header.description_len +
        header.arch_len +
        header.license_len +
        header.filename_len +
        header.packager_len +
        header.checksum_len +
        header.signature_len +
        header.replaces_len +
        header.conflicts_len +
        header.provides_len +
        header.deps_len +
        header.mkdeps_len +
        header.optdeps_len +
        header.checkdeps_len;
    if (expected > val.len) return error.CorruptPkg;

    var ptr: usize = @sizeOf(Pkg.Header);
    return .{
        .build_date = header.build_date,

        .version = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.version_len, &ptr)),
        .description = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.description_len, &ptr)),
        .arch = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.arch_len, &ptr)),
        .license = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.license_len, &ptr)),
        .filename = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.filename_len, &ptr)),
        .packager = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.packager_len, &ptr)),
        .checksum = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.checksum_len, &ptr)),
        .signature = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.signature_len, &ptr)),
        .replaces = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.replaces_len, &ptr)),
        .conflicts = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.conflicts_len, &ptr)),
        .provides = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.provides_len, &ptr)),
        .deps = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.deps_len, &ptr)),
        .mkdeps = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.mkdeps_len, &ptr)),
        .optdeps = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.optdeps_len, &ptr)),
        .checkdeps = try alloc.dupe(u8, Pkg.Header.nextField(raw, header.checkdeps_len, &ptr)),
    };
}

pub fn insertInstalledPkg(
    alloc: std.mem.Allocator,
    txn: *c.MDB_txn,
    dbi: c.MDB_dbi,
    key: []const u8,
    fields: Pkg.Installed,
) !void {
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

    var mdb_key = mdbVal(key);
    var val = mdbVal(buf[0..w]);

    try checkCode(c.mdb_put(
        txn,
        dbi,
        &mdb_key,
        &val,
        0,
    ));
}

pub fn readInstalledPkg(alloc: std.mem.Allocator, val: []const u8) !Pkg.Installed {
    const raw = @as([*]const u8, @ptrCast(val));
    if (val.len < @sizeOf(Pkg.Installed.Header)) return error.CorruptPkg;

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
