const std = @import("std");
const archive = @import("../utils/archive.zig");
const pkginfo = @import("../parse/pkginfo.zig");

const Db = @import("Database.zig");
const Context = @import("Context.zig");
const Pkg = @import("Package.zig");

pub const PkgInstallInfo = struct {
    pkg: Pkg,
    location: []const u8,
    cache: []const u8,
    files: [][]const u8,

    pub fn clone(self: *PkgInstallInfo, alloc: std.mem.Allocator) !PkgInstallInfo {
        var files = try alloc.alloc([]const u8, self.files.len);
        errdefer {
            for (files) |file| {
                alloc.free(file);
            }
            alloc.free(files);
        }

        for (self.files, 0..) |file, idx| {
            files[idx] = try alloc.dupe(u8, file);
        }

        return .{
            .pkg = try self.pkg.clone(alloc),
            .location = try alloc.dupe(u8, self.location),
            .cache = try alloc.dupe(u8, self.cache),
            .files = files,
        };
    }

    pub fn deinit(self: *PkgInstallInfo, alloc: std.mem.Allocator) void {
        for (self.files) |file| {
            alloc.free(file);
        }

        alloc.free(self.files);
        alloc.free(self.location);
        alloc.free(self.cache);

        self.pkg.deinit(alloc);
    }
};

const InstallerError = error{
    FailedToGetPackageId,
    AlreadyInstalled,
    RelativePathInPackage,
};

pub fn prepareInstall(
    ctx: *Context,
    pkgs: []Pkg,
) ![]PkgInstallInfo {
    try ctx.log(
        .Info,
        .Download,
        "package files",
    );

    var installs: std.ArrayList(PkgInstallInfo) = .empty;
    defer installs.deinit(ctx.alloc);

    for (pkgs) |pkg| {
        const dup = dup: {
            for (ctx.txn.installs.items) |item| {
                if (std.mem.eql(u8, item.pkg.name, pkg.name) and
                    std.mem.eql(u8, item.pkg.version, pkg.version))
                    break :dup true;
            }
            break :dup false;
        };
        if (dup) continue;

        const queried: []Pkg.Installed = try ctx.db.queryPkg(
            .Installed,
            pkg.name,
            pkg.repo,
        );
        defer {
            for (queried) |p| {
                p.deinit(ctx.alloc);
            }
            ctx.alloc.free(queried);
        }
        const diff_ver = blk: {
            for (pkgs) |p| {
                if (std.mem.eql(u8, p.version, pkg.version)) continue else break :blk true;
            }
            break :blk false;
        };
        if (queried.len > 0 and !diff_ver) {
            return error.AlreadyInstalled;
        }

        var file_list: std.ArrayList([]const u8) = .empty;
        defer file_list.deinit(ctx.alloc);

        const cache = try std.fs.path.join(ctx.alloc, &.{
            ctx.paths.cache,
            "pkg",
            if (std.mem.indexOf(u8, pkg.filename, ".pkg.tar.")) |i|
                pkg.filename[0..i]
            else
                pkg.checksum,
        });
        defer ctx.alloc.free(cache);
        try std.fs.cwd().makePath(cache);

        const dest = try std.fs.path.join(ctx.alloc, &.{
            cache,
            pkg.filename,
        });
        defer ctx.alloc.free(dest);

        try ctx.mirrors.downloadPkg(
            ctx,
            pkg,
            dest,
        );

        const file = try std.fs.cwd().openFile(
            dest,
            .{ .mode = .read_only },
        );
        defer file.close();

        var reader = try archive.Reader.init();
        defer reader.deinit();
        try reader.openFd(file.handle);
        while (try reader.nextEntry()) |entry| {
            const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));

            const path_type = archive.c.archive_entry_mode(entry) & archive.c.S_IFMT;

            var rel = path;
            if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
            if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

            const basename = std.fs.path.basename(rel);
            if (basename.len > 0 and basename[0] == '.') continue;

            const install_path = try std.fs.path.join(ctx.alloc, &.{
                ctx.paths.root,
                rel,
            });
            defer ctx.alloc.free(install_path);

            if (path_type == archive.c.S_IFREG or path_type == archive.c.S_IFLNK) {
                try file_list.append(
                    ctx.alloc,
                    try ctx.alloc.dupe(u8, install_path),
                );
            }
        }

        const info = PkgInstallInfo{
            .pkg = try pkg.clone(ctx.alloc),
            .location = try ctx.alloc.dupe(u8, dest),
            .cache = try ctx.alloc.dupe(u8, cache),
            .files = try file_list.toOwnedSlice(ctx.alloc),
        };

        try installs.append(ctx.alloc, info);
    }

    return try installs.toOwnedSlice(ctx.alloc);
}

