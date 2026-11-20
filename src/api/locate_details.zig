// Ported from src/tyr/locate_serializer.cc and the Baldr JSON writers
// (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const geo = @import("../geo/root.zig");
const snap = @import("../snap/search.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Writer = @import("json_writer.zig").Writer;
const View = graph.reader.View;
const NodeId = graph.format.NodeId;
const EdgeHot = graph.format.EdgeHot;
const EdgeClass = graph.class_table.EdgeClass;
const AccessMask = graph.constants.AccessMask;

pub fn writeEdge(w: *Writer, view: *const View, hit: snap.PathEdge, record: graph.cold.Record, deadline: Deadline) !void {
    const edge = try view.edge(hit.id);
    const class = try view.class(edge.cls.class_id);
    const fixed = try record.shape(w.gpa, deadline);
    if (fixed.len < 2) return error.IncompleteShape;
    const shape = try w.gpa.alloc(geo.PointLL, fixed.len);
    var bounds = geo.AABB.fromPoints(fixed[0].toTilePoint(), fixed[0].toTilePoint());
    for (fixed, shape, 0..) |vertex, *point, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        point.* = vertex.toTilePoint();
        _ = bounds.expandPoint(point.*);
    }
    const id = @backingInt(hit.id);
    try writeRestrictions(w, record, id, deadline);
    try w.beginObjectField("live_speed");
    try w.endObject();
    try writeCircle(w, shape, bounds.center(), deadline);
    var reference: [graph.openlr.max_encoded_bytes]u8 = undefined;
    try w.field("linear_reference", try graph.openlr.pointAlongEdge(&reference, shape, class.*, edge.geom.len_m, hit.percent_along, deadline));
    w.setPrecision(1);
    try w.field("distance", hit.distance);
    try w.field("shoulder", class.flags.shoulder);
    try w.field("heading", @as(f64, hit.heading));
    w.setPrecision(3);
    try w.field("outbound_reach", hit.reach.outbound);
    try w.field("inbound_reach", hit.reach.inbound);
    try writeEdgeInfo(w, view, record, class, shape, deadline);
    try writeAttributes(w, edge, class, try view.edgeSlopes(hit.id), !record.reverse);
    try writeId(w, "edge_id", id);
    try w.beginArrayField("predicted_speeds");
    try w.endArray();
}

pub fn writeNode(w: *Writer, view: *const View, id: NodeId) !void {
    const node = try view.node(id);
    const edges = try view.outEdgeRange(id);
    const node_type = std.enums.fromInt(graph.constants.NodeType, node.attr.type);
    w.setPrecision(2);
    try w.field("elevation", @as(f64, graph.cold.no_elevation));
    w.setPrecision(3);
    try w.field("edge_count", edges.count());
    try w.beginObjectField("access");
    try writeAccess(w, @bitCast(node.attr.access), .node);
    try w.endObject();
    try w.field("tagged_access", node.attr.tagged_access);
    try w.field("intersection_type", switch (node.attr.intersection) {
        .false_intersection => "false",
        .dead_end => "dead-end",
        else => @tagName(node.attr.intersection),
    });
    const admin = try view.nodeAdmin(id);
    try w.beginObjectField("administrative");
    try w.field("iso_3166-1", admin.country_iso);
    try w.field("country", if (admin.country.len != 0) admin.country else "None");
    try w.field("iso_3166-2", admin.state_iso);
    try w.field("state", if (admin.state.len != 0) admin.state else "None");
    if (view.tz_rules) |zones| {
        if (try zones.name(try view.nodeTimezone(id))) |name| try w.field("time_zone_name", name);
    }
    try w.endObject();
    try w.field("density", node.attr.density);
    try w.field("local_edge_count", edges.count());
    try w.field("drive_on_right", !node.attr.drive_on_left);
    try w.field("mode_change", node_type == .bike_share);
    try w.field("private_access", node.attr.private_access);
    try w.field("traffic_signal", node.attr.signal != 0);
    try w.field("type", if (node_type) |kind| if (kind == .motorway_junction) "motor_way_junction" else @tagName(kind) else "null");
    try w.field("transition_count", 0);
    try w.field("named_intersection", false);
    try writeId(w, "node_id", @backingInt(id));
}

fn writeId(w: *Writer, comptime name: []const u8, id: u32) !void {
    try w.beginObjectField(name);
    try w.field("level", 0);
    try w.field("tile_id", 0);
    try w.field("id", id);
    try w.field("value", id);
    try w.endObject();
}

