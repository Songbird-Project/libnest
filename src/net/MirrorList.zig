const std = @import("std");

const Downloader = @import("Downloader.zig");
const Db = @import("../core/Database.zig");
const Pkg = @import("../core/Package.zig");

const MirrorList = @This();

alloc: std.mem.Allocator,
mirrors: [][]const u8,

pub fn init(alloc: std.mem.Allocator, path: []const u8) !MirrorList {
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
        if (mirrors_writer.written().len <= 0) continue;
        if (mirrors_writer.written().len >= 1 and mirrors_writer.written()[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, mirrors_writer.written(), '=')) |eql| {
            const mirror = std.mem.trim(
                u8,
                mirrors_writer.written()[eql + 1 .. mirrors_writer.written().len],
                " \r\t",
            );
            try mirrors.append(
                alloc,
                try alloc.dupe(u8, mirror),
            );
        }

        _ = mirror_file.toss(1);
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

pub fn downloadPkg(
    self: MirrorList,
    mdb_name_repo: Db.c.MDB_val,
    pkg: Pkg,
    dest: []const u8,
    download_cb: ?*const Downloader.callback,
) !void {
    var dl: Downloader = try .init(self.alloc, 3, download_cb);
    defer dl.deinit();

    const name_repo = @as(
        [*]const u8,
        @ptrCast(mdb_name_repo.mv_data),
    )[0..mdb_name_repo.mv_size];
    const name_repo_delim = std.mem.indexOfScalar(u8, name_repo, 0);
    const repo = name_repo[name_repo_delim.? + 1 ..];

    for (self.mirrors) |mirror| {
        const url = try self.fmtMirrorURL(
            mirror,
            repo,
            pkg.arch,
            pkg.filename,
        );
        defer self.alloc.free(url);

        dl.download(url, dest) catch continue;
        break;
    }
}

pub fn downloadDb(
    self: MirrorList,
    name: []const u8,
    arch: []const u8,
    dest: []const u8,
    download_cb: ?*const Downloader.callback,
) !void {
    var dl: Downloader = try .init(self.alloc, 3, download_cb);
    defer dl.deinit();

    for (self.mirrors) |mirror| {
        const url = try self.fmtDbURL(mirror, name, arch);
        defer self.alloc.free(url);

        dl.download(url, dest) catch continue;
        break;
    }
}

pub fn fmtMirrorURL(
    self: MirrorList,
    mirror: []const u8,
    repo: []const u8,
    arch: []const u8,
    filename: []const u8,
) ![]const u8 {
    const repo_size = std.mem.replacementSize(
        u8,
        mirror,
        "$repo",
        repo,
    );
    const repo_url = try self.alloc.alloc(u8, repo_size);
    defer self.alloc.free(repo_url);
    _ = std.mem.replace(
        u8,
        mirror,
        "$repo",
        repo,
        repo_url,
    );

    const arch_size = std.mem.replacementSize(
        u8,
        repo_url,
        "$arch",
        arch,
    );
    const url = try self.alloc.alloc(u8, arch_size);
    defer self.alloc.free(url);
    _ = std.mem.replace(
        u8,
        repo_url,
        "$arch",
        arch,
        url,
    );

    const pkg_url = try std.fmt.allocPrint(
        self.alloc,
        "{s}/{s}",
        .{ url, filename },
    );

    return pkg_url;
}

pub fn fmtDbURL(
    self: MirrorList,
    mirror: []const u8,
    name: []const u8,
    arch: []const u8,
) ![]const u8 {
    const repo_size = std.mem.replacementSize(
        u8,
        mirror,
        "$repo",
        name,
    );
    const repo_url = try self.alloc.alloc(u8, repo_size);
    defer self.alloc.free(repo_url);
    _ = std.mem.replace(
        u8,
        mirror,
        "$repo",
        name,
        repo_url,
    );

    const arch_size = std.mem.replacementSize(
        u8,
        repo_url,
        "$arch",
        arch,
    );
    const url = try self.alloc.alloc(u8, arch_size);
    defer self.alloc.free(url);
    _ = std.mem.replace(
        u8,
        repo_url,
        "$arch",
        arch,
        url,
    );

    const db_url = try std.fmt.allocPrint(
        self.alloc,
        "{s}/{s}.files",
        .{ url, name },
    );

    return db_url;
}
