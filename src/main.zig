const std = @import("std");
const c = @cImport({
    @cInclude("git2.h");
    @cInclude("ncurses.h");
    @cInclude("string.h");
});

const err = @import("err.zig");
const git = @import("git.zig");
const ui = @import("ui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const lib = try git.Lib.init();
    defer lib.deinit() catch {};

    const repo = try lib.open_repo("./");
    defer repo.deinit();

    var interface = try ui.Interface.init(allocator, repo);
    defer interface.deinit();

    while (true) {
        try interface.paint(allocator);
        if (try interface.handle_input()) {
            break;
        }
    }
}

const GitRepo = struct {
    const Self = @This();

    repository: ?*c.git_repository,

    pub fn init(path: [*c]const u8) err.GitError!Self {
        var self: Self = undefined;
        try err.wrap_git(c.git_repository_open(&self.repository, path));
        return self;
    }

    pub fn deinit(self: *Self) void {
        c.git_repository_free(self.repository);
    }

    pub fn status_list(self: *Self, opts: *const c.git_status_options) err.GitError!GitRepoStatusIterator {
        var iter = GitRepoStatusIterator{
            .count = undefined,
            .index = 0,
            .opts = opts,
            .status_list = undefined,
        };
        try err.wrap_git(c.git_status_list_new(
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
    const Self = @This();

    status_index_new: bool,
    status_index_modified: bool,
    status_index_deleted: bool,
    status_index_renamed: bool,
    status_index_typechange: bool,
    _padding1: u2 = 0,
    status_worktree_new: bool,
    status_worktree_modified: bool,
    status_worktree_deleted: bool,
    status_worktree_typechange: bool,
    status_worktree_renamed: bool,
    status_worktree_unreadable: bool,
    _padding2: u1 = 0,
    status_ignored: bool,
    status_conflicted: bool,
    _padding3: u16 = 0,

    pub fn from_git_status_t(git_status: c.git_status_t) GitStatus {
        return @bitCast(git_status);
    }

    pub fn is_staged(self: Self) bool {
        _ = self;
        return false;
    }

    pub fn is_untracked(self: Self) bool {
        return self.status_worktree_new;
    }
};
