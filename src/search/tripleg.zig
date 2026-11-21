// Ported from src/thor/triplegbuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const model = @import("../api/trip.zig");
const request = @import("../api/request.zig");
const Attributes = @import("../api/attributes.zig").Controller;
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");
const format = graph.format;
const View = graph.reader.View;
const Control = @import("search.zig").Control;
const Segment = @import("endpoints.zig").Segment;
const multi = @import("multi.zig");
const legs = @import("legs.zig");
const transit = @import("transit_leg.zig");
const Ride = @import("multimodal.zig").Ride;
const Cost = @import("../costing/compiled.zig").Cost;
const snap = @import("../snap/search.zig");

pub const Travel = union(enum) {
    drive: model.VehicleType,
    pedestrian: model.PedestrianType,
    bicycle: model.BicycleType,
};

pub const Input = struct {
    segments: []const Segment,
    geometry: *const legs.Leg,
    attributes: Attributes = .{},
    travel: Travel = .{ .drive = .kCar },
    locations: ?Locations = null,
    algorithms: []const []const u8 = &.{},
    trace: bool = false,
    leg_id: u32 = 0,
    leg_count: u32 = 1,
};

pub const Locations = struct {
    requested: []const request.Location,
    correlations: []const snap.PathLocation,
    waypoints: []const multi.Waypoint,
    segment_contexts: []const multi.SegmentContext,
};

/// Projects a recosted leg into the trip model. The path and geometry come
/// from the same request. The output borrows strings from its graph view and
/// all constructed arrays belong to the caller's request arena.
pub fn build(a: std.mem.Allocator, view: *const View, input: Input, control: Control) !model.TripLeg {
    try control.check();
    const geometry = input.geometry;
    if (input.segments.len == 0 or input.segments.len != geometry.edges.len or geometry.shape.len == 0)
        return error.InvalidRoute;

    const attrs = input.attributes;
    const include_dataset_id = attrs.has(.osm_changeset) and view.dataset_id != null;
    var dataset_id: u64 = 0;
    const nodes = try a.alloc(model.Node, input.segments.len + 1);
    var admins: std.ArrayList(graph.admin.Names) = .empty;
    defer admins.deinit(a);
    var elapsed: Cost = .{};
    var end_node: format.NodeId = undefined;
    var previous: ?format.EdgeId = null;
    var previous_ride: ?Ride = null;
    for (input.segments, geometry.edges, nodes[0..input.segments.len]) |segment, edge, *out| {
        try control.check();
        if (segment.edge != edge.id or edge.shape_begin > edge.shape_end or edge.shape_end >= geometry.shape.len or
            !(segment.begin >= 0 and segment.end >= segment.begin and segment.end <= 1))
            return error.InvalidRoute;
        var from: format.NodeId = undefined;
        var street: ?*const format.EdgeHot = null;
        var platform: ?u32 = null;
        const trip_edge = if (edge.ride) |ride| blk: {
            const table = view.transit_index orelse return error.MissingTransitSection;
            const ends = try transit.stops(table, ride);
            from = try transit.node(table, ends.from);
            end_node = try transit.node(table, ends.to);
            platform = ends.from;
            break :blk try rideEdge(table, ride, edge, attrs);
        } else blk: {
            const directed = try view.edge(edge.id);
            street = directed;
            const opposite = try view.edge(try view.oppEdge(edge.id));
            from = @fromBackingInt(opposite.head);
            end_node = @fromBackingInt(directed.head);
            if (previous_ride) |ride| {
                const table = view.transit_index orelse return error.MissingTransitSection;
                platform = (try transit.stops(table, ride)).to;
            }
            break :blk try buildEdge(a, view, from, try view.node(from), directed, segment, edge, input, control);
        };
        const node = try view.node(from);
        if (include_dataset_id and dataset_id == 0) dataset_id = view.nodeDatasetId(from) orelse 0;
        out.* = .{
            .edge = trip_edge,
            .cost = nodeCost(attrs, elapsed, edge.transition),
        };
        if (platform) |id| {
            if (attrs.hasAny("node.transit_platform_info."))
                out.transit_platform_info = try transit.platformInfo(a, view, id, previous_ride, edge.ride, attrs);
        }
        if (attrs.has(.@"node.type"))
            out.type = std.enums.fromInt(model.NodeType, node.attr.type) orelse .kStreetIntersection;
        if (attrs.has(.@"node.traffic_signal")) out.traffic_signal = node.attr.signal != 0;
        if (attrs.has(.@"node.fork")) out.fork = node.attr.intersection == .fork;
        if (attrs.has(.@"node.time_zone")) {
            const zone = try view.nodeTimezone(from);
            if (view.tz_rules) |rules| out.time_zone = (try rules.name(zone)) orelse "";
        }
        if (attrs.has(.@"node.admin_index"))
            out.admin_index = try adminIndex(a, &admins, try view.nodeAdmin(from), control);
        if (street) |directed| {
            if (attrs.hasAny("node.intersecting_edge.") or (input.trace and (attrs.hasAny("node.") or attrs.has(.@"edge.names"))))
                out.intersecting_edge = try intersections(a, view, from, edge.id, directed, previous, input.trace, attrs, control);
            if (attrs.has(.@"node.stop_impact")) {
                if (previous) |id| {
                    const incoming = try view.edge(id);
                    if (incoming.head == @backingInt(from)) {
                        const row = try view.turnRow(from, incoming.cls.opp_local);
                        if (directed.cls.local >= row.len) return error.InvalidLocalEdge;
                        out.stop_impact = (row[directed.cls.local] >> 3) & 7;
                    }
                }
            }
        }
        previous = if (street != null) edge.id else null;
        previous_ride = edge.ride;
        elapsed = edge.elapsed;
    }

    const last = &nodes[nodes.len - 1];
    last.* = .{ .cost = nodeCost(attrs, elapsed, .{}) };
    if (attrs.has(.@"node.admin_index"))
        last.admin_index = try adminIndex(a, &admins, try view.nodeAdmin(end_node), control);
    const bbox: model.BoundingBox = .{
        .min_ll = latLng(geometry.summary.bounds.minpt()),
        .max_ll = latLng(geometry.summary.bounds.maxpt()),
    };
    const locations = if (input.locations) |source| try projectLocations(a, input, source, control) else &.{};
    return .{
        .osm_changeset = dataset_id,
        .leg_id = input.leg_id,
        .leg_count = input.leg_count,
        .location = locations,
        .node = nodes,
        .admin = try projectAdmins(a, attrs, admins.items, control),
        .shape = if (attrs.has(.shape)) geometry.encoded_shape else "",
        .bbox = bbox,
        .shape_attributes = try shapeAttributes(a, view, input, control),
        .level_changes = if (attrs.has(.@"edge.levels")) try levelChanges(a, geometry.edges, nodes, locations, control) else &.{},
        .algorithms = input.algorithms,
        .summary = .{
            .length = @floatCast(geometry.summary.length_m / 1000),
            .time = geometry.summary.time,
            .bbox = bbox,
            .has_time_restrictions = geometry.summary.has_time_restrictions,
            .has_toll = geometry.summary.has_toll,
            .has_ferry = geometry.summary.has_ferry,
            .has_highway = geometry.summary.has_highway,
        },
    };
}

