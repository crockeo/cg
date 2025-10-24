const c = @cImport({
    @cInclude("git2.h");
});

const err = @import("err.zig");

pub const Lib = struct {
    const Self = @This();

    pub fn init() err.GitError!Self {
        try err.wrap_git(c.git_libgit2_init());
        return .{};
    }

    pub fn deinit(self: Self) err.GitError!void {
        _ = self;
        try err.wrap_git(c.git_libgit2_shutdown());
    }

    pub fn open_repo(self: Self, repo_path: [:0]const u8) err.GitError!Repo {
        _ = self;
        var repo: ?*c.git_repository = undefined;
        try err.wrap_git(c.git_repository_open(&repo, repo_path));
        return .{ .repo = repo };
    }
};

pub const Repo = struct {
    const Self = @This();

    repo: ?*c.git_repository,

    pub fn deinit(self: Self) void {
        c.git_repository_free(self.repo);
    }

    pub fn status(self: Self) err.GitError!StatusList {
        // TODO: allow `status` to receive options,
        // which can be provided to `StatusList`.
        var status_list: StatusList = .{
            .status_list = null,
            .opt = .{
                .flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED,
                .show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR,
                .version = c.GIT_STATUS_OPTIONS_VERSION,
            },
        };
        try err.wrap_git(c.git_status_list_new(
            &status_list.status_list,
            self.repo,
            &status_list.opt,
        ));
        return status_list;
    }
};

pub const StatusList = struct {
    const Self = @This();

    opt: c.git_status_options,
    status_list: ?*c.git_status_list,

    pub fn deinit(self: Self) void {
        c.git_status_list_free(self.status_list);
    }

    pub fn len(self: Self) usize {
        return c.git_status_list_entrycount(self.status_list);
    }

    pub fn get(self: Self, index: usize) err.GitError!StatusEntry {
        return .{
            .status_entry = c.git_status_byindex(self.status_list, index),
        };
    }

    pub fn iter(self: Self) StatusListIter {
        return .{
            .count = self.len(),
            .index = 0,
            .parent = self,
        };
    }
};

pub const StatusListIter = struct {
    const Self = @This();

    count: usize,
    index: usize,
    parent: StatusList,

    pub fn next(self: *Self) err.GitError!?StatusEntry {
        if (self.index >= self.count) {
            return null;
        }
        const next_value = try self.parent.get(self.index);
        self.index += 1;
        return next_value;
    }
};

pub const StatusEntry = struct {
    const Self = @This();

    status_entry: *const c.git_status_entry,

    pub fn index_to_workdir(self: Self) ?DiffDelta {
        if (self.status_entry.*.index_to_workdir == null) {
            return null;
        }
        return .{ .diff_delta = self.status_entry.*.index_to_workdir };
    }

    pub fn head_to_index(self: Self) ?DiffDelta {
        if (self.status_entry.*.head_to_index == null) {
            return null;
        }
        return .{ .diff_delta = self.status_entry.*.head_to_index };
    }
};

pub const DiffDelta = struct {
    diff_delta: [*c]const c.git_diff_delta,
};
