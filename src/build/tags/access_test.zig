const std = @import("std");
const osm = @import("../osm.zig");
const tags = @import("root.zig");

const Scratch = tags.Scratch;
const transformWay = tags.transformWay;
const transformNode = tags.transformNode;

test "graph.lua access tables match every upstream mode value and direction" {
    const testing = std.testing;
    var scratch: Scratch = .{};
    var lines = std.mem.splitScalar(u8, @embedFile("testdata/access.tsv"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next().?;
        const key = fields.next().?;
        const value = fields.next().?;
        const first = try std.fmt.parseInt(u16, fields.next().?, 10);
        const second = try std.fmt.parseInt(u16, fields.next().?, 10);
        const third = fields.next().?;
        try testing.expectEqual(null, fields.next());
        const tag: osm.Tag = .{ .key = key, .value = value };
        const no_access: osm.Tag = .{ .key = "access", .value = "no" };
        if (std.mem.eql(u8, kind, "w")) {
            const input: []const osm.Tag = &.{ .{ .key = "highway", .value = "bridleway" }, no_access, tag };
            const way = (try transformWay(&scratch, input, .none)) orelse return error.UnexpectedWayDrop;
            const masks = [2]u16{ @bitCast(way.forward_access), @bitCast(way.backward_access) };
            if (!std.mem.eql(u16, &.{ first, second }, &masks)) std.debug.print("way {s}={s}\n", .{ key, value });
            try testing.expectEqualSlices(u16, &.{ first, second }, &masks);
        } else {
            try testing.expectEqualStrings("n", kind);
            const input: []const osm.Tag = &.{ no_access, tag };
            const node = (try transformNode(&scratch, input, .none)).?;
            const private = try std.fmt.parseInt(u16, third, 10);
            const fields_found = [3]u16{ @bitCast(node.access), @intFromBool(node.flags.tagged_access), @intFromBool(node.flags.private_access) };
            if (!std.mem.eql(u16, &.{ first, second, private }, &fields_found)) std.debug.print("node {s}={s}\n", .{ key, value });
            try testing.expectEqualSlices(u16, &.{ first, second, private }, &fields_found);
        }
        count += 1;
    }
    try testing.expectEqual(1156, count);
}

test "filter_tags_generic directional overrides, reverse ways and reversible lanes" {
    const testing = std.testing;
    var scratch: Scratch = .{};
    const contra: []const osm.Tag = &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "junction", .value = "roundabout" },
        .{ .key = "oneway", .value = "yes" },
        .{ .key = "cycleway", .value = "opposite_lane" },
        .{ .key = "vehicle:backward", .value = "no" },
        .{ .key = "bicycle:backward", .value = "yes" },
        .{ .key = "bus:backward", .value = "designated" },
    };
    const loop = (try transformWay(&scratch, contra, .none)).?;
    try testing.expect(loop.flags.oneway and loop.flags.roundabout);
    try testing.expect(loop.forward_access.auto and !loop.backward_access.auto);
    try testing.expect(loop.forward_access.bicycle and loop.backward_access.bicycle);
    try testing.expect(loop.backward_access.bus);

    const reverse: []const osm.Tag = &.{
        .{ .key = "highway", .value = "path" },
        .{ .key = "oneway", .value = "-1" },
        .{ .key = "oneway:bicycle", .value = "-1" },
    };
    const reversed = (try transformWay(&scratch, reverse, .none)).?;
    try testing.expect(reversed.flags.oneway and reversed.flags.oneway_reverse);
    try testing.expect(reversed.forward_access.bicycle and !reversed.backward_access.bicycle);
    try testing.expect(!reversed.forward_access.pedestrian and reversed.backward_access.pedestrian);

    const reversible: []const osm.Tag = &.{
        .{ .key = "highway", .value = "road" },
        .{ .key = "access", .value = "permissive" },
        .{ .key = "oneway", .value = "reversible" },
    };
    const lane = (try transformWay(&scratch, reversible, .none)).?;
    try testing.expect(!lane.flags.oneway);
    try testing.expect(lane.forward_access.bus and lane.backward_access.bus);
    try testing.expect(!lane.forward_access.auto and !lane.backward_access.auto);
    try testing.expect(!lane.forward_access.pedestrian);
}

