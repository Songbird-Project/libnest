const std = @import("std");

const Context = @import("../core/Context.zig");

pub const Dep = struct {
    name: []const u8 = "Invalid",
    type: enum {
        Opt,
        Make,
        Check,
        Install,
    } = .Install,

    pub fn deinit(self: *Dep, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub fn getDeps(ctx: *Context, path: []const u8, arch: []const u8) ![]Dep {
    const script =
        \\merge_arch_deps() {
        \\  local supported_attrs=(depends optdepends makedepends checkdepends)
        \\
        \\  for attr in "${supported_attrs[@]}"; do
        \\    eval "$attr+=(\"\${${attr}_$CARCH[@]}\")"
        \\  done
        \\
        \\  unset -v "${supported_attrs[@]/%/_$CARCH}"
        \\}
        \\
        \\source "$PKGBUILD"
        \\merge_arch_deps
        \\
        \\for dep in "${depends[@]}"; do
        \\    printf "i:%s\n" "$dep"
        \\done
        \\
        \\for dep in "${makedepends[@]}"; do
        \\    printf "m:%s\n" "$dep"
        \\done
        \\
        \\for dep in "${checkdepends[@]}"; do
        \\    printf "c:%s\n" "$dep"
        \\done
        \\
        \\for dep in "${optdepends[@]}"; do
        \\    printf "o:%s\n" "$dep"
        \\done
    ;

    const env = std.process.Environ.Map.init(ctx.alloc);
    defer env.deinit();
    try env.put("PKGBUILD", path);
    try env.put("CARCH", arch);

    const bash = try std.process.run(ctx.alloc, ctx.io, .{
        .argv = &.{
            "bash",
            "-c",
            script,
        },
        .environ_map = &env,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer ctx.alloc.free(bash.stdout);
    defer ctx.alloc.free(bash.stderr);

    switch (bash.term) {
        .exited => |code| {
            if (code != 0) return error.DepResolutionFailed;
        },
        else => return error.DepResolutionFailed,
    }

    var lines = std.mem.splitScalar(u8, bash.stdout, '\n');
    var deps: std.ArrayList(Dep) = .empty;
    errdefer {
        for (deps.items) |dep| dep.deinit(ctx.alloc);
        deps.deinit(ctx.alloc);
    }

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.findScalar(u8, line, ':')) |idx| {
            var dep = Dep{};

            if (std.mem.eql(u8, line[0..idx], "i"))
                dep.type = .Install
            else if (std.mem.eql(u8, line[0..idx], "o"))
                dep.type = .Opt
            else if (std.mem.eql(u8, line[0..idx], "m"))
                dep.type = .Make
            else if (std.mem.eql(u8, line[0..idx], "c"))
                dep.type = .Check
            else
                continue;

            dep.name = try ctx.alloc.dupe(u8, line[idx + 1 ..]);

            try deps.append(ctx.alloc, dep);
        }
    }

    return deps.toOwnedSlice(ctx.alloc);
}
