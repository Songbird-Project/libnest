const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const context = @import("../core/context.zig");
const Context = context.Context;
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
pub fn ingestPackage(ctx: Context, reader: *archive.Reader, id: i64) !void {
    const db = ctx.getStore();

    var hashes: std.StringHashMap([32]u8) = .init(ctx.alloc);
    defer {
        var iter = hashes.iterator();
        while (iter.next()) |entry| {
            ctx.alloc.free(entry.key_ptr.*);
        }

        hashes.deinit();
    }

    var pending_links: std.ArrayList(struct { path: []const u8, links_to: []const u8, mode: u32 }) = .empty;
    defer {
        for (pending_links.items) |link| {
            ctx.alloc.free(link.path);
            ctx.alloc.free(link.links_to);
        }
        pending_links.deinit(ctx.alloc);
    }

    while (try reader.nextEntry()) |entry| {
        const result = try ingestEntry(ctx, reader, entry);
        defer result.deinit(ctx.alloc);

        if (result.kind == .skip) continue;

        switch (result.kind) {
            .file => {
                try hashes.put(
                    try ctx.alloc.dupe(u8, result.path),
                    result.hash.?,
                );
                try db.exec(
                    \\INSERT INTO blobs(hash, size, created)
                    \\VALUES(?1, ?2, unixepoch())
                , .{ if (result.hash) |hash| &hash else null, result.size });
                try db.exec(
                    \\INSERT INTO files(package_id, path, hash, target, mode)
                    \\VALUES (?,?,?,NULL,?)
                , .{ id, result.path, if (result.hash) |hash| &hash else null, result.mode });
            },
            .link => {
                try pending_links.append(ctx.alloc, .{
                    .path = try ctx.alloc.dupe(u8, result.path),
                    .links_to = try ctx.alloc.dupe(u8, result.links_to.?),
                    .mode = result.mode,
                });
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
    }

    for (pending_links.items) |link| {
        const hash = hashes.get(link.links_to) orelse {
            try ctx.log(
                .Error,
                "Unresolved hardlink from {s} to {s}\n",
                .{ link.path, link.links_to },
            );
            return error.UnresolvedLink;
        };

        try db.exec(
            \\INSERT INTO files(package_id, path, hash, target, mode)
            \\VALUES (?,?,?,NULL,?)
        , .{ id, link.path, &hash, link.mode });
    }
}

fn ingestEntry(ctx: Context, reader: *archive.Reader, entry: *archive.c.archive_entry) !IngestResult {
    const path = try ctx.alloc.dupe(u8, std.mem.span(archive.c.archive_entry_pathname(entry)));

    if (METADATA_FILES.has(Io.Dir.path.basename(path))) return .{
        .path = path,
        .kind = .skip,
    };

    const kind = archive.c.archive_entry_filetype(entry);
    const mode = archive.c.archive_entry_perm(entry);

    if (archive.c.archive_entry_hardlink(entry)) |target_ptr| {
        const target = std.mem.span(target_ptr);

        return .{
            .kind = .link,
            .path = path,
            .mode = mode,
            .links_to = try ctx.alloc.dupe(u8, target),
        };
    }

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
        archive.c.S_IFREG => return try archive.ingestFile(
            ctx,
            reader,
            path,
            mode,
        ),
        else => {
            try ctx.log(
                .Error,
                "Unsupported archive entry with path={s}, kind=0o{o}, mode=0o{o}\n",
                .{ path, kind, mode },
            );
            return error.UnsupportedEntryKind;
        },
    }
}
