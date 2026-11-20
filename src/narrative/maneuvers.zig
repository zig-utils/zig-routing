// Ported from src/odin/maneuversbuilder.cc (Valhalla 3.9.3).
// Transit routing supplies scheduled transit maneuvers in P9.06. Bike-share actions remain kNoneAction until P9.07 supplies station data.
const trip = @import("../api/trip.zig");
const directions = @import("../api/directions.zig");
const turn = @import("../graph/turn.zig");
const enhanced = @import("enhanced.zig");
const guidance_views = @import("guidance_views.zig");
const junctions = @import("junctions.zig");
const maneuver = @import("maneuver.zig");
const postprocess = @import("postprocess.zig");
const signs = @import("signs.zig");
const turn_lanes = @import("turn_lanes.zig");

// Ported from ManeuversBuilder::DetermineCardinalDirection.
pub fn cardinalDirection(heading: u32) directions.CardinalDirection {
    return switch (heading) {
        24...66 => .kNorthEast,
        67...113 => .kEast,
        114...156 => .kSouthEast,
        157...203 => .kSouth,
        204...246 => .kSouthWest,
        247...293 => .kWest,
        294...336 => .kNorthWest,
        else => .kNorth,
    };
}

// Ported from ManeuversBuilder::DetermineRelativeDirection(uint32_t).
pub fn relativeDirection(degree: u32) maneuver.RelativeDirection {
    return switch (degree) {
        31...159 => .right,
        160...200 => .reverse,
        201...329 => .left,
        else => .keep_straight,
    };
}

// Ported from ManeuversBuilder::DetermineRelativeDirection(Maneuver&).
fn directionAt(value: *const maneuver.Maneuver, node: enhanced.Node, previous: enhanced.Edge, current: enhanced.Edge) !maneuver.RelativeDirection {
    const direction = relativeDirection(value.turn_degree);
    const heading = previous.value.end_heading;
    const mode = previous.value.travel_mode;
    const counts = try node.countIntersectingEdges(heading, mode);
    const kind = turn.classify(value.turn_degree);
    switch (direction) {
        .keep_straight => {
            const left = counts.left;
            const right = counts.right;
            if (left.similar_traversable_outbound > 0 and right.similar_traversable_outbound == 0) return .keep_right;
            if (right.similar_traversable_outbound > 0 and left.similar_traversable_outbound == 0) return .keep_left;
            if ((left.traversable_outbound > 0) != (right.traversable_outbound > 0)) {
                const crossing = try node.straightestIntersectingEdge(heading, mode);
                if (!current.isStraightest(value.turn_degree, crossing.degree) or
                    (value.turn_channel and kind != .straight) or value.fork)
                {
                    return if (left.traversable_outbound > 0) .keep_right else .keep_left;
                }
            }
        },
        .left => if (kind == .slight_left and try node.hasSpecifiedTurnEdge(.left, heading, value.travel_mode)) return .keep_left,
        .right => if (kind == .slight_right and try node.hasSpecifiedTurnEdge(.right, heading, value.travel_mode)) return .keep_right,
        else => {},
    }
    return direction;
}

pub const TurnContext = junctions.Context;

// Ported from ManeuversBuilder::SetSimpleDirectionalManeuverType.
pub fn simpleDirectionalType(value: *const maneuver.Maneuver, context: ?TurnContext) !directions.ManeuverType {
    const degree = value.turn_degree;
    const kind = turn.classify(degree);
    const base: directions.ManeuverType = switch (kind) {
        .straight => .kContinue,
        .slight_right => .kSlightRight,
        .right => .kRight,
        .sharp_right => .kSharpRight,
        .reverse => junctions.reverseType(value, if (context) |at| !at.current.value.drive_on_left else value.drive_on_right),
        .sharp_left => .kSharpLeft,
        .left => .kLeft,
        .slight_left => .kSlightLeft,
    };
    const at = context orelse return base;
    const heading = at.previous.value.end_heading;
    const incoming_mode = at.previous.value.travel_mode;
    const incoming_class = at.previous.value.road_class;
    const mode = value.travel_mode;
    switch (kind) {
        .straight => {
            const direction = value.begin_relative_direction;
            if (at.current.value.internal_intersection and !at.current.isTurnChannelUse()) {
                return switch (direction) {
                    .left, .keep_left => .kSlightLeft,
                    .right, .keep_right => .kSlightRight,
                    else => base,
                };
            }
            if (direction != .keep_right and direction != .keep_left) return base;
            const slight: directions.ManeuverType = if (direction == .keep_right) .kSlightRight else .kSlightLeft;
            if (at.current.isTurnChannelUse()) return slight;
            if (at.current.isHighway() and value.length_km < short_continue_threshold) return base;
            if (!try at.node.hasSimilarStraightSignificantRoadClassEdge(degree, heading, incoming_mode, incoming_class)) return base;
            if (!at.current.isHighway() and !try at.node.hasForwardTraversableUseEdge(heading, incoming_mode, .kRampUse)) return slight;
            if (try at.node.hasSimilarStraightNonRampOrSameNameRampEdge(degree, heading, incoming_mode))
                return junctions.forkType(direction);
        },
        .slight_right, .slight_left => {
            if (value.begin_relative_direction != .keep_straight or
                try at.node.hasForwardTraversableSignificantRoadClassEdge(heading, incoming_mode, incoming_class)) return base;
            const counts = try at.node.countIntersectingEdges(heading, incoming_mode);
            const outer = if (kind == .slight_right) counts.right else counts.left;
            if (outer.all > 0 or (counts.left.all == 0 and counts.right.all == 0)) return .kContinue;
        },
        .right => {
            const rightmost = try at.node.rightMostTurnDegree(degree, heading, mode);
            if (degree < rightmost and !try at.node.hasSpecifiedTurnEdge(.slight_right, heading, mode)) return .kSlightRight;
            if (degree > rightmost and !try at.node.hasSpecifiedTurnEdge(.sharp_right, heading, mode)) return .kSharpRight;
        },
        .left => {
            const leftmost = try at.node.leftMostTurnDegree(degree, heading, mode);
            if (degree > leftmost and !try at.node.hasSpecifiedTurnEdge(.slight_left, heading, mode)) return .kSlightLeft;
            if (degree < leftmost and !try at.node.hasSpecifiedTurnEdge(.sharp_left, heading, mode)) return .kSharpLeft;
        },
        else => {},
    }
    return base;
}

const short_continue_threshold: f32 = 0.6;
const max_internal_length_km: f32 = 0.032;
const small_end_ramp_fork_threshold: f32 = 0.125;

const std = @import("std");
const VerbalStyle = @import("verbal_text.zig").Style;
const io = @import("../infra/io.zig");
const Maneuver = maneuver.Maneuver;

// Ported from ManeuversBuilder::Build and ConfirmManeuverTypeAssignment.
pub fn build(arena: std.mem.Allocator, path: *const trip.TripLeg, deadline: io.Deadline) ![]const Maneuver {
    return buildWithOptions(arena, path, .{}, deadline);
}

pub const Options = struct {
    roundabout_exits: bool = true,
};

pub const setVerbalMultiCueFlags = postprocess.setVerbalMultiCueFlags;

pub fn buildWithOptions(arena: std.mem.Allocator, path: *const trip.TripLeg, options: Options, deadline: io.Deadline) ![]const Maneuver {
    return (try buildAnnotated(arena, path, options, deadline)).maneuvers;
}

pub const BuildResult = struct {
    trip_leg: trip.TripLeg,
    maneuvers: []Maneuver,
};

