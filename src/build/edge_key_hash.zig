//! Deterministic displacement hash for the optional edge-key index.
const std = @import("std");
const keys = @import("../graph/edge_keys.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;
const empty_slot = std.math.maxInt(u32);

pub const Built = struct {
    header: keys.HashHeader,
    buckets: []u64,
    slots: []u32,

    pub fn view(self: Built) keys.Hash {
        return .{ .seed = self.header.seed, .buckets = self.buckets, .slots = self.slots };
    }

    pub fn deinit(self: Built, a: Allocator) void {
        a.free(self.buckets);
        a.free(self.slots);
    }
};

/// Place larger buckets first. Every remaining slot receives one key
/// from a singleton bucket, so the result has exactly one slot per key.
pub fn build(a: Allocator, records: []const keys.Record, deadline: Deadline) !?Built {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (records.len == 0) return null;
    if (records.len >= empty_slot) return error.TooManyDirectedEdges;
    const buckets = try a.alloc(u64, (records.len + 1) / 2);
    errdefer a.free(buckets);
    const slots = try a.alloc(u32, records.len);
    errdefer a.free(slots);
    var result: Built = .{ .header = .{ .seed = 0 }, .buckets = buckets, .slots = slots };
    for (0..8) |seed| {
        if (deadline.expired()) return error.DeadlineExceeded;
        result.header.seed = seed;
        if (try place(a, result, records, deadline)) return result;
    }
    return error.EdgeKeyHashDisplacementExhausted;
}

fn place(a: Allocator, output: Built, records: []const keys.Record, deadline: Deadline) !bool {
    @memset(output.buckets, keys.empty_bucket);
    @memset(output.slots, empty_slot);
    const hash = output.view();
    const first = try a.alloc(u32, output.buckets.len + 1);
    defer a.free(first);
    @memset(first, 0);
    for (records, 0..) |record, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        first[hash.bucketFor(record.key) + 1] += 1;
    }
    var largest: u32 = 0;
    for (first[1..], 0..) |*end, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        largest = @max(largest, end.*);
        end.* += first[i];
    }
    const members = try a.alloc(u32, records.len);
    defer a.free(members);
    {
        const next = try a.dupe(u32, first[0..output.buckets.len]);
        defer a.free(next);
        for (records, 0..) |record, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const slot = &next[hash.bucketFor(record.key)];
            members[slot.*] = @intCast(i);
            slot.* += 1;
        }
    }
    const by_size = try orderBuckets(a, first, largest, deadline);
    defer a.free(by_size);
    for (by_size) |bucket| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const group = members[first[bucket]..first[@as(usize, bucket) + 1]];
        if (group.len < 2) break;
        var displacement: u64 = 1;
        while (displacement <= 65536) : (displacement += 1) {
            if (displacement % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (try assignGroup(output.slots, records, group, displacement, deadline)) {
                output.buckets[bucket] = displacement;
                break;
            }
        } else return false;
    }

    var cursor: usize = 0;
    for (first[0..output.buckets.len], 0..) |start, bucket| {
        if (bucket % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (first[bucket + 1] - start != 1) continue;
        while (output.slots[cursor] != empty_slot) : (cursor += 1) {
            if (cursor % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        }
        output.slots[cursor] = members[start];
        output.buckets[bucket] = keys.singleton_bucket | cursor;
        cursor += 1;
    }
    return true;
}

fn orderBuckets(a: Allocator, first: []const u32, largest: u32, deadline: Deadline) ![]u32 {
    const next = try a.alloc(u32, @as(usize, largest) + 1);
    defer a.free(next);
    @memset(next, 0);
    for (first[0 .. first.len - 1], first[1..], 0..) |begin, end, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        next[largest - (end - begin)] += 1;
    }
    var sum: u32 = 0;
    for (next, 0..) |*count, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const size = count.*;
        count.* = sum;
        sum += size;
    }
    const order = try a.alloc(u32, first.len - 1);
    errdefer a.free(order);
    for (first[0 .. first.len - 1], first[1..], 0..) |begin, end, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const entry = &next[largest - (end - begin)];
        order[entry.*] = @intCast(i);
        entry.* += 1;
    }
    return order;
}

fn assignGroup(slots: []u32, records: []const keys.Record, group: []const u32, displacement: u64, deadline: Deadline) !bool {
    for (group, 0..) |index, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const slot = keys.Hash.slotFor(records[index].key, displacement, slots.len);
        if (slots[slot] != empty_slot) {
            for (group[0..i], 0..) |earlier, j| {
                if (j % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const previous = keys.Hash.slotFor(records[earlier].key, displacement, slots.len);
                slots[previous] = empty_slot;
            }
            return false;
        }
        slots[slot] = index;
    }
    return true;
}

test "displacement hash uses exactly one slot per directed edge" {
    const testing = std.testing;
    const a = testing.allocator;
    const records = try a.alloc(keys.Record, 1025);
    defer a.free(records);
    const inverse = try a.alloc(u32, records.len);
    defer a.free(inverse);
    for (records, inverse, 0..) |*record, *row, i| {
        record.* = .{ .key = .{ .way_id = 42, .begin_node = @as(i64, @intCast(i)) - 512, .end_node = 851 }, .edge = @intCast(i) };
        row.* = @intCast(i);
    }
    const result = (try build(a, records, .none)).?;
    defer result.deinit(a);
    try testing.expectEqual(records.len, result.slots.len);
    const view: keys.View = .{ .records = records, .inverse = inverse, .hash = result.view() };
    try view.verify(records.len, .none);
    for (records) |record| try testing.expectEqual(record.edge, @backingInt((try view.find(record.key)).?));
    const repeated = (try build(a, records, .none)).?;
    defer repeated.deinit(a);
    try testing.expectEqual(result.header.seed, repeated.header.seed);
    try testing.expectEqualSlices(u64, result.buckets, repeated.buckets);
    try testing.expectEqualSlices(u32, result.slots, repeated.slots);
    try testing.expectEqual(null, try view.find(.{ .way_id = 43, .begin_node = 8, .end_node = 851 }));
}
