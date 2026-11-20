//! Stable radix order for build-time streams keyed by 64-bit integers.
const std = @import("std");
const io = @import("io.zig");
const Allocator = std.mem.Allocator;

pub fn sortByU64(
    comptime T: type,
    gpa: Allocator,
    values: []T,
    scratch: []T,
    context: anytype,
    comptime keyOf: fn (@TypeOf(context), T) u64,
    deadline: io.Deadline,
) !void {
    std.debug.assert(values.len == scratch.len);
    if (values.len < 2) return;
    const counts = try gpa.alloc(usize, 1 << 16);
    defer gpa.free(counts);
    var source = values;
    var target = scratch;
    for (0..4) |pass| {
        const shift: u6 = @intCast(pass * 16);
        @memset(counts, 0);
        for (source, 0..) |value, i| {
            const key = keyOf(context, value);
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            counts[@as(u16, @truncate(key >> shift))] += 1;
        }
        try bucketOffsets(counts, deadline);
        for (source, 0..) |value, i| {
            const key = keyOf(context, value);
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const bin = &counts[@as(u16, @truncate(key >> shift))];
            target[bin.*] = value;
            bin.* += 1;
        }
        std.mem.swap([]T, &source, &target);
    }
}

// Shared by the record-specific sort kernels. The histogram only contains counts.
noinline fn bucketOffsets(counts: []usize, deadline: io.Deadline) !void {
    var start: usize = 0;
    for (counts, 0..) |*bin, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const count = bin.*;
        bin.* = start;
        start += count;
    }
}
