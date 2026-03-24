const std = @import("std");

const Db = @import("Database.zig");
const MirrorList = @import("../net/MirrorList.zig");

const Context = @This();

alloc: std.mem.Allocator,
arch: []const u8,
prefix: []const u8,

db: Db,
mirrors: MirrorList,

/// Callbacks
download_cb: ?*const fn (f64, f64) anyerror!void = null,
select_cb: ?*const fn ([][]const u8, usize) anyerror!isize = null,

pub fn init(
    alloc: std.mem.Allocator,
    prefix: ?[]const u8,
    arch: []const u8,
    mirrorlist_path: []const u8,
) !Context {
    const p = prefix orelse "/";

    var db = try Db.init(alloc, p);
    errdefer db.deinit();

    var mirrors = try MirrorList.init(alloc, mirrorlist_path);
    errdefer mirrors.deinit();

    return .{
        .alloc = alloc,
        .arch = try alloc.dupe(u8, arch),
        .prefix = try alloc.dupe(u8, p),
        .db = db,
        .mirrors = mirrors,
    };
}

pub fn deinit(self: *Context) void {
    self.mirrors.deinit();
    self.db.deinit();
    self.alloc.free(self.arch);
    self.alloc.free(self.prefix);
}