fn rideEdge(table: graph.transit.View, ride: Ride, edge: legs.Edge, attrs: Attributes) !model.Edge {
    if (ride.departure.route >= table.routes.len) return error.InvalidTransitRoute;
    const route = table.routes[ride.departure.route];
    const use = @import("../costing/transit.zig").vehicleUse(route.flags.vehicle);
    var result: model.Edge = .{ .source_along_edge = 0, .target_along_edge = 1 };
    if (attrs.has(.@"edge.id")) result.id = ride.departure.line;
    if (attrs.has(.@"edge.length")) result.length_km = edge.length_m * 0.001;
    if (attrs.has(.@"edge.speed") and edge.full_travel_secs > 0) result.speed = edge.length_m * 3.6 / edge.full_travel_secs;
    if (attrs.has(.@"edge.begin_shape_index")) result.begin_shape_index = try shapeIndex(edge.shape_begin);
    if (attrs.has(.@"edge.end_shape_index")) result.end_shape_index = try shapeIndex(edge.shape_end);
    if (attrs.has(.@"edge.use")) result.use = if (use == .rail) .kRailUse else .kBusUse;
    if (attrs.has(.@"edge.travel_mode")) result.travel_mode = .kTransit;
    if (attrs.has(.@"edge.transit_type")) result.transit_type = switch (route.flags.vehicle) {
        .tram, .metro, .rail, .bus, .ferry, .cable_car, .gondola, .funicular => @fromBackingInt(@as(i32, @backingInt(route.flags.vehicle))),
        .trolleybus => .kBus,
        else => .kRail,
    };
    if (attrs.hasAny("edge.transit_route_info.")) result.transit_route_info = try transit.routeInfo(table, ride, attrs);
    return result;
}

fn latLng(point: geo.PointLL) model.LatLng {
    return .{ .lat = point.lat, .lng = point.lng };
}

pub fn traceEndpoints(a: std.mem.Allocator, geometry: *const legs.Leg, requested: []const request.Location, path: []const Segment, origin_distance: f32, destination_distance: f32) ![]const model.Location {
    const locations = try a.alloc(model.Location, 2);
    const chosen = try a.alloc(model.PathEdge, 2);
    const last = path.len - 1;
    for (locations, chosen, [_]usize{ geometry.origin, geometry.destination }, [_]usize{ 0, last }, [_]f32{ path[0].begin, path[last].end }, [_]f32{ origin_distance, destination_distance }, [_]geo.PointLL{ geometry.shape[0], geometry.shape[geometry.shape.len - 1] }) |*out, *edge, index, part, fraction, distance, point| {
        edge.* = .{
            .graph_id = @backingInt(path[part].edge),
            .percent_along = fraction,
            .ll = latLng(point),
            .distance = distance,
        };
        out.* = copyLocation(requested[index]);
        out.correlation = .{
            .edges = @as(*[1]model.PathEdge, @ptrCast(edge)),
            .projected_ll = edge.ll,
            .original_index = requested[index].original_index,
        };
    }
    return locations;
}

