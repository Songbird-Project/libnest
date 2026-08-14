const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const context = @import("../core/context.zig");
const Ctx = context.Context;
const store = @import("./store.zig");
const archive = @import("../utils/archive.zig");

const METADATA_FILES: std.StaticStringMap(void) = .initComptime(.{
    .{ ".PKGINFO", {} },
    .{ ".MTREE", {} },
    .{ ".INSTALL", {} },
    .{ ".BUILDINFO", {} },
});

pub const EntryKind = enum {
    file,
    link,
    symlink,
    dir,
    skip,
};

pub const IngestResult = struct {
    kind: EntryKind,
    path: []const u8,
    mode: u32 = 0,

    hash: ?[32]u8 = null,
    size: u64 = 0,

    target: ?[]const u8 = null,

    links_to: ?[]const u8 = null,

    pub fn deinit(self: IngestResult, alloc: Allocator) void {
        alloc.free(self.path);
        if (self.target) |t| alloc.free(t);
        if (self.links_to) |l| alloc.free(l);
    }
};

/// `ingestPackage` requires that a valid transaction is already active
pub fn ingestPackage(ctx: Ctx, db: store.StoreConn, reader: *archive.Reader, id: i64) !void {
    var hashes: std.StringHashMap([32]u8) = .init(ctx.alloc);
    defer hashes.deinit();

    while (try reader.nextEntry()) |entry| {
        const result = try ingestEntry(ctx, reader, entry);
        defer result.deinit(ctx.alloc);

        if (result.kind == .skip) continue;

        try db.execNoArgs("SAVEPOINT ingest");
        errdefer db.execNoArgs("ROLLBACK TO ingest") catch {};

        switch (result.kind) {
            .file => {
                try hashes.put(result.path, result.hash.?);
                try db.exec(
                    \\INSERT INTO blobs(hash, size, created)
                    \\VALUES(?1, ?2, unixepoch()) ON CONFLICT DO NOTHING
                , .{ result.hash, result.size });
                try db.exec(
                    \\INSERT INTO files(package_id, path, hash, target, mode)
                    \\VALUES (?,?,?,NULL,?)
                , .{ id, result.path, result.hash, result.mode });
            },
            .link => {
                const hash = hashes.get(result.links_to.?) orelse return error.UnresolvedLink;
                try db.exec(
                    \\INSERT INTO files(package_id, path, hash, target, mode)
                    \\VALUES (?,?,?,NULL,?)
                , .{ id, result.path, hash, result.mode });
            },
            .symlink => {
                try db.exec(
                    \\INSERT INTO files(package_id, path, hash, target, mode)
                    \\VALUES (?,?,NULL,?,?)
                , .{ id, result.path, result.target, result.mode });
            },
            .dir => {},
            else => unreachable,
        }

        try db.execNoArgs("RELEASE ingest");
    }
}

fn ingestEntry(ctx: Ctx, reader: *archive.Reader, entry: *archive.c.archive_entry) !IngestResult {
    const path = try ctx.alloc.dupe(u8, std.mem.span(archive.c.archive_entry_pathname(entry)));

    if (METADATA_FILES.has(Io.Dir.path.basename(path))) return .{
        .path = path,
        .kind = .skip,
    };

    const kind = archive.c.archive_entry_filetype(entry);
    const mode = archive.c.archive_entry_perm(entry);

    switch (kind) {
        archive.c.S_IFDIR => return .{
            .kind = .dir,
            .path = path,
            .mode = mode,
        },
        archive.c.S_IFLNK => return .{
            .kind = .symlink,
            .path = path,
            .mode = mode,
            .target = try ctx.alloc.dupe(
                u8,
                std.mem.span(archive.c.archive_entry_symlink(entry)),
            ),
        },
        archive.c.S_IFREG => {
            if (archive.c.archive_entry_hardlink(entry)) |target_ptr| {
                const target: []const u8 = std.mem.span(target_ptr);
                return .{
                    .kind = .link,
                    .path = path,
                    .mode = mode,
                    .links_to = try ctx.alloc.dupe(u8, target),
                };
            } else return try archive.ingestFile(
                ctx,
                reader,
                path,
                mode,
            );
        },
        else => return error.UnsupportedEntryKind,
    }
}
