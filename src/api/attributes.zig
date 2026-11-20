// Ported from src/baldr/attributes_controller.cc and valhalla/baldr/attributes_controller.h
// (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const json = @import("json.zig");

pub const FilterAction = @import("proto/options.zig").FilterAction;

pub const Filter = struct {
    action: FilterAction = .no_action,
    keys: []const json.Value = &.{},

    pub fn parse(value: json.Value) Filter {
        return .{
            .action = std.meta.stringToEnum(FilterAction, json.get([]const u8, value, "/action", "")) orelse .no_action,
            .keys = json.array(value, "/attributes") orelse &.{},
        };
    }
};

/// The enum spellings are the public filter keys.
pub const Key = enum(u8) {
    @"edge.names",
    @"edge.length",
    @"edge.speed",
    @"edge.speed_type",
    @"edge.speeds_faded",
    @"edge.speeds_non_faded",
    @"edge.road_class",
    @"edge.begin_heading",
    @"edge.end_heading",
    @"edge.begin_shape_index",
    @"edge.end_shape_index",
    @"edge.traversability",
    @"edge.use",
    @"edge.toll",
    @"edge.unpaved",
    @"edge.tunnel",
    @"edge.bridge",
    @"edge.roundabout",
    @"edge.internal_intersection",
    @"edge.drive_on_right",
    @"edge.surface",
    @"edge.sign.exit_number",
    @"edge.sign.exit_branch",
    @"edge.sign.exit_toward",
    @"edge.sign.exit_name",
    @"edge.sign.guide_branch",
    @"edge.sign.guide_toward",
    @"edge.sign.junction_name",
    @"edge.sign.guidance_view_junction",
    @"edge.sign.guidance_view_signboard",
    @"edge.travel_mode",
    @"edge.vehicle_type",
    @"edge.pedestrian_type",
    @"edge.bicycle_type",
    @"edge.transit_type",
    @"edge.transit_route_info.onestop_id",
    @"edge.transit_route_info.block_id",
    @"edge.transit_route_info.trip_id",
    @"edge.transit_route_info.short_name",
    @"edge.transit_route_info.long_name",
    @"edge.transit_route_info.headsign",
    @"edge.transit_route_info.color",
    @"edge.transit_route_info.text_color",
    @"edge.transit_route_info.description",
    @"edge.transit_route_info.operator_onestop_id",
    @"edge.transit_route_info.operator_name",
    @"edge.transit_route_info.operator_url",
    @"edge.id",
    @"edge.way_id",
    @"edge.begin_osm_node_id",
    @"edge.end_osm_node_id",
    @"edge.weighted_grade",
    @"edge.max_upward_grade",
    @"edge.max_downward_grade",
    @"edge.mean_elevation",
    @"edge.lane_count",
    @"edge.lane_connectivity",
    @"edge.cycle_lane",
    @"edge.bicycle_network",
    @"edge.elevation",
    @"edge.sac_scale",
    @"edge.shoulder",
    @"edge.sidewalk",
    @"edge.density",
    @"edge.speed_limit",
    @"edge.conditional_speed_limits",
    @"edge.truck_speed",
    @"edge.truck_route",
    @"edge.default_speed",
    @"edge.destination_only",
    @"edge.destination_only_hgv",
    @"edge.is_urban",
    @"edge.tagged_values",
    @"edge.indoor",
    @"edge.landmarks",
    @"edge.country_crossing",
    @"edge.forward",
    @"edge.levels",
    @"edge.traffic_signal",
    @"edge.hov_type",
    @"edge.ramp",
    @"edge.dismount",
    @"edge.use_sidepath",
    @"edge.sidewalk_left",
    @"edge.sidewalk_right",
    @"edge.bss_connection",
    @"edge.lit",
    @"edge.not_thru",
    @"edge.part_of_complex_restriction",
    @"edge.layer",
    @"edge.is_shortcut",
    @"edge.leaves_tile",
    @"edge.curvature",
    @"edge.speed_forward",
    @"edge.deadend_forward",
    @"edge.lanecount_forward",
    @"edge.truck_speed_forward",
    @"edge.traffic_signal_forward",
    @"edge.stop_sign_forward",
    @"edge.yield_sign_forward",
    @"edge.access_forward",
    @"edge.live_speed_forward",
    @"edge.freeflow_speed_forward",
    @"edge.speed_backward",
    @"edge.deadend_backward",
    @"edge.lanecount_backward",
    @"edge.truck_speed_backward",
    @"edge.traffic_signal_backward",
    @"edge.stop_sign_backward",
    @"edge.yield_sign_backward",
    @"edge.access_backward",
    @"edge.live_speed_backward",
    @"edge.freeflow_speed_backward",
    incidents,
    @"node.intersecting_edge.begin_heading",
    @"node.intersecting_edge.from_edge_name_consistency",
    @"node.intersecting_edge.to_edge_name_consistency",
    @"node.intersecting_edge.driveability",
    @"node.intersecting_edge.cyclability",
    @"node.intersecting_edge.walkability",
    @"node.intersecting_edge.use",
    @"node.intersecting_edge.road_class",
    @"node.intersecting_edge.lane_count",
    @"node.intersecting_edge.sign_info",
    @"node.elapsed_time",
    @"node.admin_index",
    @"node.type",
    @"node.traffic_signal",
    @"node.fork",
    @"node.transit_platform_info.type",
    @"node.transit_platform_info.onestop_id",
    @"node.transit_platform_info.name",
    @"node.transit_platform_info.station_onestop_id",
    @"node.transit_platform_info.station_name",
    @"node.transit_platform_info.arrival_date_time",
    @"node.transit_platform_info.departure_date_time",
    @"node.transit_platform_info.is_parent_stop",
    @"node.transit_platform_info.assumed_schedule",
    @"node.transit_platform_info.lat_lon",
    @"node.transit_station_info.onestop_id",
    @"node.transit_station_info.name",
    @"node.transit_station_info.lat_lon",
    @"node.transit_egress_info.onestop_id",
    @"node.transit_egress_info.name",
    @"node.transit_egress_info.lat_lon",
    @"node.time_zone",
    @"node.transition_time",
    @"node.stop_impact",
    @"node.drive_on_right",
    @"node.elevation",
    @"node.tagged_access",
    @"node.private_access",
    @"node.cash_only_toll",
    @"node.mode_change_allowed",
    @"node.named_intersection",
    @"node.is_transit",
    @"node.access",
    osm_changeset,
    @"admin.country_code",
    @"admin.country_text",
    @"admin.state_code",
    @"admin.state_text",
    shape,
    @"matched.point",
    @"matched.type",
    @"matched.edge_index",
    @"matched.begin_route_discontinuity",
    @"matched.end_route_discontinuity",
    @"matched.distance_along_edge",
    @"matched.distance_from_trace_point",
    confidence_score,
    raw_score,
    @"shape_attributes.time",
    @"shape_attributes.length",
    @"shape_attributes.speed",
    @"shape_attributes.speed_limit",
    @"shape_attributes.closure",
    @"shape_attributes.congestion",
    @"incident.id",
    @"incident.type",
    @"incident.description",
    @"incident.sub_type",
    @"incident.sub_type_description",
    @"incident.start_time",
    @"incident.end_time",
    @"incident.impact",
    @"incident.road_closed",
    @"incident.congestion_value",
    @"incident.creation_time",
    @"incident.long_description",
    @"incident.clear_lanes",
    @"incident.num_lanes_blocked",
    @"incident.length",
    @"incident.iso_3166_1_alpha2",
    @"incident.iso_3166_1_alpha3",
};

