// Ported from src/thor/triplegbuilder.cc and src/sif/recost.cc (Valhalla 3.9.3).

const std = @import("std");
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");
const snap = @import("../snap/search.zig");
const Cost = @import("../costing/compiled.zig").Cost;
const multi = @import("multi.zig");
const search = @import("search.zig");
const EdgeId = graph.format.EdgeId;
const View = graph.reader.View;

pub const Edge = struct {
    id: EdgeId,
    length_m: f32,
    elapsed: Cost,
    transition: Cost,
    shape_begin: usize,
    shape_end: usize,
};

pub const Summary = struct {
    length_m: f64 = 0,
    time: f64 = 0,
    /// Recosted traversal and transition weight.
    cost: f64 = 0,
    bounds: geo.AABB,
    has_toll: bool = false,
    has_highway: bool = false,
    has_ferry: bool = false,
    // Populated when timed access restrictions participate in search (P5.15).
    has_time_restrictions: bool = false,
};

pub const Leg = struct {
    origin: usize,
    destination: usize,
    edges: []const Edge,
    shape: []const geo.PointLL,
    encoded_shape: []const u8,
    summary: Summary,
};

pub const Trip = struct {
    legs: []const Leg,
    summary: Summary,
};

/// Assemble the selected path in travel order. The allocator and correlations
/// come from the same request that produced the route.
pub fn build(a: std.mem.Allocator, view: *const View, kernel: anytype, route: multi.Route, correlations: []const snap.PathLocation, control: search.Control) !Trip {
    if (route.legs.len == 0 or route.waypoints.len != correlations.len) return error.InvalidRoute;
    const legs = try a.alloc(Leg, route.legs.len);
    var fixed: std.ArrayList(geo.FixedLL) = .empty;
    defer fixed.deinit(a);
    var vertices: std.ArrayList(geo.PointLL) = .empty;
    defer vertices.deinit(a);
    var summary: Summary = undefined;
    for (route.legs, legs, 0..) |leg, *output, i| {
        try control.check();
        output.* = try buildLeg(a, view, kernel, leg, correlations, &fixed, &vertices, control);
        const step = output.summary;
        if (i == 0) {
            summary = step;
        } else {
            summary.length_m += step.length_m;
            summary.time += step.time;
            summary.cost += step.cost;
            summary.bounds.expand(step.bounds);
            summary.has_toll = summary.has_toll or step.has_toll;
            summary.has_highway = summary.has_highway or step.has_highway;
            summary.has_ferry = summary.has_ferry or step.has_ferry;
            summary.has_time_restrictions = summary.has_time_restrictions or step.has_time_restrictions;
        }
    }
    return .{ .legs = legs, .summary = summary };
}

