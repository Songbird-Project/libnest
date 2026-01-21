const std = @import("std");
const curl = @import("curl");

const Downloader = @This();

alloc: std.mem.Allocator,
client: *curl.Easy,
ca_bundle: *std.array_list.Managed(u8),
retry_limit: u8,
retries: u8 = 0,

const DownloadError = error{
    TooManyRetries,
};

pub fn init(alloc: std.mem.Allocator, retries: u8) !Downloader {
    // const client = try alloc.create(std.http.Client);
    // client.* = std.http.Client{ .allocator = alloc };
    const client = try alloc.create(curl.Easy);
    const ca_bundle = try alloc.create(std.array_list.Managed(u8));
    ca_bundle.* = try curl.allocCABundle(alloc);
    client.* = try curl.Easy.init(.{ .ca_bundle = ca_bundle.* });

    return Downloader{
        .alloc = alloc,
        .client = client,
        .ca_bundle = ca_bundle,
        .retry_limit = retries,
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
    url: [:0]const u8,
    dest: []const u8,
    download_cb: ?*const fn (downloaded: usize, total: usize) void,
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

    if (partial_exists) try headers.add(range);
    try self.client.setUrl(url);
    try self.client.setHeaders(headers);
    try self.client.setMethod(.GET);

    var dl_writer: std.io.Writer.Allocating = .init(self.alloc);
    defer dl_writer.deinit();
    try self.client.setWriter(&dl_writer.writer);

    const response = try self.client.perform();

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
        const err = self.download(
            url,
            dest,
            download_cb,
        );
        return err;
    }

    const file: std.fs.File = if (partial_exists)
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

    // var downloaded: usize = partial_size;
    // while (true) {
    try file.writeAll(dl_writer.writer.buffered());
    // downloaded = (try file.stat()).size;

    // if (try response.getHeader("Content-Length")) |cl_header| {
    //     if (download_cb) |cb| {
    //         cb(
    //             downloaded,
    //             (try std.fmt.parseInt(
    //                 usize,
    //                 cl_header.get(),
    //                 10,
    //             )) + partial_size,
    //         );
    //     }
    // }
    // }
}
