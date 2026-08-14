const std = @import("std");
const curl = @import("curl");

const RepoConn = @import("../core/repo.zig").RepoConn;
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

    pub fn download(
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

    pub fn downloadFromMirror(
        self: CurlClient,
        ctx: Context,
        repo_conn: RepoConn,
        filename: []const u8,
        dest: []const u8,
    ) !void {
        const repo = repo_conn.repo;
        for (repo.mirrors) |mirror| {
            const repo_url = try std.mem.replaceOwned(
                u8,
                ctx.alloc,
                mirror,
                "$repo",
                repo.name,
            );
            defer ctx.alloc.free(repo_url);

            const resolved_url = try std.mem.replaceOwned(
                u8,
                ctx.alloc,
                repo_url,
                "$arch",
                repo.arch,
            );
            defer ctx.alloc.free(resolved_url);

            const url = try std.fmt.allocPrint(
                ctx.alloc,
                "{s}/{s}",
                .{ resolved_url, filename },
            );
            defer ctx.alloc.free(url);

            self.download(ctx, url, dest) catch {
                try ctx.log(
                    .Error,
                    "Failed to download repo file for '{s}' from mirror '{s}'\n",
                    .{ repo.name, url },
                );
                continue;
            };
            return;
        }

        return error.AllMirrorsFailed;
    }
};
