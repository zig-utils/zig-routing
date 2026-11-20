// Ported from test/maneuversbuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const trip = @import("../api/trip.zig");
const directions = @import("../api/directions.zig");
const maneuver = @import("maneuver.zig");
const builder = @import("maneuvers.zig");
const testing = std.testing;

test "upstream maneuver base directions" {
    const cases = [_]struct { angle: u32, expected: directions.ManeuverType }{
        .{ .angle = 350, .expected = .kContinue },
        .{ .angle = 0, .expected = .kContinue },
        .{ .angle = 10, .expected = .kContinue },
        .{ .angle = 11, .expected = .kSlightRight },
        .{ .angle = 28, .expected = .kSlightRight },
        .{ .angle = 44, .expected = .kSlightRight },
        .{ .angle = 45, .expected = .kRight },
        .{ .angle = 90, .expected = .kRight },
        .{ .angle = 135, .expected = .kRight },
        .{ .angle = 136, .expected = .kSharpRight },
        .{ .angle = 148, .expected = .kSharpRight },
        .{ .angle = 159, .expected = .kSharpRight },
        .{ .angle = 160, .expected = .kUturnRight },
        .{ .angle = 179, .expected = .kUturnRight },
        .{ .angle = 180, .expected = .kUturnLeft },
        .{ .angle = 200, .expected = .kUturnLeft },
        .{ .angle = 201, .expected = .kSharpLeft },
        .{ .angle = 213, .expected = .kSharpLeft },
        .{ .angle = 224, .expected = .kSharpLeft },
        .{ .angle = 225, .expected = .kLeft },
        .{ .angle = 270, .expected = .kLeft },
        .{ .angle = 315, .expected = .kLeft },
        .{ .angle = 316, .expected = .kSlightLeft },
        .{ .angle = 333, .expected = .kSlightLeft },
        .{ .angle = 349, .expected = .kSlightLeft },
    };
    for (cases) |case| try testing.expectEqual(case.expected, try builder.simpleDirectionalType(&.{ .turn_degree = case.angle }, null));
}

test "upstream maneuver cardinal directions" {
    const cases = [_]struct { angle: u32, expected: directions.CardinalDirection }{
        .{ .angle = 337, .expected = .kNorth },
        .{ .angle = 0, .expected = .kNorth },
        .{ .angle = 23, .expected = .kNorth },
        .{ .angle = 24, .expected = .kNorthEast },
        .{ .angle = 45, .expected = .kNorthEast },
        .{ .angle = 66, .expected = .kNorthEast },
        .{ .angle = 67, .expected = .kEast },
        .{ .angle = 90, .expected = .kEast },
        .{ .angle = 113, .expected = .kEast },
        .{ .angle = 114, .expected = .kSouthEast },
        .{ .angle = 135, .expected = .kSouthEast },
        .{ .angle = 156, .expected = .kSouthEast },
        .{ .angle = 157, .expected = .kSouth },
        .{ .angle = 180, .expected = .kSouth },
        .{ .angle = 203, .expected = .kSouth },
        .{ .angle = 204, .expected = .kSouthWest },
        .{ .angle = 225, .expected = .kSouthWest },
        .{ .angle = 246, .expected = .kSouthWest },
        .{ .angle = 247, .expected = .kWest },
        .{ .angle = 270, .expected = .kWest },
        .{ .angle = 293, .expected = .kWest },
        .{ .angle = 294, .expected = .kNorthWest },
        .{ .angle = 315, .expected = .kNorthWest },
        .{ .angle = 336, .expected = .kNorthWest },
    };
    for (cases) |case| try testing.expectEqual(case.expected, builder.cardinalDirection(case.angle));
}

