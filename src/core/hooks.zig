const std = @import("std");
const builtin = @import("builtin");
const ini = @import("ini");

const Txn = @import("Transaction.zig");
const Context = @import("Context.zig");

const When = enum { Pre, Post };
const Operator = enum { Install, Upgrade, Remove };

const HookError = error{
    InvalidHook,
};

const Trigger = struct {
    ops: []Operator = &.{},
    type: enum { Path, Pkg } = .Pkg,
    targets: [][]const u8 = &.{},
};

pub const Hook = struct {
    name: []const u8,
    exec: ?[]const u8 = null,
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
        defer parser.deinit();

        var hook = Hook{
            .name = try alloc.dupe(u8, path),
        };
        errdefer hook.deinit(alloc);

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
                            trigger.?.targets = try targets.toOwnedSlice(alloc);
                            ops.clearRetainingCapacity();
                            targets.clearRetainingCapacity();

                            try triggers.append(alloc, trigger.?);
                        }
                        current_header = .Trigger;
                        trigger = .{};
                    } else if (std.mem.eql(u8, header, "Action")) {
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
                            try targets.append(alloc, try alloc.dupe(u8, kv.value));
                    } else if (current_header == .Action) {
                        if (std.mem.eql(u8, kv.key, "Description"))
                            hook.desc = try alloc.dupe(u8, kv.value)
                        else if (std.mem.eql(u8, kv.key, "Depends"))
                            try depends.append(alloc, try alloc.dupe(u8, kv.value))
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

        if (trigger != null) {
            trigger.?.ops = try ops.toOwnedSlice(alloc);
            trigger.?.targets = try targets.toOwnedSlice(alloc);
            try triggers.append(alloc, trigger.?);
        }

        hook.triggers = try triggers.toOwnedSlice(alloc);
        hook.deps = try depends.toOwnedSlice(alloc);

        return hook;
    }

    pub fn deinit(self: *Hook, alloc: std.mem.Allocator) void {
        for (self.triggers) |trigger| {
            for (trigger.targets) |target| alloc.free(target);
            alloc.free(trigger.targets);
            alloc.free(trigger.ops);
        }

        if (self.exec) |exec| alloc.free(exec);
        if (self.desc) |desc| alloc.free(desc);
        if (self.deps) |deps| {
            for (deps) |dep| alloc.free(dep);
            alloc.free(deps);
        }

        alloc.free(self.name);
        alloc.free(self.triggers);
    }

    pub fn tryRun(
        self: *Hook,
        alloc: std.mem.Allocator,
        ctx: *Context,
    ) !void {
        var run = false;
        for (self.triggers) |trigger| {
            if (try triggerable(trigger, ctx)) run = true;
        }
        if (!run) return;

        var child = std.process.Child.init(&.{
            "sh",
            "-c",
            self.exec orelse return error.InvalidHook,
        }, alloc);

        child.stdin_behavior = .Ignore;
        child.stdout_behavior = if (builtin.is_test) .Ignore else .Inherit;
        child.stderr_behavior = if (builtin.is_test) .Ignore else .Inherit;

        const term = try child.spawnAndWait();

        switch (term) {
            .Exited => |code| {
                switch (code) {
                    0 => {},
                    else => {
                        if (self.abort_on_fail) std.process.exit(15);
                    },
                }
            },
            else => return error.ProcessTerminatedUnexpectedly,
        }
    }

    fn triggerable(trigger: Trigger, ctx: *Context) !bool {
        for (trigger.ops) |op| {
            switch (op) {
                .Install => {
                    for (ctx.txn.installs.items) |info| {
                        switch (trigger.type) {
                            .Pkg => {
                                for (trigger.targets) |target| {
                                    if (std.mem.eql(u8, info.pkg.name, target))
                                        return true;
                                }
                            },
                            .Path => {
                                for (trigger.targets) |target| {
                                    for (info.files) |file| {
                                        if (std.mem.eql(
                                            u8,
                                            file,
                                            target,
                                        )) return true;
                                    }
                                }
                            },
                        }
                    }
                },
                .Upgrade => {
                    for (ctx.txn.upgrades.items) |pkg| {
                        switch (trigger.type) {
                            .Pkg => {
                                for (trigger.targets) |target| {
                                    if (std.mem.eql(u8, pkg.name, target))
                                        return true;
                                }
                            },
                            .Path => {
                                const pkgid = try ctx.db.config.pkgid_query.one(
                                    u8,
                                    .{},
                                    .{ pkg.name, pkg.repo },
                                ) orelse return error.CorruptDatabase;
                                var it = try ctx.db.config.query_file.iterator(
                                    []const u8,
                                    .{pkgid},
                                );

                                for (trigger.targets) |target| {
                                    while (try it.nextAlloc(
                                        ctx.alloc,
                                        .{},
                                    )) |path| {
                                        defer ctx.alloc.free(path);
                                        if (std.mem.eql(
                                            u8,
                                            path,
                                            target,
                                        )) return true;
                                    }
                                }
                            },
                        }
                    }
                },
                .Remove => {
                    for (ctx.txn.removes.items) |pkg| {
                        switch (trigger.type) {
                            .Pkg => {
                                for (trigger.targets) |target| {
                                    if (std.mem.eql(u8, pkg, target))
                                        return true;
                                }
                            },
                            .Path => {
                                const pkgid = try ctx.db.config.pkgid_query.one(
                                    u8,
                                    .{},
                                    .{ pkg, null },
                                ) orelse return error.CorruptDatabase;
                                var it = try ctx.db.config.query_file.iterator(
                                    []const u8,
                                    .{pkgid},
                                );

                                for (trigger.targets) |target| {
                                    while (try it.nextAlloc(
                                        ctx.alloc,
                                        .{},
                                    )) |path| {
                                        defer ctx.alloc.free(path);
                                        if (std.mem.eql(
                                            u8,
                                            path,
                                            target,
                                        )) return true;
                                    }
                                }
                            },
                        }
                    }
                },
            }
        }

        return false;
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
            const path = try std.fs.path.join(alloc, &.{
                hook_path,
                entry.name,
            });
            defer alloc.free(path);
            const hook = try alloc.create(Hook);
            hook.* = try Hook.init(alloc, path);
            try hooks.append(alloc, hook);
        }
    }

    return hooks.toOwnedSlice(alloc);
}

pub fn deinitAll(alloc: std.mem.Allocator, hooks: []*Hook) void {
    for (hooks) |hook| {
        hook.deinit(alloc);
        alloc.destroy(hook);
    }
    alloc.free(hooks);
}

pub fn tryRunAll(
    alloc: std.mem.Allocator,
    ctx: *Context,
    when: When,
) !void {
    for (ctx.hooks) |hook| if (hook.when == when) try hook.tryRun(alloc, ctx);
}
