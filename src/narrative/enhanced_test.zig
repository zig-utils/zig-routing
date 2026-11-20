// Ported from test/enhancedtrippath.cc (Valhalla 3.9.3).
const std = @import("std");
const trip = @import("../api/trip.zig");
const directions = @import("../api/directions.zig");
const lanes = @import("../graph/lanes.zig");
const enhanced = @import("enhanced.zig");
const maneuver = @import("maneuver.zig");
const io = @import("../infra/io.zig");
const testing = std.testing;

fn side(all: u32, similar: u32, outbound: u32, similar_outbound: u32) enhanced.IntersectingEdgeCounts.Side {
    return .{ .all = all, .similar = similar, .traversable_outbound = outbound, .similar_traversable_outbound = similar_outbound };
}

fn cross(heading: u32, access: trip.Traversability) trip.IntersectingEdge {
    return .{ .begin_heading = heading, .driveability = access };
}

test "upstream enhanced trip path counts right and left intersections" {
    const cases = [_]struct {
        from: u32,
        path: u32,
        intersections: []const trip.IntersectingEdge,
        expected: enhanced.IntersectingEdgeCounts,
    }{
        .{ .from = 0, .path = 5, .intersections = &.{cross(355, .kBoth)}, .expected = .{ .left = side(1, 1, 1, 1) } },
        .{ .from = 0, .path = 355, .intersections = &.{cross(5, .kForward)}, .expected = .{ .right = side(1, 1, 1, 1) } },
        .{ .from = 0, .path = 11, .intersections = &.{cross(0, .kBackward)}, .expected = .{ .left = side(1, 1, 0, 0) } },
        .{ .from = 90, .path = 105, .intersections = &.{cross(85, .kNone)}, .expected = .{ .left = side(1, 1, 0, 0) } },
        .{ .from = 0, .path = 345, .intersections = &.{cross(355, .kNone)}, .expected = .{ .right = side(1, 1, 0, 0) } },
        .{ .from = 270, .path = 255, .intersections = &.{cross(275, .kNone)}, .expected = .{ .right = side(1, 1, 0, 0) } },
        .{ .from = 0, .path = 340, .intersections = &.{
            cross(45, .kNone), cross(90, .kNone), cross(135, .kNone), cross(315, .kNone), cross(270, .kNone), cross(225, .kNone),
        }, .expected = .{ .right = side(3, 0, 0, 0), .left = side(3, 1, 0, 0) } },
        .{ .from = 80, .path = 60, .intersections = &.{ cross(157, .kBoth), cross(337, .kForward) }, .expected = .{
            .right = side(1, 0, 1, 0),
            .left = side(1, 0, 1, 0),
        } },
        .{ .from = 180, .path = 352, .intersections = &.{
            cross(355, .kNone), cross(270, .kNone), cross(180, .kNone), cross(90, .kNone), cross(10, .kNone),
        }, .expected = .{ .right = side(1, 1, 0, 0), .left = side(4, 0, 0, 0) } },
        .{ .from = 180, .path = 10, .intersections = &.{
            cross(90, .kNone), cross(180, .kNone), cross(270, .kNone), cross(352, .kNone), cross(355, .kNone), cross(5, .kNone),
        }, .expected = .{ .right = side(5, 0, 0, 0), .left = side(1, 1, 0, 0) } },
    };
    for (cases) |case| {
        const at: trip.Node = .{ .edge = .{ .begin_heading = case.path }, .intersecting_edge = case.intersections };
        const view: enhanced.Node = .{ .value = &at };
        try testing.expectEqual(case.expected, try view.countIntersectingEdges(case.from, .kDrive));
    }
}

test "borrowed trip-leg views access the path and endpoints" {
    const nodes = [_]trip.Node{
        .{ .edge = .{ .length_km = 1.5 } },
        .{ .edge = .{ .length_km = 2.5, .name = &.{.{ .value = "High Street" }} } },
        .{ .cost = .{ .elapsed_cost = .{ .seconds = 55 } } },
    };
    const locations = [_]trip.Location{ .{ .name = "Origin" }, .{ .name = "Destination" } };
    const admins = [_]trip.Admin{.{ .country_code = "GB", .state_code = "ENG" }};
    const raw: trip.TripLeg = .{ .node = &nodes, .location = &locations, .admin = &admins };
    const leg: enhanced.Leg = .{ .value = &raw };
    try testing.expectEqual(2, leg.lastNodeIndex().?);
    try testing.expectEqual(&nodes[0].edge.?, leg.prevEdge(1, 1).?.value);
    try testing.expectEqual(&nodes[1].edge.?, leg.nextEdge(0, 1).?.value);
    try testing.expectEqual(&nodes[1].edge.?, leg.currEdge(1).?.value);
    try testing.expect(leg.prevEdge(0, 1) == null);
    try testing.expect(leg.currEdge(2) == null);
    try testing.expect(leg.nextEdge(1, std.math.maxInt(usize)) == null);
    try testing.expectEqualStrings("GB", leg.countryCode(1));
    try testing.expectEqualStrings("ENG", leg.stateCode(1));
    try testing.expectEqual(&locations[0], try leg.origin());
    try testing.expectEqual(&locations[1], try leg.destination());
    try testing.expectEqual(55, leg.node(2).?.elapsedTime());
    try testing.expectEqual(4, try leg.length(.kilometers));
    try testing.expectApproxEqAbs(@as(f32, 2.485484), try leg.length(.miles), 0.000001);
    try testing.expectError(error.MissingLocations, (enhanced.Leg{ .value = &.{} }).origin());
    const cancelled: enhanced.Leg = .{ .value = &raw, .deadline = .{ .at_ns = 0 } };
    try testing.expectError(error.DeadlineExceeded, cancelled.length(.kilometers));
}