test "upstream maneuver relative directions" {
    const cases = [_]struct { angle: u32, expected: maneuver.RelativeDirection }{
        .{ .angle = 330, .expected = .keep_straight },
        .{ .angle = 0, .expected = .keep_straight },
        .{ .angle = 30, .expected = .keep_straight },
        .{ .angle = 31, .expected = .right },
        .{ .angle = 90, .expected = .right },
        .{ .angle = 159, .expected = .right },
        .{ .angle = 160, .expected = .reverse },
        .{ .angle = 180, .expected = .reverse },
        .{ .angle = 200, .expected = .reverse },
        .{ .angle = 201, .expected = .left },
        .{ .angle = 270, .expected = .left },
        .{ .angle = 329, .expected = .left },
    };
    for (cases) |case| try testing.expectEqual(case.expected, builder.relativeDirection(case.angle));
}

test "maneuver build accumulates path cost and preserves street names across a simple T turn" {
    const north_names = [_]trip.StreetName{.{ .value = "North Road" }};
    const east_names = [_]trip.StreetName{.{ .value = "East Road" }};
    const intersections = [_]trip.IntersectingEdge{.{ .begin_heading = 270, .driveability = .kBoth }};
    const nodes = [_]trip.Node{
        .{ .edge = .{ .length_km = 0.25, .default_speed = 36, .road_class = .kResidential, .name = &north_names, .end_shape_index = 1 } },
        .{ .edge = .{ .length_km = 0.25, .default_speed = 36, .road_class = .kResidential, .name = &north_names, .begin_shape_index = 1, .end_shape_index = 2 }, .cost = .{ .elapsed_cost = .{ .seconds = 25 } } },
        .{ .edge = .{ .length_km = 0.3, .default_speed = 36, .road_class = .kResidential, .name = &east_names, .begin_heading = 90, .end_heading = 90, .begin_shape_index = 2, .end_shape_index = 3 }, .intersecting_edge = &intersections, .cost = .{ .elapsed_cost = .{ .seconds = 50 } } },
        .{ .cost = .{ .elapsed_cost = .{ .seconds = 85 } } },
    };
    const path: trip.TripLeg = .{ .node = &nodes, .location = &.{ .{ .side_of_street = .kLeft }, .{ .side_of_street = .kRight } } };
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const result = try builder.build(storage.allocator(), &path, .none);
    try testing.expectEqual(3, result.len);
    try testing.expectEqual(directions.ManeuverType.kStartLeft, result[0].type);
    try testing.expectEqual(directions.ManeuverType.kRight, result[1].type);
    try testing.expectEqual(directions.ManeuverType.kDestinationRight, result[2].type);
    try testing.expectEqualStrings("North Road", result[0].street_names[0].value);
    try testing.expectEqualStrings("East Road", result[1].street_names[0].value);
    try testing.expectEqual(50, result[0].time);
    try testing.expectEqual(35, result[1].time);
    try testing.expectEqual(30, result[1].basic_time);
    try testing.expectEqual(2, result[0].end_shape_index);
    try testing.expectEqual(2, result[1].begin_shape_index);
    try testing.expect(result[1].tee);
    try testing.expectError(error.DeadlineExceeded, builder.build(storage.allocator(), &path, .{ .at_ns = 0 }));
}

