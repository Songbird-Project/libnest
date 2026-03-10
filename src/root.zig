const std = @import("std");

pub const mdb = @import("utils/mdb.zig");
pub const version = @import("core/version.zig");

pub const Db = @import("core/Database.zig");
pub const Dependency = @import("core/Dependency.zig");
pub const Pkg = @import("core/Package.zig");

pub const net = struct {
    pub const Downloader = @import("net/Downloader.zig");
    pub const MirrorList = @import("net/MirrorList.zig");
};

pub const AUR = struct {
    pub const Builder = @import("aur/Builder.zig");
    pub const Client = @import("aur/Client.zig");
    pub const Pkg = @import("aur/Package.zig");
};

pub const libnest_version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};
