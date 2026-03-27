const std = @import("std");

const Db = @import("Database.zig");
const MirrorList = @import("../net/MirrorList.zig");

pub const PathConfig = struct {
    root: []const u8 = "/",
    lib: []const u8 = "usr/lib",
    config: []const u8 = "etc",
    cache: []const u8 = "var/cache/libnest",
    db: []const u8 = "etc/libnest",

    pub fn deinit(self: *PathConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.root);
        alloc.free(self.lib);
        alloc.free(self.config);
        alloc.free(self.cache);
        alloc.free(self.db);
    }
};

const Context = @This();

alloc: std.mem.Allocator,
arch: []const u8,

db: Db,
mirrors: MirrorList,
paths: PathConfig,

/// Callbacks
download_cb: ?*const fn ([]const u8, f64, f64, bool) anyerror!void = null,
select_cb: ?*const fn ([][]const u8, usize) anyerror!isize = null,

pub fn init(
    alloc: std.mem.Allocator,
    arch: []const u8,
    mirrorlist_path: []const u8,
    paths: PathConfig,
) !Context {
    var p = PathConfig{
        .root = try alloc.dupe(u8, paths.root),
        .lib = try std.fs.path.join(alloc, &.{
            paths.root,
            paths.lib,
        }),
        .config = try std.fs.path.join(alloc, &.{
            paths.root,
            paths.config,
        }),
        .cache = try std.fs.path.join(alloc, &.{
            paths.root,
            paths.cache,
        }),
        .db = try std.fs.path.join(alloc, &.{
            paths.root,
            paths.db,
        }),
    };
    errdefer p.deinit(alloc);

    var db = try Db.init(alloc, p.db);
    errdefer db.deinit();

    var mirrors = try MirrorList.init(alloc, mirrorlist_path);
    errdefer mirrors.deinit();

    return .{
        .alloc = alloc,
        .arch = try alloc.dupe(u8, arch),
        .db = db,
        .mirrors = mirrors,
        .paths = p,
    };
}

pub fn deinit(self: *Context) void {
    self.mirrors.deinit();
    self.db.deinit();
    self.alloc.free(self.arch);
    self.paths.deinit(self.alloc);
}
