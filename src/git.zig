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
