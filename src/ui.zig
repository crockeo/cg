const std = @import("std");
const posix = std.posix;

const git = @import("git.zig");
const term = @import("term.zig");

// TODOs:
//
// - When highlighting a line, make the background go to the end of the line.
//   Don't just stop at the end of the text.

const CORNER_TOP_LEFT = "╭";
const CORNER_TOP_RIGHT = "╮";
const CORNER_BOTTOM_LEFT = "╰";
const CORNER_BOTTOM_RIGHT = "╯";
const EDGE_HORIZONTAL = "─";
const EDGE_VERTICAL = "│";

pub fn paint_box(
    writer: *std.io.Writer,
    title: ?[]const u8,
    row: usize,
    col: usize,
    width: usize,
    height: usize,
) error{WriteFailed}!void {
    for (row..row + height) |i| {
        try term.go_to_pos(writer, i, col);

        const start_str = blk: {
            if (i == row) {
                break :blk CORNER_TOP_LEFT;
            }
            if (i == row + height - 1) {
                break :blk CORNER_BOTTOM_LEFT;
            }
            break :blk EDGE_VERTICAL;
        };
        const end_str = blk: {
            if (i == row) {
                break :blk CORNER_TOP_RIGHT;
            }
            if (i == row + height - 1) {
                break :blk CORNER_BOTTOM_RIGHT;
            }
            break :blk EDGE_VERTICAL;
        };
        const fill_str = blk: {
            if (i == row or i == row + height - 1) {
                break :blk EDGE_HORIZONTAL;
            }
            break :blk " ";
        };

        try writer.writeAll(start_str);
        if (i == row and title != null) {
            try writer.writeAll(fill_str);
            try writer.writeAll(" ");
            try writer.writeAll(title.?);
            try writer.writeAll(" ");
            // 5 here =
            // - 2 for the start + end str
            // - 1 for the preceding fill str
            // - 2 for the spaces
            for (0..width - 5 - title.?.len) |_| {
                try writer.writeAll(fill_str);
            }
        } else {
            for (0..width - 2) |_| {
                try writer.writeAll(fill_str);
            }
        }
        try writer.writeAll(end_str);
    }
}

pub const Section = enum {
    head,
    untracked,
    unstaged,
    staged,
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
    user_state: *const UserState,
    repo_state: *const git.State,
    stdout: std.fs.File,
) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buf);
    var writer = &stdout_writer.interface;
    defer writer.flush() catch {};
    const pretty = Pretty{ .writer = writer };

    // Clear screen and move cursor to home
    try writer.writeAll("\x1b[2J\x1b[H");

    try paint_refs(user_state, repo_state, pretty);
    try paint_delta(user_state, pretty, "Untracked files", repo_state.untracked, .untracked);
    try paint_delta(user_state, pretty, "Unstaged files", repo_state.unstaged, .unstaged);
    try paint_delta(user_state, pretty, "Staged files", repo_state.staged, .staged);

    if (user_state.debug_output) |debug_output| {
        try writer.print("{s}\n\r", .{debug_output});
    }
}

fn paint_refs(
    user_state: *const UserState,
    repo_state: *const git.State,
    pretty: Pretty,
) !void {
    const branch_head = repo_state.git_status.branch_head orelse "(detached)";

    const base_style = highlight_style(user_state, .head, 0);
    try pretty.printStyled("  Head: ", base_style, .{});

    const head_ref = blk: {
        for (repo_state.branch_refs.items) |ref| {
            if (ref.is_head) {
                break :blk ref;
            }
        }
        return;
    };

    const sha = head_ref.objectname[0..8];
    const title = head_ref.subject;

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
    items: std.ArrayList(git.FileItem),
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

pub const Pretty = struct {
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

pub const Style = struct {
    const Self = @This();

    pub const default = Self{};
    pub const highlighted = Self{ .background = .mantle };

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

pub const Color = struct {
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
