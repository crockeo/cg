const std = @import("std");
const posix = std.posix;

const git = @import("git.zig");
const term = @import("term.zig");

// TODOs:
//
// - When highlighting a line, make the background go to the end of the line.
//   Don't just stop at the end of the text.

const FileItem = struct {
    path: []const u8,
    status_name: []const u8,
};

fn change_type_name(change_type: git.Status.ChangeType) []const u8 {
    return switch (change_type) {
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

const RepoStatus = struct {
    cli_status: *git.Status,
    staged: std.ArrayList(FileItem),
    unstaged: std.ArrayList(FileItem),
    untracked: std.ArrayList(FileItem),

    fn deinit(self: *RepoStatus, allocator: std.mem.Allocator) void {
        self.cli_status.deinit();
        self.staged.deinit(allocator);
        self.unstaged.deinit(allocator);
        self.untracked.deinit(allocator);
    }
};

pub const Interface = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    original_termios: posix.termios,
    repo_status: ?RepoStatus,
    state: State,
    stdin: std.fs.File,
    stdout: std.fs.File,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .original_termios = try term.enter_raw_mode(),
            .repo_status = null,
            .state = .{ .allocator = allocator },
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.repo_status) |*status| {
            status.deinit(self.allocator);
        }
        self.state.deinit();
        term.restore(self.original_termios) catch {};
        self.allocator.destroy(self);
    }

    pub fn update(self: *Self) !void {
        const cli_status = try git.status(self.allocator);
        errdefer cli_status.deinit();

        var staged = std.ArrayList(FileItem).empty;
        errdefer staged.deinit(self.allocator);

        var unstaged = std.ArrayList(FileItem).empty;
        errdefer unstaged.deinit(self.allocator);

        var untracked = std.ArrayList(FileItem).empty;
        errdefer untracked.deinit(self.allocator);

        for (cli_status.files) |file| {
            switch (file) {
                .changed => |changed| {
                    const x_is_staged = changed.xy.x != .unmodified;
                    const y_is_unstaged = changed.xy.y != .unmodified;

                    if (x_is_staged) {
                        try staged.append(self.allocator, .{
                            .path = changed.path,
                            .status_name = change_type_name(changed.xy.x),
                        });
                    }
                    if (y_is_unstaged) {
                        try unstaged.append(self.allocator, .{
                            .path = changed.path,
                            .status_name = change_type_name(changed.xy.y),
                        });
                    }
                },
                .copied_or_renamed => |copied_or_renamed| {
                    const x_is_staged = copied_or_renamed.xy.x != .unmodified;
                    const y_is_unstaged = copied_or_renamed.xy.y != .unmodified;

                    if (x_is_staged) {
                        try staged.append(self.allocator, .{
                            .path = copied_or_renamed.path,
                            .status_name = change_type_name(copied_or_renamed.xy.x),
                        });
                    }
                    if (y_is_unstaged) {
                        try unstaged.append(self.allocator, .{
                            .path = copied_or_renamed.path,
                            .status_name = change_type_name(copied_or_renamed.xy.y),
                        });
                    }
                },
                .unmerged => |unmerged| {
                    try unstaged.append(self.allocator, .{
                        .path = unmerged.path,
                        .status_name = "unmerged",
                    });
                },
                .untracked_file => |untracked_file| {
                    try untracked.append(self.allocator, .{
                        .path = untracked_file.path,
                        .status_name = "untracked",
                    });
                },
                .ignored_file => {},
            }
        }

        if (self.repo_status) |*repo_status| {
            repo_status.deinit(self.allocator);
        }
        self.repo_status = .{
            .cli_status = cli_status,
            .staged = staged,
            .unstaged = unstaged,
            .untracked = untracked,
        };
    }

    pub fn handle_input(self: *Self) !bool {
        const repo_status = self.repo_status orelse return error.NoRepoStatus;

        var buf: [16]u8 = undefined;
        const len = try self.stdin.read(&buf);
        const slice = buf[0..len];

        const input: ?State.Input = blk: {
            for ([_]struct { haystack: []const u8, input: State.Input }{
                .{ .haystack = "c", .input = .commit },
                .{ .haystack = "\x1b[B", .input = .down },
                .{ .haystack = "p", .input = .push },
                .{ .haystack = "q", .input = .quit },
                .{ .haystack = "s", .input = .stage },
                .{ .haystack = "\x09", .input = .toggle_expand },
                .{ .haystack = "u", .input = .unstage },
                .{ .haystack = "\x1b[A", .input = .up },
            }) |possible_input| {
                if (std.mem.eql(u8, slice, possible_input.haystack)) {
                    break :blk possible_input.input;
                }
            }
            break :blk null;
        };
        if (input) |confirmed_input| {
            return self.state.handle_input(&repo_status, confirmed_input);
        }
        return false;
    }

    pub fn paint(self: *Self) !void {
        const repo_status = self.repo_status orelse return error.NoRepoStatus;

        var stdout_buf: [1024]u8 = undefined;
        var stdout_writer = self.stdout.writer(&stdout_buf);
        var writer = &stdout_writer.interface;
        defer writer.flush() catch {};
        const pretty = Pretty{ .writer = writer };

        // Clear screen and move cursor to home
        try writer.writeAll("\x1b[2J\x1b[H");

        try self.paint_refs(pretty);
        try self.paint_delta(pretty, "Untracked files", repo_status.untracked, .untracked);
        try self.paint_delta(pretty, "Unstaged files", repo_status.unstaged, .unstaged);
        try self.paint_delta(pretty, "Staged files", repo_status.staged, .staged);

        if (self.state.debug_output) |debug_output| {
            try writer.print("{s}\n\r", .{debug_output});
        }
    }

    fn paint_refs(self: *const Self, pretty: Pretty) !void {
        const repo_status = self.repo_status orelse return error.NoRepoStatus;
        const branch_head = repo_status.cli_status.branch_head orelse "(detached)";

        const base_style = self.highlight_style(.head, 0);
        try pretty.printStyled("  Head: ", base_style, .{});

        // Get commit SHA and title from git log
        var child = std.process.Child.init(
            &[_][]const u8{ "git", "log", "-1", "--format=%h %s" },
            self.allocator,
        );
        child.stdout_behavior = .Pipe;
        try child.spawn();

        const stdout = child.stdout orelse return error.NoStdout;
        var buf: [1024]u8 = undefined;
        const len = try stdout.read(&buf);
        _ = try child.wait();

        const output = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);
        var it = std.mem.splitScalar(u8, output, ' ');
        const sha = it.next() orelse "";
        const title = it.rest();

        try pretty.printStyled(
            "{s} ",
            base_style.add(.{ .foreground = .sky }),
            .{sha},
        );
        {
            const style = blk: {
                if (std.mem.startsWith(u8, branch_head, "origin/")) {
                    break :blk base_style.add(.{ .foreground = .green });
                }
                break :blk base_style.add(.{ .foreground = .peach });
            };
            try pretty.printStyled(
                "{s} ",
                style,
                .{branch_head},
            );
        }
        try pretty.printStyled(
            "{s}\n\r\n\r",
            base_style,
            .{title},
        );
    }

    fn paint_delta(
        self: *const Self,
        pretty: Pretty,
        header: []const u8,
        items: std.ArrayList(FileItem),
        section: State.Section,
    ) !void {
        const expanded = switch (section) {
            .untracked => self.state.untracked_expanded,
            .unstaged => self.state.unstaged_expanded,
            .staged => self.state.staged_expanded,
            else => unreachable,
        };

        {
            const base_style = self.highlight_style(section, 0);
            try pretty.printStyled("{s} ", base_style, .{Self.prefix(expanded)});
            try pretty.printStyled(
                "{s}",
                base_style.add(.{ .bold = true, .foreground = .mauve }),
                .{header},
            );
            try pretty.printStyled(" ({d})\n\r", base_style, .{items.items.len});
        }

        if (expanded) {
            for (1.., items.items) |i, item| {
                const base_style = self.highlight_style(section, i);
                try pretty.printStyled("> ", base_style, .{});
                try pretty.printStyled(
                    "{s}",
                    base_style.add(.{ .bold = true, .foreground = .blue }),
                    .{item.status_name},
                );
                try pretty.printStyled("    {s}\n\r", base_style, .{item.path});
            }
        }
        try pretty.print("\n\r", .{});
    }

    fn highlight_style(self: *const Self, section: State.Section, pos: usize) Style {
        if (self.state.section == section and self.state.pos == pos) {
            return .highlighted;
        }
        return .default;
    }

    fn prefix(expanded: bool) []const u8 {
        if (expanded) {
            return "v";
        }
        return ">";
    }
};

