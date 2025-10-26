const std = @import("std");
const posix = std.posix;

const git = @import("git.zig");
const term = @import("term.zig");

pub const Interface = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    original_termios: posix.termios,
    repo: git.Repo,
    stdin: std.fs.File,
    stdout: std.fs.File,

    pub fn init(allocator: std.mem.Allocator, repo: git.Repo) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .original_termios = try term.enter_raw_mode(),
            .repo = repo,
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

        if (std.mem.eql(u8, buf[0..len], "q")) {
            return true;
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

        // TODO: actually get the SHA of the root, and the commit message
        try writer.print("> Head:     SHA1 branch commit message\n\n\r", .{});

        if (untracked.items.len > 0) {
            try pretty.print("v ", .{}, .{});
            try pretty.print("Untracked files", .{ .bold = true, .foreground = .mauve }, .{});
            try writer.print(" ({d})\n\r", .{untracked.items.len});

            for (untracked.items) |diff_delta| {
                try writer.print("> {s}\n\r", .{diff_delta.diff_delta.*.new_file.path});
            }
            try writer.writeAll("\n\r");
        }

        if (unstaged.items.len > 0) {
            try pretty.print("v ", .{}, .{});
            try pretty.print("Unstaged changes", .{ .bold = true, .foreground = .mauve }, .{});
            try pretty.print(" ({d})\n\r", .{}, .{unstaged.items.len});
            for (unstaged.items) |diff_delta| {
                const status_name = diff_delta.status().name();
                try pretty.print("> ", .{}, .{});
                try pretty.print("{s}", .{ .bold = true, .foreground = .blue }, .{status_name});
                try pretty.print("    {s}\n\r", .{}, .{diff_delta.diff_delta.*.new_file.path});
            }
            try writer.writeAll("\n\r");
        }

        if (staged.items.len > 0) {
            try writer.print("v Staged changes ({d})\n\r", .{staged.items.len});
            for (staged.items) |diff_delta| {
                const status_name = diff_delta.status().name();
                try writer.print("> {s}   {s}\n\r", .{ status_name, diff_delta.diff_delta.*.new_file.path });
            }
            try writer.writeAll("\n\r");
        }

        try pretty.print("> ", .{}, .{});
        try pretty.print("Recent commits\n\r", .{ .bold = true, .foreground = .mauve }, .{});
    }
};

const Pretty = struct {
    const Self = @This();

    writer: *std.io.Writer,

    pub fn print(self: Self, comptime fmt: []const u8, style: Style, args: anytype) error{WriteFailed}!void {
        errdefer self.reset() catch {};
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
    }
};

const Color = struct {
    const Self = @This();

    r: u8,
    g: u8,
    b: u8,

    pub const blue = Self{ .r = 0x8a, .g = 0xad, .b = 0xf4 };
    pub const flamingo = Self{ .r = 0xf0, .g = 0xc6, .b = 0xc6 };
    pub const green = Self{ .r = 0xa6, .g = 0xda, .b = 0x95 };
    pub const lavender = Self{ .r = 0xb7, .g = 0xbd, .b = 0xf8 };
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
