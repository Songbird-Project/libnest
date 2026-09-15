const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("../core/context.zig").Context;
const RepoDatabaseRegistry = @import("../core/repo.zig").RepoDatabaseRegistry;
const RepoDatabase = @import("../core/repo.zig").RepoDatabase;
const package = @import("package.zig");
const version = @import("../utils/version.zig");
const zqlite = @import("zqlite");

pub const MirrorFormatterOpts = struct {
    sentinel: ?u8 = null,
    formatters: []struct { key: []const u8, value: anyopaque },
};

pub fn mirrorUrl(
    alloc: Allocator,
    fmt: []const u8,
    filename: []const u8,
    comptime format_opts: MirrorFormatterOpts,
) !if (format_opts.sentinel) |s| [:s]const u8 else []const u8 {
    var resolved: Io.Writer.Allocating = .init(alloc);
    errdefer resolved.deinit();
    const writer = &resolved.writer;

    var remaining = fmt;
    while (std.mem.findScalar(u8, remaining, '$')) |idx| {
        try writer.writeAll(remaining[0..idx]);

        inline for (format_opts.formatters) |formatter| {
            if (std.mem.startsWith(u8, remaining, "$" ++ formatter.key)) {
                try writer.print("{}", .{formatter.value});
                remaining = remaining["$" ++ formatter.key.len ..];
            } else {
                try writer.writeByte('$');
                remaining = remaining[idx + 1 ..];
            }
        }
    }

    try writer.print("{s}/{s}", .{ remaining, filename });

    return try if (format_opts.sentinel) |s| resolved.toOwnedSliceSentinel(s) else resolved.toOwnedSlice();
}

const comps: std.StaticStringMap(u8) = .initComptime(.{
    .{ ">", 0 },
    .{ "<", 1 },
    .{ "=", 2 },
    .{ ">=", 3 },
    .{ "<=", 4 },
});

fn putSelected(
    alloc: Allocator,
    selected: *std.StringHashMap(i64),
    name: []const u8,
    id: i64,
) !void {
    if (selected.contains(name))
        return;

    const key = try alloc.dupe(u8, name);
    errdefer alloc.free(key);

    try selected.put(key, id);
}

fn stripOperator(s: []const u8) []const u8 {
    if (s.len >= 2 and comps.get(s[0..2]) != null) return s[2..];
    if (s.len >= 1 and comps.get(s[0..1]) != null) return s[1..];
    return s;
}

fn formatEVR(alloc: std.mem.Allocator, epoch: u32, ver: []const u8, release: ?[]const u8) ![]u8 {
    return if (release) |r|
        std.fmt.allocPrint(alloc, "{d}:{s}-{s}", .{ epoch, ver, r })
    else
        std.fmt.allocPrint(alloc, "{d}:{s}", .{ epoch, ver });
}

fn satisfiesConstraint(local: []const u8, constraint: []const u8) !bool {
    var comp: u8 = undefined;
    var op_len: u8 = undefined;

    if (constraint.len >= 2) {
        if (comps.get(constraint[0..2])) |c| {
            comp = c;
            op_len = 2;
        } else if (comps.get(constraint[0..1])) |c| {
            comp = c;
            op_len = 1;
        } else return true;
    } else {
        comp = comps.get(constraint[0..1]) orelse return error.InvalidDependencyConstraint;
        op_len = 1;
    }

    const res = version.cmp(local, constraint[op_len..]);
    return switch (comp) {
        0 => res == 1,
        1 => res == -1,
        2 => res == 0,
        3 => res >= 0,
        4 => res <= 0,
        else => unreachable,
    };
}

fn getDepends(context: Context, conn: zqlite.Conn, id: i64) ![]package.Dependency {
    var list: std.ArrayList(package.Dependency) = .empty;
    errdefer {
        for (list.items) |*d| d.deinit(context.alloc);
        list.deinit(context.alloc);
    }

    var rows = try conn.rows(
        "SELECT name, ver_constraint, kind FROM depends WHERE package_id = ?1",
        .{id},
    );
    defer rows.deinit();

    while (rows.next()) |r| {
        try list.append(context.alloc, .{
            .name = try context.alloc.dupe(u8, r.cString(0)),
            .constraint = if (r.nullableCString(1)) |c| try context.alloc.dupe(u8, c) else null,
            .kind = switch (r.int(2)) {
                0 => .Run,
                1 => .Make,
                2 => .Check,
                3 => .Optional,
                else => {
                    try context.log(.Error, "Invalid dependency kind\n", .{});
                    return error.InvalidDependency;
                },
            },
        });
    }

    return try list.toOwnedSlice(context.alloc);
}