fn projectLocations(a: std.mem.Allocator, input: Input, source: Locations, control: Control) ![]const model.Location {
    const origin = input.geometry.origin;
    const dest = input.geometry.destination;
    if (origin >= dest or dest >= source.requested.len or dest >= source.correlations.len or dest >= source.waypoints.len or
        source.segment_contexts.len != input.segments.len) return error.InvalidRoute;
    const locations = try a.alloc(model.Location, dest - origin + 1);
    const chosen = try a.alloc(model.PathEdge, locations.len);
    var index: usize = 0;
    var distance: f64 = 0;
    for (locations, chosen, origin..dest + 1) |*out, *path_edge, location| {
        try control.check();
        if (location != origin) {
            const pair = location - 1;
            while (index + 1 < input.segments.len and source.segment_contexts[index + 1].pair <= pair) {
                try control.check();
                distance += input.geometry.edges[index].length_m;
                index += 1;
            }
            if (source.segment_contexts[index].pair != pair) return error.InvalidRoute;
        }
        const first = location == origin;
        const segment = input.segments[index];
        const geometry = input.geometry.edges[index];
        const fraction = if (first) segment.begin else segment.end;
        const shape_index = if (first) geometry.shape_begin else geometry.shape_end;
        const candidate = (try selectedCandidate(source.correlations[location], segment.edge, fraction, control)) orelse
            return error.MissingPathCorrelation;
        const side: model.SideOfStreet = @fromBackingInt(@backingInt(candidate.side));
        path_edge.* = .{
            .graph_id = @backingInt(segment.edge),
            .percent_along = candidate.percent_along,
            .ll = latLng(candidate.projected),
            .side_of_street = side,
            .distance = candidate.distance,
            .begin_node = candidate.node == .begin,
            .end_node = candidate.node == .end,
            .outbound_reach = @intCast(@min(candidate.reach.outbound, std.math.maxInt(i32))),
            .inbound_reach = @intCast(@min(candidate.reach.inbound, std.math.maxInt(i32))),
            .heading = candidate.heading,
        };
        const waypoint = source.waypoints[location];
        out.* = copyLocation(source.requested[location]);
        out.date_time = waypoint.date_time orelse out.date_time;
        out.waiting_secs = waypoint.waiting_secs;
        out.time_zone_offset = waypoint.time_zone_offset;
        out.time_zone_name = waypoint.time_zone_name;
        if (first or location == dest) out.side_of_street = side;
        out.correlation = .{
            .edges = @as(*[1]model.PathEdge, @ptrCast(path_edge)),
            .original_index = source.requested[location].original_index,
            .projected_ll = if (first or location == dest) path_edge.ll else null,
            .leg_shape_index = if (first or location == dest) 0 else try shapeIndex(shape_index),
            .distance_from_leg_origin = if (first or location == dest) 0 else distance + geometry.length_m,
        };
    }
    return locations;
}

fn selectedCandidate(correlation: snap.PathLocation, id: format.EdgeId, fraction: f32, control: Control) !?snap.PathEdge {
    var same_edge: ?snap.PathEdge = null;
    for ([_][]const snap.PathEdge{ correlation.edges, correlation.filtered_edges }) |candidates| {
        for (candidates, 0..) |candidate, i| {
            if (i % 64 == 0) try control.check();
            if (candidate.id != id) continue;
            if (candidate.percent_along == fraction) return candidate;
            if (same_edge == null) same_edge = candidate;
        }
    }
    return same_edge;
}

fn copyLocation(location: request.Location) model.Location {
    const filter = location.search_filter;
    return .{
        .ll = .{ .lat = location.lat, .lng = location.lng },
        .type = @fromBackingInt(@backingInt(location.type)),
        .heading = if (location.heading) |value| @bitCast(value) else null,
        .name = location.name orelse "",
        .street = location.street orelse "",
        .date_time = location.date_time orelse "",
        .heading_tolerance = if (location.heading_tolerance) |value| @bitCast(value) else null,
        .node_snap_tolerance = if (location.node_snap_tolerance) |value| @intFromFloat(@min(@max(value, 0), 4294967040)) else null,
        .minimum_reachability = location.minimum_reachability,
        .radius = location.radius,
        .accuracy = location.accuracy,
        .time = if (location.time >= 0) location.time else null,
        .skip_ranking_candidates = location.skip_ranking_candidates,
        .preferred_side = @fromBackingInt(@backingInt(location.preferred_side)),
        .display_ll = if (location.display_lat != null and location.display_lng != null)
            .{ .lat = location.display_lat, .lng = location.display_lng }
        else
            null,
        .search_cutoff = location.search_cutoff,
        .street_side_tolerance = location.street_side_tolerance,
        .street_side_max_distance = location.street_side_max_distance,
        .preferred_layer = location.preferred_layer,
        .waiting_secs = location.waiting_secs,
        .street_side_cutoff = if (location.street_side_cutoff) |value| @fromBackingInt(@backingInt(value)) else null,
        .minimum_inbound_reachability = location.minimum_inbound_reachability,
        .minimum_outbound_reachability = location.minimum_outbound_reachability,
        .search_filter = .{
            .min_road_class = @fromBackingInt(@backingInt(filter.min_road_class)),
            .max_road_class = @fromBackingInt(@backingInt(filter.max_road_class)),
            .exclude_tunnel = filter.exclude_tunnel,
            .exclude_bridge = filter.exclude_bridge,
            .exclude_ramp = filter.exclude_ramp,
            .exclude_closures = filter.exclude_closures,
            .exclude_toll = filter.exclude_toll,
            .exclude_ferry = filter.exclude_ferry,
            .exclude_steps = filter.exclude_steps,
            .exclude_restricted = filter.exclude_restricted,
            .level = if (filter.level == request.max_level) null else filter.level,
        },
    };
}

fn shapeIndex(index: usize) !u32 {
    return std.math.cast(u32, index) orelse error.TooManyShapePoints;
}

