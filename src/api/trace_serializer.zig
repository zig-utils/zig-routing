// Ported from src/tyr/trace_serializer.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Writer = @import("json_writer.zig").Writer;
const Attributes = @import("attributes.zig").Controller;
const Warning = @import("proto/info.zig").CodedDescription.Values;
const request = @import("request.zig");
const model = @import("trip.zig");

const Encoder = struct {
    writer: Writer,
    attrs: Attributes,
    options: *const request.Options,
    deadline: Deadline,

    fn check(self: *const Encoder) error{DeadlineExceeded}!void {
        if (self.deadline.expired()) return error.DeadlineExceeded;
    }

    fn path(self: *Encoder, route: model.TripRoute) !void {
        const w = &self.writer;
        const leg = route.legs[0];
        const attrs = self.attrs;
        if (attrs.has(.osm_changeset)) try w.field("osm_changeset", leg.osm_changeset);
        if (attrs.has(.shape)) try w.field("shape", leg.shape);
        w.setPrecision(3);
        if (attrs.has(.confidence_score)) try w.field("confidence_score", route.confidence_score);
        if (attrs.has(.raw_score)) try w.field("raw_score", route.raw_score);
        if (leg.admin.len != 0) {
            try w.beginArrayField("admins");
            for (leg.admin) |admin| {
                try self.check();
                try w.beginObject();
                inline for (comptime std.meta.fieldNames(model.Admin)) |name| {
                    const value = @field(admin, name);
                    if (value.len != 0) try w.field(name, value);
                }
                try w.endObject();
            }
            try w.endArray();
        }
        try w.beginArrayField("edges");
        for (leg.node[0 .. leg.node.len - 1], leg.node[1..]) |start, end| {
            try self.check();
            if (start.edge) |arc| try self.edge(arc, end);
        }
        try w.endArray();
        if (attrs.hasAny("matched.") and route.matched_points.len != 0) try self.matched(route.matched_points);
        if (attrs.hasAny("shape_attributes.")) try self.shapeAttributes(leg);
    }

    fn edge(self: *Encoder, e: model.Edge, end: model.Node) !void {
        const w = &self.writer;
        const attrs = self.attrs;
        const scale: f64 = if (self.options.units == .miles) @as(f32, 0.621371) else 1;
        w.setPrecision(3);
        try w.beginObject();
        inline for (.{
            "truck_route",           "density",         "shoulder",          "lane_count",  "max_downward_grade",
            "max_upward_grade",      "weighted_grade",  "way_id",            "id",          "curvature",
            "internal_intersection", "roundabout",      "bridge",            "tunnel",      "unpaved",
            "toll",                  "end_shape_index", "begin_shape_index", "end_heading", "begin_heading",
            "country_crossing",      "forward",         "traffic_signal",
        }) |name| {
            if (attrs.has(@field(@import("attributes.zig").Key, "edge." ++ name))) try w.field(name, @field(e, name));
        }
        if (attrs.has(.@"edge.speed")) try w.field("speed", scaledSpeed(e.speed, scale));
        if (attrs.has(.@"edge.truck_speed") and e.truck_speed > 0) try w.field("truck_speed", scaledSpeed(e.truck_speed, scale));
        if (attrs.has(.@"edge.speed_limit") and e.speed_limit > 0) {
            if (e.speed_limit == graph.constants.unlimited_speed_limit)
                try w.field("speed_limit", "unlimited")
            else
                try w.field("speed_limit", scaledSpeed(@floatFromInt(e.speed_limit), scale));
        }
        if (attrs.has(.@"edge.sac_scale")) try w.field("sac_scale", @backingInt(e.sac_scale));
        if (attrs.has(.@"edge.sidewalk")) try w.field("sidewalk", enumName(e.sidewalk, &.{ "none", "left", "right", "both" }));
        if (attrs.has(.@"edge.bicycle_network")) try w.field("bicycle_network", @intFromBool(e.bicycle_network));
        if (attrs.has(.@"edge.cycle_lane")) try w.field("cycle_lane", enumName(e.cycle_lane, &.{ "none", "shared", "dedicated", "separated" }));
        if (attrs.has(.@"edge.mean_elevation") and e.mean_elevation != graph.cold.no_elevation) {
            const mean: f32 = @floatFromInt(e.mean_elevation);
            try w.field("mean_elevation", if (scale == 1) e.mean_elevation else @as(i64, @intFromFloat(mean * 3.2808399)));
        }
        if (attrs.has(.@"edge.begin_osm_node_id")) if (e.begin_osm_node_id) |node_id| try w.field("node_id", node_id);
        if (attrs.has(.@"edge.travel_mode")) try w.field("travel_mode", enumName(e.travel_mode, &.{ "drive", "pedestrian", "bicycle", "transit" }));
        if (attrs.has(.@"edge.vehicle_type") and e.travel_mode == .kDrive)
            try w.field("vehicle_type", enumName(e.vehicle_type, &.{ "car", "motorcycle", "bus", "truck" }));
        if (attrs.has(.@"edge.pedestrian_type") and e.travel_mode == .kPedestrian)
            try w.field("pedestrian_type", enumName(e.pedestrian_type, &.{ "foot", "wheelchair" }));
        if (attrs.has(.@"edge.bicycle_type") and e.travel_mode == .kBicycle)
            try w.field("bicycle_type", enumName(e.bicycle_type, &.{ "road", "cross", "hybrid", "mountain" }));
        if (attrs.has(.@"edge.surface")) try w.field("surface", graphName(graph.constants.Surface, e.surface));
        if (attrs.has(.@"edge.drive_on_right")) try w.field("drive_on_right", !e.drive_on_left);
        if (attrs.has(.@"edge.use")) try w.field("use", useName(e.use));
        if (attrs.has(.@"edge.traversability")) try w.field("traversability", traversability(e.traversability));
        if (attrs.has(.@"edge.road_class")) try w.field("road_class", graphName(graph.constants.RoadClass, e.road_class));
        if (attrs.has(.@"edge.speed_type")) try w.field("speed_type", graphName(graph.constants.SpeedType, e.speed_type));
        if (attrs.has(.@"edge.speeds_faded") and self.options.date_time_type == .current)
            if (e.speeds_faded) |s| try self.speeds("speeds_faded", s, scale);
        if (attrs.has(.@"edge.speeds_non_faded")) try self.speeds("speeds_non_faded", e.speeds_non_faded orelse .{}, scale);
        if (attrs.has(.@"edge.hov_type")) try w.field("hov_type", enumName(e.hov_type, &.{ "HOV-2", "HOV-3" }));
        if (attrs.has(.@"edge.levels") and e.levels.len != 0) {
            try w.beginArrayField("levels");
            w.setPrecision(@intCast(@min(e.level_precision, 15)));
            for (e.levels) |level| {
                try self.check();
                try w.beginArray();
                try w.float(level.start);
                try w.float(level.end);
                try w.endArray();
            }
            try w.endArray();
            w.setPrecision(3);
        }
        if (attrs.has(.@"edge.length")) {
            try w.field("length", @as(f64, e.length_km) * scale);
            if (e.source_along_edge != 0) try w.field("source_percent_along", e.source_along_edge);
            if (e.target_along_edge != 1) try w.field("target_percent_along", e.target_along_edge);
        }
        if (e.name.len != 0) {
            try w.beginArrayField("names");
            for (e.name) |name| {
                try self.check();
                try w.string(name.value);
            }
            try w.endArray();
        }
        if (e.lane_connectivity.len != 0) {
            try w.beginArrayField("lane_connectivity");
            for (e.lane_connectivity) |lane| {
                try self.check();
                try w.beginObject();
                try w.field("from", lane.from_way_id);
                try w.field("to_lanes", lane.to_lanes);
                try w.field("from_lanes", lane.from_lanes);
                try w.endObject();
            }
            try w.endArray();
        }
        if (e.traffic_segment.len != 0) {
            try w.beginArrayField("traffic_segments");
            for (e.traffic_segment) |segment| {
                try self.check();
                try w.beginObject();
                inline for (.{ "segment_id", "begin_percent", "end_percent", "starts_segment", "ends_segment" }) |name|
                    try w.field(name, @field(segment, name));
                try w.endObject();
            }
            try w.endArray();
        }
        if (e.sign) |sign| {
            try w.beginObjectField("sign");
            try self.signs("exit_number", sign.exit_numbers);
            try self.signs("exit_branch", sign.exit_onto_streets);
            try self.signs("exit_toward", sign.exit_toward_locations);
            try self.signs("exit_name", sign.exit_names);
            try w.endObject();
        }
        if (attrs.hasAny("node.")) try self.node(end, e.end_osm_node_id);
        try w.endObject();
    }

    fn signs(self: *Encoder, name: []const u8, values: []const model.SignElement) !void {
        if (values.len == 0) return;
        try self.writer.beginArrayField(name);
        for (values) |sign| {
            try self.check();
            try self.writer.string(sign.text);
        }
        try self.writer.endArray();
    }

    fn speeds(self: *Encoder, name: []const u8, values: model.Speeds, scale: f64) !void {
        try self.writer.beginObjectField(name);
        inline for (.{ "current_flow", "predicted_flow", "constrained_flow", "free_flow" }) |source| {
            const speed = @field(values, source);
            if (speed != 0) try self.writer.field(source, scaledSpeed(speed, scale));
        }
        try self.writer.field("no_flow", scaledSpeed(values.no_flow, scale));
        try self.writer.endObject();
    }

    fn node(self: *Encoder, n: model.Node, osm_id: ?u64) !void {
        const w = &self.writer;
        const attrs = self.attrs;
        try w.beginObjectField("end_node");
        if (n.intersecting_edge.len != 0) {
            try w.beginArrayField("intersecting_edges");
            for (n.intersecting_edge) |e| {
                try self.check();
                try w.beginObject();
                inline for (.{ "walkability", "cyclability", "driveability" }) |name| {
                    const value = @field(e, name);
                    if (value != .kNone and attrs.has(@field(@import("attributes.zig").Key, "node.intersecting_edge." ++ name)))
                        try w.field(name, traversability(value));
                }
                if (attrs.has(.@"node.intersecting_edge.from_edge_name_consistency")) try w.field("from_edge_name_consistency", e.prev_name_consistency);
                if (attrs.has(.@"node.intersecting_edge.to_edge_name_consistency")) try w.field("to_edge_name_consistency", e.curr_name_consistency);
                if (attrs.has(.@"node.intersecting_edge.begin_heading")) try w.field("begin_heading", e.begin_heading);
                if (attrs.has(.@"node.intersecting_edge.use")) try w.field("use", useName(e.use));
                if (attrs.has(.@"node.intersecting_edge.road_class")) try w.field("road_class", graphName(graph.constants.RoadClass, e.road_class));
                try w.endObject();
            }
            try w.endArray();
        }
        const cost = n.cost orelse model.PathCost{};
        if (attrs.has(.@"node.elapsed_time")) {
            const elapsed = cost.elapsed_cost orelse model.Cost{};
            try w.field("elapsed_time", elapsed.seconds);
            try w.field("elapsed_cost", elapsed.cost);
        }
        if (attrs.has(.@"edge.end_osm_node_id")) if (osm_id) |id| try w.field("node_id", id);
        if (attrs.has(.@"node.admin_index")) try w.field("admin_index", n.admin_index);
        if (attrs.has(.@"node.type")) try w.field("type", nodeName(n.type));
        if (attrs.has(.@"node.traffic_signal")) try w.field("traffic_signal", n.traffic_signal);
        if (attrs.has(.@"node.fork")) try w.field("fork", n.fork);
        if (attrs.has(.@"node.time_zone") and n.time_zone.len != 0) try w.field("time_zone", n.time_zone);
        if (attrs.has(.@"node.transition_time")) try w.field("transition_time", (cost.transition_cost orelse model.Cost{}).seconds);
        if (attrs.has(.@"node.stop_impact")) if (n.stop_impact) |impact| try w.field("stop_impact", impact);
        try w.endObject();
    }

    fn matched(self: *Encoder, points: []const model.MatchedPoint) !void {
        const w = &self.writer;
        const attrs = self.attrs;
        w.setPrecision(6);
        try w.beginArrayField("matched_points");
        for (points) |point| {
            try self.check();
            try w.beginObject();
            if (point.latlng) |ll| {
                try w.field("lon", ll.lng orelse 0);
                try w.field("lat", ll.lat orelse 0);
            }
            if (attrs.has(.@"matched.type")) try w.field("type", switch (point.type) {
                .kMatched => "matched",
                .kInterpolated => "interpolated",
                else => "unmatched",
            });
            if (point.edge_index) |index| try w.field("edge_index", if (index == std.math.maxInt(u32)) std.math.maxInt(u64) else @as(u64, index));
            if (point.begins_discontinuity) try w.field("begin_route_discontinuity", true);
            if (point.ends_discontinuity) try w.field("end_route_discontinuity", true);
            if (point.distance_along_edge) |value| try w.field("distance_along_edge", value);
            if (point.distance_from_trace_point) |value| try w.field("distance_from_trace_point", value);
            try w.endObject();
        }
        try w.endArray();
    }

    fn shapeAttributes(self: *Encoder, leg: model.TripLeg) !void {
        const w = &self.writer;
        const attrs = self.attrs;
        const values = leg.shape_attributes orelse model.ShapeAttributes{};
        try w.beginObjectField("shape_attributes");
        w.setPrecision(3);
        inline for (.{ "time", "length", "speed", "congestion", "speed_limit" }, .{ 0.001, 0.0001, 0.36, 1, 1 }) |name, scale| {
            if (attrs.has(@field(@import("attributes.zig").Key, "shape_attributes." ++ name))) {
                try w.beginArrayField(name);
                for (@field(values, name), 0..) |value, index| {
                    if (index % 256 == 0) try self.check();
                    if (scale == 1) try w.uint(value) else try w.float(@as(f64, @floatFromInt(value)) * scale);
                }
                try w.endArray();
            }
        }
        if (attrs.has(.@"shape_attributes.closure")) {
            try w.beginArrayField("closure");
            for (leg.closures) |closure| {
                try self.check();
                try w.beginObject();
                try w.field("begin_shape_index", closure.begin_shape_index orelse 0);
                try w.field("end_shape_index", closure.end_shape_index orelse 0);
                try w.endObject();
            }
            try w.endArray();
        }
        try w.endObject();
    }
};

