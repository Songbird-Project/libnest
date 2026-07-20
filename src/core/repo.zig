pub const PGPKey = struct {
    id: []const u8,
    algorithm: []const u8,
    data: []const u8,
};

pub const Repo = struct {
    id: []const u8,
    name: []const u8,
    arch: []const u8,
    // only used to get the .db file for indexing
    mirrors: []const []const u8,
    priority: i32,
    enabled: bool,
    keys: []PGPKey,
};
