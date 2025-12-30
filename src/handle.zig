//! Handle.zig
//! libnest handle type for performing actions

const curl = @import("curl");
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const errors = @import("error.zig");

/// The libnest handle type
pub const NestHandle = struct {
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
    curlm: ?*curl.Multi,

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
    handle_error: ?errors.NestError,
    /// Lock file descriptor
    lockfd: posix.fd_t,
};

//====== Functions ======//
/// Create a new handle and allocate it's memory
/// The allocator cannot be an arena or fixed buffer
pub fn newHandle(alloc: std.mem.Allocator) !NestHandle {
    var handle: *NestHandle = try alloc.create(NestHandle);
    defer alloc.destroy(handle);
    handle.* = std.mem.zeroes(NestHandle);

    const curlm: *curl.Multi = try alloc.create(curl.Multi);
    curlm.* = try curl.Multi.init();

    handle.lockfile = "/home/dds/Desktop/Projects/Zig/libs/libnest/lock/lock/nest.lock";
    handle.lockfd = -1;
    handle.curlm = curlm;

    return handle.*;
}

/// Destroy a nest handle instance and free it's memory
pub fn freeHandle(alloc: std.mem.Allocator, handle: ?*NestHandle) void {
    if (handle == null) return;
    const h = handle.?;

    if (h.curlm) |curlm| {
        _ = curl.libcurl.curl_multi_cleanup(curlm);
        alloc.destroy(curlm);
        h.curlm = null;
    }
    curl.libcurl.curl_global_cleanup();
}

pub fn lock(handle: *NestHandle) !i8 {
    const dir = std.fs.path.dirname(handle.lockfile) orelse "/";
    try std.fs.cwd().makePath(dir);
    while (handle.lockfd == -1) {
        handle.lockfd = posix.open(handle.lockfile, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
        }, 0o000) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
    }

    return if (handle.lockfd >= 0) 0 else -1;
}

pub fn unlock(alloc: std.mem.Allocator, handle: *NestHandle) !i8 {
    if (handle.lockfile.len <= 0) return 0;
    if (handle.lockfd <= 0) return 0;

    posix.close(handle.lockfd);
    handle.lockfd = -1;

    const lockfile = try alloc.dupeZ(u8, handle.lockfile);
    defer alloc.free(lockfile);
    if (std.os.linux.unlink(lockfile) != 0) {
        handle.handle_error = .NEST_ERR_SYSTEM;
        return -1;
    }

    return 0;
}