const AccessScope = enum { edge, node, restriction };
fn writeAccess(w: *Writer, mask: AccessMask, scope: AccessScope) !void {
    if (scope != .restriction) try w.field("bicycle", mask.bicycle);
    try w.field("bus", mask.bus);
    try w.field("car", mask.auto);
    try w.field("emergency", mask.emergency);
    try w.field("HOV", mask.hov);
    try w.field("pedestrian", mask.pedestrian);
    try w.field("taxi", mask.taxi);
    try w.field("truck", mask.truck);
    try w.field("wheelchair", mask.wheelchair);
    if (scope != .node) {
        try w.field("moped", mask.moped);
        try w.field("motorcycle", mask.motorcycle);
    }
}

fn writeCircle(w: *Writer, shape: []const geo.PointLL, center: geo.PointLL, deadline: Deadline) !void {
    var radius: f64 = 0;
    for (shape, 0..) |point, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        radius = @max(radius, center.distance(point));
    }
    try w.beginObjectField("bounding_circle");
    w.setPrecision(6);
    try w.field("lat", center.lat);
    try w.field("lon", center.lng);
    try w.field("radius", @as(u64, @intFromFloat(@ceil(radius))));
    w.setPrecision(3);
    try w.endObject();
}

fn writeEdgeInfo(w: *Writer, view: *const View, record: graph.cold.Record, class: *const EdgeClass, shape: []geo.PointLL, deadline: Deadline) !void {
    try w.beginObjectField("edge_info");
    try w.field("way_id", record.wayId());
    const bike: graph.constants.BikeNetwork = @bitCast(@as(u8, class.category.bike_network));
    try w.beginObjectField("bike_network");
    try w.field("national", bike.ncn);
    try w.field("regional", bike.rcn);
    try w.field("local", bike.lcn);
    try w.field("mountain", bike.mtb);
    try w.endObject();
    const names = try record.names(view.cold_data.?, .{ .deadline = deadline });
    try w.beginArrayField("names");
    for (0..names.count()) |i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        try w.string((try names.valueAt(i)).text);
    }
    try w.endArray();
    // EdgeInfo always returns the stored shape. The OpenLR and correlation
    // fields already consumed the travel-order shape.
    if (record.reverse) {
        for (shape[0 .. shape.len / 2], 0..) |point, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            shape[i] = shape[shape.len - 1 - i];
            shape[shape.len - 1 - i] = point;
        }
    }
    const encoded = try w.gpa.alloc(u8, geo.polyline.maxEncodedLen(.polyline, shape.len));
    const bytes = try geo.polyline.encodeWithDeadline(.polyline, 6, shape, encoded, deadline);
    try w.field("shape", encoded[0..bytes]);
    const elevation = record.meanElevation();
    try w.field("mean_elevation", if (elevation == graph.cold.no_elevation) @as(?i16, null) else elevation);
    const limit = record.speedLimit();
    if (limit == graph.constants.unlimited_speed_limit) try w.field("speed_limit", "unlimited") else try w.field("speed_limit", limit);
    if (record.indoor.levels.len != 0) {
        try w.beginArrayField("levels");
        for (record.indoor.levels) |range| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const first = range.bounds.first;
            const last = range.bounds.last;
            if (first != last) try w.beginArray();
            try w.float(first);
            if (first != last) {
                try w.float(last);
                try w.endArray();
            }
        }
        try w.endArray();
    }
    try w.endObject();
}

