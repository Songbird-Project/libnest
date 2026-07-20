const std = @import("std");
const zqlite = @import("zqlite");

const EVR = struct {
    epoch: []const u8,
    version: []const u8,
    release: ?[]const u8,
};

pub fn parseEVR(evr: []const u8) EVR {
    var epoch: []const u8 = "0";
    var version: []const u8 = evr;
    var release: ?[]const u8 = null;

    var s: usize = 0;
    for (evr, 0..) |c, i| {
        if (!std.ascii.isDigit(c)) {
            s = i;
            break;
        }
    }

    if (s < evr.len and evr[s] == ':') {
        epoch = evr[0..s];
        version = evr[s + 1 ..];
    }

    if (std.mem.findScalarLast(u8, version, '-')) |se| {
        release = version[se + 1 ..];
        version = version[0..se];
    }

    return .{
        .epoch = epoch,
        .version = version,
        .release = release,
    };
}

fn rpmvercmp(a: []const u8, b: []const u8) i8 {
    if (std.mem.eql(u8, a, b)) return 0;

    var i: usize = 0;
    var j: usize = 0;

    var last_i: usize = 0;
    var last_j: usize = 0;

    while (i < a.len and j < b.len) {
        while (i < a.len and !std.ascii.isAlphanumeric(a[i])) : (i += 1) {}
        while (j < b.len and !std.ascii.isAlphanumeric(b[j])) : (j += 1) {}

        if (!(i < a.len and j < b.len)) break;

        const sep_a = i - last_i;
        const sep_b = j - last_j;
        if (sep_a != sep_b) {
            return if (sep_a < sep_b) -1 else 1;
        }

        last_i = i;
        last_j = j;

        const is_num = std.ascii.isDigit(a[i]);

        const si = i;
        const sj = j;

        if (is_num) {
            while (i < a.len and std.ascii.isDigit(a[i])) : (i += 1) {}
            while (j < b.len and std.ascii.isDigit(b[j])) : (j += 1) {}
        } else {
            while (i < a.len and std.ascii.isAlphabetic(a[i])) : (i += 1) {}
            while (j < b.len and std.ascii.isAlphabetic(b[j])) : (j += 1) {}
        }

        var seg_a = a[si..i];
        var seg_b = b[sj..j];

        if (seg_a.len == 0) return -1;
        if (seg_b.len == 0) return if (is_num) 1 else -1;

        if (is_num) {
            while (seg_a.len > 0 and seg_a[0] == '0') seg_a = seg_a[1..];
            while (seg_b.len > 0 and seg_b[0] == '0') seg_b = seg_b[1..];

            if (seg_a.len > seg_b.len) return 1;
            if (seg_a.len < seg_b.len) return -1;
        }

        const ord = std.mem.order(u8, seg_a, seg_b);
        if (ord != .eq) {
            return if (ord == .lt) -1 else 1;
        }

        last_i = i;
        last_j = j;
    }

    if (i >= a.len and j >= b.len) return 0;

    if ((i >= a.len and !(j < b.len and std.ascii.isAlphabetic(b[j]))) or
        (i < a.len and std.ascii.isAlphabetic(a[i])))
    {
        return -1;
    } else {
        return 1;
    }
}

/// Return:
///  -1: a < b
///   0: a = b
///   1: a > b
pub fn cmp(a: ?[]const u8, b: ?[]const u8) i8 {
    if (a == null and b == null) {
        return 0;
    } else if (a == null) {
        return -1;
    } else if (b == null) {
        return 1;
    }

    if (std.mem.eql(u8, a.?, b.?)) return 0;

    const evr1 = parseEVR(a.?);
    const evr2 = parseEVR(b.?);

    var ret: i8 = rpmvercmp(evr1.epoch, evr2.epoch);
    if (ret != 0) return ret;
    ret = rpmvercmp(evr1.version, evr2.version);
    if (ret != 0) return ret;
    if (evr1.release != null and evr2.release != null)
        ret = rpmvercmp(evr1.release.?, evr2.release.?);
    return ret;
}

pub fn evrCmp(e1: i32, v1: []const u8, r1: ?[]const u8, e2: i32, v2: []const u8, r2: ?[]const u8) i8 {
    if (e1 != e2) return if (e1 > e2) 1 else -1;
    const vret = rpmvercmp(v1, v2);
    if (vret != 0) return vret;
    if (r1 != null and r2 != null) return rpmvercmp(r1.?, r2.?);
    return 0;
}

pub fn sqlCmp(
    ctx: ?*zqlite.c.sqlite3_context,
    _: c_int,
    argv: [*c]?*zqlite.c.sqlite3_value,
) callconv(.c) void {
    const e1 = zqlite.c.sqlite3_value_int(argv[0]);
    const v1 = valSlice(argv[1]);
    const r1 = valSliceOpt(argv[2]);
    const e2 = zqlite.c.sqlite3_value_int(argv[3]);
    const v2 = valSlice(argv[4]);
    const r2 = valSliceOpt(argv[5]);
    zqlite.c.sqlite3_result_int(ctx, @intCast(evrCmp(e1, v1, r1, e2, v2, r2)));
}

fn valSlice(v: ?*zqlite.c.sqlite3_value) []const u8 {
    const ptr = zqlite.c.sqlite3_value_text(v);
    const len: usize = @intCast(zqlite.c.sqlite3_value_bytes(v));
    return ptr[0..len];
}

fn valSliceOpt(v: ?*zqlite.c.sqlite3_value) ?[]const u8 {
    if (zqlite.c.sqlite3_value_type(v) == zqlite.c.SQLITE_NULL) return null;
    return valSlice(v);
}