fn shapeAttributes(a: std.mem.Allocator, view: *const View, input: Input, control: Control) !?model.ShapeAttributes {
    const attrs = input.attributes;
    if (!attrs.hasAny("shape_attributes.")) return null;
    const with_time = attrs.has(.@"shape_attributes.time");
    const with_length = attrs.has(.@"shape_attributes.length");
    const with_speed = attrs.has(.@"shape_attributes.speed");
    const with_limit = attrs.has(.@"shape_attributes.speed_limit");
    const with_congestion = attrs.has(.@"shape_attributes.congestion");
    const with_distance = with_length or with_time or with_speed;
    const points = input.geometry.shape;
    const count = points.len - 1;
    const time: []u32 = if (with_time) try a.alloc(u32, count) else &.{};
    const length: []u32 = if (with_length) try a.alloc(u32, count) else &.{};
    const speed: []u32 = if (with_speed) try a.alloc(u32, count) else &.{};
    const limit: []u32 = if (with_limit) try a.alloc(u32, count) else &.{};
    const congestion: []u32 = if (with_congestion) try a.alloc(u32, count) else &.{};
    var written: usize = 0;
    var prior_time: f32 = 0;
    for (input.geometry.edges, input.segments) |edge, segment| {
        try control.check();
        if (edge.shape_end - edge.shape_begin > count - written) return error.InvalidRoute;
        const duration = if (edge.ride != null) edge.full_travel_secs else edge.elapsed.secs - edge.transition.secs - prior_time;
        prior_time = edge.elapsed.secs;
        const travelled = if (with_time or with_speed) blk: {
            if (edge.ride != null) break :blk @as(f64, edge.length_m);
            const directed = try view.edge(edge.id);
            const metres: f64 = @floatFromInt(directed.geom.len_m);
            break :blk metres * (@as(f64, segment.end) - segment.begin);
        } else 0;
        const speed_mps = if (travelled == 0 or duration <= 0) 0 else travelled / duration;
        const speed_limit = if (with_limit and edge.ride == null)
            (try view.coldRecordWithDeadline(edge.id, control.deadline)).speedLimit()
        else
            0;
        for (edge.shape_begin..edge.shape_end) |index| {
            if (written % 256 == 0) try control.check();
            const distance = if (with_distance) points[index].distance(points[index + 1]) else 0;
            const seconds = if (speed_mps == 0) 0 else distance / speed_mps;
            if (with_time) time[written] = try roundedAttribute(seconds * 1000);
            if (with_length) length[written] = try roundedAttribute(distance * 10);
            if (with_speed) speed[written] = try roundedAttribute(if (seconds == 0) 0 else distance * 10 / seconds);
            if (with_limit) limit[written] = speed_limit;
            if (with_congestion) congestion[written] = 0;
            written += 1;
        }
    }
    return .{
        .time = if (with_time) time[0..written] else &.{},
        .length = if (with_length) length[0..written] else &.{},
        .speed = if (with_speed) speed[0..written] else &.{},
        .speed_limit = if (with_limit) limit[0..written] else &.{},
        .congestion = if (with_congestion) congestion[0..written] else &.{},
    };
}

fn roundedAttribute(value: f64) !u32 {
    const rounded = @round(value);
    if (!(rounded >= 0 and rounded <= std.math.maxInt(u32))) return error.InvalidShapeAttribute;
    return @intFromFloat(rounded);
}

fn levelChanges(a: std.mem.Allocator, geometry: []const legs.Edge, nodes: []const model.Node, locations: []const model.Location, control: Control) ![]const model.LevelChange {
    const origin_level = if (locations.len == 0) null else locations[0].search_filter.?.level;
    const dest_level = if (locations.len == 0) null else locations[locations.len - 1].search_filter.?.level;
    var changes: std.ArrayList(model.LevelChange) = .empty;
    var previous: ?f32 = null;
    for (geometry, nodes[0..geometry.len], 0..) |edge, node, i| {
        try control.check();
        const value = node.edge.?;
        if (value.levels.len == 0) continue;
        const multi_level = value.levels.len != 1 or value.levels[0].start != value.levels[0].end;
        const first = i == 0;
        const last = i + 1 == geometry.len;
        const level = if (!multi_level) value.levels[0].start else if (first) origin_level else null;
        if (level) |floor| {
            if (previous == null or @abs(floor - previous.?) >= std.math.floatEps(f32)) {
                try changes.append(a, .{ .shape_index = try shapeIndex(edge.shape_begin), .level = floor, .precision = value.level_precision });
                previous = floor;
            }
        }
        if (last and multi_level) {
            if (dest_level) |floor|
                try changes.append(a, .{ .shape_index = try shapeIndex(edge.shape_end), .level = floor, .precision = value.level_precision });
        }
    }
    return changes.items;
}

fn nodeCost(attrs: Attributes, elapsed: Cost, transition: Cost) ?model.PathCost {
    const include_elapsed = attrs.has(.@"node.elapsed_time");
    const include_transition = attrs.has(.@"node.transition_time");
    if (!include_elapsed and !include_transition) return null;
    return .{
        .elapsed_cost = if (include_elapsed) .{ .seconds = elapsed.secs, .cost = elapsed.cost } else null,
        .transition_cost = if (include_transition) .{ .seconds = transition.secs, .cost = transition.cost } else null,
    };
}

fn adminIndex(a: std.mem.Allocator, admins: *std.ArrayList(graph.admin.Names), names: graph.admin.Names, control: Control) !u32 {
    for (admins.items, 0..) |known, i| {
        if (i % 64 == 0) try control.check();
        if (std.mem.eql(u8, known.country, names.country) and std.mem.eql(u8, known.country_iso, names.country_iso) and
            std.mem.eql(u8, known.state, names.state) and std.mem.eql(u8, known.state_iso, names.state_iso)) return @intCast(i);
    }
    const index = std.math.cast(u32, admins.items.len) orelse return error.TooManyAdmins;
    try admins.append(a, names);
    return index;
}

