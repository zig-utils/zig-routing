// Ported from src/mjolnir/directededgebuilder.cc and src/mjolnir/graphbuilder.cc
// (Valhalla 3.9.3). Select directed categories from the retained way tags.
const std = @import("std");
const constants = @import("../graph/constants.zig");
const EdgeClass = @import("../graph/class_table.zig").EdgeClass;
const WayAttrs = @import("tags/root.zig").WayAttrs;
const Edges = @import("edges.zig");

pub const DriveSide = enum { right, left };

/// Base class for a directed edge. Graph-level attributes such as density,
/// traffic controls and restrictions are supplied by their build stages.
pub fn fromWay(way: WayAttrs, forward: bool, drive_side: DriveSide) !EdgeClass {
    const use = way.edgeUse();
    const road_class = switch (use) {
        .footway, .steps, .ladder, .sidewalk, .pedestrian => .service_other,
        else => way.road_class,
    };
    if (road_class == .invalid) return error.InvalidRoadClass;
    const fwd = if (forward) way.forward_access else way.backward_access;
    const rev = if (forward) way.backward_access else way.forward_access;
    const right = drive_side == .right;
    return .{
        .category = .{
            .use = @intCast(@backingInt(use)),
            .road_class = @intCast(@backingInt(road_class)),
            .surface = @backingInt(way.surface),
            .sac_scale = @backingInt(way.pedestrian.sac_scale),
            .cycle_lane = @backingInt(cycleLane(way, forward, right)),
            .bike_network = @truncate(@as(u8, @bitCast(way.bicycle.network))),
            .lanes = laneCount(way, forward),
        },
        .access = .{ .forward = @bitCast(fwd), .reverse = @bitCast(rev) },
        .flags = .{
            .toll = way.flags.toll,
            .tunnel = way.flags.tunnel,
            .bridge = way.flags.bridge,
            .roundabout = way.flags.roundabout,
            .link = way.flags.link,
            .internal = way.flags.tagged_internal_intersection,
            .destination_only = !way.flags.ferry and (way.flags.destination_only or way.flags.no_thru_traffic),
            .lit = way.flags.lit,
            .sidewalk_left = way.flags.sidewalk_left,
            .sidewalk_right = way.flags.sidewalk_right,
            .dismount = way.bicycle.dismount,
            .use_sidepath = way.bicycle.use_sidepath,
            .shoulder = if (forward == right) way.flags.shoulder_right else way.flags.shoulder_left,
            .destination_only_hgv = way.flags.destination_only_hgv,
            .indoor = way.flags.indoor,
            .tagged_speed = way.speedType() == .tagged,
        },
    };
}

pub fn applySegmentControls(edge_class: *EdgeClass, segment: Edges.Flags, forward: bool, oneway: bool) void {
    edge_class.flags.traffic_signal = segment.traffic_signal and
        ((if (forward) segment.forward_signal else segment.backward_signal) or
            (oneway and !segment.forward_signal and !segment.backward_signal));
    edge_class.flags.stop_sign = segment.stop_sign and
        (!segment.direction or (if (forward) segment.forward_stop else segment.backward_stop) or
            (oneway and !segment.forward_stop and !segment.backward_stop));
    edge_class.flags.yield_sign = segment.yield_sign and
        (!segment.direction or (if (forward) segment.forward_yield else segment.backward_yield) or
            (oneway and !segment.forward_yield and !segment.backward_yield));
}

fn laneCount(way: WayAttrs, forward: bool) u4 {
    if (way.flags.forward_tagged_lanes and way.flags.backward_tagged_lanes)
        return if (forward) way.forward_lanes else way.backward_lanes;
    if (way.flags.oneway or way.flags.oneway_reverse) return way.lanes;
    return @max(1, way.lanes / 2);
}

fn cycleLane(way: WayAttrs, forward: bool, drive_on_right: bool) constants.CycleLane {
    const bike = way.bicycle;
    const bike_fwd = way.forward_access.bicycle;
    const bike_rev = way.backward_access.bicycle;
    const directions: struct { left: bool, right: bool } = if (bike_fwd != bike_rev)
        .{ .left = bike_fwd, .right = bike_fwd }
    else if (way.flags.oneway)
        .{ .left = bike.left_opposite == way.flags.oneway_reverse, .right = bike.right_opposite == way.flags.oneway_reverse }
    else
        .{ .left = bike.left_opposite == drive_on_right, .right = bike.right_opposite != drive_on_right };
    const left: constants.CycleLane = if (directions.left == forward) bike.lane_left else .none;
    const right: constants.CycleLane = if (directions.right == forward) bike.lane_right else .none;
    return @fromBackingInt(@max(@backingInt(left), @backingInt(right)));
}

test "class direction follows Valhalla lane, shoulder and access rules" {
    const testing = std.testing;
    var way: WayAttrs = .{
        .forward_access = .{ .auto = true, .bicycle = true },
        .backward_access = .{ .bicycle = true, .hov = true },
        .lanes = 5,
        .flags = .{ .sidewalk_left = true, .shoulder_right = true, .no_thru_traffic = true },
        .bicycle = .{ .lane_left = .separated, .lane_right = .dedicated, .network = .{ .icn = true } },
    };
    const fwd = try fromWay(way, true, .right);
    const rev = try fromWay(way, false, .right);
    try testing.expect(fwd.forwardAccess().auto and rev.reverseAccess().auto and rev.isHovOnly());
    try testing.expectEqual(@backingInt(constants.CycleLane.dedicated), fwd.category.cycle_lane);
    try testing.expectEqual(@backingInt(constants.CycleLane.separated), rev.category.cycle_lane);
    try testing.expectEqual(@backingInt(constants.CycleLane.separated), (try fromWay(way, true, .left)).category.cycle_lane);
    try testing.expect(fwd.flags.shoulder and !rev.flags.shoulder);
    try testing.expect(fwd.flags.sidewalk_left and rev.flags.sidewalk_left);
    try testing.expect(fwd.flags.destination_only and !fwd.onBikeNetwork());
    try testing.expectEqual(2, rev.category.lanes);

    way.flags.oneway = true;
    way.flags.oneway_reverse = true;
    way.bicycle.left_opposite = true;
    const contra = try fromWay(way, true, .right);
    try testing.expectEqual(5, contra.category.lanes);
    try testing.expectEqual(@backingInt(constants.CycleLane.separated), contra.category.cycle_lane);
    try testing.expectEqual(@backingInt(constants.CycleLane.dedicated), (try fromWay(way, false, .right)).category.cycle_lane);
    way.backward_access.bicycle = false;
    way.flags.ferry = true;
    try testing.expect(!(try fromWay(way, true, .right)).flags.destination_only);
    try testing.expectEqual(@backingInt(constants.CycleLane.none), (try fromWay(way, false, .right)).category.cycle_lane);

    const control: Edges.Flags = .{ .traffic_signal = true, .stop_sign = true };
    var value = fwd;
    applySegmentControls(&value, control, true, false);
    try testing.expect(!value.flags.traffic_signal and value.flags.stop_sign);
    applySegmentControls(&value, control, true, true);
    try testing.expect(value.flags.traffic_signal and value.flags.stop_sign);
}