test "upstream turn lane activation on long and short approaches" {
    const layout_1 = [_]lanes.Mask{ lanes.reverse, lanes.sharp_left, lanes.left, lanes.left, lanes.left | lanes.through, lanes.through, lanes.through, lanes.through | lanes.right, lanes.right, lanes.sharp_right };
    const layout_2 = [_]lanes.Mask{ lanes.slight_left, lanes.slight_left, lanes.through, lanes.through, lanes.through, lanes.merge_to_right };
    const layout_3 = [_]lanes.Mask{ lanes.merge_to_left, lanes.through, lanes.through, lanes.through, lanes.slight_right, lanes.slight_right };
    const layout_4 = [_]lanes.Mask{ lanes.left, lanes.left, lanes.through, lanes.through, lanes.through, lanes.right, lanes.right };
    const cases = [_]struct {
        layout: []const lanes.Mask,
        direction: lanes.Mask,
        km: f32,
        current: directions.ManeuverType,
        next: directions.ManeuverType,
        active: u16,
    }{
        .{ .layout = &layout_1, .direction = lanes.reverse, .km = 2.0, .current = .kUturnLeft, .next = .kRight, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.sharp_left, .km = 2.0, .current = .kSharpLeft, .next = .kRight, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.left, .km = 2.0, .current = .kLeft, .next = .kRight, .active = 3 },
        .{ .layout = &layout_1, .direction = lanes.slight_left, .km = 2.0, .current = .kSlightLeft, .next = .kRight, .active = 0 },
        .{ .layout = &layout_1, .direction = lanes.through, .km = 2.0, .current = .kContinue, .next = .kRight, .active = 4 },
        .{ .layout = &layout_1, .direction = lanes.slight_right, .km = 2.0, .current = .kSlightRight, .next = .kRight, .active = 0 },
        .{ .layout = &layout_1, .direction = lanes.right, .km = 2.0, .current = .kRight, .next = .kRight, .active = 2 },
        .{ .layout = &layout_1, .direction = lanes.sharp_right, .km = 2.0, .current = .kSharpRight, .next = .kRight, .active = 1 },
        .{ .layout = &layout_2, .direction = lanes.slight_left, .km = 2.0, .current = .kSlightLeft, .next = .kRight, .active = 2 },
        .{ .layout = &layout_2, .direction = lanes.through, .km = 2.0, .current = .kContinue, .next = .kRight, .active = 3 },
        .{ .layout = &layout_2, .direction = lanes.merge_to_right, .km = 2.0, .current = .kMergeRight, .next = .kRight, .active = 1 },
        .{ .layout = &layout_3, .direction = lanes.merge_to_left, .km = 2.0, .current = .kMergeLeft, .next = .kRight, .active = 1 },
        .{ .layout = &layout_3, .direction = lanes.through, .km = 2.0, .current = .kContinue, .next = .kRight, .active = 3 },
        .{ .layout = &layout_3, .direction = lanes.slight_right, .km = 2.0, .current = .kSlightRight, .next = .kRight, .active = 2 },
        .{ .layout = &layout_4, .direction = lanes.left, .km = 2.0, .current = .kLeft, .next = .kRight, .active = 2 },
        .{ .layout = &layout_4, .direction = lanes.left, .km = 2.0, .current = .kUturnLeft, .next = .kRight, .active = 1 },
        .{ .layout = &layout_4, .direction = lanes.right, .km = 2.0, .current = .kRight, .next = .kRight, .active = 2 },
        .{ .layout = &layout_4, .direction = lanes.right, .km = 2.0, .current = .kUturnRight, .next = .kRight, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.reverse, .km = 0.1, .current = .kUturnLeft, .next = .kRight, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.sharp_left, .km = 0.1, .current = .kSharpLeft, .next = .kRight, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.left, .km = 0.1, .current = .kLeft, .next = .kRight, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.slight_left, .km = 0.1, .current = .kSlightLeft, .next = .kRight, .active = 0 },
        .{ .layout = &layout_1, .direction = lanes.through, .km = 0.1, .current = .kContinue, .next = .kRight, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.slight_right, .km = 0.1, .current = .kSlightRight, .next = .kRight, .active = 0 },
        .{ .layout = &layout_1, .direction = lanes.right, .km = 0.1, .current = .kRight, .next = .kRight, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.sharp_right, .km = 0.1, .current = .kSharpRight, .next = .kRight, .active = 1 },
        .{ .layout = &layout_2, .direction = lanes.slight_left, .km = 0.1, .current = .kSlightLeft, .next = .kRight, .active = 1 },
        .{ .layout = &layout_2, .direction = lanes.through, .km = 0.1, .current = .kContinue, .next = .kRight, .active = 1 },
        .{ .layout = &layout_2, .direction = lanes.merge_to_right, .km = 0.1, .current = .kMergeRight, .next = .kRight, .active = 1 },
        .{ .layout = &layout_3, .direction = lanes.merge_to_left, .km = 0.1, .current = .kMergeLeft, .next = .kRight, .active = 1 },
        .{ .layout = &layout_3, .direction = lanes.through, .km = 0.1, .current = .kContinue, .next = .kRight, .active = 1 },
        .{ .layout = &layout_3, .direction = lanes.slight_right, .km = 0.1, .current = .kSlightRight, .next = .kRight, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.reverse, .km = 0.1, .current = .kUturnLeft, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.sharp_left, .km = 0.1, .current = .kSharpLeft, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.left, .km = 0.1, .current = .kLeft, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.slight_left, .km = 0.1, .current = .kSlightLeft, .next = .kLeft, .active = 0 },
        .{ .layout = &layout_1, .direction = lanes.through, .km = 0.1, .current = .kContinue, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.slight_right, .km = 0.1, .current = .kSlightRight, .next = .kLeft, .active = 0 },
        .{ .layout = &layout_1, .direction = lanes.right, .km = 0.1, .current = .kRight, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_1, .direction = lanes.sharp_right, .km = 0.1, .current = .kSharpRight, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_2, .direction = lanes.slight_left, .km = 0.1, .current = .kSlightLeft, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_2, .direction = lanes.through, .km = 0.1, .current = .kContinue, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_2, .direction = lanes.merge_to_right, .km = 0.1, .current = .kMergeRight, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_3, .direction = lanes.merge_to_left, .km = 0.1, .current = .kMergeLeft, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_3, .direction = lanes.through, .km = 0.1, .current = .kContinue, .next = .kLeft, .active = 1 },
        .{ .layout = &layout_3, .direction = lanes.slight_right, .km = 0.1, .current = .kSlightRight, .next = .kLeft, .active = 1 },
    };
    for (cases) |case| {
        var records: [10]trip.TurnLane = @splat(.{});
        for (records[0..case.layout.len], case.layout) |*record, mask| record.directions_mask = mask;
        const raw: trip.Edge = .{ .turn_lanes = records[0..case.layout.len] };
        const edge: enhanced.Edge = .{ .value = &raw };
        try testing.expect(!(try edge.hasActiveTurnLane()));
        try testing.expectEqual(case.active, try edge.activateTurnLanes(case.direction, case.km, case.current, case.next));
        try testing.expectEqual(case.active != 0, try edge.hasActiveTurnLane());
    }
}