pub fn install(
    ctx: *Context,
) !void {
    var stmt = try ctx.db.db.prepare(
        \\INSERT INTO installed (name, repo, metadata)
        \\VALUES (?, ?, jsonb(?))
        \\ON CONFLICT(name, repo) DO UPDATE SET
        \\metadata = excluded.metadata
        \\WHERE metadata != excluded.metadata
        ,
    );
    defer stmt.deinit();

    for (ctx.txn.installs.items) |info| {
        try ctx.log(
            .Info,
            .Install,
            info.pkg.name,
        );

        var reader = try archive.Reader.init();
        defer reader.deinit();

        var writer = try archive.Writer.init();
        defer writer.deinit();

        const file = try std.fs.cwd().openFile(
            info.location,
            .{ .mode = .read_only },
        );
        defer file.close();

        try reader.openFd(file.handle);
        var buf: [8192]u8 = undefined;
        while (try reader.nextEntry()) |entry| {
            const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
            const path_type = archive.c.archive_entry_mode(entry) & archive.c.S_IFMT;

            var rel = path;
            if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
            if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

            const basename = std.fs.path.basename(rel);
            const install_path = if (basename.len > 0 and basename[0] == '.')
                try std.fs.path.join(ctx.alloc, &.{
                    info.cache,
                    rel,
                })
            else if (std.mem.startsWith(u8, path, "/usr/share/libalpm/hooks/"))
                try std.fs.path.join(ctx.alloc, &.{
                    ctx.paths.hook,
                    rel[25..],
                })
            else
                try std.fs.path.join(ctx.alloc, &.{
                    ctx.paths.root,
                    rel,
                });
            defer ctx.alloc.free(install_path);

            try writer.writeHeader(
                ctx,
                info,
                entry,
                install_path,
            );

            if (path_type == archive.c.S_IFREG) {
                while (true) {
                    const bytes = try reader.readData(&buf);
                    if (bytes <= 0) break;

                    try writer.writeData(buf[0..bytes], bytes);
                }
            }

            try writer.finishEntry();
        }

        const pkginfo_path = try std.fs.path.join(ctx.alloc, &.{
            info.cache,
            ".PKGINFO",
        });
        defer ctx.alloc.free(pkginfo_path);
        const pkgid = try pkginfo.index(
            ctx,
            info.pkg.repo,
            pkginfo_path,
            &stmt,
        );
        stmt.reset();

        const mtree_path = try std.fs.path.join(ctx.alloc, &.{
            info.cache,
            ".MTREE",
        });
        defer ctx.alloc.free(mtree_path);
        try useMTREE(
            ctx,
            info.cache,
            mtree_path,
        );

        for (info.files) |installed| {
            try ctx.db.insert(pkgid, installed);
        }
    }
}

