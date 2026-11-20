// Ported from src/odin/enhancedtrippath.cc (Valhalla 3.9.3).
const std = @import("std");
const trip = @import("../api/trip.zig");
const request = @import("../api/request.zig");
const debug = @import("debug.zig");
const EncodedLevels = @import("../graph/cold.zig").EncodedLevels;
const io = @import("../infra/io.zig");
const lanes = @import("../graph/lanes.zig");
const ManeuverType = @import("../api/directions.zig").ManeuverType;
const turn = @import("../graph/turn.zig");
const mile_per_km = @import("../geo/constants.zig").mile_per_km;

pub const Leg = struct {
    value: *const trip.TripLeg,
    deadline: io.Deadline = .none,

    pub fn node(self: Leg, index: usize) ?Node {
        if (index >= self.value.node.len) return null;
        return .{ .value = &self.value.node[index], .deadline = self.deadline };
    }

    pub fn admin(self: Leg, index: usize) ?Admin {
        if (index >= self.value.admin.len) return null;
        return .{ .value = &self.value.admin[index] };
    }

    pub fn prevEdge(self: Leg, index: usize, delta: usize) ?Edge {
        return self.currEdge(std.math.sub(usize, index, delta) catch return null);
    }

    pub fn currEdge(self: Leg, index: usize) ?Edge {
        return (self.node(index) orelse return null).edge();
    }

    pub fn nextEdge(self: Leg, index: usize, delta: usize) ?Edge {
        return self.currEdge(std.math.add(usize, index, delta) catch return null);
    }

    pub fn lastNodeIndex(self: Leg) ?usize {
        return if (self.value.node.len == 0) null else self.value.node.len - 1;
    }

    pub fn isValidNodeIndex(self: Leg, index: usize) bool {
        return index < self.value.node.len;
    }

    pub fn isFirstNodeIndex(_: Leg, index: usize) bool {
        return index == 0;
    }

    pub fn isLastNodeIndex(self: Leg, index: usize) bool {
        return self.lastNodeIndex() == index;
    }

    pub fn countryCode(self: Leg, index: usize) []const u8 {
        const at = self.node(index) orelse return "";
        return if (self.admin(at.value.admin_index)) |region| region.value.country_code else "";
    }

    pub fn stateCode(self: Leg, index: usize) []const u8 {
        const at = self.node(index) orelse return "";
        return if (self.admin(at.value.admin_index)) |region| region.value.state_code else "";
    }

    /// The caller reports Valhalla error 212 for a leg lacking two locations.
    pub fn origin(self: Leg) error{MissingLocations}!*const trip.Location {
        if (self.value.location.len < 2) return error.MissingLocations;
        return &self.value.location[0];
    }

    pub fn destination(self: Leg) error{MissingLocations}!*const trip.Location {
        if (self.value.location.len < 2) return error.MissingLocations;
        return &self.value.location[self.value.location.len - 1];
    }

    pub fn length(self: Leg, units: request.Units) error{DeadlineExceeded}!f32 {
        var kilometres: f32 = 0;
        for (self.value.node, 0..) |at, index| {
            if (index % 64 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (at.edge) |edge_value| kilometres += edge_value.length_km;
        }
        return lengthInUnits(kilometres, units);
    }
};

pub const Edge = struct {
    value: *const trip.Edge,
    deadline: io.Deadline = .none,

    pub fn isForkForward(_: Edge, degree: u32) bool {
        return isForkForwardTurn(degree);
    }

    pub fn isForward(_: Edge, degree: u32) bool {
        return isForwardTurn(degree);
    }

    pub fn isWiderForward(_: Edge, degree: u32) bool {
        return isWiderForwardTurn(degree);
    }

    pub fn isStraightest(_: Edge, path: u32, crossing: u32) bool {
        return isStraightestTurn(path, crossing);
    }

    pub fn hasVehicleType(self: Edge) bool {
        return self.value.travel_mode == .kDrive;
    }

    pub fn hasPedestrianType(self: Edge) bool {
        return self.value.travel_mode == .kPedestrian;
    }

    pub fn hasBicycleType(self: Edge) bool {
        return self.value.travel_mode == .kBicycle;
    }

    pub fn hasTransitType(self: Edge) bool {
        return self.value.travel_mode == .kTransit;
    }

    pub fn nameList(self: Edge) []const trip.StreetName {
        return self.value.name;
    }

    pub fn length(self: Edge, units: request.Units) f32 {
        return lengthInUnits(self.value.length_km, units);
    }

    pub fn isUnnamed(self: Edge) bool {
        return self.value.name.len == 0;
    }

    pub fn isRoadUse(self: Edge) bool {
        return self.value.use == .kRoadUse or self.value.use == .kServiceRoadUse;
    }

    pub fn isFootwayUse(self: Edge) bool {
        return self.value.use == .kFootwayUse or self.value.use == .kPedestrianCrossingUse;
    }

    pub fn isRampUse(self: Edge) bool {
        return self.value.use == .kRampUse;
    }

    pub fn isTurnChannelUse(self: Edge) bool {
        return self.value.use == .kTurnChannelUse;
    }

    pub fn isTrackUse(self: Edge) bool {
        return self.value.use == .kTrackUse;
    }

    pub fn isDrivewayUse(self: Edge) bool {
        return self.value.use == .kDrivewayUse;
    }

    pub fn isAlleyUse(self: Edge) bool {
        return self.value.use == .kAlleyUse;
    }

    pub fn isParkingAisleUse(self: Edge) bool {
        return self.value.use == .kParkingAisleUse;
    }

    pub fn isEmergencyAccessUse(self: Edge) bool {
        return self.value.use == .kEmergencyAccessUse;
    }

    pub fn isDriveThruUse(self: Edge) bool {
        return self.value.use == .kDriveThruUse;
    }

    pub fn isCuldesacUse(self: Edge) bool {
        return self.value.use == .kCuldesacUse;
    }

    pub fn isCyclewayUse(self: Edge) bool {
        return self.value.use == .kCyclewayUse;
    }

    pub fn isMountainBikeUse(self: Edge) bool {
        return self.value.use == .kMountainBikeUse;
    }

    pub fn isSidewalkUse(self: Edge) bool {
        return self.value.use == .kSidewalkUse;
    }

    pub fn isPedestrianCrossingUse(self: Edge) bool {
        return self.value.use == .kPedestrianCrossingUse;
    }

    pub fn isElevatorUse(self: Edge) bool {
        return self.value.use == .kElevatorUse;
    }

    pub fn isStepsUse(self: Edge) bool {
        return self.value.use == .kStepsUse;
    }

    pub fn isEscalatorUse(self: Edge) bool {
        return self.value.use == .kEscalatorUse;
    }

    pub fn isPathUse(self: Edge) bool {
        return self.value.use == .kPathUse;
    }

    pub fn isPedestrianUse(self: Edge) bool {
        return self.value.use == .kPedestrianUse;
    }

    pub fn isBridlewayUse(self: Edge) bool {
        return self.value.use == .kBridlewayUse;
    }

    pub fn isRestAreaUse(self: Edge) bool {
        return self.value.use == .kRestAreaUse;
    }

    pub fn isServiceAreaUse(self: Edge) bool {
        return self.value.use == .kServiceAreaUse;
    }

    pub fn isOtherUse(self: Edge) bool {
        return self.value.use == .kOtherUse;
    }

    pub fn isFerryUse(self: Edge) bool {
        return self.value.use == .kFerryUse;
    }

    pub fn isRailFerryUse(self: Edge) bool {
        return self.value.use == .kRailFerryUse;
    }

    pub fn isRailUse(self: Edge) bool {
        return self.value.use == .kRailUse;
    }

    pub fn isBusUse(self: Edge) bool {
        return self.value.use == .kBusUse;
    }

    pub fn isEgressConnectionUse(self: Edge) bool {
        return self.value.use == .kEgressConnectionUse;
    }

    pub fn isPlatformConnectionUse(self: Edge) bool {
        return self.value.use == .kPlatformConnectionUse;
    }

    pub fn isTransitConnectionUse(self: Edge) bool {
        return self.value.use == .kTransitConnectionUse;
    }

    pub fn isConstructionUse(self: Edge) bool {
        return self.value.use == .kConstructionUse;
    }

    pub fn isTransitConnection(self: Edge) bool {
        return self.isEgressConnectionUse() or self.isPlatformConnectionUse() or self.isTransitConnectionUse();
    }

    pub fn isUnnamedWalkway(self: Edge) bool {
        return self.isUnnamed() and self.isFootwayUse();
    }

    pub fn isUnnamedCycleway(self: Edge) bool {
        return self.isUnnamed() and self.isCyclewayUse();
    }

    pub fn isUnnamedMountainBikeTrail(self: Edge) bool {
        return self.isUnnamed() and self.isMountainBikeUse();
    }

    pub fn isHighway(self: Edge) bool {
        return highway(self.value.road_class, self.value.use);
    }

    pub fn isOneway(self: Edge) bool {
        return self.value.traversability == .kForward or self.value.traversability == .kBackward;
    }

    pub fn traversesLevels(self: Edge) bool {
        const levels = self.value.levels;
        return levels.len > 1 or (levels.len == 1 and levels[0].start != levels[0].end);
    }

    pub fn levelRefs(self: Edge, arena: std.mem.Allocator) ![]const []const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        for (self.value.tagged_value, 0..) |tag, index| {
            if (index % 64 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (tag.type == .kLevelRef) try result.append(arena, tag.value);
        }
        if (result.items.len != 0) return result.items;
        for (self.value.tagged_value, 0..) |tag, index| {
            if (index % 64 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (tag.type != .kLevels) continue;
            var decoded = try EncodedLevels.parse(tag.value);
            const range = (try decoded.next(self.deadline)) orelse continue;
            if (range.bounds.first != range.bounds.last or try decoded.next(self.deadline) != null) continue;
            const label = if (decoded.precision == 0)
                try std.fmt.allocPrint(arena, "Level {d:.0}", .{@as(f64, range.bounds.first)})
            else
                try std.fmt.allocPrint(arena, "Level {d:.10}", .{@as(f64, range.bounds.first)});
            try result.append(arena, label);
        }
        return result.items;
    }

    pub fn writeDebug(self: Edge, out: *io.Writer) !void {
        const edge_value = self.value;
        try out.writeAll("name=");
        if (self.isUnnamed()) {
            try out.writeAll("unnamed");
        } else {
            try debug.names(out, edge_value.name, "value", true, self.deadline);
        }
        try debug.field(out, "length", edge_value.length_km);
        try debug.fields(out, edge_value, &.{
            "speed",          "road_class",            "begin_heading", "end_heading", "begin_shape_index", "end_shape_index",
            "traversability", "use",                   "toll",          "unpaved",     "tunnel",            "bridge",
            "roundabout",     "internal_intersection",
        });
        if (edge_value.sign) |sign| {
            inline for (.{
                "exit_numbers",           "exit_onto_streets", "exit_toward_locations",   "exit_names",               "guide_onto_streets",
                "guide_toward_locations", "junction_names",    "guidance_view_junctions", "guidance_view_signboards",
            }) |group| {
                try out.print(" | {s}=", .{group});
                try debug.names(out, @field(sign, group), "text", true, self.deadline);
            }
        }
        try debug.fields(out, edge_value, &.{ "travel_mode", "vehicle_type", "pedestrian_type", "bicycle_type", "transit_type" });
        try debug.field(out, "drive_on_right", !edge_value.drive_on_left);
        try debug.field(out, "surface", edge_value.surface);
        if (edge_value.transit_route_info) |transit| {
            inline for (.{
                "onestop_id",  "block_id",            "trip_id",       "short_name",   "long_name", "headsign", "color", "text_color",
                "description", "operator_onestop_id", "operator_name", "operator_url",
            }) |key| try debug.field(out, "transit_route_info." ++ key, @field(transit, key));
        }
        try debug.fields(out, edge_value, &.{
            "id",              "way_id",   "weighted_grade", "max_upward_grade", "max_downward_grade", "lane_count",  "cycle_lane",
            "bicycle_network", "sidewalk", "density",        "speed_limit",      "truck_speed",        "truck_route",
        });
        if (edge_value.turn_lanes.len != 0) {
            try out.writeAll(" | turn_lanes=");
            try self.writeTurnLanes(out);
        }
    }

    pub fn hasActiveTurnLane(self: Edge) !bool {
        for (self.value.turn_lanes, 0..) |lane, i| {
            if (i % 64 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (lane.state == .kActive) return true;
        }
        return false;
    }

    pub fn hasNonDirectionalTurnLane(self: Edge) !bool {
        for (self.value.turn_lanes, 0..) |lane, i| {
            if (i % 64 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (lane.directions_mask == 0 or lane.directions_mask & lanes.none != 0) return true;
        }
        return false;
    }

    pub fn hasTurnLane(self: Edge, direction: lanes.Mask) !bool {
        for (self.value.turn_lanes, 0..) |lane, i| {
            if (i % 64 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (lane.directions_mask & direction != 0) return true;
        }
        return false;
    }

    pub fn activateTurnLanes(self: Edge, direction: lanes.Mask, remaining_km: f32, current: ManeuverType, next: ManeuverType) !u16 {
        if (direction != lanes.reverse) switch (current) {
            .kUturnLeft => return self.activateTurnLanesFromSide(direction, current, .left, 1),
            .kUturnRight => return self.activateTurnLanesFromSide(direction, current, .right, 1),
            else => {},
        };
        if (remaining_km < 0.402) {
            const side: ?Side = switch (next) {
                .kSlightLeft, .kLeft, .kSharpLeft, .kUturnLeft, .kRampLeft, .kExitLeft, .kStayLeft, .kDestinationLeft, .kMergeLeft => .left,
                .kSlightRight, .kRight, .kSharpRight, .kUturnRight, .kRampRight, .kExitRight, .kStayRight, .kDestinationRight, .kMergeRight => .right,
                .kMerge => if (self.value.drive_on_left) .right else .left,
                .kDestination => if (self.value.drive_on_left) .left else .right,
                else => null,
            };
            if (side) |favoured| return self.activateTurnLanesFromSide(direction, current, favoured, 1);
        }
        return self.activateTurnLanesFromSide(direction, current, .left, std.math.maxInt(u16));
    }

    pub const Side = enum { left, right };

    pub fn activateTurnLanesFromSide(self: Edge, direction: lanes.Mask, current: ManeuverType, side: Side, limit: u16) !u16 {
        if (try self.hasNonDirectionalTurnLane()) return 0;
        const lanes_list = self.value.turn_lanes;
        const uturn: ManeuverType = if (side == .left) .kUturnLeft else .kUturnRight;
        var active: u16 = 0;
        for (0..lanes_list.len) |i| {
            if (i % 64 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            const lane = &lanes_list[if (side == .left) i else lanes_list.len - i - 1];
            if (lane.directions_mask & direction == 0) continue;
            if (active < limit) {
                lane.state = .kActive;
                active += 1;
            } else if (current != uturn) {
                lane.state = .kValid;
            }
            lane.active_direction = direction;
        }
        return active;
    }

    pub fn writeTurnLanes(self: Edge, out: *io.Writer) !void {
        if (self.value.turn_lanes.len == 0) return;
        try out.writeAll("[ ");
        for (self.value.turn_lanes, 0..) |lane, i| {
            if (i % 64 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (i != 0) try out.writeAll(" | ");
            switch (lane.directions_mask) {
                0 => try out.writeAll("empty"),
                lanes.none => try out.writeAll("none"),
                else => {
                    var separated = false;
                    if (!self.value.drive_on_left) try writeLaneIndication(out, lane, lanes.reverse, "reverse", &separated);
                    for (lane_indications) |indication|
                        try writeLaneIndication(out, lane, indication.mask, indication.text, &separated);
                    if (self.value.drive_on_left) try writeLaneIndication(out, lane, lanes.reverse, "reverse", &separated);
                },
            }
            switch (lane.state) {
                .kActive => try out.writeAll(" ACTIVE"),
                .kValid => try out.writeAll(" VALID"),
                else => {},
            }
        }
        try out.writeAll(" ]");
    }
};

pub const IntersectingEdge = struct {
    value: *const trip.IntersectingEdge,

    pub fn writeDebug(self: IntersectingEdge, out: *io.Writer) io.Writer.Error!void {
        try out.print("begin_heading={d}", .{self.value.begin_heading});
        try debug.fields(out, self.value, &.{
            "prev_name_consistency", "curr_name_consistency", "driveability", "cyclability", "walkability", "use", "road_class", "lane_count",
        });
    }

    pub fn traversability(self: IntersectingEdge, mode: trip.TravelMode) trip.Traversability {
        return switch (mode) {
            .kDrive => self.value.driveability,
            .kBicycle => self.value.cyclability,
            else => self.value.walkability,
        };
    }

    pub fn isTraversable(self: IntersectingEdge, mode: trip.TravelMode) bool {
        return self.traversability(mode) != .kNone;
    }

    pub fn isTraversableOutbound(self: IntersectingEdge, mode: trip.TravelMode) bool {
        const access = self.traversability(mode);
        return access == .kForward or access == .kBoth;
    }

    pub fn turnDegree(self: IntersectingEdge, heading: u32) u32 {
        return turn.degree(heading, self.value.begin_heading);
    }

    pub fn isHighway(self: IntersectingEdge) bool {
        return highway(self.value.road_class, self.value.use);
    }
};

pub const Node = struct {
    value: *const trip.Node,
    deadline: io.Deadline = .none,

    pub fn edge(self: Node) ?Edge {
        return if (self.value.edge) |*value| .{ .value = value, .deadline = self.deadline } else null;
    }

    pub fn intersection(self: Node, index: usize) ?IntersectingEdge {
        if (index >= self.value.intersecting_edge.len) return null;
        return .{ .value = &self.value.intersecting_edge[index] };
    }

    pub fn writeDebug(self: Node, out: *io.Writer) io.Writer.Error!void {
        try out.print("elapsed_time={d:.6}", .{self.elapsedTime()});
        try debug.fields(out, self.value, &.{ "admin_index", "type", "fork" });
        if (self.value.transit_platform_info) |platform| {
            inline for (.{ "type", "onestop_id", "name", "arrival_date_time", "departure_date_time" }) |key|
                try debug.field(out, "transit_platform_info." ++ key, @field(platform, key));
            try debug.field(out, "transit_platform_info.assumed_schedule()", platform.assumed_schedule);
            inline for (.{ "station_onestop_id", "station_name" }) |key|
                try debug.field(out, "transit_platform_info." ++ key, @field(platform, key));
        }
        try debug.field(out, "time_zone", self.value.time_zone);
    }

    pub fn elapsedTime(self: Node) f64 {
        const cost = self.value.cost orelse return 0;
        return if (cost.elapsed_cost) |elapsed| elapsed.seconds else 0;
    }

    pub fn hasIntersectingEdges(self: Node) bool {
        return self.value.intersecting_edge.len != 0;
    }

    pub fn hasIntersectingEdgeNameConsistency(self: Node) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.value.prev_name_consistency or cross.value.curr_name_consistency) return true;
        }
        return false;
    }

    pub fn hasIntersectingEdgeCurrNameConsistency(self: Node) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.value.curr_name_consistency) return true;
        }
        return false;
    }

    pub fn hasNonBackwardTraversableSameNameRampIntersectingEdge(self: Node, heading: u32, mode: trip.TravelMode) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.value.use == .kRampUse and cross.isTraversable(mode) and
                (cross.value.prev_name_consistency or cross.value.curr_name_consistency) and
                !isBackward(cross.turnDegree(heading))) return true;
        }
        return false;
    }

    pub fn countIntersectingEdges(self: Node, heading: u32, mode: trip.TravelMode) !IntersectingEdgeCounts {
        var counts: IntersectingEdgeCounts = .{};
        const path = turn.degree(heading, if (self.edge()) |edge_view| edge_view.value.begin_heading else 0);
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            const degree = cross.turnDegree(heading);
            const right = if (path > 180) degree > path or degree < 180 else degree > path and degree < 180;
            const left = if (path > 180) degree < path and degree > 180 else degree < path or degree > 180;
            const outbound = cross.isTraversableOutbound(mode);
            if (right) counts.right.record(outbound, turn.degree(path, degree) <= 40);
            if (left) counts.left.record(outbound, turn.degree(degree, path) <= 40);
        }
        return counts;
    }

    pub fn hasForwardIntersectingEdge(self: Node, heading: u32) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (isForwardTurn(cross.turnDegree(heading))) return true;
        }
        return false;
    }

    pub fn hasForwardTraversableIntersectingEdge(self: Node, heading: u32, mode: trip.TravelMode) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (isForwardTurn(cross.turnDegree(heading)) and cross.isTraversableOutbound(mode)) return true;
        }
        return false;
    }

    pub fn hasRoadForkTraversableIntersectingEdge(self: Node, heading: u32, mode: trip.TravelMode, allow_service_road: bool) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (isForkForwardTurn(cross.turnDegree(heading)) and cross.isTraversableOutbound(mode) and
                cross.value.prev_name_consistency and isForkRoad(cross.value.use) and
                (allow_service_road or cross.value.road_class != .kServiceOther)) return true;
        }
        return false;
    }

    pub fn hasForwardTraversableSignificantRoadClassEdge(self: Node, heading: u32, mode: trip.TravelMode, path_class: trip.RoadClass) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (isForwardTurn(cross.turnDegree(heading)) and cross.isTraversableOutbound(mode) and
                significantRoadClass(cross.value.road_class, path_class)) return true;
        }
        return false;
    }

    pub fn hasForwardTraversableUseEdge(self: Node, heading: u32, mode: trip.TravelMode, use: trip.Use) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.value.use == use and isForwardTurn(cross.turnDegree(heading)) and cross.isTraversableOutbound(mode)) return true;
        }
        return false;
    }

    pub fn hasSimilarStraightSignificantRoadClassEdge(self: Node, path: u32, heading: u32, mode: trip.TravelMode, path_class: trip.RoadClass) !bool {
        if (!isRelativeStraight(path)) return false;
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (similarStraight(path, cross.turnDegree(heading)) and cross.isTraversableOutbound(mode) and
                significantRoadClass(cross.value.road_class, path_class)) return true;
        }
        return false;
    }

    pub fn hasSimilarStraightNonRampOrSameNameRampEdge(self: Node, path: u32, heading: u32, mode: trip.TravelMode) !bool {
        if (!isRelativeStraight(path)) return false;
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (similarStraight(path, cross.turnDegree(heading)) and cross.isTraversableOutbound(mode) and
                (cross.value.use != .kRampUse or cross.value.prev_name_consistency)) return true;
        }
        return false;
    }

    pub fn hasOnlyForwardTraversableRoadClassEdges(self: Node, heading: u32, mode: trip.TravelMode, path_class: trip.RoadClass) !bool {
        if (!self.hasIntersectingEdges()) return false;
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (!isForkRoad(cross.value.use) or @backingInt(path_class) < @backingInt(cross.value.road_class) or
                !isForkForwardTurn(cross.turnDegree(heading)) or !cross.isTraversableOutbound(mode)) return false;
        }
        return true;
    }

    pub fn hasWiderForwardTraversableIntersectingEdge(self: Node, heading: u32, mode: trip.TravelMode) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (isWiderForwardTurn(cross.turnDegree(heading)) and cross.isTraversableOutbound(mode)) return true;
        }
        return false;
    }

    pub fn hasWiderForwardTraversableHighwayEdge(self: Node, heading: u32, mode: trip.TravelMode) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.isHighway() and isWiderForwardTurn(cross.turnDegree(heading)) and cross.isTraversableOutbound(mode)) return true;
        }
        return false;
    }

    pub fn hasTraversableIntersectingEdge(self: Node, mode: trip.TravelMode) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.isTraversable(mode)) return true;
        }
        return false;
    }

    pub fn hasTraversableOutboundIntersectingEdge(self: Node, mode: trip.TravelMode) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.isTraversableOutbound(mode)) return true;
        }
        return false;
    }

    pub fn hasTraversableExcludeUseEdge(self: Node, mode: trip.TravelMode, excluded: trip.Use) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.value.use != excluded and cross.isTraversableOutbound(mode)) return true;
        }
        return false;
    }

    pub fn hasForwardTraversableExcludeUseEdge(self: Node, heading: u32, mode: trip.TravelMode, excluded: trip.Use) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.value.use != excluded and isForwardTurn(cross.turnDegree(heading)) and cross.isTraversableOutbound(mode)) return true;
        }
        return false;
    }

    pub fn hasSpecifiedTurnEdge(self: Node, kind: turn.Type, heading: u32, mode: trip.TravelMode) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.isTraversableOutbound(mode) and turn.classify(cross.turnDegree(heading)) == kind) return true;
        }
        return false;
    }

    pub fn hasSpecifiedRoadClassEdge(self: Node, class: trip.RoadClass) !bool {
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (cross.value.road_class == class) return true;
        }
        return false;
    }

    pub const Straightest = struct { degree: u32 = 180, use: ?trip.Use = null };

    /// Null mode includes every intersection. Ties retain the first edge.
    pub fn straightestIntersectingEdge(self: Node, heading: u32, mode: ?trip.TravelMode) !Straightest {
        var best: Straightest = .{};
        var closest: u32 = 180;
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (mode) |travel| if (!cross.isTraversableOutbound(travel)) continue;
            const degree = cross.turnDegree(heading);
            const delta = turn.delta(degree, 0);
            if (delta >= closest) continue;
            best = .{ .degree = degree, .use = cross.value.use };
            closest = delta;
        }
        return best;
    }

    pub fn isStraightestTraversableIntersectingEdgeReversed(self: Node, heading: u32, mode: trip.TravelMode) !bool {
        return isBackward((try self.straightestIntersectingEdge(heading, mode)).degree);
    }

    pub fn rightMostTurnDegree(self: Node, path: u32, heading: u32, mode: trip.TravelMode) !u32 {
        return self.closestTurnDegree(path, heading, mode, 90);
    }

    pub fn leftMostTurnDegree(self: Node, path: u32, heading: u32, mode: trip.TravelMode) !u32 {
        return self.closestTurnDegree(path, heading, mode, 270);
    }

    fn closestTurnDegree(self: Node, path: u32, heading: u32, mode: trip.TravelMode, target: u32) !u32 {
        var best = path;
        var closest = turn.delta(path, target);
        var edges = self.intersections();
        while (try edges.next()) |cross| {
            if (!cross.isTraversableOutbound(mode)) continue;
            const degree = cross.turnDegree(heading);
            const delta = turn.delta(degree, target);
            if (delta >= closest) continue;
            best = degree;
            closest = delta;
        }
        return best;
    }

    const Intersections = struct {
        node: Node,
        index: usize = 0,

        fn next(self: *Intersections) error{DeadlineExceeded}!?IntersectingEdge {
            const current = self.node.intersection(self.index) orelse return null;
            if (self.index % 64 == 0 and self.node.deadline.expired()) return error.DeadlineExceeded;
            self.index += 1;
            return current;
        }
    };

    fn intersections(self: Node) Intersections {
        return .{ .node = self };
    }

    pub fn isStreetIntersection(self: Node) bool {
        return self.value.type == .kStreetIntersection;
    }

    pub fn isGate(self: Node) bool {
        return self.value.type == .kGate;
    }

    pub fn isBollard(self: Node) bool {
        return self.value.type == .kBollard;
    }

    pub fn isTollBooth(self: Node) bool {
        return self.value.type == .kTollBooth;
    }

    pub fn isTransitEgress(self: Node) bool {
        return self.value.type == .kTransitEgress;
    }

    pub fn isTransitStation(self: Node) bool {
        return self.value.type == .kTransitStation;
    }

    pub fn isTransitPlatform(self: Node) bool {
        return self.value.type == .kTransitPlatform;
    }

    pub fn isBikeShare(self: Node) bool {
        return self.value.type == .kBikeShare;
    }

    pub fn isParking(self: Node) bool {
        return self.value.type == .kParking;
    }

    pub fn isMotorwayJunction(self: Node) bool {
        return self.value.type == .kMotorwayJunction;
    }

    pub fn isBorderControl(self: Node) bool {
        return self.value.type == .kBorderControl;
    }

    pub fn isTollGantry(self: Node) bool {
        return self.value.type == .kTollGantry;
    }

    pub fn isSumpBuster(self: Node) bool {
        return self.value.type == .kSumpBuster;
    }

    pub fn isBuildingEntrance(self: Node) bool {
        return self.value.type == .kBuildingEntrance;
    }

    pub fn isElevator(self: Node) bool {
        return self.value.type == .kElevator;
    }
};