test "ramp angles, signed exits and merge collapse survive the full maneuver build" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const local: trip.Edge = .{ .length_km = 0.2, .road_class = .kPrimary, .name = &.{.{ .value = "Approach" }}, .end_shape_index = 1 };
    const highway: trip.Edge = .{ .length_km = 0.3, .name = &.{.{ .value = "A2", .is_route_number = true }}, .begin_shape_index = 2, .end_shape_index = 3 };
    const sign: trip.Sign = .{ .exit_numbers = &.{.{ .text = "5" }}, .exit_toward_locations = &.{.{ .text = "Utrecht" }} };
    for ([_]struct { heading: u32, sign: ?trip.Sign = null, expected: directions.ManeuverType }{
        .{ .heading = 0, .expected = .kRampStraight },
        .{ .heading = 65, .expected = .kRampRight },
        .{ .heading = 295, .expected = .kRampLeft },
        .{ .heading = 65, .sign = sign, .expected = .kExitRight },
        .{ .heading = 295, .sign = sign, .expected = .kExitLeft },
    }) |case| {
        _ = storage.reset(.retain_capacity);
        const nodes = [_]trip.Node{
            .{ .edge = local },
            .{ .edge = .{
                .length_km = 0.15,
                .road_class = .kPrimary,
                .use = .kRampUse,
                .begin_heading = case.heading,
                .begin_shape_index = 1,
                .end_shape_index = 2,
                .sign = case.sign,
            } },
            .{ .edge = highway },
            .{},
        };
        const path: trip.TripLeg = .{ .node = &nodes, .location = &.{ .{}, .{} } };
        const result = try builder.build(storage.allocator(), &path, .none);
        try testing.expectEqual(@as(usize, 3), result.len);
        const ramp = result[1];
        try testing.expectEqual(case.expected, ramp.type);
        try testing.expect(ramp.has_collapsed_merge_maneuver);
        try testing.expectEqualStrings("A2", ramp.street_names[0].value);
        try testing.expectEqualStrings(if (case.sign != null) "Utrecht" else "A2", if (case.sign != null) ramp.signs.exit_toward_locations[0].text else ramp.signs.exit_onto_streets[0].text);
        try testing.expectEqual(@as(u32, 3), ramp.end_shape_index);
    }
}

test "roundabout entry counts passed exits and carries the selected exit names and signs" {
    const exit_sign: trip.Sign = .{ .guide_toward_locations = &.{.{ .text = "City centre" }} };
    const nodes = [_]trip.Node{
        .{ .edge = .{ .name = &.{.{ .value = "Approach" }}, .length_km = 0.2, .road_class = .kPrimary, .end_shape_index = 1 } },
        .{ .edge = .{ .name = &.{ .{ .value = "Molenplein" }, .{ .value = "N 10", .is_route_number = true } }, .length_km = 0.04, .road_class = .kPrimary, .roundabout = true, .begin_shape_index = 1, .end_shape_index = 2 } },
        .{ .edge = .{ .length_km = 0.04, .road_class = .kPrimary, .roundabout = true, .begin_shape_index = 2, .end_shape_index = 3 }, .intersecting_edge = &.{.{ .begin_heading = 90, .driveability = .kForward }} },
        .{ .edge = .{ .name = &.{.{ .value = "Exit Road" }}, .length_km = 0.3, .road_class = .kPrimary, .begin_heading = 90, .begin_shape_index = 3, .end_shape_index = 4, .sign = exit_sign } },
        .{},
    };
    const path: trip.TripLeg = .{ .node = &nodes, .location = &.{ .{}, .{} } };
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const result = try builder.build(storage.allocator(), &path, .none);
    try testing.expectEqual(@as(usize, 4), result.len);
    try testing.expectEqual(.kRoundaboutEnter, result[1].type);
    try testing.expectEqual(.kRoundaboutExit, result[2].type);
    try testing.expectEqual(@as(u32, 2), result[1].roundabout_exit_count);
    try testing.expectEqual(@as(usize, 1), result[1].street_names.len);
    try testing.expectEqualStrings("Molenplein", result[1].street_names[0].value);
    try testing.expectEqualStrings("Exit Road", result[1].roundabout_exit_street_names[0].value);
    try testing.expectEqualStrings("City centre", result[1].roundabout_exit_signs.guide_toward_locations[0].text);
    const collapsed = try builder.buildWithOptions(storage.allocator(), &path, .{ .roundabout_exits = false }, .none);
    try testing.expectEqual(@as(usize, 3), collapsed.len);
    try testing.expectEqual(.kRoundaboutEnter, collapsed[1].type);
    try testing.expectEqual(@as(u32, 3), collapsed[1].roundabout_exit_shape_index);
    try testing.expectEqual(@as(u32, 4), collapsed[1].end_shape_index);
}

