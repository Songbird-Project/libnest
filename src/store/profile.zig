const std = @import("std");
const Io = std.Io;
const Context = @import("../core/context.zig").Context;
const store = @import("store.zig");
const StoreConn = store.StoreConn;

pub fn new(store_db: StoreConn, name: []const u8) !i64 {
    const row = try store_db.row(
        \\INSERT INTO profiles(name) VALUES (?1)
        \\ON CONFLICT(name) DO UPDATE SET name = excluded.name
        \\RETURNING id;
    , .{name});
    defer row.?.deinit();

    return row.?.int(0);
}

pub fn getId(ctx: Context, store_db: StoreConn, name: []const u8) !i64 {
    const row = try store_db.row("SELECT * FROM profiles WHERE name = ?1", .{name});

    if (row) |r| {
        defer r.deinit();
        return r.int(0);
    }

    ctx.log(.Error, "Couldn't find profile: '{s}'", .{name});
    return error.ProfileNotFound;
}

pub fn getName(ctx: Context, store_db: StoreConn, id: i64) ![]const u8 {
    const row = try store_db.row("SELECT * FROM profiles WHERE id = ?1", .{id});

    if (row) |r| {
        defer r.deinit();
        return try ctx.alloc.dupe(u8, r.cString(1));
    }

    ctx.log(.Error, "Couldn't find profile with id: '{d}'", .{id});
    return error.ProfileNotFound;
}
