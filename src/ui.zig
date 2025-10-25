const std = @import("std");
const c = @cImport({
    @cInclude("curses.h");
});

const err = @import("err.zig");
const git = @import("git.zig");

pub const Interface = struct {
    const Self = @This();

    repo: git.Repo,
    window: *c.WINDOW,

    pub fn init(repo: git.Repo) err.CursesError!Self {
        const window = c.initscr();
        if (window == null) {
            return err.CursesError.CursesError;
        }
        errdefer _ = c.endwin();

        try err.wrap_curses(c.cbreak());
        try err.wrap_curses(c.noecho());
        try err.wrap_curses(c.keypad(window, true));
        try Color.init();

        return .{
            .repo = repo,
            .window = window.?,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        _ = c.endwin();
    }

    pub fn handle_input(self: *Self) void {
        _ = c.getch();
        _ = self;
    }

    pub fn paint(self: *Self, allocator: std.mem.Allocator) !void {
        try err.wrap_curses(c.clear());

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
        try Printer.print("> Head:     SHA1 branch commit message\n\n", .{}, .{});

        if (untracked.items.len > 0) {
            try Printer.print("v ", .{}, .{});
            try Printer.print("Untracked files", .{ .bold = true, .color = .section_header }, .{});
            try Printer.print(" ({d})\n", .{}, .{untracked.items.len});

            for (untracked.items) |diff_delta| {
                try err.wrap_curses(c.printw("> %s\n", diff_delta.diff_delta.*.new_file.path));
            }
            try err.wrap_curses(c.printw("\n"));
        }

        if (unstaged.items.len > 0) {
            try err.wrap_curses(c.printw("v Unstaged changes (%d)\n", unstaged.items.len));
            for (unstaged.items) |diff_delta| {
                const status_name: [*c]const u8 = @ptrCast(diff_delta.status().name());
                try err.wrap_curses(c.printw("> %s   %s\n", status_name, diff_delta.diff_delta.*.new_file.path));
            }
            try err.wrap_curses(c.printw(
                "\n",
            ));
        }

        if (staged.items.len > 0) {
            try err.wrap_curses(c.printw("v Staged changes (%d)\n", staged.items.len));
            for (staged.items) |diff_delta| {
                const status_name: [*c]const u8 = @ptrCast(diff_delta.status().name());
                try err.wrap_curses(c.printw("> %s   %s\n", status_name, diff_delta.diff_delta.*.new_file.path));
            }
            try err.wrap_curses(c.printw(
                "\n",
            ));
        }

        try err.wrap_curses(c.printw(
            "> Recent commits\n",
        ));
    }
};

const Color = enum(c_int) {
    section_header = 1,

    fn init() err.CursesError!void {
        try err.wrap_curses(c.start_color());
        try err.wrap_curses(c.use_default_colors());
        try err.wrap_curses(c.init_pair(@intFromEnum(Color.section_header), c.COLOR_MAGENTA, -1));
    }

    fn attron(self: Color) err.CursesError!void {
        try err.wrap_curses(c.attron(c.COLOR_PAIR(@intFromEnum(self))));
    }

    fn attroff(self: Color) err.CursesError!void {
        try err.wrap_curses(c.attroff(c.COLOR_PAIR(@intFromEnum(self))));
    }
};

const PrintOptions = struct {
    bold: bool = false,
    color: ?Color = null,
};

fn print(contents: [*c]const u8, options: PrintOptions) err.CursesError!void {
    if (options.bold) {
        try err.wrap_curses(c.attron(c.A_BOLD));
    }
    if (options.color) |color| {
        try err.wrap_curses(c.attron(c.COLOR_PAIR(@intFromEnum(color))));
    }

    // TODO: how to pass args?
    try err.wrap_curses(c.printw(contents));

    if (options.color) |color| {
        try err.wrap_curses(c.attroff(c.COLOR_PAIR(@intFromEnum(color))));
    }
    if (options.bold) {
        try err.wrap_curses(c.attroff(c.A_BOLD));
    }
}

const Printer = struct {
    fn print(comptime fmt: []const u8, options: PrintOptions, args: anytype) Error!void {
        if (options.bold) {
            try err.wrap_curses(c.attron(c.A_BOLD));
        }
        if (options.color) |color| {
            try err.wrap_curses(c.attron(c.COLOR_PAIR(@intFromEnum(color))));
        }

        try writer.print(fmt, args);

        if (options.color) |color| {
            try err.wrap_curses(c.attroff(c.COLOR_PAIR(@intFromEnum(color))));
        }
        if (options.bold) {
            try err.wrap_curses(c.attroff(c.A_BOLD));
        }
    }

    // ... all of this is just implementation details,
    // which allow us to treat ncurses output as if
    // it were just a normal Zig std.io.Writer.
    const Error = error{WriteFailed} || err.CursesError;

    const vtable = std.io.Writer.VTable{
        .drain = drain,
    };

    var writer = std.io.Writer{
        .buffer = &.{},
        .vtable = &vtable,
    };

    fn drain(_: *std.io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
        // TODO: to be a Good(tm) writer, I need to do something with `splat`.
        // Not thinking about that for now.
        _ = splat;

        var written: usize = 0;
        for (data) |slice| {
            const ret = c.addnstr(
                @ptrCast(@alignCast(slice.ptr)),
                @intCast(slice.len),
            );
            if (ret == c.ERR) {
                return error.WriteFailed;
            }
            written += slice.len;
        }

        return written;
    }
};