/// The returned leg carries lane states and any lanes inherited by moved internal edges.
pub fn buildAnnotated(arena: std.mem.Allocator, path: *const trip.TripLeg, options: Options, deadline: io.Deadline) !BuildResult {
    const leg: enhanced.Leg = .{ .value = path, .deadline = deadline };
    var copied_nodes: ?[]trip.Node = null;
    const builder: Builder = .{ .leg = leg, .arena = arena, .copied_nodes = &copied_nodes };
    var result = try builder.combine(try builder.produce());
    try signs.countAndSort(arena, result, deadline);
    for (result) |*value| {
        try builder.check();
        try builder.setManeuverType(value, false);
    }
    try builder.setTraversableOutboundIntersectingEdgeFlags(result);
    result = try builder.processRoundabouts(result, options.roundabout_exits);
    try builder.setToStayOnAttribute(result);
    try builder.enhanceSignlessInterchanges(result);
    try guidance_views.process(arena, leg, result);
    try builder.updateManeuverPlacementForInternalIntersectionTurns(result);
    result = try builder.collapseSmallEndRampFork(result);
    result = try builder.collapseMergeManeuvers(result);
    var annotated = path.*;
    if (copied_nodes) |nodes| annotated.node = nodes;
    try turn_lanes.process(.{ .value = &annotated, .deadline = deadline }, result);
    try postprocess.attachLandmarks(arena, leg, result);
    try postprocess.markLongStreetNames(result, deadline);
    return .{ .trip_leg = annotated, .maneuvers = result };
}

