//! Arena-backed sparse status arrays indexed by dense u32 graph IDs.
const std = @import("std");

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
