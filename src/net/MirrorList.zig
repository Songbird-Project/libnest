const std = @import("std");

const Downloader = @import("Downloader.zig");
const Pkg = @import("../core/Package.zig");

const MirrorList = @This();

alloc: std.mem.Allocator,
mirrors: [][]const u8,

pub fn init(
    alloc: std.mem.Allocator,
    path: []const u8,
) !MirrorList {
    var mirror_file_buffer: [8192]u8 = undefined;
    var mirror_file_reader = (try std.fs.cwd().openFile(
        path,
        .{ .mode = .read_only },
    )).reader(&mirror_file_buffer);
    const mirror_file = &mirror_file_reader.interface;

    var mirrors: std.ArrayList([]const u8) = .empty;
    defer mirrors.deinit(alloc);
    var mirrors_writer: std.io.Writer.Allocating = .init(alloc);
    defer mirrors_writer.deinit();

    while (true) {
        _ = mirror_file.streamDelimiter(&mirrors_writer.writer, '\n') catch |err| {
            if (err == error.EndOfStream) break else return err;
        };

        _ = mirror_file.toss(1);
        const mirror = try alloc.dupe(u8, mirrors_writer.written());
        try mirrors.append(alloc, mirror);
        mirrors_writer.clearRetainingCapacity();
    }

    if (mirrors_writer.written().len > 0) {
        try mirrors.append(alloc, mirrors_writer.written());
    }

    return MirrorList{
        .alloc = alloc,
        .mirrors = try mirrors.toOwnedSlice(alloc),
    };
}

pub fn deinit(self: *MirrorList) void {
    for (self.mirrors) |item| self.alloc.free(item);
    self.alloc.free(self.mirrors);
}

pub fn download(
    self: MirrorList,
    pkg: Pkg,
    dest: []const u8,
    download_cb: ?*const fn (downloaded: f64, total: f64) anyerror!void,
) !void {
    var dl: Downloader = try .init(self.alloc, 3, download_cb);
    defer dl.deinit();

    for (self.mirrors) |mirror| {
        const url = try self.fmtPkgURL(mirror, pkg);
        defer self.alloc.free(url);

        dl.download(url, dest) catch continue;
        break;
    }
}

pub fn fmtPkgURL(
    self: MirrorList,
    mirror: []const u8,
    pkg: Pkg,
) ![]const u8 {
    const repo_size = std.mem.replacementSize(
        u8,
        mirror,
        "$repo",
        pkg.repo,
    );
    const repo_url = try self.alloc.alloc(u8, repo_size);
    defer self.alloc.free(repo_url);
    _ = std.mem.replace(
        u8,
        mirror,
        "$repo",
        pkg.repo,
        repo_url,
    );

    const arch_size = std.mem.replacementSize(
        u8,
        repo_url,
        "$arch",
        pkg.arch,
    );
    const url = try self.alloc.alloc(u8, arch_size);
    defer self.alloc.free(url);
    _ = std.mem.replace(
        u8,
        repo_url,
        "$arch",
        pkg.arch,
        url,
    );

    const pkg_url = try Pkg.format(
        self.alloc,
        "{s}/{s}-{s}-{s}.pkg.tar.zst",
        .{ url, pkg.name, pkg.version, pkg.arch },
    );

    return pkg_url;
}