test "a turn channel ending at a side-of-street destination preserves arrival" {
    const nodes = [_]trip.Node{
        .{ .edge = .{ .name = &.{.{ .value = "Approach" }}, .length_km = 0.2, .road_class = .kPrimary, .end_shape_index = 1 } },
        .{ .edge = .{ .length_km = 0.02, .road_class = .kPrimary, .use = .kTurnChannelUse, .begin_heading = 60, .begin_shape_index = 1, .end_shape_index = 2 } },
        .{},
    };
    const path: trip.TripLeg = .{ .node = &nodes, .location = &.{ .{}, .{ .side_of_street = .kRight } } };
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const result = try builder.build(storage.allocator(), &path, .none);
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(.kRight, result[1].type);
    try testing.expectEqual(.kDestinationRight, result[2].type);
    try testing.expectEqual(@as(u32, 2), result[2].begin_shape_index);
}

test "moving a straight internal edge carries turn lanes to the new maneuver boundary" {
    const graph_lanes = @import("../graph/lanes.zig");
    var approach = [_]trip.TurnLane{.{ .directions_mask = graph_lanes.left }};
    const nodes = [_]trip.Node{
        .{ .edge = .{ .name = &.{.{ .value = "Approach" }}, .length_km = 0.3, .road_class = .kPrimary, .end_shape_index = 1, .turn_lanes = &approach } },
        .{ .edge = .{ .internal_intersection = true, .length_km = 0.012, .road_class = .kPrimary, .begin_shape_index = 1, .end_shape_index = 2 } },
        .{ .edge = .{ .name = &.{.{ .value = "Exit road" }}, .length_km = 0.3, .road_class = .kPrimary, .begin_heading = 270, .begin_shape_index = 2, .end_shape_index = 3 } },
        .{},
    };
    const path: trip.TripLeg = .{ .node = &nodes, .location = &.{ .{}, .{} } };
    var storage = std.heap.ArenaAllocator.init(testing.allocator);
    defer storage.deinit();
    const built = try builder.buildAnnotated(storage.allocator(), &path, .{}, .none);
    try testing.expectEqual(@as(usize, 3), built.maneuvers.len);
    try testing.expectEqual(.kLeft, built.maneuvers[1].type);
    try testing.expectEqual(@as(u32, 2), built.maneuvers[0].end_node_index);
    try testing.expectEqual(@as(u32, 2), built.maneuvers[1].begin_node_index);
    try testing.expectEqual(@as(usize, 0), path.node[1].edge.?.turn_lanes.len);
    const transferred = built.trip_leg.node[1].edge.?.turn_lanes;
    try testing.expectEqual(@as(usize, 1), transferred.len);
    try testing.expectEqual(.kActive, transferred[0].state);
    try testing.expectEqual(graph_lanes.left, transferred[0].active_direction);
}

test "ferry and rail ferry edges produce enter and exit maneuvers" {
    var storage = std.heap.ArenaAllocator.init(testing.allocator);
    defer storage.deinit();
    for ([_]trip.Use{ .kFerryUse, .kRailFerryUse }) |use| {
        const nodes = [_]trip.Node{
            .{ .edge = .{ .name = &.{.{ .value = "West Pier" }}, .length_km = 0.2, .road_class = .kPrimary, .end_shape_index = 1 } },
            .{ .edge = .{ .name = &.{.{ .value = "Harbor crossing" }}, .length_km = 2.5, .road_class = .kPrimary, .use = use, .begin_shape_index = 1, .end_shape_index = 2 } },
            .{ .edge = .{ .name = &.{.{ .value = "East Pier" }}, .length_km = 0.3, .road_class = .kPrimary, .begin_shape_index = 2, .end_shape_index = 3 } },
            .{},
        };
        const path: trip.TripLeg = .{ .node = &nodes, .location = &.{ .{}, .{} } };
        const values = try builder.build(storage.allocator(), &path, .none);
        try testing.expectEqual(@as(usize, 4), values.len);
        try testing.expectEqual(.kFerryEnter, values[1].type);
        try testing.expectEqual(.kFerryExit, values[2].type);
        try testing.expectEqual(use == .kFerryUse, values[1].ferry);
        try testing.expectEqual(use == .kRailFerryUse, values[1].rail_ferry);
    }
}

