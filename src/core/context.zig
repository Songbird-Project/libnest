const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const RepoConn = @import("./repo.zig").RepoConn;
const config = @import("config.zig").config;

pub const LogLevel = enum(u8) { Debug, Info, Warn, Error, Fatal };

pub const LogOptions = struct {
    debug_prefix: []const u8 = "\x1B[0;34m[\x1B[0;37mD\x1B[0;34m]\x1B[0m ",
    info_prefix: []const u8 = "\x1B[0;34m[\x1B[0;32m*\x1B[0;34m]\x1B[0m ",
    warn_prefix: []const u8 = "\x1B[0;34m[\x1B[0;33mW\x1B[0;34m]\x1B[0m ",
    error_prefix: []const u8 = "\x1B[0;34m[\x1B[0;31mE\x1B[0;34m]\x1B[0m ",
    fatal_prefix: []const u8 = "\x1B[0;34m[\x1B[0;35mF\x1B[0;34m]\x1B[0m ",
};

pub const PathOptions = struct {
    root: []const u8 = "/",
    config: []const u8 = "etc/" ++ config.name,
    cache: []const u8 = "var/cache/" ++ config.name,
    state: []const u8 = "var/lib/" ++ config.name,
    store: []const u8 = "etc/" ++ config.name ++ "/store",
};

pub const Context = struct {
    io: std.Io,
    alloc: std.mem.Allocator,

    repos: std.StringHashMap(RepoConn),

    log_options: LogOptions = .{},
    path_options: PathOptions = .{},

    log_cb: *const fn (std.Io, LogLevel, []const u8) void = defaultLogCb,

    pub fn init(alloc: Allocator, io: Io) Context {
        return .{
            .io = io,
            .alloc = alloc,

            .repos = .init(alloc),
        };
    }

    pub fn deinit(self: *Context) void {
        var it = self.repos.valueIterator();
        while (it.next()) |conn| conn.deinit(self);
        self.repos.deinit();
    }

    pub fn log(
        self: Context,
        level: LogLevel,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const prefix = switch (level) {
            .Debug => self.log_options.debug_prefix,
            .Info => self.log_options.info_prefix,
            .Warn => self.log_options.warn_prefix,
            .Error => self.log_options.error_prefix,
            .Fatal => self.log_options.fatal_prefix,
        };

        const msg = try std.fmt.allocPrint(self.alloc, "{s}" ++ fmt, .{prefix} ++ args);
        defer self.alloc.free(msg);

        self.log_cb(self.io, level, msg);
    }
};

fn defaultLogCb(io: std.Io, level: LogLevel, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    const file = switch (level) {
        .Fatal, .Error, .Warn => std.Io.File.stderr(),
        .Info, .Debug => std.Io.File.stdout(),
    };

    var writer = file.writer(io, &buf);
    writer.interface.writeAll(msg) catch {};
    writer.interface.flush() catch {};
}
