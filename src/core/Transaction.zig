const std = @import("std");
const installer = @import("installer.zig");

installs: std.ArrayList(installer.PkgInstallInfo) = .empty,
upgrades: std.ArrayList([]const u8) = .empty,
removes: std.ArrayList([]const u8) = .empty,

const Txn = @This();

pub fn update(
    self: *Txn,
    alloc: std.mem.Allocator,
    installs: []installer.PkgInstallInfo,
    upgrades: [][]const u8,
    removes: [][]const u8,
) !void {
    for (installs) |*install| try self.installs.append(
        alloc,
        try install.clone(alloc),
    );

    for (upgrades) |upgrade| try self.upgrades.append(
        alloc,
        try alloc.dupe(u8, upgrade),
    );

    for (removes) |remove| try self.removes.append(
        alloc,
        try alloc.dupe(u8, remove),
    );
}

pub fn deinit(self: *Txn, alloc: std.mem.Allocator) void {
    for (self.installs.items) |*item| item.deinit(alloc);
    for (self.upgrades.items) |item| alloc.free(item);
    for (self.removes.items) |item| alloc.free(item);

    self.installs.deinit(alloc);
    self.upgrades.deinit(alloc);
    self.removes.deinit(alloc);
}
