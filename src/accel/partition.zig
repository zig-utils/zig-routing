//! Inertial-flow nested dissection of the bundle's undirected topology.
const std = @import("std");
const format = @import("../graph/format.zig");
const View = @import("../graph/reader.zig").View;
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const flow = @import("inertial_flow.zig");
const check = flow.check;
const Allocator = std.mem.Allocator;
const NodeId = format.NodeId;

pub const Options = struct {
    /// Count directed CSR entries so the limit also describes storage size.
    leaf_edges: u32 = 65_536,
    /// Maximum child size as a percentage of the parent's node count,
    /// rounded up to a whole node.
    max_side_percent: u8 = 80,
    threads: usize = 1,
    deadline: io.Deadline = .none,
};

pub const no_child = std.math.maxInt(u32);

pub const Cell = struct {
    begin: u32,
    end: u32,
    separator_begin: u32,
    left: u32 = no_child,
    right: u32 = no_child,
    directed_edges: u32,

    comptime {
        std.debug.assert(@sizeOf(Cell) == 6 * @sizeOf(u32));
    }

    pub fn isLeaf(self: Cell) bool {
        return self.left == no_child and self.right == no_child;
    }
};

pub const Order = struct {
    /// Old node ID at each new rank. A cell's separator occupies its suffix.
    nodes: []NodeId,
    /// Preorder, rooted at index zero. Child ranges precede the separator.
    cells: []Cell,

    pub fn deinit(self: Order, a: Allocator) void {
        a.free(self.cells);
        a.free(self.nodes);
    }
};

pub fn build(a: Allocator, view: *const View, options: Options) !Order {
    if (options.threads == 0 or options.leaf_edges == 0 or
        options.max_side_percent < 50 or options.max_side_percent >= 100) return error.InvalidPartitionOptions;
    try check(options.deadline, 0);
    if (view.nodes.len >= flow.unseen or view.edges.len >= flow.unseen) return error.GraphTooLarge;
    if (view.nodes.len == 0) return .{ .nodes = &.{}, .cells = &.{} };
    const coordinates = view.coordinates orelse return error.MissingCoordinatesSection;
    for (0..view.nodes.len) |i| {
        try check(options.deadline, i);
        _ = try view.coordinate(@fromBackingInt(@as(u32, @intCast(i))));
    }

    const nodes = try a.alloc(NodeId, view.nodes.len);
    errdefer a.free(nodes);
    // Scratch is shared by concurrent subtrees, independently of the result
    // allocator supplied by the caller.
    const work: Work = .{ .a = std.heap.smp_allocator, .coordinates = coordinates, .options = options };
    const tree = try work.subtree(try readGraph(work.a, view, options.deadline), nodes, 0, options.threads);
    defer tree.deinit(work.a);
    const cells = try a.alloc(Cell, tree.count);
    errdefer a.free(cells);
    try tree.emit(cells, 0, options.deadline);
    return .{ .nodes = nodes, .cells = cells };
}

const Graph = struct {
    ids: []NodeId = &.{},
    offsets: []u32 = &.{},
    arcs: []flow.Arc = &.{},

    fn init(a: Allocator, node_count: usize, arc_count: usize) !Graph {
        const ids = try a.alloc(NodeId, node_count);
        errdefer a.free(ids);
        const offsets = try a.alloc(u32, node_count + 1);
        errdefer a.free(offsets);
        return .{ .ids = ids, .offsets = offsets, .arcs = try a.alloc(flow.Arc, arc_count) };
    }

    fn deinit(self: Graph, a: Allocator) void {
        a.free(self.arcs);
        a.free(self.offsets);
        a.free(self.ids);
    }

    fn network(self: Graph) flow.Network {
        return .{ .offsets = self.offsets, .arcs = self.arcs };
    }
};

