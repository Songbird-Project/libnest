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
    explicit: bool,

    pub fn clone(self: *PkgInstallInfo, alloc: std.mem.Allocator) !PkgInstallInfo {
        return .{
            .pkg = try self.pkg.clone(alloc),
            .location = try alloc.dupe(u8, self.location),
            .cache = try alloc.dupe(u8, self.cache),
            .explicit = self.explicit,
        };
    }

    pub fn deinit(self: *PkgInstallInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.location);
        alloc.free(self.cache);

        self.pkg.deinit(alloc);
    }
};

const InstallerError = error{
    FailedToGetTarget,
    AlreadyInstalled,
    RelativePathInPackage,
};

pub fn prepareInstall(
    ctx: *Context,
    pkgs: []Pkg,
) ![]PkgInstallInfo {
    var installs: std.ArrayList(PkgInstallInfo) = .empty;
    errdefer {
        for (installs.items) |*i| i.deinit(ctx.alloc);
        installs.deinit(ctx.alloc);
    }

    for (pkgs, 0..) |pkg, idx| {
        const explicit = if (idx == pkgs.len - 1) true else false;

        const dup = dup: {
            for (ctx.txn.installs.items) |item| {
                if (std.mem.eql(u8, item.pkg.name, pkg.name) and
                    std.mem.eql(u8, item.pkg.version, pkg.version))
                    break :dup true;
            }
            break :dup false;
        };
        if (dup) continue;

        const queried: []Pkg.Installed = try ctx.db.queryInstalled(
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
            for (queried) |p| {
                if (std.mem.eql(
                    u8,
                    p.version,
                    pkg.version,
                )) continue else break :blk true;
            }
            break :blk false;
        };
        if (queried.len > 0 and !diff_ver) {
            return error.AlreadyInstalled;
        }

        var files: std.ArrayList([]const u8) = .empty;
        defer {
            for (files.items) |f| ctx.alloc.free(f);
            files.deinit(ctx.alloc);
        }

        const cache = try std.Io.Dir.path.join(ctx.alloc, &.{
            ctx.paths.cache,
            "pkg",
            if (std.mem.find(u8, pkg.filename, ".pkg.tar.")) |i|
                pkg.filename[0..i]
            else
                pkg.checksum,
        });
        defer ctx.alloc.free(cache);
        try std.Io.Dir.cwd().createDirPath(ctx.io, cache);

        const dest = try std.Io.Dir.path.join(ctx.alloc, &.{
            cache,
            pkg.filename,
        });
        defer ctx.alloc.free(dest);

        try ctx.log(
            .Info,
            "Downloading package files...",
        );

        try ctx.mirrors.downloadPkg(
            ctx,
            pkg,
            dest,
        );

        const file = try std.Io.Dir.cwd().openFile(
            ctx.io,
            dest,
            .{ .mode = .read_only },
        );
        defer file.close(ctx.io);

        var reader = try archive.Reader.init();
        defer reader.deinit();
        try reader.openFd(file.handle);
        while (try reader.nextEntry()) |entry| {
            const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));

            const path_type = archive.c.archive_entry_mode(entry) & archive.c.S_IFMT;

            var rel = path;
            if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
            if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

            const basename = std.Io.Dir.path.basename(rel);
            if (basename.len > 0 and basename[0] == '.') continue;

            const install_path = try std.Io.Dir.path.join(ctx.alloc, &.{
                ctx.paths.root,
                rel,
            });
            defer ctx.alloc.free(install_path);

            if (path_type == archive.c.S_IFREG or path_type == archive.c.S_IFLNK) {
                try files.append(
                    ctx.alloc,
                    try ctx.alloc.dupe(u8, install_path),
                );
            }
        }

        if (try conflicts(ctx, pkg.name, files.items)) return error.Conflict;

        try ctx.txn.updateFiles(ctx.alloc, files.items);

        var info = PkgInstallInfo{
            .pkg = try pkg.clone(ctx.alloc),
            .location = try ctx.alloc.dupe(u8, dest),
            .cache = try ctx.alloc.dupe(u8, cache),
            .explicit = explicit,
        };
        errdefer info.deinit(ctx.alloc);

        try installs.append(ctx.alloc, info);
    }

    return try installs.toOwnedSlice(ctx.alloc);
}

