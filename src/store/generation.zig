const std = @import("std");
const Io = std.Io;
const package = @import("../core/package.zig");
const Context = @import("../core/context.zig").Context;
const store = @import("store.zig");
const profile = @import("profile.zig");

pub fn getId(context: Context, profile_id: i64, gen_num: i64) !i64 {
    const store_conn = try context.getStore();
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

pub fn getNumber(context: Context, gen_id: i64) !struct { profile: i64, number: i64 } {
    const store_conn = try context.getStore();
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

pub fn getCurrent(context: Context, profile_id: i64) !i64 {
    const store_conn = try context.getStore();
    const gen_row = try store_conn.row(
        "SELECT generation FROM profiles WHERE id = ?1",
        .{profile_id},
    );
    if (gen_row == null) return error.NoGenerations;
    defer gen_row.?.deinit();

    return gen_row.?.int(0);
}

pub fn getLatest(context: Context, profile_id: i64) !i64 {
    const store_conn = try context.getStore();
    const latest_gen_row = try store_conn.row(
        "SELECT COALESCE(MAX(number), -2623) from generations WHERE profile_id = ?1",
        .{profile_id},
    );
    if (latest_gen_row == null) return error.NoGenerations;
    defer latest_gen_row.?.deinit();

    const num = latest_gen_row.?.int(0);
    if (num == -2623) return error.NoGenerations;
    return num;
}

pub fn new(context: Context, profile_id: i64) !i64 {
    const store_db = try context.getStore();

    try store_db.transaction();
    errdefer store_db.rollback();

    const gen_number_row = try store_db.row(
        "SELECT COALESCE(MAX(number), 0) + 1 from generations WHERE profile_id = ?1",
        .{profile_id},
    );
    const gen_number = gen_number_row.?.int(0);
    gen_number_row.?.deinit();

    const gen_id_row = try store_db.row(
        \\INSERT INTO generations(profile_id, number, created)
        \\VALUES (?1, ?2, unixepoch()) RETURNING id;
    , .{ profile_id, gen_number });
    const gen_id = gen_id_row.?.int(0);
    gen_id_row.?.deinit();

    try store_db.commit();
    return gen_id;
}

pub fn build(
    context: Context,
    gen_id: i64,
    providers: []package.Provider,
) !void {
    const store_conn = try context.getStore();

    const gen = try getNumber(context, gen_id);
    const profile_name = try profile.getName(context, gen.profile);
    defer context.alloc.free(profile_name);

    var num_buf: [32]u8 = undefined;
    const str_gen = try std.fmt.bufPrint(&num_buf, "{d}", .{gen.number});
    const gen_dir = try Io.Dir.path.join(context.alloc, &.{
        context.path_options.root,
        context.path_options.store,
        "profiles",
        profile_name,
        str_gen,
    });
    defer context.alloc.free(gen_dir);
    try Io.Dir.cwd().createDirPath(context.io, gen_dir);

    var seen_paths: std.StringHashMap([]const u8) = .init(context.alloc);
    defer {
        var it = seen_paths.keyIterator();
        while (it.next()) |path| context.alloc.free(path.*);
        seen_paths.deinit();
    }

    try store_conn.transaction();
    errdefer store_conn.rollback();

    for (providers) |provider| {
        const id_row = try store_conn.row("SELECT id FROM packages WHERE name = ?1", .{provider.info.name});
        if (id_row == null) return error.CorruptStore;
        const id = id_row.?.int(0);
        id_row.?.deinit();

        try store_conn.exec(
            "INSERT INTO gen_entries(gen_id, package_id) VALUES(?1, ?2)",
            .{ gen_id, id },
        );

        var rows = try store_conn.rows(
            "SELECT path,hash,target,mode FROM files WHERE package_id = ?1",
            .{id},
        );
        defer rows.deinit();

        while (rows.next()) |row| {
            var dest = try Io.Dir.path.join(context.alloc, &.{ gen_dir, row.cString(0) });

            if (seen_paths.get(dest)) |owner| {
                const dir = try context.alloc.dupe(u8, Io.Dir.path.dirname(dest).?);
                defer context.alloc.free(dir);
                const base = try context.alloc.dupe(u8, Io.Dir.path.basename(dest));
                defer context.alloc.free(base);

                const new_name = try std.fmt.allocPrint(context.alloc, "{s}-{s}", .{ owner, base });
                defer context.alloc.free(new_name);

                context.alloc.free(dest);
                dest = try Io.Dir.path.join(context.alloc, &.{ dir, new_name });

                try context.log(
                    .Warn,
                    "Conflict detected: '{s}' claimed by '{s}' and '{s}' -- resolved to '{s}'",
                    .{ row.cString(0), owner, provider.info.name, dest },
                );
            }

            try seen_paths.put(dest, provider.info.name);
            try Io.Dir.cwd().createDirPath(context.io, Io.Dir.path.dirname(dest).?);

            Io.Dir.cwd().deleteFile(context.io, dest) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };

            if (row.nullableCString(2)) |target| {
                try Io.Dir.cwd().symLink(context.io, target, dest, .{});
            } else {
                const str_blob = row.blob(1);
                if (str_blob.len != 32) return error.InvalidHash;
                var hash: [32]u8 = undefined;
                @memcpy(&hash, str_blob);
                const blob_path = try store.objectPath(context, hash);
                try Io.Dir.cwd().symLink(context.io, blob_path, dest, .{});
            }
        }
    }

    try store_conn.commit();
}

pub fn activate(context: Context, gen_id: i64) !void {
    const store_conn = try context.getStore();

    const gen = try getNumber(context, gen_id);
    const profile_name = try profile.getName(context, gen.profile);
    defer context.alloc.free(profile_name);

    var num_buf: [32]u8 = undefined;
    const str_gen = try std.fmt.bufPrint(&num_buf, "{d}", .{gen.number});
    const gen_dir = try Io.Dir.path.join(context.alloc, &.{
        context.path_options.root,
        context.path_options.store,
        "profiles",
        profile_name,
        str_gen,
    });
    defer context.alloc.free(gen_dir);

    const current = try Io.Dir.path.join(context.alloc, &.{
        context.path_options.root,
        context.path_options.store,
        "profiles",
        profile_name,
        "current",
    });
    defer context.alloc.free(current);

    const tmp = try std.fmt.allocPrint(context.alloc, "{s}.tmp", .{current});
    defer context.alloc.free(tmp);

    Io.Dir.cwd().deleteFile(context.io, tmp) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try store_conn.exec("UPDATE profiles SET generation = ?1 WHERE id = ?2", .{ gen.number, gen.profile });
    try Io.Dir.cwd().symLink(context.io, gen_dir, tmp, .{ .is_directory = true });
    try Io.Dir.cwd().rename(tmp, .cwd(), current, context.io);
}

pub fn protect(context: Context, gen_id: i64, protected: bool) !void {
    const store_conn = try context.getStore();

    const gen = try getNumber(context, gen_id);
    const current_gen_row = try store_conn.row("SELECT generation FROM profiles WHERE id = ?1", .{gen.profile});
    defer current_gen_row.?.deinit();

    const profile_name = try profile.getName(context, gen.profile);
    defer context.alloc.free(profile_name);

    if (protected and current_gen_row.?.int(0) == gen.number) {
        try context.log(
            .Warn,
            "Generation {d} in '{s}' is currently active, protection will have no effect until a new generation is activated\n",
            .{ gen.number, profile_name },
        );
    }

    try store_conn.exec("UPDATE generations SET protected = ?1 WHERE id = ?2", .{
        @intFromBool(protected),
        gen_id,
    });
}

pub fn purgeUnsafe(context: Context, gen_id: i64) !void {
    const store_conn = try context.getStore();

    const gen = try getNumber(context, gen_id);
    const profile_name = try profile.getName(context, gen.profile);
    defer context.alloc.free(profile_name);

    try store_conn.exec("DELETE FROM generations WHERE id = ?1", .{gen_id});

    var num_buf: [32]u8 = undefined;
    const str_gen = try std.fmt.bufPrint(&num_buf, "{d}", .{gen.number});
    const gen_dir = try Io.Dir.path.join(context.alloc, &.{
        context.path_options.root,
        context.path_options.store,
        "profiles",
        profile_name,
        str_gen,
    });
    defer context.alloc.free(gen_dir);

    try Io.Dir.cwd().deleteTree(context.io, gen_dir);
}

pub fn purge(context: Context, gen_id: i64) !void {
    const store_conn = try context.getStore();

    const gen = try getNumber(context, gen_id);
    const profile_name = try profile.getName(context, gen.profile);
    defer context.alloc.free(profile_name);

    const current_gen = try getCurrent(context, gen.profile);

    const row = try store_conn.row(
        "SELECT number,protected FROM generations WHERE id = ?1",
        .{gen_id},
    );
    defer row.?.deinit();
    const gen_num = row.int(0);
    const protected = row.int(1) != 0;

    if (protected or gen.number == current_gen or gen.number == current_gen - 1) {
        try context.log(
            .Info,
            "Generation {d} in '{s}' is protected\n",
            .{ gen_num, profile_name },
        );
        return;
    }

    try purgeUnsafe(context, gen_id);
}

/// Purge old generations from the profile
/// Skips the current, previous and any protected generations
pub fn purgeAll(context: Context, profile_id: i64, older_than: u32) !void {
    const store_conn = try context.getStore();

    const current_gen = try getCurrent(context, profile_id);
    const profile_name = try profile.getName(context, profile_id);
    defer context.alloc.free(profile_name);

    var gens = try store_conn.rows(
        "SELECT id,number,protected FROM generations WHERE profile_id = ?1 ORDER BY number DESC",
        .{profile_id},
    );
    defer gens.deinit();

    try store_conn.transaction();
    errdefer store_conn.rollback();

    while (gens.next()) |gen| {
        const gen_id = gen.int(0);
        const gen_num = gen.int(1);
        const protected = gen.int(2) != 0;

        if (protected or gen_num == current_gen or gen_num == current_gen - 1) {
            if (gen_num < older_than) try context.log(
                .Info,
                "Generation {d} in '{s}' is protected, skipping...\n",
                .{ gen_num, profile_name },
            );
            continue;
        }

        if (gen_num <= older_than) continue;

        try purgeUnsafe(context, gen_id);
    }

    try store_conn.commit();
}