pub fn useMTREE(
    ctx: *Context,
    cache: []const u8,
    mtree_path: []const u8,
) !void {
    var reader = try archive.Reader.init();
    defer reader.deinit();

    const file = std.fs.cwd().openFile(
        mtree_path,
        .{ .mode = .read_only },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    var visited = std.StringHashMap(void).init(ctx.alloc);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| ctx.alloc.free(k.*);
        visited.deinit();
    }

    try reader.openFd(file.handle);
    while (try reader.nextEntry()) |entry| {
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        const path_type = archive.c.archive_entry_mode(entry) & archive.c.S_IFMT;

        var rel = path;
        if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
        if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

        const basename = std.fs.path.basename(rel);
        const install_path = if (basename.len > 0 and basename[0] == '.')
            try std.fs.path.join(ctx.alloc, &.{
                cache,
                rel,
            })
        else if (std.mem.startsWith(u8, path, "/usr/share/libalpm/hooks/"))
            try std.fs.path.join(ctx.alloc, &.{
                ctx.paths.hook,
                rel[25..],
            })
        else
            try std.fs.path.join(ctx.alloc, &.{
                ctx.paths.root,
                rel,
            });
        defer ctx.alloc.free(install_path);

        if (path_type == archive.c.S_IFREG) {
            const hash_path = hash: {
                if (archive.c.archive_entry_hardlink(entry)) |lnk| {
                    const target: []const u8 = std.mem.span(lnk);

                    var target_rel = target;
                    if (std.mem.startsWith(u8, target, "./")) target_rel = target_rel[2..];
                    if (std.mem.startsWith(u8, target, "/")) target_rel = target_rel[1..];

                    const rel_basename = std.fs.path.basename(target_rel);
                    const target_path = if (rel_basename.len > 0 and rel_basename[0] == '.')
                        try std.fs.path.join(ctx.alloc, &.{
                            cache,
                            target_rel,
                        })
                    else if (std.mem.startsWith(u8, target, "/usr/share/libalpm/hooks/"))
                        try std.fs.path.join(ctx.alloc, &.{
                            ctx.paths.hook,
                            target_rel[25..],
                        })
                    else
                        try std.fs.path.join(ctx.alloc, &.{
                            ctx.paths.root,
                            target_rel,
                        });

                    break :hash target_path;
                } else break :hash install_path;
            };
            defer if (!std.mem.eql(u8, hash_path, install_path)) ctx.alloc.free(hash_path);
            if (visited.contains(path)) continue;
            try visited.put(try ctx.alloc.dupe(u8, path), {});

            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var buf: [8192]u8 = undefined;

            const f = try std.fs.cwd().openFile(hash_path, .{
                .mode = .read_only,
            });
            defer f.close();

            while (true) {
                const bytes = try f.read(&buf);
                if (bytes == 0) break;
                hasher.update(buf[0..bytes]);
            }

            var hash: [32]u8 = undefined;
            hasher.final(&hash);

            const mtree_hash = archive.c.archive_entry_digest(
                entry,
                archive.c.ARCHIVE_ENTRY_DIGEST_SHA256,
            )[0..32];
            if (!std.mem.eql(u8, mtree_hash, &hash)) return error.CorruptDownload;
        } else if (path_type == archive.c.S_IFLNK) {
            const expect: []const u8 = std.mem.span(archive.c.archive_entry_symlink(entry));

            var buf: [std.fs.max_path_bytes]u8 = undefined;

            const on_disk = try std.fs.cwd().readLink(install_path, &buf);

            if (!std.mem.eql(u8, expect, on_disk)) return error.CorruptDownload;
        }
    }
}

pub fn uninstall(
    ctx: *Context,
    pkgname: []const u8,
    repo: []const u8,
) !void {
    const pkgid = try ctx.db.db.oneAlloc(
        i64,
        ctx.alloc,
        "SELECT id FROM installed WHERE name = ? AND repo = ?",
        .{},
        .{ pkgname, repo },
    );

    if (pkgid == null) return error.FailedToGetPackageId;

    var stmt = try ctx.db.db.prepare("SELECT path FROM files WHERE pkgid = ?");
    defer stmt.deinit();

    var iter = try stmt.iterator([]const u8, .{pkgid});
    while (try iter.nextAlloc(ctx.alloc, .{})) |path| {
        defer ctx.alloc.free(path);
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    try ctx.db.db.exec(
        \\DELETE FROM installed WHERE id = ?
    , .{}, .{pkgid.?});
}