const State = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    // NOTE: Since we can't use `std.debug.print`,
    // we can use this field to perform debugging.
    debug_output: ?[]const u8 = null,

    pos: usize = 0,
    section: Section = .head,
    untracked_expanded: bool = true,
    unstaged_expanded: bool = true,
    staged_expanded: bool = true,

    const Input = enum {
        commit,
        down,
        push,
        quit,
        stage,
        toggle_expand,
        unstage,
        up,
    };

    const Section = enum {
        head,
        untracked,
        unstaged,
        staged,
    };

    fn deinit(self: Self) void {
        if (self.debug_output) |debug_output| {
            self.allocator.free(debug_output);
        }
    }

    // TODO: When I stage/unstage, I don't check that the `pos` is valid
    // w.r.t. the number of remaining elements in the untracked/unstaged/staged list.
    fn handle_input(self: *Self, repo_status: *const RepoStatus, input: Input) !bool {
        if (input == .commit and repo_status.staged.items.len > 0) {
            try self.perform_commit();
            return false;
        }
        if (input == .push) {
            // TODO: do this only when we have unpushed commits
            try self.perform_push();
            return false;
        }
        if (input == .quit) {
            return true;
        }
        switch (self.section) {
            .head => return try self.handle_head_input(repo_status, input),
            .untracked => return try self.handle_untracked_input(repo_status, input),
            .unstaged => return try self.handle_unstaged_input(repo_status, input),
            .staged => return try self.handle_staged_input(repo_status, input),
        }
    }

    fn handle_head_input(self: *Self, repo_status: *const RepoStatus, input: Input) !bool {
        _ = repo_status;
        switch (input) {
            .down => {
                self.section = .untracked;
            },
            else => {},
        }
        return false;
    }

    fn handle_untracked_input(self: *Self, repo_status: *const RepoStatus, input: Input) !bool {
        switch (input) {
            .down => {
                const max_pos = blk: {
                    if (!self.untracked_expanded) {
                        break :blk 0;
                    }
                    break :blk repo_status.untracked.items.len;
                };
                if (self.pos >= max_pos) {
                    self.pos = 0;
                    self.section = .unstaged;
                } else {
                    self.pos += 1;
                }
            },
            .stage => {
                if (self.pos == 0 and repo_status.untracked.items.len > 0) {
                    var paths = try self.allocator.alloc([]const u8, repo_status.untracked.items.len);
                    defer self.allocator.free(paths);
                    for (0.., repo_status.untracked.items) |i, item| {
                        paths[i] = item.path;
                    }
                    try git.stage(self.allocator, paths);
                } else if (self.pos > 0) {
                    const item = repo_status.untracked.items[self.pos - 1];
                    try git.stage(self.allocator, &[_][]const u8{item.path});
                    if (self.pos == repo_status.untracked.items.len) {
                        self.pos -= 1;
                    }
                }
            },
            .toggle_expand => {
                self.untracked_expanded = !self.untracked_expanded;
                if (!self.untracked_expanded) {
                    self.pos = 0;
                }
            },
            .up => {
                if (self.pos == 0) {
                    self.section = .head;
                } else {
                    self.pos -= 1;
                }
            },
            else => {},
        }
        return false;
    }

    fn handle_unstaged_input(self: *Self, repo_status: *const RepoStatus, input: Input) !bool {
        switch (input) {
            .down => {
                const max_pos = blk: {
                    if (!self.unstaged_expanded) {
                        break :blk 0;
                    }
                    break :blk repo_status.unstaged.items.len;
                };
                if (self.pos >= max_pos) {
                    self.pos = 0;
                    self.section = .staged;
                } else {
                    self.pos += 1;
                }
            },
            .stage => {
                if (self.pos == 0 and repo_status.unstaged.items.len > 0) {
                    var paths = try self.allocator.alloc([]const u8, repo_status.unstaged.items.len);
                    defer self.allocator.free(paths);
                    for (0.., repo_status.unstaged.items) |i, item| {
                        paths[i] = item.path;
                    }
                    try git.stage(self.allocator, paths);
                } else if (self.pos > 0) {
                    const item = repo_status.unstaged.items[self.pos - 1];
                    try git.stage(self.allocator, &[_][]const u8{item.path});
                    if (self.pos == repo_status.unstaged.items.len) {
                        self.pos -= 1;
                    }
                }
            },
            .toggle_expand => {
                self.unstaged_expanded = !self.unstaged_expanded;
                if (!self.unstaged_expanded) {
                    self.pos = 0;
                }
            },
            .up => {
                if (self.pos > 0) {
                    self.pos -= 1;
                    return false;
                }

                self.section = .untracked;
                if (self.untracked_expanded) {
                    self.pos = repo_status.untracked.items.len;
                } else {
                    self.pos = 0;
                }
            },
            else => {},
        }
        return false;
    }

    fn handle_staged_input(self: *Self, repo_status: *const RepoStatus, input: Input) !bool {
        switch (input) {
            .down => {
                const max_pos = blk: {
                    if (!self.staged_expanded) {
                        break :blk 0;
                    }
                    break :blk repo_status.staged.items.len;
                };
                if (self.pos < max_pos) {
                    self.pos += 1;
                }
            },
            .toggle_expand => {
                self.staged_expanded = !self.staged_expanded;
                if (!self.staged_expanded) {
                    self.pos = 0;
                }
            },
            .unstage => {
                if (self.pos == 0 and repo_status.staged.items.len > 0) {
                    var paths = try self.allocator.alloc([]const u8, repo_status.staged.items.len);
                    defer self.allocator.free(paths);
                    for (0.., repo_status.staged.items) |i, item| {
                        paths[i] = item.path;
                    }
                    try git.unstage(self.allocator, paths);
                } else if (self.pos > 0) {
                    const item = repo_status.staged.items[self.pos - 1];
                    try git.unstage(self.allocator, &[_][]const u8{item.path});
                    if (self.pos == repo_status.staged.items.len) {
                        self.pos -= 1;
                    }
                }
            },
            .up => {
                if (self.pos > 0) {
                    self.pos -= 1;
                    return false;
                }

                self.section = .unstaged;
                if (self.unstaged_expanded) {
                    self.pos = repo_status.unstaged.items.len;
                } else {
                    self.pos = 0;
                }
            },
            else => {},
        }
        return false;
    }

    fn perform_commit(self: *Self) !void {
        try git.commit(self.allocator);
        _ = try term.enter_raw_mode();
    }

    fn perform_push(self: *Self) !void {
        try git.push(self.allocator, "origin", "main");
    }

    fn set_debug_message(self: *Self, debug_message: []const u8) error{OutOfMemory}!void {
        if (self.debug_output) |debug_output| {
            self.allocator.free(debug_output);
        }
        self.debug_output = try self.allocator.dupe(u8, debug_message);
    }
};

