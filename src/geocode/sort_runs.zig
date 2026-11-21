//! Sort a build-time stream while checking its deadline between bounded runs.
const std = @import("std");
const io = @import("../infra/io.zig");
const Allocator = std.mem.Allocator;

/// Sort bounded runs, then merge them with deadline checks even for very
/// common terms whose posting lists span most of the input.
pub fn sort(
    comptime T: type,
    a: Allocator,
    values: []T,
    scratch: *std.ArrayList(T),
    comptime less: fn (void, T, T) bool,
    deadline: io.Deadline,
) !void {
    const run_size = 1024;
    if (values.len < 2) return;
    var start: usize = 0;
    while (start < values.len) : (start += run_size) {
        if (deadline.expired()) return error.DeadlineExceeded;
        std.mem.sortUnstable(T, values[start..@min(start + run_size, values.len)], {}, less);
    }
    if (values.len <= run_size) return;
    try scratch.resize(a, values.len);
    var source = values;
    var target = scratch.items;
    var width: usize = run_size;
    while (width < values.len) : (width *= 2) {
        start = 0;
        while (start < values.len) : (start += width * 2) {
            const middle = @min(start + width, values.len);
            const end = @min(middle + width, values.len);
            var left = start;
            var right = middle;
            for (start..end) |i| {
                if (i % run_size == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (right == end or (left < middle and less({}, source[left], source[right]))) {
                    target[i] = source[left];
                    left += 1;
                } else {
                    target[i] = source[right];
                    right += 1;
                }
            }
        }
        std.mem.swap([]T, &source, &target);
    }
    if (source.ptr != values.ptr) {
        start = 0;
        while (start < values.len) : (start += run_size) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const end = @min(start + run_size, values.len);
            @memcpy(values[start..end], source[start..end]);
        }
    }
}