const Builder = struct {
    leg: enhanced.Leg,
    arena: std.mem.Allocator,
    copied_nodes: ?*?[]trip.Node = null,

    fn check(self: Builder) error{DeadlineExceeded}!void {
        if (self.leg.deadline.expired()) return error.DeadlineExceeded;
    }

    fn context(self: Builder, index: usize) error{InvalidTripLeg}!TurnContext {
        return .{
            .node = self.leg.node(index) orelse return error.InvalidTripLeg,
            .previous = self.leg.prevEdge(index, 1) orelse return error.InvalidTripLeg,
            .current = self.leg.currEdge(index) orelse return error.InvalidTripLeg,
        };
    }

    // Ported from ManeuversBuilder::Produce.
    fn produce(self: Builder) ![]Maneuver {
        try self.check();
        const end = self.leg.lastNodeIndex() orelse return error.MissingNodes;
        if (end == 0) return error.SingleNode;
        if (end >= std.math.maxInt(u32)) return error.InvalidTripLeg;
        _ = try self.leg.origin();
        const destination = try self.leg.destination();
        for (0..end) |index| {
            try self.check();
            const edge = self.leg.currEdge(index) orelse return error.InvalidTripLeg;
            try requireSupportedEdge(edge);
        }
        const values = try self.arena.alloc(Maneuver, end + 1);
        var first = end;
        values[first] = try self.createDestinationManeuver(end, destination.side_of_street);
        first -= 1;
        values[first] = try self.initializeManeuver(end);
        var index = end - 1;
        while (index != 0) : (index -= 1) {
            try self.check();
            const value = &values[first];
            const at = try self.context(index);
            if (at.current.value.pedestrian_type == .kBlind) try self.recordBlindIntersection(value, at.node);
            if (try self.canManeuverIncludePreviousEdge(value, index, at)) {
                try self.updateManeuver(value, at.previous, index);
            } else {
                try self.finalizeManeuver(value, index);
                first -= 1;
                values[first] = try self.initializeManeuver(index);
            }
        }
        try self.createStartManeuver(&values[first]);
        return values[first..];
    }

    // Ported from ManeuversBuilder::CreateDestinationManeuver.
    fn createDestinationManeuver(self: Builder, index: usize, side: trip.SideOfStreet) !Maneuver {
        const previous = self.leg.prevEdge(index, 1) orelse return error.InvalidTripLeg;
        const shape_index = previous.value.end_shape_index;
        var value: Maneuver = .{
            .type = switch (side) {
                .kLeft => .kDestinationLeft,
                .kRight => .kDestinationRight,
                else => .kDestination,
            },
            .begin_node_index = @intCast(index),
            .end_node_index = @intCast(index),
            .begin_shape_index = shape_index,
            .end_shape_index = shape_index,
            .verbal_style = VerbalStyle.forAdmin(self.leg.countryCode(index), self.leg.stateCode(index)),
        };
        copyTravel(&value, previous);
        return value;
    }

    // Ported from ManeuversBuilder::CreateStartManeuver.
    fn createStartManeuver(self: Builder, value: *Maneuver) !void {
        value.type = switch ((try self.leg.origin()).side_of_street) {
            .kLeft => .kStartLeft,
            .kRight => .kStartRight,
            else => .kStart,
        };
        const first = self.leg.currEdge(0) orelse return error.InvalidTripLeg;
        if (first.isStepsUse() or first.isEscalatorUse() or first.traversesLevels()) value.type = .kNone;
        try self.finalizeManeuver(value, 0);
    }

    // Ported from ManeuversBuilder::InitializeManeuver.
    fn initializeManeuver(self: Builder, index: usize) !Maneuver {
        const previous = self.leg.prevEdge(index, 1) orelse return error.InvalidTripLeg;
        const roundabout = inRoundabout(previous);
        var value: Maneuver = .{
            .end_heading = previous.value.end_heading,
            .end_node_index = @intCast(index),
            .end_shape_index = previous.value.end_shape_index,
            .drive_on_right = !previous.value.drive_on_left,
            .turn_channel = previous.isTurnChannelUse(),
            .ramp = previous.isRampUse(),
            .ferry = previous.isFerryUse(),
            .rail_ferry = previous.isRailFerryUse(),
            .elevator = previous.isElevatorUse(),
            .indoor_steps = previous.isStepsUse() and previous.value.indoor,
            .steps = previous.isStepsUse() and (previous.traversesLevels() or previous.value.length_km >= 0.003 or previous.value.pedestrian_type == .kBlind),
            .escalator = previous.isEscalatorUse(),
            .has_level_changes = previous.traversesLevels(),
            .roundabout = roundabout,
            .roundabout_exit_count = @intFromBool(roundabout),
            .internal_intersection = previous.value.internal_intersection and index != 1 and !self.leg.isLastNodeIndex(index),
            .trail_type = trailType(previous),
        };
        const next_edge = self.leg.currEdge(index);
        if (next_edge) |edge| value.end_level_ref = try self.endLevelRef(edge);
        if (previous.isTransitConnection()) {
            value.transit_connection = true;
            value.type = if (previous.isPlatformConnectionUse() and next_edge != null and next_edge.?.value.travel_mode == .kTransit)
                .kTransitConnectionStart
            else
                .kTransitConnectionDestination;
            const node = self.leg.node(index) orelse return error.InvalidTripLeg;
            value.transit_connection_platform_info = node.value.transit_platform_info orelse .{};
        }
        copyTravel(&value, previous);
        if (value.pedestrian_type == .kBlind) {
            value.bridge = previous.value.bridge;
            value.tunnel = previous.value.tunnel;
        }
        try self.updateManeuver(&value, previous, index);
        return value;
    }

    // Ported from ManeuversBuilder::UpdateManeuver and GetSpeed.
    fn updateManeuver(self: Builder, value: *Maneuver, previous: enhanced.Edge, index: usize) !void {
        const edge = previous.value;
        const entry_direction = if (self.leg.prevEdge(index, 2)) |earlier|
            relativeDirection(turn.degree(earlier.value.end_heading, edge.begin_heading))
        else
            .keep_straight;
        const usable_internal_name = value.internal_intersection and
            ((!edge.drive_on_left and entry_direction == .left) or (edge.drive_on_left and entry_direction == .right));
        if ((value.street_names.len == 0 and !value.internal_intersection) or usable_internal_name) {
            value.street_names = previous.nameList();
            value.name_style = self.nameStyle(index);
        }
        value.internal_right_turn_count += @intFromBool(entry_direction == .right);
        value.internal_left_turn_count += @intFromBool(entry_direction == .left);
        value.length_km += edge.length_km;
        value.basic_time += basicTime(edge, value.travel_mode);
        value.portions_toll = value.portions_toll or edge.toll;
        value.portions_unpaved = value.portions_unpaved or edge.unpaved;
        value.portions_highway = value.portions_highway or previous.isHighway();
        value.has_time_restrictions = value.has_time_restrictions or edge.has_time_restrictions;
        if (inRoundabout(previous)) {
            const node = self.leg.node(index) orelse return error.InvalidTripLeg;
            const mode = if (edge.travel_mode == .kBicycle and previous.isRoadUse()) .kDrive else edge.travel_mode;
            const exits = try node.countIntersectingEdges(edge.end_heading, mode);
            value.roundabout_exit_count += if (edge.drive_on_left) exits.left.traversable_outbound else exits.right.traversable_outbound;
        }
        if (edge.sign) |sign| {
            inline for (.{ "exit_numbers", "exit_onto_streets", "exit_toward_locations", "exit_names" }) |key|
                @field(value.signs, key) = try self.addSigns(@field(value.signs, key), @field(sign, key));
        }
    }

    // Ported from ManeuversBuilder::FinalizeManeuver.
    fn finalizeManeuver(self: Builder, value: *Maneuver, index: usize) !void {
        const node = self.leg.node(index) orelse return error.InvalidTripLeg;
        const current = node.edge() orelse return error.InvalidTripLeg;
        const end = self.leg.node(value.end_node_index) orelse return error.InvalidTripLeg;
        value.begin_heading = current.value.begin_heading;
        value.begin_cardinal_direction = cardinalDirection(value.begin_heading);
        value.begin_node_index = @intCast(index);
        value.begin_shape_index = current.value.begin_shape_index;
        value.verbal_style = VerbalStyle.forAdmin(self.leg.countryCode(index), self.leg.stateCode(index));
        value.time = end.elapsedTime() - node.elapsedTime();
        if (node.isElevator()) {
            value.elevator = true;
            value.node_type = node.value.type;
            const refs = try current.levelRefs(self.arena);
            if (refs.len != 0) value.end_level_ref = if (refs.len == 1) refs[0] else "";
        }
        if (self.leg.prevEdge(index, 1)) |previous| {
            if (node.isBuildingEntrance()) {
                value.building_enter = current.value.indoor and !previous.value.indoor;
                value.building_exit = !current.value.indoor and previous.value.indoor;
            }
            value.turn_degree = turn.degree(previous.value.end_heading, value.begin_heading);
            value.begin_relative_direction = try directionAt(value, node, previous, current);
            value.pedestrian_crossing = current.isPedestrianCrossingUse() and previous.isFootwayUse();
            if (value.type == .kTransitConnectionStart and previous.value.travel_mode == .kTransit) value.type = .kTransitConnectionTransfer;
        }
        value.begin_intersecting_edge_name_consistency = try node.hasIntersectingEdgeNameConsistency();
        if (!current.isHighway() and !current.value.internal_intersection and current.nameList().len > 1) {
            const common = try self.commonBaseNames(current.nameList(), self.nameStyle(index), value.street_names, value.name_style);
            if (common.len < current.nameList().len) value.begin_street_names = current.nameList();
        }
        if (current.value.sign) |sign| {
            value.signs.guide_onto_streets = sign.guide_onto_streets;
            value.signs.guide_toward_locations = sign.guide_toward_locations;
            value.signs.junction_names = sign.junction_names;
        }
        try self.setManeuverType(value, true);
    }

    // Ported from ManeuversBuilder::SetManeuverType.
    fn setManeuverType(self: Builder, value: *Maneuver, none_type_allowed: bool) !void {
        if (value.type != .kNone) return;
        if (value.begin_node_index == 0) {
            value.type = facilityType(value, null) orelse try simpleDirectionalType(value, null);
            return;
        }
        const at = try self.context(value.begin_node_index);
        if (value.roundabout) {
            value.type = .kRoundaboutEnter;
        } else if (inRoundabout(at.previous)) {
            value.type = .kRoundaboutExit;
        } else if (value.fork) {
            value.type = junctions.forkType(value.begin_relative_direction);
        } else if (none_type_allowed and (value.internal_intersection or value.turn_channel)) {
            return;
        } else if (value.ramp) {
            const direction = value.begin_relative_direction;
            const exit = at.previous.isHighway() or value.signs.exit_numbers.len != 0 or
                (!at.previous.isRampUse() and (direction == .keep_left or direction == .keep_right) and !try self.rampLeadsToHighway(value));
            value.type = if (exit) junctions.exitType(value) else junctions.rampType(value);
        } else if (try junctions.mergeDirection(at, value.turn_degree)) |direction| {
            value.merge_to_relative_direction = direction;
            value.type = switch (direction) {
                .keep_left => .kMergeLeft,
                .keep_right => .kMergeRight,
                else => .kMerge,
            };
        } else {
            value.type = facilityType(value, at.previous) orelse try simpleDirectionalType(value, at);
        }
    }

    fn endLevelRef(self: Builder, edge: enhanced.Edge) ![]const u8 {
        const refs = try edge.levelRefs(self.arena);
        return if (refs.len == 1) refs[0] else "";
    }

    // Ported from ManeuversBuilder::RampLeadsToHighway.
    fn rampLeadsToHighway(self: Builder, value: *const Maneuver) !bool {
        const last = self.leg.lastNodeIndex() orelse return error.InvalidTripLeg;
        for (value.end_node_index..last) |index| {
            try self.check();
            const edge = self.leg.currEdge(index) orelse return error.InvalidTripLeg;
            if (edge.isRampUse() or edge.isTurnChannelUse() or edge.value.internal_intersection) continue;
            return edge.isHighway();
        }
        return false;
    }

    fn nameStyle(self: Builder, index: usize) maneuver.NameStyle {
        return if (std.mem.eql(u8, self.leg.countryCode(index), "US")) .us else .generic;
    }

    // Ported from the blind pedestrian node handling in ManeuversBuilder::Produce.
    fn recordBlindIntersection(self: Builder, value: *Maneuver, node: enhanced.Node) !void {
        switch (node.value.type) {
            .kStreetIntersection => {
                var names: std.ArrayList(trip.StreetName) = .empty;
                for (node.value.intersecting_edge) |crossing| {
                    try self.check();
                    for (crossing.name) |name| {
                        try self.check();
                        for (names.items, 0..) |known, i| {
                            if (i % 64 == 0) try self.check();
                            if (known.is_route_number == name.is_route_number and std.mem.eql(u8, known.value, name.value)) break;
                        } else try names.append(self.arena, .{ .value = name.value, .is_route_number = name.is_route_number });
                    }
                }
                if (names.items.len == 0) return;
                value.cross_street_names = names.items;
                value.node_type = node.value.type;
                value.traffic_signal = value.traffic_signal or node.value.traffic_signal;
            },
            .kGate, .kBollard => value.node_type = node.value.type,
            else => {},
        }
    }

    fn addSigns(self: Builder, first: []const trip.SignElement, second: []const trip.SignElement) ![]const trip.SignElement {
        if (first.len == 0) return second;
        if (second.len == 0) return first;
        const joined = try self.arena.alloc(trip.SignElement, try std.math.add(usize, first.len, second.len));
        @memcpy(joined[0..first.len], first);
        @memcpy(joined[first.len..], second);
        return joined;
    }

    // Ported from ManeuversBuilder::CanManeuverIncludePrevEdge and IncludeUnnamedPrevEdge.
    fn canManeuverIncludePreviousEdge(self: Builder, value: *Maneuver, index: usize, at: TurnContext) !bool {
        const previous = at.previous.value;
        const current = at.current.value;
        if (current.pedestrian_type == .kBlind and value.node_type != null) return false;
        if (at.node.isParking() or at.node.isBikeShare()) return false;
        if (value.transit_connection or at.previous.isTransitConnection()) {
            return value.transit_connection and at.previous.isTransitConnection() and transitConnectionsJoin(at.previous, at.current);
        }
        if (value.drive_on_right == previous.drive_on_left) return false;
        if (value.elevator or at.previous.isElevatorUse()) return value.elevator and at.previous.isElevatorUse();
        if (at.node.isElevator()) return false;
        const previous_indoor_steps = at.previous.isStepsUse() and previous.indoor;
        if (value.indoor_steps or previous_indoor_steps) return value.indoor_steps and previous_indoor_steps;
        if (value.steps or at.previous.isStepsUse()) return value.steps and at.previous.isStepsUse();
        if (value.escalator or at.previous.isEscalatorUse()) return value.escalator and at.previous.isEscalatorUse();
        if (at.node.isBuildingEntrance() or value.has_level_changes != at.previous.traversesLevels()) return false;
        if (value.travel_mode != previous.travel_mode or
            value.isUnnamedWalkway() != at.previous.isUnnamedWalkway() or
            value.isUnnamedCycleway() != at.previous.isUnnamedCycleway() or
            value.isUnnamedMountainBikeTrail() != at.previous.isUnnamedMountainBikeTrail()) return false;
        if (inRoundabout(at.previous) != value.roundabout) return false;
        if (value.roundabout) return true;
        if (try junctions.isFork(self.leg, index, at) or try junctions.isPedestrianFork(at)) {
            value.fork = true;
            return false;
        }
        if (previous.internal_intersection != value.internal_intersection) return false;
        if (previous.internal_intersection and index != 1) return true;
        if (at.previous.isTurnChannelUse() != value.turn_channel) return false;
        if (value.turn_channel) return true;
        if (value.hasExitSign()) return false;
        if (at.previous.isRampUse() != value.ramp) return false;
        const degree = turn.degree(previous.end_heading, current.begin_heading);
        if (value.ramp) return at.current.isForward(degree);
        if (value.ferry or at.previous.isFerryUse()) return value.ferry and at.previous.isFerryUse();
        if (value.rail_ferry or at.previous.isRailFerryUse()) return value.rail_ferry and at.previous.isRailFerryUse();
        if (degree == 180) {
            value.type = if (previous.drive_on_left) .kUturnRight else .kUturnLeft;
            return false;
        }
        if (try junctions.pencilPointUturn(at, self.nameStyle(index))) |kind| {
            value.type = kind;
            return false;
        }
        if (try isIntersectingForwardEdge(at)) {
            value.intersecting_forward_edge = true;
            return false;
        }
        const style = self.nameStyle(index);
        const common = try self.commonBaseNames(at.previous.nameList(), style, value.street_names, value.name_style);
        if (try isTee(at, common.len != 0)) {
            value.tee = true;
            return false;
        }
        const crossing = try at.node.straightestIntersectingEdge(previous.end_heading, previous.travel_mode);
        if (!at.current.isStraightest(degree, crossing.degree) and
            !try at.node.hasForwardTraversableIntersectingEdge(previous.end_heading, previous.travel_mode) and
            try at.node.hasTraversableExcludeUseEdge(previous.travel_mode, .kTrackUse)) return false;
        if (common.len != 0) {
            value.street_names = common;
            value.name_style = style;
            return true;
        }
        if (value.street_names.len != 0 or !at.previous.isUnnamed()) return false;
        if (!at.node.hasIntersectingEdges()) return true;
        const any_crossing = try at.node.straightestIntersectingEdge(previous.end_heading, null);
        return at.current.isStraightest(degree, any_crossing.degree);
    }

    // Ported from ManeuversBuilder::Combine.
    fn combine(self: Builder, maneuvers: []Maneuver) ![]Maneuver {
        var values = maneuvers;
        var changed = true;
        while (changed) {
            try self.check();
            changed = false;
            var write: usize = 0;
            for (1..values.len) |read| {
                try self.check();
                const current = &values[write];
                const next = &values[read];
                const previous = &values[write -| 1];
                const following = if (read + 1 < values.len) values[read + 1].type else null;
                if (try self.combinePair(previous, current, next, following, write == 0)) {
                    changed = true;
                } else {
                    write += 1;
                    if (write != read) values[write] = next.*;
                }
            }
            values = values[0 .. write + 1];
        }
        return values;
    }

    fn combinePair(self: Builder, previous: *const Maneuver, current: *Maneuver, next: *const Maneuver, following: ?directions.ManeuverType, start: bool) !bool {
        if (current.elevator or next.elevator or current.indoor_steps or next.indoor_steps or current.escalator or next.escalator or
            current.has_level_changes != next.has_level_changes or current.building_enter or current.building_exit or next.building_enter or next.building_exit or
            current.transit_connection or next.transit_connection)
            return false;
        if (current.drive_on_right != next.drive_on_right or current.travel_mode != next.travel_mode or
            next.type == .kDestination) return false;
        const possible_internal = possibleUnspecifiedInternalManeuver(previous, current, next);
        const direction = relativeDirection(current.turn_degree);
        if (possible_internal and (direction == .left or direction == .right) and
            direction == relativeDirection(next.turn_degree) and
            relativeDirection(turn.degree(previous.end_heading, next.begin_heading)) == .reverse and
            try previous.hasSimilarNames(next, true, self.leg.deadline))
        {
            combineUnspecifiedInternalManeuver(previous, current, next, if (direction == .left) .kUturnLeft else .kUturnRight);
            return true;
        }
        if (next.tee or next.fork or current.ferry or next.ferry) return false;
        if (current.internal_intersection and !next.isDestinationType()) {
            try self.combineInternalManeuver(previous, current, next, start);
            return true;
        }
        if (try self.turnChannelCombinable(previous, current, next, start)) {
            try self.combineTurnChannel(previous, current, next, start);
            return true;
        }
        if (next.intersecting_forward_edge or current.trail_type != next.trail_type) return false;
        if (current.pedestrian_type == .kBlind and next.pedestrian_type == .kBlind and
            (current.node_type != null or next.node_type != null or current.steps or next.steps or current.bridge or next.bridge or current.tunnel or next.tunnel)) return false;

        const next_edge = self.leg.currEdge(next.begin_node_index);
        if (next.begin_relative_direction == .keep_straight and next_edge != null and !next_edge.?.isTurnChannelUse() and
            !next.internal_intersection and !current.ramp and !next.ramp and !current.roundabout and !next.roundabout)
        {
            const common = try self.commonBaseNames(current.street_names, current.name_style, next.street_names, next.name_style);
            if (common.len != 0) {
                if (current.begin_street_names.len == 0 and !current.portions_highway and current.street_names.len > common.len)
                    current.begin_street_names = current.street_names;
                current.street_names = common;
                combineManeuvers(current, next);
                return true;
            }
            if (current.street_names.len == 0 and next.street_names.len == 0) {
                combineManeuvers(current, next);
                return true;
            }
        }
        if (try self.areRampManeuversCombinable(current, next)) {
            combineManeuvers(current, next);
            return true;
        }
        if (try self.isNextManeuverObvious(current, next, following)) {
            if (current.street_names.len == 0) {
                current.street_names = next.street_names;
                current.name_style = next.name_style;
            }
            current.contains_obvious_maneuver = true;
            current.turn_channel = false;
            combineManeuvers(current, next);
            return true;
        }
        if (possible_internal and (direction == .left or direction == .right) and next.type == .kRampStraight) {
            combineUnspecifiedInternalManeuver(previous, current, next, .kNone);
            return true;
        }
        return false;
    }

    // Ported from ManeuversBuilder::CombineInternalManeuver.
    fn combineInternalManeuver(self: Builder, previous: *const Maneuver, current: *Maneuver, next: *const Maneuver, start: bool) !void {
        var combined = next.*;
        combined.turn_degree = turn.degree(if (start) current.end_heading else previous.end_heading, next.begin_heading);
        if (current.hasUsableInternalIntersectionName()) combined.cross_street_names = current.street_names;
        combined.internal_right_turn_count = current.internal_right_turn_count;
        combined.internal_left_turn_count = current.internal_left_turn_count;
        combined.begin_relative_direction = relativeDirection(combined.turn_degree);
        if (combined.begin_relative_direction == .keep_straight and
            combined.internal_left_turn_count > 0 and combined.internal_right_turn_count > 0)
        {
            combined.begin_relative_direction = relativeDirection(turn.degree(previous.end_heading, current.end_heading));
        }
        prependManeuver(&combined, current);
        combined.type = if (start) .kStart else .kNone;
        try self.setManeuverType(&combined, true);
        current.* = combined;
    }

    // Ported from ManeuversBuilder::IsTurnChannelManeuverCombinable.
    fn turnChannelCombinable(self: Builder, previous: *const Maneuver, current: *const Maneuver, next: *const Maneuver, start: bool) !bool {
        if (!current.turn_channel or next.isDestinationType() or current.length_km > 0.2) return false;
        const at = try self.context(current.end_node_index);
        const degree = turn.degree(at.previous.value.end_heading, at.current.value.begin_heading);
        if (try at.node.hasForwardTraversableIntersectingEdge(current.end_heading, current.travel_mode)) return false;
        if (degree < 290 and degree > 70 and current.length_km >= 0.036) return false;
        const kind = turn.classify(turn.degree(if (start) current.end_heading else previous.end_heading, next.begin_heading));
        return switch (current.begin_relative_direction) {
            .keep_right, .right => next.begin_relative_direction != .left and switch (kind) {
                .straight, .slight_right, .right, .sharp_right, .reverse => true,
                else => false,
            },
            .keep_left, .left => next.begin_relative_direction != .right and switch (kind) {
                .straight, .slight_left, .left, .sharp_left, .reverse => true,
                else => false,
            },
            .keep_straight => kind == .straight,
            else => false,
        };
    }

    // Ported from ManeuversBuilder::CombineTurnChannelManeuver.
    fn combineTurnChannel(self: Builder, previous: *const Maneuver, current: *Maneuver, next: *const Maneuver, start: bool) !void {
        var combined = next.*;
        combined.turn_degree = turn.degree(if (start) current.end_heading else previous.end_heading, next.begin_heading);
        combined.begin_relative_direction = current.begin_relative_direction;
        prependManeuver(&combined, current);
        if (current.hasSigns() and !next.hasSigns()) combined.signs = current.signs;
        combined.type = if (start) .kStart else .kNone;
        try self.setManeuverType(&combined, true);
        current.* = combined;
    }

    // Ported from ManeuversBuilder::AreRampManeuversCombinable.
    fn areRampManeuversCombinable(self: Builder, current: *const Maneuver, next: *const Maneuver) !bool {
        if (!current.ramp or !next.ramp or next.fork or current.internal_intersection or next.internal_intersection) return false;
        const node = self.leg.node(next.begin_node_index) orelse return error.InvalidTripLeg;
        return !try node.hasTraversableOutboundIntersectingEdge(next.travel_mode) or
            try node.isStraightestTraversableIntersectingEdgeReversed(current.end_heading, next.travel_mode) or next.type == .kRampStraight;
    }

    // Ported from ManeuversBuilder::IsNextManeuverObvious.
    fn isNextManeuverObvious(self: Builder, current: *const Maneuver, next: *const Maneuver, following: ?directions.ManeuverType) !bool {
        if (next.type != .kContinue) return false;
        const node = self.leg.node(next.begin_node_index) orelse return error.InvalidTripLeg;
        if (!try node.hasTraversableIntersectingEdge(next.travel_mode)) return true;
        if (next.signs.exit_numbers.len != 0) return false;
        if (current.ramp and current.fork and !current.contains_obvious_maneuver) {
            if (current.type == .kStayStraight) return true;
            const counts = try node.countIntersectingEdges(current.end_heading, current.travel_mode);
            return (current.type == .kStayLeft and counts.left.all == 0) or
                (current.type == .kStayRight and counts.right.all == 0);
        }
        if (next.length_km < short_continue_threshold and following != null and following != .kContinue) return true;
        return !node.isMotorwayJunction() and
            !try node.hasNonBackwardTraversableSameNameRampIntersectingEdge(current.end_heading, next.travel_mode);
    }

    // Ported from ManeuversBuilder::SetTraversableOutboundIntersectingEdgeFlags.
    fn setTraversableOutboundIntersectingEdgeFlags(self: Builder, values: []Maneuver) !void {
        for (values) |*value| {
            try self.check();
            var first = true;
            for (value.begin_node_index..value.end_node_index) |index| {
                try self.check();
                if (first) {
                    const edge = self.leg.currEdge(index) orelse return error.InvalidTripLeg;
                    first = edge.value.internal_intersection or edge.isTurnChannelUse();
                    continue;
                }
                const at = try self.context(index);
                const counts = try at.node.countIntersectingEdges(at.previous.value.end_heading, at.previous.value.travel_mode);
                value.has_right_traversable_outbound_intersecting_edge = value.has_right_traversable_outbound_intersecting_edge or counts.right.traversable_outbound != 0;
                value.has_left_traversable_outbound_intersecting_edge = value.has_left_traversable_outbound_intersecting_edge or counts.left.traversable_outbound != 0;
                if (value.has_right_traversable_outbound_intersecting_edge and value.has_left_traversable_outbound_intersecting_edge) break;
            }
        }
    }

    // Ported from ManeuversBuilder::ProcessRoundabouts.
    fn processRoundabouts(self: Builder, values: []Maneuver, keep_exits: bool) ![]Maneuver {
        var read: usize = 1;
        var write: usize = 1;
        while (read + 1 < values.len) : ({
            read += 1;
            write += 1;
        }) {
            try self.check();
            values[write] = values[read];
            const current = &values[write];
            if (!current.roundabout) continue;
            const next = &values[read + 1];
            const previous = &values[write - 1];
            var names: std.ArrayList(trip.StreetName) = .empty;
            for (current.street_names) |name| {
                try self.check();
                if (!name.is_route_number) try names.append(self.arena, name);
            }
            const common_previous = try self.commonBaseNames(names.items, current.name_style, previous.street_names, previous.name_style);
            const common_next = try self.commonBaseNames(names.items, current.name_style, next.street_names, next.name_style);
            current.street_names = if (common_previous.len == 0 and common_next.len == 0) names.items else &.{};
            current.begin_street_names = &.{};
            if (next.type != .kRoundaboutExit) continue;
            if (next.begin_street_names.len != 0 and next.contains_obvious_maneuver) {
                current.roundabout_exit_street_names = next.begin_street_names;
            } else {
                current.roundabout_exit_street_names = next.street_names;
                current.roundabout_exit_begin_street_names = next.begin_street_names;
            }
            current.roundabout_exit_signs = next.signs;
            if (keep_exits) continue;
            current.has_combined_enter_exit_roundabout = true;
            current.roundabout_length_km = current.length_km;
            current.roundabout_exit_length_km = next.length_km;
            current.roundabout_exit_begin_heading = next.begin_heading;
            current.roundabout_exit_turn_degree = next.turn_degree;
            current.roundabout_exit_shape_index = current.end_shape_index;
            current.has_left_traversable_outbound_intersecting_edge = next.has_left_traversable_outbound_intersecting_edge;
            current.has_right_traversable_outbound_intersecting_edge = next.has_right_traversable_outbound_intersecting_edge;
            combineManeuvers(current, next);
            read += 1;
        }
        values[write] = values[read];
        return values[0 .. write + 1];
    }

    // Ported from ManeuversBuilder::SetToStayOnAttribute.
    fn setToStayOnAttribute(self: Builder, values: []Maneuver) !void {
        for (1..values.len - 1) |index| {
            try self.check();
            const previous = &values[index - 1];
            const current = &values[index];
            const next = &values[index + 1];
            const deadline = self.leg.deadline;
            current.to_stay_on = switch (current.type) {
                .kSlightRight, .kRight, .kSharpRight, .kSlightLeft, .kLeft, .kSharpLeft => current.begin_street_names.len == 0 and try current.hasSimilarNames(previous, true, deadline),
                .kStayStraight, .kStayRight, .kStayLeft => try current.hasSimilarNames(previous, true, deadline) and
                    (!current.ramp or try current.hasSimilarNames(next, true, deadline)),
                .kUturnRight, .kUturnLeft => try current.hasSameNames(previous, true, deadline),
                else => false,
            };
        }
    }

    // Ported from ManeuversBuilder::EnhanceSignlessInterchnages.
    fn enhanceSignlessInterchanges(self: Builder, values: []Maneuver) !void {
        for (0..values.len - 1) |index| {
            try self.check();
            const previous = &values[index -| 1];
            const current = &values[index];
            const next = &values[index + 1];
            if ((current.ramp or (current.fork and current.street_names.len == 0)) and !current.hasExitSign() and
                !(previous.ramp or previous.fork) and next.isMergeType() and next.street_names.len != 0)
            {
                const name = next.street_names[0];
                const sign = try self.arena.alloc(trip.SignElement, 1);
                sign[0] = .{ .text = name.value, .is_route_number = name.is_route_number, .pronunciation = name.pronunciation };
                current.signs.exit_onto_streets = sign;
            }
        }
    }

    // Ported from ManeuversBuilder::UpdateManeuverPlacementForInternalIntersectionTurns.
    fn updateManeuverPlacementForInternalIntersectionTurns(self: Builder, values: []Maneuver) !void {
        for (1..values.len - 1) |index| {
            try self.check();
            const previous = &values[index - 1];
            const current = &values[index];
            switch (current.type) {
                .kSlightRight, .kRight, .kSharpRight, .kUturnRight, .kUturnLeft, .kSharpLeft, .kLeft, .kSlightLeft, .kRampRight, .kRampLeft, .kStayRight, .kStayLeft => {},
                else => continue,
            }
            if (previous.travel_mode != current.travel_mode) continue;
            while (current.begin_node_index + 1 < current.end_node_index) {
                try self.check();
                const at = try self.context(current.begin_node_index);
                if (!at.current.value.internal_intersection or relativeDirection(at.degree()) != .keep_straight) break;
                try self.moveInternalEdgeToPreviousManeuver(previous, current, at.current.value);
            }
        }
    }

    // Ported from ManeuversBuilder::MoveInternalEdgeToPreviousManeuver.
    fn moveInternalEdgeToPreviousManeuver(self: Builder, previous: *Maneuver, current: *Maneuver, edge: *const trip.Edge) !void {
        try self.inheritTurnLanes(current.begin_node_index);
        const next_begin = current.begin_node_index + 1;
        const boundary = self.leg.node(next_begin) orelse return error.InvalidTripLeg;
        const start = self.leg.node(previous.begin_node_index) orelse return error.InvalidTripLeg;
        const end = self.leg.node(current.end_node_index) orelse return error.InvalidTripLeg;
        const time = basicTime(edge, current.travel_mode);
        previous.length_km += edge.length_km;
        previous.basic_time += time;
        previous.end_node_index = next_begin;
        previous.end_shape_index = edge.end_shape_index;
        previous.time = boundary.elapsedTime() - start.elapsedTime();
        current.length_km -= edge.length_km;
        current.basic_time -= time;
        current.begin_node_index = next_begin;
        current.begin_shape_index = edge.end_shape_index;
        current.time = end.elapsedTime() - boundary.elapsedTime();
    }

    fn inheritTurnLanes(self: Builder, index: u32) !void {
        const copied = self.copied_nodes orelse return;
        const nodes: []const trip.Node = if (copied.*) |prior| prior else self.leg.value.node;
        const edge = nodes[index].edge orelse return error.InvalidTripLeg;
        if (edge.turn_lanes.len != 0) return;
        const previous = nodes[index - 1].edge orelse return error.InvalidTripLeg;
        if (previous.turn_lanes.len == 0) return;
        if (copied.* == null) copied.* = try self.arena.dupe(trip.Node, nodes);
        copied.*.?[index].edge.?.turn_lanes = try self.arena.dupe(trip.TurnLane, previous.turn_lanes);
    }

    // Ported from ManeuversBuilder::CollapseSmallEndRampFork.
    fn collapseSmallEndRampFork(self: Builder, values: []Maneuver) ![]Maneuver {
        var write: usize = 1;
        for (1..values.len - 1) |read| {
            try self.check();
            const previous = &values[write - 1];
            const current = &values[read];
            const next = &values[read + 1];
            if (!previous.has_collapsed_small_end_ramp_fork and previous.ramp and current.ramp and !next.ramp and
                current.length_km <= small_end_ramp_fork_threshold and forkThenTurnSameDirection(current.type, next.type))
            {
                combineManeuvers(previous, current);
                previous.has_collapsed_small_end_ramp_fork = true;
            } else {
                values[write] = current.*;
                write += 1;
            }
        }
        values[write] = values[values.len - 1];
        return values[0 .. write + 1];
    }

    // Ported from ManeuversBuilder::CollapseMergeManeuvers.
    fn collapseMergeManeuvers(self: Builder, values: []Maneuver) ![]Maneuver {
        var read: usize = 0;
        var write: usize = 0;
        while (read < values.len) : ({
            read += 1;
            write += 1;
        }) {
            try self.check();
            values[write] = values[read];
            const current = &values[write];
            if (read + 1 == values.len or !current.ramp or current.has_collapsed_merge_maneuver) continue;
            const next = &values[read + 1];
            if (!next.isMergeType()) continue;
            if (current.to_stay_on and !try next.hasSameNames(current, true, self.leg.deadline)) current.to_stay_on = false;
            if (next.street_names.len != 0) {
                current.street_names = next.street_names;
                current.name_style = next.name_style;
            }
            if (!current.hasSigns()) {
                current.signs.guide_onto_streets = next.signs.guide_onto_streets;
                current.signs.guide_toward_locations = next.signs.guide_toward_locations;
            }
            combineManeuvers(current, next);
            current.has_collapsed_merge_maneuver = true;
            read += 1;
        }
        return values[0..write];
    }

    // Ported from StreetNames::FindCommonBaseNames and StreetNamesUs::FindCommonBaseNames.
    fn commonBaseNames(self: Builder, left: []const trip.StreetName, left_style: maneuver.NameStyle, right: []const trip.StreetName, right_style: maneuver.NameStyle) ![]const trip.StreetName {
        if (left.len == 0 or right.len == 0) return &.{};
        var common: std.ArrayList(trip.StreetName) = .empty;
        var complete_prefix: usize = 0;
        var changed = false;
        for (left) |name| {
            try self.check();
            const first = maneuver.baseName(name.value, left_style);
            var match: ?trip.StreetName = null;
            for (right, 0..) |other, i| {
                if (i % 64 == 0) try self.check();
                if (!std.mem.eql(u8, first, maneuver.baseName(other.value, right_style))) continue;
                match = other;
                break;
            }
            const replacement = if (match) |other|
                !hasPostCardinal(name.value, left_style) and hasPostCardinal(other.value, right_style)
            else
                false;
            if (!changed and match != null and !replacement) {
                complete_prefix += 1;
                continue;
            }
            if (!changed) {
                changed = true;
                try common.appendSlice(self.arena, left[0..complete_prefix]);
            }
            if (match) |other| try common.append(self.arena, if (replacement) other else name);
        }
        return if (changed) common.items else left;
    }
};

