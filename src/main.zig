const std = @import("std");
const c = @cImport({
    @cInclude("git2.h");
    @cInclude("ncurses.h");
    @cInclude("string.h");
});

pub fn main() !void {
    try wrap_git_call(c.git_libgit2_init());
    defer _ = c.git_libgit2_shutdown();

    _ = c.initscr();
    defer _ = c.endwin();

    _ = c.cbreak();
    _ = c.noecho();
    _ = c.keypad(c.stdscr, true);

    var repo = try GitRepo.init("./.git");
    defer repo.deinit();

    const opts = c.git_status_options{
        .flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED,
        .show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR,
        .version = c.GIT_STATUS_OPTIONS_VERSION,
    };

    var status_iter = try repo.status_list(&opts);
    _ = c.printw("%d entries\n", status_iter.len());
    while (status_iter.next()) |status_entry| {
        _ = c.printw("%d\n", status_entry.*.status);
        // _ = c.printw(status_entry.);
    }

    _ = c.printw("Hello, ncurses!\n");
    _ = c.printw("Press any key to continue!");
    _ = c.refresh();
    _ = c.getch();
}

const GitRepo = struct {
    const Self = @This();

    repository: ?*c.git_repository,

    pub fn init(path: [*c]const u8) GitError!Self {
        var self: Self = undefined;
        try wrap_git_call(c.git_repository_open(&self.repository, path));
        return self;
    }

    pub fn deinit(self: *Self) void {
        c.git_repository_free(self.repository);
    }

    pub fn status_list(self: *Self, opts: *const c.git_status_options) GitError!GitRepoStatusIterator {
        var iter = GitRepoStatusIterator{
            .count = undefined,
            .index = 0,
            .opts = opts,
            .status_list = undefined,
        };
        try wrap_git_call(c.git_status_list_new(
            &iter.status_list,
            self.repository,
            opts,
        ));
        iter.count = c.git_status_list_entrycount(iter.status_list);
        return iter;
    }
};

const GitRepoStatusIterator = struct {
    const Self = @This();

    count: usize,
    index: usize,
    opts: *const c.git_status_options,
    status_list: ?*c.git_status_list,

    pub fn len(self: *const Self) usize {
        return self.count;
    }

    pub fn next(self: *Self) [*c]const c.git_status_entry {
        if (self.index >= self.count) {
            c.git_status_list_free(self.status_list);
            return null;
        }
        const status_entry = c.git_status_byindex(self.status_list, self.index);
        self.index += 1;
        return status_entry;
    }
};

/// Corresponds directly to libgit2's `git_status_t` type.
/// Uses a packed struct in a u16 to represent statuses.
///
/// Taken from https://libgit2.org/docs/reference/main/status/git_status_t.html
const GitStatus = packed struct {
    status_index_new: bool,
    status_index_modified: bool,
    status_index_deleted: bool,
    status_index_renamed: bool,
    status_index_typechange: bool,
    _padding1: u2 = 0,
    status_wt_new: bool,
    status_wt_modified: bool,
    status_wt_deleted: bool,
    status_wt_typechange: bool,
    status_wt_renamed: bool,
    status_wt_unreadable: bool,
    _padding2: u1 = 0,
    status_ignored: bool,
    status_conflicted: bool,

    pub fn from_git_status_t(git_status: c.git_status_t) GitStatus {
        return @bitCast(git_status);
    }
};

/// Set of possible error codes produced from libgit2.
///
/// Taken from: https://libgit2.org/docs/reference/main/errors/git_error_code.html
const GitError = error{
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
fn wrap_git_call(error_code: c_int) GitError!void {
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
        {} => return error.Unknown,
    }
}
