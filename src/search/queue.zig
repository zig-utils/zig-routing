//! Exact priority queues. Search keeps replaced entries until they reach the root.

const std = @import("std");

pub const Entry = extern struct {
    key: u32,
    label: u32,

    pub fn init(priority: f32, label: u32) Entry {
        std.debug.assert(!std.math.isNan(priority) and priority >= 0);
        return .{ .key = @bitCast(if (priority == 0) @as(f32, 0) else priority), .label = label };
    }

    fn less(a: Entry, b: Entry) bool {
        return a.rank() < b.rank();
    }

    /// The key is the bit pattern of a non-negative f32, so one u64 with the
    /// key above the label orders exactly like (cost, label).
    inline fn rank(self: Entry) u64 {
        return (@as(u64, self.key) << 32) | self.label;
    }
};

comptime {
    std.debug.assert(@sizeOf(Entry) == 8);
    std.debug.assert(@offsetOf(Entry, "key") == 0 and @offsetOf(Entry, "label") == 4);
}

/// Four-way min-heap ordered by (key, label). Search pushes unique pairs, so
/// any correct heap pops the same sequence there.
pub const Heap = struct {
    items: std.ArrayList(Entry) = .empty,

    pub fn push(self: *Heap, arena: std.mem.Allocator, entry: Entry) !void {
        if (self.items.items.len == self.items.capacity) try self.grow(arena);
        const items = self.items.items.ptr;
        const rank = entry.rank();
        var hole = self.items.items.len;
        self.items.items.len += 1;
        while (hole != 0) {
            const parent = (hole - 1) / 4;
            const item = items[parent];
            if (rank >= item.rank()) break;
            items[hole] = item;
            hole = parent;
        }
        items[hole] = entry;
    }

    noinline fn grow(self: *Heap, arena: std.mem.Allocator) !void {
        try self.items.ensureUnusedCapacity(arena, 1);
    }

    pub fn peek(self: *const Heap) ?Entry {
        return if (self.items.items.len == 0) null else self.items.items[0];
    }

    pub fn pop(self: *Heap) ?Entry {
        const len = self.items.items.len;
        if (len == 0) return null;
        const items = self.items.items.ptr;
        const root = items[0];
        const count = len - 1;
        self.items.items.len = count;
        if (count == 0) return root;
        const last = items[count];
        const rank = last.rank();

        var hole: usize = 0;
        // Full sibling groups: pick the least child without branches.
        while (hole * 4 + 4 < count) {
            const first = hole * 4 + 1;
            const a = items[first].rank();
            const b = items[first + 1].rank();
            const c = items[first + 2].rank();
            const d = items[first + 3].rank();
            const ab: usize = if (b < a) first + 1 else first;
            const cd: usize = if (d < c) first + 3 else first + 2;
            const ab_rank = @min(a, b);
            const cd_rank = @min(c, d);
            const least = if (cd_rank < ab_rank) cd else ab;
            if (@min(ab_rank, cd_rank) >= rank) {
                items[hole] = last;
                return root;
            }
            items[hole] = items[least];
            hole = least;
        }
        // At most one partial sibling group remains below the hole.
        const first = hole * 4 + 1;
        if (first < count) {
            var least = first;
            var least_rank = items[first].rank();
            for (first + 1..count) |i| {
                const r = items[i].rank();
                if (r < least_rank) {
                    least = i;
                    least_rank = r;
                }
            }
            if (least_rank < rank) {
                items[hole] = items[least];
                hole = least;
            }
        }
        items[hole] = last;
        return root;
    }
};

