const std = @import("std");
const builtin = @import("builtin");

const Pkg = @import("./Package.zig");
const git = @import("../utils/git.zig");

const Builder = @This();

alloc: std.mem.Allocator,
makepkg_path: []const u8,

pub fn init(alloc: std.mem.Allocator, makepkg_path: []const u8) !Builder {
    return .{
        .alloc = alloc,
        .makepkg_path = try alloc.dupe(u8, makepkg_path),
    };
}

pub fn deinit(self: *Builder) void {
    self.alloc.free(self.makepkg_path);
}

pub fn build(self: *Builder, prefix: ?[]const u8, pkg: Pkg.Basic) !void {
    const cache = try std.fs.path.join(self.alloc, &.{
        prefix orelse "/",
        "var",
        "cache",
        pkg.Name,
    });
    defer self.alloc.free(cache);

    _ = git.init();

    const url = try std.fmt.allocPrint(
        self.alloc,
        "https://aur.archlinux.org/{s}.git",
        .{pkg.Name},
    );
    defer self.alloc.free(url);

    const repo = try git.clone(
        self.alloc,
        url,
        cache,
    );

    git.free_repository(repo);
    _ = git.deinit();

    var child = std.process.Child.init(&.{
        self.makepkg_path,
    }, self.alloc);

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = if (builtin.is_test) .Ignore else .Inherit;
    child.stderr_behavior = if (builtin.is_test) .Ignore else .Inherit;
    child.cwd = cache;

    const term = try child.spawnAndWait();

    switch (term) {
        .Exited => |code| {
            switch (code) {
                0 => return,
                13 => return error.AlreadyBuilt,
                else => return error.BuildFailed,
            }
        },
        else => return error.ProcessTerminatedUnexpectedly,
    }
}
