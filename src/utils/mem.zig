const std = @import("std");

pub fn dupeSlice(comptime T: type, alloc: std.mem.Allocator, slices: []const T) ![]T {
    comptime {
        const t = @typeInfo(T);
        if (t != .pointer or t.pointer.size != .Slice) {
            @compileError("`T` must be a slice type, found " ++ @typeName(T));
        }
    }

    const Base = std.meta.Elem(T);

    const new_slices = try alloc.alloc(T, slices.len);
    var written: usize = 0;

    errdefer {
        for (new_slices[0..written]) |e| alloc.free(e);
        alloc.free(new_slices);
    }

    for (slices, 0..) |slice, i| {
        new_slices[i] = try alloc.dupe(Base, slice);
        written += 1;
    }
    return new_slices;
}

pub fn freeSlice(alloc: std.mem.Allocator, slices: anytype) void {
    for (slices) |slice| alloc.free(slice);
    alloc.free(slices);
}
