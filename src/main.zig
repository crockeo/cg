const std = @import("std");

const git = @import("git.zig");
const input = @import("input.zig");
const queue = @import("queue.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

const Event = union(enum) {
    git_status: *git.Status,
    input: input.Input,
    pause_ui: void,
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_termios = try term.enter_raw_mode();
    defer term.restore(original_termios) catch {};

    var event_queue = try queue.Queue(Event).init(allocator);
    defer event_queue.deinit();

    var job_queue = try queue.Queue(Job).init(allocator);
    defer job_queue.deinit();

    // Shared atomic flag to pause input thread during commit
    var input_paused = std.atomic.Value(bool).init(false);

    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        input_thread_main,
        .{ event_queue, &input_paused },
    );
    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        refresh_thread_main,
        .{ allocator, event_queue },
    );
    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        job_thread_main,
        .{ allocator, original_termios, &input_paused, event_queue, job_queue },
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
    var paused = false;

    while (true) {
        const event = event_queue.get();
        switch (event) {
            .input => |input_evt| {
                // Quit handling
                if (input_evt.key == .Escape or input_evt.key == .Q or (input_evt.key == .C and input_evt.modifiers.ctrl)) {
                    break;
                }

                if (curr_repo_state) |*repo_state| {
                    // Navigation
                    if (input_evt.key == .Down and !input_evt.modifiers.ctrl and !input_evt.modifiers.alt) {
                        try handle_down(&user_state, repo_state);
                    } else if (input_evt.key == .Up and !input_evt.modifiers.ctrl and !input_evt.modifiers.alt) {
                        try handle_up(&user_state, repo_state);
                    } else if (input_evt.key == .Tab and !input_evt.modifiers.ctrl and !input_evt.modifiers.alt) {
                        handle_toggle_expand(&user_state);
                    }
                    // Actions
                    else if (input_evt.key == .S and !input_evt.modifiers.ctrl and !input_evt.modifiers.alt) {
                        try handle_stage(allocator, &user_state, repo_state, job_queue);
                    } else if (input_evt.key == .U and !input_evt.modifiers.ctrl and !input_evt.modifiers.alt) {
                        try handle_unstage(allocator, &user_state, repo_state, job_queue);
                    } else if (input_evt.key == .C and !input_evt.modifiers.ctrl and !input_evt.modifiers.alt) {
                        if (repo_state.staged.items.len > 0) {
                            try job_queue.put(.commit);
                        }
                    } else if (input_evt.key == .P and !input_evt.modifiers.ctrl and !input_evt.modifiers.alt) {
                        try job_queue.put(.{ .push = .{ .remote = "origin", .branch = "main" } });
                    }

                    // Repaint after input (unless paused)
                    if (!paused) {
                        try ui.paint(allocator, &user_state, repo_state, stdout);
                    }
                }
            },
            .git_status => |git_status| {
                if (curr_git_status) |last_git_status| {
                    last_git_status.deinit();
                }
                curr_git_status = git_status;

                // Update RepoState
                if (curr_repo_state) |*repo_state| {
                    repo_state.deinit(allocator);
                }
                curr_repo_state = try ui.RepoState.init(allocator, git_status);

                // Resume UI and repaint with new repo state
                paused = false;
                if (curr_repo_state) |*repo_state| {
                    try ui.paint(allocator, &user_state, repo_state, stdout);
                }
            },
            .pause_ui => {
                paused = true;
            },
        }
    }
}

fn handle_down(user_state: *ui.UserState, repo_state: *const ui.RepoState) !void {
    switch (user_state.section) {
        .head => {
            user_state.section = .untracked;
        },
        .untracked => {
            const max_pos = if (user_state.untracked_expanded) repo_state.untracked.items.len else 0;
            if (user_state.pos >= max_pos) {
                user_state.pos = 0;
                user_state.section = .unstaged;
            } else {
                user_state.pos += 1;
            }
        },
        .unstaged => {
            const max_pos = if (user_state.unstaged_expanded) repo_state.unstaged.items.len else 0;
            if (user_state.pos >= max_pos) {
                user_state.pos = 0;
                user_state.section = .staged;
            } else {
                user_state.pos += 1;
            }
        },
        .staged => {
            const max_pos = if (user_state.staged_expanded) repo_state.staged.items.len else 0;
            if (user_state.pos < max_pos) {
                user_state.pos += 1;
            }
        },
    }
}

fn handle_up(user_state: *ui.UserState, repo_state: *const ui.RepoState) !void {
    switch (user_state.section) {
        .head => {},
        .untracked => {
            if (user_state.pos == 0) {
                user_state.section = .head;
            } else {
                user_state.pos -= 1;
            }
        },
        .unstaged => {
            if (user_state.pos > 0) {
                user_state.pos -= 1;
            } else {
                user_state.section = .untracked;
                user_state.pos = if (user_state.untracked_expanded) repo_state.untracked.items.len else 0;
            }
        },
        .staged => {
            if (user_state.pos > 0) {
                user_state.pos -= 1;
            } else {
                user_state.section = .unstaged;
                user_state.pos = if (user_state.unstaged_expanded) repo_state.unstaged.items.len else 0;
            }
        },
    }
}

