const std = @import("std");
const Pkg = @import("../core/Package.zig");
const Context = @import("../core/Context.zig");

pub const Field = enum {
    none,
    name,
    version,
    desc,
    builddate,
    arch,
    license,
    filename,
    packager,
    checksum,
    signature,
    replaces,
    conflicts,
    provides,
    depends,
    makedeps,
    optdeps,
    checkdeps,

    pub fn parse(name: []const u8) Field {
        if (std.mem.eql(u8, name, "NAME")) return .name;
        if (std.mem.eql(u8, name, "VERSION")) return .version;
        if (std.mem.eql(u8, name, "DESC")) return .desc;
        if (std.mem.eql(u8, name, "BUILDDATE")) return .builddate;
        if (std.mem.eql(u8, name, "ARCH")) return .arch;
        if (std.mem.eql(u8, name, "LICENSE")) return .license;
        if (std.mem.eql(u8, name, "FILENAME")) return .filename;
        if (std.mem.eql(u8, name, "PACKAGER")) return .packager;
        if (std.mem.eql(u8, name, "SHA256SUM")) return .checksum;
        if (std.mem.eql(u8, name, "PGPSIG")) return .signature;
        if (std.mem.eql(u8, name, "REPLACES")) return .replaces;
        if (std.mem.eql(u8, name, "CONFLICTS")) return .conflicts;
        if (std.mem.eql(u8, name, "PROVIDES")) return .provides;
        if (std.mem.eql(u8, name, "DEPENDS")) return .depends;
        if (std.mem.eql(u8, name, "MAKEDEPENDS")) return .makedeps;
        if (std.mem.eql(u8, name, "OPTDEPENDS")) return .optdeps;
        if (std.mem.eql(u8, name, "CHECKDEPENDS")) return .checkdeps;

        return .none;
    }
};

pub fn index(
    ctx: *Context,
    desc: []const u8,
    repo: []const u8,
    hash: []const u8,
) !void {
    const pkg = try parse(
        ctx.alloc,
        repo,
        desc,
    );
    defer pkg.deinit(ctx.alloc);

    try ctx.db.insertSync(hash, pkg);
}

pub fn parse(alloc: std.mem.Allocator, repo: []const u8, src: []const u8) !Pkg {
    var pkg = Pkg{
        .name = &.{},
        .repo = try alloc.dupe(u8, repo),
        .version = &.{},
        .description = &.{},
        .build_date = 0,
        .arch = &.{},
        .license = &.{},
        .filename = &.{},
        .packager = &.{},
        .checksum = &.{},
        .signature = &.{},
        .replaces = &.{},
        .conflicts = &.{},
        .provides = &.{},
        .deps = &.{},
        .mkdeps = &.{},
        .optdeps = &.{},
        .checkdeps = &.{},
    };

    var licenses: std.ArrayListUnmanaged([]const u8) = .empty;
    var replaces: std.ArrayListUnmanaged([]const u8) = .empty;
    var conflicts: std.ArrayListUnmanaged([]const u8) = .empty;
    var provides: std.ArrayListUnmanaged([]const u8) = .empty;
    var deps: std.ArrayListUnmanaged([]const u8) = .empty;
    var mkdeps: std.ArrayListUnmanaged([]const u8) = .empty;
    var optdeps: std.ArrayListUnmanaged([]const u8) = .empty;
    var checkdeps: std.ArrayListUnmanaged([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, src, '\n');

    errdefer {
        licenses.deinit(alloc);
        replaces.deinit(alloc);
        conflicts.deinit(alloc);
        provides.deinit(alloc);
        deps.deinit(alloc);
        mkdeps.deinit(alloc);
        optdeps.deinit(alloc);
        checkdeps.deinit(alloc);

        pkg.deinit(alloc);
    }

    var field: Field = .none;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(
            u8,
            line,
            " \r\t",
        );
        if (trimmed.len == 0) continue;

        if (trimmed.len > 2 and trimmed[0] == '%' and trimmed[trimmed.len - 1] == '%') {
            field = Field.parse(trimmed[1 .. trimmed.len - 1]);
            continue;
        }

        switch (field) {
            .name => pkg.name = try alloc.dupe(u8, trimmed),
            .version => pkg.version = try alloc.dupe(u8, trimmed),
            .desc => pkg.description = try alloc.dupe(u8, trimmed),

            .builddate => {
                pkg.build_date = try std.fmt.parseInt(
                    i64,
                    trimmed,
                    10,
                );
            },

            .arch => pkg.arch = try alloc.dupe(u8, trimmed),
            .filename => pkg.filename = try alloc.dupe(u8, trimmed),
            .packager => pkg.packager = try alloc.dupe(u8, trimmed),
            .checksum => pkg.checksum = try alloc.dupe(u8, trimmed),
            .signature => pkg.signature = try alloc.dupe(u8, trimmed),

            .license => try licenses.append(
                alloc,
                try alloc.dupe(u8, trimmed),
            ),
            .replaces => try replaces.append(
                alloc,
                try alloc.dupe(u8, trimmed),
            ),
            .conflicts => try conflicts.append(
                alloc,
                try alloc.dupe(u8, trimmed),
            ),
            .provides => try provides.append(
                alloc,
                try alloc.dupe(u8, trimmed),
            ),
            .depends => try deps.append(
                alloc,
                try alloc.dupe(u8, trimmed),
            ),
            .makedeps => try mkdeps.append(
                alloc,
                try alloc.dupe(u8, trimmed),
            ),
            .optdeps => try optdeps.append(
                alloc,
                try alloc.dupe(u8, trimmed),
            ),
            .checkdeps => try checkdeps.append(
                alloc,
                try alloc.dupe(u8, trimmed),
            ),

            .none => {},
        }
    }

    pkg.license = try licenses.toOwnedSlice(alloc);
    pkg.replaces = try replaces.toOwnedSlice(alloc);
    pkg.conflicts = try conflicts.toOwnedSlice(alloc);
    pkg.provides = try provides.toOwnedSlice(alloc);
    pkg.deps = try deps.toOwnedSlice(alloc);
    pkg.mkdeps = try mkdeps.toOwnedSlice(alloc);
    pkg.optdeps = try optdeps.toOwnedSlice(alloc);
    pkg.checkdeps = try checkdeps.toOwnedSlice(alloc);

    return pkg;
}
