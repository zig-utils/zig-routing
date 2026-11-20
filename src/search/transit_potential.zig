//! Reverse costs on a relaxed graph of walking and scheduled rides.
const std = @import("std");
const graph = @import("../graph/root.zig");
const Kernel = @import("../costing/multimodal.zig").Kernel;
const core = @import("search.zig");
const endpoints = @import("endpoints.zig");
const paged = @import("paged.zig");
const queue = @import("queue.zig");
const Allocator = std.mem.Allocator;
const View = graph.reader.View;
const EdgeId = graph.format.EdgeId;
const NodeId = graph.format.NodeId;
const infinity = std.math.inf(f32);

const Status = struct { cost: f32 = infinity, settled: bool = false };

pub const Potential = struct {
    nodes: paged.Array(Status, .{}) = .{},
    unsettled_floor: f32 = 0,

    pub fn init(a: Allocator, view: *const View, kernel: *const Kernel, timetable: anytype, minimum_ride: []const f32, targets: *const endpoints.Targets, ceiling: f32, control: core.Control) !Potential {
        // Any competing path below the ceiling loses at most one float
        // spacing per addition. Removing that spacing from each increment
        // bounds its cost even when the reverse traversal sums in a
        // different order. Omitted waits, turns and transfers are nonnegative.
        const bits: u32 = @bitCast(ceiling);
        const next: f32 = @bitCast(bits + 1);
        const spacing = if (std.math.isFinite(next)) @as(f64, next) - ceiling else @as(f64, ceiling) - @as(f32, @bitCast(bits - 1));
        var result: Potential = .{};
        var pending: queue.Heap = .{};
        defer pending.items.deinit(a);
        for (targets.entries) |item| {
            try control.check();
            const candidate = item.candidate;
            const edge = try view.edge(candidate.edge);
            const from = try view.edge(try view.oppEdge(candidate.edge));
            const full = try walkCost(view, kernel, edge);
            if (!std.math.isFinite(full)) continue;
            const partial = full * candidate.fraction + candidate.score;
            try result.offer(a, &pending, from.head, @max(0, @as(f64, partial) - spacing), ceiling);
        }

        // Distance to an unsettled node is at least the last settled cost.
        // This lets us bound construction without pruning the forward search.
        var settled: usize = 0;
        while (settled < 32768) {
            try control.check();
            const item = pending.pop() orelse break;
            const status = try result.nodes.at(a, item.label);
            if (item.key != @as(u32, @bitCast(status.cost)) or status.settled) continue;
            const cost: f64 = status.cost;
            result.unsettled_floor = status.cost;
            status.settled = true;
            settled += 1;
            const node: NodeId = @fromBackingInt(item.label);
            const range = try view.outEdgeRange(node);
            for (view.edges[range.first..range.end], range.first..) |edge, i| {
                const id: EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
                const forward = try view.edge(try view.oppEdge(id));
                const increment = try walkCost(view, kernel, forward);
                try result.offer(a, &pending, edge.head, cost + @max(0, @as(f64, increment) - spacing), ceiling);
            }
            if (timetable) |index| {
                const stop = index.platformAt(node) orelse continue;
                const table = view.transit_index.?;
                for (try index.incoming(stop)) |id| {
                    try control.check();
                    const line = table.lines[id];
                    const origin = table.stops[line.origin].place.graph_node;
                    if (origin == graph.transit.no_id) continue;
                    try result.offer(a, &pending, origin, cost + @max(0, @as(f64, minimum_ride[id]) - spacing), ceiling);
                }
            }
        }
        return result;
    }

    pub fn estimate(self: *const Potential, node: NodeId) f32 {
        const status = self.nodes.get(@backingInt(node));
        return if (status.settled) status.cost else self.unsettled_floor;
    }

    fn offer(self: *Potential, a: Allocator, pending: *queue.Heap, node: u32, cost: f64, ceiling: f32) !void {
        if (cost > ceiling) return;
        const rounded = core.roundedDown(cost);
        const current = try self.nodes.at(a, node);
        if (rounded >= current.cost) return;
        std.debug.assert(!current.settled);
        current.cost = rounded;
        try pending.push(a, queue.Entry.init(rounded, node));
    }
};

fn walkCost(view: *const View, kernel: *const Kernel, edge: *const graph.format.EdgeHot) !f32 {
    const class = try view.class(edge.cls.class_id);
    return kernel.walkCost(class, edge.*, kernel.walking.untimedFerrySpeed(edge.*), .{}).cost;
}
