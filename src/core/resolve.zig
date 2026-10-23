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
    formatters: []struct { key: []const u8, value: []const u8 },
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

        var matched = false;
        inline for (format_opts.formatters) |formatter| {
            if (std.mem.startsWith(u8, remaining, "$" ++ formatter.key)) {
                try writer.print("{s}", .{formatter.value});
                remaining = remaining[1 + formatter.key.len ..];
                matched = true;
            }
        }

        if (!matched) {
            try writer.writeByte('$');
            remaining = remaining[1..];
        }
    }

    try writer.print("{s}/{s}", .{ remaining, filename });

    return try if (format_opts.sentinel) |s| resolved.toOwnedSliceSentinel(s) else resolved.toOwnedSlice();
}

pub fn packageFilename(ctx: Context, pkg: package.PackageInfo) ![]const u8 {
    const ver = try if (pkg.epoch != 0)
        std.fmt.allocPrint(ctx.alloc, "{d}:{s}", .{ pkg.epoch, pkg.version })
    else
        std.fmt.allocPrint(ctx.alloc, "{s}", .{pkg.version});
    defer ctx.alloc.free(ver);

    const full_ver = try if (pkg.release) |rel|
        std.fmt.allocPrint(ctx.alloc, "{s}-{s}", .{ ver, rel })
    else
        std.fmt.allocPrint(ctx.alloc, "{s}", .{ver});
    defer ctx.alloc.free(full_ver);

    return std.fmt.allocPrint(ctx.alloc, "{s}-{s}-{s}.pkg.tar.zst", .{
        pkg.name,
        full_ver,
        pkg.arch,
    });
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

pub const PackageResolver = struct {
    context: Context,
    registry: RepoDatabaseRegistry,
    seen: std.AutoHashMap(i64, []const u8),
    selected: std.StringHashMap(i64),

    const WorkItem = struct {
        name: []const u8,
        explicit: bool = false,
        parent: ?[]const u8 = null,
        constraint: ?[]const u8 = null,
    };

    pub const ProviderCandidate = struct {
        name: []const u8,
        repo: []const u8,
        id: i64,

        fn fromProvider(alloc: Allocator, items: []const PackageResolver.Provider) ![]ProviderCandidate {
            var out = try alloc.alloc(ProviderCandidate, items.len);
            for (items, 0..) |p, idx| out[idx] = .{
                .name = try alloc.dupe(u8, p.name),
                .repo = p.db.repo.name,
                .id = p.id,
            };
            return out;
        }

        pub fn deinit(self: *ProviderCandidate, alloc: Allocator) void {
            alloc.free(self.name);
        }
    };

    pub const ProviderResult = union(enum) {
        found: package.Provider,
        ambiguous: struct { name: []const u8, parent: ?[]const u8, candidates: []ProviderCandidate },
        unsatisfied: struct { name: []const u8, parent: ?[]const u8, constraint: ?[]const u8 },
    };

    const ResolveResult = union(enum) {
        ok: []package.Provider,
        ambiguous: @FieldType(ProviderResult, "ambiguous"),
        unsatisfied: @FieldType(ProviderResult, "unsatisfied"),
    };

    const Provider = struct {
        db: *RepoDatabase,
        name: []const u8,
        id: i64,
        version: ?[]const u8 = null,
    };

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

    pub fn checkProvider(
        self: *PackageResolver,
        provider: PackageResolver.Provider,
        constraint: ?[]const u8,
        explicit: bool,
    ) !package.Provider {
        const alloc = self.context.alloc;
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
            .release = if (row.nullableCString(6)) |rel| try alloc.dupe(u8, rel) else null,
            .explicit = explicit,
        };
        errdefer pkg.deinit(alloc);

        if (constraint) |c| {
            const local = if (provider.version) |pv|
                stripOperator(pv)
            else
                try version.formatEvr(alloc, pkg.epoch, pkg.version, pkg.release);
            defer if (provider.version == null) alloc.free(local);

            if (!try satisfiesConstraint(local, c)) {
                pkg.deinit(alloc);
                return error.ConstraintFailed;
            }
        }

        pkg.deps = try getDepends(self.context, conn, id);
        pkg.provides = try getConstrainedRelation(self.context, conn, "provides", id);
        pkg.conflicts = try getConstrainedRelation(self.context, conn, "conflicts", id);
        pkg.replaces = try getConstrainedRelation(self.context, conn, "replaces", id);
        pkg.licenses = try getNames(self.context, conn, "licenses", id);

        return .{ .info = pkg, .db = provider.db, .id = id };
    }

    fn tryCandidates(
        self: *PackageResolver,
        candidates: []PackageResolver.Provider,
        name: []const u8,
        explicit: bool,
        constraint: ?[]const u8,
        parent: ?[]const u8,
    ) !ProviderResult {
        const alloc = self.context.alloc;
        for (candidates) |candidate| {
            const found = self.checkProvider(candidate, constraint, explicit) catch |err| switch (err) {
                error.ConstraintFailed => continue,
                else => return err,
            };
            try putSelected(alloc, &self.selected, name, candidate.id);
            try putSelected(alloc, &self.selected, candidate.name, candidate.id);

            var rows = try candidate.db.conn.rows(
                "SELECT name FROM provides WHERE package_id = ?1",
                .{candidate.id},
            );
            defer rows.deinit();
            while (rows.next()) |row| try putSelected(alloc, &self.selected, row.cString(0), candidate.id);

            return .{ .found = found };
        }

        return .{ .unsatisfied = .{ .name = name, .parent = parent, .constraint = constraint } };
    }

    pub fn getProvider(
        self: *PackageResolver,
        name: []const u8,
        explicit: bool,
        parent: ?[]const u8,
        constraint: ?[]const u8,
        worklist: []const WorkItem,
    ) !ProviderResult {
        const alloc = self.context.alloc;

        var providers: std.ArrayList(PackageResolver.Provider) = .empty;
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

        if (providers.items.len == 0) return .{ .unsatisfied = .{
            .name = name,
            .parent = parent,
            .constraint = constraint,
        } };

        std.mem.sort(PackageResolver.Provider, providers.items, {}, struct {
            fn lt(_: void, a: PackageResolver.Provider, b: PackageResolver.Provider) bool {
                return a.db.repo.priority < b.db.repo.priority;
            }
        }.lt);

        var i: usize = 0;
        while (i < providers.items.len) {
            var j = i + 1;
            while (j < providers.items.len) {
                if (std.mem.eql(u8, providers.items[i].name, providers.items[j].name)) {
                    const dead = providers.orderedRemove(j);
                    alloc.free(dead.name);
                    if (dead.version) |v| alloc.free(v);
                } else j += 1;
            }
            i += 1;
        }

        for (providers.items) |p| if (std.mem.eql(u8, p.name, name)) return try self.tryCandidates(
            &.{p},
            name,
            explicit,
            constraint,
            parent,
        );

        var explicits: std.ArrayList(PackageResolver.Provider) = .empty;
        defer explicits.deinit(alloc);
        for (providers.items) |p| {
            const is_explicit = self.selected.contains(p.name) or blk: {
                for (worklist) |item| if (item.explicit and std.mem.eql(u8, item.name, p.name)) break :blk true;
                break :blk false;
            };
            if (is_explicit) try explicits.append(alloc, p);
        }

        if (explicits.items.len > 0) return try self.tryCandidates(explicits.items, name, explicit, constraint, parent);
        if (providers.items.len == 1) return try self.tryCandidates(providers.items, name, explicit, constraint, parent);

        return .{ .ambiguous = .{
            .name = name,
            .parent = parent,
            .candidates = try ProviderCandidate.fromProvider(alloc, providers.items),
        } };
    }

    pub fn resolve(self: *PackageResolver, names: [][]const u8, constraints: ?[]?[]const u8) !ResolveResult {
        const alloc = self.context.alloc;
        const store_conn = try self.context.getStore();

        defer {
            var sel_it = self.selected.keyIterator();
            while (sel_it.next()) |key| alloc.free(key.*);
            self.selected.clearRetainingCapacity();

            var seen_it = self.seen.valueIterator();
            while (seen_it.next()) |val| alloc.free(val.*);
            self.seen.clearRetainingCapacity();
        }

        var worklist: std.ArrayList(WorkItem) = .empty;
        defer worklist.deinit(alloc);

        for (names, 0..) |name, idx| {
            const constraint = if (constraints) |c| c[idx] else null;
            const satisfied = blk: {
                const rows = try store_conn.rows("SELECT epoch, version, release FROM packages WHERE name = ?1", .{name});
                defer rows.deinit();

                var exist = false;
                while (rows.next()) |row| {
                    exist = true;
                    const c = constraint orelse continue;
                    const local = try version.formatEvr(
                        alloc,
                        @intCast(row.int(0)),
                        row.cString(1),
                        row.nullableCString(2),
                    );
                    defer alloc.free(local);

                    if (try satisfiesConstraint(local, c)) break :blk true;
                }

                break :blk constraint == null and exist;
            };
            if (satisfied) continue;

            try worklist.append(alloc, .{ .name = name, .explicit = true, .constraint = constraint });
        }

        var providers: std.ArrayList(package.Provider) = .empty;
        errdefer {
            for (providers.items) |provider| provider.deinit(alloc);
            providers.deinit(alloc);
        }

        var i: usize = 0;
        while (i < worklist.items.len) : (i += 1) {
            const item = worklist.items[i];

            switch (try self.getProvider(
                item.name,
                item.explicit,
                item.parent,
                item.constraint,
                worklist.items,
            )) {
                .ambiguous => |a| {
                    for (providers.items) |p| p.deinit(alloc);
                    providers.clearAndFree(alloc);
                    return .{ .ambiguous = a };
                },
                .unsatisfied => |u| {
                    for (providers.items) |p| p.deinit(alloc);
                    providers.clearAndFree(alloc);
                    return .{ .unsatisfied = u };
                },
                .found => |current| {
                    if (self.seen.get(current.id)) |_| {
                        current.deinit(alloc);
                        continue;
                    }
                    const current_version = try version.formatEvr(
                        alloc,
                        current.info.epoch,
                        current.info.version,
                        current.info.release,
                    );

                    try self.seen.put(current.id, current_version);
                    try providers.append(alloc, current);
                    for (current.info.deps) |dep| {
                        if (dep.kind != .Run) continue;
                        try worklist.append(alloc, .{
                            .name = dep.name,
                            .constraint = dep.constraint,
                            .parent = current.info.name,
                        });
                    }
                },
            }
        }

        return .{ .ok = try providers.toOwnedSlice(alloc) };
    }
};
