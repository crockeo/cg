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
        try err.wrap_curses(c.printw("> Head:     SHA1 branch commit message\n\n"));

        if (untracked.items.len > 0) {
            try err.wrap_curses(c.printw("v Untracked files (%d)\n", untracked.items.len));
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
