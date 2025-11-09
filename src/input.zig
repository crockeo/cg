const std = @import("std");

pub fn read(stdin: std.fs.File) !Input {
    var buf: [16]u8 = undefined;
    const len = try stdin.read(&buf);
    return Input.from_slice(buf[0..len]);
}

pub const Input = enum {
    Unknown,

    fn from_slice(slice: []const u8) Input {
        _ = slice;
        @panic("Not implemented.");
    }
};
