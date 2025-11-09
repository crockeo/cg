const std = @import("std");

const event = @import("event.zig");
const git = @import("git.zig");
const input = @import("input.zig");
const queue = @import("queue.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

const LoopEvent = union(enum) {
    git_status: *git.Status,
    input: input.Input,
};

const Job = union(enum) {
    stage: [][]const u8,
    unstage: [][]const u8,
    commit: void,
    push: struct {
        remote: []const u8,
        branch: []const u8,
    },
};

const App = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    event_queue: *queue.Queue(LoopEvent),
    job_queue: *queue.Queue(Job),
    original_termios: std.posix.termios,
    paused: event.Event,
    ready_for_input: event.Event,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const original_termios = try term.enter_raw_mode();
        errdefer term.restore(original_termios) catch {};

        var event_queue = try queue.Queue(LoopEvent).init(allocator);
        errdefer event_queue.deinit();

        var job_queue = try queue.Queue(Job).init(allocator);
        errdefer job_queue.deinit();

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .event_queue = event_queue,
            .job_queue = job_queue,
            .original_termios = original_termios,
            .paused = .{},
            .ready_for_input = .{},
        };
        return self;
    }

    pub fn deinit(self: *App) void {
        term.restore(self.original_termios) catch {};
        self.job_queue.deinit();
        self.event_queue.deinit();
        self.allocator.destroy(self);
    }

    /// `input_thread_main` runs in the background fetching input from the user,
    /// and sending it to the main thread as a LoopEvent.
    fn input_thread_main(self: *Self) void {
        const stdin = std.fs.File.stdin();
        while (true) {
            self.ready_for_input.consume();
            const input_evt = input.read(stdin) catch {
                @panic("input_thread_main error while reading input.");
            };
            self.event_queue.put(.{ .input = input_evt }) catch {
                @panic("input_thread_main OOM");
            };
        }
    }

    /// `refresh_thread_main` runs in the background
    /// updating the current state of the Git repo,
    /// in cases where the user makes no inputs.
    fn refresh_thread_main(self: *Self) void {
        while (true) {
            self.paused.wait(false);
            const git_status = git.status(self.allocator) catch {
                @panic("refresh_thread_main failed to get new status");
            };
            errdefer git_status.deinit();
            self.event_queue.put(.{ .git_status = git_status }) catch {
                @panic("refresh_thread_main OOM");
            };
            std.Thread.sleep(std.time.ns_per_s * 5);
        }
    }

    /// `job_thread_main` accepts jobs from the main thread
    /// to perform them without blocking repainting.
    /// When a job is finished, this thread will construct a new git status
    /// and provide it to the main thread through an event.
    fn job_thread_main(self: *Self) void {
        while (true) {
            const job = self.job_queue.get();
            switch (job) {
                .stage => |paths| {
                    git.stage(self.allocator, paths) catch {
                        @panic("job_thread_main failed to stage files");
                    };
                    self.allocator.free(paths);
                },
                .unstage => |paths| {
                    git.unstage(self.allocator, paths) catch {
                        @panic("job_thread_main failed to unstage files");
                    };
                    self.allocator.free(paths);
                },
                .commit => {
                    git.commit(self.allocator) catch {
                        @panic("job_thread_main failed to commit");
                    };

                    _ = term.enter_raw_mode() catch {
                        @panic("job_thread_main failed to re-enter raw mode after commit");
                    };
                    self.paused.set(false);
                },
                .push => |push_info| {
                    git.push(self.allocator, push_info.remote, push_info.branch) catch {
                        @panic("job_thread_main failed to push");
                    };
                },
            }

            // Trigger a git status refresh after completing the job
            const git_status = git.status(self.allocator) catch {
                @panic("job_thread_main failed to get new status after job");
            };
            self.event_queue.put(.{ .git_status = git_status }) catch {
                @panic("job_thread_main OOM");
            };
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        App.input_thread_main,
        .{app},
    );
    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        App.refresh_thread_main,
        .{app},
    );
    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        App.job_thread_main,
        .{app},
    );

    var user_state = ui.UserState.init(allocator);
    defer user_state.deinit();

    var curr_git_status: ?*git.Status = null;
    defer {
        if (curr_git_status) |git_status| {
            git_status.deinit();
        }
    }

    var curr_repo_state: ?ui.RepoState = null;
    defer {
        if (curr_repo_state) |*repo_state| {
            repo_state.deinit(allocator);
        }
    }

    const stdout = std.fs.File.stdout();
    while (true) {
        app.paused.wait(false);
        app.ready_for_input.set(true);

        if (curr_repo_state) |*repo_state| {
            try ui.paint(allocator, &user_state, repo_state, stdout);
        }

        const evt = app.event_queue.get();
        switch (evt) {
            .input => |input_evt| {
                if (input_evt.eql(.{ .key = .Escape }) or
                    input_evt.eql(.{ .key = .Q }) or
                    input_evt.eql(.{ .key = .C, .modifiers = .{ .ctrl = true } }))
                {
                    break;
                }

                const repo_state = &(curr_repo_state orelse {
                    // No repo state yet, signal ready for next input
                    continue;
                });

                if (input_evt.eql(.{ .key = .C }) and repo_state.staged.items.len > 0) {
                    try app.job_queue.put(.commit);
                    app.paused.set(true);
                    continue;
                }

                if (input_evt.eql(.{ .key = .P })) {
                    try app.job_queue.put(.{ .push = .{ .remote = "origin", .branch = "main" } });
                } else {
                    switch (user_state.section) {
                        .head => try handle_head_input(allocator, &user_state, repo_state, input_evt, app.job_queue),
                        .untracked => try handle_untracked_input(allocator, &user_state, repo_state, input_evt, app.job_queue),
                        .unstaged => try handle_unstaged_input(allocator, &user_state, repo_state, input_evt, app.job_queue),
                        .staged => try handle_staged_input(allocator, &user_state, repo_state, input_evt, app.job_queue),
                    }
                }
            },
            .git_status => |git_status| {
                if (curr_git_status) |last_git_status| {
                    last_git_status.deinit();
                }
                curr_git_status = git_status;

                if (curr_repo_state) |*repo_state| {
                    repo_state.deinit(allocator);
                }
                curr_repo_state = try ui.RepoState.init(allocator, git_status);

                app.paused.set(false);
            },
        }
    }
}