fn getConstrainedRelation(
    context: Context,
    conn: zqlite.Conn,
    comptime table: []const u8,
    id: i64,
) ![]package.Constrained {
    var list: std.ArrayList(package.Constrained) = .empty;
    errdefer {
        for (list.items) |*c| c.deinit(context.alloc);
        list.deinit(context.alloc);
    }

    var rows = try conn.rows(
        "SELECT name, ver_constraint FROM " ++ table ++ " WHERE package_id = ?1",
        .{id},
    );
    defer rows.deinit();

    while (rows.next()) |r| {
        try list.append(context.alloc, .{
            .name = try context.alloc.dupe(u8, r.cString(0)),
            .constraint = if (r.nullableCString(1)) |c| try context.alloc.dupe(u8, c) else null,
        });
    }

    return try list.toOwnedSlice(context.alloc);
}

fn getNames(context: Context, conn: zqlite.Conn, comptime table: []const u8, id: i64) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |n| context.alloc.free(n);
        list.deinit(context.alloc);
    }

    var rows = try conn.rows(
        "SELECT name FROM " ++ table ++ " WHERE package_id = ?1",
        .{id},
    );
    defer rows.deinit();

    while (rows.next()) |r| {
        try list.append(context.alloc, try context.alloc.dupe(u8, r.cString(0)));
    }

    return try list.toOwnedSlice(context.alloc);
}

