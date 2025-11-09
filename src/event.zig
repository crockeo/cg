const std = @import("std");

pub const Event = struct {
    const Self = @This();

    cond: std.Thread.Condition = .{},
    is_set: bool = false,
    mut: std.Thread.Mutex = .{},

    pub fn set(self: *Self, is_set: bool) void {
        self.mut.lock();
        defer self.mut.unlock();
        self.is_set = is_set;
        self.cond.broadcast();
    }

    pub fn wait(self: *Self, is_set: bool) void {
        self.mut.lock();
        defer self.mut.unlock();
        while (self.is_set != is_set) {
            self.cond.wait(&self.mut);
        }
    }

    pub fn consume(self: *Self) void {
        self.mut.lock();
        defer self.mut.unlock();
        while (!self.is_set) {
            self.cond.wait(&self.mut);
        }
        self.is_set = false;
    }
};
