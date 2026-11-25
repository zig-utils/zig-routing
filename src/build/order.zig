//! Node ID ordering independent from topology and section emission.
const std = @import("std");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const geo = @import("../geo/point.zig");
const grid = @import("../geo/grid.zig");
const format = @import("../graph/format.zig");
const Allocator = std.mem.Allocator;

pub const Ordering = struct {
    kind: format.OrderingKind = .hilbert,

    /// The output maps each new dense ID to its provisional node ID.
    /// Equal Hilbert keys keep their provisional order.
    pub fn permutation(self: Ordering, gpa: Allocator, points: []const geo.FixedLL, deadline: io.Deadline) ![]u32 {
        if (points.len > std.math.maxInt(u32)) return error.TooManyNodes;
        const ids = try gpa.alloc(u32, points.len);
        errdefer gpa.free(ids);
        for (ids, 0..) |*id, i| {
            try check(deadline, i);
            id.* = @intCast(i);
        }
        switch (self.kind) {
            // Needs the topology, so the build orders it in its own stage.
            .nested_dissection => return error.UnsupportedOrdering,
            .encounter => {},
            .hilbert => {
                if (points.len < 2) return ids;
                const keys = try gpa.alloc(u64, points.len);
                defer gpa.free(keys);
                const scratch = try gpa.alloc(u32, points.len);
                defer gpa.free(scratch);
                for (points, keys, 0..) |point, *key, i| {
                    try check(deadline, i);
                    key.* = grid.hilbertOfPoint(31, point.toPoint());
                }
                try radix.sortByU64(u32, gpa, ids, scratch, @as([]const u64, keys), nodeKey, deadline);
            },
        }
        return ids;
    }
};

fn nodeKey(keys: []const u64, node: u32) u64 {
    return keys[node];
}

pub fn hash(ids: []const u32, deadline: io.Deadline) !u64 {
    var hasher: std.hash.XxHash3 = .init(0);
    var rest = ids;
    while (rest.len != 0) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const chunk = rest[0..@min(rest.len, 64 * 1024)];
        hasher.update(std.mem.sliceAsBytes(chunk));
        rest = rest[chunk.len..];
    }
    return hasher.final();
}

fn check(deadline: io.Deadline, i: usize) !void {
    if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

test "Hilbert permutation keeps the original order of equal coordinates" {
    const testing = std.testing;
    const points = [_]geo.FixedLL{
        .{ .lng = 0, .lat = 100 },
        .{ .lng = -100, .lat = 0 },
        .{ .lng = 0, .lat = 100 },
        .{ .lng = -2_000_000, .lat = -2_000_000 },
    };
    const algorithm: Ordering = .{};
    const perm = try algorithm.permutation(testing.allocator, &points, .none);
    defer testing.allocator.free(perm);
    const encounter: Ordering = .{ .kind = .encounter };
    const identity = try encounter.permutation(testing.allocator, &points, .none);
    defer testing.allocator.free(identity);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, identity);
    var seen: [points.len]bool = @splat(false);
    var last_key: u64 = 0;
    var last_id: u32 = 0;
    for (perm, 0..) |id, i| {
        try testing.expect(!seen[id]);
        seen[id] = true;
        const key = grid.hilbertOfPoint(31, points[id].toPoint());
        try testing.expect(key >= last_key);
        if (i != 0 and key == last_key) try testing.expect(id > last_id);
        last_id = id;
        last_key = key;
    }
    try testing.expect(!std.mem.eql(u32, perm, identity));
    try testing.expectError(error.DeadlineExceeded, algorithm.permutation(testing.allocator, &points, .{ .at_ns = 0 }));
}
