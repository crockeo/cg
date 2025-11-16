const std = @import("std");

// Wow! This is a bit rough.
// I wish I could just use inferred error sets everywhere,
// but the current system with InputMap requires a known error type.
//
// I just keep unioning things together here 😭
// anyone know a better way?
pub const Error = error{
    FileTooBig,
    OutOfMemory,
    WriteFailed,
} ||
    std.fs.File.ReadError ||
    std.process.Child.SpawnError ||
    std.process.Child.WaitError;
