//! Reverse costs on a relaxed graph of walking and scheduled rides.
const std = @import("std");
const graph = @import("../graph/root.zig");
const costing = @import("../costing/multimodal.zig");
const Kernel = costing.Kernel;
const Cost = @import("../costing/compiled.zig").Cost;
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
    /// Add the same offset to every complete path so the reverse search
    /// can represent negative terminal costs on its nonnegative queue.
    terminal_shift: f64 = 0,

    pub fn init(a: Allocator, view: *const View, kernel: *const Kernel, timetable: anytype, minimum_ride: []const f32, targets: *const endpoints.Targets, ceiling: f32, control: core.Control) !Potential {
        var result: Potential = .{};
        var max_remainder: f32 = 0;
        for (targets.entries) |item| {
            try control.check();
            const candidate = item.candidate;
            const edge = try view.edge(candidate.edge);
            const base_cost = try walkBase(view, kernel, edge);
            const full = kernel.scaleWalkCost(base_cost).cost;
            if (!std.math.isFinite(full)) continue;
            const remainder = costing.destinationRemainder(base_cost, candidate.fraction, candidate.score).cost;
            max_remainder = @max(max_remainder, remainder);
            result.terminal_shift = @max(result.terminal_shift, @as(f64, remainder) - full);
        }
        // Any competing path below the ceiling loses at most one float
        // spacing per addition. Removing that spacing from each increment
        // bounds its cost even when the reverse traversal sums in a
        // different order. The last addition can be larger than the ceiling
        // by the destination remainder. Waits, turns and transfers are nonnegative.
        const bound = core.roundedDown(@as(f64, ceiling) + max_remainder);
        const bits: u32 = @bitCast(bound);
        const next: f32 = @bitCast(bits + 1);
        const spacing = if (std.math.isFinite(next)) @as(f64, next) - bound else @as(f64, bound) - @as(f32, @bitCast(bits - 1));
        var pending: queue.Heap = .{};
        defer pending.items.deinit(a);
        for (targets.entries) |item| {
            try control.check();
            const candidate = item.candidate;
            const edge = try view.edge(candidate.edge);
            const from = try view.edge(try view.oppEdge(candidate.edge));
            const base_cost = try walkBase(view, kernel, edge);
            const full = kernel.scaleWalkCost(base_cost).cost;
            if (!std.math.isFinite(full)) continue;
            const remainder = costing.destinationRemainder(base_cost, candidate.fraction, candidate.score);
            const partial = @as(f64, full) - remainder.cost;
            try result.offer(a, &pending, from.head, @max(0, partial + result.terminal_shift - 2 * spacing), ceiling);
        }

        // Settle the reverse costs within the current ceiling. A node
        // outside that range can still use the last settled cost as a bound.
        while (pending.pop()) |item| {
            try control.check();
            const status = try result.nodes.at(a, item.label);
            if (item.key != @as(u32, @bitCast(status.cost)) or status.settled) continue;
            const cost: f64 = status.cost;
            result.unsettled_floor = status.cost;
            status.settled = true;
            const node: NodeId = @fromBackingInt(item.label);
            const range = try view.outEdgeRange(node);
            for (view.edges[range.first..range.end], range.first..) |edge, i| {
                const id: EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
                const forward = try view.edge(try view.oppEdge(id));
                const increment = kernel.scaleWalkCost(try walkBase(view, kernel, forward)).cost;
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

fn walkBase(view: *const View, kernel: *const Kernel, edge: *const graph.format.EdgeHot) !Cost {
    const class = try view.class(edge.cls.class_id);
    return kernel.baseWalkCost(class, edge.*, kernel.walking.untimedFerrySpeed(edge.*), .{});
}
