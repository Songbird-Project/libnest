const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const store = @import("../store/store.zig");
const config = @import("config");

pub const LogLevel = enum(u8) { Debug, Info, Warn, Error, Fatal, None };

pub const LogOptions = struct {
    debug_prefix: []const u8 = "\x1B[0;34m[\x1B[0;37mD\x1B[0;34m]\x1B[0m ",
    info_prefix: []const u8 = "\x1B[0;34m[\x1B[0;32m*\x1B[0;34m]\x1B[0m ",
    warn_prefix: []const u8 = "\x1B[0;34m[\x1B[0;33mW\x1B[0;34m]\x1B[0m ",
    error_prefix: []const u8 = "\x1B[0;34m[\x1B[0;31mE\x1B[0;34m]\x1B[0m ",
    fatal_prefix: []const u8 = "\x1B[0;34m[\x1B[0;35mF\x1B[0;34m]\x1B[0m ",

    minimum_log_level: LogLevel = .Info,
    enabled: bool = true,
};

pub const PathOptions = struct {
    root: []const u8 = "/",
    config: []const u8 = "etc/" ++ config.name,
    cache: []const u8 = "etc/" ++ config.name ++ "/.cache",
    db: []const u8 = "etc/" ++ config.name ++ "/.db",
    store: []const u8 = "etc/" ++ config.name ++ "/.store",
};

pub const Context = struct {
    io: Io,
    alloc: std.mem.Allocator,

    store: ?store.StoreConn = null,

    log_options: LogOptions = .{},
    path_options: PathOptions = .{},

    log_cb: *const fn (Io, LogLevel, []const u8) anyerror!void = defaultLogCb,

    pub fn init(alloc: Allocator, io: Io) Context {
        return .{
            .io = io,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Context) void {
        if (self.store) |conn| conn.close();
    }

    pub fn getStore(self: Context) !store.StoreConn {
        return self.store orelse error.NoStoreAvailable;
    }

    pub fn log(
        self: Context,
        level: LogLevel,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        if (!self.log_options.enabled) return;
        if (@intFromEnum(level) < @intFromEnum(self.log_options.minimum_log_level)) return;

        const prefix = switch (level) {
            .None => "",
            .Debug => self.log_options.debug_prefix,
            .Info => self.log_options.info_prefix,
            .Warn => self.log_options.warn_prefix,
            .Error => self.log_options.error_prefix,
            .Fatal => self.log_options.fatal_prefix,
        };

        const msg = try std.fmt.allocPrint(self.alloc, "{s}" ++ fmt, .{prefix} ++ args);
        defer self.alloc.free(msg);

        try self.log_cb(self.io, level, msg);
    }
};

fn defaultLogCb(io: Io, level: LogLevel, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const file = switch (level) {
        .Fatal, .Error, .Warn => Io.File.stderr(),
        .None, .Info, .Debug => Io.File.stdout(),
    };

    var writer = file.writer(io, &buf);
    const w = &writer.interface;
    try w.writeAll(msg);
    try w.flush();
}
