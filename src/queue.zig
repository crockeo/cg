const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        cond: std.Thread.Condition,
        mut: std.Thread.Mutex,
        queue: std.ArrayList(T),

        pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .cond = .{},
                .mut = .{},
                .queue = .empty,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn put(self: *Self, value: T) error{OutOfMemory}!void {
            self.mut.lock();
            defer self.mut.unlock();
            try self.queue.append(self.allocator, value);
            self.cond.signal();
        }

        pub fn get(self: *Self) T {
            self.mut.lock();
            defer self.mut.unlock();

            while (self.queue.items.len == 0) {
                self.cond.wait(&self.mut);
            }

            return self.queue.orderedRemove(0);
        }
    };
}

pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        inner: *Queue(T),
        sem: std.Thread.Semaphore,

        pub fn init(allocator: std.mem.Allocator, max: usize) error{OutOfMemory}!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .inner = try Queue(T).init(allocator),
                .sem = .{ .permits = max },
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
            self.allocator.destroy(self);
        }

        pub fn put(self: *Self, value: T) error{OutOfMemory}!void {
            try self.inner.put(value);
            self.sem.post();
        }

        pub fn get(self: *Self) T {
            self.sem.wait();
            return self.inner.get();
        }
    };
}