// Ported from ManeuversBuilder::PossibleUnspecifiedInternalManeuver.
fn possibleUnspecifiedInternalManeuver(previous: *const Maneuver, current: *const Maneuver, next: *const Maneuver) bool {
    return !current.internal_intersection and current.travel_mode == .kDrive and
        !previous.roundabout and !current.roundabout and !next.roundabout and
        current.length_km <= max_internal_length_km and !current.isStartType() and !next.isDestinationType();
}

// Ported from ManeuversBuilder::CombineUnspecifiedInternalManeuver.
fn combineUnspecifiedInternalManeuver(previous: *const Maneuver, current: *Maneuver, next: *const Maneuver, kind: directions.ManeuverType) void {
    var combined = next.*;
    combined.turn_degree = turn.degree(previous.end_heading, next.begin_heading);
    combined.begin_relative_direction = relativeDirection(combined.turn_degree);
    if (current.street_names.len != 0) combined.cross_street_names = current.street_names;
    prependManeuver(&combined, current);
    combined.type = kind;
    current.* = combined;
}

fn prependManeuver(current: *Maneuver, previous: *const Maneuver) void {
    current.length_km += previous.length_km;
    current.time += previous.time;
    current.basic_time += previous.basic_time;
    current.begin_node_index = previous.begin_node_index;
    current.begin_shape_index = previous.begin_shape_index;
}

