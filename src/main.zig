const std = @import("std");

const git = @import("git.zig");
const input = @import("input.zig");
const queue = @import("queue.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

const UserState = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

const Event = union(enum) {
    git_status: *git.Status,
    input: input.Input,
};

const Job = union(enum) {};

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

    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        input_thread_main,
        .{event_queue},
    );
    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        refresh_thread_main,
        .{ allocator, event_queue },
    );
    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        job_thread_main,
        .{ event_queue, job_queue },
    );

    var curr_git_status: ?*git.Status = null;
    defer {
        if (curr_git_status) |git_status| {
            git_status.deinit();
        }
    }

    while (true) {
        const event = event_queue.get();
        switch (event) {
            .input => |input_evt| {
                if (input_evt.key == .Escape or input_evt.key == .Q or (input_evt.key == .C and input_evt.modifiers.ctrl)) {
                    break;
                }
                std.debug.print("{any}\n", .{input_evt});
            },
            .git_status => |git_status| {
                if (curr_git_status) |last_git_status| {
                    last_git_status.deinit();
                }
                curr_git_status = git_status;
            },
        }
    }
}

fn input_thread_main(event_queue: *queue.Queue(Event)) void {
    const stdin = std.fs.File.stdin();
    while (true) {
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
fn job_thread_main(event_queue: *queue.Queue(Event), job_queue: *queue.Queue(Job)) void {
    _ = event_queue;
    _ = job_queue;
}
