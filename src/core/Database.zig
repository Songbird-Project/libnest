const std = @import("std");
const sqlite = @import("sqlite");

const Context = @import("../core/Context.zig");
const Downloader = @import("../net/Downloader.zig");
const Pkg = @import("Package.zig");

const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");

pub const DBConfig = struct {
    insert_sync_stmt: sqlite.DynamicStatement,
    insert_installed_stmt: sqlite.DynamicStatement,

    pub fn init(
        db: *sqlite.Db,
    ) !DBConfig {
        errdefer std.debug.print("{f}\n", .{db.getDetailedError()});

        const sync_stmt = try db.prepareDynamic(
            \\INSERT INTO sync (name, repo, version, metadata)
            \\VALUES (?, ?, ?, jsonb(?))
            \\ON CONFLICT(name, repo) DO UPDATE SET
            \\metadata = excluded.metadata
            \\WHERE metadata != excluded.metadata
        );
        const installed_stmt = try db.prepareDynamic(
            \\INSERT INTO installed (name, repo, version, explicit, metadata)
            \\VALUES (?, ?, ?, ?, jsonb(?))
            \\ON CONFLICT(name, repo) DO UPDATE SET
            \\metadata = excluded.metadata
            \\WHERE metadata != excluded.metadata
        );

        return .{
            .insert_sync_stmt = sync_stmt,
            .insert_installed_stmt = installed_stmt,
        };
    }

    pub fn deinit(self: *DBConfig) void {
        self.insert_sync_stmt.deinit();
        self.insert_installed_stmt.deinit();
    }
};

const DbError = error{
    RelativePathInPkg,
    RelativePathInMTREE,
    CorruptDatabase,
    InvalidDatabase,
};

const Db = @This();

alloc: std.mem.Allocator,
db: *sqlite.Db,
config: *DBConfig,

