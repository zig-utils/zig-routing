//! A four-way min heap. Search keeps old entries until they reach the root.

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
