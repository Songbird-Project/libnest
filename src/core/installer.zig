const std = @import("std");
const archive = @import("../utils/archive.zig");
const pkginfo = @import("../parse/pkginfo.zig");

const Db = @import("Database.zig");
const Context = @import("Context.zig");
const Pkg = @import("Package.zig");

const InstallerError = error{
    FailedToGetPackageId,
    AlreadyInstalled,
    RelativePathInPackage,
};

pub fn install(
    ctx: *Context,
    pkg: Pkg,
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

    const pkgs: []Pkg.Installed = try ctx.db.queryPkg(.Installed, pkg.name);
    defer {
        for (pkgs) |p| {
            p.deinit(ctx.alloc);
        }
        ctx.alloc.free(pkgs);
    }
    const diff_ver = blk: {
        for (pkgs) |p| {
            if (std.mem.eql(u8, p.version, pkg.version)) continue else break :blk true;
        }
        break :blk false;
    };
    if (pkgs.len > 0 and !diff_ver) return error.AlreadyInstalled;

    var reader = try archive.Reader.init();
    defer reader.deinit();

    var writer = try archive.Writer.init();
    defer writer.deinit();

    const cache = try std.fs.path.join(ctx.alloc, &.{
        ctx.prefix,
        "var",
        "cache",
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

    try reader.openFd(file.handle);
    var buf: [8192]u8 = undefined;
    while (try reader.nextEntry()) |entry| {
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        if (std.mem.containsAtLeast(u8, path, 1, ".."))
            return error.RelativePathInPkg;

        const path_type = archive.c.archive_entry_mode(entry) & 0o170000;

        var rel = path;
        if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
        if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

        const install_path = if (path[0] == '.') try std.fs.path.join(ctx.alloc, &.{
            cache,
            rel,
        }) else try std.fs.path.join(ctx.alloc, &.{
            ctx.prefix,
            rel,
        });
        defer ctx.alloc.free(install_path);

        if (path_type == 0o100000) {
            try writer.writeHeader(entry, install_path);
            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes <= 0) break;

                try writer.writeData(buf[0..bytes], bytes);
            }
        }

        try writer.finishEntry();
    }

    const pkginfo_path = try std.fs.path.join(ctx.alloc, &.{
        cache,
        ".PKGINFO",
    });
    defer ctx.alloc.free(pkginfo_path);
    const pkgid = try pkginfo.index(
        ctx,
        pkg.repo,
        pkginfo_path,
        &stmt,
    );
    stmt.reset();

    const mtree_path = try std.fs.path.join(ctx.alloc, &.{
        cache,
        ".MTREE",
    });
    defer ctx.alloc.free(mtree_path);
    try useMTREE(
        ctx,
        pkgid,
        cache,
        mtree_path,
    );
}

pub fn useMTREE(
    ctx: *Context,
    pkgid: i64,
    cache: []const u8,
    mtree_path: []const u8,
) !void {
    var reader = try archive.Reader.init();
    defer reader.deinit();

    const writer = archive.c.archive_write_disk_new() orelse
        return error.UnableToCreateWriter;
    defer _ = archive.c.archive_write_free(writer);

    _ = archive.c.archive_write_disk_set_standard_lookup(writer);
    _ = archive.c.archive_write_disk_set_options(
        writer,
        archive.c.ARCHIVE_EXTRACT_PERM |
            archive.c.ARCHIVE_EXTRACT_TIME |
            archive.c.ARCHIVE_EXTRACT_OWNER |
            archive.c.ARCHIVE_EXTRACT_ACL |
            archive.c.ARCHIVE_EXTRACT_SECURE_NODOTDOT |
            archive.c.ARCHIVE_EXTRACT_SECURE_SYMLINKS |
            archive.c.ARCHIVE_EXTRACT_UNLINK |
            archive.c.ARCHIVE_EXTRACT_FFLAGS,
    );

    const file = std.fs.cwd().openFile(
        mtree_path,
        .{ .mode = .read_only },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    try reader.openFd(file.handle);
    while (try reader.nextEntry()) |entry| {
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));

        if (std.mem.containsAtLeast(u8, path, 1, ".."))
            return error.RelativePathInPkg;

        var rel = path;
        if (std.mem.startsWith(u8, path, "./")) rel = rel[2..];
        if (std.mem.startsWith(u8, path, "/")) rel = rel[1..];

        const install_path = if (path[0] == '.') try std.fs.path.join(ctx.alloc, &.{
            cache,
            rel,
        }) else try std.fs.path.join(ctx.alloc, &.{
            ctx.prefix,
            rel,
        });
        defer ctx.alloc.free(install_path);

        const path_type = archive.c.archive_entry_mode(entry) & 0o170000;

        if (path_type == 0o10000) {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var buf: [8192]u8 = undefined;

            const f = try std.fs.cwd().openFile(install_path, .{
                .mode = .read_only,
            });
            defer f.close();

            while (true) {
                const bytes = try f.read(&buf);
                if (bytes <= 0) break;
                hasher.update(buf[0..bytes]);
            }

            var hash: [32]u8 = undefined;
            hasher.final(&hash);

            const entry_hash: []const u8 = std.mem.span(archive.c.archive_entry_digest(
                entry,
                archive.c.ARCHIVE_ENTRY_DIGEST_SHA256,
            ));
            var mtree_hash: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&mtree_hash, entry_hash);
            if (!std.mem.eql(u8, &mtree_hash, &hash)) return error.CorruptDownload;

            archive.c.archive_entry_set_pathname(entry, install_path.ptr);
            const ret = archive.c.archive_write_header(writer, entry);
            if (ret != archive.c.ARCHIVE_OK) return error.WriteHeaderFailed;
            _ = archive.c.archive_write_finish_entry(writer);

            try ctx.db.insert(pkgid, install_path);
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
        try std.fs.cwd().deleteFile(path);
    }

    try ctx.db.db.exec(
        \\DELETE FROM installed WHERE id = ?
    , .{}, .{pkgid.?});
}
