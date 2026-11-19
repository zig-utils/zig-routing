const std = @import("std");
const osm = @import("../osm.zig");
const build = @import("root.zig");
const CountingAllocator = @import("../../infra/arena.zig").CountingAllocator;

test "speed and lane tags retain Valhalla's priority and directional flags" {
    const testing = std.testing;
    var scratch: build.Scratch = .{};
    const tagged: []const osm.Tag = &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "maxspeed", .value = "90" },
        .{ .key = "maxspeed:advisory", .value = "45 mph" },
        .{ .key = "maxspeed:practical", .value = "41" },
        .{ .key = "maxspeed:forward", .value = "30 mph" },
        .{ .key = "maxspeed:hgv", .value = "200" },
        .{ .key = "lanes", .value = "3" },
        .{ .key = "lanes:forward", .value = "2;3" },
        .{ .key = "lanes:backward", .value = "16" },
        .{ .key = "turn:lanes", .value = "through|right" },
        .{ .key = "turn:lanes:forward", .value = "left|through" },
        .{ .key = "turn:lanes:backward", .value = "right" },
    };
    const way = (try build.transformWay(&scratch, tagged, .none)).?;
    try testing.expectEqual(41, way.speed);
    try testing.expectEqual(90, way.speed_limit);
    try testing.expectEqual(48, way.forward_speed);
    try testing.expectEqual(48, way.backward_speed);
    try testing.expectEqual(140, way.truck_speed);
    try testing.expect(way.flags.tagged_speed and way.flags.forward_tagged_speed and way.flags.backward_tagged_speed);
    try testing.expectEqual(.tagged, way.speedType());
    try testing.expectEqual(3, way.lanes);
    try testing.expectEqual(2, way.forward_lanes);
    try testing.expectEqual(0, way.backward_lanes);
    try testing.expect(way.flags.tagged_lanes and way.flags.forward_tagged_lanes and !way.flags.backward_tagged_lanes);
    try testing.expectEqualStrings("through|right", way.turn_lanes.general.?);
    try testing.expectEqualStrings("left|through", way.turn_lanes.forward.?);
    try testing.expectEqualStrings("right", way.turn_lanes.backward.?);

    const reverse_only: []const osm.Tag = &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "oneway", .value = "-1" },
        .{ .key = "maxspeed", .value = "none" },
        .{ .key = "maxspeed:backward", .value = "40" },
    };
    const reverse = (try build.transformWay(&scratch, reverse_only, .none)).?;
    try testing.expectEqual(35, reverse.speed);
    try testing.expectEqual(255, reverse.speed_limit);
    try testing.expectEqual(40, reverse.backward_speed);
    try testing.expectEqual(0, reverse.forward_speed);
    try testing.expect(reverse.flags.oneway_reverse and reverse.flags.backward_tagged_speed and !reverse.flags.forward_tagged_speed);

    const zone: []const osm.Tag = &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "maxspeed", .value = "DE:urban" },
    };
    const classified = (try build.transformWay(&scratch, zone, .none)).?;
    try testing.expectEqual(35, classified.speed);
    try testing.expectEqual(0, classified.speed_limit);
    try testing.expectEqual(.classified, classified.speedType());
    try testing.expectEqualStrings("DE:urban", classified.speed_zone.?);

    for ([_][]const u8{ "grade1", "grade2", "grade3", "grade4", "grade5", "unknown" }, [_]u8{ 20, 15, 12, 10, 5, 5 }) |grade, expected| {
        const track: []const osm.Tag = &.{ .{ .key = "highway", .value = "track" }, .{ .key = "tracktype", .value = grade } };
        try testing.expectEqual(expected, (try build.transformWay(&scratch, track, .none)).?.speed);
    }
}