test "filter_tags_generic HOV and construction masks and directed edge wheelchair access" {
    const testing = std.testing;
    var scratch: Scratch = .{};
    const hov: []const osm.Tag = &.{
        .{ .key = "highway", .value = "motorway" },
        .{ .key = "oneway", .value = "yes" },
        .{ .key = "hov", .value = "designated" },
        .{ .key = "hov:minimum", .value = "2" },
        .{ .key = "hov:lanes", .value = "designated|designated" },
    };
    const designated = (try transformWay(&scratch, hov, .none)).?;
    try testing.expect(designated.forward_access.hov and !designated.backward_access.hov);
    try testing.expect(!designated.forward_access.auto and !designated.forward_access.truck);
    const mixed_tag: osm.Tag = .{ .key = "hov:lanes", .value = "designated|yes" };
    const mixed_input = hov[0..4].* ++ .{mixed_tag};
    const mixed = (try transformWay(&scratch, &mixed_input, .none)).?;
    try testing.expect(!mixed.forward_access.hov and mixed.forward_access.auto);

    const works: []const osm.Tag = &.{
        .{ .key = "highway", .value = "construction" },
        .{ .key = "construction", .value = "road" },
        .{ .key = "wheelchair", .value = "yes" },
    };
    const work = (try transformWay(&scratch, works, .none)).?;
    try testing.expectEqual(@as(u16, 0), @as(u16, @bitCast(work.forward_access)));
    try testing.expectEqual(@as(u16, 0), @as(u16, @bitCast(work.backward_access)));

    const stair: []const osm.Tag = &.{ .{ .key = "highway", .value = "steps" }, .{ .key = "wheelchair", .value = "yes" } };
    const stairs = (try transformWay(&scratch, stair, .none)).?;
    try testing.expect(stairs.flags.wheelchair_tag and stairs.flags.wheelchair);
    try testing.expect(stairs.forward_access.pedestrian and !stairs.forward_access.wheelchair);
    const ramp: []const osm.Tag = &.{ .{ .key = "highway", .value = "path" }, .{ .key = "oneway", .value = "yes" } };
    const ramps = (try transformWay(&scratch, ramp, .none)).?;
    try testing.expect(ramps.forward_access.wheelchair and !ramps.backward_access.wheelchair);
}

test "nodes_proc barriers, node types and access exceptions" {
    const testing = std.testing;
    const graph = @import("../../graph/constants.zig");
    const cases = [_]struct { barrier: []const u8, kind: graph.NodeType, mask: u16 }{
        .{ .barrier = "gate", .kind = .gate, .mask = 2047 },
        .{ .barrier = "yes", .kind = .gate, .mask = 2047 },
        .{ .barrier = "lift_gate", .kind = .gate, .mask = 2047 },
        .{ .barrier = "swing_gate", .kind = .gate, .mask = 2047 },
        .{ .barrier = "sliding_beam", .kind = .gate, .mask = 2047 },
        .{ .barrier = "bollard", .kind = .bollard, .mask = 262 },
        .{ .barrier = "block", .kind = .bollard, .mask = 262 },
        .{ .barrier = "kissing_gate", .kind = .bollard, .mask = 262 },
        .{ .barrier = "motorcycle_barrier", .kind = .bollard, .mask = 262 },
        .{ .barrier = "cycle_barrier", .kind = .bollard, .mask = 262 },
        .{ .barrier = "chain", .kind = .bollard, .mask = 262 },
        .{ .barrier = "bar", .kind = .bollard, .mask = 262 },
        .{ .barrier = "sump_buster", .kind = .sump_buster, .mask = 1886 },
        .{ .barrier = "fence", .kind = .street_intersection, .mask = 0 },
        .{ .barrier = "barrier_board", .kind = .street_intersection, .mask = 0 },
        .{ .barrier = "wall", .kind = .street_intersection, .mask = 0 },
        .{ .barrier = "jersey_barrier", .kind = .street_intersection, .mask = 0 },
        .{ .barrier = "debris", .kind = .street_intersection, .mask = 0 },
        .{ .barrier = "toll_booth", .kind = .toll_booth, .mask = 2047 },
        .{ .barrier = "border_control", .kind = .border_control, .mask = 2047 },
    };
    var scratch: Scratch = .{};
    for (cases) |case| {
        const input: []const osm.Tag = &.{.{ .key = "barrier", .value = case.barrier }};
        const node = (try transformNode(&scratch, input, .none)).?;
        try testing.expectEqual(case.kind, node.type);
        try testing.expectEqual(case.mask, @as(u16, @bitCast(node.access)));
    }
    const rising: []const osm.Tag = &.{ .{ .key = "barrier", .value = "bollard" }, .{ .key = "bollard", .value = "rising" } };
    try testing.expectEqual(.gate, (try transformNode(&scratch, rising, .none)).?.type);
    const private: []const osm.Tag = &.{ .{ .key = "barrier", .value = "bollard" }, .{ .key = "access", .value = "private" } };
    const private_node = (try transformNode(&scratch, private, .none)).?;
    try testing.expect(private_node.flags.private_access and private_node.access.auto);
    const wall: []const osm.Tag = &.{ .{ .key = "barrier", .value = "wall" }, .{ .key = "foot", .value = "yes" } };
    try testing.expectEqual(@as(u16, 258), @as(u16, @bitCast((try transformNode(&scratch, wall, .none)).?.access)));
    const crossing: []const osm.Tag = &.{
        .{ .key = "highway", .value = "crossing" },
        .{ .key = "vehicle", .value = "no" },
        .{ .key = "bicycle", .value = "no" },
    };
    try testing.expectEqual(@as(u16, 2047), @as(u16, @bitCast((try transformNode(&scratch, crossing, .none)).?.access)));
}
