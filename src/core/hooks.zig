const std = @import("std");
const ini = @import("ini");

const Context = @import("Context.zig");

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
    triggers: []Trigger,
    deps: ?[][]const u8 = null,
    when: When = .Pre,
    abort_on_fail: bool = false,
    needs_targets: bool = false,

    pub fn init(ctx: *Context, path: []const u8) !Hook {
        const f = try std.fs.cwd().openFile(path, .{
            .mode = .read_only,
        });
        defer f.close();
        var buf: [4096]u8 = undefined;
        var reader = f.reader(&buf);
        var parser = ini.parse(
            ctx.alloc,
            &reader.interface,
            ";#",
        );

        var hook = Hook{
            .name = path,
        };

        var trigger: Trigger = undefined;
        var current_header: enum { Trigger, Action } = .Trigger;

        var triggers: std.ArrayList(Trigger) = .empty;
        defer triggers.deinit(ctx.alloc);

        var ops: std.ArrayList(Operator) = .empty;
        defer ops.deinit(ctx.alloc);

        var targets: std.ArrayList([]const u8) = .empty;
        defer targets.deinit(ctx.alloc);

        var depends: std.ArrayList([]const u8) = .empty;
        defer depends.deinit(ctx.alloc);

        while (try parser.next()) |record| {
            switch (record) {
                .section => |header| {
                    if (std.mem.eql(u8, header, "Trigger")) {
                        if (trigger != undefined) {
                            trigger.ops = ops.toOwnedSlice(ctx.alloc);
                            ops.clearRetainingCapacity();
                            try triggers.append(ctx.alloc, trigger);
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
                                trigger.type = .Path
                            else if (std.mem.eql(u8, kv.value, "Package"))
                                trigger.type = .Pkg;
                        } else if (std.mem.eql(u8, kv.key, "Operation")) {
                            if (std.mem.eql(u8, kv.value, "Install"))
                                ops.append(ctx.alloc, .Install)
                            else if (std.mem.eql(u8, kv.value, "Upgrade"))
                                try ops.append(ctx.alloc, .Upgrade)
                            else if (std.mem.eql(u8, kv.value, "Remove"))
                                try ops.append(ctx.alloc, .Remove);
                        } else if (std.mem.eql(u8, kv.key, "Target"))
                            try targets.append(ctx.alloc, kv.value);
                    } else if (current_header == .Action) {
                        if (std.mem.eql(u8, kv.key, "Description"))
                            hook.desc = ctx.alloc.dupe(u8, kv.value)
                        else if (std.mem.eql(u8, kv.key, "Depends"))
                            try depends.append(ctx.alloc, kv.value)
                        else if (std.mem.eql(u8, kv.key, "Exec"))
                            hook.exec = ctx.alloc.dupe(u8, kv.value)
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
                else => {},
            }
        }

        hook.triggers = triggers.toOwnedSlice(ctx.alloc);
        hook.deps = depends.toOwnedSlice(ctx.alloc);

        return hook;
    }

    pub fn deinit(self: *Hook, ctx: *Context) void {
        for (self.triggers) |trigger| {
            for (trigger.targets) |target| ctx.alloc.free(target);
            ctx.alloc.free(trigger.ops);
        }

        if (self.deps) |deps| for (deps) |dep| ctx.alloc.free(dep);
        if (self.desc) |desc| ctx.alloc.free(desc);

        ctx.alloc.free(self.name);
        ctx.alloc.free(self.exec);
    }
};

pub fn initAll(ctx: *Context) ![]Hook {
    var hook_dir = try std.fs.cwd().openDir(ctx.paths.hook, .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer hook_dir.close();
    var it = hook_dir.iterate();

    var hooks: std.ArrayList(Hook) = .empty;

    while (try it.nextLinux()) |entry| {
        if (entry.kind == .file and
            std.mem.endsWith(u8, entry.name, ".hook"))
            try hooks.append(ctx.alloc, Hook.init(ctx, entry.name));
    }
}

pub fn deinitAll(ctx: *Context, hooks: []Hook) void {
    for (hooks) |hook| hook.deinit(ctx);
}