fn handle_head_input(
    allocator: std.mem.Allocator,
    user_state: *ui.UserState,
    repo_state: *const ui.RepoState,
    input_evt: input.Input,
    job_queue: *queue.Queue(Job),
) !void {
    _ = allocator;
    _ = repo_state;
    _ = job_queue;

    if (input_evt.modifiers.ctrl or input_evt.modifiers.alt) return;

    switch (input_evt.key) {
        .Down => {
            user_state.section = .untracked;
        },
        else => {},
    }
}

fn handle_untracked_input(
    allocator: std.mem.Allocator,
    user_state: *ui.UserState,
    repo_state: *const ui.RepoState,
    input_evt: input.Input,
    job_queue: *queue.Queue(Job),
) !void {
    if (input_evt.modifiers.ctrl or input_evt.modifiers.alt) return;

    switch (input_evt.key) {
        .Down => {
            const max_pos = if (user_state.untracked_expanded) repo_state.untracked.items.len else 0;
            if (user_state.pos >= max_pos) {
                user_state.pos = 0;
                user_state.section = .unstaged;
            } else {
                user_state.pos += 1;
            }
        },
        .Up => {
            if (user_state.pos == 0) {
                user_state.section = .head;
            } else {
                user_state.pos -= 1;
            }
        },
        .Tab => {
            user_state.untracked_expanded = !user_state.untracked_expanded;
            if (!user_state.untracked_expanded) {
                user_state.pos = 0;
            }
        },
        .S => {
            const items = repo_state.untracked;
            if (user_state.pos == 0 and items.items.len > 0) {
                // Stage all files in section
                var paths = try allocator.alloc([]const u8, items.items.len);
                for (0.., items.items) |i, item| {
                    paths[i] = item.path;
                }
                try job_queue.put(.{ .stage = paths });
            } else if (user_state.pos > 0) {
                // Stage single file
                const item = items.items[user_state.pos - 1];
                var paths = try allocator.alloc([]const u8, 1);
                paths[0] = item.path;
                try job_queue.put(.{ .stage = paths });

                // Adjust position if we staged the last item
                if (user_state.pos == items.items.len) {
                    user_state.pos -= 1;
                }
            }
        },
        else => {},
    }
}