const Pretty = struct {
    const Self = @This();

    writer: *std.io.Writer,

    pub fn print(self: Self, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
        try self.writer.print(fmt, args);
        try self.reset();
    }

    pub fn printStyled(
        self: Self,
        comptime fmt: []const u8,
        style: Style,
        args: anytype,
    ) error{WriteFailed}!void {
        try style.start(self.writer);
        try self.writer.print(fmt, args);
        try self.reset();
    }

    fn reset(self: Self) error{WriteFailed}!void {
        try self.writer.writeAll("\x1b[0m");
    }
};

const Style = struct {
    const Self = @This();

    const default = Self{};
    const highlighted = Self{ .background = .mantle };

    background: ?Color = null,
    foreground: ?Color = null,
    bold: bool = false,

    pub fn add(self: Self, other: Self) Self {
        var new = self;
        if (other.background) |background| {
            new.background = background;
        }
        if (other.foreground) |foreground| {
            new.foreground = foreground;
        }
        new.bold = self.bold or other.bold;
        return new;
    }

    fn start(self: Self, writer: *std.io.Writer) error{WriteFailed}!void {
        if (self.bold) {
            try writer.writeAll("\x1b[1m");
        }
        if (self.foreground) |foreground| {
            try writer.writeAll("\x1b[38;2;");
            try foreground.print(writer);
            try writer.writeAll("m");
        }
        if (self.background) |background| {
            try writer.writeAll("\x1b[48;2;");
            try background.print(writer);
            try writer.writeAll("m");
        }
    }
};

