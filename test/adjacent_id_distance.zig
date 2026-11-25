const std = @import("std");
const graph = @import("routing").graph;

pub const Summary = struct {
    median: f64 = 0,
    p90: u32 = 0,
    p99: u32 = 0,
    max: u32 = 0,
    undirected_edges: usize = 0,
    at_distance_one: usize = 0,
};

/// Measure each undirected edge once. Ranks are indexed by the bundle's node
/// IDs and let the partition benchmark evaluate an order before rebuilding.
pub fn median(allocator: std.mem.Allocator, view: *const graph.reader.View, ranks: ?[]const u32) !f64 {
    return (try summary(allocator, view, ranks)).median;
}

/// The median and tail of the adjacent ID distances, with the count of
/// edges whose ends take consecutive IDs.
pub fn summary(allocator: std.mem.Allocator, view: *const graph.reader.View, ranks: ?[]const u32) !Summary {
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
    if (count == 0) return .{};
    std.mem.sortUnstable(u32, distances, {}, std.sort.asc(u32));
    const middle = @as(u64, distances[(count - 1) / 2]) + distances[count / 2];
    return .{
        .median = @as(f64, @floatFromInt(middle)) / 2,
        .p90 = distances[(count - 1) * 9 / 10],
        .p99 = distances[(count - 1) * 99 / 100],
        .max = distances[count - 1],
        .undirected_edges = count,
        .at_distance_one = std.sort.upperBound(u32, distances, @as(u32, 1), orderU32) - std.sort.lowerBound(u32, distances, @as(u32, 1), orderU32),
    };
}

fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}
