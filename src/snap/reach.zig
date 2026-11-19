// Ported from src/loki/reach.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const paged = @import("../search/paged.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Arc = @import("edge.zig").DirectedEdge;
const EdgeId = graph.format.EdgeId;
const NodeId = graph.format.NodeId;

pub const Counts = struct {
    inbound: u32 = 0,
    outbound: u32 = 0,

    pub fn satisfies(self: Counts, required: Counts) bool {
        return self.inbound >= required.inbound and self.outbound >= required.outbound;
    }
};

const Direction = enum { outbound, inbound };

/// Request-local edge reach cache and bounded walk. Traversal labels are
/// directed cursors so two arrivals at a restricted intersection stay distinct.
pub const Finder = struct {
    view: *const graph.reader.View,
    arena: std.mem.Allocator,
    limit: u32,
    deadline: Deadline,
    cache: paged.Array(?Counts, null) = .{},
    seen_arcs: paged.Array(u32, 0) = .{},
    seen_nodes: paged.Array(u32, 0) = .{},
    generation: u32 = 0,
    frontier: std.ArrayList(Arc) = .empty,

    pub fn counts(self: *Finder, id: EdgeId, costing: anytype) !Counts {
        if (self.limit == 0) return .{};
        try self.check();
        if (self.cache.get(@backingInt(id))) |value| return value;
        const seed = try Arc.read(self.view, id);
        var result: Counts = .{};
        if (costing.allowed(seed)) {
            result.outbound = try self.expand(costing, seed, .outbound, false);
            result.inbound = try self.expand(costing, seed, .inbound, false);
            if (isClosed(costing, seed)) {
                if (result.outbound < self.limit) result.outbound = @max(result.outbound, try self.expand(costing, seed, .outbound, true));
                if (result.inbound < self.limit) result.inbound = @max(result.inbound, try self.expand(costing, seed, .inbound, true));
            }
        }
        (try self.cache.at(self.arena, @backingInt(id))).* = result;
        return result;
    }

    fn check(self: *const Finder) error{DeadlineExceeded}!void {
        if (self.deadline.expired()) return error.DeadlineExceeded;
    }

    fn nextGeneration(self: *Finder) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            self.seen_arcs = .{};
            self.seen_nodes = .{};
            self.generation = 1;
        }
        self.frontier.clearRetainingCapacity();
    }

    fn expand(self: *Finder, costing: anytype, seed: Arc, comptime direction: Direction, comptime leave_closure: bool) !u32 {
        self.nextGeneration();
        try self.enqueue(seed);
        var reached: u32 = 0;
        var cursor: usize = 0;
        while (cursor < self.frontier.items.len) : (cursor += 1) {
            try self.check();
            const previous = self.frontier.items[cursor];
            const opposite = try self.view.oppEdge(previous.id);
            const head = if (direction == .outbound) previous.hot.head else (try self.view.edge(opposite)).head;
            if (!nodeAllowed(costing, try self.view.node(@fromBackingInt(head)))) continue;
            var first = head;
            while (try self.view.aliasNeighbor(first, false)) |left| {
                try self.check();
                first = left;
            }
            const visited = try self.seen_nodes.at(self.arena, first);
            if (visited.* != self.generation) {
                visited.* = self.generation;
                reached += 1;
                if (reached == self.limit) return reached;
            }
            var alias = first;
            var uturn: ?Arc = null;
            var has_exit = false;
            while (true) {
                try self.check();
                const range = try self.view.outEdgeRange(@fromBackingInt(alias));
                for (range.first..range.end) |i| {
                    const outgoing: EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
                    const id = if (direction == .outbound) outgoing else try self.view.oppEdge(outgoing);
                    const candidate = try Arc.read(self.view, id);
                    if (candidate.class.flags.node_connector or !costing.allowed(candidate)) continue;
                    if (isClosed(costing, candidate) and (!leave_closure or !isClosed(costing, previous))) continue;
                    const arrival = if (direction == .outbound) previous else candidate;
                    const departure = if (direction == .outbound) candidate else previous;
                    if (!try self.legal(costing, alias, head, arrival, departure)) continue;
                    if (leave_closure and candidate.id == opposite) {
                        uturn = candidate;
                    } else {
                        has_exit = true;
                        try self.enqueue(candidate);
                    }
                }
                alias = (try self.view.aliasNeighbor(alias, true)) orelse break;
            }
            if (!has_exit) if (uturn) |arc| {
                try self.enqueue(arc);
            };
        }
        return reached;
    }

    fn enqueue(self: *Finder, arc: Arc) !void {
        const tag = try self.seen_arcs.at(self.arena, @backingInt(arc.id));
        if (tag.* == self.generation) return;
        tag.* = self.generation;
        try self.frontier.append(self.arena, arc);
    }

    fn legal(self: *const Finder, costing: anytype, alias: u32, head: u32, arrival: Arc, departure: Arc) !bool {
        if (alias == head) {
            const opposite = try self.view.edge(try self.view.oppEdge(arrival.id));
            const row = try self.view.turnRow(@fromBackingInt(head), opposite.cls.local);
            if (departure.hot.cls.local >= row.len) return error.InvalidLocalEdge;
            if (row[departure.hot.cls.local] & 0x80 != 0) return false;
        }
        if (@hasDecl(@TypeOf(costing), "allowedTransition")) return costing.allowedTransition(arrival, departure);
        return true;
    }
};

fn nodeAllowed(costing: anytype, node: *const graph.format.NodeHot) bool {
    if (@hasDecl(@TypeOf(costing), "allowedNode")) return costing.allowedNode(node);
    return true;
}

fn isClosed(costing: anytype, arc: Arc) bool {
    if (@hasDecl(@TypeOf(costing), "closed")) return costing.closed(arc);
    return false;
}