fn readGraph(a: Allocator, view: *const View, deadline: io.Deadline) !Graph {
    var graph = try Graph.init(a, view.nodes.len, view.edges.len);
    errdefer graph.deinit(a);
    if (view.first_edge.len != graph.offsets.len or view.first_edge[0] != 0 or
        view.first_edge[graph.ids.len] != graph.arcs.len) return error.InvalidCsrRange;

    for (graph.ids, 0..) |*id, i| {
        try check(deadline, i);
        id.* = @fromBackingInt(@as(u32, @intCast(i)));
        const row = try view.outEdgeRange(id.*);
        graph.offsets[i] = row.first;
        for (row.first..row.end) |edge| {
            const reverse = @backingInt(try view.oppEdge(@fromBackingInt(@as(u32, @intCast(edge)))));
            const opposing = view.edges[reverse];
            if (opposing.head != i or edge - row.first != opposing.cls.opp_local or edge == reverse) {
                return error.InvalidOpposingEdge;
            }
            graph.arcs[edge] = .{ .head = view.edges[edge].head, .reverse = reverse };
        }
    }
    graph.offsets[graph.ids.len] = @intCast(graph.arcs.len);
    return graph;
}

const Side = enum(u8) { left, right, separator };
const Counts = std.EnumArray(Side, usize);

fn chooseSides(a: Allocator, graph: Graph, coords: []const format.Coordinate, options: Options, best_sides: []Side) !Counts {
    const network = graph.network();
    const n = graph.ids.len;
    const deadline = options.deadline;
    const rounded_up: usize = @intCast((@as(u64, n) * options.max_side_percent + 99) / 100);
    const limit = @min(n - 1, rounded_up);
    const pinned = n - limit;
    const work = try flow.Flow.init(a, network);
    defer work.deinit(a);
    if (try disconnectedCut(network, work, best_sides, pinned, limit, deadline)) |counts| return counts;

    const order = try a.alloc(u32, n);
    defer a.free(order);
    const scratch = try a.alloc(u32, n);
    defer a.free(scratch);
    const keys = try a.alloc(u64, n);
    defer a.free(keys);
    // Unwrap longitude relative to the first node and approximate its local
    // scale in integer units before projecting on the diagonals.
    const origin = coords[@backingInt(graph.ids[0])];
    const scale: i64 = @intFromFloat(@round(@cos(origin.toPoint().lat * (std.math.pi / 180.0)) * 1024.0));

    var best: ?Cut = null;
    for ([_][2]i64{ .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, -1 } }) |axis| {
        for (graph.ids, order, keys, 0..) |id, *index, *key, i| {
            try check(deadline, i);
            index.* = @intCast(i);
            const point = coords[@backingInt(id)];
            const lon = @mod(@as(i64, point.lng) - origin.lng + 1_800_000_000, 3_600_000_000) - 1_800_000_000;
            const value = axis[0] * scale * lon + axis[1] * 1024 * point.lat;
            key.* = @as(u64, @bitCast(value)) ^ (1 << 63);
        }
        try radix.sortByU64(u32, a, order, scratch, @as([]const u64, keys), projectionKey, deadline);
        const edges = try work.run(network, order, pinned, deadline);
        if (best) |previous| if (edges > previous.edges) continue;

        const candidate = try vertexCut(network, work, edges, deadline);
        if (best == null or candidate.betterThan(best.?)) {
            best = candidate;
            for (best_sides, work.levels, work.next, 0..) |*side, level, boundary, i| {
                try check(deadline, i);
                side.* = if (boundary != 0 and (level != flow.unseen) == candidate.remove_left)
                    .separator
                else if (level != flow.unseen)
                    .left
                else
                    .right;
            }
        }
    }
    return best.?.counts;
}

fn projectionKey(keys: []const u64, index: u32) u64 {
    return keys[index];
}

/// Pack whole connected components first when their sizes permit a balanced
/// zero cut. Original ID order breaks ties, including among isolated nodes.
fn disconnectedCut(network: flow.Network, work: flow.Flow, sides: []Side, pinned: usize, limit: usize, deadline: io.Deadline) !?Counts {
    @memset(work.levels, flow.unseen);
    @memset(sides, .right);
    var left: usize = 0;
    for (work.levels, 0..) |*visited, start| {
        try check(deadline, start);
        if (visited.* != flow.unseen) continue;
        work.queue[0] = @intCast(start);
        visited.* = 0;
        var tail: usize = 1;
        var cursor: usize = 0;
        while (cursor < tail) : (cursor += 1) {
            try check(deadline, cursor);
            const first, const last = network.edgeRange(work.queue[cursor]);
            for (network.arcs[first..last]) |arc| {
                if (work.levels[arc.head] != flow.unseen) continue;
                work.levels[arc.head] = 0;
                work.queue[tail] = arc.head;
                tail += 1;
            }
        }
        if (tail > limit - left) continue;
        for (work.queue[0..tail], 0..) |node, i| {
            try check(deadline, i);
            sides[node] = .left;
        }
        left += tail;
        if (left >= pinned) return Counts.init(.{ .left = left, .right = sides.len - left, .separator = 0 });
    }
    return null;
}

