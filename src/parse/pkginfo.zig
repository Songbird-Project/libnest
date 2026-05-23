const std = @import("std");
const mem = @import("../utils/mem.zig");

const Pkg = @import("../core/Package.zig");
const Context = @import("../core/Context.zig");

pub fn index(
    ctx: *Context,
    repo: []const u8,
    path: []const u8,
    explicit: bool,
) !i64 {
    const pkg = try parse(
        ctx.alloc,
        repo,
        path,
    );
    defer pkg.deinit(ctx.alloc);

    return try ctx.db.insertInstalled(
        explicit,
        pkg,
    );
}

pub fn parse(alloc: std.mem.Allocator, repo: []const u8, path: []const u8) !Pkg.Installed {
    const pkginfo = try std.fs.cwd().readFileAlloc(
        alloc,
        path,
        1024 * 1024,
    );
    defer alloc.free(pkginfo);

    var fields: std.StringHashMap([][]const u8) = .init(alloc);
    defer {
        var it = fields.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        fields.deinit();
    }

    var lines = std.mem.splitScalar(u8, pkginfo, '\n');
    var current_values: std.ArrayList([]const u8) = .empty;
    defer current_values.deinit(alloc);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eql| {
            const key = std.mem.trim(
                u8,
                trimmed[0..eql],
                " \t\r",
            );
            const val = std.mem.trim(
                u8,
                trimmed[eql + 1 ..],
                " \t\r",
            );

            var parts = std.mem.splitScalar(u8, val, ',');
            while (parts.next()) |p| {
                try current_values.append(alloc, std.mem.trim(
                    u8,
                    p,
                    " \t\r",
                ));
            }

            if (fields.getPtr(key)) |existing_values| {
                const old_slice = existing_values.*;
                const new_slice = try alloc.alloc(
                    []const u8,
                    old_slice.len + current_values.items.len,
                );

                @memcpy(new_slice[0..old_slice.len], old_slice);
                @memcpy(new_slice[old_slice.len..], current_values.items);

                alloc.free(old_slice);
                existing_values.* = new_slice;
                current_values.clearRetainingCapacity();
            } else {
                try fields.put(
                    try alloc.dupe(u8, key),
                    try current_values.toOwnedSlice(alloc),
                );
            }
        }
    }

    const get = struct {
        fn f(m: anytype, k: []const u8) []const u8 {
            return if (m.get(k)) |v| (if (v.len > 0) v[0] else "") else "";
        }
    }.f;

    var pkg = Pkg.Installed{};
    errdefer pkg.deinit(alloc);

    pkg.name = try alloc.dupe(u8, get(fields, "pkgname"));
    pkg.repo = try alloc.dupe(u8, repo);
    pkg.version = try alloc.dupe(u8, get(fields, "pkgver"));
    pkg.description = try alloc.dupe(u8, get(fields, "pkgdesc"));
    pkg.url = try alloc.dupe(u8, get(fields, "url"));
    pkg.arch = try alloc.dupe(u8, get(fields, "arch"));
    pkg.packager = try alloc.dupe(u8, get(fields, "packager"));
    pkg.build_date = try std.fmt.parseInt(
        i64,
        get(fields, "builddate"),
        10,
    );
    pkg.size = try std.fmt.parseInt(i64, get(fields, "size"), 10);
    pkg.license = try mem.dupeSlice(
        []const u8,
        alloc,
        fields.get("license") orelse &.{},
    );
    pkg.conflicts = try mem.dupeSlice(
        []const u8,
        alloc,
        fields.get("conflicts") orelse &.{},
    );
    pkg.provides = try mem.dupeSlice(
        []const u8,
        alloc,
        fields.get("provides") orelse &.{},
    );
    pkg.deps = try mem.dupeSlice(
        []const u8,
        alloc,
        fields.get("depend") orelse &.{},
    );
    pkg.mkdeps = try mem.dupeSlice(
        []const u8,
        alloc,
        fields.get("makedepend") orelse &.{},
    );
    pkg.optdeps = try mem.dupeSlice(
        []const u8,
        alloc,
        fields.get("optdepend") orelse &.{},
    );
    pkg.checkdeps = try mem.dupeSlice(
        []const u8,
        alloc,
        fields.get("checkdepend") orelse &.{},
    );

    return pkg;
}