// Ported from valhalla/baldr/double_bucket_queue.h (Valhalla 3.9.3).
// The low-level window is indexed by the costing unit. Order within a bucket
// is exact, including fractional costs and the search engine's label tie break.
pub const BucketQueue = struct {
    const bucket_count = 256;
    const BucketIndex = u8;
    const GroupIndex = u2;
    const InGroup = u6;
    const max_bucket = std.math.maxInt(u64);

    buckets: [bucket_count]Heap = @splat(.{}),
    overflow: Heap = .{},
    nonempty: [bucket_count / 64]u64 = @splat(0),
    groups: u4 = 0,
    refilling: bool = false,
    base: u64 = 0,
    units_reciprocal: f64,

    pub fn init(unit_size: u32) !BucketQueue {
        if (unit_size == 0) return error.InvalidBucketWidth;
        return .{ .units_reciprocal = 1 / @as(f64, @floatFromInt(unit_size)) };
    }

    pub fn clear(self: *BucketQueue) void {
        for (&self.buckets) |*bucket| bucket.items.clearRetainingCapacity();
        self.overflow.items.clearRetainingCapacity();
        self.nonempty = @splat(0);
        self.groups = 0;
        self.refilling = false;
        self.base = 0;
    }

    pub fn push(self: *BucketQueue, arena: std.mem.Allocator, entry: Entry) !void {
        const offset = self.bucketFor(entry) -| self.base;
        if (offset < bucket_count) return self.pushFine(arena, @intCast(offset), entry);
        try self.overflow.push(arena, entry);
    }

    pub fn popWithin(self: *BucketQueue, arena: std.mem.Allocator, control: anytype) !?Entry {
        if (self.refilling) {
            try self.refill(arena, control);
        } else if (self.groups == 0) {
            const first = self.overflow.peek() orelse return null;
            self.base = self.bucketFor(first);
            self.refilling = true;
            try self.refill(arena, control);
        }
        const group: GroupIndex = @intCast(@ctz(self.groups));
        const slot: InGroup = @intCast(@ctz(self.nonempty[group]));
        const index = @as(BucketIndex, group) * 64 + slot;
        const selected = &self.buckets[index];
        const entry = selected.pop().?;
        if (selected.items.items.len == 0) {
            self.nonempty[group] &= ~(@as(u64, 1) << slot);
            if (self.nonempty[group] == 0) self.groups &= ~(@as(u4, 1) << group);
        }
        return entry;
    }

    fn pushFine(self: *BucketQueue, arena: std.mem.Allocator, index: BucketIndex, entry: Entry) !void {
        const bucket = &self.buckets[index];
        const was_empty = bucket.items.items.len == 0;
        try bucket.push(arena, entry);
        if (was_empty) {
            const group: GroupIndex = @intCast(index / 64);
            const slot: InGroup = @truncate(index);
            self.nonempty[group] |= @as(u64, 1) << slot;
            self.groups |= @as(u4, 1) << group;
        }
    }

    fn bucketFor(self: *const BucketQueue, entry: Entry) u64 {
        const cost: f32 = @bitCast(entry.key);
        const scaled = @as(f64, cost) * self.units_reciprocal;
        return if (scaled >= @as(f64, @floatFromInt(max_bucket))) max_bucket else @intFromFloat(scaled);
    }

    noinline fn refill(self: *BucketQueue, arena: std.mem.Allocator, control: anytype) !void {
        // A cancelled or failed transfer can be resumed before any fine
        // bucket is popped. Both levels still own their respective entries.
        var moved: usize = 0;
        while (self.overflow.peek()) |entry| : (moved += 1) {
            if (moved % 1024 == 0) try control.check();
            const offset = self.bucketFor(entry) - self.base;
            if (offset >= bucket_count) break;
            try self.pushFine(arena, @intCast(offset), entry);
            _ = self.overflow.pop().?;
        }
        self.refilling = false;
    }
};

/// Radix heap for Dijkstra walks with nondecreasing popped costs.
/// Positive float bit patterns sort in the same order as their values.
pub const RadixQueue = Radix(false, false);

/// Composite keys are monotone when equal-priority insertions have increasing
/// label indices. This includes Dijkstra's zero-cost steps.
pub const OrderedRadixQueue = Radix(true, false);

pub const LabelActivityQueue = Radix(false, true);
pub const CompactQueue = Radix(true, true);

