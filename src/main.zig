const std = @import("std");
const c = @cImport({
    @cInclude("git2.h");
    @cInclude("ncurses.h");
    @cInclude("string.h");
});

const err = @import("err.zig");
const git = @import("git.zig");

pub fn main() !void {
    const lib = try git.Lib.init();
    defer lib.deinit() catch {};

    const repo = try lib.open_repo("./");
    defer repo.deinit();

    const status = try repo.status();
    defer status.deinit();

    var iter = status.iter();
    while (try iter.next()) |entry| {
        std.debug.print("{any}\n", .{entry});
        if (entry.head_to_index()) |head_to_index| {
            _ = head_to_index;
        }
        if (entry.index_to_workdir()) |index_to_workdir| {
            _ = index_to_workdir;
        }
    }

    // try err.wrap_git(c.git_libgit2_init());
    // defer _ = c.git_libgit2_shutdown();

    // var repo = try GitRepo.init("../../core");
    // defer repo.deinit();

    // const opts = c.git_status_options{
    //     .flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED,
    //     .show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR,
    //     .version = c.GIT_STATUS_OPTIONS_VERSION,
    // };

    // var status_iter = try repo.status_list(&opts);
    // std.debug.print("Found {d} entries:\n", .{status_iter.len()});
    // while (status_iter.next()) |status_entry| {
    //     const path = blk: {
    //         if (status_entry.*.index_to_workdir) |index_to_workdir| {
    //             break :blk index_to_workdir.*.new_file.path;
    //         }
    //         if (status_entry.*.head_to_index) |head_to_index| {
    //             break :blk head_to_index.*.new_file.path;
    //         }
    //         @panic("Unknown situation");
    //     };
    //     const is_staged = blk: {
    //         if (status_entry.*.index_to_workdir != null) {
    //             break :blk "Staged";
    //         }
    //         if (status_entry.*.head_to_index != null) {
    //             break :blk "Unstaged";
    //         }
    //         @panic("Unknown situation");
    //     };
    //     const status = blk: {
    //         if (status_entry.*.index_to_workdir) |index_to_workdir| {
    //             const delta: GitDelta = @enumFromInt(index_to_workdir.*.status);
    //             break :blk delta.name();
    //         }
    //         if (status_entry.*.head_to_index) |head_to_index| {
    //             const delta: GitDelta = @enumFromInt(head_to_index.*.status);
    //             break :blk delta.name();
    //         }
    //         @panic("Unknown situation");
    //     };
    //     std.debug.print("{s} {s} {s}\n", .{ path, is_staged, status });

    //     // std.debug.print("{any}\n", .{GitStatus.from_git_status_t(status_entry.*.status)});
    // }
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

const GitDelta = enum(c_uint) {
    Unmodified = 0,
    Added = 1,
    Deleted = 2,
    Modified = 3,
    Renamed = 4,
    Copied = 5,
    Ignored = 6,
    Untracked = 7,
    TypeChange = 8,
    Unreadable = 9,
    Conflicted = 10,

    pub fn name(self: GitDelta) []const u8 {
        switch (self) {
            .Unmodified => return "Unmodified",
            .Added => return "Added",
            .Deleted => return "Deleted",
            .Modified => return "Modified",
            .Renamed => return "Renamed",
            .Copied => return "Copied",
            .Ignored => return "Ignored",
            .Untracked => return "Untracked",
            .TypeChange => return "TypeChange",
            .Unreadable => return "Unreadable",
            .Conflicted => return "Conflicted",
        }
    }
};
