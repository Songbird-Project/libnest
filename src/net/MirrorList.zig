const std = @import("std");

const Downloader = @import("Downloader.zig");
const Db = @import("../core/Database.zig");

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

pub fn downloadPkg(
    self: MirrorList,
    db: *Db,
    name: []const u8,
    repo: []const u8,
    dest: []const u8,
    download_cb: ?*const Downloader.callback,
) !void {
    var dl: Downloader = try .init(self.alloc, 3, download_cb);
    defer dl.deinit();

    const filename_query =
        \\SELECT filename FROM packages WHERE name=? and repo=?
    ;
    var filename_stmt = try db.sqlite_db.prepare(filename_query);
    defer filename_stmt.deinit();

    const filename = try filename_stmt.oneAlloc([]const u8, self.alloc, .{}, .{
        .name = name,
        .repo = repo,
    });
    defer if (filename) |f| self.alloc.free(f);

    const arch_query =
        \\SELECT arch FROM packages WHERE name=? and repo=?
    ;
    var arch_stmt = try db.sqlite_db.prepare(arch_query);
    defer arch_stmt.deinit();

    const arch = try arch_stmt.oneAlloc([]const u8, self.alloc, .{}, .{
        .name = name,
        .repo = repo,
    });
    defer if (arch) |a| self.alloc.free(a);

    for (self.mirrors) |mirror| {
        const url = try self.fmtMirrorURL(
            mirror,
            repo,
            arch.?,
            filename.?,
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
