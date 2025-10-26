const std = @import("std");
const posix = std.posix;

const git = @import("git.zig");
const term = @import("term.zig");

// TODOs:
//
// - When highlighting a line, make the background go to the end of the line.
//   Don't just stop at the end of the text.
//
// - I need to be able to give the `State` struct the current state of the repo
//   in order to have it be the home of "react to input" actually make sense.

pub const Interface = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    original_termios: posix.termios,
    repo: git.Repo,
    state: State,
    stdin: std.fs.File,
    stdout: std.fs.File,

    pub fn init(allocator: std.mem.Allocator, repo: git.Repo) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .original_termios = try term.enter_raw_mode(),
            .repo = repo,
            .state = .{ .pos = 0, .section = .head },
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        term.restore(self.original_termios) catch {};
        self.allocator.destroy(self);
    }

    pub fn handle_input(self: *Self) !bool {
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
            if (std.mem.eql(u8, slice, "\x09")) {
                break :blk .toggle_expand;
            }
            if (std.mem.eql(u8, slice, "\x1b[A")) {
                break :blk .up;
            }
            break :blk null;
        };
        if (input) |confirmed_input| {
            return self.state.handle_input(confirmed_input);
        }
        return false;
    }

    pub fn paint(self: *Self, allocator: std.mem.Allocator) !void {
        var stdout_buf: [1024]u8 = undefined;
        var stdout_writer = self.stdout.writer(&stdout_buf);
        var writer = &stdout_writer.interface;
        defer writer.flush() catch {};
        const pretty = Pretty{ .writer = writer };

        // Clear screen and move cursor to home
        try writer.writeAll("\x1b[2J\x1b[H");

        const status = try self.repo.status();
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

        try self.paint_refs(pretty);
        try self.paint_delta(pretty, "Untracked files", untracked, .untracked);
        try self.paint_delta(pretty, "Unstaged files", unstaged, .unstaged);
        try self.paint_delta(pretty, "Staged files", staged, .staged);
    }

    fn paint_refs(self: *const Self, pretty: Pretty) !void {
        // TODO: find out how to source the right information for these entries
        // from libgit2
        var styles = [_]Style{ .default, .default, .default };
        if (self.state.section == .head) {
            styles[self.state.pos] = .highlighted;
        }
        try pretty.printStyled(
            "{s} Head:   SHA1 commit message\n\r",
            styles[0],
            .{Self.prefix(self.state.refs_expanded)},
        );
        if (self.state.refs_expanded) {
            try pretty.printStyled("  Merge:  SHA1 commit message\n\r", styles[1], .{});
            try pretty.printStyled("  Push:   SHA1 commit message\n\r", styles[2], .{});
        }
        try pretty.print("\n\r", .{});
    }

    fn paint_delta(
        self: *const Self,
        pretty: Pretty,
        header: []const u8,
        deltas: std.ArrayList(git.DiffDelta),
        section: State.Section,
    ) !void {
        if (deltas.items.len == 0) {
            return;
        }
        const expanded = switch (section) {
            .untracked => self.state.untracked_expanded,
            .unstaged => self.state.unstaged_expanded,
            .staged => self.state.staged_expanded,
            else => unreachable,
        };
        try pretty.print("{s} ", .{Self.prefix(expanded)});
        try pretty.printStyled("{s}", .{ .bold = true, .foreground = .mauve }, .{header});
        try pretty.print(" ({d})\n\r", .{deltas.items.len});

        for (deltas.items) |delta| {
            try pretty.print("> ", .{});
            try pretty.printStyled("{s}", .{ .bold = true, .foreground = .blue }, .{delta.status().name()});
            try pretty.print("    {s}\n\r", .{delta.diff_delta.*.new_file.path});
        }
        try pretty.print("\n\r", .{});
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
    refs_expanded: bool = false,
    untracked_expanded: bool = true,
    unstaged_expanded: bool = true,
    staged_expanded: bool = true,

    const Input = enum {
        down,
        quit,
        toggle_expand,
        up,
    };

    const Section = enum {
        head,
        untracked,
        unstaged,
        staged,
    };

    fn handle_input(self: *Self, input: Input) bool {
        if (input == .quit) {
            return true;
        }
        switch (self.section) {
            .head => return self.handle_head_input(input),
            .untracked => return self.handle_untracked_input(input),
            .unstaged => return self.handle_unstaged_input(input),
            .staged => return self.handle_staged_input(input),
        }
    }

    fn handle_head_input(self: *Self, input: Input) bool {
        switch (input) {
            .down => {
                if (!self.refs_expanded or self.pos >= 2) {
                    self.pos = 0;
                    // TODO: need to make State aware of the current deltas,
                    // and then use this to figure out what the next section is,
                    // because it's not "untracked" when there are no untracked files.
                    self.section = .untracked;
                } else {
                    self.pos += 1;
                }
            },
            .toggle_expand => {
                self.refs_expanded = !self.refs_expanded;
                if (!self.refs_expanded and self.pos > 0) {
                    self.pos = 0;
                }
            },
            .up => {
                if (self.pos > 0) {
                    self.pos -= 1;
                }
            },
            else => {},
        }
        return false;
    }

    fn handle_untracked_input(self: *Self, input: Input) bool {
        _ = self;
        _ = input;
        return false;
    }

    fn handle_unstaged_input(self: *Self, input: Input) bool {
        _ = self;
        _ = input;
        return false;
    }

    fn handle_staged_input(self: *Self, input: Input) bool {
        _ = self;
        _ = input;
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
