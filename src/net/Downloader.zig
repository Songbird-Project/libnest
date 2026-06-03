const std = @import("std");
const curl = @import("curl");

fn write(
    ptr: [*c]c_char,
    size: c_uint,
    nmemb: c_uint,
    user_data: *anyopaque,
) callconv(.c) c_uint {
    const real_size = size * nmemb;
    const data = (@as([*]const u8, @ptrCast(ptr)))[0..real_size];
    const file_writer: *std.Io.File.Writer = @ptrCast(@alignCast(user_data));

    file_writer.interface.writeAll(data) catch return 0;
    return @intCast(real_size);
}

const Downloader = @This();

alloc: std.mem.Allocator,
client: *curl.Easy,
ca_bundle: std.array_list.Aligned(u8, null),
retry_limit: u8,
retries: u8 = 0,
cb_error: ?anyerror = null,
downloaded: usize = 0,
partial_size: usize = 0,
current_dl: []const u8 = "None",
finished: bool = false,
download_cb: ?*const fn ([]const u8, f64, f64, bool) anyerror!void,

pub fn init(
    io: std.Io,
    alloc: std.mem.Allocator,
    retries: u8,
    download_cb: ?*const fn ([]const u8, f64, f64, bool) anyerror!void,
) !Downloader {
    var ca_bundle = try curl.allocCABundle(alloc, io);
    errdefer ca_bundle.deinit(alloc);

    const client = try alloc.create(curl.Easy);
    errdefer alloc.destroy(client);

    client.* = try curl.Easy.init(.{ .ca_bundle = ca_bundle });
    errdefer client.deinit();

    return Downloader{
        .alloc = alloc,
        .client = client,
        .ca_bundle = ca_bundle,
        .retry_limit = retries,
        .download_cb = download_cb,
    };
}

pub fn deinit(self: *Downloader) void {
    self.client.deinit();
    self.alloc.destroy(self.client);
    self.ca_bundle.deinit(self.alloc);
}

fn checkComplete(self: *Downloader, io: std.Io, path: []const u8, url: []const u8) !bool {
    var file_res = std.Io.Dir.cwd().openFile(
        io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file_res.close(io);

    const stat = try file_res.stat(io);
    if (stat.size == 0) return false;

    self.client.reset();
    const dup_url = try self.alloc.dupeZ(u8, url);
    defer self.alloc.free(dup_url);
    try self.client.setUrl(dup_url);
    try self.client.setMethod(.HEAD);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(
        self.client.handle,
        curl.libcurl.CURLOPT_NOBODY,
        @as(c_long, 1),
    ), null);

    const response = try self.client.perform();
    if (response.status_code != 200) return false;

    const cl_header = try response.getHeader("Content-Length");
    if (cl_header) |h| {
        const remote_size = try std.fmt.parseInt(u64, h.get(), 10);
        if (stat.size != remote_size) return false;
    }

    if (self.download_cb) |cb| {
        cb(
            self.current_dl,
            @as(f64, @floatFromInt(stat.size)),
            @as(f64, @floatFromInt(stat.size)),
            true,
        ) catch {};
    }

    return true;
}

pub fn download(
    self: *Downloader,
    io: std.Io,
    url: []const u8,
    dest: []const u8,
    name: []const u8,
) !void {
    self.retries = 0;
    self.current_dl = name;

    if (try self.checkComplete(io, dest, url)) return;

    while (true) {
        self.partial_size = 0;
        self.downloaded = 0;
        self.finished = false;
        self.cb_error = null;

        const success = try self.attempt(io, url, dest);
        if (success) return;

        if (self.retries >= self.retry_limit) return error.TooManyRetries;
        self.retries += 1;
    }
}

pub fn attempt(
    self: *Downloader,
    io: std.Io,
    url: []const u8,
    dest: []const u8,
) !bool {
    self.client.reset();

    var file = blk: {
        const f = std.Io.Dir.cwd().openFile(io, dest, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => break :blk try std.Io.Dir.cwd().createFile(io, dest, .{ .read = true }),
            else => return err,
        };
        break :blk f;
    };
    defer {
        file.sync(io) catch {};
        file.close(io);
    }
    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    defer file_writer.flush() catch {};

    const partial_size = (try file.stat(io)).size;
    if (partial_size > 0) {
        self.partial_size = partial_size;
        try file_writer.seekTo(partial_size);
    }

    var headers: curl.Easy.Headers = .{};
    defer headers.deinit();

    const range = try std.fmt.allocPrintSentinel(
        self.alloc,
        "Range: bytes={d}-",
        .{partial_size},
        0,
    );
    defer self.alloc.free(range);

    const usable_url = try self.alloc.dupeZ(u8, url);
    defer self.alloc.free(usable_url);
    try self.client.setUrl(usable_url);

    if (partial_size > 0) try headers.add(range);
    try self.client.setHeaders(headers);

    try self.client.setMethod(.GET);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(
        self.client.handle,
        curl.libcurl.CURLOPT_XFERINFODATA,
        self,
    ), null);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(
        self.client.handle,
        curl.libcurl.CURLOPT_NOPROGRESS,
        @as(c_long, 0),
    ), null);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(
        self.client.handle,
        curl.libcurl.CURLOPT_XFERINFOFUNCTION,
        Downloader.cb_wrapper,
    ), null);

    try self.client.setVerbose(false);
    try self.client.setWritedata(&file_writer);
    try self.client.setWritefunction(Downloader.write);

    const response = try self.client.perform();
    if (self.cb_error) |err| return err;

    return switch (response.status_code) {
        200 => true,
        206 => if (partial_size > 0) true else false,
        416 => false,
        else => error.UnexpectedHTTPCode,
    };
}

pub fn cb_wrapper(
    clientp: *anyopaque,
    c_dltotal: curl.libcurl.curl_off_t,
    c_dlnow: curl.libcurl.curl_off_t,
    _: curl.libcurl.curl_off_t,
    _: curl.libcurl.curl_off_t,
) callconv(.c) c_uint {
    const self: *Downloader = @ptrCast(@alignCast(clientp));

    const total_downloaded: f64 = @as(f64, @floatFromInt(c_dlnow)) + @as(f64, @floatFromInt(self.partial_size));
    const total_size: f64 = if (c_dltotal > 0)
        @as(f64, @floatFromInt(c_dltotal)) + @as(f64, @floatFromInt(self.partial_size))
    else
        0;

    var done: bool = false;
    if (total_size > 0 and total_downloaded >= total_size) {
        if (!self.finished) {
            done = true;
            self.finished = true;
        } else return 0;
    }

    if (self.downloaded == @as(usize, @intFromFloat(total_size))) return 0;
    self.downloaded = @as(usize, @intFromFloat(total_downloaded));

    if (self.download_cb) |cb| {
        cb(self.current_dl, total_downloaded, total_size, done) catch |err| {
            self.cb_error = err;
            return 1;
        };
    }

    return 0;
}
