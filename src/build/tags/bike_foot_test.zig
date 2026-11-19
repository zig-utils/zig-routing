const std = @import("std");
const osm = @import("../osm.zig");
const graph = @import("../../graph/constants.zig");
const tags = @import("root.zig");

test "graph.lua cycleway values, contraflow and shared paths" {
    const testing = std.testing;
    const cases = [_]struct { value: []const u8, lane: graph.CycleLane = .none, opposite: bool = false }{
        .{ .value = "yes" },
        .{ .value = "no" },
        .{ .value = "none" },
        .{ .value = "designated" },
        .{ .value = "use_sidepath" },
        .{ .value = "permissive" },
        .{ .value = "destination" },
        .{ .value = "dismount" },
        .{ .value = "lane", .lane = .dedicated },
        .{ .value = "track", .lane = .separated },
        .{ .value = "shared", .lane = .shared },
        .{ .value = "shared_lane", .lane = .shared },
        .{ .value = "sidepath" },
        .{ .value = "share_busway", .lane = .shared },
        .{ .value = "allowed" },
        .{ .value = "private" },
        .{ .value = "cyclestreet" },
        .{ .value = "crossing" },
        .{ .value = "opposite", .opposite = true },
        .{ .value = "opposite_lane", .lane = .dedicated, .opposite = true },
        .{ .value = "opposite_track", .lane = .separated, .opposite = true },
        .{ .value = "buffered_lane", .lane = .dedicated },
        .{ .value = "unrecognized" },
    };
    var scratch: tags.Scratch = .{};
    for (cases) |case| {
        const raw: []const osm.Tag = &.{
            .{ .key = "highway", .value = "residential" },
            .{ .key = "cycleway", .value = case.value },
        };
        const bike = (try tags.transformWay(&scratch, raw, .none)).?.bicycle;
        try testing.expectEqual(case.lane, bike.lane_left);
        try testing.expectEqual(case.lane, bike.lane_right);
        try testing.expectEqual(case.opposite, bike.left_opposite);
        try testing.expectEqual(case.opposite, bike.right_opposite);
    }

    const contra: []const osm.Tag = &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "oneway", .value = "yes" },
        .{ .key = "oneway:bicycle", .value = "no" },
        .{ .key = "cycleway:right", .value = "track" },
        .{ .key = "shoulder:left", .value = "yes" },
    };
    const contraflow = (try tags.transformWay(&scratch, contra, .none)).?;
    try testing.expectEqual(.separated, contraflow.bicycle.lane_left);
    try testing.expectEqual(.separated, contraflow.bicycle.lane_right);
    try testing.expect(contraflow.bicycle.left_opposite and !contraflow.bicycle.right_opposite);
    try testing.expect(contraflow.flags.shoulder_left and contraflow.flags.shoulder_right);

    const both: []const osm.Tag = &.{
        .{ .key = "highway", .value = "footway" },
        .{ .key = "oneway", .value = "yes" },
        .{ .key = "cycleway:both", .value = "track" },
        .{ .key = "segregated", .value = "yes" },
    };
    const segregated = (try tags.transformWay(&scratch, both, .none)).?;
    try testing.expectEqual(.dedicated, segregated.bicycle.lane_left);
    try testing.expect(segregated.forward_access.bicycle and segregated.backward_access.bicycle);

    const buffer: []const osm.Tag = &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "cycleway:left:buffer", .value = "yes" },
        .{ .key = "cycleway:right", .value = "opposite_track" },
    };
    const buffered = (try tags.transformWay(&scratch, buffer, .none)).?.bicycle;
    try testing.expectEqual(.dedicated, buffered.lane_left);
    try testing.expectEqual(.separated, buffered.lane_right);
    try testing.expect(buffered.right_opposite);
}

