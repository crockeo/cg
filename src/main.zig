const std = @import("std");

const git = @import("git.zig");
const input = @import("input.zig");
const queue = @import("queue.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

const CGError = error{
    OutOfMemory,
};

const Event = union(enum) {
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

    const HandleContext = struct {
        job_queue: *queue.Queue(Job),
        original_termios: std.posix.termios,
    };

    const PaintContext = struct {
        term_height: usize,
        term_width: usize,
    };

    const Result = union(enum) {
        exit: void,
        pass: void,
        pop: void,
        push: State,
        stop: void,
    };

    const VTable = struct {
        deinit: ?*const fn (self: *Self) void,
        paint: *const fn (self: *const Self, PaintContext) CGError!void,
        handle: *const fn (self: *Self, HandleContext, Event) CGError!Result,
    };

    context: *anyopaque,
    vtable: *const VTable,

    pub fn deinit(self: *Self) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }

    pub fn handle(self: *Self, ctx: HandleContext, event: Event) CGError!Result {
        return try self.vtable.handle(self, ctx, event);
    }

    pub fn paint(self: *const Self, ctx: PaintContext) CGError!void {
        try self.vtable.paint(self, ctx);
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
    curr_input_map: *input.InputMap(*Self),
    input_map: *input.InputMap(*Self),
    job_queue: *queue.Queue(Job),
    original_termios: std.posix.termios,
    repo_state: ?ui.RepoState,
    user_state: ui.UserState,

    pub fn init(allocator: std.mem.Allocator, job_queue: *queue.Queue(Job), original_termios: std.posix.termios) error{OutOfMemory}!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const input_map = try input.InputMap(*Self).init(allocator);
        errdefer input_map.deinit();

        self.* = .{
            .allocator = allocator,
            .input_map = input_map,
            .curr_input_map = input_map,
            .job_queue = job_queue,
            .original_termios = original_termios,
            .repo_state = null,
            .user_state = ui.UserState.init(allocator),
        };

        try self.input_map.add(&[_]input.Input{.{ .key = .Up }}, Self.arrow_up_handler);
        try self.input_map.add(&[_]input.Input{.{ .key = .Down }}, Self.arrow_down_handler);
        try self.input_map.add(&[_]input.Input{.{ .key = .B }}, Self.branch_handler);
        try self.input_map.add(&[_]input.Input{ .{ .key = .C }, .{ .key = .C } }, Self.commit_handler);
        try self.input_map.add(&[_]input.Input{.{ .key = .S }}, Self.stage_handler);
        try self.input_map.add(&[_]input.Input{.{ .key = .Tab }}, Self.toggle_expand_handler);
        try self.input_map.add(&[_]input.Input{.{ .key = .U }}, Self.unstage_handler);

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
        self.input_map.deinit();
        if (self.repo_state) |*repo_state| {
            repo_state.deinit(self.allocator);
        }
        self.user_state.deinit();
        self.allocator.destroy(self);
    }

    pub fn paint(state: *const State, ctx: State.PaintContext) CGError!void {
        _ = ctx;
        const self: *const Self = @ptrCast(@alignCast(state.context));
        const stdout = std.fs.File.stdout();
        if (self.repo_state) |*repo_state| {
            ui.paint(self.allocator, &self.user_state, repo_state, stdout) catch {};
        }
    }

    pub fn handle(state: *State, _: State.HandleContext, event: Event) CGError!State.Result {
        const self: *Self = @ptrCast(@alignCast(state.context));

        switch (event) {
            .input => |input_evt| {
                if (input_evt.eql(.{ .key = .Escape }) and self.curr_input_map != self.input_map) {
                    self.curr_input_map = self.input_map;
                    return .stop;
                } else if (input_evt.eql(.{ .key = .Escape }) or
                    input_evt.eql(.{ .key = .Q }) or
                    input_evt.eql(.{ .key = .C, .modifiers = .{ .ctrl = true } }))
                {
                    return .exit;
                }

                const next_input_map = self.curr_input_map.get(input_evt) orelse {
                    self.curr_input_map = self.input_map;
                    return .stop;
                };

                if (next_input_map.handler) |handler| {
                    _ = try handler(self);
                    return .stop;
                }

                return .stop;
            },
            .repo_state => |new_repo_state| {
                if (self.repo_state) |*repo_state| {
                    repo_state.deinit(self.allocator);
                }
                // TODO: reconcile this with user state
                self.repo_state = new_repo_state;
                return .stop;
            },
        }
    }

    ////////////////////
    // Input Handlers //
    ////////////////////
    fn arrow_up_handler(self: *Self) !input.HandlerResult {
        const repo_state = &(self.repo_state orelse return .{});
        switch (self.user_state.section) {
            .head => {
                // Intentionally ignored, since there's nothing above here.
            },
            .untracked => {
                if (!self.user_state.untracked_expanded or self.user_state.pos == 0) {
                    self.user_state.pos = 0;
                    self.user_state.section = .head;
                } else {
                    self.user_state.pos -= 1;
                }
            },
            .unstaged => {
                if (!self.user_state.unstaged_expanded or self.user_state.pos == 0) {
                    if (self.user_state.untracked_expanded) {
                        self.user_state.pos = repo_state.untracked.items.len;
                    } else {
                        self.user_state.pos = 0;
                    }
                    self.user_state.section = .untracked;
                } else {
                    self.user_state.pos -= 1;
                }
            },
            .staged => {
                if (!self.user_state.staged_expanded or self.user_state.pos == 0) {
                    if (self.user_state.unstaged_expanded) {
                        self.user_state.pos = repo_state.unstaged.items.len;
                    } else {
                        self.user_state.pos = 0;
                    }
                    self.user_state.section = .unstaged;
                } else {
                    self.user_state.pos -= 1;
                }
            },
        }
        return .{};
    }

    fn arrow_down_handler(self: *Self) !input.HandlerResult {
        const repo_state = self.repo_state orelse return .{};
        switch (self.user_state.section) {
            .head => {
                self.user_state.pos = 0;
                self.user_state.section = .untracked;
            },
            .untracked => {
                if (!self.user_state.untracked_expanded or
                    self.user_state.pos == repo_state.untracked.items.len)
                {
                    self.user_state.pos = 0;
                    self.user_state.section = .unstaged;
                } else {
                    self.user_state.pos += 1;
                }
            },
            .unstaged => {
                if (!self.user_state.unstaged_expanded or
                    self.user_state.pos == repo_state.unstaged.items.len)
                {
                    self.user_state.pos = 0;
                    self.user_state.section = .staged;
                } else {
                    self.user_state.pos += 1;
                }
            },
            .staged => {
                if (!self.user_state.staged_expanded or
                    self.user_state.pos >= repo_state.staged.items.len)
                {
                    // Intentionally ignored, since there's nothing past here.
                } else {
                    self.user_state.pos += 1;
                }
            },
        }
        return .{};
    }

    fn branch_handler(self: *Self) !input.HandlerResult {
        _ = self;
        // TODO: push InputState to state stack
        // For now just returning, will implement after refactoring App
        return .{};
    }

    fn commit_handler(self: *Self) !input.HandlerResult {
        // TODO: error handling from event handlers

        // Unlike the other handlers, we do commit synchronously,
        // since we have to give control over to the user's editor.
        term.restore(self.original_termios) catch {};
        defer _ = term.enter_raw_mode() catch {};

        git.commit(self.allocator) catch {};
        self.job_queue.put(.refresh) catch {};
        return .{};
    }

    fn stage_handler(self: *Self) !input.HandlerResult {
        if (self.user_state.section != .untracked and self.user_state.section != .unstaged) {
            return .{};
        }

        const deltas = self.current_deltas() orelse return .{};
        if (deltas.items.len == 0) {
            return .{};
        }

        const paths = try self.current_pos_paths(deltas);
        if (self.user_state.pos == deltas.items.len) {
            self.user_state.pos -= 1;
        }
        try self.job_queue.put(.{ .stage = paths });

        return .{};
    }

    fn toggle_expand_handler(self: *Self) !input.HandlerResult {
        switch (self.user_state.section) {
            .untracked => {
                self.user_state.untracked_expanded = !self.user_state.untracked_expanded;
                if (!self.user_state.untracked_expanded) {
                    self.user_state.pos = 0;
                }
            },
            .unstaged => {
                self.user_state.unstaged_expanded = !self.user_state.unstaged_expanded;
                if (!self.user_state.unstaged_expanded) {
                    self.user_state.pos = 0;
                }
            },
            .staged => {
                self.user_state.staged_expanded = !self.user_state.staged_expanded;
                if (!self.user_state.staged_expanded) {
                    self.user_state.pos = 0;
                }
            },
            else => {},
        }
        return .{};
    }

    fn unstage_handler(self: *Self) !input.HandlerResult {
        if (self.user_state.section != .staged) {
            return .{};
        }

        const deltas = self.current_deltas() orelse return .{};
        if (deltas.items.len == 0) {
            return .{};
        }

        const paths = try self.current_pos_paths(deltas);
        if (self.user_state.pos == deltas.items.len) {
            self.user_state.pos -= 1;
        }
        try self.job_queue.put(.{ .unstage = paths });

        return .{};
    }

    ////////////////////
    // Helper Methods //
    ////////////////////
    fn current_deltas(self: *const Self) ?*const std.ArrayList(ui.FileItem) {
        const repo_state = &(self.repo_state orelse return null);
        switch (self.user_state.section) {
            .untracked => return &repo_state.untracked,
            .unstaged => return &repo_state.unstaged,
            .staged => return &repo_state.staged,
            else => return null,
        }
    }

    fn current_pos_paths(
        self: *const Self,
        deltas: *const std.ArrayList(ui.FileItem),
    ) ![]const []const u8 {
        if (self.user_state.pos == 0) {
            var paths = try self.allocator.alloc([]const u8, deltas.items.len);
            for (0.., deltas.items) |i, delta| {
                paths[i] = delta.path;
            }
            return paths;
        }

        const delta = deltas.items[self.user_state.pos - 1];
        var paths = try self.allocator.alloc([]const u8, 1);
        paths[0] = delta.path;
        return paths;
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

    pub fn handle(state: *State, ctx: State.HandleContext, event: Event) State.Result {
        const self: *Self = @ptrCast(@alignCast(state.context));
        // TODO: handle input
        _ = self;
        _ = ctx;
        switch (event) {
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
    event_queue: *queue.LockstepQueue(Event),
    job_queue: *queue.Queue(Job),
    original_termios: std.posix.termios,
    states: std.ArrayList(State),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const original_termios = try term.enter_raw_mode();
        errdefer term.restore(original_termios) catch {};

        var event_queue = try queue.LockstepQueue(Event).init(allocator);
        errdefer event_queue.deinit();

        var job_queue = try queue.Queue(Job).init(allocator);
        errdefer job_queue.deinit();

        var states = std.ArrayList(State).empty;
        errdefer {
            for (states.items) |*state| {
                state.deinit();
            }
            states.deinit(allocator);
        }

        const base_state = try BaseState.init(allocator, job_queue, original_termios);
        try states.append(allocator, base_state.as_state());

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .event_queue = event_queue,
            .job_queue = job_queue,
            .original_termios = original_termios,
            .states = states,
        };
        return self;
    }

    pub fn deinit(self: *App) void {
        term.restore(self.original_termios) catch {};
        self.event_queue.deinit();
        self.job_queue.deinit();
        for (self.states.items) |*state| {
            state.deinit();
        }
        self.states.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// `foreground_main` runs in a loop in the foreground,
    /// painting the UI and reacting to events from the background threads.
    fn foreground_main(self: *Self) !void {
        while (true) {
            for (self.states.items) |state| {
                try state.paint(.{ .term_height = 0, .term_width = 0 });
            }

            const evt = self.event_queue.get();
            defer self.event_queue.next();

            for (0..self.states.items.len) |i| {
                const result = try self.states.items[self.states.items.len - 1 - i].handle(
                    .{
                        .job_queue = self.job_queue,
                        .original_termios = self.original_termios,
                    },
                    evt,
                );
                switch (result) {
                    .exit => {
                        return;
                    },
                    .pass => {
                        continue;
                    },
                    .pop => {
                        if (self.states.pop()) |popped_state| {
                            var state = popped_state;
                            state.deinit();
                        }
                    },
                    .push => |state| {
                        try self.states.append(self.allocator, state);
                    },
                    .stop => {
                        // Intentionally empty, to do nothing
                        // but stop the next state from handling input.
                    },
                }
                break;
            }
        }
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

    try app.foreground_main();
}