const Cut = struct {
    edges: u32,
    counts: Counts,
    remove_left: bool,

    fn betterThan(self: Cut, other: Cut) bool {
        if (self.edges != other.edges) return self.edges < other.edges;
        if (self.counts.get(.separator) != other.counts.get(.separator)) {
            return self.counts.get(.separator) < other.counts.get(.separator);
        }
        return @max(self.counts.get(.left), self.counts.get(.right)) < @max(other.counts.get(.left), other.counts.get(.right));
    }
};

/// Either bank of the edge cut covers every crossing. Take the smaller
/// bank, and break equal-size ties by minimizing the larger child.
fn vertexCut(network: flow.Network, work: flow.Flow, edges: u32, deadline: io.Deadline) !Cut {
    @memset(work.next, 0);
    var left: usize = 0;
    for (work.levels, 0..) |level, node| {
        try check(deadline, node);
        if (level == flow.unseen) continue;
        left += 1;
        const first, const last = network.edgeRange(@intCast(node));
        for (network.arcs[first..last]) |arc| {
            if (work.levels[arc.head] != flow.unseen) continue;
            work.next[node] = 1;
            work.next[arc.head] = 1;
        }
    }
    var left_bank: usize = 0;
    var right_bank: usize = 0;
    for (work.levels, work.next, 0..) |level, boundary, i| {
        try check(deadline, i);
        if (level != flow.unseen) {
            left_bank += boundary;
        } else {
            right_bank += boundary;
        }
    }
    const right = work.levels.len - left;
    const remove_left = left_bank < right_bank or (left_bank == right_bank and left >= right);
    return .{
        .edges = edges,
        .remove_left = remove_left,
        .counts = Counts.init(.{
            .left = left - (if (remove_left) left_bank else 0),
            .right = right - (if (remove_left) 0 else right_bank),
            .separator = if (remove_left) left_bank else right_bank,
        }),
    };
}

fn split(a: Allocator, graph: Graph, sides: []const Side, counts: Counts, separator: []NodeId, deadline: io.Deadline) ![2]Graph {
    const edge_map = try a.alloc(u32, graph.arcs.len);
    defer a.free(edge_map);
    const local = try a.alloc(u32, graph.ids.len);
    defer a.free(local);
    var next_node: [3]u32 = @splat(0);
    var next_edge: [2]u32 = @splat(0);
    const network = graph.network();
    for (sides, graph.ids, local, 0..) |side, id, *mapped, node| {
        try check(deadline, node);
        const child = @backingInt(side);
        mapped.* = next_node[child];
        next_node[child] += 1;
        if (side == .separator) {
            separator[mapped.*] = id;
            continue;
        }
        const first, const end = network.edgeRange(@intCast(node));
        for (first..end) |edge| {
            if (sides[graph.arcs[edge].head] != side) continue;
            edge_map[edge] = next_edge[child];
            next_edge[child] += 1;
        }
    }

    var children: [2]Graph = @splat(.{});
    errdefer for (children) |child| child.deinit(a);
    inline for (.{ Side.left, Side.right }, 0..) |side, i| {
        children[i] = try Graph.init(a, counts.get(side), next_edge[i]);
        children[i].offsets[counts.get(side)] = next_edge[i];
    }
    next_edge = @splat(0);
    for (sides, graph.ids, local, 0..) |side, id, index, node| {
        try check(deadline, node);
        if (side == .separator) continue;
        const child = @backingInt(side);
        children[child].ids[index] = id;
        children[child].offsets[index] = next_edge[child];
        const first, const end = network.edgeRange(@intCast(node));
        for (first..end) |edge| {
            const arc = graph.arcs[edge];
            if (sides[arc.head] != side) continue;
            children[child].arcs[next_edge[child]] = .{ .head = local[arc.head], .reverse = edge_map[arc.reverse] };
            next_edge[child] += 1;
        }
    }
    return children;
}

