// Ported from test/gurka/test_centroid.cc, test_zero_length_route.cc, and
// test_instructions_pencilpoint_uturn.cc (Valhalla 3.9.3).

const std = @import("std");
const gurka = @import("gurka.zig");
const Allocator = std.mem.Allocator;

test {
    _ = @import("pbf.zig");
    _ = @import("edges.zig");
}

pub fn intersection(arena: Allocator) !gurka.Map {
    return gurka.Map.init(arena, try gurka.mapToCoordinates(
        \\A---B---C
        \\    |
        \\    D
    , 20), &.{
        .{ .label = "BC", .tags = &.{.{ .key = "highway", .value = "residential" }} },
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "residential" },
            .{ .key = "name", .value = "Main Street" },
            .{ .key = "osm_id", .value = "9001" },
        } },
        .{ .label = "BD", .tags = &.{.{ .key = "highway", .value = "residential" }} },
    }, &.{
        .{ .label = "B", .tags = &.{.{ .key = "osm_id", .value = "1" }} },
    }, &.{
        .{
            .members = &.{
                .{ .kind = .way, .ref = "AB", .role = "from" },
                .{ .kind = .node, .ref = "B", .role = "via" },
                .{ .kind = .way, .ref = "BD", .role = "to" },
            },
            .tags = &.{
                .{ .key = "type", .value = "restriction" },
                .{ .key = "restriction", .value = "no_right_turn" },
            },
        },
    });
}

test "fixture resolves labels, names and relation references" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const fixture = try intersection(arena);
    const main = fixture.findWay("AB").?;
    const junction = fixture.findNode("B").?;
    try std.testing.expectEqual(9001, main.id);
    try std.testing.expectEqual(1, junction.id);
    try std.testing.expectEqual(2, fixture.findNode("A").?.id);
    try std.testing.expectEqualStrings("Main Street", gurka.tagValue(main.tags, "name").?);
    try std.testing.expectEqualStrings("BC", gurka.tagValue(fixture.findWay("BC").?.tags, "name").?);
    try std.testing.expectEqualSlices(i64, &.{ 2, 1 }, main.refs);
    const members = fixture.osm.relations[0].members;
    try std.testing.expectEqual(9001, members[0].id);
    try std.testing.expectEqual(junction.id, members[1].id);
    try std.testing.expectEqual(fixture.findWay("BD").?.id, members[2].id);
    const layout = try gurka.mapToCoordinates("A---B", 20);
    try std.testing.expectError(error.UnknownNode, gurka.Map.init(arena, layout, &.{.{ .label = "AC" }}, &.{}, &.{}));
    try std.testing.expectError(error.UnknownWay, gurka.Map.init(arena, layout, &.{}, &.{}, &.{
        .{ .members = &.{.{ .kind = .way, .ref = "AB", .role = "from" }} },
    }));
}

// Ported from test/gurka/test_centroid.cc.
fn centroid(arena: Allocator) !void {
    const layout = try gurka.mapToCoordinates("A-----B--1--C-----D", 10);
    const residential: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    var fixture = try gurka.Map.init(arena, layout, &.{
        .{ .label = "AB", .tags = residential },
        .{ .label = "BC", .tags = residential },
        .{ .label = "CD", .tags = residential },
    }, &.{}, &.{});
    try std.testing.expect(fixture.layout.get("1") != null);
    try std.testing.expectEqual(null, fixture.findNode("1"));
    try fixture.build();
    _ = try fixture.doAction(.centroid, &.{ "A", "D" }, .pedestrian);
}

// Ported from test/gurka/test_zero_length_route.cc.
fn zeroLength(arena: Allocator) !void {
    const layout = try gurka.mapToCoordinates("A---1----B", 1000);
    var fixture = try gurka.Map.init(arena, layout, &.{
        .{ .label = "AB", .tags = &.{.{ .key = "highway", .value = "primary" }} },
    }, &.{}, &.{});
    try fixture.build();
    const result = try fixture.doAction(.route, &.{ "1", "1" }, .auto);
    try gurka.expectPath(result, &.{"AB"});
    try gurka.expectSteps(result, &.{ "AB", "AB" }, false);
}

// Ported from test/gurka/test_instructions_pencilpoint_uturn.cc.
fn pencilPointUturn(arena: Allocator) !void {
    const layout = try gurka.mapToCoordinatesAt(
        \\        A---B\
        \\        C---D/ E
    , 10, .{ .lng = 5.1079374, .lat = 52.0887174 });
    var fixture = try gurka.Map.init(arena, layout, &.{
        .{ .label = "ABE", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Silverbrook Road" },
            .{ .key = "oneway", .value = "-1" },
        } },
        .{ .label = "CDE", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Silverbrook Road" },
            .{ .key = "oneway", .value = "yes" },
        } },
    }, &.{}, &.{});
    try fixture.build();
    const result = try fixture.doAction(.route, &.{ "C", "A" }, .auto);
    try gurka.expectManeuvers(result, &.{ .kStart, .kUturnLeft, .kDestination });
}

test "upstream centroid, zero-length route and pencil-point U-turn examples compile" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    try std.testing.expectError(error.NotImplemented, centroid(arena));
    try std.testing.expectError(error.NotImplemented, zeroLength(arena));
    try std.testing.expectError(error.NotImplemented, pencilPointUturn(arena));
}
