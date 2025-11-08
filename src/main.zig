const std = @import("std");

const ui = @import("ui.zig");

const Application = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    background: Background,
    foreground: Foreground,
    repo_state: ?RepoState,
    user_state: UserState,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .background = Background.init(allocator),
            .foreground = Foreground.init(allocator),
            .repo_state = null,
            .user_state = UserState.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.background.deinit();
        self.foreground.deinit();
        if (self.repo_state) |*repo_state| {
            repo_state.deinit();
        }
        self.user_state.deinit();
        self.allocator.destroy(self);
    }
};

const Background = struct {
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

const Foreground = struct {
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try Application.init(allocator);
    defer app.deinit();

    var interface = try ui.Interface.init(allocator);
    defer interface.deinit();

    while (true) {
        try interface.update();
        try interface.paint();
        if (try interface.handle_input()) {
            break;
        }
    }
}
