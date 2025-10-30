const std = @import("std");
const c = @cImport({
    @cInclude("git2.h");
    @cInclude("string.h");
});

const err = @import("err.zig");

pub fn commit(allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(
        &[_][]const u8{ "git", "commit" },
        allocator,
    );
    try child.spawn();
    _ = try child.wait();
}

pub fn push(allocator: std.mem.Allocator, remote: []const u8, branch: []const u8) !void {
    var child = std.process.Child.init(
        &[_][]const u8{ "git", "push", remote, branch },
        allocator,
    );
    try child.spawn();
    _ = try child.wait();
}

pub fn stage(allocator: std.mem.Allocator, paths: []const []const u8) !void {
    const args = try std.mem.concat(allocator, []const u8, &[_][]const []const u8{
        &[_][]const u8{ "git", "add", "--" },
        paths,
    });
    defer allocator.free(args);

    var child = std.process.Child.init(args, allocator);
    try child.spawn();
    _ = try child.wait();
}

// TODO: modify the naming of this once we get rid of the old status stuff.
const CLIStatus = struct {
    const Self = @This();

    const ChangeType = enum {
        added,
        copied,
        deleted,
        file_type_change,
        modified,
        renamed,
        unmodified,
        updated_unmerged,

        fn parse(char: u8) !ChangeType {
            return switch (char) {
                '.' => .unmodified,
                'M' => .modified,
                'T' => .file_type_change,
                'A' => .added,
                'D' => .deleted,
                'R' => .renamed,
                'C' => .copied,
                'U' => .updated_unmerged,
                else => error.InvalidChangeType,
            };
        }
    };

    const XY = struct {
        x: ChangeType,
        y: ChangeType,

        fn parse(xy_str: []const u8) !XY {
            if (xy_str.len != 2) return error.InvalidXY;
            return .{
                .x = try ChangeType.parse(xy_str[0]),
                .y = try ChangeType.parse(xy_str[1]),
            };
        }
    };

    const ChangedFile = struct {
        xy: XY,
        submodule_state: []const u8,
        mode_head: []const u8,
        mode_index: []const u8,
        mode_worktree: []const u8,
        object_name_head: []const u8,
        object_name_index: []const u8,
        path: []const u8,

        fn parse(line: []const u8) !ChangedFile {
            var it = std.mem.splitScalar(u8, line, ' ');
            const xy = try XY.parse(it.next() orelse return error.MissingXY);
            const submodule_state = it.next() orelse return error.MissingSubmoduleState;
            const mode_head = it.next() orelse return error.MissingModeHead;
            const mode_index = it.next() orelse return error.MissingModeIndex;
            const mode_worktree = it.next() orelse return error.MissingModeWorktree;
            const object_name_head = it.next() orelse return error.MissingObjectNameHead;
            const object_name_index = it.next() orelse return error.MissingObjectNameIndex;
            const path = it.rest();

            return .{
                .xy = xy,
                .submodule_state = submodule_state,
                .mode_head = mode_head,
                .mode_index = mode_index,
                .mode_worktree = mode_worktree,
                .object_name_head = object_name_head,
                .object_name_index = object_name_index,
                .path = path,
            };
        }
    };
    const CopiedOrRenamedFile = struct {
        const Score = union {
            copied: u8,
            renamed: u8,
        };
        xy: XY,
        submodule_state: []const u8,
        mode_head: []const u8,
        mode_index: []const u8,
        mode_worktree: []const u8,
        object_name_head: []const u8,
        object_name_index: []const u8,
        score: Score,
        path: []const u8,
        original_path: []const u8,

        fn parse(line: []const u8) !CopiedOrRenamedFile {
            var it = std.mem.splitScalar(u8, line, ' ');
            const xy = try XY.parse(it.next() orelse return error.MissingXY);
            const submodule_state = it.next() orelse return error.MissingSubmoduleState;
            const mode_head = it.next() orelse return error.MissingModeHead;
            const mode_index = it.next() orelse return error.MissingModeIndex;
            const mode_worktree = it.next() orelse return error.MissingModeWorktree;
            const object_name_head = it.next() orelse return error.MissingObjectNameHead;
            const object_name_index = it.next() orelse return error.MissingObjectNameIndex;
            const score_str = it.next() orelse return error.MissingScore;

            const score_type = score_str[0];
            const score_value = try std.fmt.parseInt(u8, score_str[1..], 10);
            const score: Score = switch (score_type) {
                'R' => .{ .renamed = score_value },
                'C' => .{ .copied = score_value },
                else => return error.InvalidScoreType,
            };

            const rest = it.rest();
            var path_it = std.mem.splitScalar(u8, rest, '\t');
            const path = path_it.next() orelse return error.MissingPath;
            const original_path = path_it.next() orelse return error.MissingOriginalPath;

            return .{
                .xy = xy,
                .submodule_state = submodule_state,
                .mode_head = mode_head,
                .mode_index = mode_index,
                .mode_worktree = mode_worktree,
                .object_name_head = object_name_head,
                .object_name_index = object_name_index,
                .score = score,
                .path = path,
                .original_path = original_path,
            };
        }
    };
    const UnmergedFile = struct {
        xy: XY,
        submodule_state: []const u8,
        mode_stage_1: []const u8,
        mode_stage_2: []const u8,
        mode_stage_3: []const u8,
        mode_worktree: []const u8,
        object_name_stage_1: []const u8,
        object_name_stage_2: []const u8,
        object_name_stage_3: []const u8,
        path: []const u8,

        fn parse(line: []const u8) !UnmergedFile {
            var it = std.mem.splitScalar(u8, line, ' ');
            const xy = try XY.parse(it.next() orelse return error.MissingXY);
            const submodule_state = it.next() orelse return error.MissingSubmoduleState;
            const mode_stage_1 = it.next() orelse return error.MissingModeStage1;
            const mode_stage_2 = it.next() orelse return error.MissingModeStage2;
            const mode_stage_3 = it.next() orelse return error.MissingModeStage3;
            const mode_worktree = it.next() orelse return error.MissingModeWorktree;
            const object_name_stage_1 = it.next() orelse return error.MissingObjectNameStage1;
            const object_name_stage_2 = it.next() orelse return error.MissingObjectNameStage2;
            const object_name_stage_3 = it.next() orelse return error.MissingObjectNameStage3;
            const path = it.rest();

            return .{
                .xy = xy,
                .submodule_state = submodule_state,
                .mode_stage_1 = mode_stage_1,
                .mode_stage_2 = mode_stage_2,
                .mode_stage_3 = mode_stage_3,
                .mode_worktree = mode_worktree,
                .object_name_stage_1 = object_name_stage_1,
                .object_name_stage_2 = object_name_stage_2,
                .object_name_stage_3 = object_name_stage_3,
                .path = path,
            };
        }
    };
    const UntrackedFile = struct {
        path: []const u8,

        fn parse(line: []const u8) UntrackedFile {
            return .{ .path = line };
        }
    };
    const IgnoredFile = struct {
        path: []const u8,

        fn parse(line: []const u8) IgnoredFile {
            return .{ .path = line };
        }
    };
    const File = union {
        changed: ChangedFile,
        copied_or_renamed: CopiedOrRenamedFile,
        unmerged: UnmergedFile,
        untracked_file: UntrackedFile,
        ignored_file: IgnoredFile,
    };

    allocator: std.mem.Allocator,
    contents: []const u8,
    files: []const File,

    // These are not values themselves,
    // but rather pointers into "contents"
    branch_head: ?[]const u8 = null,
    branch_upstream: ?[]const u8 = null,

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.contents);
        self.allocator.free(self.files);
        self.allocator.destroy(self);
    }
};

