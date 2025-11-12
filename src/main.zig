const std = @import("std");

const event = @import("event.zig");
const git = @import("git.zig");
const input = @import("input.zig");
const queue = @import("queue.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

const LoopEvent = union(enum) {
    repo_state: ui.RepoState,
    input: input.Input,
};

const Job = union(enum) {
    push: struct {
        remote: []const u8,
        branch: []const u8,
    },
    refresh: void,
    stage: []const []const u8,
    unstage: []const []const u8,
};

pub const State = struct {
    const Self = @This();

    const PaintContext = struct {
        term_height: usize,
        term_width: usize,
    };

    const Result = union(enum) {
        pass: void,
        pop: void,
        push: State,
        stop: void,
    };

    const VTable = struct {
        deinit: ?*const fn (self: *Self) void,
        paint: *const fn (self: *const Self, PaintContext) void,
        handle: *const fn (self: *Self, LoopEvent) Result,
    };

    context: *anyopaque,
    vtable: *const VTable,

    pub fn deinit(self: *Self) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }

    pub fn paint(self: *const Self, ctx: PaintContext) void {
        self.vtable.paint(self, ctx);
    }

    pub fn handle(self: *Self, loop_event: LoopEvent) Result {
        return self.vtable.handle(self, loop_event);
    }
};

/// BaseState represents the universal state of the program.
/// This is the state that is running when the program starts,
/// and it can never be removed from the running program.
pub const BaseState = struct {
    const Self = @This();

    const vtable = State.VTable{
        .deinit = &Self.deinit,
        .paint = &Self.paint,
        .handle = &Self.handle,
    };

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(state: State) void {
        const self: *Self = @ptrCast(@alignCast(state.context));
        self.allocator.destroy(self);
    }

    pub fn paint(state: State, ctx: State.PaintContext) void {
        _ = state;
        _ = ctx;
    }

    pub fn handle(state: State, loop_event: LoopEvent) State.Result {
        _ = state;
        _ = loop_event;
    }
};

/// InputState is used when you want to collect input from the user.
/// It renders a prompt over the center of the screen.
///
/// (TODO) You can also optionally include a series of options,
/// which will be fuzzy-filtered with the current input.
///
/// (TODO) The user can either cancel (ESC) and no side effect will happen,
/// or it will pop itself from the state stack and call a callback
/// with the final value.
pub const InputState = struct {
    const Self = @This();

    const vtable = State.VTable{
        .deinit = &Self.deinit,
        .paint = &Self.paint,
        .handle = &Self.handle,
    };

    allocator: std.mem.Allocator,
    contents: std.ArrayList(u8),
    options: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, options: []const []const u8) error{OutOfMemory}!*Self {
        var options_dupe = try allocator.alloc([]const u8, options.len);
        errdefer allocator.free(options_dupe);

        for (0.., options) |i, option| {
            options_dupe[i] = try allocator.dupe(u8, option);
            errdefer allocator.free(options_dupe[i]);
        }

        const self = try allocator.create(Self);
        errdefer allocator.free(self);
        self.* = .{
            .allocator = allocator,
            .contents = .empty,
            .options = options_dupe,
        };
        return self;
    }

    pub fn as_state(self: *Self) State {
        return .{
            .context = @ptrCast(self),
            .vtable = &Self.vtable,
        };
    }

    pub fn deinit(state: *State) void {
        const self: *Self = @ptrCast(@alignCast(state.context));
        self.contents.deinit(self.allocator);
        for (self.options) |option| {
            self.allocator.free(option);
        }
        self.allocator.free(self.options);
        self.allocator.destroy(self);
    }

    pub fn paint(state: *const State, ctx: State.PaintContext) void {
        const self: *const Self = @ptrCast(@alignCast(state.context));
        // TODO: paint
        _ = self;
        _ = ctx;
    }

    pub fn handle(state: *State, loop_event: LoopEvent) State.Result {
        const self: *Self = @ptrCast(@alignCast(state.context));
        // TODO: handle input
        _ = self;
        switch (loop_event) {
            .input => |input_evt| {
                if (input_evt.eql(.{ .key = .Escape })) {
                    return .pop;
                }
            },
            else => {},
        }
        return .pass;
    }
};

