//! Weak components of the physical road graph, stored by dense node ID.
const std = @import("std");
const format = @import("../graph/format.zig");
const Deadline = @import("../infra/io.zig").Deadline;

pub fn label(parent: []u32, offsets: []const u32, edges: []const format.EdgeHot, deadline: Deadline) !void {
    if (offsets.len != parent.len + 1 or offsets[0] != 0 or offsets[parent.len] != edges.len or
        parent.len > std.math.maxInt(u32)) return error.InvalidComponentTopology;
    for (parent, 0..) |*component, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        component.* = @intCast(i);
    }
    for (offsets[0..parent.len], offsets[1..], 0..) |start, end, node| {
        if (node % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (end < start or end > edges.len or end - start > 32) return error.InvalidComponentTopology;
        for (edges[start..end]) |edge| {
            if (edge.head >= parent.len) return error.InvalidComponentTopology;
            if (edge.head >= node) continue;
            const a = try root(parent, @intCast(node), deadline);
            const b = try root(parent, edge.head, deadline);
            parent[@max(a, b)] = @min(a, b);
        }
    }
    // Every parent is smaller than its child, so one ascending pass suffices.
    for (parent, 0..) |*component, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        component.* = parent[component.*];
    }
}

fn root(parent: []u32, start: u32, deadline: Deadline) !u32 {
    var node = start;
    var count: usize = 0;
    while (parent[node] != node) : (count += 1) {
        if (count % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        parent[node] = parent[parent[node]];
        node = parent[node];
    }
    return node;
}