fn basicTime(edge: *const trip.Edge, mode: trip.TravelMode) f32 {
    const speed: f32 = switch (mode) {
        .kPedestrian => 5.1,
        .kBicycle => 20,
        else => edge.default_speed,
    };
    return if (speed > 0) @trunc(edge.length_km / (speed * (1.0 / 3600.0)) + 0.5) else 0;
}

fn forkThenTurnSameDirection(fork: directions.ManeuverType, following: directions.ManeuverType) bool {
    return switch (fork) {
        .kStayRight => following == .kSlightRight or following == .kRight or following == .kSharpRight,
        .kStayLeft => following == .kSlightLeft or following == .kLeft or following == .kSharpLeft,
        else => false,
    };
}

fn requireSupportedEdge(edge: enhanced.Edge) !void {
    const raw = edge.value;
    if (!(raw.length_km >= 0 and std.math.isFinite(raw.length_km))) return error.InvalidTripLeg;
    if (raw.travel_mode == .kTransit) return error.UnsupportedManeuver;
}

// Ported from the station entrance and exit cases of CanManeuverIncludePrevEdge.
fn transitConnectionsJoin(previous: enhanced.Edge, current: enhanced.Edge) bool {
    return switch (previous.value.use) {
        .kEgressConnectionUse => current.isPlatformConnectionUse() or current.isTransitConnectionUse(),
        .kPlatformConnectionUse => current.isPlatformConnectionUse() or current.isEgressConnectionUse(),
        .kTransitConnectionUse => current.isEgressConnectionUse(),
        else => false,
    };
}