pub fn cli_status(allocator: std.mem.Allocator) !*CLIStatus {
    const stat = try allocator.create(CLIStatus);
    stat.* = .{
        .allocator = allocator,
        .contents = undefined,
        .files = undefined,
    };
    errdefer allocator.destroy(stat);

    var child = std.process.Child.init(
        &[_][]const u8{ "git", "status", "--branch", "--porcelain=v2" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    try child.spawn();

    stat.*.contents = blk: {
        var buf: [1024]u8 = undefined;
        var stdout = child.stdout orelse @panic("Logic error.");

        var allocating_writer = std.io.Writer.Allocating.init(allocator);
        errdefer allocating_writer.deinit();

        while (true) {
            const read = try stdout.read(&buf);
            if (read == 0) {
                break;
            }
            try allocating_writer.writer.writeAll(buf[0..read]);
        }

        break :blk try allocating_writer.toOwnedSlice();
    };
    errdefer allocator.free(stat.*.contents);
    _ = try child.wait();

    var files = std.ArrayList(CLIStatus.File).empty;
    errdefer files.deinit(allocator);

    var lines = std.mem.splitScalar(u8, stat.*.contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# branch.head")) {
            stat.*.branch_head = line["# branch.head ".len..];
        } else if (std.mem.startsWith(u8, line, "# branch.upstream")) {
            stat.*.branch_upstream = line["# branch.upstream ".len..];
        } else if (std.mem.startsWith(u8, line, "1 ")) {
            const file = try CLIStatus.ChangedFile.parse(line[2..]);
            try files.append(allocator, .{ .changed = file });
        } else if (std.mem.startsWith(u8, line, "2 ")) {
            const file = try CLIStatus.CopiedOrRenamedFile.parse(line[2..]);
            try files.append(allocator, .{ .copied_or_renamed = file });
        } else if (std.mem.startsWith(u8, line, "u ")) {
            const file = try CLIStatus.UnmergedFile.parse(line[2..]);
            try files.append(allocator, .{ .unmerged = file });
        } else if (std.mem.startsWith(u8, line, "? ")) {
            const file = CLIStatus.UntrackedFile.parse(line[2..]);
            try files.append(allocator, .{ .untracked_file = file });
        } else if (std.mem.startsWith(u8, line, "! ")) {
            const file = CLIStatus.IgnoredFile.parse(line[2..]);
            try files.append(allocator, .{ .ignored_file = file });
        }
    }

    stat.*.files = try files.toOwnedSlice(allocator);
    return stat;
}

pub fn unstage(allocator: std.mem.Allocator, paths: []const []const u8) !void {
    const args = try std.mem.concat(allocator, []const []const u8, &[_][]const []const u8{
        &[_][]const u8{ "git", "reset", "HEAD", "--" },
        paths,
    });
    defer allocator.free(args);

    var child = std.process.Child(args, allocator);
    try child.spawn();
    _ = try child.wait();
}

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

    pub fn commit(self: Self, message: [:0]const u8) err.GitError!void {
        var oid: c.git_oid = undefined;
        try err.wrap_git(c.git_commit_create_from_stage(
            &oid,
            self.repo,
            message,
            null,
        ));
    }

    pub fn head(self: Self) err.GitError!Ref {
        var ref: Ref = .{ .reference = undefined };
        try err.wrap_git(c.git_repository_head(&ref.reference, self.repo));
        return ref;
    }

    pub fn index(self: Self) err.GitError!Index {
        var idx: Index = .{ .repo = self, .index = undefined };
        try err.wrap_git(c.git_repository_index(&idx.index, self.repo));
        return idx;
    }

    pub fn remote(self: Self, name: [:0]const u8) err.GitError!Remote {
        var rmt: Remote = .{ .repo = self, .remote = undefined };
        try err.wrap_git(c.git_remote_lookup(&rmt.remote, self.repo, name));
        return rmt;
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

pub const Commit = struct {
    const Self = @This();

    commit: ?*c.git_commit,

    pub fn deinit(self: Self) void {
        c.git_commit_free(self.commit);
    }

    pub fn sha(self: Self) [c.GIT_OID_HEXSZ]u8 {
        const oid = c.git_object_id(@ptrCast(self.commit));
        var sha_str: [c.GIT_OID_HEXSZ]u8 = undefined;
        _ = c.git_oid_tostr(&sha_str, c.GIT_OID_HEXSZ, oid);
        return sha_str;
    }

    pub fn title(self: Self) []const u8 {
        const title_ptr = c.git_commit_summary(self.commit);
        const len = c.strlen(title_ptr);
        return title_ptr[0..len];
    }
};

pub const Ref = struct {
    const Self = @This();

    reference: ?*c.git_reference,

    pub fn deinit(self: Self) void {
        c.git_reference_free(self.reference);
    }

    pub fn commit(self: Self) err.GitError!Commit {
        var object = Commit{ .commit = undefined };
        try err.wrap_git(c.git_reference_peel(
            &object.commit,
            self.reference,
            c.GIT_OBJECT_COMMIT,
        ));
        return object;
    }

    pub fn branch_name(self: Self) err.GitError![]const u8 {
        var branch_name_ptr: [*c]const u8 = undefined;
        try err.wrap_git(c.git_branch_name(&branch_name_ptr, self.reference));
        const len = c.strlen(branch_name_ptr);
        return branch_name_ptr[0..len];
    }
};

const Remote = struct {
    const Self = @This();

    repo: Repo,
    remote: ?*c.git_remote,

    // TODO: clean up and debug this AI slop :)
    pub fn push(self: Self) err.GitError!void {
        var opts: c.git_push_options = undefined;
        try err.wrap_git(c.git_push_options_init(&opts, c.GIT_PUSH_OPTIONS_VERSION));
        opts.callbacks.credentials = Remote.credentials_callback;
        opts.callbacks.push_update_reference = Remote.push_update_reference_callback;

        // Get current branch
        const head = try self.repo.head();
        defer head.deinit();
        const branch = try head.branch_name();

        // Build refspec for current branch
        var refspec_buf: [256]u8 = undefined;
        const refspec = std.fmt.bufPrintZ(
            &refspec_buf,
            "refs/heads/{s}:refs/heads/{s}",
            .{ branch, branch },
        ) catch @panic("Oh no");

        var refspecs = [_][*c]const u8{refspec.ptr};
        var refspecs_array = c.git_strarray{
            .strings = @ptrCast(&refspecs),
            .count = 1,
        };

        try err.wrap_git(c.git_remote_push(
            self.remote,
            &refspecs_array,
            &opts,
        ));
    }

    fn push_update_reference_callback(
        refname: [*c]const u8,
        status: [*c]const u8,
        data: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = refname;
        _ = data;
        if (status != null) {
            // Push failed with a status message
            return -1;
        }
        return 0;
    }

    fn credentials_callback(
        out: [*c][*c]c.git_credential,
        url: [*c]const u8,
        username_from_url: [*c]const u8,
        allowed_types: c_uint,
        payload: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = url;
        _ = payload;

        if (allowed_types & c.GIT_CREDTYPE_SSH_KEY > 0) {
            return c.git_credential_ssh_key_from_agent(out, username_from_url);
        }

        return -1;
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

    pub fn unstaged(self: Self) ?DiffDelta {
        if (self.status_entry.*.index_to_workdir == null) {
            return null;
        }
        return .{ .diff_delta = self.status_entry.*.index_to_workdir };
    }

    pub fn staged(self: Self) ?DiffDelta {
        if (self.status_entry.*.head_to_index == null) {
            return null;
        }
        return .{ .diff_delta = self.status_entry.*.head_to_index };
    }
};

pub const DiffDelta = struct {
    const Self = @This();

    diff_delta: [*c]const c.git_diff_delta,

    pub fn status(self: Self) Status {
        return @enumFromInt(self.diff_delta.*.status);
    }

    pub fn path(self: Self) [:0]const u8 {
        const len = c.strlen(self.diff_delta.*.new_file.path);
        return self.diff_delta.*.new_file.path[0..len :0];
    }

    pub const Status = enum(c_uint) {
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

        pub fn name(self: Status) [:0]const u8 {
            switch (self) {
                .Unmodified => return "unmodified",
                .Added => return "added",
                .Deleted => return "deleted",
                .Modified => return "modified",
                .Renamed => return "renamed",
                .Copied => return "copied",
                .Ignored => return "ignored",
                .Untracked => return "untracked",
                .TypeChange => return "typechange",
                .Unreadable => return "unreadable",
                .Conflicted => return "conflicted",
            }
        }
    };
};

pub const Index = struct {
    const Self = @This();

    const UnstageContext = {};

    repo: Repo,
    index: ?*c.git_index,

    pub fn deinit(self: Self) void {
        c.git_index_free(self.index);
    }

    pub fn unstage_file(self: Self, path: [:0]const u8) err.GitError!void {
        // TODO: instead of doing this for *every* unstage,
        // we could make most of this context ahead of time for bulk operations.
        const head = try self.repo.head();
        defer head.deinit();

        const head_commit = try head.commit();

        var tree: ?*c.git_tree = undefined;
        try err.wrap_git(c.git_commit_tree(&tree, head_commit.commit));
        defer c.git_tree_free(tree);

        var tree_entry: ?*c.git_tree_entry = undefined;
        err.wrap_git(c.git_tree_entry_bypath(&tree_entry, tree, path)) catch |e| {
            if (e == err.GitError.NotFound) {
                try err.wrap_git(c.git_index_remove_bypath(self.index, path));
                return;
            }
            return e;
        };
        defer c.git_tree_entry_free(tree_entry);

        const object_id = c.git_tree_entry_id(tree_entry);
        const filemode = c.git_tree_entry_filemode(tree_entry);

        var index_entry: c.git_index_entry = std.mem.zeroes(c.git_index_entry);
        index_entry.path = path;
        index_entry.id = object_id.*;
        index_entry.mode = filemode;

        try err.wrap_git(c.git_index_add(self.index, &index_entry));
    }

    pub fn stage(self: Self, diff_delta: DiffDelta) err.GitError!void {
        const path = diff_delta.path();
        if (diff_delta.status() == .Deleted) {
            try err.wrap_git(c.git_index_remove_bypath(self.index, path));
        } else {
            try err.wrap_git(c.git_index_add_bypath(self.index, path));
        }
    }

    pub fn write(self: Self) err.GitError!void {
        try err.wrap_git(c.git_index_write(self.index));
    }
};
