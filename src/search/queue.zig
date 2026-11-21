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
        return a.key < b.key or (a.key == b.key and a.label < b.label);
    }
};

comptime {
    std.debug.assert(@sizeOf(Entry) == 8);
    std.debug.assert(@offsetOf(Entry, "key") == 0 and @offsetOf(Entry, "label") == 4);
}

pub const Heap = struct {
    items: std.ArrayList(Entry) = .empty,

    pub fn push(self: *Heap, arena: std.mem.Allocator, entry: Entry) !void {
        try self.items.ensureUnusedCapacity(arena, 1);
        var hole = self.items.items.len;
        self.items.items.len += 1;
        while (hole != 0) {
            const parent = (hole - 1) / 4;
            const item = self.items.items[parent];
            if (!entry.less(item)) break;
            self.items.items[hole] = item;
            hole = parent;
        }
        self.items.items[hole] = entry;
    }

    pub fn peek(self: *const Heap) ?Entry {
        return if (self.items.items.len == 0) null else self.items.items[0];
    }

    pub fn pop(self: *Heap) ?Entry {
        if (self.items.items.len == 0) return null;
        const root = self.items.items[0];
        const last = self.items.pop().?;
        const items = self.items.items;
        if (items.len == 0) return root;

        var hole: usize = 0;
        while (hole <= (items.len - 1) / 4) {
            const first = hole * 4 + 1;
            if (first >= items.len) break;
            var least = first;
            for (first + 1..@min(items.len, first + 4)) |i| {
                if (items[i].less(items[least])) least = i;
            }
            if (!items[least].less(last)) break;
            items[hole] = items[least];
            hole = least;
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
pub const RadixQueue = struct {
    buckets: [32]std.ArrayList(Entry) = @splat(.empty),
    equal: Heap = .{},
    nonempty: u32 = 0,
    minimum: u32 = 0,
    redistributing: ?u5 = null,

    pub fn init(unit_size: u32) !RadixQueue {
        if (unit_size == 0) return error.InvalidBucketWidth;
        return .{};
    }

    pub fn push(self: *RadixQueue, arena: std.mem.Allocator, entry: Entry) !void {
        if (entry.key < self.minimum) return error.NonmonotonePriority;
        const differing = entry.key ^ self.minimum;
        if (differing == 0) return self.equal.push(arena, entry);
        const index: u5 = @intCast(31 - @clz(differing));
        try self.buckets[index].append(arena, entry);
        self.nonempty |= @as(u32, 1) << index;
    }

    pub fn popWithin(self: *RadixQueue, arena: std.mem.Allocator, control: anytype) !?Entry {
        if (self.redistributing != null) {
            try self.redistribute(arena, control);
        } else if (self.equal.items.items.len == 0) {
            if (self.nonempty == 0) return null;
            const index: u5 = @intCast(@ctz(self.nonempty));
            var minimum: u32 = std.math.maxInt(u32);
            for (self.buckets[index].items, 0..) |entry, i| {
                if (i % 256 == 0) try control.check();
                minimum = @min(minimum, entry.key);
            }
            self.minimum = minimum;
            self.redistributing = index;
            try self.redistribute(arena, control);
        }
        return self.equal.pop();
    }

    noinline fn redistribute(self: *RadixQueue, arena: std.mem.Allocator, control: anytype) !void {
        const index = self.redistributing.?;
        const bucket = &self.buckets[index];
        var moved: usize = 0;
        while (bucket.last()) |entry| : (moved += 1) {
            if (moved % 256 == 0) try control.check();
            // Lowering the differing bit puts every moved entry in a
            // strictly lower bucket. Keep its original copy until push succeeds.
            try self.push(arena, entry);
            _ = bucket.pop();
        }
        self.nonempty &= ~(@as(u32, 1) << index);
        self.redistributing = null;
    }
};

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

test "radix queue retains entries across interrupted redistribution" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pending = try RadixQueue.init(1);
    for (0..1024) |label| try pending.push(a, Entry.init(300, @intCast(label)));

    const CancelAfterFiveChecks = struct {
        remaining: usize = 5,

        fn check(self: *@This()) error{Cancelled}!void {
            if (self.remaining == 0) return error.Cancelled;
            self.remaining -= 1;
        }
    };
    var control: CancelAfterFiveChecks = .{};
    try t.expectError(error.Cancelled, pending.popWithin(a, &control));
    try t.expect(pending.redistributing != null);
    for (0..1024) |label| {
        try t.expectEqual(@as(?Entry, Entry.init(300, @intCast(label))), try pending.popWithin(a, Uncancelled{}));
    }
    try t.expectEqual(@as(?Entry, null), try pending.popWithin(a, Uncancelled{}));
}