fn Radix(comptime include_ties: bool, comptime track_replacements: bool) type {
    return struct {
        const Self = @This();
        pub const label_activity = track_replacements;
        const Key = if (include_ties) u64 else u32;
        const empty_key = std.math.maxInt(Key);
        const digit_bits = 4;
        const digit_count = @bitSizeOf(Key) / digit_bits;
        const slots_per_digit = 1 << digit_bits;
        const Digit = @Int(.unsigned, std.math.log2(digit_count));
        const Digits = @Int(.unsigned, digit_count);
        const Shift = @Int(.unsigned, std.math.log2(@bitSizeOf(Key)));
        const Slot = u4;
        const Index = @Int(.unsigned, @bitSizeOf(Digit) + digit_bits);

        const Bucket = struct {
            entries: std.ArrayList(Entry) = .empty,
            minimum: Key = empty_key,
        };

        buckets: [digit_count * slots_per_digit]Bucket = @splat(.{}),
        equal: if (include_ties) usize else Heap = if (include_ties) 0 else .{},
        slots: [digit_count]u16 = @splat(0),
        digits: Digits = 0,
        minimum: Key = 0,
        redistributing: ?Index = null,

        pub fn init(unit_size: u32) !Self {
            if (unit_size == 0) return error.InvalidBucketWidth;
            return .{};
        }

        pub fn push(self: *Self, arena: std.mem.Allocator, entry: Entry) !void {
            if (key(entry) < self.minimum) return error.NonmonotonePriority;
            return self.insert(arena, entry);
        }

        fn key(entry: Entry) Key {
            return if (include_ties) (@as(u64, entry.key) << 32) | entry.label else entry.key;
        }

        fn insert(self: *Self, arena: std.mem.Allocator, entry: Entry) !void {
            const value = key(entry);
            const differing = value ^ self.minimum;
            if (differing == 0) {
                if (!include_ties) return self.equal.push(arena, entry);
                self.equal += 1;
                return;
            }
            const digit: Digit = @intCast((@bitSizeOf(Key) - 1 - @clz(differing)) / digit_bits);
            const shift: Shift = @as(Shift, digit) * digit_bits;
            const slot: Slot = @truncate(value >> shift);
            const bucket = &self.buckets[bucketIndex(digit, slot)];
            try bucket.entries.append(arena, entry);
            bucket.minimum = @min(bucket.minimum, value);
            if (bucket.entries.items.len == 1) {
                self.slots[digit] |= @as(u16, 1) << slot;
                self.digits |= @as(Digits, 1) << digit;
            }
        }

        pub fn popWithin(self: *Self, arena: std.mem.Allocator, control: anytype) !?Entry {
            if (self.redistributing != null) {
                try self.redistribute(arena, control);
            } else if (if (include_ties) self.equal == 0 else self.equal.items.items.len == 0) {
                if (self.digits == 0) return null;
                const digit: Digit = @intCast(@ctz(self.digits));
                const slot: Slot = @intCast(@ctz(self.slots[digit]));
                const index = bucketIndex(digit, slot);
                const bucket = &self.buckets[index];
                if (bucket.entries.items.len == 1) {
                    const entry = bucket.entries.pop().?;
                    self.minimum = key(entry);
                    self.clearBucket(index);
                    return entry;
                }
                self.minimum = bucket.minimum;
                self.redistributing = index;
                try self.redistribute(arena, control);
            }
            if (!include_ties) return self.equal.pop();
            self.equal -= 1;
            return .{ .key = @truncate(self.minimum >> 32), .label = @truncate(self.minimum) };
        }

        fn bucketIndex(digit: Digit, slot: Slot) Index {
            return @as(Index, digit) * slots_per_digit + slot;
        }

        fn clearBucket(self: *Self, index: Index) void {
            const digit: Digit = @intCast(index / slots_per_digit);
            const slot: Slot = @truncate(index);
            self.slots[digit] &= ~(@as(u16, 1) << slot);
            if (self.slots[digit] == 0) self.digits &= ~(@as(Digits, 1) << digit);
            self.buckets[index].minimum = empty_key;
        }

        noinline fn redistribute(self: *Self, arena: std.mem.Allocator, control: anytype) !void {
            const index = self.redistributing.?;
            const bucket = &self.buckets[index].entries;
            var moved: usize = 0;
            while (bucket.last()) |entry| : (moved += 1) {
                if (moved % 256 == 0) try control.check();
                // All entries in the selected bucket share the new minimum's
                // leading digits. Keep the original copy until insertion succeeds.
                try self.insert(arena, entry);
                _ = bucket.pop();
            }
            self.clearBucket(index);
            self.redistributing = null;
        }
    };
}

test "four-way heap handles ties and sparse final child groups" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var heap: Heap = .{};
    try std.testing.expectEqual(@as(?Entry, null), heap.pop());
    var rng = std.Random.DefaultPrng.init(0x402e);
    const random = rng.random();
    var sorted: [1027]Entry = undefined;
    for (&sorted, 0..) |*row, i| {
        const key: f32 = @floatFromInt(random.uintLessThan(u32, 27));
        row.* = .init(key, @intCast(i));
        try heap.push(a, row.*);
    }
    std.mem.sort(Entry, &sorted, {}, struct {
        fn less(_: void, a_entry: Entry, b_entry: Entry) bool {
            return a_entry.less(b_entry);
        }
    }.less);
    for (sorted) |row| try std.testing.expectEqual(row, heap.pop().?);
    try std.testing.expectEqual(@as(?Entry, null), heap.pop());
}

