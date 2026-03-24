const std = @import("std");

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

pub fn getDeps(alloc: std.mem.Allocator, path: []const u8, arch: []const u8) ![]Dep {
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

    var env: std.process.EnvMap = .init(alloc);
    defer env.deinit();
    try env.put("PKGBUILD", path);
    try env.put("CARCH", arch);

    var bash = std.process.Child.init(
        &.{
            "bash",
            "-c",
            script,
        },
        alloc,
    );
    bash.env_map = &env;
    bash.stdout_behavior = .Pipe;
    bash.stderr_behavior = .Pipe;

    try bash.spawn();

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(alloc);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(alloc);
    try bash.collectOutput(
        alloc,
        &stdout,
        &stderr,
        8192,
    );

    const status = try bash.wait();
    switch (status) {
        .Exited => |code| {
            if (code != 0) return error.DepResolutionFailed;
        },
        else => return error.DepResolutionFailed,
    }

    var lines = std.mem.splitScalar(u8, stdout.items, '\n');
    var deps: std.ArrayList(Dep) = .empty;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, ':')) |idx| {
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

            dep.name = try alloc.dupe(u8, line[idx + 1 ..]);

            try deps.append(alloc, dep);
        }
    }

    return deps.toOwnedSlice(alloc);
}
