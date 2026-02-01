const std = @import("std");

pub const Db = @import("core/Database.zig");
pub const Pkg = @import("core/Package.zig");

pub const net = struct {
    pub const Downloader = @import("net/Downloader.zig");
    pub const MirrorList = @import("net/MirrorList.zig");
};

pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};
