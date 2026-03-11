const std = @import("std");
const Pkg = @import("./Package.zig");
const curl = @import("curl");

pub fn Response(comptime T: type) type {
    return struct {
        resultcount: usize,
        type: []const u8,
        version: usize,
        results: []T,
    };
}

const QueryKind = enum {
    Name,
    NameDesc,
    Deps,
    Checkdeps,
    Optdeps,
    Makedeps,
    Maintainer,
    Submitter,
    Provides,
    Conflicts,
    Replaces,
    Keywords,
    Groups,
    Comaintainers,

    pub fn toString(kind: QueryKind) []const u8 {
        return switch (kind) {
            .Name => "name",
            .NameDesc => "name-desc",
            .Deps => "desc",
            .Checkdeps => "checkdepends",
            .Optdeps => "optdepends",
            .Makedeps => "makedepends",
            .Maintainer => "maintainer",
            .Submitter => "submitter",
            .Provides => "provides",
            .Conflicts => "conflicts",
            .Replaces => "replaces",
            .Keywords => "keywords",
            .Groups => "groups",
            .Comaintainers => "comaintainers",
        };
    }
};

const Client = @This();

alloc: std.mem.Allocator,
client: *curl.Easy,
ca_bundle: *std.array_list.Managed(u8),

pub fn init(alloc: std.mem.Allocator) !Client {
    const client = try alloc.create(curl.Easy);
    const ca_bundle = try alloc.create(std.array_list.Managed(u8));
    ca_bundle.* = try curl.allocCABundle(alloc);
    client.* = try curl.Easy.init(.{ .ca_bundle = ca_bundle.* });

    return Client{
        .alloc = alloc,
        .client = client,
        .ca_bundle = ca_bundle,
    };
}

pub fn deinit(self: *Client) void {
    self.client.deinit();
    self.alloc.destroy(self.client);
    self.ca_bundle.deinit();
    self.alloc.destroy(self.ca_bundle);
}

pub fn search(
    self: *Client,
    query: []const u8,
    query_kind: QueryKind,
) !std.json.Parsed(Response(Pkg.Basic)) {
    self.client.reset();

    var headers: curl.Easy.Headers = .{};
    defer headers.deinit();
    try headers.add("accept: application/json");

    try self.client.setHeaders(headers);

    const url = try std.fmt.allocPrintSentinel(
        self.alloc,
        "https://aur.archlinux.org/rpc/v5/search/{s}?by={s}",
        .{ query, query_kind.toString() },
        0,
    );
    defer self.alloc.free(url);
    try self.client.setUrl(url);

    try self.client.setMethod(.GET);

    var writer = std.io.Writer.Allocating.init(self.alloc);
    defer writer.deinit();
    try self.client.setWriter(&writer.writer);

    _ = try self.client.perform();

    return try std.json.parseFromSlice(
        Response(Pkg.Basic),
        self.alloc,
        writer.written(),
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}

pub fn info(self: *Client, query: []const u8) !std.json.Parsed(Response(Pkg.Detailed)) {
    self.client.reset();

    var headers: curl.Easy.Headers = .{};
    defer headers.deinit();
    try headers.add("accept: application/json");

    try self.client.setHeaders(headers);

    const url = try std.fmt.allocPrintSentinel(
        self.alloc,
        "https://aur.archlinux.org/rpc/v5/info/{s}",
        .{query},
        0,
    );
    defer self.alloc.free(url);
    try self.client.setUrl(url);

    try self.client.setMethod(.GET);

    var writer = std.io.Writer.Allocating.init(self.alloc);
    defer writer.deinit();
    try self.client.setWriter(&writer.writer);

    _ = try self.client.perform();

    return try std.json.parseFromSlice(
        Response(Pkg.Detailed),
        self.alloc,
        writer.written(),
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}
