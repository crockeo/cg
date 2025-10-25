const std = @import("std");
const c = @cImport({
    @cInclude("git2.h");
    @cInclude("ncurses.h");
    @cInclude("string.h");
});

const err = @import("err.zig");
const git = @import("git.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const lib = try git.Lib.init();
    defer lib.deinit() catch {};

    const repo = try lib.open_repo("./");
    defer repo.deinit();

    const status = try repo.status();
    defer status.deinit();

    var staged = std.ArrayList(git.DiffDelta).empty;
    defer staged.deinit(allocator);

    var unstaged = std.ArrayList(git.DiffDelta).empty;
    defer unstaged.deinit(allocator);

    var untracked = std.ArrayList(git.DiffDelta).empty;
    defer untracked.deinit(allocator);

    var iter = status.iter();
    while (try iter.next()) |entry| {
        if (entry.staged()) |staged_diff| {
            try staged.append(allocator, staged_diff);
        }
        if (entry.unstaged()) |unstaged_diff| {
            if (unstaged_diff.status() == .Untracked) {
                try untracked.append(allocator, unstaged_diff);
            } else {
                try unstaged.append(allocator, unstaged_diff);
            }
        }
    }

    // TODO:
    std.debug.print("> Head:     SHA1 branch commit message\n\n", .{});

    if (untracked.items.len > 0) {
        std.debug.print("v Untracked files ({d})\n", .{untracked.items.len});
        for (untracked.items) |diff_delta| {
            std.debug.print("> {s}\n", .{diff_delta.diff_delta.*.new_file.path});
        }
        std.debug.print("\n", .{});
    }

    if (unstaged.items.len > 0) {
        std.debug.print("v Unstaged changes ({d})\n", .{unstaged.items.len});
        for (unstaged.items) |diff_delta| {
            std.debug.print("> {s}   {s}\n", .{ diff_delta.status().name(), diff_delta.diff_delta.*.new_file.path });
        }
        std.debug.print("\n", .{});
    }

    if (staged.items.len > 0) {
        std.debug.print("v Staged changes ({d})\n", .{staged.items.len});
        for (staged.items) |diff_delta| {
            std.debug.print("> {s}   {s}\n", .{ diff_delta.status().name(), diff_delta.diff_delta.*.new_file.path });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("> Recent commits\n", .{});
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