pub fn json(a: std.mem.Allocator, out: *std.ArrayList(u8), trip: model.Trip, options: *const request.Options, attrs: Attributes, warnings: []const Warning, deadline: Deadline) !void {
    var enc: Encoder = .{ .writer = .init(a, out), .options = options, .attrs = attrs, .deadline = deadline };
    const w = &enc.writer;
    try w.beginObject();
    if (options.id) |id| if (id.len != 0) try w.field("id", id);
    try w.field("units", @tagName(options.units));
    try enc.path(trip.routes[0]);
    try w.beginArrayField("alternate_paths");
    for (trip.routes[1..]) |route| {
        try w.beginObject();
        try enc.path(route);
        try w.endObject();
    }
    try w.endArray();
    if (warnings.len != 0) {
        try w.beginArrayField("warnings");
        for (warnings) |warning| {
            try enc.check();
            try w.beginObject();
            try w.field("code", warning.code);
            try w.field("text", warning.description);
            try w.endObject();
        }
        try w.endArray();
    }
    try w.endObject();
}

fn scaledSpeed(speed: f32, scale: f64) u64 {
    return @intFromFloat(@round(@as(f64, speed) * scale));
}

fn enumName(value: anytype, names: []const []const u8) []const u8 {
    const index = std.math.cast(usize, @backingInt(value)) orelse return "null";
    return if (index < names.len) names[index] else "null";
}

fn graphName(comptime T: type, value: anytype) []const u8 {
    const enum_value = std.enums.fromInt(T, @backingInt(value)) orelse return "null";
    return @tagName(enum_value);
}

fn traversability(value: model.Traversability) []const u8 {
    return enumName(value, &.{ "none", "forward", "backward", "both" });
}

fn useName(value: model.Use) []const u8 {
    return if (@backingInt(value) == @backingInt(graph.constants.Use.rail_ferry)) "rail-ferry" else graphName(graph.constants.Use, value);
}

fn nodeName(value: model.NodeType) []const u8 {
    return enumName(value, &.{
        "street_intersection", "gate",                       "bollard",     "toll_booth",        "transit_egress",
        "transit_station",     "multi_use_transit_platform", "bike_share",  "parking",           "motor_way_junction",
        "border_control",      "toll_gantry",                "sump_buster", "building_entrance", "elevator",
    });
}
