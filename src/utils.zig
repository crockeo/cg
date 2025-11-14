const std = @import("std");

/// `insert_ordered` inserts an item `value` into `items`
/// such that it is in order, per definition of ordering produced by `compare_fn`.
pub fn insert_ordered(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: *std.ArrayList(T),
    value: T,
    context: anytype,
    comptime compare_fn: fn (@TypeOf(context), T, T) std.math.Order,
) error{OutOfMemory}!void {
    var left: usize = 0;
    var right: usize = items.items.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        const order = compare_fn(context, value, items.items[mid]);

        switch (order) {
            .lt => right = mid,
            .eq, .gt => left = mid + 1,
        }
    }

    try items.insert(allocator, left, value);
}

test "insert_ordered - insert into empty list" {
    const expectEqualSlices = std.testing.expectEqualSlices;

    var list = std.ArrayList(i32).empty;
    defer list.deinit(std.testing.allocator);

    const compare_fn = struct {
        fn cmp(_: void, a: i32, b: i32) std.math.Order {
            return std.math.order(a, b);
        }
    }.cmp;

    try insert_ordered(i32, std.testing.allocator, &list, 5, {}, compare_fn);

    const expected = [_]i32{5};
    try expectEqualSlices(i32, &expected, list.items);
}

test "insert_ordered - insert at beginning" {
    const expectEqualSlices = std.testing.expectEqualSlices;

    var list = std.ArrayList(i32).empty;
    defer list.deinit(std.testing.allocator);

    try list.appendSlice(std.testing.allocator, &[_]i32{ 2, 4, 6, 8 });

    const compare_fn = struct {
        fn cmp(_: void, a: i32, b: i32) std.math.Order {
            return std.math.order(a, b);
        }
    }.cmp;

    try insert_ordered(i32, std.testing.allocator, &list, 1, {}, compare_fn);

    const expected = [_]i32{ 1, 2, 4, 6, 8 };
    try expectEqualSlices(i32, &expected, list.items);
}

test "insert_ordered - insert at end" {
    const expectEqualSlices = std.testing.expectEqualSlices;

    var list = std.ArrayList(i32).empty;
    defer list.deinit(std.testing.allocator);

    try list.appendSlice(std.testing.allocator, &[_]i32{ 2, 4, 6, 8 });

    const compare_fn = struct {
        fn cmp(_: void, a: i32, b: i32) std.math.Order {
            return std.math.order(a, b);
        }
    }.cmp;

    try insert_ordered(i32, std.testing.allocator, &list, 10, {}, compare_fn);

    const expected = [_]i32{ 2, 4, 6, 8, 10 };
    try expectEqualSlices(i32, &expected, list.items);
}

test "insert_ordered - insert in middle" {
    const expectEqualSlices = std.testing.expectEqualSlices;

    var list = std.ArrayList(i32).empty;
    defer list.deinit(std.testing.allocator);

    try list.appendSlice(std.testing.allocator, &[_]i32{ 1, 3, 7, 9 });

    const compare_fn = struct {
        fn cmp(_: void, a: i32, b: i32) std.math.Order {
            return std.math.order(a, b);
        }
    }.cmp;

    try insert_ordered(i32, std.testing.allocator, &list, 5, {}, compare_fn);

    const expected = [_]i32{ 1, 3, 5, 7, 9 };
    try expectEqualSlices(i32, &expected, list.items);
}

test "insert_ordered - insert duplicate" {
    const expectEqualSlices = std.testing.expectEqualSlices;

    var list = std.ArrayList(i32).empty;
    defer list.deinit(std.testing.allocator);

    try list.appendSlice(std.testing.allocator, &[_]i32{ 1, 3, 5, 7 });

    const compare_fn = struct {
        fn cmp(_: void, a: i32, b: i32) std.math.Order {
            return std.math.order(a, b);
        }
    }.cmp;

    try insert_ordered(i32, std.testing.allocator, &list, 5, {}, compare_fn);

    const expected = [_]i32{ 1, 3, 5, 5, 7 };
    try expectEqualSlices(i32, &expected, list.items);
}

test "insert_ordered - with context" {
    const expectEqualSlices = std.testing.expectEqualSlices;

    const Context = struct {
        offset: i32,
    };

    var list = std.ArrayList(i32).empty;
    defer list.deinit(std.testing.allocator);

    try list.appendSlice(std.testing.allocator, &[_]i32{ 10, 20, 30, 40 });

    const compare_fn = struct {
        fn cmp(ctx: Context, a: i32, b: i32) std.math.Order {
            return std.math.order(a + ctx.offset, b);
        }
    }.cmp;

    const ctx = Context{ .offset = 0 };
    try insert_ordered(i32, std.testing.allocator, &list, 25, ctx, compare_fn);

    const expected = [_]i32{ 10, 20, 25, 30, 40 };
    try expectEqualSlices(i32, &expected, list.items);
}

test "insert_ordered - descending order" {
    const expectEqualSlices = std.testing.expectEqualSlices;

    var list = std.ArrayList(i32).empty;
    defer list.deinit(std.testing.allocator);

    try list.appendSlice(std.testing.allocator, &[_]i32{ 9, 7, 3, 1 });

    const compare_fn = struct {
        fn cmp(_: void, a: i32, b: i32) std.math.Order {
            return std.math.order(b, a);
        }
    }.cmp;

    try insert_ordered(i32, std.testing.allocator, &list, 5, {}, compare_fn);

    const expected = [_]i32{ 9, 7, 5, 3, 1 };
    try expectEqualSlices(i32, &expected, list.items);
}