test "heap matches a scan oracle under interleaved pushes and pops" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rng = std.Random.DefaultPrng.init(0x265);
    const random = rng.random();
    var heap: Heap = .{};
    var oracle: std.ArrayList(Entry) = .empty;
    // Labels above 2^31 and keys that tie or differ only in low mantissa bits
    // check that the key always outranks the label in the combined order.
    const keys = [_]f32{ 0, -0.0, 1, 1.0000001, 2.5, 1e30, std.math.floatMax(f32) };
    var next_label: u32 = std.math.maxInt(u32);
    for (0..20000) |step| {
        // Grow and shrink repeatedly so every partial sibling group shape is
        // popped through, including the empty heap.
        const phase = (step / 700) % 2 == 0;
        if (random.uintLessThan(u32, 10) < @as(u32, if (phase) 7 else 3)) {
            const key = if (random.boolean())
                keys[random.uintLessThan(usize, keys.len)]
            else
                @as(f32, @floatFromInt(random.uintLessThan(u32, 64))) * 0.25;
            const label = if (random.boolean()) next_label else random.uintLessThan(u32, 1 << 20) * 4096 + @as(u32, @intCast(step % 4096));
            next_label -= 1;
            const entry = Entry.init(key, label);
            var duplicate = false;
            for (oracle.items) |row| duplicate = duplicate or std.meta.eql(row, entry);
            if (duplicate) continue;
            try heap.push(a, entry);
            try oracle.append(a, entry);
        } else {
            var least: ?usize = null;
            for (oracle.items, 0..) |row, i| {
                const better = if (least) |l| row.key < oracle.items[l].key or
                    (row.key == oracle.items[l].key and row.label < oracle.items[l].label) else true;
                if (better) least = i;
            }
            const expected: ?Entry = if (least) |i| oracle.swapRemove(i) else null;
            try t.expectEqual(expected, heap.peek());
            try t.expectEqual(expected, heap.pop());
        }
        try t.expectEqual(oracle.items.len, heap.items.items.len);
    }
}

const Uncancelled = struct {
    fn check(_: Uncancelled) error{Cancelled}!void {}
};

// Ported from test/double_bucket_queue.cc.
test "Valhalla bucket queue orders sparse and high float costs" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.InvalidBucketWidth, BucketQueue.init(0));
    var pending = try BucketQueue.init(1);
    const costs = [_]u32{ 67, 325, 25, 466, 1000, 100005, 758, 167, 258, 16442, 278, 111111000, 1320209856 };
    const sorted = [_]u32{ 25, 67, 167, 258, 278, 325, 466, 758, 1000, 16442, 100005, 111111000, 1320209856 };
    for (costs, 0..) |cost, index| try pending.push(a, .init(@floatFromInt(cost), @intCast(index)));
    for (sorted) |cost| {
        const entry = (try pending.popWithin(a, Uncancelled{})).?;
        try t.expectEqual(@as(f32, @floatFromInt(cost)), @as(f32, @bitCast(entry.key)));
    }
    try t.expectEqual(@as(?Entry, null), try pending.popWithin(a, Uncancelled{}));
    for (costs, 0..) |cost, index| try pending.push(a, .init(@floatFromInt(cost), @intCast(index)));
    pending.clear();
    try t.expectEqual(@as(?Entry, null), try pending.popWithin(a, Uncancelled{}));
}

// Ported from DoubleBucketQueue.TestSimulation with a seeded heap oracle.
test "bucket queue is byte-exact with the heap when mixed inserts cross windows" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rng = std.Random.DefaultPrng.init(0x82158);
    const random = rng.random();
    for ([_]u32{ 1, 1000, 100000 }) |width| {
        var buckets = try BucketQueue.init(width);
        var heap: Heap = .{};
        for (0..3300) |index| {
            const key = @as(f32, @floatFromInt(random.uintLessThan(u32, 1000000))) * 0.125;
            const entry = Entry.init(key, @intCast(index));
            try buckets.push(a, entry);
            try heap.push(a, entry);
            if (index % 3 == 0) try t.expectEqual(heap.pop(), try buckets.popWithin(a, Uncancelled{}));
        }
        while (heap.pop()) |entry| try t.expectEqual(@as(?Entry, entry), try buckets.popWithin(a, Uncancelled{}));
        try t.expectEqual(@as(?Entry, null), try buckets.popWithin(a, Uncancelled{}));
        _ = arena.reset(.retain_capacity);
    }
}