const Color = struct {
    const Self = @This();

    r: u8,
    g: u8,
    b: u8,

    pub const base = Self{ .r = 0x24, .g = 0x27, .b = 0x3a };
    pub const blue = Self{ .r = 0x8a, .g = 0xad, .b = 0xf4 };
    pub const crust = Self{ .r = 0x18, .g = 0x19, .b = 0x26 };
    pub const flamingo = Self{ .r = 0xf0, .g = 0xc6, .b = 0xc6 };
    pub const green = Self{ .r = 0xa6, .g = 0xda, .b = 0x95 };
    pub const lavender = Self{ .r = 0xb7, .g = 0xbd, .b = 0xf8 };
    pub const mantle = Self{ .r = 0x1e, .g = 0x20, .b = 0x30 };
    pub const maroon = Self{ .r = 0xee, .g = 0x99, .b = 0xa0 };
    pub const mauve = Self{ .r = 0xc6, .g = 0xa0, .b = 0xf6 };
    pub const peach = Self{ .r = 0xf5, .g = 0xa9, .b = 0x7f };
    pub const pink = Self{ .r = 0xf5, .g = 0xbd, .b = 0xe6 };
    pub const red = Self{ .r = 0xed, .g = 0x87, .b = 0x96 };
    pub const rosewater = Self{ .r = 0xf4, .g = 0xdb, .b = 0xd6 };
    pub const sapphire = Self{ .r = 0x7d, .g = 0xc4, .b = 0xe4 };
    pub const sky = Self{ .r = 0x91, .g = 0xd7, .b = 0xe3 };
    pub const teal = Self{ .r = 0x8b, .g = 0xd5, .b = 0xca };
    pub const text = Self{ .r = 0xca, .g = 0xd3, .b = 0xf5 };
    pub const yellow = Self{ .r = 0xee, .g = 0xd4, .b = 0x9f };

    fn print(self: Self, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.print("{d};{d};{d}", .{ self.r, self.g, self.b });
    }

    fn enable(self: Color, writer: *std.io.Writer) !void {
        try writer.print("\x1b[38;2;{d};{d};{d}m", .{ self.r, self.g, self.b });
    }
};