test "Valhalla edge use predicates cover every encoded use" {
    const cases = [_]struct { predicate: *const fn (enhanced.Edge) bool, matches: []const trip.Use }{
        .{ .predicate = enhanced.Edge.isRoadUse, .matches = &.{ .kRoadUse, .kServiceRoadUse } },
        .{ .predicate = enhanced.Edge.isFootwayUse, .matches = &.{ .kFootwayUse, .kPedestrianCrossingUse } },
        .{ .predicate = enhanced.Edge.isRampUse, .matches = &.{.kRampUse} },
        .{ .predicate = enhanced.Edge.isTurnChannelUse, .matches = &.{.kTurnChannelUse} },
        .{ .predicate = enhanced.Edge.isTrackUse, .matches = &.{.kTrackUse} },
        .{ .predicate = enhanced.Edge.isDrivewayUse, .matches = &.{.kDrivewayUse} },
        .{ .predicate = enhanced.Edge.isAlleyUse, .matches = &.{.kAlleyUse} },
        .{ .predicate = enhanced.Edge.isParkingAisleUse, .matches = &.{.kParkingAisleUse} },
        .{ .predicate = enhanced.Edge.isEmergencyAccessUse, .matches = &.{.kEmergencyAccessUse} },
        .{ .predicate = enhanced.Edge.isDriveThruUse, .matches = &.{.kDriveThruUse} },
        .{ .predicate = enhanced.Edge.isCuldesacUse, .matches = &.{.kCuldesacUse} },
        .{ .predicate = enhanced.Edge.isCyclewayUse, .matches = &.{.kCyclewayUse} },
        .{ .predicate = enhanced.Edge.isMountainBikeUse, .matches = &.{.kMountainBikeUse} },
        .{ .predicate = enhanced.Edge.isSidewalkUse, .matches = &.{.kSidewalkUse} },
        .{ .predicate = enhanced.Edge.isPedestrianCrossingUse, .matches = &.{.kPedestrianCrossingUse} },
        .{ .predicate = enhanced.Edge.isElevatorUse, .matches = &.{.kElevatorUse} },
        .{ .predicate = enhanced.Edge.isStepsUse, .matches = &.{.kStepsUse} },
        .{ .predicate = enhanced.Edge.isEscalatorUse, .matches = &.{.kEscalatorUse} },
        .{ .predicate = enhanced.Edge.isPathUse, .matches = &.{.kPathUse} },
        .{ .predicate = enhanced.Edge.isPedestrianUse, .matches = &.{.kPedestrianUse} },
        .{ .predicate = enhanced.Edge.isBridlewayUse, .matches = &.{.kBridlewayUse} },
        .{ .predicate = enhanced.Edge.isRestAreaUse, .matches = &.{.kRestAreaUse} },
        .{ .predicate = enhanced.Edge.isServiceAreaUse, .matches = &.{.kServiceAreaUse} },
        .{ .predicate = enhanced.Edge.isOtherUse, .matches = &.{.kOtherUse} },
        .{ .predicate = enhanced.Edge.isFerryUse, .matches = &.{.kFerryUse} },
        .{ .predicate = enhanced.Edge.isRailFerryUse, .matches = &.{.kRailFerryUse} },
        .{ .predicate = enhanced.Edge.isRailUse, .matches = &.{.kRailUse} },
        .{ .predicate = enhanced.Edge.isBusUse, .matches = &.{.kBusUse} },
        .{ .predicate = enhanced.Edge.isEgressConnectionUse, .matches = &.{.kEgressConnectionUse} },
        .{ .predicate = enhanced.Edge.isPlatformConnectionUse, .matches = &.{.kPlatformConnectionUse} },
        .{ .predicate = enhanced.Edge.isTransitConnectionUse, .matches = &.{.kTransitConnectionUse} },
        .{ .predicate = enhanced.Edge.isConstructionUse, .matches = &.{.kConstructionUse} },
    };
    for (cases) |case| {
        for (std.enums.values(trip.Use)) |use| {
            const raw: trip.Edge = .{ .use = use };
            try testing.expectEqual(std.mem.findScalar(trip.Use, case.matches, use) != null, case.predicate(.{ .value = &raw }));
        }
    }
}