const App = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    event_queue: *queue.LockstepQueue(LoopEvent),
    input_map: *input.InputMap(*Self),
    job_queue: *queue.Queue(Job),
    original_termios: std.posix.termios,
    repo_state: ?ui.RepoState,
    states: std.ArrayList(State),
    user_state: ui.UserState,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const original_termios = try term.enter_raw_mode();
        errdefer term.restore(original_termios) catch {};

        var event_queue = try queue.LockstepQueue(LoopEvent).init(allocator);
        errdefer event_queue.deinit();

        var job_queue = try queue.Queue(Job).init(allocator);
        errdefer job_queue.deinit();

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .event_queue = event_queue,
            .input_map = try .init(allocator),
            .job_queue = job_queue,
            .original_termios = original_termios,
            .repo_state = null,
            .states = .empty,
            .user_state = ui.UserState.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *App) void {
        term.restore(self.original_termios) catch {};
        self.event_queue.deinit();
        self.input_map.deinit();
        self.job_queue.deinit();
        if (self.repo_state) |*repo_state| {
            repo_state.deinit(self.allocator);
        }
        for (self.states.items) |*state| {
            state.deinit();
        }
        self.states.deinit(self.allocator);
        self.user_state.deinit();
        self.allocator.destroy(self);
    }

    /// `input_thread_main` runs in the background fetching input from the user,
    /// and sending it to the main thread as a LoopEvent.
    fn input_thread_main(self: *Self) void {
        const stdin = std.fs.File.stdin();
        while (true) {
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
            const repo_state = ui.RepoState.init(self.allocator) catch {
                @panic("refresh_thread_main failed to get new status");
            };
            errdefer repo_state.deinit();

            self.event_queue.put(.{ .repo_state = repo_state }) catch {
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
                .push => |push_info| {
                    git.push(self.allocator, push_info.remote, push_info.branch) catch {
                        @panic("job_thread_main failed to push");
                    };
                },
                .refresh => {
                    // Intentionally omitted.
                    // Only useful to perform the refresh below.
                },
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
            }

            // Trigger a git status refresh after completing the job
            const repo_state = ui.RepoState.init(self.allocator) catch {
                @panic("job_thread_main failed to get new status");
            };
            errdefer repo_state.deinit();

            self.event_queue.put(.{ .repo_state = repo_state }) catch {
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

    try app.input_map.add(
        &[_]input.Input{.{ .key = .Up }},
        arrow_up_handler,
    );
    try app.input_map.add(
        &[_]input.Input{.{ .key = .Down }},
        arrow_down_handler,
    );
    try app.input_map.add(
        &[_]input.Input{.{ .key = .B }},
        branch_handler,
    );
    try app.input_map.add(
        &[_]input.Input{ .{ .key = .C }, .{ .key = .C } },
        commit_handler,
    );
    try app.input_map.add(
        &[_]input.Input{.{ .key = .S }},
        stage_handler,
    );
    try app.input_map.add(
        &[_]input.Input{.{ .key = .Tab }},
        toggle_expand_handler,
    );
    try app.input_map.add(
        &[_]input.Input{.{ .key = .U }},
        unstage_handler,
    );

    var curr_input_map: *input.InputMap(*App) = app.input_map;
    const stdout = std.fs.File.stdout();
    while (true) {
        if (app.repo_state) |*repo_state| {
            try ui.paint(allocator, &app.user_state, repo_state, stdout);
        }
        for (app.states.items) |state| {
            state.paint(.{ .term_height = 0, .term_width = 0 });
        }

        const evt = app.event_queue.get();
        defer app.event_queue.next();

        for (0..app.states.items.len) |i| {
            const result = app.states.items[app.states.items.len - 1 - i].handle(evt);
            switch (result) {
                .pass => {
                    continue;
                },
                .pop => {
                    if (app.states.items.len > 0) {
                        app.states.items[app.states.items.len - 1].deinit();
                    }
                    _ = app.states.pop();
                },
                .push => |state| {
                    try app.states.append(app.allocator, state);
                },
                .stop => {
                    // Intentionally omitted,
                    // so that we'll break below.
                },
            }
            break;
        }

        switch (evt) {
            .input => |input_evt| {
                if (input_evt.eql(.{ .key = .Escape }) or
                    input_evt.eql(.{ .key = .Q }) or
                    input_evt.eql(.{ .key = .C, .modifiers = .{ .ctrl = true } }))
                {
                    if (curr_input_map == app.input_map) {
                        break;
                    }
                    curr_input_map = app.input_map;
                    continue;
                }

                const next_input_map = curr_input_map.get(input_evt) orelse {
                    curr_input_map = app.input_map;
                    continue;
                };

                var resume_input = true;
                if (next_input_map.handler) |handler| {
                    const result = try handler(app);
                    resume_input = result.resume_input;
                }
            },
            .repo_state => |new_repo_state| {
                if (app.repo_state) |*repo_state| {
                    repo_state.deinit(allocator);
                }
                app.repo_state = new_repo_state;
            },
        }
    }
}

////////////////////
// Input Handlers //
////////////////////
fn arrow_up_handler(app: *App) !input.HandlerResult {
    const repo_state = &(app.repo_state orelse return .{});
    switch (app.user_state.section) {
        .head => {
            // Intentionally ignored, since there's nothing above here.
        },
        .untracked => {
            if (!app.user_state.untracked_expanded or app.user_state.pos == 0) {
                app.user_state.pos = 0;
                app.user_state.section = .head;
            } else {
                app.user_state.pos -= 1;
            }
        },
        .unstaged => {
            if (!app.user_state.unstaged_expanded or app.user_state.pos == 0) {
                if (app.user_state.untracked_expanded) {
                    app.user_state.pos = repo_state.untracked.items.len;
                } else {
                    app.user_state.pos = 0;
                }
                app.user_state.section = .untracked;
            } else {
                app.user_state.pos -= 1;
            }
        },
        .staged => {
            if (!app.user_state.staged_expanded or app.user_state.pos == 0) {
                if (app.user_state.unstaged_expanded) {
                    app.user_state.pos = repo_state.unstaged.items.len;
                } else {
                    app.user_state.pos = 0;
                }
                app.user_state.section = .unstaged;
            } else {
                app.user_state.pos -= 1;
            }
        },
    }
    return .{};
}

fn arrow_down_handler(app: *App) !input.HandlerResult {
    const repo_state = app.repo_state orelse return .{};
    switch (app.user_state.section) {
        .head => {
            app.user_state.pos = 0;
            app.user_state.section = .untracked;
        },
        .untracked => {
            if (!app.user_state.untracked_expanded or
                app.user_state.pos == repo_state.untracked.items.len)
            {
                app.user_state.pos = 0;
                app.user_state.section = .unstaged;
            } else {
                app.user_state.pos += 1;
            }
        },
        .unstaged => {
            if (!app.user_state.unstaged_expanded or
                app.user_state.pos == repo_state.unstaged.items.len)
            {
                app.user_state.pos = 0;
                app.user_state.section = .staged;
            } else {
                app.user_state.pos += 1;
            }
        },
        .staged => {
            if (!app.user_state.staged_expanded or
                app.user_state.pos >= repo_state.staged.items.len)
            {
                // Intentionally ignored, since there's nothing past here.
            } else {
                app.user_state.pos += 1;
            }
        },
    }
    return .{};
}

fn branch_handler(app: *App) !input.HandlerResult {
    const input_state = try InputState.init(app.allocator, &[_][]const u8{});
    try app.states.append(app.allocator, input_state.as_state());
    return .{};
}

fn commit_handler(app: *App) !input.HandlerResult {
    // TODO: error handling from event handlers

    // Unlike the other handlers, we do commit synchronously,
    // since we have to give control over to the user's editor.
    term.restore(app.original_termios) catch {};
    defer _ = term.enter_raw_mode() catch {};

    git.commit(app.allocator) catch {};
    app.job_queue.put(.refresh) catch {};
    return .{};
}

fn stage_handler(app: *App) !input.HandlerResult {
    if (app.user_state.section != .untracked and app.user_state.section != .unstaged) {
        return .{};
    }

    const deltas = current_deltas(app) orelse return .{};
    if (deltas.items.len == 0) {
        return .{};
    }

    const paths = try current_pos_paths(app, deltas);
    if (app.user_state.pos == deltas.items.len) {
        app.user_state.pos -= 1;
    }
    try app.job_queue.put(.{ .stage = paths });

    return .{};
}

fn toggle_expand_handler(app: *App) !input.HandlerResult {
    switch (app.user_state.section) {
        .untracked => {
            app.user_state.untracked_expanded = !app.user_state.untracked_expanded;
            if (!app.user_state.untracked_expanded) {
                app.user_state.pos = 0;
            }
        },
        .unstaged => {
            app.user_state.unstaged_expanded = !app.user_state.unstaged_expanded;
            if (!app.user_state.unstaged_expanded) {
                app.user_state.pos = 0;
            }
        },
        .staged => {
            app.user_state.staged_expanded = !app.user_state.staged_expanded;
            if (!app.user_state.staged_expanded) {
                app.user_state.pos = 0;
            }
        },
        else => {},
    }
    return .{};
}

fn unstage_handler(app: *App) !input.HandlerResult {
    if (app.user_state.section != .staged) {
        return .{};
    }

    const deltas = current_deltas(app) orelse return .{};
    if (deltas.items.len == 0) {
        return .{};
    }

    const paths = try current_pos_paths(app, deltas);
    if (app.user_state.pos == deltas.items.len) {
        app.user_state.pos -= 1;
    }
    try app.job_queue.put(.{ .unstage = paths });

    return .{};
}

/////////////
// Helpers //
/////////////
fn current_deltas(app: *const App) ?*const std.ArrayList(ui.FileItem) {
    const repo_state = &(app.repo_state orelse return null);
    switch (app.user_state.section) {
        .untracked => return &repo_state.untracked,
        .unstaged => return &repo_state.unstaged,
        .staged => return &repo_state.staged,
        else => return null,
    }
}

fn current_pos_paths(
    app: *const App,
    deltas: *const std.ArrayList(ui.FileItem),
) ![]const []const u8 {
    if (app.user_state.pos == 0) {
        var paths = try app.allocator.alloc([]const u8, deltas.items.len);
        for (0.., deltas.items) |i, delta| {
            paths[i] = delta.path;
        }
        return paths;
    }

    const delta = deltas.items[app.user_state.pos - 1];
    var paths = try app.allocator.alloc([]const u8, 1);
    paths[0] = delta.path;
    return paths;
}
