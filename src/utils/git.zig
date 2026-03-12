const std = @import("std");
pub const c = @cImport(@cInclude("git2.h"));

pub fn init() isize {
    return @as(isize, c.git_libgit2_init());
}

pub fn deinit() isize {
    return @as(isize, c.git_libgit2_shutdown());
}

pub fn clone(alloc: std.mem.Allocator, git_url: []const u8, dest: []const u8) !?*c.git_repository {
    var clone_opts: c.git_clone_options = undefined;
    _ = c.git_clone_options_init(&clone_opts, c.GIT_CLONE_OPTIONS_VERSION);

    var out: ?*c.git_repository = null;
    const url_c = try alloc.dupeZ(u8, git_url);
    defer alloc.free(url_c);
    const dest_c = try alloc.dupeZ(u8, dest);
    defer alloc.free(dest_c);
    _ = c.git_clone(&out, url_c.ptr, dest_c.ptr, &clone_opts);

    return out;
}

pub fn free_repository(repo: ?*c.git_repository) void {
    c.git_repository_free(repo);
}
