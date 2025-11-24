const std = @import("std");

const err = @import("err.zig");

pub fn InputMap(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();
        const Handler = *const fn (T) err.Error!R;

        const Result = union(enum) {
            handler: Handler,
            next: *Self,
            reset: void,
        };

        allocator: std.mem.Allocator,
        assoc: std.AutoHashMap(Input, *Self),
        handler: ?Handler,

        pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .assoc = .init(allocator),
                .handler = null,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            var children = self.assoc.valueIterator();
            while (children.next()) |child| {
                child.*.deinit();
            }
            self.assoc.deinit();
            self.allocator.destroy(self);
        }

        pub fn add(self: *Self, input_sequence: []const Input, handler: Handler) error{OutOfMemory}!void {
            var curr = self;
            for (input_sequence) |input| {
                curr = curr.assoc.get(input) orelse blk: {
                    const next = try Self.init(self.allocator);
                    try curr.assoc.put(input, next);
                    break :blk next;
                };
            }
            curr.handler = handler;
        }

        pub fn handle(self: *Self, input: Input) Result {
            const next = self.assoc.get(input) orelse {
                return .reset;
            };
            if (next.handler) |handler| {
                return .{ .handler = handler };
            }
            return .{ .next = next };
        }
    };
}

test "InputMap - empty" {
    var input_map = try InputMap(struct {}, struct {}).init(std.testing.allocator);
    defer input_map.deinit();
    try std.testing.expectEqual(.reset, input_map.handle(.{ .key = .A }));
}

test "InputMap - single_handler" {
    const T = struct {};
    var input_map = try InputMap(T, T).init(std.testing.allocator);
    defer input_map.deinit();

    const handler = struct {
        fn f(_: T) err.Error!T {
            return .{};
        }
    }.f;

    try input_map.add(&[_]Input{.{ .key = .A }}, handler);

    try std.testing.expectEqual(.reset, input_map.handle(.{ .key = .B }));
    const result_handler = switch (input_map.handle(.{ .key = .A })) {
        .handler => |h| h,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(handler, result_handler);
}

test "InputMap - chain" {
    const T = struct {};
    var input_map = try InputMap(T, T).init(std.testing.allocator);
    defer input_map.deinit();

    const handler = struct {
        fn f(_: T) err.Error!T {
            return .{};
        }
    }.f;

    try input_map.add(&[_]Input{ .{ .key = .A }, .{ .key = .B } }, handler);

    try std.testing.expectEqual(.reset, input_map.handle(.{ .key = .C }));

    const next_map = switch (input_map.handle(.{ .key = .A })) {
        .next => |n| n,
        else => return error.TestUnexpectedResult,
    };

    const result_handler = switch (next_map.handle(.{ .key = .B })) {
        .handler => |h| h,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(handler, result_handler);
}

pub fn read(stdin: std.fs.File) !Input {
    var buf: [16]u8 = undefined;
    const len = try stdin.read(&buf);
    return Input.from_slice(buf[0..len]);
}

pub const Input = struct {
    const Self = @This();

    key: Key,
    modifiers: Modifiers = .{},

    pub fn eql(self: Self, other: Input) bool {
        return self.key == other.key and self.modifiers.eql(other.modifiers);
    }

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
                '-' => Key.Dash,
                '/' => Key.Slash,
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

    pub fn char(self: Input) ?u8 {
        switch (self.key) {
            .A => return if (self.modifiers.shift) 'A' else 'a',
            .B => return if (self.modifiers.shift) 'B' else 'b',
            .C => return if (self.modifiers.shift) 'C' else 'c',
            .D => return if (self.modifiers.shift) 'D' else 'd',
            .E => return if (self.modifiers.shift) 'E' else 'e',
            .F => return if (self.modifiers.shift) 'F' else 'f',
            .G => return if (self.modifiers.shift) 'G' else 'g',
            .H => return if (self.modifiers.shift) 'H' else 'h',
            .I => return if (self.modifiers.shift) 'I' else 'i',
            .J => return if (self.modifiers.shift) 'J' else 'j',
            .K => return if (self.modifiers.shift) 'K' else 'k',
            .L => return if (self.modifiers.shift) 'L' else 'l',
            .M => return if (self.modifiers.shift) 'M' else 'm',
            .N => return if (self.modifiers.shift) 'N' else 'n',
            .O => return if (self.modifiers.shift) 'O' else 'o',
            .P => return if (self.modifiers.shift) 'P' else 'p',
            .Q => return if (self.modifiers.shift) 'Q' else 'q',
            .R => return if (self.modifiers.shift) 'R' else 'r',
            .S => return if (self.modifiers.shift) 'S' else 's',
            .T => return if (self.modifiers.shift) 'T' else 't',
            .U => return if (self.modifiers.shift) 'U' else 'u',
            .V => return if (self.modifiers.shift) 'V' else 'v',
            .W => return if (self.modifiers.shift) 'W' else 'w',
            .X => return if (self.modifiers.shift) 'X' else 'x',
            .Y => return if (self.modifiers.shift) 'Y' else 'y',
            .Z => return if (self.modifiers.shift) 'Z' else 'z',
            .Slash => return '/',
            .Dash => return '-',
            .Zero => return '0',
            .One => return '1',
            .Two => return '2',
            .Three => return '3',
            .Four => return '4',
            .Five => return '5',
            .Six => return '6',
            .Seven => return '7',
            .Eight => return '8',
            .Nine => return '9',
            .Space => return ' ',
            else => return null,
        }
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

    // Characters
    Dash,
    Slash,

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
    const Self = @This();

    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,

    pub fn eql(self: Self, other: Self) bool {
        return self.alt == other.alt and self.ctrl == other.ctrl and self.shift == other.shift;
    }
};
