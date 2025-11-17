const std = @import("std");

const err = @import("err.zig");

pub const FileItem = struct {
    path: []const u8,
    status_name: []const u8,
};

/// State represents the unified state of the Git repo.
pub const State = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    branch_refs: std.ArrayList(Ref),
    git_status: *Status,
    staged: std.ArrayList(FileItem),
    unstaged: std.ArrayList(FileItem),
    untracked: std.ArrayList(FileItem),

    pub fn build(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var branch_refs = try branch(allocator);
        errdefer {
            for (branch_refs.items) |branch_ref| {
                branch_ref.deinit(allocator);
            }
            branch_refs.deinit(allocator);
        }

        const git_status = try status(allocator);
        errdefer git_status.deinit();

        var staged = std.ArrayList(FileItem).empty;
        errdefer staged.deinit(allocator);

        var unstaged = std.ArrayList(FileItem).empty;
        errdefer unstaged.deinit(allocator);

        var untracked = std.ArrayList(FileItem).empty;
        errdefer untracked.deinit(allocator);

        for (git_status.files) |file| {
            switch (file) {
                .changed => |changed| {
                    const x_is_staged = changed.xy.x != .unmodified;
                    const y_is_unstaged = changed.xy.y != .unmodified;

                    if (x_is_staged) {
                        try staged.append(allocator, .{
                            .path = changed.path,
                            .status_name = changed.xy.x.name(),
                        });
                    }
                    if (y_is_unstaged) {
                        try unstaged.append(allocator, .{
                            .path = changed.path,
                            .status_name = changed.xy.y.name(),
                        });
                    }
                },
                .copied_or_renamed => |copied_or_renamed| {
                    const x_is_staged = copied_or_renamed.xy.x != .unmodified;
                    const y_is_unstaged = copied_or_renamed.xy.y != .unmodified;

                    if (x_is_staged) {
                        try staged.append(allocator, .{
                            .path = copied_or_renamed.path,
                            .status_name = copied_or_renamed.xy.x.name(),
                        });
                    }
                    if (y_is_unstaged) {
                        try unstaged.append(allocator, .{
                            .path = copied_or_renamed.path,
                            .status_name = copied_or_renamed.xy.y.name(),
                        });
                    }
                },
                .unmerged => |unmerged| {
                    try unstaged.append(allocator, .{
                        .path = unmerged.path,
                        .status_name = "unmerged",
                    });
                },
                .untracked_file => |untracked_file| {
                    try untracked.append(allocator, .{
                        .path = untracked_file.path,
                        .status_name = "untracked",
                    });
                },
                .ignored_file => {},
            }
        }

        self.* = .{
            .allocator = allocator,
            .branch_refs = branch_refs,
            .git_status = git_status,
            .staged = staged,
            .unstaged = unstaged,
            .untracked = untracked,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.branch_refs.items) |branch_ref| {
            branch_ref.deinit(self.allocator);
        }
        self.branch_refs.deinit(self.allocator);
        self.git_status.deinit();
        self.staged.deinit(self.allocator);
        self.unstaged.deinit(self.allocator);
        self.untracked.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

pub const Ref = struct {
    const Self = @This();

    is_head: bool,
    objectname: []const u8,
    refname: []const u8,
    subject: []const u8,
    upstream: []const u8,

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.objectname);
        allocator.free(self.refname);
        allocator.free(self.subject);
        allocator.free(self.upstream);
    }
};

pub fn branch(allocator: std.mem.Allocator) !std.ArrayList(Ref) {
    var child = std.process.Child.init(
        &[_][]const u8{
            "git",
            "branch",
            "--format=%(if)%(HEAD)%(then)+%(else)-%(end)\t%(objectname)\t%(refname)\t%(contents:subject)\t%(upstream)",
        },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    try child.spawn();

    const output = try child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(output);

    var refs = std.ArrayList(Ref).empty;
    var lines = std.mem.splitAny(u8, output, "\n\r");
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }

        var segments = std.mem.splitScalar(u8, line, '\t');

        const head_marker = segments.next().?;
        const objectname = segments.next().?;
        const refname = segments.next().?;
        const subject = segments.next().?;
        const upstream = segments.next().?;

        try refs.append(
            allocator,
            .{
                .is_head = head_marker[0] == '+',
                .objectname = try allocator.dupe(u8, objectname),
                .refname = try allocator.dupe(u8, refname),
                .subject = try allocator.dupe(u8, subject),
                .upstream = try allocator.dupe(u8, upstream),
            },
        );
    }

    _ = try child.wait();
    return refs;
}

pub fn commit(allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(
        &[_][]const u8{ "git", "commit" },
        allocator,
    );
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    _ = try child.wait();
}

pub fn push(allocator: std.mem.Allocator, remote: []const u8, branch_name: []const u8) !void {
    var child = std.process.Child.init(
        &[_][]const u8{ "git", "push", remote, branch_name },
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

pub const Status = struct {
    const Self = @This();

    pub const ChangeType = enum {
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

        pub fn name(self: ChangeType) []const u8 {
            return switch (self) {
                .added => "added",
                .copied => "copied",
                .deleted => "deleted",
                .file_type_change => "typechange",
                .modified => "modified",
                .renamed => "renamed",
                .unmodified => "unmodified",
                .updated_unmerged => "unmerged",
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
    const File = union(enum) {
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

pub fn status(allocator: std.mem.Allocator) !*Status {
    const stat = try allocator.create(Status);
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

    var files = std.ArrayList(Status.File).empty;
    errdefer files.deinit(allocator);

    var lines = std.mem.splitScalar(u8, stat.*.contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# branch.head")) {
            stat.*.branch_head = line["# branch.head ".len..];
        } else if (std.mem.startsWith(u8, line, "# branch.upstream")) {
            stat.*.branch_upstream = line["# branch.upstream ".len..];
        } else if (std.mem.startsWith(u8, line, "1 ")) {
            const file = try Status.ChangedFile.parse(line[2..]);
            try files.append(allocator, .{ .changed = file });
        } else if (std.mem.startsWith(u8, line, "2 ")) {
            const file = try Status.CopiedOrRenamedFile.parse(line[2..]);
            try files.append(allocator, .{ .copied_or_renamed = file });
        } else if (std.mem.startsWith(u8, line, "u ")) {
            const file = try Status.UnmergedFile.parse(line[2..]);
            try files.append(allocator, .{ .unmerged = file });
        } else if (std.mem.startsWith(u8, line, "? ")) {
            const file = Status.UntrackedFile.parse(line[2..]);
            try files.append(allocator, .{ .untracked_file = file });
        } else if (std.mem.startsWith(u8, line, "! ")) {
            const file = Status.IgnoredFile.parse(line[2..]);
            try files.append(allocator, .{ .ignored_file = file });
        }
    }

    stat.*.files = try files.toOwnedSlice(allocator);
    return stat;
}

pub fn unstage(allocator: std.mem.Allocator, paths: []const []const u8) !void {
    const args = try std.mem.concat(allocator, []const u8, &[_][]const []const u8{
        &[_][]const u8{ "git", "reset", "HEAD", "--" },
        paths,
    });
    defer allocator.free(args);

    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = try child.wait();
}