fn handle_toggle_expand(user_state: *ui.UserState) void {
    switch (user_state.section) {
        .head => {},
        .untracked => {
            user_state.untracked_expanded = !user_state.untracked_expanded;
            if (!user_state.untracked_expanded) {
                user_state.pos = 0;
            }
        },
        .unstaged => {
            user_state.unstaged_expanded = !user_state.unstaged_expanded;
            if (!user_state.unstaged_expanded) {
                user_state.pos = 0;
            }
        },
        .staged => {
            user_state.staged_expanded = !user_state.staged_expanded;
            if (!user_state.staged_expanded) {
                user_state.pos = 0;
            }
        },
    }
}

fn handle_stage(
    allocator: std.mem.Allocator,
    user_state: *ui.UserState,
    repo_state: *const ui.RepoState,
    job_queue: *queue.Queue(Job),
) !void {
    const items = switch (user_state.section) {
        .untracked => repo_state.untracked,
        .unstaged => repo_state.unstaged,
        else => return,
    };

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
}

fn handle_unstage(
    allocator: std.mem.Allocator,
    user_state: *ui.UserState,
    repo_state: *const ui.RepoState,
    job_queue: *queue.Queue(Job),
) !void {
    if (user_state.section != .staged) {
        return;
    }

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
}

fn input_thread_main(event_queue: *queue.Queue(Event), input_paused: *std.atomic.Value(bool)) void {
    const stdin = std.fs.File.stdin();
    while (true) {
        // Check if input reading is paused (e.g., during commit with editor open)
        if (input_paused.load(.acquire)) {
            std.Thread.sleep(std.time.ns_per_ms * 50);
            continue;
        }

        const input_evt = input.read(stdin) catch {
            @panic("input_thread_main error while reading input.");
        };
        event_queue.put(.{ .input = input_evt }) catch {
            @panic("input_thread_main OOM");
        };
    }
}

/// `refresh_thread_main` runs in the background
/// updating the current state of the Git repo,
/// in cases where the user makes no inputs.
fn refresh_thread_main(allocator: std.mem.Allocator, event_queue: *queue.Queue(Event)) void {
    while (true) {
        const git_status = git.status(allocator) catch {
            @panic("refresh_thread_main failed to get new status");
        };
        errdefer git_status.deinit();
        event_queue.put(.{ .git_status = git_status }) catch {
            @panic("refresh_thread_main OOM");
        };
        std.Thread.sleep(std.time.ns_per_s * 5);
    }
}

/// `job_thread_main` accepts jobs from the main thread
/// to perform them without blocking repainting.
/// When a job is finished, this thread will construct a new git status
/// and provide it to the main thread through an event.
fn job_thread_main(
    allocator: std.mem.Allocator,
    original_termios: std.posix.termios,
    input_paused: *std.atomic.Value(bool),
    event_queue: *queue.Queue(Event),
    job_queue: *queue.Queue(Job),
) void {
    while (true) {
        const job = job_queue.get();
        switch (job) {
            .stage => |paths| {
                git.stage(allocator, paths) catch {
                    @panic("job_thread_main failed to stage files");
                };
                allocator.free(paths);
            },
            .unstage => |paths| {
                git.unstage(allocator, paths) catch {
                    @panic("job_thread_main failed to unstage files");
                };
                allocator.free(paths);
            },
            .commit => {
                // Pause UI to prevent painting interference
                event_queue.put(.pause_ui) catch {
                    @panic("job_thread_main failed to send pause_ui event");
                };

                // Pause input thread so editor can receive keystrokes
                input_paused.store(true, .release);

                // Exit raw mode so editor works properly
                term.restore(original_termios) catch {
                    @panic("job_thread_main failed to restore terminal mode");
                };

                // Run commit (opens editor, runs pre-commit hooks)
                git.commit(allocator) catch {
                    @panic("job_thread_main failed to commit");
                };

                // Re-enter raw mode after commit completes
                _ = term.enter_raw_mode() catch {
                    @panic("job_thread_main failed to re-enter raw mode after commit");
                };

                // Resume input thread
                input_paused.store(false, .release);
            },
            .push => |push_info| {
                git.push(allocator, push_info.remote, push_info.branch) catch {
                    @panic("job_thread_main failed to push");
                };
            },
        }

        // Trigger a git status refresh after completing the job
        const git_status = git.status(allocator) catch {
            @panic("job_thread_main failed to get new status after job");
        };
        event_queue.put(.{ .git_status = git_status }) catch {
            @panic("job_thread_main OOM");
        };
    }
}
