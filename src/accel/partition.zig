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
    /// Leaf paths only join nodes whose input IDs are at most this far
    /// apart, which keeps the input order's locality between paths.
    max_link_gap: u32 = 256,
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

/// An undirected graph as CSR: arcs of node `i` are `arcs[offsets[i]..offsets[i + 1]]`, and
/// every arc's `reverse` is the index of its opposing arc. Node `i` sits at `coordinates[i]`.
/// Input IDs should be spatially local (Hilbert order, say): ties and the leaf link gap use them.
pub const Input = struct {
    offsets: []const u32,
    arcs: []const flow.Arc,
    coordinates: []const format.Coordinate,

    /// Read a bundle's topology, checking each opposing edge against its local slot.
    pub fn fromView(a: Allocator, view: *const View, deadline: io.Deadline) !Input {
        if (view.nodes.len >= flow.unseen or view.edges.len >= flow.unseen) return error.GraphTooLarge;
        if (view.nodes.len == 0) return .{ .offsets = &.{0}, .arcs = &.{}, .coordinates = &.{} };
        const all_coordinates = view.coordinates orelse return error.MissingCoordinatesSection;
        if (all_coordinates.len < view.nodes.len) return error.InvalidNodeId;
        const coordinates = all_coordinates[0..view.nodes.len];
        if (view.first_edge.len != view.nodes.len + 1 or view.first_edge[0] != 0 or
            view.first_edge[view.nodes.len] != view.edges.len) return error.InvalidCsrRange;
        const arcs = try a.alloc(flow.Arc, view.edges.len);
        errdefer a.free(arcs);
        for (0..view.nodes.len) |i| {
            try check(deadline, i);
            const id: NodeId = @fromBackingInt(@as(u32, @intCast(i)));
            _ = try view.coordinate(id);
            const row = try view.outEdgeRange(id);
            for (row.first..row.end) |edge| {
                const reverse = @backingInt(try view.oppEdge(@fromBackingInt(@as(u32, @intCast(edge)))));
                const opposing = view.edges[reverse];
                if (opposing.head != i or edge - row.first != opposing.cls.opp_local or edge == reverse) {
                    return error.InvalidOpposingEdge;
                }
                arcs[edge] = .{ .head = view.edges[edge].head, .reverse = reverse };
            }
        }
        return .{ .offsets = view.first_edge, .arcs = arcs, .coordinates = coordinates };
    }

    /// Free what `fromView` allocated.
    pub fn deinitView(self: Input, a: Allocator) void {
        if (self.arcs.len != 0) a.free(self.arcs);
    }

    fn nodeCount(self: Input) usize {
        return self.coordinates.len;
    }

    fn validate(self: Input, deadline: io.Deadline) !void {
        const n = self.coordinates.len;
        if (n >= flow.unseen or self.arcs.len >= flow.unseen) return error.GraphTooLarge;
        if (self.offsets.len != n + 1 or self.offsets[0] != 0 or self.offsets[n] != self.arcs.len) return error.InvalidCsrRange;
        for (0..n) |i| {
            try check(deadline, i);
            if (!self.coordinates[i].inRange()) return error.InvalidCoordinate;
            const first = self.offsets[i];
            const end = self.offsets[i + 1];
            if (first > end or end > self.arcs.len) return error.InvalidCsrRange;
            for (first..end) |edge| {
                const arc = self.arcs[edge];
                if (arc.head >= n or arc.reverse >= self.arcs.len or arc.reverse == edge) return error.InvalidOpposingEdge;
                const opposing = self.arcs[arc.reverse];
                // The opposing arc must leave the head and point back at this node.
                if (opposing.reverse != edge or opposing.head != i or
                    arc.reverse < self.offsets[arc.head] or arc.reverse >= self.offsets[arc.head + 1]) return error.InvalidOpposingEdge;
            }
        }
    }
};

/// Dissect, then order each leaf and separator so neighbors take adjacent
/// ranks where they can.
pub fn build(a: Allocator, view: *const View, options: Options) !Order {
    const input = try Input.fromView(std.heap.smp_allocator, view, options.deadline);
    defer input.deinitView(std.heap.smp_allocator);
    return buildInput(a, input, options);
}

/// `build` over a CSR graph.
pub fn buildInput(a: Allocator, input: Input, options: Options) !Order {
    const order = try dissect(a, input, options);
    errdefer order.deinit(a);
    try orderRanges(input, order, options);
    return order;
}

