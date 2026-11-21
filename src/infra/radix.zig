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
    const first_key = keyOf(context, values[0]);
    var varying_bits: u64 = 0;
    @memset(counts, 0);
    for (values, 0..) |value, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const key = keyOf(context, value);
        varying_bits |= first_key ^ key;
        counts[@as(u16, @truncate(key))] += 1;
    }
    var source = values;
    var target = scratch;
    for (0..4) |pass| {
        const shift: u6 = @intCast(pass * 16);
        // Stable scattering would keep a uniform digit in its current order.
        if (@as(u16, @truncate(varying_bits >> shift)) == 0) continue;
        if (pass != 0) {
            @memset(counts, 0);
            for (source, 0..) |value, i| {
                const key = keyOf(context, value);
                if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                counts[@as(u16, @truncate(key >> shift))] += 1;
            }
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
    if (source.ptr != values.ptr) {
        var offset: usize = 0;
        while (offset < source.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const end = offset + @min(source.len - offset, 8192);
            @memcpy(values[offset..end], source[offset..end]);
            offset = end;
        }
    }
}

test "skipping uniform digits preserves stable order and the original destination" {
    const t = std.testing;
    const Value = struct {
        key: u64,
        order: u8,

        fn readKey(_: void, value: @This()) u64 {
            return value.key;
        }
    };
    const lower = 0x0000_0001_0000_0021;
    const upper = 0x0000_0002_0000_0021;
    var values = [_]Value{
        .{ .key = upper, .order = 0 },
        .{ .key = lower, .order = 1 },
        .{ .key = upper, .order = 2 },
        .{ .key = lower, .order = 3 },
    };
    var scratch: [values.len]Value = undefined;
    try sortByU64(Value, t.allocator, &values, &scratch, {}, Value.readKey, .none);
    try t.expectEqualDeep([_]Value{
        .{ .key = lower, .order = 1 },
        .{ .key = lower, .order = 3 },
        .{ .key = upper, .order = 0 },
        .{ .key = upper, .order = 2 },
    }, values);
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