fn buildLeg(a: std.mem.Allocator, view: *const View, kernel: anytype, leg: multi.Leg, correlations: []const snap.PathLocation, fixed: *std.ArrayList(geo.FixedLL), vertices: *std.ArrayList(geo.PointLL), control: search.Control) !Leg {
    if (leg.segments.len == 0 or leg.segments.len != leg.segment_contexts.len or leg.origin >= leg.destination or leg.destination >= correlations.len) return error.InvalidRoute;
    const edges = try a.alloc(Edge, leg.segments.len);
    var shape: std.ArrayList(geo.PointLL) = .empty;
    var summary: Summary = .{ .bounds = undefined };
    var elapsed: Cost = .{};
    var previous: search.Label = .{};
    for (leg.segments, leg.segment_contexts, edges, 0..) |segment, context, *output, i| {
        try control.check();
        if (context.pair < leg.origin or context.pair >= leg.destination or
            !(segment.begin >= 0 and segment.end >= segment.begin and segment.end <= 1)) return error.InvalidRoute;
        const edge = try view.edge(segment.edge);
        const class = try view.class(edge.cls.class_id);
        const metres: f32 = @floatFromInt(edge.geom.len_m);
        const fraction = segment.end - segment.begin;
        const length = metres * fraction;

        const record = try view.coldRecord(segment.edge);
        if (record.header.point_count < 2) return error.IncompleteShape;
        try fixed.resize(a, record.header.point_count);
        try record.decodeShape(fixed.items, control.deadline);
        try vertices.resize(a, fixed.items.len);
        for (fixed.items, vertices.items, 0..) |vertex, *point, j| {
            if (j % 256 == 0) try control.check();
            point.* = vertex.toTilePoint();
        }
        if (i == 0 or i + 1 == edges.len or segment.begin != 0 or segment.end != 1) {
            const start = if (segment.begin == 0) vertices.items[0] else try projected(correlations[context.pair], segment.edge, segment.begin, control);
            const end = if (segment.end == 1) vertices.items[vertices.items.len - 1] else try projected(correlations[context.pair + 1], segment.edge, segment.end, control);
            try geo.line.trimShapeWithDeadline(segment.begin * metres, start, segment.end * metres, end, vertices, control.deadline);
        }
        const joined = shape.items.len != 0 and shape.items[shape.items.len - 1].eql(vertices.items[0]);
        const shape_begin = shape.items.len - @intFromBool(joined);
        const points = vertices.items[@intFromBool(joined)..];
        if (shape.items.len == 0) summary.bounds = geo.AABB.fromPoints(points[0], points[0]);
        try shape.ensureUnusedCapacity(a, points.len);
        for (points, 0..) |point, j| {
            if (j % 256 == 0) try control.check();
            shape.appendAssumeCapacity(point);
            _ = summary.bounds.expandPoint(point);
        }

        var transition: Cost = .{};
        if (context.starts_pair) previous = .{};
        if (previous.edge != search.no_index) {
            const incoming = try view.edge(previous.edgeId());
            const node: graph.format.NodeId = @fromBackingInt(incoming.head);
            const row = try view.turnRow(node, incoming.cls.opp_local);
            const range = try view.outEdgeRange(node);
            if (edge.cls.local >= row.len or range.first + edge.cls.local != @backingInt(segment.edge)) return error.DisconnectedPath;
            transition = try kernel.turnCost(view, .{
                .node = node,
                .incoming = previous.edgeId(),
                .incoming_edge = incoming,
                .outgoing = segment.edge,
                .outgoing_edge = edge,
                .row = row[edge.cls.local],
            }, previous, .forward);
        }
        const full = try kernel.edgeCost(view, segment.edge, edge, .forward);
        if (full.cost == std.math.inf(f32) or transition.cost == std.math.inf(f32)) return error.InvalidRouteCost;
        const scale = @max(fraction, std.math.floatEps(f32));
        elapsed = elapsed.add(transition.add(.{ .cost = full.cost * scale, .secs = full.secs * scale }));
        previous = .{
            .edge = @backingInt(segment.edge),
            .cost = elapsed.cost,
            .secs = elapsed.secs,
            .dist_m = previous.dist_m +| @as(u32, @intFromFloat(@round(length))),
            .tcost = transition.cost,
        };
        output.* = .{
            .id = segment.edge,
            .length_m = length,
            .elapsed = elapsed,
            .transition = transition,
            .shape_begin = shape_begin,
            .shape_end = shape.items.len - 1,
        };
        summary.has_toll = summary.has_toll or class.flags.toll;
        summary.has_highway = summary.has_highway or class.category.road_class == @backingInt(graph.constants.RoadClass.motorway);
        summary.has_ferry = summary.has_ferry or class.category.use == @backingInt(graph.constants.Use.ferry);
    }
    summary.length_m = @as(f64, leg.length_km) * 1000;
    summary.time = elapsed.secs;
    summary.cost = elapsed.cost;
    const encoded = try a.alloc(u8, geo.polyline.maxEncodedLen(.polyline, shape.items.len));
    const size = try geo.polyline.encodeWithDeadline(.polyline, 6, shape.items, encoded, control.deadline);
    try control.check();
    return .{
        .origin = leg.origin,
        .destination = leg.destination,
        .edges = edges,
        .shape = shape.items,
        .encoded_shape = encoded[0..size],
        .summary = summary,
    };
}

fn projected(location: snap.PathLocation, edge: EdgeId, fraction: f32, control: search.Control) !geo.PointLL {
    for ([_][]const snap.PathEdge{ location.edges, location.filtered_edges }) |candidates| {
        for (candidates, 0..) |candidate, i| {
            if (i % 64 == 0) try control.check();
            if (candidate.id == edge and candidate.percent_along == fraction) return candidate.projected;
        }
    }
    return error.MissingPathCorrelation;
}