test "Valhalla node type predicates cover every category" {
    const cases = [_]struct { predicate: *const fn (enhanced.Node) bool, matches: trip.NodeType }{
        .{ .predicate = enhanced.Node.isStreetIntersection, .matches = .kStreetIntersection },
        .{ .predicate = enhanced.Node.isGate, .matches = .kGate },
        .{ .predicate = enhanced.Node.isBollard, .matches = .kBollard },
        .{ .predicate = enhanced.Node.isTollBooth, .matches = .kTollBooth },
        .{ .predicate = enhanced.Node.isTransitEgress, .matches = .kTransitEgress },
        .{ .predicate = enhanced.Node.isTransitStation, .matches = .kTransitStation },
        .{ .predicate = enhanced.Node.isTransitPlatform, .matches = .kTransitPlatform },
        .{ .predicate = enhanced.Node.isBikeShare, .matches = .kBikeShare },
        .{ .predicate = enhanced.Node.isParking, .matches = .kParking },
        .{ .predicate = enhanced.Node.isMotorwayJunction, .matches = .kMotorwayJunction },
        .{ .predicate = enhanced.Node.isBorderControl, .matches = .kBorderControl },
        .{ .predicate = enhanced.Node.isTollGantry, .matches = .kTollGantry },
        .{ .predicate = enhanced.Node.isSumpBuster, .matches = .kSumpBuster },
        .{ .predicate = enhanced.Node.isBuildingEntrance, .matches = .kBuildingEntrance },
        .{ .predicate = enhanced.Node.isElevator, .matches = .kElevator },
    };
    for (cases) |case| {
        for (std.enums.values(trip.NodeType)) |node_type| {
            const raw: trip.Node = .{ .type = node_type };
            try testing.expectEqual(case.matches == node_type, case.predicate(.{ .value = &raw }));
        }
    }
}

test "Valhalla forward and straightest angle bounds" {
    const edge: enhanced.Edge = .{ .value = &.{} };
    const cases = [_]struct { degree: u32, fork: bool, forward: bool, wider: bool }{
        .{ .degree = 0, .fork = true, .forward = true, .wider = true },
        .{ .degree = 20, .fork = true, .forward = true, .wider = true },
        .{ .degree = 21, .fork = false, .forward = true, .wider = true },
        .{ .degree = 45, .fork = false, .forward = true, .wider = true },
        .{ .degree = 46, .fork = false, .forward = false, .wider = true },
        .{ .degree = 55, .fork = false, .forward = false, .wider = true },
        .{ .degree = 56, .fork = false, .forward = false, .wider = false },
        .{ .degree = 304, .fork = false, .forward = false, .wider = false },
        .{ .degree = 305, .fork = false, .forward = false, .wider = true },
        .{ .degree = 314, .fork = false, .forward = false, .wider = true },
        .{ .degree = 315, .fork = false, .forward = true, .wider = true },
        .{ .degree = 339, .fork = false, .forward = true, .wider = true },
        .{ .degree = 340, .fork = true, .forward = true, .wider = true },
    };
    for (cases) |case| {
        try testing.expectEqual(case.fork, edge.isForkForward(case.degree));
        try testing.expectEqual(case.forward, edge.isForward(case.degree));
        try testing.expectEqual(case.wider, edge.isWiderForward(case.degree));
    }
    const straightest = [_]struct { path: u32, crossing: u32, expected: bool }{
        .{ .path = 10, .crossing = 0, .expected = true },
        .{ .path = 11, .crossing = 0, .expected = false },
        .{ .path = 350, .crossing = 0, .expected = true },
        .{ .path = 56, .crossing = 180, .expected = false },
        .{ .path = 55, .crossing = 180, .expected = true },
    };
    for (straightest) |case|
        try testing.expectEqual(case.expected, edge.isStraightest(case.path, case.crossing));
}

