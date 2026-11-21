//! Iteration order of the unique edge sets used by the pinned Meili oracle.
const std = @import("std");
const graph = @import("../graph/root.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;
const EdgeId = graph.format.EdgeId;

pub const Arc = struct {
    edge: EdgeId,
    shape: EdgeId,
    hash: u64,
};

const before_head = std.math.maxInt(u32);
const empty_bucket = before_head - 1;

const Node = struct {
    arc: Arc,
    bucket: u32,
    next: u32 = before_head,
};

/// Meili visits two successive unordered sets. The reference uses prime
/// buckets and a single forward list, with each bucket's nodes adjacent.
/// Insertion in a new bucket prepends a group. Insertion in an occupied
/// bucket prepends within that group. Rehashing traverses the old list.
pub const Set = struct {
    // Bucket counts visited by the pinned libstdc++ unique-key growth policy.
    const primes = [_]u32{
        13,        29,        59,         127,        257,      541,      1109,      2357,
        5087,      10273,     20753,      42043,      85229,    172933,   351061,    712697,
        1447153,   2938679,   5967347,    12117689,   24607243, 49969847, 101473717, 206062531,
        418451333, 849749479, 1725587117, 3504151727,
    };

    buckets: std.ArrayList(u32) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    head: u32 = before_head,
    level: usize = 0,

    pub fn deinit(self: *Set, a: Allocator) void {
        self.buckets.deinit(a);
        self.nodes.deinit(a);
    }

    pub fn clear(self: *Set) void {
        self.buckets.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.head = before_head;
        self.level = 0;
    }

    pub fn insert(self: *Set, a: Allocator, arc: Arc, deadline: Deadline) !void {
        var slot: u32 = if (self.level == 0) 0 else self.bucket(arc.hash);
        if (self.level != 0 and try self.contains(slot, arc.edge, deadline)) return;
        if (self.nodes.items.len == self.buckets.items.len) {
            if (self.level == primes.len) return error.TooManyTraceEdges;
            try self.buckets.resize(a, primes[self.level]);
            self.level += 1;
            @memset(self.buckets.items, empty_bucket);
            var index = self.head;
            self.head = before_head;
            while (index != before_head) {
                if (deadline.expired()) return error.DeadlineExceeded;
                const next = self.nodes.items[index].next;
                self.nodes.items[index].bucket = self.bucket(self.nodes.items[index].arc.hash);
                self.link(index);
                index = next;
            }
            slot = self.bucket(arc.hash);
        }
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(a, .{ .arc = arc, .bucket = slot });
        self.link(index);
    }

    fn bucket(self: *const Set, hash: u64) u32 {
        return @intCast(switch (self.level) {
            1 => hash % primes[0],
            2 => hash % primes[1],
            3 => hash % primes[2],
            4 => hash % primes[3],
            else => hash % self.buckets.items.len,
        });
    }

    fn contains(self: *const Set, slot: u32, edge: EdgeId, deadline: Deadline) !bool {
        const previous = self.buckets.items[slot];
        var index = switch (previous) {
            empty_bucket => return false,
            before_head => self.head,
            else => self.nodes.items[previous].next,
        };
        while (index != before_head) {
            const node = self.nodes.items[index];
            if (node.bucket != slot) break;
            if (node.arc.edge == edge) return true;
            if (deadline.expired()) return error.DeadlineExceeded;
            index = node.next;
        }
        return false;
    }

    fn link(self: *Set, index: u32) void {
        const node = &self.nodes.items[index];
        const slot = node.bucket;
        const previous = self.buckets.items[slot];
        switch (previous) {
            empty_bucket => {
                if (self.head != before_head) self.buckets.items[self.nodes.items[self.head].bucket] = index;
                node.next = self.head;
                self.head = index;
                self.buckets.items[slot] = before_head;
            },
            before_head => {
                node.next = self.head;
                self.head = index;
            },
            else => {
                const predecessor = &self.nodes.items[previous];
                node.next = predecessor.next;
                predecessor.next = index;
            },
        }
    }

    pub const Iterator = struct {
        set: *const Set,
        index: u32,

        pub fn next(self: *Iterator) ?Arc {
            if (self.index == before_head) return null;
            const node = self.set.nodes.items[self.index];
            self.index = node.next;
            return node.arc;
        }
    };

    pub fn iterator(self: *const Set) Iterator {
        return .{ .set = self, .index = self.head };
    }
};

test "Meili bucket order survives collisions, duplicates and rehashing" {
    var set: Set = .{};
    defer set.deinit(std.testing.allocator);
    for (0..16) |i| {
        const id: EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
        const arc: Arc = .{ .edge = id, .shape = id, .hash = i * 13 };
        try set.insert(std.testing.allocator, arc, .none);
        try set.insert(std.testing.allocator, arc, .none);
    }
    var items = set.iterator();
    for ([_]u32{ 15, 14, 13, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }) |id| {
        try std.testing.expectEqual(id, @backingInt((items.next() orelse return error.MissingEdge).edge));
    }
    try std.testing.expect(items.next() == null);
}
