const std = @import("std");
const Io = std.Io;
const Context = @import("../core/context.zig").Context;

pub fn new(ctx: Context, name: []const u8) !i64 {
    const row = try ctx.getStore().row(
        \\INSERT INTO profiles(name) VALUES (?1)
        \\ON CONFLICT(name) DO NOTHING
        \\RETURNING id;
    , .{name});
    defer row.?.deinit();

    return row.?.int(0);
}

pub fn getId(ctx: Context, name: []const u8) !i64 {
    const row = try ctx.getStore().row("SELECT * FROM profiles WHERE name = ?1", .{name});

    if (row) |r| {
        defer r.deinit();
        return r.int(0);
    }

    return error.ProfileNotFound;
}

pub fn getName(ctx: Context, id: i64) ![]const u8 {
    const row = try ctx.getStore().row("SELECT * FROM profiles WHERE id = ?1", .{id});

    if (row) |r| {
        defer r.deinit();
        return try ctx.alloc.dupe(u8, r.cString(1));
    }

    return error.ProfileNotFound;
}
