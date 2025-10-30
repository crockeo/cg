const std = @import("std");

const ui = @import("ui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