fn handle_unstaged_input(
    allocator: std.mem.Allocator,
    user_state: *ui.UserState,
    repo_state: *const ui.RepoState,
    input_evt: input.Input,
    job_queue: *queue.Queue(Job),
) !void {
    if (input_evt.modifiers.ctrl or input_evt.modifiers.alt) return;

    switch (input_evt.key) {
        .Down => {
            const max_pos = if (user_state.unstaged_expanded) repo_state.unstaged.items.len else 0;
            if (user_state.pos >= max_pos) {
                user_state.pos = 0;
                user_state.section = .staged;
            } else {
                user_state.pos += 1;
            }
        },
        .Up => {
            if (user_state.pos > 0) {
                user_state.pos -= 1;
            } else {
                user_state.section = .untracked;
                user_state.pos = if (user_state.untracked_expanded) repo_state.untracked.items.len else 0;
            }
        },
        .Tab => {
            user_state.unstaged_expanded = !user_state.unstaged_expanded;
            if (!user_state.unstaged_expanded) {
                user_state.pos = 0;
            }
        },
        .S => {
            const items = repo_state.unstaged;
            if (user_state.pos == 0 and items.items.len > 0) {
                // Stage all files in section
                var paths = try allocator.alloc([]const u8, items.items.len);
                for (0.., items.items) |i, item| {
                    paths[i] = item.path;
                }
                try job_queue.put(.{ .stage = paths });
            } else if (user_state.pos > 0) {
                // Stage single file
                const item = items.items[user_state.pos - 1];
                var paths = try allocator.alloc([]const u8, 1);
                paths[0] = item.path;
                try job_queue.put(.{ .stage = paths });

                // Adjust position if we staged the last item
                if (user_state.pos == items.items.len) {
                    user_state.pos -= 1;
                }
            }
        },
        else => {},
    }
}

fn handle_staged_input(
    allocator: std.mem.Allocator,
    user_state: *ui.UserState,
    repo_state: *const ui.RepoState,
    input_evt: input.Input,
    job_queue: *queue.Queue(Job),
) !void {
    if (input_evt.modifiers.ctrl or input_evt.modifiers.alt) return;

    switch (input_evt.key) {
        .Down => {
            const max_pos = if (user_state.staged_expanded) repo_state.staged.items.len else 0;
            if (user_state.pos < max_pos) {
                user_state.pos += 1;
            }
        },
        .Up => {
            if (user_state.pos > 0) {
                user_state.pos -= 1;
            } else {
                user_state.section = .unstaged;
                user_state.pos = if (user_state.unstaged_expanded) repo_state.unstaged.items.len else 0;
            }
        },
        .Tab => {
            user_state.staged_expanded = !user_state.staged_expanded;
            if (!user_state.staged_expanded) {
                user_state.pos = 0;
            }
        },
        .U => {
            const items = repo_state.staged;
            if (user_state.pos == 0 and items.items.len > 0) {
                // Unstage all files
                var paths = try allocator.alloc([]const u8, items.items.len);
                for (0.., items.items) |i, item| {
                    paths[i] = item.path;
                }
                try job_queue.put(.{ .unstage = paths });
            } else if (user_state.pos > 0) {
                // Unstage single file
                const item = items.items[user_state.pos - 1];
                var paths = try allocator.alloc([]const u8, 1);
                paths[0] = item.path;
                try job_queue.put(.{ .unstage = paths });

                // Adjust position if we unstaged the last item
                if (user_state.pos == items.items.len) {
                    user_state.pos -= 1;
                }
            }
        },
        else => {},
    }
}