test "Valhalla edge defaults and alternate uses" {
    const cases = [_]struct { use: trip.Use, highway: bool, walkway: bool, cycleway: bool, mtb: bool, transit: bool }{
        .{ .use = .kRoadUse, .highway = true, .walkway = false, .cycleway = false, .mtb = false, .transit = false },
        .{ .use = .kRampUse, .highway = false, .walkway = false, .cycleway = false, .mtb = false, .transit = false },
        .{ .use = .kTurnChannelUse, .highway = false, .walkway = false, .cycleway = false, .mtb = false, .transit = false },
        .{ .use = .kFootwayUse, .highway = true, .walkway = true, .cycleway = false, .mtb = false, .transit = false },
        .{ .use = .kPedestrianCrossingUse, .highway = true, .walkway = true, .cycleway = false, .mtb = false, .transit = false },
        .{ .use = .kCyclewayUse, .highway = true, .walkway = false, .cycleway = true, .mtb = false, .transit = false },
        .{ .use = .kMountainBikeUse, .highway = true, .walkway = false, .cycleway = false, .mtb = true, .transit = false },
        .{ .use = .kEgressConnectionUse, .highway = true, .walkway = false, .cycleway = false, .mtb = false, .transit = true },
        .{ .use = .kPlatformConnectionUse, .highway = true, .walkway = false, .cycleway = false, .mtb = false, .transit = true },
        .{ .use = .kTransitConnectionUse, .highway = true, .walkway = false, .cycleway = false, .mtb = false, .transit = true },
    };
    for (cases) |case| {
        var raw: trip.Edge = .{ .use = case.use, .road_class = .kMotorway };
        const edge: enhanced.Edge = .{ .value = &raw };
        try testing.expect(edge.isUnnamed());
        try testing.expectEqual(case.highway, edge.isHighway());
        try testing.expectEqual(case.highway, (enhanced.IntersectingEdge{ .value = &.{ .use = case.use } }).isHighway());
        try testing.expectEqual(case.walkway, edge.isUnnamedWalkway());
        try testing.expectEqual(case.cycleway, edge.isUnnamedCycleway());
        try testing.expectEqual(case.mtb, edge.isUnnamedMountainBikeTrail());
        try testing.expectEqual(case.transit, edge.isTransitConnection());
        raw.name = &.{.{ .value = "Main" }};
        try testing.expect(!edge.isUnnamed());
        try testing.expect(!edge.isUnnamedWalkway() and !edge.isUnnamedCycleway() and !edge.isUnnamedMountainBikeTrail());
        try testing.expectEqualStrings("Main", edge.nameList()[0].value);
    }
    for (std.enums.values(trip.Traversability), [_]bool{ false, true, true, false }) |access, oneway| {
        const edge: enhanced.Edge = .{ .value = &.{ .traversability = access } };
        try testing.expectEqual(oneway, edge.isOneway());
    }
    for (std.enums.values(trip.TravelMode)) |mode| {
        const edge: enhanced.Edge = .{ .value = &.{ .travel_mode = mode } };
        try testing.expectEqual(mode == .kDrive, edge.hasVehicleType());
        try testing.expectEqual(mode == .kPedestrian, edge.hasPedestrianType());
        try testing.expectEqual(mode == .kBicycle, edge.hasBicycleType());
        try testing.expectEqual(mode == .kTransit, edge.hasTransitType());
    }
}

test "upstream lane defaults and debug output for two driving sides" {
    const cases = [_]struct { mask: lanes.Mask, directional: bool, requested_turn: bool }{
        .{ .mask = 0, .directional = false, .requested_turn = false },
        .{ .mask = lanes.none, .directional = false, .requested_turn = false },
        .{ .mask = lanes.left, .directional = true, .requested_turn = true },
        .{ .mask = lanes.right, .directional = true, .requested_turn = false },
    };
    for (cases) |case| {
        var records = [_]trip.TurnLane{.{ .directions_mask = case.mask }};
        const edge: enhanced.Edge = .{ .value = &.{ .turn_lanes = &records } };
        try testing.expect(!(try edge.hasActiveTurnLane()));
        try testing.expectEqual(!case.directional, try edge.hasNonDirectionalTurnLane());
        try testing.expectEqual(case.requested_turn, try edge.hasTurnLane(lanes.left));
    }
    var records = [_]trip.TurnLane{
        .{ .directions_mask = lanes.reverse | lanes.left, .state = .kActive, .active_direction = lanes.reverse },
        .{ .directions_mask = lanes.through | lanes.right, .state = .kValid, .active_direction = lanes.right },
        .{},
        .{ .directions_mask = lanes.none },
    };
    var raw: trip.Edge = .{ .turn_lanes = &records };
    const edge: enhanced.Edge = .{ .value = &raw };
    var bytes: [256]u8 = undefined;
    var out = io.Writer.fixed(&bytes);
    try edge.writeTurnLanes(&out);
    try testing.expectEqualStrings("[ *reverse*;left ACTIVE | through;*right* VALID | empty | none ]", out.buffered());
    raw.drive_on_left = true;
    out = io.Writer.fixed(&bytes);
    try edge.writeTurnLanes(&out);
    try testing.expectEqualStrings("[ left;*reverse* ACTIVE | through;*right* VALID | empty | none ]", out.buffered());
    try testing.expectEqual(0, try edge.activateTurnLanes(lanes.left, 1, .kLeft, .kRight));
}

