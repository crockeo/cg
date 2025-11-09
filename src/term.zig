const std = @import("std");

pub fn enter_raw_mode() !std.posix.termios {
    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();

    const original_termios = try std.posix.tcgetattr(stdin.handle);
    errdefer restore(original_termios) catch {
        @panic("Failed to restore original termios");
    };

    // Set terminal to raw mode
    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.oflag.OPOST = false;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

    // - Enter alternate screen buffer
    // - Clear screen
    // - Hide cursor
    try stdout.writeAll("\x1b[?1049h");
    try stdout.writeAll("\x1b[2J");
    try stdout.writeAll("\x1b[?25l");

    return original_termios;
}

pub fn restore(original_termios: std.posix.termios) !void {
    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();

    // - Show cursor
    // - Exit alternate screen buffer
    stdout.writeAll("\x1b[?25h") catch {};
    stdout.writeAll("\x1b[?1049l") catch {};

    // Ensure escape sequences are processed before changing terminal mode
    stdout.sync() catch {};

    try std.posix.tcsetattr(stdin.handle, .FLUSH, original_termios);
}
