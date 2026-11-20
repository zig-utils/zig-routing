//! Match borrowed strings from the pinned Valhalla fixtures.
const std = @import("std");
const Snapshot = @import("zig_test_framework").Snapshot;

pub fn match(name: []const u8, expected: []const u8, actual: []const u8) !void {
    var snapshot = Snapshot.init(std.testing.allocator, name, .{});
    try snapshot.matchExpectedString(expected, actual);
}

pub fn count(expected: usize, actual: usize) !void {
    try std.testing.expectEqual(expected, actual);
}
