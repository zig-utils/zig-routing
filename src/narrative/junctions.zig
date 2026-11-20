// Ported from src/odin/maneuversbuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const trip = @import("../api/trip.zig");
const directions = @import("../api/directions.zig");
const turn = @import("../graph/turn.zig");
const enhanced = @import("enhanced.zig");
const maneuver = @import("maneuver.zig");
const Maneuver = maneuver.Maneuver;
const Type = directions.ManeuverType;

pub const Context = struct {
    node: enhanced.Node,
    previous: enhanced.Edge,
    current: enhanced.Edge,

    pub fn degree(self: Context) u32 {
        return turn.degree(self.previous.value.end_heading, self.current.value.begin_heading);
    }
};

// Ported from the fork branch of ManeuversBuilder::SetManeuverType.
pub fn forkType(direction: maneuver.RelativeDirection) Type {
    return switch (direction) {
        .keep_right, .right => .kStayRight,
        .keep_left, .left => .kStayLeft,
        else => .kStayStraight,
    };
}

// Ported from the exit branch of ManeuversBuilder::SetManeuverType.
pub fn exitType(value: *const Maneuver) Type {
    return switch (value.begin_relative_direction) {
        .keep_right, .right => .kExitRight,
        .keep_left, .left => .kExitLeft,
        else => if (value.drive_on_right) .kExitRight else .kExitLeft,
    };
}

// Ported from the on-ramp branch of ManeuversBuilder::SetManeuverType.
pub fn rampType(value: *const Maneuver) Type {
    return switch (value.begin_relative_direction) {
        .keep_right, .right, .none => .kRampRight,
        .keep_left, .left => .kRampLeft,
        .keep_straight => .kRampStraight,
        .reverse => if (turnsLeft(value.turn_degree, value.drive_on_right)) .kRampLeft else .kRampRight,
    };
}

// Ported from the reverse branch of ManeuversBuilder::SetSimpleDirectionalManeuverType.
pub fn reverseType(value: *const Maneuver, drive_on_right: bool) Type {
    if (value.internal_left_turn_count != value.internal_right_turn_count)
        return if (value.internal_left_turn_count > value.internal_right_turn_count) .kUturnLeft else .kUturnRight;
    return switch (value.begin_relative_direction) {
        .keep_left => .kUturnLeft,
        .keep_right => .kUturnRight,
        else => if (turnsLeft(value.turn_degree, drive_on_right)) .kUturnLeft else .kUturnRight,
    };
}

fn turnsLeft(degree: u32, drive_on_right: bool) bool {
    return degree > 180 or (degree == 180 and drive_on_right);
}

// Ported from ManeuversBuilder::IsMergeManeuverType and DetermineMergeToRelativeDirection.
pub fn mergeDirection(at: Context, degree: u32) !?maneuver.RelativeDirection {
    if (!at.previous.isRampUse() or at.current.isRampUse()) return null;
    const road_class = at.current.value.road_class;
    const highway = at.current.isHighway();
    const major_oneway = (road_class == .kTrunk or road_class == .kPrimary) and at.current.isOneway() and at.current.isForward(degree);
    if (!highway and (!major_oneway or !try at.node.hasIntersectingEdgeCurrNameConsistency())) return null;
    const counts = try at.node.countIntersectingEdges(at.previous.value.end_heading, at.previous.value.travel_mode);
    if (counts.left.all > 0 and counts.left.similar == 0 and counts.right.all == 0) return .keep_left;
    if (counts.right.all > 0 and counts.right.similar == 0 and counts.left.all == 0) return .keep_right;
    return .none;
}