fn projectAdmins(a: std.mem.Allocator, attrs: Attributes, admins: []const graph.admin.Names, control: Control) ![]const model.Admin {
    if (!attrs.hasAny("admin.")) return &.{};
    const result = try a.alloc(model.Admin, admins.len);
    for (admins, result, 0..) |names, *out, i| {
        if (i % 64 == 0) try control.check();
        // The first tile admin is the placeholder with empty ISO codes.
        const unknown = names.country.len == 0 and names.country_iso.len == 0 and
            names.state.len == 0 and names.state_iso.len == 0;
        out.* = .{
            .country_code = if (attrs.has(.@"admin.country_code")) names.country_iso else "",
            .country_text = if (attrs.has(.@"admin.country_text")) (if (unknown) "None" else names.country) else "",
            .state_code = if (attrs.has(.@"admin.state_code")) names.state_iso else "",
            .state_text = if (attrs.has(.@"admin.state_text")) (if (unknown) "None" else names.state) else "",
        };
    }
    return result;
}

fn buildEdge(a: std.mem.Allocator, view: *const View, from: format.NodeId, node: *const format.NodeHot, directed: *const format.EdgeHot, segment: Segment, edge: legs.Edge, input: Input, control: Control) !model.Edge {
    const attrs = input.attributes;
    const class = try view.class(directed.cls.class_id);
    var result: model.Edge = .{ .source_along_edge = segment.begin, .target_along_edge = segment.end };
    const metres: f32 = @floatFromInt(directed.geom.len_m);
    if (attrs.has(.@"edge.length")) result.length_km = metres * 0.001 * (segment.end - segment.begin);
    if (attrs.has(.@"edge.speed") and edge.full_travel_secs > 0) {
        const metres_per_second: f32 = metres / edge.full_travel_secs;
        result.speed = @floatCast(@as(f64, metres_per_second) * 3.6);
    }
    if (attrs.has(.@"edge.road_class")) result.road_class = @fromBackingInt(class.category.road_class);
    if (attrs.has(.@"edge.use")) result.use = std.enums.fromInt(model.Use, class.category.use) orelse .kOtherUse;
    if (attrs.has(.@"edge.surface")) result.surface = @fromBackingInt(class.category.surface);
    if (attrs.has(.@"edge.toll")) result.toll = class.flags.toll;
    if (attrs.has(.@"edge.unpaved")) result.unpaved = class.category.surface >= @backingInt(graph.constants.Surface.compacted);
    if (attrs.has(.@"edge.tunnel")) result.tunnel = class.flags.tunnel;
    if (attrs.has(.@"edge.bridge")) result.bridge = class.flags.bridge;
    if (attrs.has(.@"edge.roundabout")) result.roundabout = class.flags.roundabout;
    if (attrs.has(.@"edge.internal_intersection")) result.internal_intersection = class.flags.internal;
    if (attrs.has(.@"edge.drive_on_right")) result.drive_on_left = node.attr.drive_on_left;
    if (attrs.has(.@"edge.destination_only")) result.destination_only = class.flags.destination_only;
    if (attrs.has(.@"edge.indoor")) result.indoor = class.flags.indoor;
    if (attrs.has(.@"edge.country_crossing")) result.country_crossing = class.flags.country_crossing;
    if (attrs.has(.@"edge.traffic_signal")) result.traffic_signal = class.flags.traffic_signal;
    if (attrs.has(.@"edge.curvature")) result.curvature = directed.geom.curvature;
    if (attrs.has(.@"edge.id")) result.id = @backingInt(edge.id);
    if (attrs.has(.@"edge.weighted_grade")) result.weighted_grade = (@as(f32, @floatFromInt(directed.geom.grade)) - 6) / 0.6;
    if (attrs.has(.@"edge.max_upward_grade") or attrs.has(.@"edge.max_downward_grade")) {
        const slopes = try view.edgeSlopeData(edge.id);
        if (attrs.has(.@"edge.max_upward_grade"))
            result.max_upward_grade = if (slopes) |s| s.maxUp() else graph.cold.no_elevation;
        if (attrs.has(.@"edge.max_downward_grade"))
            result.max_downward_grade = if (slopes) |s| s.maxDown() else graph.cold.no_elevation;
    }
    if (attrs.has(.@"edge.lane_count")) result.lane_count = class.category.lanes;
    if (attrs.has(.@"edge.cycle_lane")) result.cycle_lane = @fromBackingInt(class.category.cycle_lane);
    if (attrs.has(.@"edge.bicycle_network")) result.bicycle_network = class.onBikeNetwork();
    if (attrs.has(.@"edge.sac_scale")) result.sac_scale = @fromBackingInt(class.category.sac_scale);
    if (attrs.has(.@"edge.shoulder")) result.shoulder = class.flags.shoulder;
    if (attrs.has(.@"edge.sidewalk")) result.sidewalk = @fromBackingInt(
        @as(i32, @intFromBool(class.flags.sidewalk_left)) | (@as(i32, @intFromBool(class.flags.sidewalk_right)) << 1),
    );
    if (attrs.has(.@"edge.density")) result.density = class.category.density;
    if (attrs.has(.@"edge.is_urban")) result.is_urban = class.category.density > 8;
    if (attrs.has(.@"edge.default_speed")) result.default_speed = @floatFromInt(directed.speed[0]);
    if (attrs.has(.@"edge.speeds_non_faded")) result.speeds_non_faded = .{
        .no_flow = @floatFromInt(directed.speed[0]),
        .free_flow = @floatFromInt(directed.speed[1]),
        .constrained_flow = @floatFromInt(directed.speed[2]),
    };
    if (attrs.has(.@"edge.truck_speed")) result.truck_speed = @floatFromInt(directed.speed[3]);
    if (attrs.has(.@"edge.truck_route")) result.truck_route = class.flags.truck_route;
    if (attrs.has(.@"edge.speed_type")) result.speed_type = if (class.flags.tagged_speed) .kTagged else .kClassified;
    if (attrs.has(.@"edge.hov_type")) result.hov_type = if (class.flags.hov3) .kHOV3 else .kHOV2;

    const begin = try shapeIndex(edge.shape_begin);
    const end = try shapeIndex(edge.shape_end);
    if (attrs.has(.@"edge.begin_shape_index")) result.begin_shape_index = begin;
    if (attrs.has(.@"edge.end_shape_index")) result.end_shape_index = end;
    const heading_distance = graph.constants.headingOffset(class.category.road_class, class.category.use);
    if (attrs.has(.@"edge.begin_heading"))
        result.begin_heading = @intFromFloat(@round(try geo.point.headingAlongPolylineWithDeadline(input.geometry.shape, heading_distance, begin, end, control.deadline)));
    if (attrs.has(.@"edge.end_heading"))
        result.end_heading = @intFromFloat(@round(try geo.point.headingAtEndOfPolylineWithDeadline(input.geometry.shape, heading_distance, begin, end, control.deadline)));

    const mode: model.TravelMode = switch (input.travel) {
        .drive => |vehicle| blk: {
            if (attrs.has(.@"edge.vehicle_type")) result.vehicle_type = vehicle;
            break :blk .kDrive;
        },
        .pedestrian => |pedestrian| blk: {
            if (attrs.has(.@"edge.pedestrian_type")) result.pedestrian_type = pedestrian;
            break :blk .kPedestrian;
        },
        .bicycle => |bicycle| blk: {
            if (class.flags.dismount or class.category.use == @backingInt(graph.constants.Use.steps)) {
                if (attrs.has(.@"edge.pedestrian_type")) result.pedestrian_type = .kFoot;
                break :blk .kPedestrian;
            }
            if (attrs.has(.@"edge.bicycle_type")) result.bicycle_type = bicycle;
            break :blk .kBicycle;
        },
    };
    if (attrs.has(.@"edge.travel_mode")) result.travel_mode = mode;

    if (attrs.has(.@"edge.way_id") or attrs.has(.@"edge.forward") or attrs.has(.@"edge.traversability") or
        attrs.has(.@"edge.speed_limit") or attrs.has(.@"edge.mean_elevation") or attrs.has(.@"edge.names") or
        attrs.has(.@"edge.tagged_values") or attrs.has(.@"edge.levels"))
    {
        const record = try view.coldRecordWithDeadline(edge.id, control.deadline);
        if (attrs.has(.@"edge.way_id")) result.way_id = record.wayId();
        if (attrs.has(.@"edge.forward")) result.forward = !record.reverse;
        if (attrs.has(.@"edge.speed_limit")) result.speed_limit = record.speedLimit();
        if (attrs.has(.@"edge.mean_elevation")) result.mean_elevation = record.meanElevation();
        if (attrs.has(.@"edge.traversability")) {
            const forward = class.forwardAccess();
            const reverse = class.reverseAccess();
            const along = if (record.reverse) reverse else forward;
            const against = if (record.reverse) forward else reverse;
            result.traversability = switch (input.travel) {
                .drive => traversal(along.auto, against.auto),
                .pedestrian => traversal(along.pedestrian, against.pedestrian),
                .bicycle => traversal(along.bicycle, against.bicycle),
            };
        }
        if (attrs.has(.@"edge.names") or attrs.has(.@"edge.tagged_values") or attrs.has(.@"edge.levels"))
            try populateNamesAndLevels(a, view.cold_data.?, record, attrs, &result, control);
    }

    if (view.signs != null) {
        if (attrs.hasAny("edge.sign.")) {
            const rows = try graph.signs.signsForEdge(view, edge.id);
            const junctions = if (attrs.has(.@"edge.sign.junction_name")) try graph.signs.signsForNode(view, from) else &.{};
            result.sign = try projectSigns(a, view, rows, junctions, attrs, control);
            if (input.trace and rows.len + junctions.len != 0 and result.sign == null) result.sign = .{};
        } else if (input.trace and class.flags.sign and (try graph.signs.signsForEdge(view, edge.id)).len != 0) {
            result.sign = .{};
        }
    }
    if (class.flags.turnlanes) {
        const masks = try graph.lanes.turnLanes(view, edge.id);
        const turn_lanes = try a.alloc(model.TurnLane, masks.len);
        for (masks, turn_lanes, 0..) |mask, *lane, i| {
            if (i % 64 == 0) try control.check();
            lane.* = .{ .directions_mask = mask };
        }
        result.turn_lanes = turn_lanes;
    }
    if (attrs.has(.@"edge.lane_connectivity") and class.flags.lane_conn) {
        const connections = try graph.lanes.laneConnectivity(view, edge.id);
        const out = try a.alloc(model.LaneConnectivity, connections.len);
        for (connections, out, 0..) |connection, *lane, i| {
            if (i % 64 == 0) try control.check();
            lane.* = .{
                .from_way_id = connection.from_way,
                .from_lanes = try laneString(a, connection.from_lanes),
                .to_lanes = try laneString(a, connection.to_lanes),
            };
        }
        result.lane_connectivity = out;
    }
    return result;
}

