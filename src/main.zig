const std = @import("std");

const input = @import("input.zig");
const queue = @import("queue.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

const RepoState = struct {
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
    input: input.Input,
    repo_state: RepoState,
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
        .{event_queue},
    );
    _ = try std.Thread.spawn(
        .{ .allocator = allocator },
        job_thread_main,
        .{ event_queue, job_queue },
    );

    while (true) {
        const event = event_queue.get();
        switch (event) {
            .input => |input_evt| {
                if (input_evt.key == .Escape or input_evt.key == .Q) {
                    break;
                }
                std.debug.print("{any}\n", .{input_evt});
            },
            .repo_state => |repo_state_evt| {
                _ = repo_state_evt;
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

fn refresh_thread_main(event_queue: *queue.Queue(Event)) void {
    _ = event_queue;
}

fn job_thread_main(event_queue: *queue.Queue(Event), job_queue: *queue.Queue(Job)) void {
    _ = event_queue;
    _ = job_queue;
}