const PackageResolver = struct {
    context: Context,
    registry: RepoDatabaseRegistry,
    seen: std.AutoHashMap(i64, []const u8),
    selected: std.StringHashMap(i64),

    pub fn init(context: Context, registry: RepoDatabaseRegistry) PackageResolver {
        const alloc = context.alloc;

        return .{
            .context = context,
            .registry = registry,
            .seen = .init(alloc),
            .selected = .init(alloc),
        };
    }

    pub fn deinit(self: *PackageResolver) void {
        const alloc = self.context.alloc;

        var seen_it = self.seen.valueIterator();
        while (seen_it.next()) |v| alloc.free(v.*);
        self.seen.deinit();

        var selected_it = self.selected.keyIterator();
        while (selected_it.next()) |k| alloc.free(k.*);
        self.selected.deinit();
    }

    pub fn getProvider(
        self: *PackageResolver,
        name: []const u8,
        explicit: bool,
        provider_constraint: ?[]const u8,
    ) !package.Provider {
        const alloc = self.context.alloc;

        var providers: std.ArrayList(struct {
            db: *RepoDatabase,
            name: []const u8,
            id: i64,
            version: ?[]const u8 = null,
        }) = .empty;
        defer {
            for (providers.items) |item| {
                alloc.free(item.name);
                if (item.version) |ver| alloc.free(ver);
            }
            providers.deinit(alloc);
        }

        for (self.registry.databases) |*db| {
            var rows = try db.conn.rows(
                \\SELECT id, name, NULL AS ver_constraint FROM packages WHERE name = ?1
                \\UNION
                \\SELECT pk.id, pk.name, p.ver_constraint FROM provides p
                \\  JOIN packages pk ON p.package_id = pk.id
                \\WHERE p.name = ?1
            , .{name});
            defer rows.deinit();

            while (rows.next()) |r| {
                try providers.append(alloc, .{
                    .db = db,
                    .name = try alloc.dupe(u8, r.cString(1)),
                    .id = r.int(0),
                    .version = if (r.nullableCString(2)) |v| try alloc.dupe(u8, v) else null,
                });
            }
        }

        if (providers.items.len == 0) {
            try self.context.log(.Error, "No providers found for '{s}'\n", .{name});
            return error.ProviderNotFound;
        }

        const selected_id: ?i64 = if (self.selected.get(name)) |id| blk: {
            for (providers.items) |p| {
                if (p.id == id) break :blk id;
            }
            break :blk null;
        } else null;

        const provider = if (selected_id) |id| blk: {
            for (providers.items) |p| {
                if (p.id == id) break :blk p;
            }
            return error.ProviderNotFound;
        } else blk: {
            const index = if (providers.items.len == 1) 0 else select: {
                try self.context.log(
                    .Info,
                    "There are {d} providers for '{s}', select which one you would like to use:\n",
                    .{ providers.items.len, name },
                );

                for (providers.items, 1..) |pkg, idx| {
                    try self.context.log(.None, "{d:>3}: {s}\n", .{ idx, pkg.name });
                }

                break :select try self.context.select(providers.items.len);
            };

            const chosen = providers.items[index];

            try putSelected(alloc, &self.selected, name, chosen.id);
            try putSelected(alloc, &self.selected, chosen.name, chosen.id);

            var rows = try chosen.db.conn.rows(
                "SELECT name FROM provides WHERE package_id = ?1",
                .{chosen.id},
            );
            defer rows.deinit();
            while (rows.next()) |row| {
                try putSelected(alloc, &self.selected, row.cString(0), chosen.id);
            }

            break :blk chosen;
        };

        var row = (try provider.db.conn.row("SELECT * FROM packages WHERE id = ?1", .{provider.id})).?;
        defer row.deinit();
        const conn = provider.db.conn;

        const id = row.int(0);
        const pkg = try alloc.create(package.PackageInfo);
        errdefer alloc.destroy(pkg);

        const blob = row.blob(3);
        if (blob.len != 32) return error.InvalidHash;
        var hash: [32]u8 = undefined;
        @memcpy(&hash, blob);

        pkg.* = .{
            .name = try alloc.dupe(u8, row.cString(1)),
            .arch = try alloc.dupe(u8, row.cString(2)),
            .checksum = hash,
            .repo = try alloc.dupe(u8, provider.db.repo.name),
            .epoch = @intCast(row.int(4)),
            .version = try alloc.dupe(u8, row.cString(5)),
            .release = if (row.nullableCString(6)) |sum| try alloc.dupe(u8, sum) else null,
            .explicit = explicit,
        };
        errdefer pkg.deinit(alloc);

        if (provider_constraint) |c| {
            const local = if (provider.version) |pv|
                stripOperator(pv)
            else
                try formatEVR(alloc, pkg.epoch, pkg.version, pkg.release);
            defer if (provider.version == null) alloc.free(local);

            if (!try satisfiesConstraint(local, c)) return error.ConflictingDependencies;
        }

        pkg.deps = try getDepends(self.context, conn, id);
        pkg.provides = try getConstrainedRelation(self.context, conn, "provides", id);
        pkg.conflicts = try getConstrainedRelation(self.context, conn, "conflicts", id);
        pkg.replaces = try getConstrainedRelation(self.context, conn, "replaces", id);
        pkg.licenses = try getNames(self.context, conn, "licenses", id);

        return .{ .info = pkg, .db = provider.db, .id = id };
    }

    pub fn resolve(self: *PackageResolver, name: []const u8, constraint: ?[]const u8) ![]package.Provider {
        const alloc = self.context.alloc;

        const WorkItem = struct {
            name: []const u8,
            first: bool = false,
            constraint: ?[]const u8,
        };

        var worklist: std.ArrayList(WorkItem) = .empty;
        defer worklist.deinit(alloc);

        try self.context.log(.Info, "Resolving dependencies for '{s}'...\n", .{name});
        try worklist.append(alloc, .{ .name = name, .first = true, .constraint = constraint });

        var providers: std.ArrayList(package.Provider) = .empty;
        errdefer {
            for (providers.items) |provider| provider.deinit(alloc);
            providers.deinit(alloc);
        }

        var i: usize = 0;
        while (i < worklist.items.len) : (i += 1) {
            const item = worklist.items[i];
            const current = try self.getProvider(item.name, item.first, item.constraint);

            if (self.seen.get(current.id)) |_| {
                current.deinit(alloc);
                continue;
            }

            const current_version = try formatEVR(alloc, current.info.epoch, current.info.version, current.info.release);
            try self.seen.put(current.id, current_version);
            try providers.append(alloc, current);

            for (current.info.deps) |dep| {
                if (dep.kind != .Run) continue;
                try worklist.append(alloc, .{ .name = dep.name, .constraint = dep.constraint });
            }
        }

        return try providers.toOwnedSlice(alloc);
    }

    pub fn resolveAll(self: *PackageResolver, names: [][]const u8, constraints: ?[]?[]const u8) ![]package.Provider {
        const alloc = self.context.alloc;
        const store_conn = try self.context.getStore();

        var providers: std.ArrayList(package.Provider) = .empty;
        errdefer {
            for (providers.items) |provider| provider.deinit(alloc);
            providers.deinit(alloc);
        }

        for (names, 0..) |name, idx| {
            const exists = if (try store_conn.row("SELECT id FROM packages WHERE name = ?1", .{name})) |row| blk: {
                defer row.deinit();
                break :blk true;
            } else false;
            if (exists) continue;

            const constraint = if (constraints) |c| c[idx] else null;
            const resolved = try self.resolve(name, constraint);
            defer alloc.free(resolved);

            try providers.appendSlice(alloc, resolved);
        }

        return try providers.toOwnedSlice(alloc);
    }
};
