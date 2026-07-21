pub const Repo = struct {
    name: []const u8,
    arch: []const u8,
    // only used to get the .db file for indexing
    mirrors: []const []const u8,
    priority: i32,
    enabled: bool = true,
};