test "build string table joins localized names and refs, stores destination tags and reuses IDs" {
    const testing = std.testing;
    var counting = CountingAllocator.init(testing.allocator);
    var strings = build.names.StringTable.init(counting.allocator());
    defer strings.deinit();
    var scratch: build.Scratch = .{};
    var editable_name: [13]u8 = "Canal Road;A4".*;
    const raw: []const osm.Tag = &.{
        .{ .key = "highway", .value = "primary" },
        .{ .key = "name", .value = &editable_name },
        .{ .key = "name:nl", .value = "Oude Gracht;Gracht" },
        .{ .key = "name:qq", .value = "Unrecognised translation" },
        .{ .key = "alt_name", .value = "Market Road" },
        .{ .key = "official_name", .value = "East Canal Road" },
        .{ .key = "ref", .value = "A4;A5" },
        .{ .key = "int_ref", .value = "E8;A5" },
        .{ .key = "tunnel:name", .value = "Canal Tunnel" },
        .{ .key = "bridge:name", .value = "Canal Bridge" },
        .{ .key = "destination", .value = "Utrecht" },
        .{ .key = "destination:ref", .value = "N430" },
        .{ .key = "destination:street", .value = "Canal Road" },
        .{ .key = "junction:ref", .value = "15a" },
        .{ .key = "turn:lanes", .value = "left|through" },
    };
    const first = (try build.transformIndexedWay(&scratch, &strings, raw, .{}, .none)).?.names;
    try testing.expectEqualStrings("Canal Road;Oude Gracht;Gracht", strings.get(first.name.text).?);
    try testing.expectEqualStrings(";nl;nl", strings.get(first.name.language).?);
    try testing.expectEqual(.empty, first.alt_name.text);
    try testing.expectEqualStrings("East Canal Road", strings.get(first.official_name.text).?);
    try testing.expectEqualStrings("A4;A5;E8", strings.get(first.ref.text).?);
    try testing.expectEqualStrings("E8;A5", strings.get(first.int_ref.text).?);
    try testing.expectEqualStrings("Canal Tunnel", strings.get(first.tunnel_name.text).?);
    try testing.expectEqualStrings("Canal Bridge", strings.get(first.bridge_name).?);
    try testing.expectEqualStrings("Utrecht", strings.get(first.destination.text).?);
    try testing.expectEqualStrings("N430", strings.get(first.destination_ref.text).?);
    try testing.expectEqualStrings("Canal Road", strings.get(first.destination_street.text).?);
    try testing.expectEqualStrings("15a", strings.get(first.junction_ref.text).?);
    try testing.expectEqualStrings("left|through", strings.get(first.turn_lanes_forward).?);
    const prior_calls = counting.calls();
    const again = (try build.transformIndexedWay(&scratch, &strings, raw, .{}, .none)).?.names;
    try testing.expectEqual(first, again);
    try testing.expectEqual(prior_calls, counting.calls());
    const alt = (try build.transformIndexedWay(&scratch, &strings, raw, .{ .allow_alt_name = true }, .none)).?.names;
    try testing.expectEqualStrings("Market Road", strings.get(alt.alt_name.text).?);
    editable_name[0] = 'X';
    try testing.expectEqualStrings("Canal Road;Oude Gracht;Gracht", strings.get(first.name.text).?);
}

test "name normalization preserves unsigned refs, directions and language delimiters" {
    const testing = std.testing;
    var strings = build.names.StringTable.init(testing.allocator);
    defer strings.deinit();
    var scratch: build.Scratch = .{};
    const unnamed: []const osm.Tag = &.{ .{ .key = "highway", .value = "primary" }, .{ .key = "unsigned_ref", .value = "N43" } };
    const ref = (try build.transformIndexedWay(&scratch, &strings, unnamed, .{}, .none)).?.names.ref.text;
    try testing.expectEqualStrings("N43", strings.get(ref).?);

    const multilingual: []const osm.Tag = &.{
        .{ .key = "highway", .value = "primary" },
        .{ .key = "name", .value = "Canal / Straat" },
        .{ .key = "name:en", .value = "Canal / Straat" },
        .{ .key = "ref", .value = "A4;A5" },
        .{ .key = "direction", .value = "North;South" },
    };
    const result = (try build.transformIndexedWay(&scratch, &strings, multilingual, .{ .use_direction_on_ways = true }, .none)).?.names;
    try testing.expectEqualStrings("Canal;Straat;Canal;Straat", strings.get(result.name.text).?);
    try testing.expectEqualStrings(";;en;en", strings.get(result.name.language).?);
    try testing.expectEqualStrings("A4 North;A5 South", strings.get(result.ref.text).?);
}
