const curl = @import("curl");
const std = @import("std");
const linux = std.os.linux;
const errors = @import("errors.zig");

const NestHandle = struct {
    //====== Internal ======//
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
};

pub fn nestHandleNew(alloc: std.mem.Allocator) !*NestHandle {
    var handle: *NestHandle = try alloc.create(NestHandle);
    var curlm = try curl.Multi.init();

    handle.lockfd = -1;
    handle.curlm = &curlm;

    return handle;
}

pub fn nestHandleFree(alloc: std.mem.Allocator, handle: *NestHandle) void {
    _ = curl.libcurl.curl_multi_cleanup(handle.curlm);
    curl.libcurl.curl_global_cleanup();

    alloc.destroy(handle);
}