fn writeAttributes(w: *Writer, edge: *const EdgeHot, class: *const EdgeClass, slopes: graph.format.Slopes, forward: bool) !void {
    try w.beginObjectField("edge");
    try writeId(w, "end_node", edge.head);
    try w.beginObjectField("speeds");
    try w.field("default", edge.speed[0]);
    try w.field("type", if (class.flags.tagged_speed) "tagged" else "classified");
    try w.field("free_flow", edge.speed[1]);
    try w.field("constrained_flow", edge.speed[2]);
    try w.field("predicted", edge.cls.pred_speed != 0);
    try w.endObject();
    try w.field("access_restriction", class.detail.access_restriction != 0);
    try w.beginObjectField("start_restriction");
    try writeAccess(w, @bitCast(class.restrictions.start), .edge);
    try w.endObject();
    try w.beginObjectField("end_restriction");
    try writeAccess(w, @bitCast(class.restrictions.end), .edge);
    try w.endObject();
    const flags = class.flags;
    try w.field("part_of_complex_restriction", flags.complex_restriction);
    try w.field("has_sign", flags.sign);
    try w.field("toll", flags.toll);
    try w.field("destination_only", flags.destination_only);
    try w.field("destination_only_hgv", flags.destination_only_hgv);
    try w.field("tunnel", flags.tunnel);
    try w.field("bridge", flags.bridge);
    try w.field("round_about", flags.roundabout);
    try w.field("traffic_signal", flags.traffic_signal);
    try w.field("forward", forward);
    try w.field("not_thru", flags.not_thru);
    try w.field("stop_sign", flags.stop_sign);
    try w.field("yield_sign", flags.yield_sign);
    try w.field("cycle_lane", @tagName(@as(graph.constants.CycleLane, @fromBackingInt(@intCast(class.category.cycle_lane)))));
    try w.field("bike_network", class.onBikeNetwork());
    try w.field("truck_route", flags.truck_route);
    try w.field("lane_count", class.category.lanes);
    try w.field("country_crossing", flags.country_crossing);
    try w.field("sidewalk_left", flags.sidewalk_left);
    try w.field("sidewalk_right", flags.sidewalk_right);
    try w.field("sac_scale", @tagName(@as(graph.constants.SacScale, @fromBackingInt(@intCast(class.category.sac_scale)))));
    try w.field("deadend", flags.dead_end);
    try w.beginObjectField("geo_attributes");
    try w.field("length", edge.geom.len_m);
    w.setPrecision(2);
    try w.field("weighted_grade", (@as(f64, @floatFromInt(edge.geom.grade)) - 6) / 0.6);
    try w.field("max_up_slope", @as(f64, @floatFromInt(slopes.maxUp())));
    try w.field("max_down_slope", @as(f64, @floatFromInt(slopes.maxDown())));
    w.setPrecision(3);
    try w.field("curvature", edge.geom.curvature);
    try w.endObject();
    try w.beginObjectField("access");
    try writeAccess(w, class.forwardAccess(), .edge);
    try w.endObject();
    try w.beginObjectField("classification");
    try w.field("classification", @tagName(@as(graph.constants.RoadClass, @fromBackingInt(@intCast(class.category.road_class)))));
    const use: graph.constants.Use = @fromBackingInt(@intCast(class.category.use));
    try w.field("use", if (use == .rail_ferry) "rail-ferry" else @tagName(use));
    try w.field("surface", @tagName(@as(graph.constants.Surface, @fromBackingInt(@intCast(class.category.surface)))));
    try w.field("link", flags.link);
    try w.field("internal", flags.internal);
    try w.endObject();
    if (class.isHovOnly()) try w.field("hov_type", if (flags.hov3) "HOV-3" else "HOV-2");
    try w.endObject();
}

fn writeRestrictions(w: *Writer, record: graph.cold.Record, id: u32, deadline: Deadline) !void {
    try w.beginArrayField("access_restrictions");
    var restrictions = record.restrictions();
    while (restrictions.next()) |entry| {
        if (deadline.expired()) return error.DeadlineExceeded;
        try w.beginObject();
        try w.field("type", switch (entry.attr.kind) {
            .hazmat => "hazmat",
            .maxheight => "max_height",
            .maxwidth => "max_width",
            .maxlength => "max_length",
            .maxweight => "max_weight",
            .maxaxleload => "max_axle_load",
            .timed_allowed => "timed_allowed",
            .timed_denied => "timed_denied",
            .destination_allowed => "destination_allowed",
            .maxaxles => "max_axles",
            else => "unsupported",
        });
        try w.field("edge_index", id);
        try writeAccess(w, @bitCast(entry.modes()), .restriction);
        try w.field("except_destination", entry.attr.except_destination);
        switch (entry.attr.kind) {
            .timed_allowed, .timed_denied, .destination_allowed => {
                try w.beginObjectField("value");
                try w.field("time_domain", entry.value);
                try w.endObject();
            },
            .maxaxles => try w.field("value", entry.value),
            .hazmat => try w.field("value", entry.value != 0),
            else => {
                w.setPrecision(2);
                try w.field("value", @as(f64, @floatFromInt(entry.value)) * 0.01);
                w.setPrecision(3);
            },
        }
        try w.endObject();
    }
    try w.endArray();
}
