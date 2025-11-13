const std = @import("std");
const posix = std.posix;

const git = @import("git.zig");
const term = @import("term.zig");

// TODOs:
//
// - When highlighting a line, make the background go to the end of the line.
//   Don't just stop at the end of the text.

pub const FileItem = struct {
    path: []const u8,
    status_name: []const u8,
};

pub const Section = enum {
    head,
    untracked,
    unstaged,
    staged,
};

pub const RepoState = struct {
    const Self = @This();

    git_status: *git.Status,
    staged: std.ArrayList(FileItem),
    unstaged: std.ArrayList(FileItem),
    untracked: std.ArrayList(FileItem),

    pub fn init(allocator: std.mem.Allocator) !Self {
        const git_status = try git.status(allocator);
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

        return .{
            .git_status = git_status,
            .staged = staged,
            .unstaged = unstaged,
            .untracked = untracked,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.git_status.deinit();
        self.staged.deinit(allocator);
        self.unstaged.deinit(allocator);
        self.untracked.deinit(allocator);
    }
};

pub const UserState = struct {
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

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.debug_output) |debug_output| {
            self.allocator.free(debug_output);
        }
    }
};

pub fn paint(
    allocator: std.mem.Allocator,
    user_state: *const UserState,
    repo_state: *const RepoState,
    stdout: std.fs.File,
) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buf);
    var writer = &stdout_writer.interface;
    defer writer.flush() catch {};
    const pretty = Pretty{ .writer = writer };

    // Clear screen and move cursor to home
    try writer.writeAll("\x1b[2J\x1b[H");

    try paint_refs(allocator, user_state, repo_state, pretty);
    try paint_delta(user_state, pretty, "Untracked files", repo_state.untracked, .untracked);
    try paint_delta(user_state, pretty, "Unstaged files", repo_state.unstaged, .unstaged);
    try paint_delta(user_state, pretty, "Staged files", repo_state.staged, .staged);

    if (user_state.debug_output) |debug_output| {
        try writer.print("{s}\n\r", .{debug_output});
    }
}

fn paint_refs(
    allocator: std.mem.Allocator,
    user_state: *const UserState,
    repo_state: *const RepoState,
    pretty: Pretty,
) !void {
    const branch_head = repo_state.git_status.branch_head orelse "(detached)";

    const base_style = highlight_style(user_state, .head, 0);
    try pretty.printStyled("  Head: ", base_style, .{});

    // Get commit SHA and title from git log
    var child = std.process.Child.init(
        &[_][]const u8{ "git", "log", "-1", "--format=%h %s" },
        allocator,
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
    user_state: *const UserState,
    pretty: Pretty,
    header: []const u8,
    items: std.ArrayList(FileItem),
    section: Section,
) !void {
    const expanded = switch (section) {
        .untracked => user_state.untracked_expanded,
        .unstaged => user_state.unstaged_expanded,
        .staged => user_state.staged_expanded,
        else => unreachable,
    };

    {
        const base_style = highlight_style(user_state, section, 0);
        try pretty.printStyled("{s} ", base_style, .{prefix(expanded)});
        try pretty.printStyled(
            "{s}",
            base_style.add(.{ .bold = true, .foreground = .mauve }),
            .{header},
        );
        try pretty.printStyled(" ({d})\n\r", base_style, .{items.items.len});
    }

    if (expanded) {
        for (1.., items.items) |i, item| {
            const base_style = highlight_style(user_state, section, i);
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

fn highlight_style(user_state: *const UserState, section: Section, pos: usize) Style {
    if (user_state.section == section and user_state.pos == pos) {
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
