// Ported from src/thor/triplegbuilder.cc and src/sif/recost.cc (Valhalla 3.9.3).

const std = @import("std");
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");
const snap = @import("../snap/search.zig");
const Cost = @import("../costing/compiled.zig").Cost;
const base = @import("../costing/base.zig");
const Segment = @import("endpoints.zig").Segment;
const multi = @import("multi.zig");
const multimodal = @import("multimodal.zig");
const transit_leg = @import("transit_leg.zig");
const request = @import("../api/request.zig");
const search = @import("search.zig");
const EdgeId = graph.format.EdgeId;
const View = graph.reader.View;

pub const Edge = struct {
    id: EdgeId,
    ride: ?multimodal.Ride = null,
    length_m: f32,
    elapsed: Cost,
    transition: Cost,
    full_travel_secs: f32 = 0,
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

/// Recompute traversal and transition cost along a fixed directed path.
pub const Recost = struct {
    elapsed: Cost = .{},
    previous: search.Label = .{},

    pub const Step = struct {
        length_m: f32,
        transition: Cost,
        elapsed: Cost,
        full_travel_secs: f32 = 0,
    };

    pub const Options = struct {
        timing: search.Timing = .{},
        control: search.Control = .{},
        ignore_access: bool = true,
    };

    pub fn add(self: *Recost, view: *const View, kernel: anytype, segment: Segment, edge: *const graph.format.EdgeHot, starts_pair: bool) !Step {
        return self.addDirected(view, kernel, segment, edge, starts_pair, false, .forward, .{});
    }

    /// Steps use physical path order. Their cumulative costs start at the
    /// endpoint from which the walk begins.
    pub fn walk(view: *const View, kernel: anytype, path: []const Segment, steps: ?[]Step, comptime direction: search.Direction, options: Options) !Cost {
        if (steps) |out| if (out.len != path.len) return error.InvalidRoute;
        var recost: Recost = .{};
        for (0..path.len) |i| {
            try options.control.check();
            const index = if (direction == .forward) i else path.len - 1 - i;
            const segment = path[index];
            const step = try recost.addDirected(view, kernel, segment, try view.edge(segment.edge), false, i + 1 == path.len, direction, options);
            if (steps) |out| out[index] = step;
        }
        return recost.elapsed;
    }

    inline fn addDirected(self: *Recost, view: *const View, kernel: anytype, segment: Segment, edge: *const graph.format.EdgeHot, starts_pair: bool, terminal: bool, comptime direction: search.Direction, options: Options) !Step {
        if (!(segment.begin >= 0 and segment.end >= segment.begin and segment.end <= 1)) return error.InvalidRoute;
        if (starts_pair) self.previous = .{};
        const first = self.previous.edge == search.no_index;
        const previous = if (first) null else try view.edge(self.previous.edgeId());
        const node: graph.format.NodeId = @fromBackingInt(if (direction == .reverse)
            edge.head
        else if (previous) |incoming|
            incoming.head
        else if (options.timing.start.valid)
            (try view.edge(try view.oppEdge(segment.edge))).head
        else
            edge.head);
        const time: graph.time_info.TimeInfo = if (options.timing.start.valid) try options.timing.at(view, node, self.previous.secs, direction) else .{};
        const traversal = try search.priceEdge(view, kernel, segment.edge, edge, direction, time, false);
        if (traversal.cost.cost == std.math.inf(f32)) return error.InvalidRouteCost;

        var access: base.AccessState = .{};
        if (comptime @hasDecl(@TypeOf(kernel), "restrictionPermission")) {
            const permission = kernel.restrictionPermission();
            const policy: search.PathAccess = .{
                .view = view,
                .permission = permission,
                .timing = options.timing,
                .direction = direction,
                .control = options.control,
                .check_access = !permission.flags.contains(.ignore_restrictions),
            };
            const evaluation = try policy.evaluate(segment.edge, edge, node, self.previous, if (first) .start else if (terminal) .end else .middle);
            const class = try view.class(edge.cls.class_id);
            if (!options.ignore_access and (!evaluation.allowed or !permission.allowedClass(class))) return error.InvalidRouteAccess;
            access = evaluation.state;
        }

        var transition: Cost = .{};
        if (previous) |preceding| {
            const incoming = if (direction == .forward) preceding else edge;
            const outgoing = if (direction == .forward) edge else preceding;
            const outgoing_id = if (direction == .forward) segment.edge else self.previous.edgeId();
            const row = try view.turnRow(node, incoming.cls.opp_local);
            const range = try view.outEdgeRange(node);
            if (outgoing.cls.local >= row.len or range.first + outgoing.cls.local != @backingInt(outgoing_id)) return error.DisconnectedPath;
            const prior = self.previous.accessState();
            const movement: search.Transition = .{
                .node = node,
                .incoming = if (direction == .forward) self.previous.edgeId() else segment.edge,
                .incoming_edge = incoming,
                .outgoing = outgoing_id,
                .outgoing_edge = outgoing,
                .row = row[outgoing.cls.local],
                .incoming_access = if (direction == .forward) prior else access,
                .outgoing_access = if (direction == .forward) access else prior,
                .measured_speed = if (direction == .forward) self.previous.measuredSpeed() else traversal.measured_speed,
            };
            if (comptime @hasDecl(@TypeOf(kernel), "allowedTurn")) {
                if (!options.ignore_access and !try kernel.allowedTurn(view, movement, self.previous, direction)) return error.InvalidRouteAccess;
            }
            transition = try search.priceTurn(view, kernel, movement, self.previous, direction, time);
            if (transition.cost == std.math.inf(f32)) return error.InvalidRouteCost;
        }

        const fraction = segment.end - segment.begin;
        const scale = @max(fraction, std.math.floatEps(f32));
        const full = traversal.cost;
        const step = transition.add(.{ .cost = full.cost * scale, .secs = full.secs * scale });
        self.elapsed = self.elapsed.add(step);
        const pair = (Cost{ .cost = self.previous.cost, .secs = self.previous.secs }).add(step);
        const length = @as(f32, @floatFromInt(edge.geom.len_m)) * fraction;
        self.previous = .{
            .edge = @backingInt(segment.edge),
            .cost = pair.cost,
            .secs = pair.secs,
            .dist_m = self.previous.dist_m +| @as(u32, @intFromFloat(@round(length))),
            .tcost = transition.cost,
        };
        self.previous.setTraversal(access, traversal);
        return .{ .length_m = length, .transition = transition, .elapsed = self.elapsed, .full_travel_secs = full.secs };
    }
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
        output.* = try buildLeg(a, view, kernel, leg, route, correlations, &fixed, &vertices, control);
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

fn buildLeg(a: std.mem.Allocator, view: *const View, kernel: anytype, leg: multi.Leg, route: multi.Route, correlations: []const snap.PathLocation, fixed: *std.ArrayList(geo.FixedLL), vertices: *std.ArrayList(geo.PointLL), control: search.Control) !Leg {
    if (leg.segments.len == 0 or leg.segments.len != leg.segment_contexts.len or leg.origin >= leg.destination or leg.destination >= correlations.len) return error.InvalidRoute;
    const edges = try a.alloc(Edge, leg.segments.len);
    var shape: std.ArrayList(geo.PointLL) = .empty;
    var summary: Summary = .{ .bounds = undefined };
    var recost: Recost = .{};
    var timing: search.Timing = .{ .invariant = route.invariant_time };
    for (leg.segments, leg.segment_contexts, edges, 0..) |segment, context, *output, i| {
        try control.check();
        if (context.pair < leg.origin or context.pair >= leg.destination) return error.InvalidRoute;
        const edge = try view.edge(segment.edge);
        const class = try view.class(edge.cls.class_id);
        if (i == 0 or context.starts_pair) timing.start = route.waypoints[context.pair].clock;
        const step = try recost.addDirected(view, kernel, segment, edge, context.starts_pair, i + 1 == edges.len, .forward, .{
            .timing = timing,
            .control = control,
        });
        const metres: f32 = @floatFromInt(edge.geom.len_m);

        try streetShape(a, view, segment.edge, fixed, vertices, control);
        if (i == 0 or i + 1 == edges.len or segment.begin != 0 or segment.end != 1) {
            // A node snap supplies its node coordinate even at fraction 0 or
            // 1. EdgeInfo vertices have a different coordinate precision.
            const start = if (i == 0 or segment.begin != 0)
                try projected(correlations[context.pair], segment.edge, segment.begin, control)
            else
                vertices.items[0];
            const end = if (i + 1 == edges.len or segment.end != 1)
                try projected(correlations[context.pair + 1], segment.edge, segment.end, control)
            else
                vertices.items[vertices.items.len - 1];
            try geo.line.trimShapeWithDeadline(segment.begin * metres, start, segment.end * metres, end, vertices, control.deadline);
        }
        const shape_begin = try appendShape(a, &shape, vertices.items, &summary.bounds, control);

        output.* = .{
            .id = segment.edge,
            .length_m = step.length_m,
            .elapsed = step.elapsed,
            .transition = step.transition,
            .full_travel_secs = step.full_travel_secs,
            .shape_begin = shape_begin,
            .shape_end = shape.items.len - 1,
        };
        summary.has_toll = summary.has_toll or class.flags.toll;
        summary.has_highway = summary.has_highway or class.category.road_class == @backingInt(graph.constants.RoadClass.motorway);
        summary.has_ferry = summary.has_ferry or class.category.use == @backingInt(graph.constants.Use.ferry);
    }
    summary.length_m = @as(f64, leg.length_km) * 1000;
    summary.time = recost.elapsed.secs;
    summary.cost = recost.elapsed.cost;
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

fn streetShape(a: std.mem.Allocator, view: *const View, id: EdgeId, fixed: *std.ArrayList(geo.FixedLL), vertices: *std.ArrayList(geo.PointLL), control: search.Control) !void {
    const record = try view.coldRecordWithDeadline(id, control.deadline);
    if (record.header.point_count < 2) return error.IncompleteShape;
    try fixed.resize(a, record.header.point_count);
    try record.decodeShape(fixed.items, control.deadline);
    try vertices.resize(a, fixed.items.len);
    for (fixed.items, vertices.items, 0..) |vertex, *point, i| {
        if (i % 256 == 0) try control.check();
        point.* = vertex.toTilePoint();
    }
}

fn appendShape(a: std.mem.Allocator, shape: *std.ArrayList(geo.PointLL), vertices: []const geo.PointLL, bounds: *geo.AABB, control: search.Control) !usize {
    if (vertices.len == 0) return error.IncompleteShape;
    const joined = shape.items.len != 0 and shape.items[shape.items.len - 1].eql(vertices[0]);
    const begin = shape.items.len - @intFromBool(joined);
    const points = vertices[@intFromBool(joined)..];
    if (shape.items.len == 0) bounds.* = geo.AABB.fromPoints(points[0], points[0]);
    try shape.ensureUnusedCapacity(a, points.len);
    for (points, 0..) |point, i| {
        if (i % 256 == 0) try control.check();
        shape.appendAssumeCapacity(point);
        _ = bounds.expandPoint(point);
    }
    return begin;
}

pub const ScheduledLeg = struct {
    geometry: Leg,
    segments: []const Segment,
    contexts: []const multi.SegmentContext,
};

pub fn buildScheduled(a: std.mem.Allocator, view: *const View, paths: []const multimodal.Path, locations: []const request.Location, correlations: []const snap.PathLocation, control: search.Control) ![]const ScheduledLeg {
    if (paths.len == 0 or paths.len + 1 != locations.len or locations.len != correlations.len) return error.InvalidRoute;
    var output: std.ArrayList(ScheduledLeg) = .empty;
    var fixed: std.ArrayList(geo.FixedLL) = .empty;
    defer fixed.deinit(a);
    var vertices: std.ArrayList(geo.PointLL) = .empty;
    defer vertices.deinit(a);
    var first: usize = 0;
    for (locations[1..], 1..) |location, last| {
        try control.check();
        if (last != paths.len and location.type != .@"break" and location.type != .break_through) continue;
        const leg = try scheduledLeg(a, view, paths[first..last], first, correlations, &fixed, &vertices, control);
        try output.append(a, leg);
        first = last;
    }
    return output.items;
}

fn scheduledLeg(a: std.mem.Allocator, view: *const View, paths: []const multimodal.Path, first: usize, correlations: []const snap.PathLocation, fixed: *std.ArrayList(geo.FixedLL), vertices: *std.ArrayList(geo.PointLL), control: search.Control) !ScheduledLeg {
    var count: usize = 0;
    for (paths) |path| {
        try control.check();
        count = try std.math.add(usize, count, path.steps.len);
    }
    const edges = try a.alloc(Edge, count);
    const segments = try a.alloc(Segment, count);
    const contexts = try a.alloc(multi.SegmentContext, count);
    var shape: std.ArrayList(geo.PointLL) = .empty;
    var summary: Summary = .{ .bounds = undefined };
    var offset: Cost = .{};
    var index: usize = 0;
    for (paths, first..) |path, pair| {
        var prior_secs: f32 = 0;
        for (path.steps, 0..) |step, i| {
            try control.check();
            const segment: Segment = switch (step.movement) {
                .walk => |walk| walk,
                .ride => .{ .edge = @fromBackingInt(search.no_index), .begin = 0, .end = 1 },
            };
            segments[index] = segment;
            contexts[index] = .{ .pair = pair, .starts_pair = i == 0 };
            var metres: f32 = 0;
            var vehicle_time: f32 = 0;
            switch (step.movement) {
                .walk => {
                    const edge = try view.edge(segment.edge);
                    const class = try view.class(edge.cls.class_id);
                    try streetShape(a, view, segment.edge, fixed, vertices, control);
                    const full_length: f32 = @floatFromInt(edge.geom.len_m);
                    const portion = segment.end - segment.begin;
                    metres = full_length * portion;
                    if (portion > 0) vehicle_time = (step.elapsed.secs - prior_secs - step.transition.secs) / portion;
                    if (i == 0 or i + 1 == path.steps.len or segment.begin != 0 or segment.end != 1) {
                        const start = if (i == 0 or segment.begin != 0) try projected(correlations[pair], segment.edge, segment.begin, control) else vertices.items[0];
                        const end = if (i + 1 == path.steps.len or segment.end != 1) try projected(correlations[pair + 1], segment.edge, segment.end, control) else vertices.items[vertices.items.len - 1];
                        try geo.line.trimShapeWithDeadline(segment.begin * full_length, start, segment.end * full_length, end, vertices, control.deadline);
                    }
                    summary.has_toll = summary.has_toll or class.flags.toll;
                    summary.has_highway = summary.has_highway or class.category.road_class == @backingInt(graph.constants.RoadClass.motorway);
                    summary.has_ferry = summary.has_ferry or class.category.use == @backingInt(graph.constants.Use.ferry);
                },
                .ride => |ride| {
                    const table = view.transit_index orelse return error.MissingTransitSection;
                    const ends = try transit_leg.stops(table, ride);
                    try vertices.resize(a, 2);
                    vertices.items[0] = table.stops[ends.from].place.coordinate.toTilePoint();
                    vertices.items[1] = table.stops[ends.to].place.coordinate.toTilePoint();
                    metres = @floatCast(vertices.items[0].distance(vertices.items[1]));
                    vehicle_time = @floatFromInt(ride.arrival_time - ride.departure_time);
                },
            }
            const begin = try appendShape(a, &shape, vertices.items, &summary.bounds, control);
            edges[index] = .{
                .id = segment.edge,
                .ride = if (step.movement == .ride) step.movement.ride else null,
                .length_m = metres,
                .elapsed = offset.add(step.elapsed),
                .transition = step.transition,
                .full_travel_secs = vehicle_time,
                .shape_begin = begin,
                .shape_end = shape.items.len - 1,
            };
            summary.length_m += metres;
            prior_secs = step.elapsed.secs;
            index += 1;
        }
        offset = offset.add(path.total);
    }
    if (shape.items.len == 0) return error.InvalidRoute;
    summary.time = offset.secs;
    summary.cost = offset.cost;
    const encoded = try a.alloc(u8, geo.polyline.maxEncodedLen(.polyline, shape.items.len));
    const size = try geo.polyline.encodeWithDeadline(.polyline, 6, shape.items, encoded, control.deadline);
    return .{
        .geometry = .{ .origin = first, .destination = first + paths.len, .edges = edges, .shape = shape.items, .encoded_shape = encoded[0..size], .summary = summary },
        .segments = segments,
        .contexts = contexts,
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