test "enhanced debug strings preserve pinned field names and pronunciations" {
    const edge: enhanced.Edge = .{ .value = &.{ .length_km = 1.25, .name = &.{.{
        .value = "Main",
        .pronunciation = .{ .value = "meɪn" },
    }} } };
    var bytes: [4096]u8 = undefined;
    var out = io.Writer.fixed(&bytes);
    try edge.writeDebug(&out);
    try testing.expect(std.mem.startsWith(u8, out.buffered(), "name=Main(meɪn) | length=1.250000 | speed=0.000000"));
    const node: enhanced.Node = .{ .value = &.{ .time_zone = "Europe/London", .fork = true } };
    out = io.Writer.fixed(&bytes);
    try node.writeDebug(&out);
    try testing.expectEqualStrings("elapsed_time=0.000000 | admin_index=0 | type=0 | fork=1 | time_zone=Europe/London", out.buffered());
    const at: enhanced.IntersectingEdge = .{ .value = &.{ .begin_heading = 90, .driveability = .kBoth, .use = .kRampUse } };
    out = io.Writer.fixed(&bytes);
    try at.writeDebug(&out);
    try testing.expectEqualStrings("begin_heading=90 | prev_name_consistency=0 | curr_name_consistency=0 | driveability=3 | cyclability=0 | walkability=0 | use=1 | road_class=0 | lane_count=0", out.buffered());
    const admin: enhanced.Admin = .{ .value = &.{ .country_code = "GB", .country_text = "United Kingdom" } };
    out = io.Writer.fixed(&bytes);
    try admin.writeDebug(&out);
    try testing.expectEqualStrings("country_code=GB | country_text=United Kingdom | state_code= | state_text=", out.buffered());
    const value: maneuver.Maneuver = .{ .type = .kLeft, .length_km = 1.25, .trail_type = .named_walkway };
    out = io.Writer.fixed(&bytes);
    try value.writeDebug(&out, .none);
    try testing.expect(std.mem.startsWith(u8, out.buffered(), "type_=15 | street_names_=unnamed | begin_street_names=unnamed"));
    try testing.expect(std.mem.containsAtLeast(u8, out.buffered(), 1, " | trail_type=kNamedWalkway | unnamed_walkway=0"));
}

test "explicit level references take precedence over single level labels" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    var raw: trip.Edge = .{ .tagged_value = &.{
        .{ .type = .kLevels, .value = "\x04\x00\x06" },
        .{ .type = .kLevelRef, .value = "L3" },
    } };
    const view: enhanced.Edge = .{ .value = &raw };
    const explicit = try view.levelRefs(arena);
    try testing.expectEqual(1, explicit.len);
    try testing.expectEqualStrings("L3", explicit[0]);
    raw.tagged_value = &.{ .{ .type = .kLevels, .value = "\x04\x00\x06" }, .{ .type = .kLevels, .value = "\x04\x02\x18" } };
    const fallback = try view.levelRefs(arena);
    try testing.expectEqual(2, fallback.len);
    try testing.expectEqualStrings("Level 3", fallback[0]);
    try testing.expectEqualStrings("Level 1.2000000477", fallback[1]);
    const ranges = [_]struct { levels: []const trip.Level, expected: bool }{
        .{ .levels = &.{}, .expected = false },
        .{ .levels = &.{.{ .start = 1, .end = 1 }}, .expected = false },
        .{ .levels = &.{.{ .start = 1, .end = 2 }}, .expected = true },
        .{ .levels = &.{ .{ .start = 1, .end = 1 }, .{ .start = 2, .end = 2 } }, .expected = true },
    };
    for (ranges) |case| {
        raw.levels = case.levels;
        try testing.expectEqual(case.expected, view.traversesLevels());
    }
}

