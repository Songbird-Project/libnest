const std = @import("std");
const testing = std.testing;
const Handle = @import("Handle.zig");
const curl = @import("curl");

test "handle memory" {
    const alloc = std.testing.allocator;

    const hndl = try Handle.init(alloc);
    hndl.deinit(alloc);
}