pub fn install(
    ctx: *Context,
) !void {
    for (ctx.txn.installs.items) |info| {
        const msg = try std.fmt.allocPrint(
            ctx.alloc,
            "Installing {s}",
            .{info.pkg.name},
        );
        defer ctx.alloc.free(msg);
        try ctx.log(
            .Info,
            msg,
        );

        var reader = try archive.Reader.init();
        defer reader.deinit();

        var writer = try archive.Writer.init();
        defer writer.deinit();

        const file = try std.Io.Dir.cwd().openFile(
            ctx.io,
            info.location,
            .{ .mode = .read_only },
        );
        defer file.close(ctx.io);

        try reader.openFd(file.handle);
        var buf: [8192]u8 = undefined;
        while (try reader.nextEntry()) |entry| {
            const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
            const path_type = archive.c.archive_entry_mode(entry) & archive.c.S_IFMT;

            var rel = path;
            if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
            if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

            const basename = std.Io.Dir.path.basename(rel);
            const install_path = if (basename.len > 0 and basename[0] == '.')
                try std.Io.Dir.path.join(ctx.alloc, &.{
                    info.cache,
                    rel,
                })
            else if (std.mem.startsWith(
                u8,
                path,
                "/usr/share/libalpm/hooks/",
            ))
                try std.Io.Dir.path.join(ctx.alloc, &.{
                    ctx.paths.hook,
                    rel[25..],
                })
            else
                try std.Io.Dir.path.join(ctx.alloc, &.{
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

        const pkginfo_path = try std.Io.Dir.path.join(ctx.alloc, &.{
            info.cache,
            ".PKGINFO",
        });
        defer ctx.alloc.free(pkginfo_path);
        const pkgid = try pkginfo.index(
            ctx,
            info.pkg.repo,
            pkginfo_path,
            info.explicit,
        );

        const mtree_path = try std.Io.Dir.path.join(ctx.alloc, &.{
            info.cache,
            ".MTREE",
        });
        defer ctx.alloc.free(mtree_path);
        try useMTREE(
            ctx,
            pkgid,
            info.cache,
            mtree_path,
        );
    }
}

pub fn useMTREE(
    ctx: *Context,
    pkgid: i64,
    cache: []const u8,
    mtree_path: []const u8,
) !void {
    var reader = try archive.Reader.init();
    defer reader.deinit();

    const file = std.Io.Dir.cwd().openFile(
        ctx.io,
        mtree_path,
        .{ .mode = .read_only },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(ctx.io);

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

        const basename = std.Io.Dir.path.basename(rel);
        const install_path = if (basename.len > 0 and basename[0] == '.')
            try std.Io.Dir.path.join(ctx.alloc, &.{
                cache,
                rel,
            })
        else if (std.mem.startsWith(u8, path, "/usr/share/libalpm/hooks/"))
            try std.Io.Dir.path.join(ctx.alloc, &.{
                ctx.paths.hook,
                rel[25..],
            })
        else
            try std.Io.Dir.path.join(ctx.alloc, &.{
                ctx.paths.root,
                rel,
            });
        defer ctx.alloc.free(install_path);

        if (path_type == archive.c.S_IFREG) {
            const hash_path = hash: {
                if (archive.c.archive_entry_hardlink(entry)) |lnk| {
                    const target: []const u8 = std.mem.span(lnk);

                    var target_rel = target;
                    if (std.mem.startsWith(u8, target, "./"))
                        target_rel = target_rel[2..];
                    if (std.mem.startsWith(u8, target, "/"))
                        target_rel = target_rel[1..];

                    const rel_basename = std.Io.Dir.path.basename(target_rel);
                    const target_path = if (rel_basename.len > 0 and rel_basename[0] == '.')
                        try std.Io.Dir.path.join(ctx.alloc, &.{
                            cache,
                            target_rel,
                        })
                    else if (std.mem.startsWith(
                        u8,
                        target,
                        "/usr/share/libalpm/hooks/",
                    ))
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
            defer if (!std.mem.eql(
                u8,
                hash_path,
                install_path,
            )) ctx.alloc.free(hash_path);
            if (visited.contains(path)) continue;
            try visited.put(try ctx.alloc.dupe(u8, path), {});

            const hash_file = try std.Io.Dir.cwd().readFileAlloc(
                ctx.io,
                hash_path,
                ctx.alloc,
                .unlimited,
            );
            defer ctx.alloc.free(hash_file);

            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(hash_file);
            var hash: [32]u8 = undefined;
            hasher.final(&hash);

            const mtree_hash = archive.c.archive_entry_digest(
                entry,
                archive.c.ARCHIVE_ENTRY_DIGEST_SHA256,
            )[0..32];
            if (!std.mem.eql(u8, mtree_hash, &hash)) return error.CorruptDownload;
        } else if (path_type == archive.c.S_IFLNK) {
            const expect: []const u8 = std.mem.span(archive.c.archive_entry_symlink(entry));

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

            const bytes = try std.Io.Dir.cwd().readLink(
                ctx.io,
                install_path,
                &buf,
            );

            if (!std.mem.eql(u8, expect, buf[0..bytes])) return error.CorruptDownload;
        }

        try ctx.db.conn.exec(
            "INSERT INTO files (pkgid, path) VALUES (?1, ?2)",
            .{ pkgid, path },
        );
    }
}

pub fn conflicts(ctx: *Context, name: []const u8, files: []const []const u8) !bool {
    const row = try ctx.db.conn.row(
        \\SELECT * FROM installed, json_each(installed.metadata, '$.conflicts')
        \\WHERE value = ?1
    , .{name});
    defer if (row) |r| r.deinit();
    if (row != null) return true;

    for (files) |file| {
        const file_row = try ctx.db.conn.row(
            \\SELECT * FROM files WHERE path=?1
        , .{file});
        defer if (file_row) |r| r.deinit();
        if (file_row != null) return true;
    }

    return false;
}
