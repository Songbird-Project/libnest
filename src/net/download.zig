const std = @import("std");
const curl = @import("curl");

const context = @import("../core/context.zig");
const Context = context.Context;

pub const CurlClient = struct {
    easy: *curl.Easy,
    ca_bundle: std.array_list.Aligned(u8, null),

    pub fn init(ctx: Context) !CurlClient {
        var ca_bundle = try curl.allocCABundle(ctx.alloc, ctx.io);
        errdefer ca_bundle.deinit(ctx.alloc);

        const easy = try ctx.alloc.create(curl.Easy);
        errdefer ctx.alloc.destroy(easy);

        easy.* = try curl.Easy.init(.{ .ca_bundle = ca_bundle });
        errdefer easy.deinit();

        return .{
            .easy = easy,
            .ca_bundle = ca_bundle,
        };
    }

    pub fn deinit(self: *CurlClient, ctx: Context) void {
        self.easy.deinit();
        ctx.alloc.destroy(self.easy);
        self.ca_bundle.deinit(ctx.alloc);
    }

    pub fn downloadToFile(
        self: CurlClient,
        ctx: Context,
        url: []const u8,
        dest: []const u8,
    ) !void {
        defer self.easy.reset();

        const c_url = try ctx.alloc.dupeSentinel(u8, url, 0);
        defer ctx.alloc.free(c_url);

        const out = try std.Io.Dir.cwd().createFile(ctx.io, dest, .{});
        defer out.close(ctx.io);
        var out_buf: [8192]u8 = undefined;
        var writer = out.writer(ctx.io, &out_buf);
        const file_writer = &writer.interface;

        try self.easy.setMethod(.GET);
        try self.easy.setUrl(c_url);
        try self.easy.setWriter(file_writer);

        const res = try self.easy.perform();
        try file_writer.flush();
        if (res.status_code != 200) {
            if (self.easy.diagnostics.getMessage()) |msg| {
                ctx.log(.Error, "GET request failed: {s}", .{msg}) catch {};
            }
            return error.DownloadFailed;
        }
    }
};
