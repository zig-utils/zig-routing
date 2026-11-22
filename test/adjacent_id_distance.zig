const std = @import("std");
const graph = @import("routing").graph;

/// Measure each undirected edge once. Ranks are indexed by the bundle's node
/// IDs and let the partition benchmark evaluate an order before rebuilding.
pub fn median(allocator: std.mem.Allocator, view: *const graph.reader.View, ranks: ?[]const u32) !f64 {
    if (ranks) |ids| {
        if (ids.len != view.nodes.len) return error.InvalidOrder;
    }
    const distances = try allocator.alloc(u32, view.edges.len / 2);
    defer allocator.free(distances);
    var count: usize = 0;
    for (0..view.nodes.len) |i| {
        const node: u32 = @intCast(i);
        const range = try view.outEdgeRange(@fromBackingInt(node));
        const tail = if (ranks) |ids| ids[node] else node;
        for (range.first..range.end) |j| {
            const id: graph.format.EdgeId = @fromBackingInt(@as(u32, @intCast(j)));
            if (j >= @backingInt(try view.oppEdge(id))) continue;
            if (count == distances.len) return error.InvalidOpposingCount;
            const neighbor = view.edges[j].head;
            const head = if (ranks) |ids| ids[neighbor] else neighbor;
            distances[count] = @max(tail, head) - @min(tail, head);
            count += 1;
        }
    }
    if (count != distances.len) return error.InvalidOpposingCount;
    if (count == 0) return 0;
    std.mem.sortUnstable(u32, distances, {}, std.sort.asc(u32));
    const middle = @as(u64, distances[(count - 1) / 2]) + distances[count / 2];
    return @as(f64, @floatFromInt(middle)) / 2;
}