// Ported from ManeuversBuilder::IsFork.
pub fn isFork(leg: enhanced.Leg, index: usize, at: Context) !bool {
    const intersections = at.node.value.intersecting_edge;
    if (intersections.len < 1 or intersections.len > 2) return false;
    const previous = at.previous;
    const current = at.current;
    const heading = previous.value.end_heading;
    const degree = at.degree();
    const mode = previous.value.travel_mode;
    const path_class = previous.value.road_class;
    if (at.node.value.fork and current.isWiderForward(degree) and
        try at.node.hasWiderForwardTraversableIntersectingEdge(heading, current.value.travel_mode))
    {
        if (at.node.isMotorwayJunction() and current.value.road_class != .kServiceOther and
            try at.node.hasSpecifiedRoadClassEdge(.kServiceOther)) return false;
        const counts = try at.node.countIntersectingEdges(heading, mode);
        if (counts.left.similar_traversable_outbound != 0 or counts.right.similar_traversable_outbound != 0) return true;
        if ((counts.left.traversable_outbound != 0 or counts.right.traversable_outbound != 0) and
            current.isRampUse() and !try at.node.isStraightestTraversableIntersectingEdgeReversed(heading, mode)) return true;
        return current.isForkForward(degree) and try at.node.hasOnlyForwardTraversableRoadClassEdges(heading, mode, path_class);
    }
    if (previous.isHighway() and current.isHighway() and current.isWiderForward(degree) and
        try at.node.hasWiderForwardTraversableHighwayEdge(heading, mode)) return true;
    if (current.isForkForward(degree) and roadCanFork(previous) and roadCanFork(current)) {
        if (@backingInt(path_class) >= @backingInt(current.value.road_class) and
            try at.node.hasOnlyForwardTraversableRoadClassEdges(heading, mode, path_class)) return true;
        const allow_service = path_class == .kServiceOther or current.value.road_class == .kServiceOther;
        if (try at.node.hasRoadForkTraversableIntersectingEdge(heading, mode, allow_service)) return true;
    }
    if (intersections.len != 1 or !previous.isHighway()) return false;
    const crossing = at.node.intersection(0).?;
    if (!((current.isHighway() and crossing.value.use == .kRampUse) or (crossing.isHighway() and current.isRampUse()))) return false;
    if (!try hasLaneBifurcation(leg, index, at, crossing)) return false;
    return previous.isForkForward(degree) and previous.isForkForward(crossing.turnDegree(heading));
}

fn roadCanFork(edge: enhanced.Edge) bool {
    return !(edge.isRampUse() or edge.isTurnChannelUse() or edge.isFerryUse() or edge.isRailFerryUse());
}

// Ported from the lane bifurcation branch inside ManeuversBuilder::IsFork.
fn hasLaneBifurcation(leg: enhanced.Leg, index: usize, at: Context, crossing: enhanced.IntersectingEdge) !bool {
    const previous = at.previous.value;
    const before: u64 = previous.lane_count;
    const after: u64 = at.current.value.lane_count;
    if (after > 1 and before == after + 1 and crossing.value.use == .kRampUse) {
        const speed = previous.default_speed;
        const typical: f32 = if (speed < 80) 0.1 else @floatCast(0.00141994 * @as(f64, speed) + 0.03509388);
        const tolerance = typical * 0.35;
        const upper = typical + tolerance;
        var distance = previous.length_km;
        var delta: usize = 2;
        while (true) : (delta += 1) {
            if (leg.deadline.expired()) return error.DeadlineExceeded;
            const edge = leg.prevEdge(index, delta) orelse {
                distance = 0;
                break;
            };
            if (edge.value.lane_count < before) break;
            distance += edge.value.length_km;
            if (distance > upper) break;
        }
        if (distance > typical - tolerance and distance < upper) return false;
    }
    if (before == 2) return after == 1 and crossing.value.lane_count == 1;
    const split = (before + 1) / 2;
    return before > 2 and after == split and crossing.value.lane_count == split;
}

// Ported from ManeuversBuilder::IsLeftPencilPointUturn and IsRightPencilPointUturn.
pub fn pencilPointUturn(at: Context, name_style: maneuver.NameStyle) !?Type {
    const degree = at.degree();
    if (at.current.value.drive_on_left or !at.previous.isOneway() or !at.current.isOneway()) return null;
    if (degree <= 134 or degree >= 226) return null;
    const counts = try at.node.countIntersectingEdges(at.previous.value.end_heading, at.previous.value.travel_mode);
    const left = degree >= 180 and counts.left.traversable_outbound == 0;
    const right = degree <= 180 and counts.right.traversable_outbound == 0;
    if (!left and !right) return null;
    for (at.previous.nameList()) |previous| {
        const base = maneuver.baseName(previous.value, name_style);
        if (at.node.deadline.expired()) return error.DeadlineExceeded;
        for (at.current.nameList(), 0..) |current, i| {
            if (i % 64 == 0 and at.node.deadline.expired()) return error.DeadlineExceeded;
            if (std.mem.eql(u8, base, maneuver.baseName(current.value, name_style))) return if (left) .kUturnLeft else .kUturnRight;
        }
    }
    return null;
}

// Ported from ManeuversBuilder::IsPedestrianFork.
pub fn isPedestrianFork(at: Context) !bool {
    const previous = at.previous.value;
    const current = at.current.value;
    const path = at.degree();
    if (previous.travel_mode != .kPedestrian or current.travel_mode != .kPedestrian or
        turn.delta(path, 0) >= 45 or at.node.value.intersecting_edge.len >= 3) return false;
    if (previous.roundabout and !current.roundabout) return true;
    const crossing = try at.node.straightestIntersectingEdge(previous.end_heading, .kPedestrian);
    const use = crossing.use orelse return false;
    if (current.use != use and !(at.current.isFootwayUse() and (use == .kPedestrianCrossingUse or use == .kFootwayUse))) return false;
    if (turn.delta(crossing.degree, 0) < 45) return true;
    const counts = try at.node.countIntersectingEdges(previous.end_heading, .kPedestrian);
    return counts.left.similar_traversable_outbound > 0 or counts.right.similar_traversable_outbound > 0;
}