test "OSMWay sidewalk values and hiking scale numeric parity" {
    const testing = std.testing;
    var scratch: tags.Scratch = .{};
    const sidewalks = [_]struct { value: []const u8, left: bool = false, right: bool = false }{
        .{ .value = "both", .left = true, .right = true },
        .{ .value = "yes", .left = true, .right = true },
        .{ .value = "shared", .left = true, .right = true },
        .{ .value = "raised", .left = true, .right = true },
        .{ .value = "left", .left = true },
        .{ .value = "right", .right = true },
        .{ .value = "no" },
        .{ .value = "none" },
        .{ .value = "separate" },
        .{ .value = "separate_double" },
        .{ .value = "detached" },
        .{ .value = "this" },
        .{ .value = "sidepath" },
        .{ .value = "explicit" },
        .{ .value = "unrecognized" },
    };
    for (sidewalks) |sidewalk| {
        const raw: []const osm.Tag = &.{
            .{ .key = "highway", .value = "residential" },
            .{ .key = "sidewalk", .value = sidewalk.value },
        };
        const way = (try tags.transformWay(&scratch, raw, .none)).?;
        try testing.expectEqual(sidewalk.left, way.flags.sidewalk_left);
        try testing.expectEqual(sidewalk.right, way.flags.sidewalk_right);
    }

    const scales = [_][]const u8{
        "unsupported",   "hiking",                  "mountain_hiking",                "demanding_mountain_hiking",
        "alpine_hiking", "demanding_alpine_hiking", "HIKING;DIFFICULT_ALPINE_HIKING",
    };
    for (scales, 0..) |value, i| {
        const raw: []const osm.Tag = &.{
            .{ .key = "highway", .value = "path" },
            .{ .key = "sac_scale", .value = value },
        };
        try testing.expectEqual(i, @backingInt((try tags.transformWay(&scratch, raw, .none)).?.pedestrian.sac_scale));
    }
    const ferrata: []const osm.Tag = &.{.{ .key = "highway", .value = "via_ferrata" }};
    try testing.expectEqual(.difficult_alpine_hiking, (try tags.transformWay(&scratch, ferrata, .none)).?.pedestrian.sac_scale);
}

test "way bicycle networks, dismount and sidepath metadata" {
    const testing = std.testing;
    var scratch: tags.Scratch = .{};
    const raw: []const osm.Tag = &.{
        .{ .key = "highway", .value = "path" },
        .{ .key = "bicycle", .value = "dismount" },
        .{ .key = "ncn_ref", .value = "" },
        .{ .key = "rcn", .value = "yes" },
        .{ .key = "icn", .value = "yes" },
        .{ .key = "mtb", .value = "yes" },
        .{ .key = "mtb:scale", .value = "3+" },
        .{ .key = "mtb:scale:uphill", .value = "1" },
    };
    const bike = (try tags.transformWay(&scratch, raw, .none)).?.bicycle;
    try testing.expect(bike.dismount and !bike.use_sidepath);
    try testing.expectEqual(@as(?u31, 3), bike.mtb_scale);
    try testing.expectEqual(@as(?u31, 1), bike.mtb_uphill_scale);
    try testing.expect(bike.network.icn);
    try testing.expectEqual(11, bike.network.costingMask());
    try testing.expectEqual(15, bike.network.merge(.{ .lcn = true }).costingMask());

    const sidepath: []const osm.Tag = &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "bicycle", .value = "use_sidepath" },
    };
    const other = (try tags.transformWay(&scratch, sidepath, .none)).?;
    try testing.expect(other.bicycle.use_sidepath and other.forward_access.bicycle);
}

test "pedestrian way and node inputs preserve steps, tactile paving and accessibility" {
    const testing = std.testing;
    var scratch: tags.Scratch = .{};
    const raw: []const osm.Tag = &.{
        .{ .key = "highway", .value = "steps" },
        .{ .key = "step_count", .value = "17" },
        .{ .key = "trail_visibility", .value = "intermediate" },
        .{ .key = "tactile_paving", .value = "partial" },
        .{ .key = "lit", .value = "yes" },
        .{ .key = "indoor", .value = "yes" },
        .{ .key = "wheelchair", .value = "yes" },
        .{ .key = "foot", .value = "designated" },
    };
    const way = (try tags.transformWay(&scratch, raw, .none)).?;
    try testing.expectEqual(.steps, way.use);
    try testing.expectEqual(@as(?u32, 17), way.pedestrian.step_count);
    try testing.expectEqual(.intermediate, way.pedestrian.trail_visibility.?);
    try testing.expectEqual(.partial, way.pedestrian.tactile_paving.?);
    try testing.expectEqualStrings("designated", way.pedestrian.foot.?);
    try testing.expect(way.flags.lit and way.flags.indoor);
    try testing.expect(way.forward_access.allowsPedestrian(.foot));
    try testing.expect(way.forward_access.allowsPedestrian(.blind));
    try testing.expect(!way.forward_access.allowsPedestrian(.wheelchair));

    const elevator: []const osm.Tag = &.{ .{ .key = "highway", .value = "elevator" }, .{ .key = "wheelchair", .value = "yes" } };
    const lift = (try tags.transformWay(&scratch, elevator, .none)).?;
    try testing.expectEqual(.elevator, lift.use);
    try testing.expect(lift.forward_access.allowsPedestrian(.wheelchair));
    const node = (try tags.transformNode(&scratch, raw, .none)).?;
    try testing.expectEqual(@as(?u32, 17), node.step_count);
    try testing.expectEqual(.partial, node.tactile_paving.?);
    const invalid: []const osm.Tag = &.{.{ .key = "step_count", .value = "8;10" }};
    try testing.expectEqual(null, (try tags.transformNode(&scratch, invalid, .none)).?.step_count);
}