const Set = std.EnumSet(Key);
const disabled_by_default: []const Key = &.{
    .@"edge.elevation",
    .@"edge.destination_only_hgv",
    .@"edge.is_urban",
    .@"edge.hov_type",
    .@"edge.ramp",
    .@"edge.dismount",
    .@"edge.use_sidepath",
    .@"edge.sidewalk_left",
    .@"edge.sidewalk_right",
    .@"edge.bss_connection",
    .@"edge.lit",
    .@"edge.not_thru",
    .@"edge.part_of_complex_restriction",
    .@"edge.layer",
    .@"edge.is_shortcut",
    .@"edge.leaves_tile",
    .@"edge.curvature",
    .@"edge.speed_forward",
    .@"edge.deadend_forward",
    .@"edge.lanecount_forward",
    .@"edge.truck_speed_forward",
    .@"edge.traffic_signal_forward",
    .@"edge.stop_sign_forward",
    .@"edge.yield_sign_forward",
    .@"edge.access_forward",
    .@"edge.live_speed_forward",
    .@"edge.freeflow_speed_forward",
    .@"edge.speed_backward",
    .@"edge.deadend_backward",
    .@"edge.lanecount_backward",
    .@"edge.truck_speed_backward",
    .@"edge.traffic_signal_backward",
    .@"edge.stop_sign_backward",
    .@"edge.yield_sign_backward",
    .@"edge.access_backward",
    .@"edge.live_speed_backward",
    .@"edge.freeflow_speed_backward",
    .incidents,
    .@"node.stop_impact",
    .@"node.drive_on_right",
    .@"node.elevation",
    .@"node.tagged_access",
    .@"node.private_access",
    .@"node.cash_only_toll",
    .@"node.mode_change_allowed",
    .@"node.named_intersection",
    .@"node.is_transit",
    .@"node.access",
    .@"shape_attributes.time",
    .@"shape_attributes.length",
    .@"shape_attributes.speed",
    .@"shape_attributes.speed_limit",
    .@"shape_attributes.closure",
    .@"shape_attributes.congestion",
    .@"incident.id",
    .@"incident.type",
    .@"incident.description",
    .@"incident.sub_type",
    .@"incident.sub_type_description",
    .@"incident.start_time",
    .@"incident.end_time",
    .@"incident.impact",
    .@"incident.road_closed",
    .@"incident.congestion_value",
    .@"incident.creation_time",
    .@"incident.long_description",
    .@"incident.clear_lanes",
    .@"incident.num_lanes_blocked",
    .@"incident.length",
    .@"incident.iso_3166_1_alpha2",
    .@"incident.iso_3166_1_alpha3",
};