pub const Admin = struct {
    value: *const trip.Admin,

    pub fn writeDebug(self: Admin, out: *io.Writer) io.Writer.Error!void {
        const a = self.value;
        try out.print("country_code={s} | country_text={s} | state_code={s} | state_text={s}", .{
            a.country_code, a.country_text, a.state_code, a.state_text,
        });
    }
};

fn highway(class: trip.RoadClass, use: trip.Use) bool {
    return class == .kMotorway and use != .kRampUse and use != .kTurnChannelUse;
}

pub fn lengthInUnits(kilometres: f32, units: request.Units) f32 {
    return if (units == .miles) kilometres * mile_per_km else kilometres;
}

pub const IntersectingEdgeCounts = struct {
    right: Side = .{},
    left: Side = .{},

    pub const Side = struct {
        all: u32 = 0,
        similar: u32 = 0,
        traversable_outbound: u32 = 0,
        similar_traversable_outbound: u32 = 0,

        fn record(self: *Side, outbound: bool, similar: bool) void {
            self.all += 1;
            self.similar += @intFromBool(similar);
            self.traversable_outbound += @intFromBool(outbound);
            self.similar_traversable_outbound += @intFromBool(outbound and similar);
        }
    };
};

fn isForkForwardTurn(degree: u32) bool {
    return degree > 339 or degree < 21;
}

