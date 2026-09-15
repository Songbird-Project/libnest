const Context = @import("../core/context.zig").Context;
const zqlite = @import("zqlite");

fn prepare(context: Context, conn: zqlite.Conn, sql: []const u8) !zqlite.Stmt {
    return conn.prepare(sql) catch |err| {
        try context.log(.Error, "Failed to prepare SQL statement: {s}\n", .{conn.lastError()});
        return err;
    };
}

fn bindAndExec(stmt: zqlite.Stmt, values: anytype) !void {
    try stmt.bind(values);
    try stmt.stepToCompletion();
    try stmt.reset();
}