pub fn init(
    alloc: std.mem.Allocator,
    db_path: []const u8,
) !Db {
    const dbpath = try std.fs.path.joinZ(alloc, &.{
        db_path,
        "pkgs.db",
    });
    defer alloc.free(dbpath);
    const db = try alloc.create(sqlite.Db);
    db.* = try sqlite.Db.init(.{
        .mode = .{ .File = dbpath },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    errdefer alloc.destroy(db);

    _ = try db.pragma(void, .{}, "foreign_keys", "ON");
    _ = try db.pragma(void, .{}, "journal_mode", "WAL");
    _ = try db.pragma(void, .{}, "cache_size", "-200000");

    try db.execMulti(
        \\CREATE TABLE IF NOT EXISTS sync(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  repo TEXT NOT NULL,
        \\  version TEXT NOT NULL,
        \\  metadata JSONB,
        \\  UNIQUE(name,repo)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS files(
        \\  pkgid INTEGER NOT NULL,
        \\  path TEXT,
        \\  FOREIGN KEY(pkgid) REFERENCES installed(id) ON DELETE CASCADE
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS installed(
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  repo TEXT NOT NULL,
        \\  version TEXT NOT NULL,
        \\  explicit BOOL,
        \\  metadata JSONB,
        \\  UNIQUE(name,repo)
        \\);
    , .{});

    var config = try DBConfig.init(db);

    return .{
        .alloc = alloc,
        .db = db,
        .config = &config,
    };
}

pub fn deinit(self: *Db) void {
    self.db.deinit();
    self.alloc.destroy(self.db);
    self.config.deinit();
}

pub fn querySync(
    self: *Db,
    name: []const u8,
    repo: ?[]const u8,
) ![]Pkg {
    var stmt = try self.db.prepareDynamic(
        \\SELECT json(metadata) FROM sync
        \\WHERE (
        \\  (name LIKE ? OR name = ?)
        \\  OR EXISTS (
        \\      SELECT 1 FROM json_each(sync.metadata, '$.provides')
        \\      WHERE (value LIKE ? OR value = ?)
        \\      )
        \\  )
        \\AND (? is NULL OR repo = ?)
    );
    defer stmt.deinit();

    var results: std.ArrayList(Pkg) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(self.alloc);
        results.deinit(self.alloc);
    }

    const likename = try std.fmt.allocPrint(
        self.alloc,
        "{s}=%",
        .{name},
    );
    defer self.alloc.free(likename);

    var it = try stmt.iterator(
        struct { metadata: []const u8 },
        .{
            likename,
            name,
            likename,
            name,
            repo,
            repo,
        },
    );

    while (try it.nextAlloc(self.alloc, .{})) |row| {
        const parsed = try std.json.parseFromSlice(
            Pkg,
            self.alloc,
            row.metadata,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();
        try results.append(self.alloc, try parsed.value.clone(self.alloc));
        self.alloc.free(row.metadata);
    }

    if (repo != null and results.items.len > 1) return error.InvalidDatabase;

    return results.toOwnedSlice(self.alloc);
}

pub fn queryInstalled(
    self: *Db,
    name: []const u8,
    repo: ?[]const u8,
) ![]Pkg.Installed {
    var stmt = try self.db.prepareDynamic(
        \\SELECT json(metadata) FROM installed
        \\WHERE (
        \\  (name LIKE ? OR name = ?)
        \\  OR EXISTS (
        \\      SELECT 1 FROM json_each(installed.metadata, '$.provides')
        \\      WHERE (value LIKE ? OR value = ?)
        \\      )
        \\  )
        \\AND (? is NULL OR repo = ?)
    );
    defer stmt.deinit();

    var results: std.ArrayList(Pkg.Installed) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(self.alloc);
        results.deinit(self.alloc);
    }

    const likename = try std.fmt.allocPrint(
        self.alloc,
        "{s}=%",
        .{name},
    );
    defer self.alloc.free(likename);

    var it = try stmt.iterator(
        struct { metadata: []const u8 },
        .{
            likename,
            name,
            likename,
            name,
            repo,
            repo,
        },
    );

    while (try it.nextAlloc(self.alloc, .{})) |row| {
        const parsed = try std.json.parseFromSlice(
            Pkg.Installed,
            self.alloc,
            row.metadata,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();
        try results.append(self.alloc, try parsed.value.clone(self.alloc));
        self.alloc.free(row.metadata);
    }

    if (repo != null and results.items.len > 1) return error.InvalidDatabase;

    return results.toOwnedSlice(self.alloc);
}

pub fn insertFile(
    self: *Db,
    pkgid: i64,
    path: []const u8,
) !void {
    var stmt = try self.db.prepare(
        \\INSERT INTO files (pkgid, path) VALUES (?, ?)
    );
    defer stmt.deinit();

    try stmt.exec(.{}, .{
        pkgid,
        path,
    });
}

pub fn insertSync(
    self: *Db,
    pkg: Pkg,
) !void {
    errdefer std.debug.print("{f}\n", .{self.db.getDetailedError()});

    var writer = std.io.Writer.Allocating.init(self.alloc);
    const w = &writer.writer;
    defer writer.deinit();
    try std.json.Stringify.value(pkg, .{}, w);
    try self.config.insert_sync_stmt.exec(.{}, .{
        pkg.name,
        pkg.repo,
        pkg.version,
        writer.written(),
    });
}

pub fn insertInstalled(
    self: *Db,
    explicit: bool,
    pkg: Pkg.Installed,
) !i64 {
    errdefer std.debug.print("{f}\n", .{self.db.getDetailedError()});

    var writer = std.io.Writer.Allocating.init(self.alloc);
    const w = &writer.writer;
    defer writer.deinit();
    try std.json.Stringify.value(pkg, .{}, w);

    try self.config.insert_installed_stmt.exec(.{}, .{
        pkg.name,
        pkg.repo,
        pkg.version,
        explicit,
        writer.written(),
    });

    self.config.insert_installed_stmt.reset();

    return self.db.getLastInsertRowID();
}

pub fn sync(
    self: *Db,
    ctx: *Context,
    repo: []const u8,
    batch_size: usize,
) !void {
    var stmt = try self.db.prepare(
        \\INSERT INTO packages (name, repo, version, metadata)
        \\VALUES (?, ?, ?, jsonb(?))
        \\ON CONFLICT(name, repo) DO UPDATE SET
        \\metadata = excluded.metadata
        \\WHERE metadata != excluded.metadata
        ,
    );
    defer stmt.deinit();

    var in_trans = false;
    var batched: usize = 0;

    var reader = try archive.Reader.init();
    defer reader.deinit();

    const repodb = try std.fmt.allocPrint(
        self.alloc,
        "{s}.db",
        .{repo},
    );
    defer self.alloc.free(repodb);
    const dest = try std.fs.path.join(self.alloc, &.{
        ctx.paths.cache,
        repodb,
    });
    defer self.alloc.free(dest);

    std.fs.cwd().deleteFile(dest) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try ctx.mirrors.downloadDb(
        ctx,
        repo,
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
        const pathrepo: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        const delim = std.mem.lastIndexOfScalar(u8, pathrepo, '/');

        if (delim == null) {
            while (true) {
                const bytes = try reader.readData(&buf);
                if (bytes == 0) break;
            }
            continue;
        }

        const is_desc = std.mem.eql(u8, pathrepo[delim.? + 1 ..], "desc");

        if (!is_desc) continue;

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.alloc);

        while (true) {
            const bytes = try reader.readData(&buf);
            if (bytes <= 0) break;
            try content.appendSlice(self.alloc, buf[0..bytes]);
        }

        if (is_desc) {
            if (batched >= batch_size and in_trans) {
                try self.db.exec("COMMIT", .{}, .{});
                batched = 0;
                in_trans = false;
            }
            if (!in_trans) {
                try self.db.exec("BEGIN IMMEDIATE", .{}, .{});
                in_trans = true;
            }

            try desc.index(
                ctx,
                content.items,
                repo,
                &stmt,
            );
            stmt.reset();

            batched += 1;
        }
    }

    if (in_trans) {
        try self.db.exec("COMMIT", .{}, .{});
        try self.db.exec("VACUUM", .{}, .{});
        batched = 0;
        in_trans = false;
    }
}
