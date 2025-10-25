const c = @cImport({
    @cInclude("curses.h");
});

pub const CursesError = error{
    CursesError,
};

pub fn wrap_curses(error_code: c_int) CursesError!void {
    if (error_code == c.ERR) {
        return CursesError.CursesError;
    }
}

/// Set of possible error codes produced from libgit2.
///
/// Taken from: https://libgit2.org/docs/reference/main/errors/git_error_code.html
pub const GitError = error{
    GenericError,
    NotFound,
    Exists,
    Ambiguous,
    Bufs,
    User,
    BareRepo,
    UnbornBranch,
    Unmerged,
    NonFastForward,
    InvalidSpec,
    Conflict,
    Locked,
    Modified,
    Auth,
    Certificate,
    Applied,
    Peel,
    EOF,
    Invalid,
    Uncommitted,
    Directory,
    MergeConflict,
    Passthrough,
    IterOver,
    Retry,
    Mismatch,
    IndexDirty,
    ApplyFail,
    Owner,
    Timeout,
    Unchanged,
    NotSupported,
    ReadOnly,
    Unknown,
};

/// Wraps a call into libgit2 which produces an error code
/// and maps it onto a [GitError].
///
/// Taken from: https://libgit2.org/docs/reference/main/errors/git_error_code.html
pub fn wrap_git(error_code: c_int) GitError!void {
    if (error_code >= 0) {
        return;
    }
    switch (error_code) {
        -1 => return error.GenericError,
        -3 => return error.NotFound,
        -4 => return error.Exists,
        -5 => return error.Ambiguous,
        -6 => return error.Bufs,
        -7 => return error.User,
        -8 => return error.BareRepo,
        -9 => return error.UnbornBranch,
        -10 => return error.Unmerged,
        -11 => return error.NonFastForward,
        -12 => return error.InvalidSpec,
        -13 => return error.Conflict,
        -14 => return error.Locked,
        -15 => return error.Modified,
        -16 => return error.Auth,
        -17 => return error.Certificate,
        -18 => return error.Applied,
        -19 => return error.Peel,
        -20 => return error.EOF,
        -21 => return error.Invalid,
        -22 => return error.Uncommitted,
        -23 => return error.Directory,
        -24 => return error.MergeConflict,
        -30 => return error.Passthrough,
        -31 => return error.IterOver,
        -32 => return error.Retry,
        -33 => return error.Mismatch,
        -34 => return error.IndexDirty,
        -35 => return error.ApplyFail,
        -36 => return error.Owner,
        -37 => return error.Timeout,
        -38 => return error.Unchanged,
        -39 => return error.NotSupported,
        -40 => return error.ReadOnly,
        else => return error.Unknown,
    }
}
