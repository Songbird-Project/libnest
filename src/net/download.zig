const std = @import("std");
const Io = std.Io;
const curl = @import("curl");

const Repo = @import("../core/repo.zig").Repo;
const Context = @import("../core/context.zig").Context;
const resolve = @import("../core/resolve.zig");

pub const CurlClient = struct {
    easy: *curl.Easy,
    ca_bundle: std.array_list.Aligned(u8, null),

    pub fn init(context: Context) !CurlClient {
        var ca_bundle = try curl.allocCABundle(context.alloc, context.io);
        errdefer ca_bundle.deinit(context.alloc);

        const easy = try context.alloc.create(curl.Easy);
        errdefer context.alloc.destroy(easy);

        easy.* = try curl.Easy.init(.{ .ca_bundle = ca_bundle });
        errdefer easy.deinit();

        return .{
            .easy = easy,
            .ca_bundle = ca_bundle,
        };
    }

    pub fn deinit(self: *CurlClient, context: Context) void {
        self.easy.deinit();
        context.alloc.destroy(self.easy);
        self.ca_bundle.deinit(context.alloc);
    }

    pub fn download(
        self: CurlClient,
        context: Context,
        url: []const u8,
        dest: []const u8,
    ) !void {
        defer self.easy.reset();

        const c_url = try context.alloc.dupeSentinel(u8, url, 0);
        defer context.alloc.free(c_url);

        const tmp = try Io.Dir.path.join(context.alloc, &.{
            Io.Dir.path.dirname(dest) orelse "",
            ".tmp",
            Io.Dir.path.basename(dest),
        });
        try Io.Dir.cwd().createDirPath(context.io, Io.Dir.path.dirname(tmp).?);

        const out = try std.Io.Dir.cwd().createFile(context.io, tmp, .{});
        defer out.close(context.io);
        var out_buf: [8192]u8 = undefined;
        var writer = out.writer(context.io, &out_buf);
        const file_writer = &writer.interface;

        try self.easy.setMethod(.GET);
        try self.easy.setUrl(c_url);
        try self.easy.setWriter(file_writer);

        const res = try self.easy.perform();
        try file_writer.flush();
        if (res.status_code != 200) {
            if (self.easy.diagnostics.getMessage()) |msg| {
                context.log(.Error, "GET request failed: {s}", .{msg}) catch {};
            }
            return error.DownloadFailed;
        }

        try Io.Dir.cwd().rename(tmp, .cwd(), dest, context.io);
    }

    pub fn downloadFromMirror(
        self: CurlClient,
        context: Context,
        repo: Repo,
        fmt: []const u8,
        filename: []const u8,
        dest: []const u8,
    ) !bool {
        const alloc = context.alloc;
        const resolved = try resolve.mirrorUrl(alloc, fmt, filename, .{
            .formatters = &.{
                .{ .key = "arch", .value = repo.arch },
                .{ .key = "repo", .value = repo.name },
            },
        });
        defer alloc.free(resolved);

        self.download(context, resolved, dest) catch |err| switch (err) {
            error.DownloadFailed => return false,
            else => return err,
        };

        return true;
    }

    pub fn downloadFromMirrors(
        self: CurlClient,
        context: Context,
        repo: Repo,
        filename: []const u8,
        dest: []const u8,
    ) !void {
        var success = false;
        for (repo.mirrors) |fmt| {
            success = self.downloadFromMirror(context, repo, fmt, filename, dest) catch |err| switch (err) {
                error.DownloadFailed => {},
                else => return err,
            };
            if (success) break;
        }
        if (!success) return error.AllMirrorsFailed;
    }
};