fn traversal(along: bool, against: bool) model.Traversability {
    return @fromBackingInt(@as(i32, @intFromBool(along)) | (@as(i32, @intFromBool(against)) << 1));
}

fn streetName(name: graph.cold.Name) model.StreetName {
    const code = @backingInt(name.language);
    return .{
        .value = name.text,
        .is_route_number = name.route,
        .language_tag = if (code <= @backingInt(model.LanguageTag.kCy)) @fromBackingInt(code) else .kUnspecified,
        .pronunciation = if (name.pronunciation) |pronunciation|
            .{ .alphabet = @fromBackingInt(@backingInt(pronunciation.alphabet)), .value = pronunciation.text }
        else
            null,
    };
}

fn populateNamesAndLevels(a: std.mem.Allocator, table: graph.cold.View, record: graph.cold.Record, attrs: Attributes, out: *model.Edge, control: Control) !void {
    const include_names = attrs.has(.@"edge.names");
    const include_tagged = attrs.has(.@"edge.tagged_values");
    const include_levels = attrs.has(.@"edge.levels");
    const names = try record.names(table, .{ .include_tagged = true, .deadline = control.deadline });
    const ordinary = names.ordinaryCount();
    if (include_names) out.name = try projectStreetNames(a, names, control);

    var tunnels: std.ArrayList(model.StreetName) = .empty;
    var tags: std.ArrayList(model.TaggedValue) = .empty;
    var encoded_levels: ?graph.cold.EncodedLevels = null;
    for (ordinary..names.count()) |i| {
        try control.check();
        const tag = (try names.tagKind(i)).?;
        const named_structure = include_names and (tag == .tunnel or tag == .bridge);
        const read_levels = include_levels and tag == .levels and encoded_levels == null;
        if (!named_structure and !include_tagged and !read_levels) continue;
        const name = if (named_structure) try names.at(i) else try names.valueAt(i);
        if (named_structure) try tunnels.append(a, streetName(name));
        if (include_tagged) try tags.append(a, .{ .value = name.text, .type = @fromBackingInt(@backingInt(tag)) });
        if (read_levels) encoded_levels = try graph.cold.EncodedLevels.parse(name.text);
    }
    if (include_levels) {
        out.level_precision = 1;
        if (encoded_levels) |*encoded| {
            out.level_precision = @max(1, encoded.precision);
            var levels = try std.ArrayList(model.Level).initCapacity(a, record.indoor.levels.len);
            while (try encoded.next(control.deadline)) |range|
                try levels.append(a, .{ .start = range.bounds.first, .end = range.bounds.last });
            out.levels = levels.items;
        } else {
            const levels = try a.alloc(model.Level, record.indoor.levels.len);
            for (record.indoor.levels, levels, 0..) |range, *level, i| {
                if (i % 64 == 0) try control.check();
                level.* = .{ .start = range.bounds.first, .end = range.bounds.last };
            }
            out.levels = levels;
        }
    }
    out.tunnel_name = tunnels.items;
    std.sort.insertion(model.TaggedValue, tags.items, {}, taggedBefore);
    out.tagged_value = tags.items;
}