// Ported from the five deceleration lane cases in test/gurka/test_forks.cc.
test "highway lane bifurcation distinguishes deceleration lanes" {
    for ([_]struct { length: f32, starts_on_extra_lane: bool, left_traffic: bool, fork: bool }{
        .{ .length = 0.2, .starts_on_extra_lane = false, .left_traffic = false, .fork = false },
        .{ .length = 0.2, .starts_on_extra_lane = false, .left_traffic = true, .fork = false },
        .{ .length = 0.13, .starts_on_extra_lane = false, .left_traffic = false, .fork = true },
        .{ .length = 0.35, .starts_on_extra_lane = false, .left_traffic = false, .fork = true },
        .{ .length = 0.2, .starts_on_extra_lane = true, .left_traffic = false, .fork = true },
    }) |case| {
        const crossing: trip.IntersectingEdge = .{
            .begin_heading = if (case.left_traffic) 75 else 105,
            .use = .kRampUse,
            .driveability = .kForward,
            .lane_count = 2,
        };
        const nodes = [_]trip.Node{
            .{ .edge = .{ .end_heading = 90, .lane_count = 2 } },
            .{ .edge = .{ .end_heading = 90, .lane_count = 3, .length_km = case.length, .default_speed = 120 } },
            .{ .edge = .{ .begin_heading = 90, .lane_count = 2 }, .intersecting_edge = &.{crossing} },
        };
        const path: trip.TripLeg = .{ .node = if (case.starts_on_extra_lane) nodes[1..] else &nodes };
        const leg: enhanced.Leg = .{ .value = &path };
        const index = path.node.len - 1;
        try std.testing.expectEqual(case.fork, try isFork(leg, index, .{
            .node = leg.node(index).?,
            .previous = leg.prevEdge(index, 1).?,
            .current = leg.currEdge(index).?,
        }));
    }
}

test "pencil point U-turns depend on direction, shared base name and outbound crossings" {
    const south = [_]trip.StreetName{.{ .value = "US 322 South", .is_route_number = true }};
    const north = [_]trip.StreetName{.{ .value = "US 322 North", .is_route_number = true }};
    const previous: trip.Edge = .{ .name = &south, .traversability = .kForward };
    var current: trip.Edge = .{ .name = &north, .traversability = .kForward, .begin_heading = 210 };
    var node: trip.Node = .{};
    const at: Context = .{ .node = .{ .value = &node }, .previous = .{ .value = &previous }, .current = .{ .value = &current } };
    try std.testing.expectEqual(.kUturnLeft, try pencilPointUturn(at, .us));
    try std.testing.expectEqual(null, try pencilPointUturn(at, .generic));
    node.intersecting_edge = &.{.{ .begin_heading = 270, .driveability = .kForward }};
    try std.testing.expectEqual(null, try pencilPointUturn(at, .us));
    current.begin_heading = 150;
    try std.testing.expectEqual(.kUturnRight, try pencilPointUturn(at, .us));
    current.traversability = .kBoth;
    try std.testing.expectEqual(null, try pencilPointUturn(at, .us));
}

test "fork directions preserve the stay-straight case" {
    try std.testing.expectEqual(.kStayLeft, forkType(.keep_left));
    try std.testing.expectEqual(.kStayStraight, forkType(.keep_straight));
    try std.testing.expectEqual(.kStayRight, forkType(.keep_right));
}

test "merge side depends on the position of the main road" {
    const approach: trip.Edge = .{ .use = .kRampUse, .road_class = .kSecondary };
    var highway: trip.Edge = .{};
    var node: trip.Node = .{};
    const at: Context = .{ .node = .{ .value = &node }, .previous = .{ .value = &approach }, .current = .{ .value = &highway } };
    try std.testing.expectEqual(.none, try mergeDirection(at, at.degree()));
    node.intersecting_edge = &.{.{ .begin_heading = 270 }};
    try std.testing.expectEqual(.keep_left, try mergeDirection(at, at.degree()));
    node.intersecting_edge = &.{.{ .begin_heading = 90, .curr_name_consistency = true }};
    try std.testing.expectEqual(.keep_right, try mergeDirection(at, at.degree()));
    highway.road_class = .kPrimary;
    highway.traversability = .kForward;
    try std.testing.expectEqual(.keep_right, try mergeDirection(at, at.degree()));
    node.intersecting_edge = &.{.{ .begin_heading = 90 }};
    try std.testing.expectEqual(null, try mergeDirection(at, at.degree()));
}
