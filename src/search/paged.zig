//! Arena-backed sparse status arrays indexed by dense u32 graph IDs.
const std = @import("std");
const memory = @import("../infra/arena.zig");

/// Dense IDs with sparse 16 KiB pages. Only the directory is worker-owned.
/// Touched slots must be cleared before the request memory is rewound.
pub fn EdgeStatus(comptime T: type) type {
    return struct {
        const Self = @This();
        const page_shift = 12;
        const per_page = 1 << page_shift;
        const Pool = memory.PagePool(16 * 1024);
        const Page = [per_page]T;

        comptime {
            std.debug.assert(@sizeOf(T) == 4 and @alignOf(T) <= 64);
        }

        slots: []?*align(64) Page,
        touched: std.ArrayList(u32) = .empty,

        pub fn init(gpa: std.mem.Allocator, count: usize) !Self {
            const len = count / per_page + @intFromBool(count % per_page != 0);
            const slots = try gpa.alloc(?*align(64) Page, len);
            @memset(slots, null);
            return .{ .slots = slots };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.slots);
            self.* = undefined;
        }

        pub fn get(self: *const Self, id: u32) T {
            const page = self.slots[id >> page_shift] orelse return @bitCast(@as(u32, 0));
            return page[id & (per_page - 1)];
        }

        /// Inline so the search loop pays one directory load and a branch.
        /// Only the first write to a page leaves it.
        pub inline fn at(self: *Self, pool: *Pool, id: u32) !*T {
            const page = self.slots[id >> page_shift] orelse try self.touch(pool, id >> page_shift);
            return &page[id & (per_page - 1)];
        }

        noinline fn touch(self: *Self, pool: *Pool, index: u32) !*align(64) Page {
            try self.touched.append(pool.arena.allocator(), index);
            const page: *align(64) Page = @ptrCast(try pool.get());
            self.slots[index] = page;
            return page;
        }

        pub fn clear(self: *Self) void {
            for (self.touched.items) |index| self.slots[index] = null;
            self.touched = .empty;
        }
    };
}

pub fn Array(comptime T: type, comptime empty: T) type {
    return struct {
        const Self = @This();
        const Page = [256]T;
        const Directory = [256]?*Page;
        const Branch = [256]?*Directory;

        roots: [256]?*Branch = @splat(null),

        pub fn get(self: *const Self, id: u32) T {
            const branch = self.roots[id >> 24] orelse return empty;
            const dir = branch[@as(u8, @truncate(id >> 16))] orelse return empty;
            const page = dir[@as(u8, @truncate(id >> 8))] orelse return empty;
            return page[@as(u8, @truncate(id))];
        }

        pub fn at(self: *Self, arena: std.mem.Allocator, id: u32) !*T {
            const branch = try ensure(Branch, arena, &self.roots[id >> 24], @splat(null));
            const dir = try ensure(Directory, arena, &branch[@as(u8, @truncate(id >> 16))], @splat(null));
            const page = try ensure(Page, arena, &dir[@as(u8, @truncate(id >> 8))], @splat(empty));
            return &page[@as(u8, @truncate(id))];
        }
    };
}

fn ensure(comptime T: type, arena: std.mem.Allocator, slot: *?*T, value: T) !*T {
    if (slot.*) |present| return present;
    const storage = try arena.create(T);
    storage.* = value;
    slot.* = storage;
    return storage;
}

test "paged status distinguishes high and low dense IDs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var status: Array(u32, 0) = .{};
    for ([_]u32{ 1, 256, 65536, 16777216, std.math.maxInt(u32) }, 1..) |id, i| {
        (try status.at(arena.allocator(), id)).* = @intCast(i);
    }
    try std.testing.expectEqual(1, status.get(1));
    try std.testing.expectEqual(0, status.get(16777217));
    try std.testing.expectEqual(5, status.get(std.math.maxInt(u32)));
}

test "edge status allocates only touched 16 KiB pages and clears their directory slots" {
    const t = std.testing;
    var arena = memory.Arena.init(t.allocator, .{});
    defer arena.deinit();
    var pool = memory.PagePool(16 * 1024).init(&arena);
    var status = try EdgeStatus(u32).init(t.allocator, 4096 * 128);
    defer status.deinit(t.allocator);
    const high: u32 = 4096 * 125 + 17;
    try t.expectEqual(0, status.get(high));
    (try status.at(&pool, 4095)).* = 3;
    (try status.at(&pool, high)).* = 5;
    try t.expectEqual(3, status.get(4095));
    try t.expectEqual(5, status.get(high));
    try t.expectEqual(0, status.get(4096));
    try t.expectEqual(2, status.touched.items.len);
    status.clear();
    arena.reset();
    try t.expectEqual(0, status.get(4095));
    try t.expectEqual(0, status.get(high));
    (try status.at(&pool, high)).* = 7;
    try t.expectEqual(7, status.get(high));
    status.clear();
}
