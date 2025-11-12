const std = @import("std");

pub fn InputMap(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();
        const Handler = *const fn (T) error{OutOfMemory}!R;

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
                curr = self.get(input) orelse blk: {
                    const next = try Self.init(self.allocator);
                    try self.assoc.put(input, next);
                    break :blk next;
                };
            }
            curr.handler = handler;
        }

        pub fn get(self: *Self, input: Input) ?*Self {
            return self.assoc.get(input);
        }
    };
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
    const Self = @This();

    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,

    pub fn eql(self: Self, other: Self) bool {
        return self.alt == other.alt and self.ctrl == other.ctrl and self.shift == other.shift;
    }
};
