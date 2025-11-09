const std = @import("std");

pub fn read(stdin: std.fs.File) !Input {
    var buf: [16]u8 = undefined;
    const len = try stdin.read(&buf);
    return Input.from_slice(buf[0..len]);
}

pub const Input = struct {
    key: Key,
    modifiers: Modifiers,

    fn from_slice(slice: []const u8) Input {
        if (slice.len == 0) {
            return .{ .key = .Unknown, .modifiers = .{} };
        }

        // Handle escape sequences
        if (slice[0] == 0x1b) {
            // Plain ESC
            if (slice.len == 1) {
                return .{ .key = .Escape, .modifiers = .{} };
            }

            // CSI sequences (ESC [)
            if (slice.len >= 3 and slice[1] == '[') {
                return switch (slice[2]) {
                    'A' => .{ .key = .Up, .modifiers = .{} },
                    'B' => .{ .key = .Down, .modifiers = .{} },
                    'C' => .{ .key = .Right, .modifiers = .{} },
                    'D' => .{ .key = .Left, .modifiers = .{} },
                    else => .{ .key = .Unknown, .modifiers = .{} },
                };
            }

            // Alt+key sequences (ESC followed by key)
            if (slice.len == 2) {
                const byte = slice[1];
                const key = switch (byte) {
                    'a'...'z' => @as(Key, @enumFromInt(@intFromEnum(Key.A) + (byte - 'a'))),
                    'A'...'Z' => @as(Key, @enumFromInt(@intFromEnum(Key.A) + (byte - 'A'))),
                    '0'...'9' => @as(Key, @enumFromInt(@intFromEnum(Key.Zero) + (byte - '0'))),
                    else => Key.Unknown,
                };
                const shift = switch (byte) {
                    'A'...'Z' => true,
                    else => false,
                };
                return .{
                    .key = key,
                    .modifiers = .{ .alt = true, .shift = shift },
                };
            }

            return .{ .key = .Unknown, .modifiers = .{} };
        }

        // Handle single byte characters
        if (slice.len == 1) {
            const byte = slice[0];

            // Special keys that need to be handled before Ctrl combinations
            if (byte == 0x09) { // Tab
                return .{ .key = .Tab, .modifiers = .{} };
            }
            if (byte == 0x0D) { // Enter
                return .{ .key = .Enter, .modifiers = .{} };
            }

            // Ctrl+A through Ctrl+Z (0x01-0x1A)
            if (byte >= 0x01 and byte <= 0x1A) {
                const key = @as(Key, @enumFromInt(@intFromEnum(Key.A) + (byte - 0x01)));
                return .{
                    .key = key,
                    .modifiers = .{ .ctrl = true },
                };
            }

            const key = switch (byte) {
                0x7F => Key.Backspace,
                'a'...'z' => @as(Key, @enumFromInt(@intFromEnum(Key.A) + (byte - 'a'))),
                'A'...'Z' => @as(Key, @enumFromInt(@intFromEnum(Key.A) + (byte - 'A'))),
                '0'...'9' => @as(Key, @enumFromInt(@intFromEnum(Key.Zero) + (byte - '0'))),
                ' ' => Key.Space,
                else => Key.Unknown,
            };
            const shift = switch (byte) {
                'A'...'Z' => true,
                else => false,
            };
            return .{
                .key = key,
                .modifiers = .{ .shift = shift },
            };
        }

        return .{ .key = .Unknown, .modifiers = .{} };
    }
};

pub const Key = enum {
    // Alphabetic keys
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,

    // Numeric keys
    Zero,
    One,
    Two,
    Three,
    Four,
    Five,
    Six,
    Seven,
    Eight,
    Nine,

    // Control keys
    Space,
    Tab,
    Enter,
    Backspace,
    Escape,

    // Arrow keys
    Up,
    Down,
    Left,
    Right,

    Unknown,
};

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
};
