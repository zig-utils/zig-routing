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
