const std = @import("std");
const Io = std.Io;
const package = @import("../core/package.zig");
const Context = @import("../core/context.zig").Context;
const store = @import("store.zig");
const StoreConn = store.StoreConn;
const profile = @import("profile.zig");

pub fn getId(store_conn: StoreConn, profile_id: i64, gen_num: i64) !i64 {
    const id_row = try store_conn.row(
        "SELECT id FROM generations WHERE profile_id = ?1 AND number = ?2",
        .{ profile_id, gen_num },
    );
    if (id_row) |row| {
        defer row.deinit();
        return row.int(0);
    }

    return error.GenerationNotFound;
}

pub fn getNumber(store_conn: StoreConn, gen_id: i64) !struct { profile: i64, number: i64 } {
    const num_row = try store_conn.row(
        "SELECT profile_id,number FROM generations WHERE id = ?1",
        .{gen_id},
    );
    if (num_row) |row| {
        defer row.deinit();
        return .{ .profile = row.int(0), .number = row.int(1) };
    }

    return error.GenerationNotFound;
}

pub fn new(store_db: StoreConn, profile_id: i64, objects: []const i64) !i64 {
    try store_db.transaction();
    errdefer store_db.rollback();

    const gen_number_row = try store_db.row(
        "SELECT COALESCE(MAX(number), 1) + 1 from generations WHERE profile_id = ?1",
        .{profile_id},
    );
    defer gen_number_row.?.deinit();
    const gen_number = gen_number_row.?.int(0);

    const gen_id_row = try store_db.row(
        \\INSERT INTO generations(profile_id, number, created)
        \\VALUES (?1, ?2, unixepoch()) RETURNING id;
    , .{ profile_id, gen_number });
    defer gen_id_row.?.deinit();
    const gen_id = gen_id_row.?.int(0);

    const entry_stmt = try store_db.prepare("INSERT INTO gen_entries(gen_id, obj_id) VALUES (?1, ?2)");
    for (objects) |obj| {
        try entry_stmt.bind(.{ gen_id, obj });
        try entry_stmt.stepToCompletion();
        try entry_stmt.reset();
    }

    try store_db.commit();
    return gen_id;
}

pub fn build(
    ctx: Context,
    store_conn: StoreConn,
    gen_id: i64,
    providers: []package.Provider,
) !void {
    const gen = try getNumber(store_conn, gen_id);
    const profile_name = try profile.getName(ctx, store_conn, gen.profile);
    defer ctx.alloc.free(profile_name);

    var num_buf: [32]u8 = undefined;
    const str_gen = try std.fmt.bufPrint(&num_buf, "{d}", .{gen.number});
    const gen_dir = try Io.Dir.path.join(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.store,
        "profiles",
        profile_name,
        str_gen,
    });
    defer ctx.alloc.free(gen_dir);
    try Io.Dir.cwd().createDirPath(ctx.io, gen_dir);

    var seen_paths: std.StringHashMap([]const u8) = .init(ctx.alloc);
    defer {
        var it = seen_paths.keyIterator();
        while (it.next()) |path| ctx.alloc.free(path.*);
        seen_paths.deinit();
    }
    for (providers) |provider| {
        const id_row = try store_conn.row("SELECT id FROM packages WHERE name = ?1", .{provider.info.name});
        if (id_row == null) return error.CorruptStore;
        defer id_row.?.deinit();

        var rows = try store_conn.rows(
            "SELECT path,hash,target,mode FROM files WHERE package_id = ?1",
            .{id_row.?.int(0)},
        );
        defer rows.deinit();

        while (rows.next()) |row| {
            var dest = try Io.Dir.path.join(ctx.alloc, &.{ gen_dir, row.cString(0) });
            if (seen_paths.get(dest)) |owner| {
                const dir = Io.Dir.path.dirname(dest).?;
                const base = Io.Dir.path.basename(dest);
                ctx.alloc.free(dest);

                const new_name = try std.fmt.allocPrint(ctx.alloc, "{s}-{s}", .{ owner, base });
                defer ctx.alloc.free(new_name);
                dest = try Io.Dir.path.join(ctx.alloc, &.{ dir, new_name });

                try ctx.log(
                    .Warn,
                    "Conflict detected: '{s}' claimed by '{s}' and '{s}' -- resolved to '{s}'",
                    .{ row.cString(0), owner, provider.info.name, dest },
                );
            }

            try seen_paths.put(dest, provider.info.name);
            try Io.Dir.cwd().createDirPath(ctx.io, Io.Dir.path.dirname(dest).?);

            Io.Dir.cwd().deleteFile(ctx.io, dest) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };

            if (row.get(?[]const u8, 2)) |target| {
                try Io.Dir.cwd().symLink(ctx.io, target, dest, .{});
            } else {
                const str_blob = row.blob(1);
                if (str_blob.len != 32) return error.InvalidHash;
                var hash: [32]u8 = undefined;
                @memcpy(&hash, str_blob);
                const blob_path = try store.objectPath(ctx, hash);
                try Io.Dir.cwd().symLink(ctx.io, blob_path, dest, .{});
            }
        }
    }
}

pub fn activate(ctx: Context, store_conn: StoreConn, gen_id: i64) !void {
    const gen = try getNumber(store_conn, gen_id);
    const profile_name = try profile.getName(ctx, store_conn, gen.profile);
    defer ctx.alloc.free(profile_name);

    var id_buf: [32]u8 = undefined;
    const str_gen = try std.fmt.bufPrint(&id_buf, "{d}", .{gen.number});
    const gen_dir = try Io.Dir.path.join(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.store,
        "profiles",
        profile_name,
        str_gen,
    });
    defer ctx.alloc.free(gen_dir);

    const current = try Io.Dir.path.join(ctx.alloc, &.{
        ctx.path_options.root,
        ctx.path_options.store,
        "profiles",
        profile_name,
        "current",
    });
    defer ctx.alloc.free(current);

    const tmp = try std.fmt.allocPrint(ctx.alloc, "{s}.tmp", .{current});
    defer ctx.alloc.free(tmp);

    Io.Dir.cwd().deleteFile(ctx.io, tmp) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try store_conn.exec("UPDATE profiles SET generation = ?1 WHERE name = ?2", .{ gen_id, profile_name });
    try Io.Dir.cwd().symLink(ctx.io, gen_dir, tmp, .{ .is_directory = true });
    try Io.Dir.cwd().rename(tmp, .cwd(), current, ctx.io);
}

pub fn protect(store_conn: StoreConn, gen_id: i64, protected: bool) !void {
    try store_conn.exec("UPDATE generations SET protected = ?1 WHERE id = ?2", .{
        @intFromBool(protected),
        gen_id,
    });
}
