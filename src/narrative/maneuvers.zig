// Ported from src/odin/maneuversbuilder.cc (Valhalla 3.9.3).
const trip = @import("../api/trip.zig");
const directions = @import("../api/directions.zig");
const turn = @import("../graph/turn.zig");
const enhanced = @import("enhanced.zig");
const maneuver = @import("maneuver.zig");

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

pub const TurnContext = struct {
    node: enhanced.Node,
    previous: enhanced.Edge,
    current: enhanced.Edge,
};

// Ported from ManeuversBuilder::SetSimpleDirectionalManeuverType.
pub fn simpleDirectionalType(value: *const maneuver.Maneuver, context: ?TurnContext) !directions.ManeuverType {
    const degree = value.turn_degree;
    const kind = turn.classify(degree);
    const base: directions.ManeuverType = switch (kind) {
        .straight => .kContinue,
        .slight_right => .kSlightRight,
        .right => .kRight,
        .sharp_right => .kSharpRight,
        .reverse => return error.UnsupportedManeuver,
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
            if (direction != .keep_right and direction != .keep_left) return base;
            const slight: directions.ManeuverType = if (direction == .keep_right) .kSlightRight else .kSlightLeft;
            if (at.current.isTurnChannelUse()) return slight;
            if (at.current.isHighway() and value.length_km < short_continue_threshold) return base;
            if (!try at.node.hasSimilarStraightSignificantRoadClassEdge(degree, heading, incoming_mode, incoming_class)) return base;
            if (!at.current.isHighway() and !try at.node.hasForwardTraversableUseEdge(heading, incoming_mode, .kRampUse)) return slight;
            if (try at.node.hasSimilarStraightNonRampOrSameNameRampEdge(degree, heading, incoming_mode)) return error.UnsupportedManeuver;
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

const std = @import("std");
const io = @import("../infra/io.zig");
const Maneuver = maneuver.Maneuver;

// Ported from ManeuversBuilder::Build and ConfirmManeuverTypeAssignment.
pub fn build(arena: std.mem.Allocator, path: *const trip.TripLeg, deadline: io.Deadline) ![]const Maneuver {
    const leg: enhanced.Leg = .{ .value = path, .deadline = deadline };
    const builder: Builder = .{ .leg = leg, .arena = arena };
    const result = try builder.combine(try builder.produce());
    for (result) |*value| {
        try builder.check();
        try builder.setManeuverType(value, false);
    }
    return result;
}

const Builder = struct {
    leg: enhanced.Leg,
    arena: std.mem.Allocator,

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
        try self.finalizeManeuver(value, 0);
    }

    // Ported from ManeuversBuilder::InitializeManeuver.
    fn initializeManeuver(self: Builder, index: usize) !Maneuver {
        const previous = self.leg.prevEdge(index, 1) orelse return error.InvalidTripLeg;
        var value: Maneuver = .{
            .end_heading = previous.value.end_heading,
            .end_node_index = @intCast(index),
            .end_shape_index = previous.value.end_shape_index,
            .drive_on_right = !previous.value.drive_on_left,
            .turn_channel = previous.isTurnChannelUse(),
            .trail_type = trailType(previous),
        };
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
        if (value.street_names.len == 0) {
            value.street_names = previous.nameList();
            value.name_style = self.nameStyle(index);
        }
        value.length_km += edge.length_km;
        const speed: f32 = switch (value.travel_mode) {
            .kPedestrian => 5.1,
            .kBicycle => 20,
            else => edge.default_speed,
        };
        if (speed > 0) value.basic_time += @trunc(edge.length_km / (speed * (1.0 / 3600.0)) + 0.5);
        value.portions_toll = value.portions_toll or edge.toll;
        value.portions_unpaved = value.portions_unpaved or edge.unpaved;
        value.portions_highway = value.portions_highway or previous.isHighway();
        value.has_time_restrictions = value.has_time_restrictions or edge.has_time_restrictions;
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
        value.time = end.elapsedTime() - node.elapsedTime();
        if (self.leg.prevEdge(index, 1)) |previous| {
            value.turn_degree = turn.degree(previous.value.end_heading, value.begin_heading);
            value.begin_relative_direction = try directionAt(value, node, previous, current);
            value.pedestrian_crossing = current.isPedestrianCrossingUse() and previous.isFootwayUse();
        }
        value.begin_intersecting_edge_name_consistency = try node.hasIntersectingEdgeNameConsistency();
        if (!current.isHighway() and current.nameList().len > 1) {
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
        if (value.type != .kNone or (none_type_allowed and value.turn_channel)) return;
        value.type = try simpleDirectionalType(value, try self.context(value.begin_node_index));
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
        if (value.drive_on_right == previous.drive_on_left or value.travel_mode != previous.travel_mode or
            value.isUnnamedWalkway() != at.previous.isUnnamedWalkway() or
            value.isUnnamedCycleway() != at.previous.isUnnamedCycleway() or
            value.isUnnamedMountainBikeTrail() != at.previous.isUnnamedMountainBikeTrail()) return false;
        if (at.previous.isTurnChannelUse() != value.turn_channel) return false;
        if (value.turn_channel) return true;
        if (value.hasExitSign()) return false;
        const degree = turn.degree(previous.end_heading, current.begin_heading);
        if (turn.classify(degree) == .reverse) return error.UnsupportedManeuver;
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
        if (current.drive_on_right != next.drive_on_right or current.travel_mode != next.travel_mode or
            next.isDestinationType() or next.tee or next.fork) return false;
        if (try self.turnChannelCombinable(previous, current, next, start)) {
            try self.combineTurnChannel(previous, current, next, start);
            return true;
        }
        if (next.intersecting_forward_edge or current.trail_type != next.trail_type) return false;
        if (current.pedestrian_type == .kBlind and next.pedestrian_type == .kBlind and
            (current.node_type != null or next.node_type != null or current.bridge or next.bridge or current.tunnel or next.tunnel)) return false;

        const next_edge = self.leg.currEdge(next.begin_node_index) orelse return error.InvalidTripLeg;
        if (next.begin_relative_direction == .keep_straight and !next_edge.isTurnChannelUse()) {
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
        return false;
    }

    // Ported from ManeuversBuilder::IsTurnChannelManeuverCombinable.
    fn turnChannelCombinable(self: Builder, previous: *const Maneuver, current: *const Maneuver, next: *const Maneuver, start: bool) !bool {
        if (!current.turn_channel or current.length_km > 0.2) return false;
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
        combined.length_km += current.length_km;
        combined.time += current.time;
        combined.basic_time += current.basic_time;
        combined.begin_node_index = current.begin_node_index;
        combined.begin_shape_index = current.begin_shape_index;
        if (current.hasSigns() and !next.hasSigns()) combined.signs = current.signs;
        combined.type = if (start) .kStart else .kNone;
        try self.setManeuverType(&combined, true);
        current.* = combined;
    }

    // Ported from ManeuversBuilder::IsNextManeuverObvious for continue maneuvers.
    fn isNextManeuverObvious(self: Builder, current: *const Maneuver, next: *const Maneuver, following: ?directions.ManeuverType) !bool {
        if (next.type != .kContinue) return false;
        const node = self.leg.node(next.begin_node_index) orelse return error.InvalidTripLeg;
        if (!try node.hasTraversableIntersectingEdge(next.travel_mode)) return true;
        if (next.signs.exit_numbers.len != 0) return false;
        if (next.length_km < short_continue_threshold and following != null and following != .kContinue) return true;
        return !node.isMotorwayJunction() and
            !try node.hasNonBackwardTraversableSameNameRampIntersectingEdge(current.end_heading, next.travel_mode);
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

fn requireSupportedEdge(edge: enhanced.Edge) !void {
    const raw = edge.value;
    if (!(raw.length_km >= 0 and std.math.isFinite(raw.length_km))) return error.InvalidTripLeg;
    if (raw.travel_mode == .kTransit or edge.isTransitConnection() or edge.isRampUse() or raw.roundabout or
        raw.internal_intersection or raw.indoor or edge.traversesLevels() or edge.isStepsUse() or
        edge.isEscalatorUse() or edge.isElevatorUse() or edge.isFerryUse() or edge.isRailFerryUse()) return error.UnsupportedManeuver;
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