// Ported from the facility and travel-mode branches of ManeuversBuilder::SetManeuverType.
fn facilityType(value: *const Maneuver, previous: ?enhanced.Edge) ?directions.ManeuverType {
    if (value.ferry or value.rail_ferry) return .kFerryEnter;
    if (previous) |edge| if (edge.isFerryUse() or edge.isRailFerryUse()) return .kFerryExit;
    if (value.elevator) return .kElevatorEnter;
    if (value.indoor_steps or value.steps) return .kStepsEnter;
    if (value.escalator) return .kEscalatorEnter;
    if (value.building_enter) return .kBuildingEnter;
    if (value.building_exit) return .kBuildingExit;
    if (value.has_level_changes and value.end_level_ref.len != 0) return .kLevelChange;
    if (previous) |edge| if (value.travel_mode == .kPedestrian and edge.value.travel_mode == .kDrive) return .kParkVehicle;
    return null;
}

// Ported from ManeuversBuilder::AreRoundaboutsProcessable.
fn inRoundabout(edge: enhanced.Edge) bool {
    return edge.value.roundabout and (edge.value.travel_mode == .kDrive or edge.value.travel_mode == .kBicycle);
}

fn copyTravel(value: *Maneuver, edge: enhanced.Edge) void {
    value.travel_mode = edge.value.travel_mode;
    if (edge.hasVehicleType()) value.vehicle_type = edge.value.vehicle_type;
    if (edge.hasPedestrianType()) value.pedestrian_type = edge.value.pedestrian_type;
    if (edge.hasBicycleType()) value.bicycle_type = edge.value.bicycle_type;
    if (edge.hasTransitType()) value.transit_type = edge.value.transit_type;
}

