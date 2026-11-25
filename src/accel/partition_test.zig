const std = @import("std");
const partition = @import("partition.zig");
const flow = @import("inertial_flow.zig");
const reader = @import("../graph/reader.zig");
const format = @import("../graph/format.zig");
const a = std.testing.allocator;

const Link = [2]u32;

const Fixture = struct {
    view: reader.View,

    fn init(points: []const format.Coordinate, links: []const Link) !Fixture {
        const nodes = try a.alloc(format.NodeHot, points.len);
        errdefer a.free(nodes);
        @memset(nodes, std.mem.zeroes(format.NodeHot));
        const edges = try a.alloc(format.EdgeHot, links.len * 2);
        errdefer a.free(edges);
        const offsets = try a.alloc(u32, points.len + 1);
        errdefer a.free(offsets);
        const degrees = try a.alloc(u32, points.len);
        defer a.free(degrees);
        @memset(degrees, 0);
        for (links) |link| {
            degrees[link[0]] += 1;
            degrees[link[1]] += 1;
        }
        offsets[0] = 0;
        for (degrees, 0..) |degree, i| offsets[i + 1] = offsets[i] + degree;
        @memset(degrees, 0);
        for (links) |link| {
            const u, const v = link;
            const uv = degrees[u];
            degrees[u] += 1;
            const vu = degrees[v];
            degrees[v] += 1;
            for ([_]u32{ u, v }, [_]u32{ v, u }, [_]u32{ uv, vu }, [_]u32{ vu, uv }) |from, to, local, reverse| {
                var edge = std.mem.zeroes(format.EdgeHot);
                edge.head = to;
                edge.cls.local = @intCast(local);
                edge.cls.opp_local = @intCast(reverse);
                edges[offsets[from] + local] = edge;
            }
        }
        return .{ .view = .{
            .headers = .initFill(null),
            .dataset_uuid = @splat(0),
            .nodes = nodes,
            .edges = edges,
            .first_edge = offsets,
            .turns = &.{},
            .classes = null,
            .coordinates = points,
            .cold_idx = null,
            .cold = null,
            .cold_data = null,
            .slopes = null,
            .spatial = null,
            .spatial_index = null,
            .metadata = null,
            .components = null,
            .turn_sides = null,
            .turn_side_index = null,
        } };
    }

    fn deinit(self: Fixture) void {
        a.free(self.view.first_edge);
        a.free(self.view.edges);
        a.free(self.view.nodes);
    }
};

fn validate(order: partition.Order, view: *const reader.View, options: partition.Options) !void {
    try std.testing.expectEqual(view.nodes.len, order.nodes.len);
    const ranks = try a.alloc(u32, order.nodes.len);
    defer a.free(ranks);
    @memset(ranks, partition.no_child);
    for (order.nodes, 0..) |node, rank| {
        const id = @backingInt(node);
        try std.testing.expect(id < ranks.len);
        try std.testing.expectEqual(partition.no_child, ranks[id]);
        ranks[id] = @intCast(rank);
    }
    try std.testing.expectEqual(@as(u32, 0), order.cells[0].begin);
    try std.testing.expectEqual(view.nodes.len, order.cells[0].end);
    try std.testing.expectEqual(order.cells.len, try validateCell(order, view, ranks, 0, options));
}

fn validateCell(order: partition.Order, view: *const reader.View, ranks: []const u32, index: u32, options: partition.Options) !u32 {
    const cell = order.cells[index];
    try std.testing.expect(cell.begin < cell.end);
    try std.testing.expect(cell.begin <= cell.separator_begin and cell.separator_begin <= cell.end);

    var next = index + 1;
    var boundary = cell.begin;
    for ([_]u32{ cell.left, cell.right }) |child_index| {
        if (child_index == partition.no_child) continue;
        try std.testing.expectEqual(next, child_index);
        const child = order.cells[child_index];
        try std.testing.expectEqual(boundary, child.begin);
        try std.testing.expect(child.end <= cell.separator_begin);
        const limit = ((cell.end - cell.begin) * options.max_side_percent + 99) / 100;
        try std.testing.expect(child.end - child.begin <= limit);
        next = try validateCell(order, view, ranks, child_index, options);
        boundary = child.end;
    }
    if (cell.isLeaf()) {
        try std.testing.expectEqual(cell.end, cell.separator_begin);
        try std.testing.expect(cell.directed_edges <= options.leaf_edges or cell.end - cell.begin == 1);
    } else {
        try std.testing.expectEqual(boundary, cell.separator_begin);
    }
    const middle = if (cell.left == partition.no_child) cell.begin else order.cells[cell.left].end;
    var arc_count: usize = 0;
    for (order.nodes[cell.begin..cell.end], cell.begin..) |node, rank| {
        for (try view.outEdges(node)) |arc| {
            const head = ranks[arc.head];
            if (head >= cell.begin and head < cell.end) arc_count += 1;
            if (cell.isLeaf() or rank >= cell.separator_begin or head < cell.begin or head >= cell.separator_begin) continue;
            try std.testing.expectEqual(rank < middle, head < middle);
        }
    }
    try std.testing.expectEqual(arc_count, cell.directed_edges);
    return next;
}

