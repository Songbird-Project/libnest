const std = @import("std");
pub const c = @cImport({
    @cInclude("lmdb.h");
});

const Pkg = @import("../core/Package.zig");
const Db = @import("../core/Database.zig");

pub fn Response(comptime T: type) type {
    return struct {
        key: []const u8,
        val: T,
    };
}

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
    alloc: std.mem.Allocator,
    txn: *c.MDB_txn,
    dbi: c.MDB_dbi,
    key: []const u8,
    val: anytype,
) !void {
    var writer = std.io.Writer.Allocating.init(alloc);
    const w = &writer.writer;
    defer writer.deinit();
    try std.json.Stringify.value(val, .{}, w);

    var mdb_key = mdbVal(key);
    var mdb_val = mdbVal(writer.written());

    try checkCode(c.mdb_put(
        txn,
        dbi,
        &mdb_key,
        &mdb_val,
        0,
    ));
}
