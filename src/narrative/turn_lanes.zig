// Ported from src/odin/maneuversbuilder.cc (Valhalla 3.9.3).
const lanes = @import("../graph/lanes.zig");
const trip = @import("../api/trip.zig");
const testing = @import("std").testing;
const enhanced = @import("enhanced.zig");
const Maneuver = @import("maneuver.zig").Maneuver;

const short_fork_km = 0.05;
const upcoming_turn_km = 3;

// Ported from ManeuversBuilder::GetExpectedTurnLaneDirection.
fn expectedDirection(edge: enhanced.Edge, value: *const Maneuver) !lanes.Mask {
    const degree = value.turn_degree;
    return switch (value.type) {
        .kUturnLeft => firstIndication(edge, &.{ lanes.reverse, lanes.left }),
        .kUturnRight => firstIndication(edge, &.{ lanes.reverse, lanes.right }),
        .kSharpLeft => firstIndication(edge, &.{ lanes.sharp_left, lanes.left }),
        .kSharpRight => firstIndication(edge, &.{ lanes.sharp_right, lanes.right }),
        .kLeft => firstIndication(edge, &.{ lanes.left, if (degree > 270) lanes.slight_left else if (degree < 270) lanes.sharp_left else 0 }),
        .kRight => firstIndication(edge, &.{ lanes.right, if (degree < 90) lanes.slight_right else if (degree > 90) lanes.sharp_right else 0 }),
        .kSlightLeft, .kExitLeft => firstIndication(edge, &.{ lanes.slight_left, lanes.left }),
        .kSlightRight, .kExitRight => firstIndication(edge, &.{ lanes.slight_right, lanes.right }),
        .kRampLeft => firstIndication(edge, if (value.begin_relative_direction == .left) &.{ lanes.left, lanes.slight_left } else &.{ lanes.slight_left, lanes.left }),
        .kRampRight => firstIndication(edge, if (value.begin_relative_direction == .right) &.{ lanes.right, lanes.slight_right } else &.{ lanes.slight_right, lanes.right }),
        .kStayLeft => forkDirection(edge, lanes.slight_left, lanes.left, lanes.right | lanes.slight_right),
        .kStayRight => forkDirection(edge, lanes.slight_right, lanes.right, lanes.left | lanes.slight_left),
        .kBecomes, .kContinue, .kRampStraight, .kStayStraight => lanes.through,
        else => lanes.none,
    };
}

fn firstIndication(edge: enhanced.Edge, choices: []const lanes.Mask) !lanes.Mask {
    for (choices) |direction| {
        if (direction != 0 and try edge.hasTurnLane(direction)) return direction;
    }
    return lanes.none;
}

fn forkDirection(edge: enhanced.Edge, slight: lanes.Mask, turn: lanes.Mask, opposite: lanes.Mask) !lanes.Mask {
    const degree = try firstIndication(edge, &.{ slight, turn });
    if (degree != lanes.none) return degree;
    return if (try edge.hasTurnLane(opposite) and try edge.hasTurnLane(lanes.through)) lanes.through else lanes.none;
}

// Ported from ManeuversBuilder::ProcessTurnLanes.
pub fn process(leg: enhanced.Leg, values: []const Maneuver) !void {
    for (1..values.len) |i| {
        if (leg.deadline.expired()) return error.DeadlineExceeded;
        const previous = &values[i - 1];
        const current = &values[i];
        if (current.travel_mode != .kDrive) continue;
        const next_type = if (i + 1 < values.len) values[i + 1].type else .kNone;
        var remaining_km: f32 = 0;
        if (leg.prevEdge(current.begin_node_index, 1)) |edge| {
            remaining_km = edge.value.length_km;
            if (edge.value.turn_lanes.len != 0 and !shortFork(current)) {
                _ = try edge.activateTurnLanes(try expectedDirection(edge, current), current.length_km, current.type, next_type);
            }
        }

        var has_directional_crossing = false;
        var index = previous.end_node_index -| 1;
        while (index > previous.begin_node_index) : (index -= 1) {
            if (leg.deadline.expired()) return error.DeadlineExceeded;
            const edge = leg.prevEdge(index, 1) orelse continue;
            const node = leg.node(index) orelse continue;
            if (!has_directional_crossing) {
                const counts = try node.countIntersectingEdges(edge.value.end_heading, edge.value.travel_mode);
                has_directional_crossing = (counts.right.traversable_outbound > 0 and current.isRightType()) or
                    (counts.left.traversable_outbound > 0 and current.isLeftType());
            }
            if (edge.value.turn_lanes.len != 0) {
                const direction = try expectedDirection(edge, current);
                if (remaining_km < upcoming_turn_km and !has_directional_crossing and direction != lanes.none) {
                    _ = try edge.activateTurnLanes(direction, current.length_km, current.type, next_type);
                } else {
                    _ = try edge.activateTurnLanes(lanes.through, remaining_km, previous.type, current.type);
                }
            }
            remaining_km += edge.value.length_km;
        }
    }
}

fn shortFork(value: *const Maneuver) bool {
    return value.length_km < short_fork_km and switch (value.type) {
        .kStayLeft, .kStayRight, .kStayStraight => true,
        else => false,
    };
}

test "approach lanes follow the upcoming turn until an intervening same-side junction" {
    const base = [_]trip.TurnLane{
        .{ .directions_mask = lanes.through },
        .{ .directions_mask = lanes.right },
        .{ .directions_mask = lanes.right },
    };
    var initial = base;
    var intermediate = base;
    var at_turn = base;
    const nodes = [_]trip.Node{
        .{ .edge = .{ .length_km = 0.1, .turn_lanes = &initial } },
        .{ .edge = .{ .length_km = 0.1, .turn_lanes = &intermediate }, .intersecting_edge = &.{.{ .begin_heading = 90, .driveability = .kForward }} },
        .{ .edge = .{ .length_km = 0.1, .turn_lanes = &at_turn } },
        .{ .edge = .{ .length_km = 0.5, .begin_heading = 90 } },
        .{},
    };
    const path: trip.TripLeg = .{ .node = &nodes };
    const moves = [_]Maneuver{
        .{ .type = .kStart, .end_node_index = 3 },
        .{ .type = .kRight, .turn_degree = 90, .begin_node_index = 3, .end_node_index = 4, .length_km = 0.5 },
        .{ .type = .kDestination, .begin_node_index = 4, .end_node_index = 4 },
    };
    try process(.{ .value = &path }, &moves);
    try testing.expectEqual(.kActive, initial[0].state);
    try testing.expectEqual(lanes.through, initial[0].active_direction);
    try testing.expectEqual(.kInvalid, initial[1].state);
    for ([_][]const trip.TurnLane{ &intermediate, &at_turn }) |row| {
        try testing.expectEqual(.kInvalid, row[0].state);
        try testing.expectEqual(.kActive, row[1].state);
        try testing.expectEqual(.kActive, row[2].state);
        try testing.expectEqual(lanes.right, row[2].active_direction);
    }
}
