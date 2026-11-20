// Ported from src/odin/maneuver.cc and valhalla/odin/maneuver.h (Valhalla 3.9.3).
const std = @import("std");
const trip = @import("../api/trip.zig");
const directions = @import("../api/directions.zig");
const request = @import("../api/request.zig");
const debug = @import("debug.zig");
const io = @import("../infra/io.zig");
const lengthInUnits = @import("enhanced.zig").lengthInUnits;

pub const RelativeDirection = enum { none, keep_straight, keep_right, right, reverse, left, keep_left };
pub const TrailType = enum { none, named_cycleway, unnamed_cycleway, named_walkway, unnamed_walkway, named_mtb_trail, unnamed_mtb_trail };
pub const NameStyle = enum { generic, us };

/// The maneuver builder holds one value per instruction in the request arena.
/// Names, signs and text borrow arena storage or the original trip leg.
pub const Maneuver = struct {
    type: directions.ManeuverType = .kNone,
    node_type: ?trip.NodeType = null,
    traffic_signal: bool = false,
    steps: bool = false,
    bridge: bool = false,
    tunnel: bool = false,
    street_names: []const trip.StreetName = &.{},
    name_style: NameStyle = .generic,
    begin_street_names: []const trip.StreetName = &.{},
    cross_street_names: []const trip.StreetName = &.{},
    instruction: []const u8 = "",
    length_km: f32 = 0,
    time: f64 = 0,
    basic_time: f64 = 0,
    turn_degree: u32 = 0,
    begin_relative_direction: RelativeDirection = .none,
    begin_cardinal_direction: directions.CardinalDirection = .kNorth,
    begin_heading: u32 = 0,
    end_heading: u32 = 0,
    begin_node_index: u32 = 0,
    end_node_index: u32 = 0,
    begin_shape_index: u32 = 0,
    end_shape_index: u32 = 0,
    ramp: bool = false,
    turn_channel: bool = false,
    ferry: bool = false,
    rail_ferry: bool = false,
    roundabout: bool = false,
    portions_toll: bool = false,
    portions_unpaved: bool = false,
    portions_highway: bool = false,
    internal_intersection: bool = false,
    signs: trip.Sign = .{},
    internal_right_turn_count: u32 = 0,
    internal_left_turn_count: u32 = 0,
    fork: bool = false,
    begin_intersecting_edge_name_consistency: bool = false,
    intersecting_forward_edge: bool = false,
    verbal_succinct_transition_instruction: []const u8 = "",
    verbal_transition_alert_instruction: []const u8 = "",
    verbal_pre_transition_instruction: []const u8 = "",
    verbal_post_transition_instruction: []const u8 = "",
    tee: bool = false,
    trail_type: TrailType = .none,
    imminent_verbal_multi_cue: bool = false,
    distant_verbal_multi_cue: bool = false,
    to_stay_on: bool = false,
    pedestrian_crossing: bool = false,
    merge_to_relative_direction: RelativeDirection = .none,
    drive_on_right: bool = true,
    has_time_restrictions: bool = false,
    has_right_traversable_outbound_intersecting_edge: bool = false,
    has_left_traversable_outbound_intersecting_edge: bool = false,
    include_verbal_pre_transition_length: bool = false,
    contains_obvious_maneuver: bool = false,
    roundabout_exit_count: u32 = 0,
    has_combined_enter_exit_roundabout: bool = false,
    roundabout_length_km: f32 = 0,
    roundabout_exit_length_km: f32 = 0,
    roundabout_exit_street_names: []const trip.StreetName = &.{},
    roundabout_exit_begin_street_names: []const trip.StreetName = &.{},
    roundabout_exit_signs: trip.Sign = .{},
    roundabout_exit_begin_heading: u32 = 0,
    roundabout_exit_turn_degree: u32 = 0,
    roundabout_exit_shape_index: u32 = 0,
    has_collapsed_small_end_ramp_fork: bool = false,
    has_collapsed_merge_maneuver: bool = false,
    has_long_street_name: bool = false,
    bss_info: trip.BikeShareStationInfo = .{},
    elevator: bool = false,
    indoor_steps: bool = false,
    escalator: bool = false,
    building_enter: bool = false,
    building_exit: bool = false,
    has_level_changes: bool = false,
    end_level_ref: []const u8 = "",
    landmarks: []const trip.RouteLandmark = &.{},
    transit_connection: bool = false,
    transit_connection_egress_info: trip.TransitEgressInfo = .{},
    transit_connection_station_info: trip.TransitStationInfo = .{},
    transit_connection_platform_info: trip.TransitPlatformInfo = .{},
    transit_info: trip.TransitRouteInfo = .{},
    depart_instruction: []const u8 = "",
    verbal_depart_instruction: []const u8 = "",
    arrive_instruction: []const u8 = "",
    verbal_arrive_instruction: []const u8 = "",
    travel_mode: trip.TravelMode = .kDrive,
    rail: bool = false,
    bus: bool = false,
    vehicle_type: trip.VehicleType = .kCar,
    pedestrian_type: trip.PedestrianType = .kFoot,
    bicycle_type: trip.BicycleType = .kRoad,
    transit_type: trip.TransitType = .kRail,
    bss_maneuver_type: directions.BssManeuverType = .kNoneAction,
    guidance_views: []const directions.GuidanceView = &.{},

    pub fn isStartType(self: *const Maneuver) bool {
        return switch (self.type) {
            .kStart, .kStartLeft, .kStartRight => true,
            else => false,
        };
    }

    pub fn isDestinationType(self: *const Maneuver) bool {
        return switch (self.type) {
            .kDestination, .kDestinationLeft, .kDestinationRight => true,
            else => false,
        };
    }

    pub fn isMergeType(self: *const Maneuver) bool {
        return switch (self.type) {
            .kMerge, .kMergeLeft, .kMergeRight => true,
            else => false,
        };
    }

    pub fn isLeftType(self: *const Maneuver) bool {
        return switch (self.type) {
            .kSlightLeft, .kLeft, .kSharpLeft, .kUturnLeft, .kRampLeft, .kExitLeft, .kStayLeft, .kDestinationLeft, .kMergeLeft => true,
            else => false,
        };
    }

    pub fn isRightType(self: *const Maneuver) bool {
        return switch (self.type) {
            .kSlightRight, .kRight, .kSharpRight, .kUturnRight, .kRampRight, .kExitRight, .kStayRight, .kDestinationRight, .kMergeRight => true,
            else => false,
        };
    }

    pub fn isTransit(self: *const Maneuver) bool {
        return switch (self.type) {
            .kTransit, .kTransitTransfer, .kTransitRemainOn => true,
            else => false,
        };
    }

    pub fn length(self: *const Maneuver, units: request.Units) f32 {
        return lengthInUnits(self.length_km, units);
    }

    pub fn roundaboutLength(self: *const Maneuver, units: request.Units) f32 {
        return lengthInUnits(self.roundabout_length_km, units);
    }

    pub fn roundaboutExitLength(self: *const Maneuver, units: request.Units) f32 {
        return lengthInUnits(self.roundabout_exit_length_km, units);
    }

    pub fn hasUsableInternalIntersectionName(self: *const Maneuver) bool {
        const links = self.end_node_index -% self.begin_node_index;
        return self.internal_intersection and self.street_names.len != 0 and (links == 1 or links == 3);
    }

    pub fn hasSameNames(self: *const Maneuver, other: ?*const Maneuver, allow_intersecting_names: bool, deadline: io.Deadline) !bool {
        return self.namesMatch(other, allow_intersecting_names, false, deadline);
    }

    pub fn hasSimilarNames(self: *const Maneuver, other: ?*const Maneuver, allow_intersecting_names: bool, deadline: io.Deadline) !bool {
        return self.namesMatch(other, allow_intersecting_names, true, deadline);
    }

    fn namesMatch(self: *const Maneuver, other: ?*const Maneuver, allow_intersecting_names: bool, similar: bool, deadline: io.Deadline) !bool {
        if (self.street_names.len == 0 or (!allow_intersecting_names and self.begin_intersecting_edge_name_consistency)) return false;
        const donor = other orelse return false;
        var count: usize = 0;
        for (donor.street_names) |left| {
            if (deadline.expired()) return error.DeadlineExceeded;
            for (self.street_names, 0..) |right, i| {
                if (i % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const matches = if (similar)
                    std.mem.eql(u8, baseName(left.value, donor.name_style), baseName(right.value, self.name_style))
                else
                    left.is_route_number == right.is_route_number and std.mem.eql(u8, left.value, right.value);
                if (matches) {
                    count += 1;
                    break;
                }
            }
        }
        return count == self.street_names.len;
    }

    pub fn isWalkway(self: *const Maneuver) bool {
        return self.trail_type == .named_walkway or self.trail_type == .unnamed_walkway;
    }

    pub fn isCycleway(self: *const Maneuver) bool {
        return self.trail_type == .named_cycleway or self.trail_type == .unnamed_cycleway;
    }

    pub fn isMountainBikeTrail(self: *const Maneuver) bool {
        return self.trail_type == .named_mtb_trail or self.trail_type == .unnamed_mtb_trail;
    }

    pub fn hasVerbalMultiCue(self: *const Maneuver) bool {
        return self.imminent_verbal_multi_cue or self.distant_verbal_multi_cue;
    }

    pub fn hasExitSign(self: *const Maneuver) bool {
        return self.signs.exit_numbers.len != 0 or self.signs.exit_onto_streets.len != 0 or
            self.signs.exit_toward_locations.len != 0 or self.signs.exit_names.len != 0;
    }

    pub fn hasGuideSign(self: *const Maneuver) bool {
        return self.signs.guide_onto_streets.len != 0 or self.signs.guide_toward_locations.len != 0;
    }

    pub fn hasSigns(self: *const Maneuver) bool {
        return self.hasExitSign() or self.hasGuideSign() or self.signs.junction_names.len != 0;
    }

    pub fn transitArrivalTime(self: *const Maneuver) []const u8 {
        const stops = self.transit_info.transit_stops;
        return if (stops.len == 0) "" else stops[stops.len - 1].arrival_date_time;
    }

    pub fn transitDepartureTime(self: *const Maneuver) []const u8 {
        const stops = self.transit_info.transit_stops;
        return if (stops.len == 0) "" else stops[0].departure_date_time;
    }

    pub fn transitStopCount(self: *const Maneuver) usize {
        return self.transit_info.transit_stops.len -| 1;
    }

    pub fn isUnnamedWalkway(self: *const Maneuver) bool {
        return self.trail_type == .unnamed_walkway;
    }

    pub fn isUnnamedCycleway(self: *const Maneuver) bool {
        return self.trail_type == .unnamed_cycleway;
    }

    pub fn isUnnamedMountainBikeTrail(self: *const Maneuver) bool {
        return self.trail_type == .unnamed_mtb_trail;
    }

    pub fn writeDebug(self: *const Maneuver, out: *io.Writer, deadline: io.Deadline) !void {
        try out.print("type_={d}", .{@backingInt(self.type)});
        inline for (.{ "street_names", "begin_street_names", "cross_street_names" }, 0..) |key, i| {
            try out.print(" | {s}=", .{if (i == 0) "street_names_" else key});
            const list = @field(self, key);
            if (list.len == 0) {
                try out.writeAll("unnamed");
            } else {
                try debug.names(out, list, "value", true, deadline);
            }
        }
        try debug.field(out, "instruction", self.instruction);
        try debug.field(out, "distance_", self.length_km);
        try debug.fields(out, self, &.{
            "time",                  "turn_degree",    "begin_relative_direction", "begin_cardinal_direction", "begin_heading",    "end_heading",
            "begin_node_index",      "end_node_index", "begin_shape_index",        "end_shape_index",          "ramp",             "turn_channel",
            "ferry",                 "rail_ferry",     "roundabout",               "portions_toll",            "portions_unpaved", "portions_highway",
            "internal_intersection",
        });
        inline for (.{
            "exit_numbers",           "exit_onto_streets", "exit_toward_locations", "exit_names", "guide_onto_streets",
            "guide_toward_locations", "junction_names",
        }) |key| {
            try out.print(" | {s}=", .{key});
            try debug.names(out, @field(self.signs, key), "text", false, deadline);
        }
        try debug.fields(out, self, &.{
            "internal_right_turn_count",          "internal_left_turn_count",               "fork",                                "begin_intersecting_edge_name_consistency",
            "intersecting_forward_edge",          "verbal_succinct_transition_instruction", "verbal_transition_alert_instruction", "verbal_pre_transition_instruction",
            "verbal_post_transition_instruction", "tee",
        });
        const trail_type = switch (self.trail_type) {
            .none => "kNone",
            .named_cycleway => "kNamedCycleway",
            .unnamed_cycleway => "kUnnamedCycleway",
            .named_walkway => "kNamedWalkway",
            .unnamed_walkway => "kUnnamedWalkway",
            .named_mtb_trail => "kNamedMtbTrail",
            .unnamed_mtb_trail => "kUnnamedMtbTrail",
        };
        try debug.field(out, "trail_type", @as([]const u8, trail_type));
        try debug.field(out, "unnamed_walkway", self.isUnnamedWalkway());
        try debug.field(out, "unnamed_cycleway", self.isUnnamedCycleway());
        try debug.field(out, "unnamed_mountain_bike_trail", self.isUnnamedMountainBikeTrail());
        try debug.fields(out, self, &.{
            "basic_time",            "imminent_verbal_multi_cue",          "distant_verbal_multi_cue", "contains_obvious_maneuver",
            "roundabout_exit_count", "has_combined_enter_exit_roundabout",
        });
        try debug.field(out, "roundabout_length", self.roundabout_length_km);
        try debug.field(out, "roundabout_exit_length", self.roundabout_exit_length_km);
        try debug.fields(out, self, &.{
            "roundabout_exit_begin_heading",     "roundabout_exit_turn_degree",  "roundabout_exit_shape_index",
            "has_collapsed_small_end_ramp_fork", "has_collapsed_merge_maneuver", "travel_mode",
            "rail",                              "bus",                          "has_long_street_name",
            "transit_connection",
        });
        try out.writeAll(" | guidance_views=");
        for (self.guidance_views) |view| {
            if (deadline.expired()) return error.DeadlineExceeded;
            try out.print("[ data_id={s} type={d} base_id={s} overlay_ids=", .{ view.data_id, @backingInt(view.type), view.base_id });
            for (view.overlay_ids, 0..) |overlay, i| {
                if (i % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
                try out.print("{s} ", .{overlay});
            }
            try out.writeByte(']');
        }
    }
};

fn baseName(value: []const u8, style: NameStyle) []const u8 {
    if (style != .us) return value;
    const compass = [_][]const u8{ "North", "East", "South", "West", "Northeast", "Southeast", "Southwest", "Northwest" };
    var start: usize = 0;
    var end = value.len;
    inline for (compass) |direction| {
        if (std.mem.startsWith(u8, value, direction ++ " ")) start = direction.len + 1;
        if (std.mem.endsWith(u8, value, " " ++ direction)) end = value.len - direction.len - 1;
    }
    return value[start..@max(start, end)];
}
