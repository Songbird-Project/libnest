build_date: i64,
version: []const u8,
description: []const u8,
arch: []const u8,
license: []const u8,
filename: []const u8,
packager: []const u8,
checksum: []const u8,
signature: []const u8,
replaces: []const u8,
conflicts: []const u8,
provides: []const u8,
deps: []const u8,
mkdeps: []const u8,
optdeps: []const u8,
checkdeps: []const u8,

pub const Header = struct {
    schema_version: u8 = 1,
    build_date: i64,

    version_len: u16,
    description_len: u16,
    arch_len: u16,
    license_len: u16,
    filename_len: u16,
    packager_len: u16,
    checksum_len: u16,
    signature_len: u16,
    replaces_len: u16,
    conflicts_len: u16,
    provides_len: u16,
    deps_len: u16,
    mkdeps_len: u16,
    optdeps_len: u16,
    checkdeps_len: u16,

    pub fn nextField(raw: [*]const u8, len: usize, ptr: *usize) []const u8 {
        const val = raw[ptr.* .. ptr.* + len];
        ptr.* += len;
        return val;
    }
};

pub const Installed = struct {
    build_date: i64,
    size: i64,
    version: []const u8,
    description: []const u8,
    url: []const u8,
    arch: []const u8,
    license: []const u8,
    packager: []const u8,
    deps: []const u8,
    optdeps: []const u8,

    pub const Header = struct {
        schema_version: u8 = 1,
        build_date: i64,
        size: i64,

        version_len: u16,
        description_len: u16,
        url_len: []const u16,
        arch_len: u16,
        license_len: u16,
        packager_len: u16,
        deps_len: u16,
        optdeps_len: u16,

        pub fn nextField(raw: [*]const u8, len: usize, ptr: *usize) []const u8 {
            const val = raw[ptr.* .. ptr.* + len];
            ptr.* += len;
            return val;
        }
    };
};
