// Ported from valhalla/loki/tiles.h (Valhalla 3.9.3).
const std = @import("std");
const attributes = @import("../api/attributes.zig");
const graph = @import("../graph/root.zig");
const mvt = @import("mvt.zig");
const EdgeId = graph.format.EdgeId;
const NodeId = graph.format.NodeId;
const Edge = graph.format.EdgeHot;
const Class = graph.class_table.EdgeClass;
const View = graph.reader.View;

const Properties = struct {
    filter: attributes.Controller,
    values: [43 + 2 * 19]mvt.Property = undefined,
    count: usize = 0,

    pub fn slice(self: *const Properties) []const mvt.Property {
        return self.values[0..self.count];
    }

    fn add(self: *Properties, key: []const u8, value: anytype) void {
        self.values[self.count] = .{ .key = key, .value = typed(value) };
        self.count += 1;
    }

    fn optional(self: *Properties, filter: attributes.Key, key: []const u8, value: anytype) void {
        if (self.filter.has(filter)) self.add(key, value);
    }

    fn typed(value: anytype) mvt.Value {
        return switch (@typeInfo(@TypeOf(value))) {
            .bool => .{ .boolean = value },
            .int => |info| if (info.signedness == .signed) .{ .signed = value } else .{ .unsigned = value },
            .comptime_int => if (value < 0) .{ .signed = value } else .{ .unsigned = value },
            .pointer => .{ .string = value },
            .float => if (@TypeOf(value) == f32) .{ .float = value } else .{ .double = value },
            else => @compileError("unsupported vector tile property type"),
        };
    }
};

pub fn edgeProperties(view: *const View, filter: attributes.Controller, id: EdgeId, edge: *const Edge, class: *const Class, twin_id: EdgeId, twin: *const Edge, record: graph.cold.Record) !Properties {
    var p: Properties = .{ .filter = filter };
    const flags = class.flags;
    const category = class.category;
    p.add("tile_level", 0);
    p.add("road_class", category.road_class);
    p.optional(.@"edge.use", "use", category.use);
    p.optional(.@"edge.tunnel", "tunnel", flags.tunnel);
    p.optional(.@"edge.bridge", "bridge", flags.bridge);
    p.optional(.@"edge.roundabout", "roundabout", flags.roundabout);
    p.optional(.@"edge.is_shortcut", "shortcut", false);
    p.optional(.@"edge.leaves_tile", "leaves_tile", false);
    p.optional(.@"edge.length", "length", edge.geom.len_m);
    p.optional(.@"edge.weighted_grade", "weighted_grade", edge.geom.grade);
    if (filter.has(.@"edge.max_upward_grade") or filter.has(.@"edge.max_downward_grade")) {
        const slopes = try view.edgeSlopes(id);
        p.optional(.@"edge.max_upward_grade", "max_up_slope", slopes.maxUp());
        p.optional(.@"edge.max_downward_grade", "max_down_slope", slopes.maxDown());
    }
    p.optional(.@"edge.curvature", "curvature", edge.geom.curvature);
    p.optional(.@"edge.toll", "toll", flags.toll);
    p.optional(.@"edge.destination_only", "destonly", flags.destination_only);
    p.optional(.@"edge.destination_only_hgv", "destonly_hgv", flags.destination_only_hgv);
    p.optional(.@"edge.indoor", "indoor", flags.indoor);
    p.optional(.@"edge.hov_type", "hov_type", @intFromBool(flags.hov3));
    p.optional(.@"edge.cycle_lane", "cyclelane", category.cycle_lane);
    p.optional(.@"edge.bicycle_network", "bike_network", @as(u4, @truncate(category.bike_network)));
    p.optional(.@"edge.truck_route", "truck_route", flags.truck_route);
    p.optional(.@"edge.speed_type", "speed_type", @intFromBool(!flags.tagged_speed));
    p.optional(.@"edge.country_crossing", "country_crossing", flags.country_crossing);
    p.optional(.@"edge.sac_scale", "sac_scale", category.sac_scale);
    p.optional(.@"edge.unpaved", "unpaved", category.surface >= @backingInt(graph.constants.Surface.compacted));
    p.optional(.@"edge.surface", "surface", category.surface);
    p.optional(.@"edge.ramp", "ramp", category.use == @backingInt(graph.constants.Use.ramp));
    p.optional(.@"edge.internal_intersection", "internal", flags.internal);
    p.optional(.@"edge.shoulder", "shoulder", flags.shoulder);
    p.optional(.@"edge.dismount", "dismount", flags.dismount);
    p.optional(.@"edge.use_sidepath", "use_sidepath", flags.use_sidepath);
    p.optional(.@"edge.density", "density", category.density);
    p.optional(.@"edge.sidewalk_left", "sidewalk_left", flags.sidewalk_left);
    p.optional(.@"edge.sidewalk_right", "sidewalk_right", flags.sidewalk_right);
    p.optional(.@"edge.bss_connection", "bss_connection", flags.bike_share_connection);
    p.optional(.@"edge.lit", "lit", flags.lit);
    p.optional(.@"edge.not_thru", "not_thru", flags.not_thru);
    p.optional(.@"edge.part_of_complex_restriction", "part_of_complex_restriction", flags.complex_restriction);
    p.optional(.@"edge.way_id", "osm_id", record.wayId());
    p.optional(.@"edge.speed_limit", "speed_limit", record.speedLimit());
    p.optional(.@"edge.layer", "layer", record.indoor.layer);
    p.optional(.@"edge.id", "edge_id:fwd", @backingInt(id));
    p.optional(.@"edge.id", "edge_id:bwd", @backingInt(twin_id));
    direction(&p, edge, class, true);
    direction(&p, twin, try view.class(twin.cls.class_id), false);
    return p;
}

