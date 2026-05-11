const std = @import("std");
const builtin = @import("builtin");
const ini = @import("ini");

const Txn = @import("Transaction.zig");

const When = enum { Pre, Post };
const Operator = enum { Install, Upgrade, Remove };

const Trigger = struct {
    ops: []Operator = &.{},
    type: enum { Path, Pkg } = .Pkg,
    targets: [][]const u8 = &.{},
};

pub const Hook = struct {
    name: []const u8,
    exec: []const u8 = "",
    desc: ?[]const u8 = null,
    triggers: []Trigger = &.{},
    deps: ?[][]const u8 = null,
    when: When = .Pre,
    abort_on_fail: bool = false,
    needs_targets: bool = false,

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !Hook {
        const f = try std.fs.cwd().openFile(path, .{
            .mode = .read_only,
        });
        defer f.close();
        var buf: [4096]u8 = undefined;
        var reader = f.reader(&buf);
        var parser = ini.parse(
            alloc,
            &reader.interface,
            ";#",
        );

        var hook = Hook{
            .name = path,
        };

        var trigger: ?Trigger = null;
        var current_header: enum { Trigger, Action } = .Trigger;

        var triggers: std.ArrayList(Trigger) = .empty;
        defer triggers.deinit(alloc);

        var ops: std.ArrayList(Operator) = .empty;
        defer ops.deinit(alloc);

        var targets: std.ArrayList([]const u8) = .empty;
        defer targets.deinit(alloc);

        var depends: std.ArrayList([]const u8) = .empty;
        defer depends.deinit(alloc);

        while (try parser.next()) |record| {
            switch (record) {
                .section => |header| {
                    if (std.mem.eql(u8, header, "Trigger")) {
                        if (trigger != null) {
                            trigger.?.ops = try ops.toOwnedSlice(alloc);
                            ops.clearRetainingCapacity();
                            try triggers.append(alloc, trigger.?);
                        }
                        current_header = .Trigger;
                        trigger = .{};
                    } else if (std.mem.eql(u8, header, "Trigger")) {
                        current_header = .Action;
                    }
                },
                .property => |kv| {
                    if (current_header == .Trigger) {
                        if (std.mem.eql(u8, kv.key, "Type")) {
                            if (std.mem.eql(u8, kv.value, "Path"))
                                trigger.?.type = .Path
                            else if (std.mem.eql(u8, kv.value, "Package"))
                                trigger.?.type = .Pkg;
                        } else if (std.mem.eql(u8, kv.key, "Operation")) {
                            if (std.mem.eql(u8, kv.value, "Install"))
                                try ops.append(alloc, .Install)
                            else if (std.mem.eql(u8, kv.value, "Upgrade"))
                                try ops.append(alloc, .Upgrade)
                            else if (std.mem.eql(u8, kv.value, "Remove"))
                                try ops.append(alloc, .Remove);
                        } else if (std.mem.eql(u8, kv.key, "Target"))
                            try targets.append(alloc, kv.value);
                    } else if (current_header == .Action) {
                        if (std.mem.eql(u8, kv.key, "Description"))
                            hook.desc = try alloc.dupe(u8, kv.value)
                        else if (std.mem.eql(u8, kv.key, "Depends"))
                            try depends.append(alloc, kv.value)
                        else if (std.mem.eql(u8, kv.key, "Exec"))
                            hook.exec = try alloc.dupe(u8, kv.value)
                        else if (std.mem.eql(u8, kv.key, "When")) {
                            if (std.mem.eql(u8, kv.value, "PreTransaction"))
                                hook.when = .Pre
                            else if (std.mem.eql(u8, kv.value, "PostTransaction"))
                                hook.when = .Post;
                        }
                    }
                },
                .enumeration => |val| {
                    if (current_header == .Action) {
                        if (std.mem.eql(u8, val, "AbortOnFail"))
                            hook.abort_on_fail = true
                        else if (std.mem.eql(u8, val, "NeedsTargets"))
                            hook.needs_targets = true;
                    }
                },
            }
        }

        hook.triggers = try triggers.toOwnedSlice(alloc);
        hook.deps = try depends.toOwnedSlice(alloc);

        return hook;
    }

    pub fn deinit(self: *Hook, alloc: std.mem.Allocator) void {
        for (self.triggers) |trigger| {
            for (trigger.targets) |target| alloc.free(target);
            alloc.free(trigger.ops);
        }

        if (self.deps) |deps| for (deps) |dep| alloc.free(dep);
        if (self.desc) |desc| alloc.free(desc);

        alloc.free(self.name);
        alloc.free(self.exec);
    }

    pub fn tryRun(
        self: *Hook,
        alloc: std.mem.Allocator,
        txn: Txn,
    ) !void {
        var run: bool = false;

        for (self.triggers) |trigger| {
            for (trigger.ops) |op| {
                for (trigger.targets) |target| {
                    switch (trigger.type) {
                        .Pkg => {
                            if (op == .Install) for (txn.installs.items) |info| {
                                if (std.mem.eql(
                                    u8,
                                    info.pkg.name,
                                    target,
                                )) run = true;
                            };
                        },
                        .Path => {
                            if (op == .Install) for (txn.installs.items) |info| {
                                if (std.mem.indexOf(
                                    u8,
                                    info.files,
                                    target,
                                )) run = true;
                            };
                        },
                    }
                }
            }
        }

        var child = std.process.Child.init(&.{
            self.exec,
        }, alloc);

        child.stdin_behavior = .Ignore;
        child.stdout_behavior = if (builtin.is_test) .Ignore else .Inherit;
        child.stderr_behavior = if (builtin.is_test) .Ignore else .Inherit;

        _ = try child.spawnAndWait();
    }
};

pub fn initAll(alloc: std.mem.Allocator, hook_path: []const u8) ![]*Hook {
    var hook_dir = try std.fs.cwd().openDir(hook_path, .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer hook_dir.close();
    var it = hook_dir.iterate();

    var hooks: std.ArrayList(*Hook) = .empty;

    while (try it.nextLinux()) |entry| {
        if (entry.kind == .file and
            std.mem.endsWith(u8, entry.name, ".hook"))
        {
            var hook = try Hook.init(alloc, entry.name);
            try hooks.append(alloc, &hook);
        }
    }

    return hooks.toOwnedSlice(alloc);
}

pub fn deinitAll(alloc: std.mem.Allocator, hooks: []*Hook) void {
    for (hooks) |hook| hook.deinit(alloc);
}

pub fn tryRunAll(
    alloc: std.mem.Allocator,
    txn: Txn,
    hooks: []*Hook,
    when: When,
) !void {
    for (hooks) |hook| if (hook.when == when) hook.run(alloc, txn);
}
