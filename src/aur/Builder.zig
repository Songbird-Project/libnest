const std = @import("std");
const builtin = @import("builtin");
const sqlite = @import("sqlite");

const archive = @import("../utils/archive.zig");
const pkginfo = @import("../parse/pkginfo.zig");
const git = @import("../utils/git.zig");

const Pkg = @import("./Package.zig");
const Db = @import("../core/Database.zig");
const CorePkg = @import("../core/Package.zig");

const Builder = @This();

alloc: std.mem.Allocator,
makepkg_path: []const u8,

pub fn init(alloc: std.mem.Allocator, makepkg_path: []const u8) !Builder {
    return .{
        .alloc = alloc,
        .makepkg_path = try alloc.dupe(u8, makepkg_path),
    };
}

pub fn deinit(self: *Builder) void {
    self.alloc.free(self.makepkg_path);
}

pub fn build(
    self: *Builder,
    db: *Db,
    prefix: ?[]const u8,
    pkg: Pkg.Basic,
    install_pkg: bool,
) !void {
    const cache = try std.fs.path.join(self.alloc, &.{
        prefix orelse "/",
        "var",
        "cache",
        pkg.Name,
    });
    defer self.alloc.free(cache);

    _ = git.init();

    const url = try std.fmt.allocPrint(
        self.alloc,
        "https://aur.archlinux.org/{s}.git",
        .{pkg.Name},
    );
    defer self.alloc.free(url);

    const repo = try git.clone(
        self.alloc,
        url,
        cache,
    );

    git.free_repository(repo);
    _ = git.deinit();

    var child = std.process.Child.init(&.{
        self.makepkg_path,
    }, self.alloc);

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = if (builtin.is_test) .Ignore else .Inherit;
    child.stderr_behavior = if (builtin.is_test) .Ignore else .Inherit;
    child.cwd = cache;

    const term = try child.spawnAndWait();

    switch (term) {
        .Exited => |code| {
            switch (code) {
                0 => {
                    if (install_pkg) try self.install(db, pkg, cache, prefix);
                },
                13 => return error.AlreadyBuilt,
                else => return error.BuildFailed,
            }
        },
        else => return error.ProcessTerminatedUnexpectedly,
    }
}

pub fn install(
    self: *Builder,
    db: *Db,
    pkg: Pkg.Basic,
    cache: []const u8,
    prefix: ?[]const u8,
) !void {
    var stmt = try db.db.prepare(
        \\INSERT INTO installed (name, repo, metadata)
        \\VALUES (?, ?, jsonb(?))
        \\ON CONFLICT(name, repo) DO UPDATE SET
        \\metadata = excluded.metadata
        \\WHERE metadata != excluded.metadata
        ,
    );
    defer stmt.deinit();

    const diff_ver = blk: {
        const pkgs = try db.queryPkg(CorePkg.Installed, pkg.Name);
        defer {
            for (pkgs) |p| {
                p.deinit();
            }
            self.alloc.free(pkgs);
        }

        if (pkgs.len == 0) break :blk true;
        for (pkgs) |p| {
            if (std.mem.eql(u8, p.value.name, pkg.Name)) {
                if (!std.mem.eql(u8, p.value.version, pkg.Version))
                    break :blk true
                else
                    break :blk false;
            }
        }
        break :blk true;
    };
    if (!diff_ver) return error.AlreadyInstalled;

    var reader = try archive.Reader.init();
    defer reader.deinit();

    var writer = try archive.Writer.init();
    defer writer.deinit();

    const filename = try std.fmt.allocPrint(
        self.alloc,
        "{s}-{s}-x86_64.pkg.tar.zst",
        .{ pkg.Name, pkg.Version },
    );
    defer self.alloc.free(filename);
    const dest = try std.fs.path.join(self.alloc, &.{
        cache,
        pkg.Name,
        filename,
    });
    defer self.alloc.free(dest);

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

        const install_path = if (path[0] == '.') try std.fs.path.join(self.alloc, &.{
            cache,
            rel,
        }) else try std.fs.path.join(self.alloc, &.{
            prefix orelse "/",
            rel,
        });
        defer self.alloc.free(install_path);

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

    const pkginfo_path = try std.fs.path.join(self.alloc, &.{
        cache,
        ".PKGINFO",
    });
    defer self.alloc.free(pkginfo_path);
    const pkgid = try pkginfo.index(
        self.alloc,
        db,
        "aur",
        pkginfo_path,
        &stmt,
    );
    stmt.reset();

    const mtree_path = try std.fs.path.join(self.alloc, &.{
        cache,
        ".MTREE",
    });
    defer self.alloc.free(mtree_path);
    try db.useMTREE(
        pkgid,
        mtree_path,
        prefix,
    );
}