fn trailType(edge: enhanced.Edge) maneuver.TrailType {
    if (edge.isFootwayUse()) return if (edge.isUnnamed()) .unnamed_walkway else .named_walkway;
    if (edge.isMountainBikeUse()) return if (edge.isUnnamed()) .unnamed_mtb_trail else .named_mtb_trail;
    if (edge.isCyclewayUse()) return if (edge.isUnnamed()) .unnamed_cycleway else .named_cycleway;
    return .none;
}

// Ported from ManeuversBuilder::CombineManeuvers.
fn combineManeuvers(current: *Maneuver, next: *const Maneuver) void {
    current.length_km += next.length_km;
    current.time += next.time;
    current.basic_time += next.basic_time;
    current.end_heading = next.end_heading;
    current.end_node_index = next.end_node_index;
    current.end_shape_index = next.end_shape_index;
    current.end_level_ref = next.end_level_ref;
    current.elevator = current.elevator or next.elevator;
    current.steps = current.steps or next.steps;
    current.indoor_steps = current.indoor_steps or next.indoor_steps;
    current.escalator = current.escalator or next.escalator;
    current.has_level_changes = current.has_level_changes or next.has_level_changes;
    current.ferry = current.ferry or next.ferry;
    current.rail_ferry = current.rail_ferry or next.rail_ferry;
    current.ramp = current.ramp or next.ramp;
    current.roundabout = current.roundabout or next.roundabout;
    current.portions_toll = current.portions_toll or next.portions_toll;
    current.portions_unpaved = current.portions_unpaved or next.portions_unpaved;
    current.portions_highway = current.portions_highway or next.portions_highway;
    current.has_time_restrictions = current.has_time_restrictions or next.has_time_restrictions;
    current.contains_obvious_maneuver = current.contains_obvious_maneuver or next.contains_obvious_maneuver;
}

// Ported from ManeuversBuilder::IsTee.
fn isTee(at: TurnContext, has_common_names: bool) !bool {
    if (at.node.value.intersecting_edge.len != 1) return false;
    const crossing = at.node.intersection(0).?;
    const previous = at.previous.value;
    if (!crossing.isTraversable(previous.travel_mode)) return false;
    if (has_common_names and !try at.node.hasTraversableExcludeUseEdge(previous.travel_mode, .kTrackUse)) return false;
    const path = turn.classify(turn.degree(previous.end_heading, at.current.value.begin_heading));
    const cross = turn.classify(crossing.turnDegree(previous.end_heading));
    return (path == .right and cross == .left) or (path == .left and cross == .right);
}

// Ported from ManeuversBuilder::IsIntersectingForwardEdge.
pub fn isIntersectingForwardEdge(at: TurnContext) !bool {
    if (!at.node.hasIntersectingEdges() or at.node.isMotorwayJunction() or at.node.value.fork or
        (at.current.isHighway() and at.previous.isHighway())) return false;
    const previous = at.previous.value;
    const degree = turn.degree(previous.end_heading, at.current.value.begin_heading);
    if (!at.current.isForward(degree))
        return at.node.hasForwardTraversableExcludeUseEdge(previous.end_heading, previous.travel_mode, .kTrackUse);
    if (!try at.node.hasForwardTraversableSignificantRoadClassEdge(previous.end_heading, previous.travel_mode, previous.road_class)) return false;
    const crossing = try at.node.straightestIntersectingEdge(previous.end_heading, previous.travel_mode);
    return !at.current.isStraightest(degree, crossing.degree);
}