test "grid dissection removes crossings, respects balance and is identical with one or eight threads" {
    const width = 21;
    const height = 19;
    var points: [width * height]format.Coordinate = undefined;
    var links: [width * (height - 1) + (width - 1) * height]Link = undefined;
    var i: usize = 0;
    for (&points, 0..) |*point, id| {
        const x = id % width;
        const y = id / width;
        point.* = .{ .lng = @intCast(10_000 * x), .lat = @intCast(10_000 * y) };
        if (x > 0) {
            links[i] = .{ @intCast(id - 1), @intCast(id) };
            i += 1;
        }
        if (y > 0) {
            links[i] = .{ @intCast(id - width), @intCast(id) };
            i += 1;
        }
    }
    const fixture = try Fixture.init(&points, &links);
    defer fixture.deinit();
    var options: partition.Options = .{ .leaf_edges = 96, .max_side_percent = 60 };
    const single = try partition.build(a, &fixture.view, options);
    defer single.deinit(a);
    options.threads = 8;
    const parallel = try partition.build(a, &fixture.view, options);
    defer parallel.deinit(a);
    try validate(single, &fixture.view, options);
    const root = single.cells[0];
    try std.testing.expect(root.end - root.separator_begin <= height);
    try std.testing.expect(single.cells[root.left].directed_edges > options.leaf_edges);
    try std.testing.expect(single.cells[root.right].directed_edges > options.leaf_edges);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(single.nodes), std.mem.sliceAsBytes(parallel.nodes));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(single.cells), std.mem.sliceAsBytes(parallel.cells));
}

test "islands, isolated nodes, coincident intersections, parallel roads and loops" {
    var points: [37]format.Coordinate = @splat(.{ .lng = 0, .lat = 0 });
    // A main road, two islands, and five points unattached to any road.
    var links: [31]Link = undefined;
    var i: usize = 0;
    for (0..31) |id| {
        if (id == 15 or id == 23) continue;
        links[i] = .{ @intCast(id), @intCast(id + 1) };
        i += 1;
    }
    links[i] = .{ 5, 5 };
    links[i + 1] = .{ 9, 10 };
    const fixture = try Fixture.init(&points, &links);
    defer fixture.deinit();
    const options: partition.Options = .{ .leaf_edges = 6, .max_side_percent = 60, .threads = 8 };
    const result = try partition.build(a, &fixture.view, options);
    defer result.deinit(a);
    try validate(result, &fixture.view, options);
    try std.testing.expectEqual(result.cells[0].end, result.cells[0].separator_begin);
    try std.testing.expect(result.cells[result.cells[0].left].separator_begin < result.cells[result.cells[0].left].end);
    try std.testing.expectError(error.DeadlineExceeded, partition.build(a, &fixture.view, .{ .deadline = .{ .at_ns = 0 } }));
}

test "Dinic matches enumerated terminal cuts on small undirected multigraphs" {
    const count = 8;
    var prng = std.Random.DefaultPrng.init(90);
    const random = prng.random();
    const points: [count]format.Coordinate = @splat(.{ .lng = 0, .lat = 0 });
    const order: [count]u32 = .{ 7, 2, 3, 4, 1, 6, 0, 5 };
    for (0..256) |trial| {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(a);
        for (0..count) |u| {
            for (u + 1..count) |v| {
                const copies = random.uintLessThanBiased(u8, 5);
                for (0..copies / 2) |_| try links.append(a, .{ @intCast(u), @intCast(v) });
            }
        }
        const fixture = try Fixture.init(&points, links.items);
        defer fixture.deinit();
        const arcs = try a.alloc(flow.Arc, links.items.len * 2);
        defer a.free(arcs);
        for (fixture.view.edges, arcs, 0..) |edge, *arc, id| {
            arc.* = .{ .head = edge.head, .reverse = @backingInt(try fixture.view.oppEdge(@fromBackingInt(@as(u32, @intCast(id))))) };
        }
        const network: flow.Network = .{ .offsets = fixture.view.first_edge, .arcs = arcs };
        const work = try flow.Flow.init(a, network);
        defer work.deinit(a);
        const pinned = trial % 4 + 1;
        const value = try work.run(network, &order, pinned, .none);
        var sources: u8 = 0;
        var sinks: u8 = 0;
        var reachable: u8 = 0;
        for (order[0..pinned]) |node| sources |= @as(u8, 1) << @as(u3, @intCast(node));
        for (order[count - pinned ..]) |node| sinks |= @as(u8, 1) << @as(u3, @intCast(node));
        for (work.levels, 0..) |level, node| {
            if (level != flow.unseen) reachable |= @as(u8, 1) << @as(u3, @intCast(node));
        }
        var best: u32 = std.math.maxInt(u32);
        for (0..256) |candidate| {
            const mask: u8 = @intCast(candidate);
            if (mask & sources != sources or mask & sinks != 0) continue;
            best = @min(best, cutSize(links.items, mask));
        }
        try std.testing.expectEqual(best, value);
        try std.testing.expectEqual(sources, reachable & sources);
        try std.testing.expectEqual(@as(u8, 0), reachable & sinks);
        try std.testing.expectEqual(value, cutSize(links.items, reachable));
    }
}

