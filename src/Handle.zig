//! Handle.zig
//! All libnest handle type for performing actions

const curl = @import("curl");
const std = @import("std");
const linux = std.os.linux;
const errors = @import("error.zig");

/// The libnest handle type
// pub const NestHandle = struct {
//====== Internal ======//
alloc: std.mem.Allocator,
user: linux.uid_t,

//====== Filesystem paths ======//
/// Root path
root: []const u8,
/// Database path
dbpath: []const u8,
/// Current log file name
logfile: []const u8,
/// Current lock file name
lockfile: []const u8,
/// Directory where GnuPG files are stored
gpgdir: []const u8,
/// User to use when performing sensitive actions
sensitive_user: []const u8,

//====== libcurl handle ======//
/// curl multi interface
curlm: *curl.Multi,

//====== libnest options ======//
/// Check disk space before performing actions
check_space: bool,
/// File extension of database files
dbextension: []const u8,
/// Default signature verification level
siglevel: u8,
/// Signature level for local repositories
local_repo_sig_level: u8,
/// Signature level for remote repositories
remote_repo_sig_level: u8,

//====== Other ======//
/// Error code
handle_error: errors.NestError,
/// Lock file descriptor
lockfd: i8,

//====== Functions ======//
/// Handle instantiation function, create a new handle and
/// allocate it's memory
pub fn init(alloc: std.mem.Allocator) !*@This() {
    var handle: *@This() = try alloc.create(@This());
    var curlm = try curl.Multi.init();

    handle.lockfd = -1;
    handle.alloc = alloc;
    handle.curlm = &curlm;

    return handle;
}

/// Destroy a nest handle instance and free it's memory
pub fn deinit(self: *@This()) void {
    _ = curl.libcurl.curl_multi_cleanup(self.curlm);
    curl.libcurl.curl_global_cleanup();

    self.alloc.destroy(self);
}
// };
