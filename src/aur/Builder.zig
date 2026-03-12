const std = @import("std");

const Pkg = @import("./Package.zig");
const git = @import("../utils/git.zig");

const Builder = @This();

alloc: std.mem.Allocator,

pub fn init(alloc: std.mem.Allocator) !Builder {
    return .{
        .alloc = alloc,
    };
}

pub fn deinit(self: *Builder) void {
    _ = self;
}

pub fn build(self: *Builder, prefix: []const u8, pkg: Pkg.Basic) !void {
    const cache = try std.fs.path.join(self.alloc, &.{
        prefix orelse "/",
        "var",
        "cache",
        pkg.ID,
    });
    defer self.alloc.free(cache);

    _ = git.init();
    defer _ = git.deinit();

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
    defer git.free_repository(repo);
}