test "intersection queries select by mode, heading, road class and road use" {
    const records = [_]trip.IntersectingEdge{
        .{ .begin_heading = 355, .use = .kRampUse, .road_class = .kPrimary, .driveability = .kForward, .cyclability = .kBackward, .prev_name_consistency = true },
        .{ .begin_heading = 5, .use = .kServiceRoadUse, .road_class = .kServiceOther, .driveability = .kBackward, .cyclability = .kForward, .walkability = .kBoth, .prev_name_consistency = true, .curr_name_consistency = true },
        .{ .begin_heading = 44, .use = .kRoadUse, .road_class = .kMotorway, .driveability = .kForward },
        .{ .begin_heading = 90, .use = .kFerryUse, .driveability = .kBoth },
        .{ .begin_heading = 270, .use = .kRoadUse, .road_class = .kPrimary, .driveability = .kBoth },
    };
    const raw: trip.Node = .{ .edge = .{ .begin_heading = 0 }, .intersecting_edge = &records };
    const view: enhanced.Node = .{ .value = &raw };
    const modes = [_]struct { mode: trip.TravelMode, degree: u32, use: trip.Use, highway: bool, right: u32, left: u32 }{
        .{ .mode = .kDrive, .degree = 355, .use = .kRampUse, .highway = true, .right = 90, .left = 270 },
        .{ .mode = .kBicycle, .degree = 5, .use = .kServiceRoadUse, .highway = false, .right = 5, .left = 0 },
        .{ .mode = .kPedestrian, .degree = 5, .use = .kServiceRoadUse, .highway = false, .right = 5, .left = 0 },
        .{ .mode = .kTransit, .degree = 5, .use = .kServiceRoadUse, .highway = false, .right = 5, .left = 0 },
    };
    for (modes) |case| {
        const nearest = try view.straightestIntersectingEdge(0, case.mode);
        try testing.expectEqual(case.degree, nearest.degree);
        try testing.expectEqual(case.use, nearest.use.?);
        try testing.expectEqual(case.highway, try view.hasWiderForwardTraversableHighwayEdge(0, case.mode));
        try testing.expectEqual(case.right, try view.rightMostTurnDegree(0, 0, case.mode));
        try testing.expectEqual(case.left, try view.leftMostTurnDegree(0, 0, case.mode));
        try testing.expect(try view.hasTraversableIntersectingEdge(case.mode));
        try testing.expect(try view.hasTraversableOutboundIntersectingEdge(case.mode));
        try testing.expect(try view.hasForwardTraversableIntersectingEdge(0, case.mode));
        try testing.expect(try view.hasWiderForwardTraversableIntersectingEdge(0, case.mode));
        try testing.expect(!(try view.isStraightestTraversableIntersectingEdgeReversed(0, case.mode)));
    }
    try testing.expectEqual(355, (try view.straightestIntersectingEdge(0, null)).degree);
    try testing.expect(try view.hasIntersectingEdgeNameConsistency());
    try testing.expect(try view.hasIntersectingEdgeCurrNameConsistency());
    try testing.expect(try view.hasNonBackwardTraversableSameNameRampIntersectingEdge(0, .kBicycle));
    try testing.expect(!(try view.hasNonBackwardTraversableSameNameRampIntersectingEdge(175, .kDrive)));
    try testing.expect(try view.hasForwardIntersectingEdge(0));
    try testing.expect(try view.hasRoadForkTraversableIntersectingEdge(0, .kBicycle, true));
    try testing.expect(!(try view.hasRoadForkTraversableIntersectingEdge(0, .kBicycle, false)));
    try testing.expect(try view.hasForwardTraversableSignificantRoadClassEdge(0, .kDrive, .kMotorway));
    try testing.expect(!(try view.hasForwardTraversableSignificantRoadClassEdge(0, .kBicycle, .kMotorway)));
    try testing.expect(try view.hasForwardTraversableUseEdge(0, .kDrive, .kRampUse));
    try testing.expect(!(try view.hasForwardTraversableUseEdge(0, .kBicycle, .kRampUse)));
    try testing.expect(try view.hasSimilarStraightSignificantRoadClassEdge(10, 0, .kDrive, .kPrimary));
    try testing.expect(!(try view.hasSimilarStraightSignificantRoadClassEdge(40, 0, .kDrive, .kPrimary)));
    try testing.expect(try view.hasSimilarStraightNonRampOrSameNameRampEdge(10, 0, .kDrive));
    try testing.expect(!(try view.hasOnlyForwardTraversableRoadClassEdges(0, .kDrive, .kPrimary)));
    const only: enhanced.Node = .{ .value = &.{ .intersecting_edge = records[1..2] } };
    try testing.expect(try only.hasOnlyForwardTraversableRoadClassEdges(0, .kBicycle, .kServiceOther));
    try testing.expect(try view.hasTraversableExcludeUseEdge(.kDrive, .kRampUse));
    try testing.expect(!(try only.hasTraversableExcludeUseEdge(.kBicycle, .kServiceRoadUse)));
    try testing.expect(try view.hasForwardTraversableExcludeUseEdge(0, .kDrive, .kRampUse));
    try testing.expect(!(try only.hasForwardTraversableExcludeUseEdge(90, .kBicycle, .kRampUse)));
    try testing.expect(try view.hasSpecifiedTurnEdge(.right, 0, .kDrive));
    try testing.expect(!(try view.hasSpecifiedTurnEdge(.right, 0, .kBicycle)));
    try testing.expect(try view.hasSpecifiedRoadClassEdge(.kPrimary));
    try testing.expect(!(try view.hasSpecifiedRoadClassEdge(.kSecondary)));
    const empty: enhanced.Node = .{ .value = &.{} };
    try testing.expect(!empty.hasIntersectingEdges());
    try testing.expectEqual(180, (try empty.straightestIntersectingEdge(0, .kDrive)).degree);
    try testing.expect(try empty.isStraightestTraversableIntersectingEdgeReversed(0, .kDrive));
    const cancelled: enhanced.Node = .{ .value = &raw, .deadline = .{ .at_ns = 0 } };
    try testing.expectError(error.DeadlineExceeded, cancelled.straightestIntersectingEdge(0, null));
}

