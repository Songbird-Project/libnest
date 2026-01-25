const std = @import("std");
const curl = @import("curl");

fn write(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.c) c_uint {
    const real_size = size * nmemb;
    const data = (@as([*]const u8, @ptrCast(ptr)))[0..real_size];
    const file: *std.fs.File = @ptrCast(@alignCast(user_data));

    file.writeAll(data) catch {
        return 0; // Indicate an error
    };
    return @intCast(real_size);
}

pub const callback = fn (f64, f64) anyerror!void;

const Downloader = @This();

alloc: std.mem.Allocator,
client: *curl.Easy,
ca_bundle: *std.array_list.Managed(u8),
retry_limit: u8,
retries: u8 = 0,
cb_error: ?anyerror = null,
cb_filled: ?u8 = null,
download_cb: ?*const Downloader.callback,

const DownloadError = error{
    TooManyRetries,
};

pub fn init(
    alloc: std.mem.Allocator,
    retries: u8,
    download_cb: ?*const Downloader.callback,
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

pub fn download(
    self: *Downloader,
    url: []const u8,
    dest: []const u8,
) !void {
    var headers: curl.Easy.Headers = .{};

    const partial_exists: bool = exists: {
        std.fs.cwd().access(dest, .{}) catch |err| switch (err) {
            error.FileNotFound => break :exists false,
            else => return err,
        };

        break :exists true;
    };

    const partial_size = size: {
        break :size (try (std.fs.cwd().openFile(
            dest,
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => break :size 0,
            else => return err,
        }).stat()).size;
    };

    const range = try std.fmt.allocPrintSentinel(
        self.alloc,
        "Range: bytes={d}-",
        .{partial_size},
        0,
    );
    defer self.alloc.free(range);

    var file: std.fs.File = if (partial_exists)
        try std.fs.cwd().openFile(
            dest,
            .{ .mode = .read_write },
        )
    else
        try std.fs.cwd().createFile(
            dest,
            .{},
        );
    defer file.close();

    if (partial_exists) {
        try file.seekTo(partial_size);
    }

    const usable_url = try self.alloc.dupeZ(u8, url);
    defer self.alloc.free(usable_url);
    try self.client.setUrl(usable_url);

    if (partial_exists) try headers.add(range);
    try self.client.setHeaders(headers);

    try self.client.setMethod(.GET);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(
        self.client.handle,
        curl.libcurl.CURLOPT_XFERINFOFUNCTION,
        Downloader.cb_wrapper,
    ));
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

    try self.client.setWritedata(&file);
    try self.client.setWritefunction(Downloader.write);

    const response = try self.client.perform();
    if (self.cb_error) |err| return err;

    if (response.status_code == 416) {
        if (try response.getHeader("Content-Range")) |cr_header| {
            const range_delimiter = std.mem.indexOf(u8, cr_header.get(), "/");
            const length = try std.fmt.parseInt(
                usize,
                cr_header.get()[range_delimiter.? + 1 ..],
                10,
            );
            if (partial_size == length) return;
        }

        if (self.retries == self.retry_limit) {
            return error.TooManyRetries;
        }

        try std.fs.cwd().deleteFile(dest);
        self.retries += 1;
        try self.download(
            url,
            dest,
        );
    }
}

pub fn cb_wrapper(
    clientp: *anyopaque,
    c_dltotal: c_long,
    c_dlnow: c_long,
    _: c_long,
    _: c_long,
) callconv(.c) c_uint {
    const dlnow: f64 = @floatFromInt(c_dlnow);
    const dltotal: f64 = @floatFromInt(c_dltotal);

    if (dltotal <= 0) return curl.libcurl.CURL_PROGRESSFUNC_CONTINUE;

    const self: *Downloader = @ptrCast(@alignCast(clientp));

    if (self.download_cb) |cb| {
        cb(dlnow, dltotal) catch |err| {
            self.cb_error = err;
            return 1;
        };
    }

    return curl.libcurl.CURL_PROGRESSFUNC_CONTINUE;
}