fn cutSize(links: []const Link, mask: u8) u32 {
    var edges: u32 = 0;
    for (links) |link| {
        if (((mask >> @as(u3, @intCast(link[0]))) ^ (mask >> @as(u3, @intCast(link[1])))) & 1 == 1) edges += 1;
    }
    return edges;
}

/// Each leaf and each separator holds the same nodes after leaf ordering as
/// after the dissection alone, and the cell tree is unchanged.
fn expectSameRanges(dissected: partition.Order, ordered: partition.Order) !void {
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(dissected.cells), std.mem.sliceAsBytes(ordered.cells));
    for (dissected.cells) |cell| {
        const begin = if (cell.isLeaf()) cell.begin else cell.separator_begin;
        const before = try a.dupe(format.NodeId, dissected.nodes[begin..cell.end]);
        defer a.free(before);
        const after = try a.dupe(format.NodeId, ordered.nodes[begin..cell.end]);
        defer a.free(after);
        std.mem.sortUnstable(u32, std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(before)), {}, std.sort.asc(u32));
        std.mem.sortUnstable(u32, std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(after)), {}, std.sort.asc(u32));
        try std.testing.expectEqualSlices(format.NodeId, before, after);
    }
}

test "leaf ordering keeps every range's nodes and is identical with one or eight threads" {
    var prng = std.Random.DefaultPrng.init(266);
    const random = prng.random();
    for (0..24) |trial| {
        const count = 40 + trial * 7;
        const points = try a.alloc(format.Coordinate, count);
        defer a.free(points);
        for (points) |*point| point.* = .{ .lng = random.intRangeAtMost(i32, 0, 200_000), .lat = random.intRangeAtMost(i32, 0, 200_000) };
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(a);
        // A spanning path in input ID order, random chords, a loop and a
        // parallel road, so leaves see joins, cycles and duplicate edges.
        for (1..count) |id| try links.append(a, .{ @intCast(id - 1), @intCast(id) });
        for (0..count) |_| try links.append(a, .{ random.uintLessThan(u32, @intCast(count)), random.uintLessThan(u32, @intCast(count)) });
        try links.append(a, .{ 3, 3 });
        try links.append(a, .{ 1, 2 });
        const fixture = try Fixture.init(points, links.items);
        defer fixture.deinit();
        for ([_]u32{ 0, 1, 8, std.math.maxInt(u32) }) |gap| {
            var options: partition.Options = .{ .leaf_edges = 40, .max_side_percent = 70, .max_link_gap = gap };
            const dissected = try partition.dissect(a, &fixture.view, options);
            defer dissected.deinit(a);
            const single = try partition.build(a, &fixture.view, options);
            defer single.deinit(a);
            options.threads = 8;
            const parallel = try partition.build(a, &fixture.view, options);
            defer parallel.deinit(a);
            try validate(single, &fixture.view, options);
            try expectSameRanges(dissected, single);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(single.nodes), std.mem.sliceAsBytes(parallel.nodes));
            // No two distinct nodes are zero IDs apart, so nothing links.
            if (gap == 0) try std.testing.expectEqualSlices(format.NodeId, dissected.nodes, single.nodes);
        }
    }
}

test "leaf ordering lays a shuffled road out at consecutive ranks" {
    const count = 64;
    var ids: [count]u32 = undefined;
    for (&ids, 0..) |*id, i| id.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(2661);
    prng.random().shuffle(u32, &ids);
    var points: [count]format.Coordinate = undefined;
    // Position i along the road holds node ids[i].
    for (ids, 0..) |id, i| points[id] = .{ .lng = @intCast(1_000 * i), .lat = 0 };
    var links: [count - 1]Link = undefined;
    for (&links, 1..) |*link, i| link.* = .{ ids[i - 1], ids[i] };
    const fixture = try Fixture.init(&points, &links);
    defer fixture.deinit();
    const options: partition.Options = .{ .leaf_edges = 1_000, .max_link_gap = std.math.maxInt(u32) };
    const order = try partition.build(a, &fixture.view, options);
    defer order.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), order.cells.len);
    var ranks: [count]u32 = undefined;
    for (order.nodes, 0..) |node, rank| ranks[@backingInt(node)] = @intCast(rank);
    for (links) |link| {
        const u = ranks[link[0]];
        const v = ranks[link[1]];
        try std.testing.expectEqual(@as(u32, 1), @max(u, v) - @min(u, v));
    }
    // The walk starts from the road's end with the lower input ID.
    try std.testing.expectEqual(@min(ids[0], ids[count - 1]), @backingInt(order.nodes[0]));
}