fn direction(p: *Properties, edge: *const Edge, class: *const Class, comptime forward: bool) void {
    const suffix = if (forward) ":fwd" else ":bwd";
    const label = if (forward) "_forward" else "_backward";
    p.optional(@field(attributes.Key, "edge.speed" ++ label), "speed" ++ suffix, edge.speed[0]);
    p.optional(@field(attributes.Key, "edge.deadend" ++ label), "deadend" ++ suffix, class.flags.dead_end);
    p.optional(@field(attributes.Key, "edge.lanecount" ++ label), "lanecount" ++ suffix, class.category.lanes);
    p.optional(@field(attributes.Key, "edge.truck_speed" ++ label), "truck_speed" ++ suffix, edge.speed[3]);
    p.optional(@field(attributes.Key, "edge.traffic_signal" ++ label), "traffic_signal" ++ suffix, class.flags.traffic_signal);
    p.optional(@field(attributes.Key, "edge.stop_sign" ++ label), "stop_sign" ++ suffix, class.flags.stop_sign);
    p.optional(@field(attributes.Key, "edge.yield_sign" ++ label), "yield_sign" ++ suffix, class.flags.yield_sign);
    p.optional(@field(attributes.Key, "edge.access" ++ label), "access" ++ suffix, class.access.forward);
    p.optional(@field(attributes.Key, "edge.freeflow_speed" ++ label), "freeflow_speed" ++ suffix, edge.speed[1]);
    // Valhalla uses the free-flow filter for both traffic speeds.
    p.optional(@field(attributes.Key, "edge.freeflow_speed" ++ label), "constrained_speed" ++ suffix, edge.speed[2]);
    if (p.filter.has(@field(attributes.Key, "edge.live_speed" ++ label))) {
        const unknown_traffic_speed = 254;
        p.add("live_speed" ++ suffix, unknown_traffic_speed);
        inline for (.{ ":speed1", ":speed2", ":speed3" }) |key|
            p.add("live_speed" ++ suffix ++ key, unknown_traffic_speed);
        inline for (.{ ":bp1", ":bp2", ":congestion1", ":congestion2", ":congestion3" }) |key|
            p.add("live_speed" ++ suffix ++ key, 0);
    }
}

pub fn nodeProperties(view: *const View, filter: attributes.Controller, id: NodeId) !Properties {
    var p: Properties = .{ .filter = filter };
    const attr = (try view.node(id)).attr;
    p.add("tile_level", 0);
    p.add("node_id", @backingInt(id));
    p.add("type", attr.type);
    p.add("traffic_signal", attr.signal != 0);
    p.optional(.@"node.drive_on_right", "drive_on_right", !attr.drive_on_left);
    p.optional(.@"node.elevation", "elevation", @as(f32, graph.cold.no_elevation));
    p.optional(.@"node.tagged_access", "tagged_access", attr.tagged_access);
    p.optional(.@"node.private_access", "private_access", attr.private_access);
    p.optional(.@"node.cash_only_toll", "cash_only_toll", attr.cash_only_toll);
    p.optional(.@"node.mode_change_allowed", "mode_change_allowed", attr.type == @backingInt(graph.constants.NodeType.bike_share));
    p.optional(.@"node.named_intersection", "named_intersection", false);
    p.optional(.@"node.access", "access", attr.access);
    if (filter.has(.@"node.time_zone")) {
        const tz = if (view.tz_rules) |zones| try zones.name(try view.nodeTimezone(id)) else null;
        p.add("timezone", tz orelse "");
    }
    if (filter.has(.@"admin.country_code") or filter.has(.@"admin.state_code")) {
        const admin = try view.nodeAdmin(id);
        p.optional(.@"admin.country_code", "iso_3166_1", admin.country_iso);
        p.optional(.@"admin.state_code", "iso_3166_2", admin.state_iso);
    }
    return p;
}