const Tree = struct {
    cell: Cell,
    children: [2]?*Tree = @splat(null),
    count: usize = 1,

    fn deinit(self: *Tree, a: Allocator) void {
        for (self.children) |child| if (child) |subtree| subtree.deinit(a);
        a.destroy(self);
    }

    fn emit(self: *const Tree, cells: []Cell, index: usize, deadline: io.Deadline) !void {
        try check(deadline, index);
        const left, const right = self.children;
        cells[index] = self.cell;
        var next = index + 1;
        if (left) |child| {
            if (next >= no_child) return error.GraphTooLarge;
            cells[index].left = @intCast(next);
            try child.emit(cells, next, deadline);
            next += child.count;
        }
        if (right) |child| {
            if (next >= no_child) return error.GraphTooLarge;
            cells[index].right = @intCast(next);
            try child.emit(cells, next, deadline);
        }
    }
};

const Work = struct {
    a: Allocator,
    coordinates: []const format.Coordinate,
    options: Options,

    fn leaf(self: Work, graph: Graph) bool {
        return graph.arcs.len <= self.options.leaf_edges or graph.ids.len < 2;
    }

    fn subtree(self: Work, input: Graph, order: []NodeId, begin: u32, threads: usize) anyerror!*Tree {
        var graph = input;
        defer graph.deinit(self.a);
        const deadline = self.options.deadline;
        try check(deadline, 0);
        const tree = try self.a.create(Tree);
        errdefer self.a.destroy(tree);
        const end = begin + @as(u32, @intCast(order.len));
        tree.* = .{ .cell = .{ .begin = begin, .end = end, .separator_begin = end, .directed_edges = @intCast(graph.arcs.len) } };
        if (self.leaf(graph)) {
            for (order, graph.ids, 0..) |*node, id, i| {
                try check(deadline, i);
                node.* = id;
            }
            return tree;
        }

        const children = children: {
            const sides = try self.a.alloc(Side, graph.ids.len);
            defer self.a.free(sides);
            const counts = try chooseSides(self.a, graph, self.coordinates, self.options, sides);
            const left = counts.get(.left);
            const child_end = left + counts.get(.right);
            tree.cell.separator_begin = begin + @as(u32, @intCast(child_end));
            break :children .{
                try split(self.a, graph, sides, counts, order[child_end..], deadline),
                left,
                child_end,
            };
        };
        graph.deinit(self.a);
        graph = .{};
        const graphs, const middle, const child_end = children;
        const concurrent = threads > 1 and !self.leaf(graphs[0]) and !self.leaf(graphs[1]);
        var left: Task = .{
            .work = self,
            .graph = graphs[0],
            .order = order[0..middle],
            .begin = begin,
            .threads = if (concurrent) threads / 2 else threads,
        };
        var right: Task = .{
            .work = self,
            .graph = graphs[1],
            .order = order[middle..child_end],
            .begin = begin + @as(u32, @intCast(middle)),
            .threads = if (concurrent) threads - left.threads else threads,
        };
        if (concurrent) {
            const thread = std.Thread.spawn(.{}, Task.run, .{&left}) catch |err| {
                left.graph.deinit(self.a);
                right.graph.deinit(self.a);
                return err;
            };
            right.run();
            thread.join();
        } else {
            left.run();
            right.run();
        }
        errdefer for ([_]anyerror!?*Tree{ left.result, right.result }) |result| {
            if (result) |child| {
                if (child) |sub| sub.deinit(self.a);
            } else |_| {}
        };
        tree.children = .{ try left.result, try right.result };
        for (tree.children) |child| if (child) |sub| {
            tree.count += sub.count;
        };
        return tree;
    }
};

const Task = struct {
    work: Work,
    graph: Graph,
    order: []NodeId,
    begin: u32,
    threads: usize,
    result: anyerror!?*Tree = undefined,

    fn run(self: *Task) void {
        if (self.order.len == 0) {
            self.graph.deinit(self.work.a);
            self.result = null;
        } else {
            self.result = self.work.subtree(self.graph, self.order, self.begin, self.threads);
        }
    }
};