test "upstream intersecting forward edges separate maneuvers sharing a road name" {
    const cases = [_]struct { from: u32, to: u32, crossing: u32 }{
        .{ .from = 291, .to = 20, .crossing = 289 },
        .{ .from = 108, .to = 20, .crossing = 111 },
        .{ .from = 13, .to = 45, .crossing = 3 },
    };
    for (cases) |case| {
        const node: trip.Node = .{ .intersecting_edge = &.{.{ .begin_heading = case.crossing, .driveability = .kBoth }} };
        try testing.expect(try builder.isIntersectingForwardEdge(.{
            .node = .{ .value = &node },
            .previous = .{ .value = &.{ .road_class = .kResidential, .end_heading = case.from } },
            .current = .{ .value = &.{ .road_class = .kResidential, .begin_heading = case.to } },
        }));
    }
}

test "a parking node retains the turn between same-named service roads" {
    const names = [_]trip.StreetName{.{ .value = "Galileïlaan" }};
    const nodes = [_]trip.Node{
        .{ .edge = .{ .name = &names, .length_km = 0.010, .road_class = .kServiceOther, .use = .kServiceRoadUse, .begin_heading = 249, .end_heading = 249, .end_shape_index = 1 } },
        .{ .type = .kParking, .edge = .{ .name = &names, .length_km = 0.015, .road_class = .kServiceOther, .use = .kServiceRoadUse, .begin_heading = 191, .end_heading = 191, .begin_shape_index = 1, .end_shape_index = 2 } },
        .{},
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const path: trip.TripLeg = .{ .node = &nodes, .location = &.{ .{}, .{} } };
    const result = try builder.build(arena.allocator(), &path, .none);
    try testing.expectEqual(3, result.len);
    try testing.expectEqual(directions.ManeuverType.kLeft, result[1].type);
    try testing.expectEqual(1, result[1].begin_node_index);
    try testing.expectEqualStrings("Galileïlaan", result[1].street_names[0].value);
}

test "blind pedestrian maneuvers retain named crossing streets and signals" {
    const names = [_]trip.StreetName{.{ .value = "Main Street" }};
    const crossing = [_]trip.StreetName{.{ .value = "Cross Street" }};
    const nodes = [_]trip.Node{
        .{ .edge = .{ .name = &names, .travel_mode = .kPedestrian, .pedestrian_type = .kBlind, .use = .kFootwayUse, .road_class = .kServiceOther, .length_km = 0.010, .end_shape_index = 1 } },
        .{ .edge = .{ .name = &names, .travel_mode = .kPedestrian, .pedestrian_type = .kBlind, .use = .kFootwayUse, .road_class = .kServiceOther, .length_km = 0.015, .begin_shape_index = 1, .end_shape_index = 2 }, .traffic_signal = true, .intersecting_edge = &.{ .{ .begin_heading = 90, .name = &crossing }, .{ .begin_heading = 270, .name = &crossing } } },
        .{},
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const path: trip.TripLeg = .{ .node = &nodes, .location = &.{ .{}, .{} } };
    const values = try builder.build(arena.allocator(), &path, .none);
    try testing.expectEqual(3, values.len);
    try testing.expectEqual(directions.ManeuverType.kContinue, values[1].type);
    try testing.expectEqual(trip.NodeType.kStreetIntersection, values[1].node_type.?);
    try testing.expect(values[1].traffic_signal);
    try testing.expectEqual(1, values[1].cross_street_names.len);
    try testing.expectEqualStrings("Cross Street", values[1].cross_street_names[0].value);
}
