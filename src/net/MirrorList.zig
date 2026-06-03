const std = @import("std");
const mem = @import("../utils/mem.zig");

const Downloader = @import("Downloader.zig");
const Db = @import("../core/Database.zig");
const Pkg = @import("../core/Package.zig");
const Context = @import("../core/Context.zig");

const MirrorError = error{
    CorruptDownload,
    RepoNotFound,
    FailedToDownloadPackage,
    FailedToDownloadDb,
};

pub const MirrorConfig = struct {
    repos: []const []const u8,
    path: []const u8,
};

const MirrorList = @This();

alloc: std.mem.Allocator,
mirrors: std.StringHashMap([][]const u8),

pub fn init(io: std.Io, alloc: std.mem.Allocator, mirrors: []const MirrorConfig) !MirrorList {
    var mirrorlist = std.StringHashMap([][]const u8).init(alloc);
    errdefer {
        var it = mirrorlist.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            mem.freeSlice(alloc, entry.value_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        mirrorlist.deinit();
    }

    for (mirrors) |mirror| {
        const mirror_file = try std.Io.Dir.cwd().readFileAlloc(
            io,
            mirror.path,
            alloc,
            .unlimited,
        );
        defer alloc.free(mirror_file);

        var parsed: std.ArrayList([]const u8) = .empty;
        defer {
            for (parsed.items) |v| alloc.free(v);
            parsed.deinit(alloc);
        }

        var lines = std.mem.splitScalar(u8, mirror_file, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(
                u8,
                raw_line,
                " \r\t",
            );
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            if (std.mem.findScalar(u8, line, '=')) |eql| {
                const stripped_line = std.mem.trim(
                    u8,
                    line[eql + 1 ..],
                    " \t\n\r",
                );
                if (!std.mem.startsWith(u8, stripped_line, "http://") and
                    !std.mem.startsWith(u8, stripped_line, "https://")) continue;
                try parsed.append(alloc, try alloc.dupe(u8, stripped_line));
            }
        }

        const owned = try parsed.toOwnedSlice(alloc);
        defer {
            for (owned) |m| alloc.free(m);
            alloc.free(owned);
        }
        for (mirror.repos) |repo| {
            var repo_mirrors: std.ArrayList([]const u8) = .empty;
            defer {
                for (repo_mirrors.items) |r| alloc.free(r);
                repo_mirrors.deinit(alloc);
            }

            for (owned) |m| {
                try repo_mirrors.append(alloc, try alloc.dupe(u8, m));
            }

            try mirrorlist.put(
                try alloc.dupe(u8, repo),
                try repo_mirrors.toOwnedSlice(alloc),
            );
        }
    }

    return MirrorList{
        .alloc = alloc,
        .mirrors = mirrorlist,
    };
}

pub fn deinit(self: *MirrorList) void {
    var key_it = self.mirrors.keyIterator();
    while (key_it.next()) |k| self.alloc.free(k.*);
    var val_it = self.mirrors.valueIterator();
    while (val_it.next()) |values| {
        for (values.*) |value| {
            self.alloc.free(value);
        }
        self.alloc.free(values.*);
    }

    self.mirrors.deinit();
}

pub fn downloadPkg(
    self: MirrorList,
    ctx: *Context,
    pkg: Pkg,
    dest: []const u8,
) !void {
    var dl = try Downloader.init(
        ctx.io,
        self.alloc,
        3,
        ctx.download_cb,
    );
    defer dl.deinit();

    const mirrors = self.mirrors.get(pkg.repo);
    if (mirrors == null) return error.RepoNotFound;
    if (mirrors.?.len == 0) return error.NoMirrorsForRepo;

    var downloaded = false;
    for (mirrors.?) |mirror| {
        const url = try self.fmtMirrorURL(
            mirror,
            pkg.repo,
            ctx.arch,
            pkg.filename,
        );
        defer self.alloc.free(url);

        dl.download(ctx.io, url, dest, pkg.name) catch continue;
        downloaded = true;
        break;
    }

    if (!downloaded) return error.FailedToDownloadPackage;

    const hash_file = try std.Io.Dir.cwd().readFileAlloc(
        ctx.io,
        dest,
        self.alloc,
        .unlimited,
    );
    defer self.alloc.free(hash_file);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(hash_file);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    var pkg_hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&pkg_hash, pkg.checksum);

    if (!std.mem.eql(u8, &pkg_hash, &hash)) return error.CorruptDownload;
}

pub fn downloadDb(
    self: MirrorList,
    ctx: *Context,
    name: []const u8,
    dest: []const u8,
) !void {
    var dl = try Downloader.init(
        ctx.io,
        self.alloc,
        3,
        ctx.download_cb,
    );
    defer dl.deinit();

    var downloaded = false;
    const mirrors = self.mirrors.get(name);

    if (mirrors == null or mirrors.?.len == 0) return error.NoMirrorsForRepo;
    for (mirrors.?) |mirror| {
        const url = try self.fmtDbURL(
            mirror,
            name,
            ctx.arch,
        );
        defer self.alloc.free(url);

        dl.download(ctx.io, url, dest, name) catch continue;
        downloaded = true;
        break;
    }

    if (!downloaded) return error.FailedToDownloadPackage;
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