const defaults: Set = default_attributes: {
    @setEvalBranchQuota(10_000);
    var selected: Set = .full;
    for (disabled_by_default) |key| selected.remove(key);
    break :default_attributes selected;
};

pub const Controller = struct {
    enabled: Set = defaults,

    pub fn fromJson(filters: json.Value, strict: bool, elevation_interval: f32, deadline: io.Deadline) error{DeadlineExceeded}!Controller {
        return init(Filter.parse(filters), strict, elevation_interval, deadline);
    }

    pub fn init(filter: Filter, strict: bool, elevation_interval: f32, deadline: io.Deadline) error{DeadlineExceeded}!Controller {
        var result: Controller = .{};
        switch (filter.action) {
            .include, .exclude => {
                const include = filter.action == .include;
                if (strict) result.enabled = if (include) .empty else .full;
                for (filter.keys, 0..) |item, i| {
                    if (i % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
                    if (item != .string) continue;
                    const key = if (std.mem.eql(u8, item.string, "edge.tagged_names"))
                        Key.@"edge.tagged_values"
                    else
                        std.meta.stringToEnum(Key, item.string) orelse continue;
                    result.enabled.setPresent(key, include);
                }
            },
            else => {},
        }
        result.enabled.setPresent(.@"edge.elevation", elevation_interval > 0);
        return result;
    }

    pub fn has(self: Controller, key: Key) bool {
        return self.enabled.contains(key);
    }

    pub fn hasAny(self: Controller, comptime prefix: []const u8) bool {
        const keys: Set = comptime selected: {
            @setEvalBranchQuota(20_000);
            var mask: Set = .empty;
            for (std.enums.values(Key)) |key| {
                if (std.mem.startsWith(u8, @tagName(key), prefix)) mask.insert(key);
            }
            break :selected mask;
        };
        return self.enabled.intersectWith(keys).count() != 0;
    }
};

test "strict and additive trip filters follow Valhalla defaults and aliases" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"action":"include","attributes":["edge.tagged_names","node.elapsed_time","nonexistent",17]}
    , .{});
    defer parsed.deinit();
    const strict = try Controller.fromJson(parsed.value, true, 0, .none);
    try std.testing.expect(strict.has(.@"edge.tagged_values"));
    try std.testing.expect(strict.hasAny("node."));
    try std.testing.expect(!strict.hasAny("admin."));
    try std.testing.expect(!strict.has(.@"edge.names"));
    const additive = try Controller.fromJson(parsed.value, false, 10, .none);
    try std.testing.expect(additive.has(.@"edge.elevation"));
    try std.testing.expect(additive.has(.@"edge.names"));
    try std.testing.expect(!additive.has(.@"shape_attributes.speed"));
    try std.testing.expectError(error.DeadlineExceeded, Controller.fromJson(parsed.value, true, 0, .{ .at_ns = 0 }));
}

test "exclude filters keep optional defaults only in strict mode" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"action":"exclude","attributes":["edge.names","edge.elevation"]}
    , .{});
    defer parsed.deinit();
    const strict = try Controller.fromJson(parsed.value, true, 25, .none);
    try std.testing.expect(!strict.has(.@"edge.names"));
    try std.testing.expect(strict.has(.@"edge.elevation"));
    try std.testing.expect(strict.has(.@"shape_attributes.speed"));
    const other = try Controller.fromJson(parsed.value, false, 0, .none);
    try std.testing.expect(!other.has(.@"edge.names"));
    try std.testing.expect(!other.has(.@"edge.elevation"));
    try std.testing.expect(!other.has(.@"shape_attributes.speed"));
}
