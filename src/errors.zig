//==================//
//      Errors      //
//==================//

/// Nest error values
/// A "generic" error should never exist.
/// Errors should be one of the following values
/// or be added to the list in the corresponding category.
pub const NestError = enum(u8) {
    //====== General Errors (0-19) ======//
    /// None or negligible
    NEST_ERR_OK = 0,
    /// System level error
    NEST_ERR_SYSTEM,
    /// Incorrect permissions have been given
    NEST_ERR_PERMS,
    /// File or directory does not exist
    NEST_ERR_DOES_NOT_EXIST,
    /// Target is not a file when it should be
    NEST_ERR_NOT_A_FILE,
    /// Target is not a directory when it should be
    NEST_ERR_NOT_A_DIR,
    /// Insufficient disk space to perform the action
    NEST_ERR_NOT_ENOUGH_SPACE,

    //====== Database Errors (20-39) ======//
    /// Failed to find the database
    NEST_ERR_DB_NOT_FOUND = 20,

    //====== Server Errors (40-59) ======//
    /// Server URL is invalid
    NEST_ERR_SERVER_BAD_URL = 40,

    //====== Handle Errors (60-79) ======//
    /// Handle is null
    NEST_ERR_HANDLE_NULL = 60,

    //====== Transaction Error (80-99) ======//
    /// A transaction is already hapenning
    NEST_ERR_TRANS_NOT_NULL = 80,

    //====== Package Error (100-119) ======//
    /// Package not found
    NEST_ERR_PKG_NOT_FOUND = 100,

    //====== Dependency Error (120-139) ======//
    /// Unable to satisfy package dependencies
    NEST_ERR_DEPS_UNSATISFIED = 120,

    //====== Signature Error (140-159) ======//
    /// Signatures are missing
    NEST_ERR_SIG_MISSING = 140,

    //====== External Library Error (160-179) ======//
    /// Error with libcurl
    NEST_ERR_EXTERN_CURL = 160,

    //====== Download Error (180-199) ======//
    /// Unable to prepare download
    NEST_ERR_DOWNLOAD_PREPARE = 180,
};

/// Return the current error code of the
/// nest handle.
pub fn nestErrNumber(err: NestError) u8 {
    return @intFromEnum(err);
}

/// Return the current error code of the
/// nest handle as a string.
pub fn nestErrString(err: NestError) []const u8 {
    return switch (err) {
        //====== General Errors (0-19) ======//
        .NEST_ERR_SYSTEM => "unexpected system error",
        .NEST_ERR_PERMS => "permission denied",
        .NEST_ERR_DOES_NOT_EXIST => "unable to find file or directory",
        .NEST_ERR_NOT_A_FILE => "unable to find or read file",
        .NEST_ERR_NOT_A_DIR => "unable to find or read directory",
        .NEST_ERR_NOT_ENOUGH_SPACE => "insufficient free disk space",

        //====== Database Errors (20-39) ======//
        .NEST_ERR_DB_NOT_FOUND => "unable to find database",

        //====== Server Errors (40-59) ======//

        //====== Handle Errors (60-79) ======//
        .NEST_ERR_HANDLE_NULL => "library not initialized",

        //====== Transaction Error (80-99) ======//
        .NEST_ERR_TRANS_NOT_NULL => "transaction already initialized",

        //====== Package Error (100-119) ======//
        .NEST_ERR_PKG_NOT_FOUND => "package not found",

        //====== Dependency Error (120-139) ======//
        .NEST_ERR_DEPS_UNSATISFIED => "unable to satisfy dependencies",

        //====== Signature Error (140-159) ======//
        .NEST_ERR_SIG_MISSING => "missing GPG signature",

        //====== External Library Error (160-179) ======//
        .NEST_ERR_EXTERN_CURL => "libcurl error",

        //====== Download Error (180-199) ======//
        .NEST_ERR_DOWNLOAD_PREPARE => "failed to prepare download",

        else => "unexpected error",
    };
}
