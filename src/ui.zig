const std = @import("std");
const posix = std.posix;

const git = @import("git.zig");
const term = @import("term.zig");

// TODOs:
//
// - When highlighting a line, make the background go to the end of the line.
//   Don't just stop at the end of the text.

const RepoStatus = struct {
    repo: *const git.Repo,
    status_list: git.StatusList,
    staged: std.ArrayList(git.DiffDelta),
    unstaged: std.ArrayList(git.DiffDelta),
    untracked: std.ArrayList(git.DiffDelta),

    fn deinit(self: *RepoStatus, allocator: std.mem.Allocator) void {
        self.status_list.deinit();
        self.staged.deinit(allocator);
        self.unstaged.deinit(allocator);
        self.untracked.deinit(allocator);
    }
};

pub const Interface = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    original_termios: posix.termios,
    repo: git.Repo,
    repo_status: ?RepoStatus,
    state: State,
    stdin: std.fs.File,
    stdout: std.fs.File,

    pub fn init(allocator: std.mem.Allocator, repo: git.Repo) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .original_termios = try term.enter_raw_mode(),
            .repo = repo,
            .repo_status = null,
            .state = .{ .pos = 0, .section = .head },
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.repo_status) |*status| {
            status.deinit(self.allocator);
        }
        term.restore(self.original_termios) catch {};
        self.allocator.destroy(self);
    }

    pub fn update(self: *Self) !void {
        const status_list = try self.repo.status();
        errdefer status_list.deinit();

        var staged = std.ArrayList(git.DiffDelta).empty;
        errdefer staged.deinit(self.allocator);

        var unstaged = std.ArrayList(git.DiffDelta).empty;
        errdefer unstaged.deinit(self.allocator);

        var untracked = std.ArrayList(git.DiffDelta).empty;
        errdefer untracked.deinit(self.allocator);

        var iter = status_list.iter();
        while (try iter.next()) |entry| {
            if (entry.staged()) |staged_diff| {
                try staged.append(self.allocator, staged_diff);
            }
            if (entry.unstaged()) |unstaged_diff| {
                if (unstaged_diff.status() == .Untracked) {
                    try untracked.append(self.allocator, unstaged_diff);
                } else {
                    try unstaged.append(self.allocator, unstaged_diff);
                }
            }
        }

        if (self.repo_status) |*repo_status| {
            repo_status.deinit(self.allocator);
        }
        self.repo_status = .{
            .repo = &self.repo,
            .status_list = status_list,
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
            if (std.mem.eql(u8, slice, "\x1b[B")) {
                break :blk .down;
            }
            if (std.mem.eql(u8, slice, "q")) {
                break :blk .quit;
            }
            if (std.mem.eql(u8, slice, "s")) {
                break :blk .stage;
            }
            if (std.mem.eql(u8, slice, "\x09")) {
                break :blk .toggle_expand;
            }
            if (std.mem.eql(u8, slice, "u")) {
                break :blk .unstage;
            }
            if (std.mem.eql(u8, slice, "\x1b[A")) {
                break :blk .up;
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
    }

    fn paint_refs(self: *const Self, pretty: Pretty) !void {
        const head = try self.repo.head();
        defer head.deinit();

        const commit = try head.commit();
        defer commit.deinit();

        const base_style = self.highlight_style(.head, 0);
        try pretty.printStyled("  Head: ", base_style, .{});
        try pretty.printStyled(
            "{s} ",
            base_style.add(.{ .foreground = .sky }),
            .{commit.sha()[0..8]},
        );
        {
            const branch_name = try head.branch_name();
            const style = blk: {
                if (std.mem.startsWith(u8, branch_name, "origin/")) {
                    break :blk base_style.add(.{ .foreground = .green });
                }
                break :blk base_style.add(.{ .foreground = .peach });
            };
            try pretty.printStyled(
                "{s} ",
                style,
                .{branch_name},
            );
        }
        try pretty.printStyled(
            "{s}\n\r\n\r",
            base_style,
            .{commit.title()},
        );
    }

    fn paint_delta(
        self: *const Self,
        pretty: Pretty,
        header: []const u8,
        deltas: std.ArrayList(git.DiffDelta),
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
            try pretty.printStyled(" ({d})\n\r", base_style, .{deltas.items.len});
        }

        if (expanded) {
            for (1.., deltas.items) |i, delta| {
                const base_style = self.highlight_style(section, i);
                try pretty.printStyled("> ", base_style, .{});
                try pretty.printStyled(
                    "{s}",
                    base_style.add(.{ .bold = true, .foreground = .blue }),
                    .{delta.status().name()},
                );
                try pretty.printStyled("    {s}\n\r", base_style, .{delta.diff_delta.*.new_file.path});
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

    pos: usize = 0,
    section: Section = .head,
    untracked_expanded: bool = true,
    unstaged_expanded: bool = true,
    staged_expanded: bool = true,

    const Input = enum {
        down,
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

    // TODO: When I stage/unstage, I don't check that the `pos` is valid
    // w.r.t. the number of remaining elements in the untracked/unstaged/staged list.
    fn handle_input(self: *Self, repo_status: *const RepoStatus, input: Input) !bool {
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
                const idx = try repo_status.repo.index();
                defer idx.deinit();

                if (self.pos == 0) {
                    for (repo_status.untracked.items) |delta| {
                        try idx.stage_file(delta.path());
                    }
                } else {
                    const delta = repo_status.untracked.items[self.pos - 1];
                    try idx.stage_file(delta.path());
                }
                try idx.write();
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
                const idx = try repo_status.repo.index();
                defer idx.deinit();

                if (self.pos == 0) {
                    for (repo_status.unstaged.items) |delta| {
                        try idx.stage_file(delta.path());
                    }
                } else {
                    const delta = repo_status.unstaged.items[self.pos - 1];
                    try idx.stage_file(delta.path());
                }
                try idx.write();
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
                const idx = try repo_status.repo.index();
                defer idx.deinit();

                if (self.pos == 0) {
                    for (repo_status.staged.items) |delta| {
                        try idx.unstage_file(delta.path());
                    }
                } else {
                    const delta = repo_status.staged.items[self.pos - 1];
                    try idx.unstage_file(delta.path());
                }
                try idx.write();
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
