const std = @import("std");

const Db = @import("Database.zig");
const MirrorList = @import("../net/MirrorList.zig");
const Pkg = @import("Package.zig");

const txn_hooks = @import("hooks.zig");
const installer = @import("installer.zig");

pub const Transaction = struct {
    installs: std.ArrayList(installer.PkgInstallInfo) = .empty,
    upgrades: std.ArrayList([]const u8) = .empty,
    removes: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Transaction, alloc: std.mem.Allocator) void {
        for (self.installs.items) |*item| item.deinit(alloc);

        self.installs.deinit(alloc);
        self.upgrades.deinit(alloc);
        self.removes.deinit(alloc);
    }
};

pub const LogLevel = enum(u8) {
    Debug,
    Info,
    Error,
    Fatal,
};

pub const Action = enum(u8) {
    Install,
    Uninstall,
    Resolve,
    Build,
    Sync,
    Download,

    pub fn format(self: Action, writer: *std.io.Writer) !void {
        try switch (self) {
            .Install => writer.writeAll("Installing"),
            .Uninstall => writer.writeAll("Uninstalling"),
            .Resolve => writer.writeAll("Resolving"),
            .Build => writer.writeAll("Building"),
            .Sync => writer.writeAll("Syncing"),
            .Download => writer.writeAll("Downloading"),
        };
    }
};

pub const PathConfig = struct {
    root: []const u8 = "/",
    cache: []const u8 = "var/cache/libnest",
    db: []const u8 = "etc/libnest",
    hook: []const u8 = "etc/libnest/hooks",

    pub fn deinit(self: *PathConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.root);
        alloc.free(self.cache);
        alloc.free(self.db);
        alloc.free(self.hook);
    }
};

const Context = @This();

alloc: std.mem.Allocator,
arch: []const u8,

db: Db,
mirrors: MirrorList,
paths: PathConfig,
hooks: []txn_hooks.Hook = &.{},
txn: Transaction = .{},

/// Callbacks
download_cb: ?*const fn ([]const u8, f64, f64, bool) anyerror!void = null,
select_cb: ?*const fn ([][]const u8, usize) anyerror!isize = null,
log_cb: ?*const fn (LogLevel, Action, []const u8) anyerror!void = null,

pub fn init(
    alloc: std.mem.Allocator,
    arch: []const u8,
    mirrorlist_path: []const u8,
    paths: PathConfig,
) !Context {
    var p = PathConfig{
        .root = try alloc.dupe(u8, paths.root),
        .cache = try std.fs.path.join(alloc, &.{
            paths.root,
            paths.cache,
        }),
        .db = try std.fs.path.join(alloc, &.{
            paths.root,
            paths.db,
        }),
        .hook = try std.fs.path.join(alloc, &.{
            paths.root,
            paths.hook,
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
    self.txn.deinit(self.alloc);
}

pub fn log(
    self: *Context,
    level: LogLevel,
    action: Action,
    detail: []const u8,
) !void {
    if (self.log_cb) |cb| {
        try cb(level, action, detail);
    }
}