/// The nested dissection alone: each range keeps the input ID order.
pub fn dissect(a: Allocator, input: Input, options: Options) !Order {
    if (options.threads == 0 or options.leaf_edges == 0 or
        options.max_side_percent < 50 or options.max_side_percent >= 100) return error.InvalidPartitionOptions;
    try check(options.deadline, 0);
    try input.validate(options.deadline);
    const n = input.nodeCount();
    if (n == 0) return .{ .nodes = &.{}, .cells = &.{} };

    const nodes = try a.alloc(NodeId, n);
    errdefer a.free(nodes);
    // Scratch is shared by concurrent subtrees, independently of the result
    // allocator supplied by the caller.
    const work: Work = .{ .a = std.heap.smp_allocator, .coordinates = input.coordinates, .options = options };
    const tree = try work.subtree(try readGraph(work.a, input, options.deadline), nodes, 0, options.threads);
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

/// Copy the input into the dissection's own graph, which the recursion frees as it splits.
fn readGraph(a: Allocator, input: Input, deadline: io.Deadline) !Graph {
    var graph = try Graph.init(a, input.nodeCount(), input.arcs.len);
    errdefer graph.deinit(a);
    for (graph.ids, 0..) |*id, i| {
        try check(deadline, i);
        id.* = @fromBackingInt(@as(u32, @intCast(i)));
    }
    @memcpy(graph.offsets, input.offsets);
    @memcpy(graph.arcs, input.arcs);
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

const no_link = std.math.maxInt(u32);

const Link = struct {
    gap: u32,
    u: u32,
    v: u32,

    fn less(_: void, x: Link, y: Link) bool {
        if (x.gap != y.gap) return x.gap < y.gap;
        if (x.u != y.u) return x.u < y.u;
        return x.v < y.v;
    }
};

/// Reorder every leaf and every separator in place. Within a range, edges
/// are taken in order of input ID gap and kept when they extend two
/// different paths, so the result is a set of disjoint paths. Each path is
/// then written contiguously, starting from the range's lowest unwritten
/// endpoint. Ranges, leaf membership and separator positions are unchanged,
/// and the result depends only on the dissection, not on the thread count.
pub fn orderRanges(input: Input, order: Order, options: Options) !void {
    const deadline = options.deadline;
    const a = std.heap.smp_allocator;
    if (order.nodes.len != input.nodeCount()) return error.InvalidOrder;
    const ranks = try a.alloc(u32, order.nodes.len);
    defer a.free(ranks);
    for (order.nodes, 0..) |node, rank| {
        try check(deadline, rank);
        ranks[@backingInt(node)] = @intCast(rank);
    }
    var longest: usize = 0;
    for (order.cells) |cell| longest = @max(longest, if (cell.isLeaf()) cell.end - cell.begin else cell.end - cell.separator_begin);
    const nodes = try a.alloc(NodeId, longest);
    defer a.free(nodes);
    const sets = try a.alloc(u32, longest);
    defer a.free(sets);
    const links = try a.alloc([2]u32, longest);
    defer a.free(links);
    var edges: std.ArrayList(Link) = .empty;
    defer edges.deinit(a);

    for (order.cells, 0..) |cell, index| {
        try check(deadline, index);
        const begin = if (cell.isLeaf()) cell.begin else cell.separator_begin;
        const count = cell.end - begin;
        if (count < 2) continue;
        const range = order.nodes[begin..cell.end];
        @memcpy(nodes[0..count], range);

        edges.clearRetainingCapacity();
        for (nodes[0..count], 0..) |node, u| {
            try check(deadline, u);
            const tail = @backingInt(node);
            for (input.arcs[input.offsets[tail]..input.offsets[tail + 1]]) |edge| {
                const rank = ranks[edge.head];
                if (rank <= begin + u or rank >= cell.end) continue;
                const gap = if (edge.head > tail) edge.head - tail else tail - edge.head;
                if (gap > options.max_link_gap) continue;
                try edges.append(a, .{ .gap = gap, .u = @intCast(u), .v = rank - begin });
            }
        }
        std.mem.sortUnstable(Link, edges.items, {}, Link.less);

        for (sets[0..count], links[0..count], 0..) |*set, *link, i| {
            set.* = @intCast(i);
            link.* = .{ no_link, no_link };
        }
        for (edges.items, 0..) |edge, i| {
            try check(deadline, i);
            const u_free = std.mem.indexOfScalar(u32, &links[edge.u], no_link) orelse continue;
            const v_free = std.mem.indexOfScalar(u32, &links[edge.v], no_link) orelse continue;
            const root_u = findSet(sets, edge.u);
            const root_v = findSet(sets, edge.v);
            if (root_u == root_v) continue;
            sets[@max(root_u, root_v)] = @min(root_u, root_v);
            links[edge.u][u_free] = edge.v;
            links[edge.v][v_free] = edge.u;
        }

        // Reuse the set slots as written marks.
        @memset(sets[0..count], 0);
        var written: usize = 0;
        for (0..count) |start| {
            try check(deadline, start);
            if (sets[start] != 0 or (links[start][0] != no_link and links[start][1] != no_link)) continue;
            var previous: u32 = no_link;
            var current: u32 = @intCast(start);
            while (current != no_link) {
                try check(deadline, written);
                range[written] = nodes[current];
                written += 1;
                sets[current] = 1;
                const pair = links[current];
                const next = if (pair[0] != previous) pair[0] else pair[1];
                previous = current;
                current = next;
            }
        }
        if (written != count) return error.InvalidLeafPaths;
    }
}

fn findSet(sets: []u32, start: u32) u32 {
    var node = start;
    while (sets[node] != node) {
        sets[node] = sets[sets[node]];
        node = sets[node];
    }
    return node;
}