fn hasPostCardinal(name: []const u8, style: maneuver.NameStyle) bool {
    if (style != .us) return false;
    inline for (.{ " North", " East", " South", " West" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return true;
    }
    return false;
}

test "upstream internal junction maneuvers combine into the expected turns" {
    const testing = std.testing;
    for (@import("junction_fixtures.zig").combine_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        errdefer std.debug.print("failed upstream fixture {s}\n", .{case.name});
        const a = arena.allocator();
        const nodes = try a.alloc(trip.Node, case.edges.len + 1);
        for (case.edges, nodes[0..case.edges.len]) |edge, *node| node.* = .{ .edge = edge };
        nodes[nodes.len - 1] = .{};
        const path: trip.TripLeg = .{ .node = nodes };
        const builder: Builder = .{ .leg = .{ .value = &path }, .arena = a };
        const combined = try builder.combine(try a.dupe(Maneuver, case.maneuvers));
        try testing.expectEqual(case.expected.len, combined.len);
        for (case.expected, combined) |expected, actual| {
            try testing.expectEqual(expected.kind, actual.type);
            try testing.expectApproxEqAbs(expected.length_km, actual.length_km, 0.00001);
            try testing.expectEqual(expected.time, actual.time);
        }
    }
}

test "upstream roundabout fixtures keep or collapse the exit" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path: trip.TripLeg = .{};
    const builder: Builder = .{ .leg = .{ .value = &path }, .arena = arena.allocator() };
    const values = [_]Maneuver{
        .{ .type = .kStart, .street_names = &.{.{ .value = "first st" }}, .length_km = 1, .time = 1, .end_heading = 100, .end_shape_index = 5 },
        .{ .type = .kRoundaboutEnter, .roundabout = true, .length_km = 1, .time = 1, .turn_degree = 32, .begin_heading = 150, .end_heading = 250, .begin_shape_index = 5, .end_shape_index = 10 },
        .{ .type = .kRoundaboutExit, .roundabout = true, .length_km = 2, .time = 1, .turn_degree = 90, .begin_heading = 280, .end_heading = 310, .begin_shape_index = 10, .end_shape_index = 15 },
        .{ .type = .kDestination, .time = 1, .begin_shape_index = 15, .end_shape_index = 15 },
    };
    var separate = values;
    const preserved = try builder.processRoundabouts(&separate, true);
    try testing.expectEqualSlices(Maneuver, &values, preserved);
    var together = values;
    const combined = try builder.processRoundabouts(&together, false);
    try testing.expectEqual(@as(usize, 3), combined.len);
    try testing.expectEqual(.kStart, combined[0].type);
    try testing.expectEqual(.kRoundaboutEnter, combined[1].type);
    try testing.expectEqual(.kDestination, combined[2].type);
    const entry = combined[1];
    try testing.expect(entry.has_combined_enter_exit_roundabout);
    try testing.expectEqual(@as(f32, 3), entry.length_km);
    try testing.expectEqual(@as(f64, 2), entry.time);
    try testing.expectEqual(@as(f32, 1), entry.roundabout_length_km);
    try testing.expectEqual(@as(f32, 2), entry.roundabout_exit_length_km);
    try testing.expectEqual(@as(u32, 280), entry.roundabout_exit_begin_heading);
    try testing.expectEqual(@as(u32, 90), entry.roundabout_exit_turn_degree);
    try testing.expectEqual(@as(u32, 10), entry.roundabout_exit_shape_index);
}

test "upstream intersection headings adjust relative direction" {
    const cases = [_]struct { from: u32, to: u32, crossings: []const u32, expected: maneuver.RelativeDirection }{
        .{ .from = 0, .to = 5, .crossings = &.{355}, .expected = .keep_right },
        .{ .from = 0, .to = 355, .crossings = &.{5}, .expected = .keep_left },
        .{ .from = 0, .to = 11, .crossings = &.{0}, .expected = .keep_right },
        .{ .from = 90, .to = 105, .crossings = &.{85}, .expected = .keep_right },
        .{ .from = 0, .to = 345, .crossings = &.{355}, .expected = .keep_left },
        .{ .from = 270, .to = 255, .crossings = &.{275}, .expected = .keep_left },
        .{ .from = 80, .to = 60, .crossings = &.{ 157, 337 }, .expected = .keep_straight },
        .{ .from = 180, .to = 339, .crossings = &.{ 355, 270, 180, 90, 10 }, .expected = .right },
        .{ .from = 180, .to = 21, .crossings = &.{ 90, 180, 270, 352, 355, 5 }, .expected = .left },
        .{ .from = 180, .to = 352, .crossings = &.{ 355, 270, 180, 90, 10 }, .expected = .reverse },
        .{ .from = 180, .to = 15, .crossings = &.{ 355, 270, 180, 90, 10 }, .expected = .reverse },
    };
    for (cases) |case| {
        var intersections: [6]trip.IntersectingEdge = undefined;
        for (case.crossings, intersections[0..case.crossings.len]) |heading, *out| {
            out.* = .{ .begin_heading = heading, .driveability = .kBoth };
        }
        const current: trip.Edge = .{ .begin_heading = case.to };
        const node: trip.Node = .{ .edge = current, .intersecting_edge = intersections[0..case.crossings.len] };
        const value: Maneuver = .{ .turn_degree = turn.degree(case.from, case.to) };
        try std.testing.expectEqual(case.expected, try directionAt(&value, .{ .value = &node }, .{
            .value = &.{ .end_heading = case.from },
        }, .{ .value = &current }));
    }
}

test "upstream simple right turn channel combines into the next named road" {
    const from_names = [_]trip.StreetName{ .{ .value = "MD 43 East", .is_route_number = true }, .{ .value = "White Marsh Boulevard" } };
    const to_names = [_]trip.StreetName{.{ .value = "Perry Hall Boulevard" }};
    const nodes = [_]trip.Node{
        .{ .edge = .{ .name = &from_names, .length_km = 0.091237, .road_class = .kTrunk, .begin_heading = 59, .end_heading = 94, .end_shape_index = 4 } },
        .{ .edge = .{ .use = .kTurnChannelUse, .length_km = 0.142, .road_class = .kSecondary, .begin_heading = 105, .end_heading = 179, .begin_shape_index = 4, .end_shape_index = 11 } },
        .{ .edge = .{ .name = &to_names, .length_km = 0.065867, .road_class = .kSecondary, .begin_heading = 188, .end_heading = 188, .begin_shape_index = 11, .end_shape_index = 14 } },
        .{},
    };
    var steps = [_]Maneuver{
        .{ .type = .kStart, .street_names = &from_names, .length_km = 0.091237, .time = 4, .begin_cardinal_direction = .kNorthEast, .begin_heading = 59, .end_heading = 94, .end_node_index = 1, .end_shape_index = 4 },
        .{ .turn_channel = true, .length_km = 0.142, .time = 5, .turn_degree = 11, .begin_relative_direction = .keep_right, .begin_cardinal_direction = .kEast, .begin_heading = 105, .end_heading = 179, .begin_node_index = 1, .end_node_index = 2, .begin_shape_index = 4, .end_shape_index = 11 },
        .{ .type = .kContinue, .street_names = &to_names, .length_km = 0.065867, .time = 4, .turn_degree = 9, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouth, .begin_heading = 188, .end_heading = 188, .begin_node_index = 2, .end_node_index = 3, .begin_shape_index = 11, .end_shape_index = 14 },
        .{ .type = .kDestination, .begin_node_index = 3, .end_node_index = 3, .begin_shape_index = 14, .end_shape_index = 14 },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const builder: Builder = .{ .leg = .{ .value = &.{ .node = &nodes } }, .arena = arena.allocator() };
    const result = try builder.combine(&steps);
    try std.testing.expectEqual(3, result.len);
    try std.testing.expectEqual(directions.ManeuverType.kStart, result[0].type);
    try std.testing.expectEqual(directions.ManeuverType.kRight, result[1].type);
    try std.testing.expectEqual(directions.ManeuverType.kDestination, result[2].type);
    try std.testing.expectEqualStrings("Perry Hall Boulevard", result[1].street_names[0].value);
    try std.testing.expectApproxEqAbs(@as(f32, 0.207867), result[1].length_km, 0.000001);
    try std.testing.expectEqual(9, result[1].time);
    try std.testing.expectEqual(94, result[1].turn_degree);
    try std.testing.expectEqual(maneuver.RelativeDirection.keep_right, result[1].begin_relative_direction);
    try std.testing.expectEqual(1, result[1].begin_node_index);
    try std.testing.expectEqual(4, result[1].begin_shape_index);
}
