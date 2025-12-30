const std = @import("std");
const testing = std.testing;
const handle = @import("handle.zig");
const curl = @import("curl");

test "handle memory" {
    const alloc = std.testing.allocator;

    var hndl = try handle.newHandle(alloc);
    defer handle.freeHandle(alloc, &hndl);
    _ = try handle.lock(&hndl);
    _ = try handle.unlock(alloc, &hndl);
}
