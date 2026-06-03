const std = @import("std");

pub const version = @import("core/version.zig");
pub const installer = @import("core/installer.zig");
pub const remover = @import("core/remover.zig");
pub const upgrader = @import("core/upgrader.zig");
pub const resolver = @import("core/resolver.zig");
pub const hooks = @import("core/hooks.zig");

pub const Context = @import("core/Context.zig");
pub const Db = @import("core/Database.zig");
pub const Dependency = @import("core/Dependency.zig");
pub const Pkg = @import("core/Package.zig");
pub const Txn = @import("core/Transaction.zig");

pub const net = struct {
    pub const Downloader = @import("net/Downloader.zig");
    pub const MirrorList = @import("net/MirrorList.zig");
};

pub const AUR = struct {
    pub const Builder = @import("aur/Builder.zig");
    pub const Client = @import("aur/Client.zig");
    pub const Pkg = @import("aur/Package.zig");
};

pub const Internal = struct {
    pub const Parse = struct {
        pub const desc = @import("parse/desc.zig");
        pub const pkginfo = @import("parse/pkginfo.zig");
        pub const pkgbuild = @import("parse/pkgbuild.zig");
    };

    pub const git = @import("utils/git.zig");
    pub const archive = @import("utils/archive.zig");
    pub const mem = @import("utils/mem.zig");
};

pub const libnest_version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};
