const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const RepoConn = @import("./repo.zig").RepoConn;
const config = @import("config.zig").config;

pub const LogLevel = enum(u8) { Debug, Info, Warn, Error, Fatal, None };

pub const LogOptions = struct {
    debug_prefix: []const u8 = "\x1B[0;34m[\x1B[0;37mD\x1B[0;34m]\x1B[0m ",
    info_prefix: []const u8 = "\x1B[0;34m[\x1B[0;32m*\x1B[0;34m]\x1B[0m ",
    warn_prefix: []const u8 = "\x1B[0;34m[\x1B[0;33mW\x1B[0;34m]\x1B[0m ",
    error_prefix: []const u8 = "\x1B[0;34m[\x1B[0;31mE\x1B[0;34m]\x1B[0m ",
    fatal_prefix: []const u8 = "\x1B[0;34m[\x1B[0;35mF\x1B[0;34m]\x1B[0m ",

    minimum_log_level: LogLevel = .Info,
};

pub const PathOptions = struct {
    root: []const u8 = "/",
    config: []const u8 = "etc/" ++ config.name,
    cache: []const u8 = "var/cache/" ++ config.name,
    state: []const u8 = "var/lib/" ++ config.name,
    store: []const u8 = "etc/" ++ config.name ++ "/store",
};

pub const Context = struct {
    io: Io,
    alloc: std.mem.Allocator,

    repos: std.StringHashMap(RepoConn),

    log_options: LogOptions = .{},
    path_options: PathOptions = .{},

    log_cb: *const fn (Io, LogLevel, []const u8) anyerror!void = defaultLogCb,
    select_cb: *const fn (Io, usize) anyerror!usize = defaultSelectCb,

    pub fn init(alloc: Allocator, io: Io) Context {
        return .{
            .io = io,
            .alloc = alloc,

            .repos = .init(alloc),
        };
    }

    pub fn deinit(self: *Context) void {
        var it = self.repos.valueIterator();
        while (it.next()) |conn| conn.deinit(self.*);
        self.repos.deinit();
    }

    pub fn log(
        self: Context,
        level: LogLevel,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
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

    pub fn select(self: Context, items: usize) !usize {
        return try self.select_cb(self.io, items);
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

fn defaultSelectCb(io: Io, items: usize) !usize {
    if (items == 0) return 0;

    var stdin_buf: [16]u8 = undefined;
    const stdin_file = Io.File.stdin();

    var stdin_reader = stdin_file.reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_buf: [256]u8 = undefined;
    const file = Io.File.stdout();
    var writer = file.writer(io, &stdout_buf);
    const w = &writer.interface;

    var buf: [16]u8 = undefined;
    var input = Io.Writer.fixed(&buf);

    while (true) {
        try w.print("Select [1-{d}]: ", .{items});
        try w.flush();

        _ = try stdin.streamDelimiter(&input, '\n');
        const trimmed = std.mem.trim(u8, input.buffered(), " \t\r\n");

        const val = std.fmt.parseInt(usize, trimmed, 10) catch continue;

        if (val <= 0 or val > items) continue;

        return val - 1;
    }
}
