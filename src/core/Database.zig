const std = @import("std");
const sqlite = @import("sqlite");

const Downloader = @import("../net/Downloader.zig");
const MirrorList = @import("../net/MirrorList.zig");

const Db = @This();

alloc: std.mem.Allocator,
sqlite_db: *sqlite.Db,

pub fn init(alloc: std.mem.Allocator, path: [:0]const u8) !Db {
    const sqlite_db = try alloc.create(sqlite.Db);
    sqlite_db.* = try sqlite.Db.init(.{
        .mode = .{ .File = path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });

    try sqlite_db.exec(
        \\CREATE TABLE IF NOT EXISTS packages(
        \\ id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\ name TEXT NOT NULL,
        \\ repo TEXT NOT NULL,
        \\ version TEXT NOT NULL,
        \\ description TEXT,
        \\ arch TEXT,
        \\ license TEXT,
        \\ packager TEXT,
        \\ build_date INTEGER,
        \\ checksum TEXT,
        \\ signature TEXT,
        \\ replaces TEXT,
        \\ conflicts TEXT,
        \\ provides TEXT,
        \\ deps TEXT,
        \\ mkdeps TEXT,
        \\ optdeps TEXT,
        \\ checkdeps TEXT,
        \\ UNIQUE(name, repo)
        \\)
    , .{}, .{});

    return Db{
        .alloc = alloc,
        .sqlite_db = sqlite_db,
    };
}

pub fn deinit(self: *Db) void {
    self.sqlite_db.deinit();
    self.alloc.destroy(self.sqlite_db);
}

pub fn sync(
    self: *Db,
    mirror_path: []const u8,
    dest: []const u8,
    name: []const u8,
    arch: []const u8,
    download_cb: ?*const Downloader.callback,
) !void {
    var mirrors = try MirrorList.init(self.alloc, mirror_path);
    defer mirrors.deinit();
    try mirrors.downloadDb(
        name,
        arch,
        dest,
        download_cb,
    );
}