test "maneuver value retains the upstream direction and travel predicates" {
    const cases = [_]struct {
        kind: directions.ManeuverType,
        start: bool = false,
        destination: bool = false,
        merge: bool = false,
        right: bool = false,
        left: bool = false,
        transit: bool = false,
    }{
        .{ .kind = .kNone },
        .{ .kind = .kStart, .start = true },
        .{ .kind = .kStartLeft, .start = true },
        .{ .kind = .kStartRight, .start = true },
        .{ .kind = .kDestination, .destination = true },
        .{ .kind = .kDestinationRight, .destination = true, .right = true },
        .{ .kind = .kDestinationLeft, .destination = true, .left = true },
        .{ .kind = .kMerge, .merge = true },
        .{ .kind = .kMergeRight, .merge = true, .right = true },
        .{ .kind = .kMergeLeft, .merge = true, .left = true },
        .{ .kind = .kSlightRight, .right = true },
        .{ .kind = .kSharpLeft, .left = true },
        .{ .kind = .kTransit, .transit = true },
        .{ .kind = .kTransitTransfer, .transit = true },
        .{ .kind = .kTransitRemainOn, .transit = true },
        .{ .kind = .kTransitConnectionStart },
    };
    for (cases) |case| {
        const value: maneuver.Maneuver = .{ .type = case.kind };
        try testing.expectEqual(case.start, value.isStartType());
        try testing.expectEqual(case.destination, value.isDestinationType());
        try testing.expectEqual(case.merge, value.isMergeType());
        try testing.expectEqual(case.left, value.isLeftType());
        try testing.expectEqual(case.right, value.isRightType());
        try testing.expectEqual(case.transit, value.isTransit());
    }
    const trails = [_]struct { kind: maneuver.TrailType, walkway: bool = false, cycleway: bool = false, mtb: bool = false, unnamed: bool = false }{
        .{ .kind = .none },
        .{ .kind = .named_walkway, .walkway = true },
        .{ .kind = .unnamed_walkway, .walkway = true, .unnamed = true },
        .{ .kind = .named_cycleway, .cycleway = true },
        .{ .kind = .unnamed_cycleway, .cycleway = true, .unnamed = true },
        .{ .kind = .named_mtb_trail, .mtb = true },
        .{ .kind = .unnamed_mtb_trail, .mtb = true, .unnamed = true },
    };
    for (trails) |trial| {
        const value: maneuver.Maneuver = .{ .trail_type = trial.kind };
        try testing.expectEqual(trial.walkway, value.isWalkway());
        try testing.expectEqual(trial.cycleway, value.isCycleway());
        try testing.expectEqual(trial.mtb, value.isMountainBikeTrail());
        try testing.expectEqual(trial.walkway and trial.unnamed, value.isUnnamedWalkway());
        try testing.expectEqual(trial.cycleway and trial.unnamed, value.isUnnamedCycleway());
        try testing.expectEqual(trial.mtb and trial.unnamed, value.isUnnamedMountainBikeTrail());
    }
}

test "maneuver name matching respects route flags, cardinal directions and intersection names" {
    var route: maneuver.Maneuver = .{
        .street_names = &.{.{ .value = "US 30 West", .is_route_number = true }},
        .name_style = .us,
        .internal_intersection = true,
    };
    const cases = [_]struct {
        value: []const u8,
        route: bool = true,
        same: bool = false,
        similar: bool = false,
    }{
        .{ .value = "US 30 West", .same = true, .similar = true },
        .{ .value = "US 30 West", .route = false, .similar = true },
        .{ .value = "US 30", .similar = true },
        .{ .value = "North US 30 Southeast", .similar = true },
        .{ .value = "US 31 West" },
    };
    for (cases) |case| {
        const names = [_]trip.StreetName{.{ .value = case.value, .is_route_number = case.route }};
        const next: maneuver.Maneuver = .{ .street_names = &names, .name_style = .us };
        try testing.expectEqual(case.same, try route.hasSameNames(&next, false, .none));
        try testing.expectEqual(case.similar, try route.hasSimilarNames(&next, false, .none));
    }
    route.begin_intersecting_edge_name_consistency = true;
    try testing.expect(!(try route.hasSameNames(&route, false, .none)));
    try testing.expect(try route.hasSameNames(&route, true, .none));
    try testing.expectError(error.DeadlineExceeded, route.hasSameNames(&route, true, .{ .at_ns = 0 }));
    for ([_]u32{ 0, 1, 2, 3, 4 }, [_]bool{ false, true, false, true, false }) |links, usable| {
        route.end_node_index = links;
        try testing.expectEqual(usable, route.hasUsableInternalIntersectionName());
    }
    try testing.expect(route.drive_on_right and route.node_type == null);
    try testing.expectEqual(trip.TravelMode.kDrive, route.travel_mode);
    try testing.expectEqual(trip.TransitType.kRail, route.transit_type);
    try testing.expectEqual(0, route.transitStopCount());
    route.transit_info.transit_stops = &.{ .{ .departure_date_time = "08:00" }, .{ .arrival_date_time = "08:30" } };
    try testing.expectEqual(1, route.transitStopCount());
    try testing.expectEqualStrings("08:00", route.transitDepartureTime());
    try testing.expectEqualStrings("08:30", route.transitArrivalTime());
    try testing.expect(!route.hasVerbalMultiCue());
    route.distant_verbal_multi_cue = true;
    try testing.expect(route.hasVerbalMultiCue());
    try testing.expect(!route.hasSigns());
    route.signs.guide_toward_locations = &.{.{ .text = "North" }};
    try testing.expect(route.hasGuideSign() and route.hasSigns() and !route.hasExitSign());
    route.signs.exit_numbers = &.{.{ .text = "3" }};
    try testing.expect(route.hasExitSign());
}