fn taggedBefore(_: void, a: model.TaggedValue, b: model.TaggedValue) bool {
    return @backingInt(a.type) < @backingInt(b.type);
}

fn projectStreetNames(a: std.mem.Allocator, names: graph.cold.Names, control: Control) ![]const model.StreetName {
    const out = try a.alloc(model.StreetName, names.ordinaryCount());
    for (out, 0..) |*name, i| {
        if (i % 64 == 0) try control.check();
        name.* = streetName(try names.at(i));
    }
    return out;
}

const sign_groups = .{
    .{ .exit_number, "exit_numbers", .@"edge.sign.exit_number" },
    .{ .exit_branch, "exit_onto_streets", .@"edge.sign.exit_branch" },
    .{ .exit_toward, "exit_toward_locations", .@"edge.sign.exit_toward" },
    .{ .exit_name, "exit_names", .@"edge.sign.exit_name" },
    .{ .guide_branch, "guide_onto_streets", .@"edge.sign.guide_branch" },
    .{ .guide_toward, "guide_toward_locations", .@"edge.sign.guide_toward" },
    .{ .junction_name, "junction_names", .@"edge.sign.junction_name" },
    .{ .guidance_view_junction, "guidance_view_junctions", .@"edge.sign.guidance_view_junction" },
    .{ .guidance_view_signboard, "guidance_view_signboards", .@"edge.sign.guidance_view_signboard" },
};

fn projectSigns(a: std.mem.Allocator, view: *const View, rows: []const graph.signs.Entry, junctions: []const graph.signs.Entry, attrs: Attributes, control: Control) !?model.Sign {
    if (rows.len == 0 and junctions.len == 0) return null;
    const table = view.cold_data orelse return error.MissingColdData;
    const storage = try a.alloc(model.SignElement, rows.len + junctions.len);
    var sign: model.Sign = .{};
    var written: usize = 0;
    inline for (sign_groups) |group| {
        const kind: graph.signs.Type = group[0];
        if (attrs.has(group[2])) {
            const start = written;
            const source = if (kind == .junction_name) junctions else rows;
            for (source, 0..) |row, i| {
                if (i % 64 == 0) try control.check();
                if (row.attr.sign_type != kind) continue;
                storage[written] = .{ .text = try row.text(table), .is_route_number = row.attr.route_number };
                written += 1;
            }
            @field(sign, group[1]) = storage[start..written];
        }
    }
    return if (written == 0) null else sign;
}

fn laneString(a: std.mem.Allocator, mask: u64) ![]const u8 {
    const max = graph.lanes.Connection.max_lanes;
    var text: [3 * max]u8 = undefined;
    var len: usize = 0;
    for (0..max) |i| {
        const lane = graph.lanes.Connection.lane(mask, @intCast(i));
        if (lane == 0) continue;
        if (len != 0) {
            text[len] = '|';
            len += 1;
        }
        if (lane >= 10) {
            text[len] = '1';
            len += 1;
        }
        text[len] = '0' + @as(u8, lane % 10);
        len += 1;
    }
    return a.dupe(u8, text[0..len]);
}

