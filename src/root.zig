const std = @import("std");

pub const config = @import("core/config.zig").config;
pub const package = @import("core/package.zig");
pub const sync = @import("core/sync.zig");
pub const context = @import("core/context.zig");
pub const repo = @import("core/repo.zig");

pub const store = @import("store/store.zig");

pub const download = @import("net/download.zig");

pub const Internal = struct {
    pub const Parse = struct {
        pub const desc = @import("parse/desc.zig");
        // pub const pkginfo = @import("parse/pkginfo.zig");
        // pub const pkgbuild = @import("parse/pkgbuild.zig");
    };

    pub const git = @import("utils/git.zig");
    pub const archive = @import("utils/archive.zig");
    pub const mem = @import("utils/mem.zig");
    pub const version = @import("utils/version.zig");
};

pub const libnest_version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};
