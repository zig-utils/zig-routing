//! Node-level reverse distance bounds for a single destination column.
const std = @import("std");
const graph = @import("../graph/root.zig");
const search = @import("../search/search.zig");
const queue = @import("../search/queue.zig");
const NodeId = graph.format.NodeId;
const View = graph.reader.View;

const Distances = std.AutoHashMapUnmanaged(u32, u16);

pub const Bounds = struct {
    settled: Distances,
    frontier: u16,

    pub fn rulesOut(self: Bounds, node: NodeId, metres: f32, limit: f32) bool {
        if (metres >= limit) return true;
        const suffix = self.settled.get(@backingInt(node)) orelse self.frontier;
        const start: u32 = @intFromFloat(metres);
        // Every full edge length is an integer. Under 2^24 the sum of
        // the floors is exactly representable, and rounding the actual
        // f32 addition cannot fall below that integer.
        return start + suffix >= @as(u32, @intFromFloat(@ceil(limit)));
    }
};

/// Reverse search relaxes a superset of legal turns, directions and
/// access states. The forward search still evaluates each actual move.
pub const Builder = struct {
    const settle_limit = 48;
    const discover_limit = 128;
    const radius_limit = 512;
    const Entry = struct { node: u32, metres: u16 };

    allocator: std.mem.Allocator,
    view: *const View,
    ceiling: u16,
    pending: queue.Heap = .{},
    seen: Distances = .empty,
    saturated: bool = false,

    pub fn init(a: std.mem.Allocator, view: *const View, limit: f32) ?Builder {
        if (!(limit > 0 and limit <= 1 << 24)) return null;
        const ceiling: u16 = @intFromFloat(@min(radius_limit, @ceil(limit)));
        return .{ .allocator = a, .view = view, .ceiling = ceiling };
    }

    pub fn addNode(self: *Builder, node: NodeId) !void {
        try self.offer(@backingInt(node), 0);
    }

    pub fn addEdge(self: *Builder, edge: graph.format.EdgeId, fraction: f32) !void {
        const forward = try self.view.edge(edge);
        const reverse = try self.view.edge(try self.view.opposingId(forward));
        const length: f32 = @floatFromInt(forward.geom.len_m);
        // Match priceCut's f32 product before taking the floor. Dropping
        // turn and access constraints gives a lower bound at the edge tail.
        try self.offer(reverse.head, @intFromFloat(length * fraction));
    }

    fn offer(self: *Builder, node: u32, metres: u32) !void {
        if (metres >= self.ceiling) return;
        const distance: u16 = @intCast(metres);
        if (self.seen.getPtr(node)) |prior| {
            if (prior.* <= distance) return;
            prior.* = distance;
        } else {
            if (self.seen.count() == discover_limit) {
                self.saturated = true;
                return;
            }
            try self.seen.put(self.allocator, node, distance);
        }
        try self.pending.push(self.allocator, .{ .key = distance, .label = node });
    }

    pub fn finish(self: *Builder, a: std.mem.Allocator, control: search.Control) !?Bounds {
        if (self.saturated or self.pending.peek() == null) return null;
        var entries: [settle_limit]Entry = undefined;
        var len: usize = 0;
        var frontier = self.ceiling;
        while (self.pending.pop()) |top| {
            try control.check();
            if (self.seen.get(top.label).? != top.key) continue;
            if (len == settle_limit) {
                frontier = @intCast(top.key);
                break;
            }
            entries[len] = .{ .node = top.label, .metres = @intCast(top.key) };
            len += 1;
            for (try self.view.outEdges(@fromBackingInt(top.label))) |*outward| {
                const incoming = try self.view.edge(try self.view.opposingId(outward));
                try self.offer(outward.head, top.key + incoming.geom.len_m);
                if (self.saturated) break;
            }
            if (self.saturated) {
                // With nonnegative arcs, every unprocessed route has at
                // least the distance of the node we just started.
                frontier = @intCast(top.key);
                break;
            }
        }
        if (frontier == 0) return null;
        var settled: Distances = .empty;
        try settled.ensureTotalCapacity(a, @intCast(len));
        for (entries[0..len]) |entry| settled.putAssumeCapacity(entry.node, entry.metres);
        return .{ .settled = settled, .frontier = frontier };
    }
};