fn intersections(a: std.mem.Allocator, view: *const View, from: format.NodeId, current: format.EdgeId, directed: *const format.EdgeHot, previous: ?format.EdgeId, trace: bool, attrs: Attributes, control: Control) ![]const model.IntersectingEdge {
    const incoming = if (previous) |id| try view.edge(id) else null;
    const previous_opp = if (previous) |id| try view.oppEdge(id) else null;
    // A trace gap changes the start node, but Valhalla's intersection
    // enumeration still excludes the prior opposing local index.
    const prior_local = if (trace and incoming != null) incoming.?.cls.opp_local else null;
    const want_previous = attrs.has(.@"node.intersecting_edge.from_edge_name_consistency");
    const want_current = attrs.has(.@"node.intersecting_edge.to_edge_name_consistency");

    // Contiguous aliases describe one physical intersection.
    var node_id = @backingInt(from);
    while (try view.aliasNeighbor(node_id, false)) |alias| {
        try control.check();
        node_id = alias;
    }
    var out: std.ArrayList(model.IntersectingEdge) = .empty;
    while (true) {
        try control.check();
        const node: format.NodeId = @fromBackingInt(node_id);
        const previous_row = if (want_previous and incoming != null and incoming.?.head == node_id)
            try view.turnRow(node, incoming.?.cls.opp_local)
        else
            null;
        const current_row = if (want_current and node == from) try view.turnRow(node, directed.cls.local) else null;
        const range = try view.outEdgeRange(node);
        for (range.first..range.end) |slot| {
            const id: format.EdgeId = @fromBackingInt(@as(u32, @intCast(slot)));
            if (id == current or id == previous_opp) continue;
            const edge = try view.edge(id);
            if (node == from and prior_local == edge.cls.local) continue;
            const class = try view.class(edge.cls.class_id);
            if (class.flags.node_connector or class.category.use == @backingInt(graph.constants.Use.construction)) continue;
            const forward = class.forwardAccess();
            const reverse = class.reverseAccess();
            var value: model.IntersectingEdge = .{};
            if (attrs.has(.@"node.intersecting_edge.begin_heading")) {
                if (view.headings) |codes| {
                    value.begin_heading = graph.headings.decode(codes[slot]);
                } else {
                    const shape = try view.shapeWithDeadline(id, a, control.deadline);
                    defer a.free(shape);
                    const bearing = try graph.headings.sample(shape, true, class, control.deadline);
                    value.begin_heading = graph.headings.decode(graph.headings.encode(bearing));
                }
            }
            if (attrs.has(.@"node.intersecting_edge.driveability")) value.driveability = traversal(forward.auto, reverse.auto);
            if (attrs.has(.@"node.intersecting_edge.cyclability")) value.cyclability = traversal(forward.bicycle, reverse.bicycle);
            if (attrs.has(.@"node.intersecting_edge.walkability")) value.walkability = traversal(forward.pedestrian, reverse.pedestrian);
            if (attrs.has(.@"node.intersecting_edge.use"))
                value.use = std.enums.fromInt(model.Use, class.category.use) orelse .kOtherUse;
            if (attrs.has(.@"node.intersecting_edge.road_class")) value.road_class = @fromBackingInt(class.category.road_class);
            if (attrs.has(.@"node.intersecting_edge.lane_count")) value.lane_count = class.category.lanes;
            if (attrs.has(.@"node.intersecting_edge.sign_info") and attrs.hasAny("edge.sign.") and class.flags.sign) {
                const rows = try graph.signs.signsForEdge(view, id);
                value.sign = try projectSigns(a, view, rows, &.{}, attrs, control);
            }
            if (attrs.has(.@"edge.names")) {
                const names = try view.namesWithOptions(id, .{ .deadline = control.deadline });
                value.name = try projectStreetNames(a, names, control);
            }
            if (want_previous and previous_opp != null) {
                value.prev_name_consistency = if (previous_row) |row|
                    try nameFlag(row, edge.cls.local)
                else if (trace and node == from) blk: {
                    const row = try view.turnRow(@fromBackingInt(incoming.?.head), incoming.?.cls.opp_local);
                    break :blk edge.cls.local < row.len and try nameFlag(row, edge.cls.local);
                } else try sameEdgeName(view, previous_opp.?, id, control);
            }
            if (want_current) {
                value.curr_name_consistency = if (current_row) |row|
                    try nameFlag(row, edge.cls.local)
                else
                    try sameEdgeName(view, current, id, control);
            }
            try out.append(a, value);
        }
        node_id = (try view.aliasNeighbor(node_id, true)) orelse break;
    }
    return out.items;
}

fn nameFlag(row: []const format.TurnEntry, index: u5) !bool {
    if (index >= row.len) return error.InvalidLocalEdge;
    return row[index] & 0x40 != 0;
}

fn sameEdgeName(view: *const View, left: format.EdgeId, right: format.EdgeId, control: Control) !bool {
    const lhs = try view.namesWithOptions(left, .{ .deadline = control.deadline });
    const rhs = try view.namesWithOptions(right, .{ .deadline = control.deadline });
    if (lhs.count() == 0 or rhs.count() == 0) return lhs.count() == rhs.count();
    for (0..lhs.count()) |i| {
        try control.check();
        const name = try lhs.at(i);
        for (0..rhs.count()) |j| {
            if (j % 64 == 0) try control.check();
            if (std.mem.eql(u8, name.text, (try rhs.at(j)).text)) return true;
        }
    }
    return false;
}
