const std = @import("std");
const Repo = @import("repo.zig").Repo;
const download = @import("../net/download.zig");
const Context = @import("context.zig").Context;
const zqlite = @import("zqlite");
const archive = @import("../utils/archive.zig");
const desc = @import("../parse/desc.zig");
const package = @import("package.zig");

pub fn syncRepo(ctx: Context, db: zqlite.Conn, repo: Repo) !void {
    var client = try download.CurlClient.init(ctx);
    defer client.deinit(ctx);

    const db_name = try std.fmt.allocPrint(
        ctx.alloc,
        "{s}-{s}.db",
        .{ repo.name, repo.arch },
    );
    defer ctx.alloc.free(db_name);
    const dest = try std.Io.Dir.path.join(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.cache,
        "db",
        db_name,
    });
    defer ctx.alloc.free(dest);

    if (std.Io.Dir.path.dirname(dest)) |dir| {
        try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    }

    for (repo.mirrors) |mirror| {
        const repo_url = try std.mem.replaceOwned(
            u8,
            ctx.alloc,
            mirror,
            "$repo",
            repo.name,
        );
        defer ctx.alloc.free(repo_url);

        const resolved_url = try std.mem.replaceOwned(
            u8,
            ctx.alloc,
            repo_url,
            "$arch",
            repo.arch,
        );
        defer ctx.alloc.free(resolved_url);

        const url = try std.fmt.allocPrint(
            ctx.alloc,
            "{s}/{s}.db",
            .{ resolved_url, repo.name },
        );
        defer ctx.alloc.free(url);

        client.downloadToFile(ctx, url, dest) catch {
            try ctx.log(
                .Error,
                "Failed to download repo file for '{s}' from mirror '{s}'\n",
                .{ repo.name, url },
            );
            continue;
        };
        break;
    }

    var reader = try archive.Reader.init();
    defer reader.deinit();

    const db_file = std.Io.Dir.cwd().openFile(
        ctx.io,
        dest,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.log(
                .Error,
                "Failed to download repo file for '{s}'\n",
                .{repo.name},
            );
            return err;
        },
        else => return err,
    };
    defer db_file.close(ctx.io);

    try reader.openFd(db_file.handle);
    var buf: [8192]u8 = undefined;

    const sync_stmt = db.prepare(
        \\INSERT INTO packages(name, epoch, version, release)
        \\VALUES (?1, ?2, ?3, ?4)
        \\ON CONFLICT(name) DO UPDATE SET
        \\  epoch = excluded.epoch,
        \\  version = excluded.version,
        \\  release = excluded.release
        \\WHERE vercmp(excluded.epoch, excluded.version, excluded.release,
        \\             packages.epoch, packages.version, packages.release) > 0
        \\RETURNING id;
    ) catch |err| {
        try ctx.log(.Error, "Failed to prepare SQL statement: {s}\n", .{db.lastError()});
        return err;
    };

    try db.transaction();

    while (try reader.nextEntry()) |entry| {
        const path: []const u8 = std.mem.span(archive.c.archive_entry_pathname(entry));
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(path), "desc")) continue;

        var contents: std.ArrayList(u8) = .empty;
        defer contents.deinit(ctx.alloc);

        while (true) {
            const read = try reader.readData(&buf);
            if (read <= 0) break;
            try contents.appendSlice(ctx.alloc, buf[0..read]);
        }

        var pkg_info = try desc.parse(
            ctx.alloc,
            repo.name,
            contents.items,
        );
        defer pkg_info.deinit(ctx.alloc);

        if (!std.mem.eql(u8, pkg_info.arch, repo.arch) and
            !std.mem.eql(u8, pkg_info.arch, "any")) continue;

        try db.execNoArgs("SAVEPOINT pkg");
        errdefer db.execNoArgs("ROLLBACK TO pkg") catch {};

        try sync_stmt.bind(.{
            pkg_info.name,
            pkg_info.epoch,
            pkg_info.version,
            pkg_info.release,
        });
        const row = try sync_stmt.step();

        if (row) {
            const id = sync_stmt.int(0);

            try db.exec("DELETE FROM depends WHERE package_id = ?1;", .{id});
            try db.exec("DELETE FROM provides WHERE package_id = ?1;", .{id});
            try db.exec("DELETE FROM conflicts WHERE package_id = ?1;", .{id});
            try db.exec("DELETE FROM replaces WHERE package_id = ?1;", .{id});
            try db.exec("DELETE FROM licenses WHERE package_id = ?1;", .{id});
            for (pkg_info.deps) |dep| {
                try db.exec(
                    \\INSERT INTO depends(package_id, name, kind, ver_constraint) VALUES (?1, ?2, ?3, ?4)
                , .{ id, dep.name, @intFromEnum(dep.kind), dep.constraint });
            }
            for (pkg_info.provides) |provide| {
                try db.exec(
                    \\INSERT INTO provides(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)
                , .{ id, provide.name, provide.constraint });
            }

            for (pkg_info.conflicts) |confs| {
                try db.exec(
                    \\INSERT INTO conflicts(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)
                , .{ id, confs.name, confs.constraint });
            }
            for (pkg_info.replaces) |reps| {
                try db.exec(
                    \\INSERT INTO replaces(package_id, name, ver_constraint) VALUES (?1, ?2, ?3)
                , .{ id, reps.name, reps.constraint });
            }
            for (pkg_info.licenses) |name| {
                try db.exec(
                    \\INSERT INTO licenses(package_id, name) VALUES (?1, ?2)
                , .{ id, name });
            }
        }

        try sync_stmt.reset();
        try db.execNoArgs("RELEASE pkg");
    }
    try db.commit();
}
