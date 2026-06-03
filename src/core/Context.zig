const std = @import("std");

const Db = @import("Database.zig");
const MirrorList = @import("../net/MirrorList.zig");
const Pkg = @import("Package.zig");
const Txn = @import("Transaction.zig");

const txn_hooks = @import("hooks.zig");
const installer = @import("installer.zig");

pub const LogLevel = enum(u8) {
    Debug,
    Info,
    Warn,
    Error,
    Fatal,
};

pub const PathConfig = struct {
    root: []const u8 = "/",
    cache: []const u8 = "var/cache/libnest",
    config: []const u8 = "etc/libnest",
    hook: []const u8 = "etc/libnest/hooks",

    pub fn deinit(self: *PathConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.root);
        alloc.free(self.cache);
        alloc.free(self.config);
        alloc.free(self.hook);
    }
};

const Context = @This();

io: std.Io,
alloc: std.mem.Allocator,
arch: []const u8,

db: Db,
mirrors: MirrorList,
paths: PathConfig,
hooks: []*txn_hooks.Hook,
txn: Txn = .{},

/// Callbacks
download_cb: ?*const fn ([]const u8, f64, f64, bool) anyerror!void = null,
select_cb: ?*const fn ([][]const u8, usize) anyerror!isize = null,
log_cb: ?*const fn (std.Io, LogLevel, []const u8) anyerror!void = null,

pub fn init(
    io: std.Io,
    alloc: std.mem.Allocator,
    arch: []const u8,
    paths: PathConfig,
    mirrors: []const MirrorList.MirrorConfig,
) !Context {
    var p = PathConfig{
        .root = try alloc.dupe(u8, paths.root),
        .cache = try std.Io.Dir.path.join(alloc, &.{
            paths.root,
            paths.cache,
        }),
        .config = try std.Io.Dir.path.join(alloc, &.{
            paths.root,
            paths.config,
        }),
        .hook = try std.Io.Dir.path.join(alloc, &.{
            paths.root,
            paths.hook,
        }),
    };
    errdefer p.deinit(alloc);

    try std.Io.Dir.cwd().createDirPath(io, p.root);
    try std.Io.Dir.cwd().createDirPath(io, p.cache);
    try std.Io.Dir.cwd().createDirPath(io, p.config);
    try std.Io.Dir.cwd().createDirPath(io, p.hook);

    var db = try Db.init(alloc, p.config);
    errdefer db.deinit();

    var mirrorlist = try MirrorList.init(io, alloc, mirrors);
    errdefer mirrorlist.deinit();

    const hooks = try txn_hooks.initAll(io, alloc, p.hook);
    errdefer txn_hooks.deinitAll(alloc, hooks);

    return .{
        .io = io,
        .alloc = alloc,
        .arch = try alloc.dupe(u8, arch),
        .db = db,
        .mirrors = mirrorlist,
        .paths = p,
        .hooks = hooks,
    };
}

pub fn deinit(self: *Context) void {
    self.mirrors.deinit();
    self.db.deinit();
    self.alloc.free(self.arch);
    self.paths.deinit(self.alloc);
    self.txn.deinit(self.alloc);
    txn_hooks.deinitAll(self.alloc, self.hooks);
}

pub fn log(
    self: *Context,
    level: LogLevel,
    detail: []const u8,
) !void {
    if (self.log_cb) |cb| {
        try cb(self.io, level, detail);
    }
}
