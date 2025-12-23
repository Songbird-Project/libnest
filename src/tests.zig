const std = @import("std");
const testing = std.testing;
const handle = @import("handle.zig");
const curl = @import("curl");

test "handle memory" {
    const alloc = std.testing.allocator;

    const hndl = try handle.nestHandleNew(alloc);
    handle.nestHandleFree(alloc, hndl);
}
