const std = @import("std");

/// Returns true if all of the characters of `needle`
/// are present in `haystack`,
/// with any amount of gaps between them.
pub fn matches(
    haystack: []const u8,
    needle: []const u8,
) bool {
    if (needle.len == 0) {
        return true;
    }
    var needle_idx: usize = 0;
    for (haystack) |char| {
        if (needle[needle_idx] == char) {
            needle_idx += 1;
            if (needle_idx == needle.len) {
                return true;
            }
        }
    }
    return false;
}

/// Produces an edit score for a haystack vs. a needle.
/// Currently this is bad.
pub fn score(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
) error{OutOfMemory}!usize {
    // Implementing a classic "min edit distance" algorithm.
    // You can visualize the initial conditions like this:
    //
    //       H A Y S T A C K
    //     - - - - - - - - -
    //   | 0 0 0 0 0 0 0 0 0
    // N | 0 X X X X X X X X
    // E | 0 X X X X X X X X
    // E | 0 X X X X X X X X
    // D | 0 X X X X X X X X
    // L | 0 X X X X X X X X
    // E | 0 X X X X X X X X
    if (needle.len == 0) {
        return 0;
    }

    var matrix = try allocator.alloc(usize, haystack.len * needle.len);
    defer allocator.free(matrix);

    // TODO: i can make this take less memory, because I only need the current + previous rows.
    for (0..haystack.len) |col| {
        matrix[pos(0, col, haystack.len, needle.len)] = 0;
    }
    for (0..needle.len) |row| {
        matrix[pos(row, 0, haystack.len, needle.len)] = 0;
    }

    for (1..needle.len) |row| {
        for (1..haystack.len) |col| {
            const edit_cost: usize = blk: {
                if (needle[row] == haystack[col]) {
                    break :blk 0;
                }
                break :blk 1;
            };
            matrix[pos(row, col, haystack.len, needle.len)] = @min(
                matrix[pos(row - 1, col, haystack.len, needle.len)] + edit_cost,
                matrix[pos(row, col - 1, haystack.len, needle.len)] + edit_cost,
                matrix[pos(row - 1, col - 1, haystack.len, needle.len)] + edit_cost,
            );
        }
    }

    return matrix[pos(needle.len - 1, haystack.len - 1, haystack.len, needle.len)];
}

inline fn pos(row: usize, col: usize, width: usize, height: usize) usize {
    std.debug.assert(row >= 0 and row < height);
    std.debug.assert(col >= 0 and col < width);
    return row * width + col;
}

const SortPair = struct {
    index: usize,
    value: []const u8,

    fn less_than(scores_ctx: []usize, lhs: SortPair, rhs: SortPair) bool {
        return scores_ctx[lhs.index] < scores_ctx[rhs.index];
    }
};

pub fn sort_by_scores(
    allocator: std.mem.Allocator,
    values: [][]const u8,
    scores: []usize,
) error{OutOfMemory}!void {
    std.debug.assert(values.len == scores.len);
    var pairs = try allocator.alloc(SortPair, values.len);
    defer allocator.free(pairs);
    for (0.., values) |i, value| {
        pairs[i] = .{
            .index = i,
            .value = value,
        };
    }
    std.mem.sort(SortPair, pairs, scores, SortPair.less_than);
    for (0.., pairs) |i, pair| {
        values[i] = pair.value;
    }
}

test "match - empty" {
    const result = matches("testing", "");
    try std.testing.expectEqual(true, result);
}

test "match - sequence" {
    const result = matches("testing", "tsng");
    try std.testing.expectEqual(true, result);
}

test "score - equal" {
    const value = try score(std.testing.allocator, "value", "value");
    try std.testing.expectEqual(0, value);
}

test "score - simple edit" {
    const value = try score(std.testing.allocator, "value1", "value2");
    try std.testing.expectEqual(1, value);
}

test "score - deletion" {
    const value = try score(std.testing.allocator, "value", "val");
    try std.testing.expectEqual(2, value);
}

test "score - insertion" {
    const value = try score(std.testing.allocator, "val", "value");
    try std.testing.expectEqual(2, value);
}

test "score - empty" {
    const value = try score(std.testing.allocator, "value", "");
    try std.testing.expectEqual(0, value);
}
