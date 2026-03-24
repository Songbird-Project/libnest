const std = @import("std");

const Downloader = @import("Downloader.zig");
const Db = @import("../core/Database.zig");
const Pkg = @import("../core/Package.zig");
const Context = @import("../core/Context.zig");

const MirrorList = @This();

alloc: std.mem.Allocator,
mirrors: [][]const u8,

pub fn init(alloc: std.mem.Allocator, path: []const u8) !MirrorList {
    const mirror_file = try std.fs.cwd().readFileAlloc(
        alloc,
        path,
        1024 * 1024,
    );
    defer alloc.free(mirror_file);

    var mirrors: std.ArrayList([]const u8) = .empty;
    defer mirrors.deinit(alloc);

    var lines = std.mem.splitScalar(u8, mirror_file, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(
            u8,
            raw_line,
            " \r\t",
        );
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eql| {
            const mirror = std.mem.trim(u8, line[eql + 1 ..], " \t");
            if (!std.mem.startsWith(u8, mirror, "http://") and
                !std.mem.startsWith(u8, mirror, "https://")) continue;
            try mirrors.append(alloc, try alloc.dupe(u8, mirror));
        }
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
    ctx: *Context,
    pkg: Pkg,
    dest: []const u8,
) !void {
    var dl = try Downloader.init(
        self.alloc,
        3,
        ctx.download_cb,
    );
    defer dl.deinit();

    for (self.mirrors) |mirror| {
        const url = try self.fmtMirrorURL(
            mirror,
            pkg.repo,
            ctx.arch,
            pkg.filename,
        );
        defer self.alloc.free(url);

        dl.download(url, dest) catch continue;
        break;
    }
}

pub fn downloadDb(
    self: MirrorList,
    ctx: *Context,
    name: []const u8,
    dest: []const u8,
) !void {
    var dl = try Downloader.init(
        self.alloc,
        3,
        ctx.download_cb,
    );
    defer dl.deinit();

    for (self.mirrors) |mirror| {
        const url = try self.fmtDbURL(
            mirror,
            name,
            ctx.arch,
        );
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
        "{s}/{s}.db",
        .{ url, name },
    );

    return db_url;
}
