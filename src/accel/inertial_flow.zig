//! Unit-capacity Dinic on undirected CSR. The two directed entries of an
//! undirected edge are each other's residual reverses.
const std = @import("std");
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;

pub const Arc = struct { head: u32, reverse: u32 };
pub const unseen = std.math.maxInt(u32);

pub const Network = struct {
    offsets: []const u32,
    arcs: []const Arc,

    pub fn edgeRange(self: Network, node: u32) struct { u32, u32 } {
        return .{ self.offsets[node], self.offsets[@as(usize, node) + 1] };
    }
};

pub const Flow = struct {
    residual: []u8,
    levels: []u32,
    next: []u32,
    queue: []u32,

    pub fn init(a: Allocator, graph: Network) !Flow {
        const n = graph.offsets.len - 1;
        const residual = try a.alloc(u8, graph.arcs.len);
        errdefer a.free(residual);
        const levels = try a.alloc(u32, n);
        errdefer a.free(levels);
        const next = try a.alloc(u32, n);
        errdefer a.free(next);
        return .{ .residual = residual, .levels = levels, .next = next, .queue = try a.alloc(u32, n) };
    }

    pub fn deinit(self: Flow, a: Allocator) void {
        a.free(self.queue);
        a.free(self.next);
        a.free(self.levels);
        a.free(self.residual);
    }

    /// Terminals are the first and last `pinned` vertices in the projection.
    /// Treat them as connected to virtual terminals with infinite capacity.
    /// On return, levels mark the source side of the minimum cut.
    pub fn run(self: Flow, graph: Network, order: []const u32, pinned: usize, deadline: Deadline) !u32 {
        @memset(self.residual, 1);
        @memset(self.next, 0);
        for (order[order.len - pinned ..], 0..) |sink, i| {
            try check(deadline, i);
            self.next[sink] = unseen;
        }
        var value: u32 = 0;
        while (true) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const sink_level = try self.bfs(graph, order[0..pinned], deadline);
            if (sink_level == unseen) return value;
            for (self.next, graph.offsets[0..order.len], 0..) |*next, first, i| {
                try check(deadline, i);
                if (next.* != unseen) next.* = first;
            }
            for (order[0..pinned], 0..) |source, i| {
                try check(deadline, i);
                value += try self.block(graph, source, deadline);
            }
        }
    }

    fn bfs(self: Flow, graph: Network, sources: []const u32, deadline: Deadline) !u32 {
        @memset(self.levels, unseen);
        for (sources, 0..) |node, i| {
            try check(deadline, i);
            self.levels[node] = 0;
            self.queue[i] = node;
        }
        var end = sources.len;
        var cursor: usize = 0;
        var sink_level: u32 = unseen;
        while (cursor < end) : (cursor += 1) {
            try check(deadline, cursor);
            const node = self.queue[cursor];
            const level = self.levels[node];
            if (level >= sink_level) break;
            const first, const last = graph.edgeRange(node);
            for (first..last) |e| {
                const head = graph.arcs[e].head;
                if (self.residual[e] == 0 or self.levels[head] != unseen) continue;
                self.levels[head] = level + 1;
                if (self.next[head] == unseen) sink_level = level + 1;
                self.queue[end] = head;
                end += 1;
            }
        }
        return sink_level;
    }

    /// Reuse the BFS queue as a path stack. Each non-sink has a current arc
    /// and we discard its level once it can no longer reach a sink this phase.
    fn block(self: Flow, graph: Network, source: u32, deadline: Deadline) !u32 {
        self.queue[0] = source;
        var depth: usize = 0;
        var steps: usize = 0;
        var value: u32 = 0;
        while (self.levels[source] != unseen) : (steps += 1) {
            try check(deadline, steps);
            const node = self.queue[depth];
            if (self.next[node] == unseen) {
                const path = self.queue[0..depth];
                var capacity: u8 = 2;
                for (path, 0..) |parent, i| {
                    try check(deadline, i);
                    capacity = @min(capacity, self.residual[self.next[parent]]);
                }
                var saturated = depth;
                for (path, 0..) |parent, i| {
                    try check(deadline, i);
                    const arc = self.next[parent];
                    self.residual[arc] -= capacity;
                    self.residual[graph.arcs[arc].reverse] += capacity;
                    if (self.residual[arc] == 0) saturated = @min(saturated, i);
                }
                std.debug.assert(saturated < depth);
                depth = saturated;
                value += capacity;
                continue;
            }
            const next = &self.next[node];
            _, const last = graph.edgeRange(node);
            while (next.* < last) : (next.* += 1) {
                const arc = graph.arcs[next.*];
                if (self.residual[next.*] > 0 and self.levels[arc.head] == self.levels[node] + 1) break;
            }
            if (next.* < last) {
                depth += 1;
                self.queue[depth] = graph.arcs[next.*].head;
            } else {
                self.levels[node] = unseen;
                if (depth == 0) break;
                depth -= 1;
            }
        }
        return value;
    }
};

pub fn check(deadline: Deadline, i: usize) error{DeadlineExceeded}!void {
    if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
}