fn isRelativeStraight(degree: u32) bool {
    return degree > 329 or degree < 31;
}

fn isForwardTurn(degree: u32) bool {
    return degree > 314 or degree < 46;
}

fn isWiderForwardTurn(degree: u32) bool {
    return degree > 304 or degree < 56;
}

fn isStraightestTurn(path: u32, crossing: u32) bool {
    if (!isWiderForwardTurn(path)) return false;
    return turn.delta(path, 0) <= turn.delta(crossing, 0) + 10;
}

fn isBackward(degree: u32) bool {
    return degree > 124 and degree < 236;
}

fn similarStraight(path: u32, cross: u32) bool {
    return isRelativeStraight(cross) and turn.delta(path, cross) <= 30;
}

fn significantRoadClass(cross: trip.RoadClass, path: trip.RoadClass) bool {
    return @as(i64, @backingInt(cross)) - @backingInt(path) <= 2;
}

fn isForkRoad(use: trip.Use) bool {
    return switch (use) {
        .kRampUse, .kTurnChannelUse, .kFerryUse, .kRailFerryUse => false,
        else => true,
    };
}

const lane_indications = [_]struct { mask: lanes.Mask, text: []const u8 }{
    .{ .mask = lanes.sharp_left, .text = "sharp_left" },
    .{ .mask = lanes.left, .text = "left" },
    .{ .mask = lanes.slight_left, .text = "slight_left" },
    .{ .mask = lanes.merge_to_left, .text = "merge_to_left" },
    .{ .mask = lanes.through, .text = "through" },
    .{ .mask = lanes.merge_to_right, .text = "merge_to_right" },
    .{ .mask = lanes.slight_right, .text = "slight_right" },
    .{ .mask = lanes.right, .text = "right" },
    .{ .mask = lanes.sharp_right, .text = "sharp_right" },
};

fn writeLaneIndication(out: *io.Writer, lane: trip.TurnLane, mask: lanes.Mask, text: []const u8, separated: *bool) io.Writer.Error!void {
    if (lane.directions_mask & mask == 0) return;
    if (separated.*) try out.writeByte(';');
    separated.* = true;
    const selected = lane.state != .kInvalid and lane.active_direction == mask;
    if (selected) try out.writeByte('*');
    try out.writeAll(text);
    if (selected) try out.writeByte('*');
}