test "bucket queue can resume an interrupted refill without misordering entries" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buckets = try BucketQueue.init(1);
    var heap: Heap = .{};
    for (0..2048) |index| {
        const entry = Entry.init(300, @intCast(index));
        try buckets.push(a, entry);
        try heap.push(a, entry);
    }
    const CancelAfterFirstCheck = struct {
        checked: bool = false,

        fn check(self: *@This()) error{Cancelled}!void {
            if (self.checked) return error.Cancelled;
            self.checked = true;
        }
    };
    var control: CancelAfterFirstCheck = .{};
    try t.expectError(error.Cancelled, buckets.popWithin(a, &control));
    const later = Entry.init(300.25, 2048);
    try buckets.push(a, later);
    try heap.push(a, later);
    while (heap.pop()) |entry| try t.expectEqual(@as(?Entry, entry), try buckets.popWithin(a, Uncancelled{}));
    try t.expectEqual(@as(?Entry, null), try buckets.popWithin(a, Uncancelled{}));
}

test "radix queue preserves fractional costs and label ties" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pending: RadixQueue = .{};
    var heap: Heap = .{};
    var rng = std.Random.DefaultPrng.init(0x251);
    const random = rng.random();
    var minimum: f32 = 0;
    for (0..3300) |i| {
        const cost = minimum + @as(f32, @floatFromInt(random.uintLessThan(u32, 1024))) * 0.125;
        const entry = Entry.init(cost, @intCast(3300 - i));
        try heap.push(a, entry);
        try pending.push(a, entry);
        if (i % 3 == 0) {
            const expected = heap.pop().?;
            try t.expectEqual(@as(?Entry, expected), try pending.popWithin(a, Uncancelled{}));
            minimum = @bitCast(expected.key);
        }
    }
    while (heap.pop()) |entry| try t.expectEqual(@as(?Entry, entry), try pending.popWithin(a, Uncancelled{}));
    try t.expectEqual(@as(?Entry, null), try pending.popWithin(a, Uncancelled{}));
}

test "composite radix keys keep monotone ties in exact heap order" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pending = try OrderedRadixQueue.init(1);
    var heap: Heap = .{};
    var rng = std.Random.DefaultPrng.init(0x260);
    const random = rng.random();
    var minimum: f32 = 0;
    for (0..4096) |i| {
        const extra: u8 = if (i % 2 == 0) 0 else random.uintLessThan(u8, 64);
        const entry = Entry.init(minimum + @as(f32, @floatFromInt(extra)) * 0.125, @intCast(i));
        try heap.push(a, entry);
        try pending.push(a, entry);
        if (i % 3 != 0) continue;
        const expected = heap.pop().?;
        try t.expectEqual(@as(?Entry, expected), try pending.popWithin(a, Uncancelled{}));
        minimum = @bitCast(expected.key);
    }
    while (heap.pop()) |entry| try t.expectEqual(@as(?Entry, entry), try pending.popWithin(a, Uncancelled{}));
    try t.expectEqual(@as(?Entry, null), try pending.popWithin(a, Uncancelled{}));
}

test "radix queue retains entries across interrupted redistribution" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const CancelAfterFirstCheck = struct {
        checked: bool = false,

        fn check(self: *@This()) error{Cancelled}!void {
            if (self.checked) return error.Cancelled;
            self.checked = true;
        }
    };
    inline for (.{ RadixQueue, OrderedRadixQueue }) |Q| {
        var pending = try Q.init(1);
        for (0..1024) |label| try pending.push(a, Entry.init(300, @intCast(label)));

        var control: CancelAfterFirstCheck = .{};
        try t.expectError(error.Cancelled, pending.popWithin(a, &control));
        try t.expect(pending.redistributing != null);
        try pending.push(a, Entry.init(300.25, 1024));
        for (0..1024) |label| {
            try t.expectEqual(@as(?Entry, Entry.init(300, @intCast(label))), try pending.popWithin(a, Uncancelled{}));
        }
        try t.expectEqual(@as(?Entry, Entry.init(300.25, 1024)), try pending.popWithin(a, Uncancelled{}));
        try t.expectEqual(@as(?Entry, null), try pending.popWithin(a, Uncancelled{}));
    }
}
