const std = @import("std");

const Downloader = @This();

alloc: std.mem.Allocator,
client: *std.http.Client,
retry_limit: u8,
retries: u8 = 0,

pub fn init(alloc: std.mem.Allocator, retries: u8) !Downloader {
    const client = try alloc.create(std.http.Client);
    client.* = std.http.Client{ .allocator = alloc };

    return Downloader{
        .alloc = alloc,
        .client = client,
        .retry_limit = retries,
    };
}

pub fn deinit(self: *Downloader) void {
    self.client.deinit();
    self.alloc.destroy(self.client);
}

pub fn download(
    self: *Downloader,
    url: []const u8,
    dest: []const u8,
) !void {
    const uri = try std.Uri.parse(url);

    var request = try self.client.request(.GET, uri, .{});
    defer request.deinit();

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

    const range = try std.fmt.allocPrint(
        self.alloc,
        "bytes={d}-",
        .{partial_size},
    );
    defer self.alloc.free(range);

    if (partial_exists) {
        const range_header = std.http.Header{
            .name = "Range",
            .value = range,
        };
        request.extra_headers = &[_]std.http.Header{range_header};
    }

    try request.sendBodiless();
    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    if (std.mem.eql(u8, response.head.status.phrase().?, "Range Not Satisfiable")) {
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.mem.eql(u8, header.name, "Content-Range")) {
                const range_delimiter = std.mem.indexOf(u8, header.value, "/");
                const length = try std.fmt.parseInt(
                    usize,
                    header.value[range_delimiter.? + 1 ..],
                    10,
                );
                if (partial_size == length) return;
            }
        }

        if (self.retries == self.retry_limit) {
            return;
        }

        try std.fs.cwd().deleteFile(dest);
        self.retry_limit += 1;
        const err = self.download(
            url,
            dest,
        );
        return err;
    }

    const file: std.fs.File = try std.fs.cwd().createFile(
        dest,
        .{},
    );
    defer file.close();

    var transfer_buffer: [8192]u8 = undefined;
    var response_reader = response.reader(&transfer_buffer);

    var read_buffer: [8092]u8 = undefined;

    while (true) {
        const read_size = try response_reader.readSliceShort(&read_buffer);
        try file.writeAll(read_buffer[0..read_size]);
        if (read_size < read_buffer.len) break;
    }
}
