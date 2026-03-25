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
    const file: *std.fs.File = @ptrCast(@alignCast(user_data));

    file.writeAll(data) catch {
        return 0;
    };
    return @intCast(real_size);
}

const DlResult = enum { success, retry };

const Downloader = @This();

alloc: std.mem.Allocator,
client: *curl.Easy,
ca_bundle: *std.array_list.Managed(u8),
retry_limit: u8,
retries: u8 = 0,
cb_error: ?anyerror = null,
downloaded: usize = 0,
partial_size: usize = 0,
current_dl: []const u8 = "None",
finished: bool = false,
download_cb: ?*const fn ([]const u8, f64, f64, bool) anyerror!void,

const DownloadError = error{
    TooManyRetries,
    UnexpectedHTTPCode,
};

pub fn init(
    alloc: std.mem.Allocator,
    retries: u8,
    download_cb: ?*const fn ([]const u8, f64, f64, bool) anyerror!void,
) !Downloader {
    const client = try alloc.create(curl.Easy);
    const ca_bundle = try alloc.create(std.array_list.Managed(u8));
    ca_bundle.* = try curl.allocCABundle(alloc);
    client.* = try curl.Easy.init(.{ .ca_bundle = ca_bundle.* });

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
    self.ca_bundle.deinit();
    self.alloc.destroy(self.ca_bundle);
}

fn getTargetSize(self: *Downloader, alloc: std.mem.Allocator, url: []const u8) !?u64 {
    self.client.reset();

    const dup_url = try alloc.dupeZ(u8, url);
    defer alloc.free(dup_url);

    try self.client.setUrl(dup_url);
    try self.client.setMethod(.HEAD);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(
        self.client.handle,
        curl.libcurl.CURLOPT_NOBODY,
        @as(c_long, 1),
    ));

    const response = try self.client.perform();
    if (response.status_code != 200) return null;

    const cl_header = try response.getHeader("Content-Length");
    if (cl_header) |h| {
        const cl = h.get();
        return try std.fmt.parseInt(u64, cl, 10);
    }

    return null;
}

fn fullFile(self: *Downloader, path: []const u8, url: []const u8) !bool {
    var file_res = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file_res.close();

    const stat = try file_res.stat();
    if (stat.size == 0) return false;

    if (try self.getTargetSize(self.alloc, url)) |remote_size| {
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
    url: []const u8,
    dest: []const u8,
    name: []const u8,
) !void {
    self.retries = 0;
    self.current_dl = name;

    if (try fullFile(self, dest, url)) return;

    while (true) {
        self.partial_size = 0;
        self.downloaded = 0;
        self.finished = false;

        const res = try self.attemptDownload(url, dest);

        switch (res) {
            .success => return,
            .retry => {
                if (self.retries >= self.retry_limit) return error.TooManyRetries;
                self.retries += 1;
                continue;
            },
        }
    }
}

pub fn attemptDownload(
    self: *Downloader,
    url: []const u8,
    dest: []const u8,
) !DlResult {
    self.client.reset();

    var headers: curl.Easy.Headers = .{};
    defer headers.deinit();

    const partial_exists: bool = exists: {
        std.fs.cwd().access(dest, .{}) catch |err| switch (err) {
            error.FileNotFound => break :exists false,
            else => return err,
        };
        break :exists true;
    };

    const partial_size = size: {
        break :size (try (std.fs.cwd().openFile(dest, .{}) catch |err| switch (err) {
            error.FileNotFound => break :size 0,
            else => return err,
        }).stat()).size;
    };

    const range = try std.fmt.allocPrintSentinel(self.alloc, "Range: bytes={d}-", .{partial_size}, 0);
    defer self.alloc.free(range);

    var file: std.fs.File = if (partial_exists)
        try std.fs.cwd().openFile(dest, .{ .mode = .read_write })
    else
        try std.fs.cwd().createFile(dest, .{ .truncate = (partial_size == 0), .read = true });
    defer {
        file.sync() catch {};
        file.close();
    }

    if (partial_exists) {
        self.partial_size = partial_size;
        try file.seekFromEnd(0);
    }

    const usable_url = try self.alloc.dupeZ(u8, url);
    defer self.alloc.free(usable_url);
    try self.client.setUrl(usable_url);

    if (partial_exists) try headers.add(range);
    try self.client.setHeaders(headers);

    try self.client.setMethod(.GET);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(
        self.client.handle,
        curl.libcurl.CURLOPT_XFERINFODATA,
        self,
    ));
    try curl.checkCode(curl.libcurl.curl_easy_setopt(
        self.client.handle,
        curl.libcurl.CURLOPT_NOPROGRESS,
        @as(c_long, 0),
    ));
    try curl.checkCode(curl.libcurl.curl_easy_setopt(
        self.client.handle,
        curl.libcurl.CURLOPT_XFERINFOFUNCTION,
        Downloader.cb_wrapper,
    ));

    try self.client.setVerbose(false);
    try self.client.setWritedata(&file);
    try self.client.setWritefunction(Downloader.write);

    const response = try self.client.perform();
    if (self.cb_error) |err| return err;

    if (response.status_code == 200 or (response.status_code == 206 and partial_exists)) {
        self.retries = 0;
        return .success;
    }

    if (response.status_code == 416) return .retry;

    return error.UnexpectedHTTPCode;
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
