// Ported from test/gurka/test_indoor.cc, test/gurka/test_turn_lanes.cc, and
// test/gurka/test_instructions_ferry_toward.cc (Valhalla 3.9.3).
const std = @import("std");
const gurka = @import("gurka.zig");
const Allocator = std.mem.Allocator;

fn indoorTags(comptime highway: []const u8, comptime level: []const u8, comptime reference: ?[]const u8) gurka.Tags {
    const common = [_]gurka.Tag{
        .{ .key = "highway", .value = highway },
        .{ .key = "indoor", .value = "yes" },
        .{ .key = "level", .value = level },
    };
    return if (reference) |name| &(common ++ [_]gurka.Tag{.{ .key = "level:ref", .value = name }}) else &common;
}

pub fn indoor(arena: Allocator) !gurka.Map {
    const lobby = indoorTags("corridor", "1", "Lobby");
    const upper = indoorTags("corridor", "3", null);
    const escalator = indoorTags("steps", "1;2", null);
    return gurka.Map.init(arena, try gurka.mapToCoordinates(
        \\          AzZ-Y-X-W
        \\          |
        \\          B
        \\          |
        \\          C---------x-------y
        \\          |                 |
        \\D----E----F----G----H---I---J--S--T--U
        \\|         |         |
        \\N         K         |
        \\|         |         |
        \\O         L         P
        \\          |         |
        \\          M         |
        \\                    |
        \\                    Q
    , 100), &.{
        .{ .label = "AB", .tags = indoorTags("corridor", "0", "Parking") },
        .{ .label = "BC", .tags = indoorTags("steps", "0;1", null) },
        .{ .label = "CF", .tags = lobby },
        .{ .label = "DE", .tags = &.{ .{ .key = "highway", .value = "footway" }, .{ .key = "level", .value = "1" } } },
        .{ .label = "EF", .tags = lobby },
        .{ .label = "FK", .tags = lobby },
        .{ .label = "KL", .tags = &.{ escalator[0], escalator[1], escalator[2], .{ .key = "conveying", .value = "yes" } } },
        .{ .label = "LM", .tags = indoorTags("corridor", "2", null) },
        .{ .label = "FG", .tags = lobby },
        .{ .label = "GH", .tags = indoorTags("elevator", "1;2", null) },
        .{ .label = "HI", .tags = indoorTags("corridor", "2", null) },
        .{ .label = "IJ", .tags = upper },
        .{ .label = "DN", .tags = &.{.{ .key = "highway", .value = "steps" }} },
        .{ .label = "NO", .tags = &.{.{ .key = "highway", .value = "footway" }} },
        .{ .label = "Cx", .tags = indoorTags("steps", "-1;0-2", null) },
        .{ .label = "xy", .tags = indoorTags("steps", "2;3", null) },
        .{ .label = "yJ", .tags = upper },
        .{ .label = "JS", .tags = upper },
        .{ .label = "ST", .tags = &.{ .{ .key = "highway", .value = "steps" }, .{ .key = "level", .value = "3;4" } } },
        .{ .label = "TU", .tags = &.{ .{ .key = "highway", .value = "footway" }, .{ .key = "level", .value = "4" } } },
        .{ .label = "AZ", .tags = indoorTags("steps", "0-4", null) },
        .{ .label = "ZY", .tags = indoorTags("corridor", "4", null) },
        .{ .label = "YX", .tags = indoorTags("steps", "4;5", null) },
        .{ .label = "XW", .tags = indoorTags("steps", "5", null) },
        .{ .label = "HP", .tags = indoorTags("corridor", "2", null) },
        .{ .label = "PQ", .tags = indoorTags("corridor", "17", null) },
    }, &.{
        .{ .label = "E", .tags = &.{ .{ .key = "entrance", .value = "yes" }, .{ .key = "indoor", .value = "yes" } } },
        .{ .label = "I", .tags = indoorTags("elevator", "2;3", null) },
        .{ .label = "P", .tags = indoorTags("elevator", "1-25", null) },
    }, &.{});
}

pub fn splitLanes(arena: Allocator) !gurka.Map {
    const one_way: gurka.Tag = .{ .key = "oneway", .value = "yes" };
    const trunk: gurka.Tag = .{ .key = "highway", .value = "trunk" };
    const parkway: gurka.Tag = .{ .key = "name", .value = "Bronx and Pelham Parkway" };
    return gurka.Map.init(arena, try gurka.mapToCoordinates(
        \\    C
        \\    |
        \\    |  D--E
        \\A---B<
        \\    |  F--G
        \\    |
        \\    H
    , 10), &.{
        .{ .label = "AB", .tags = &.{ trunk, parkway, one_way, .{ .key = "lanes", .value = "3" }, .{ .key = "turn:lanes", .value = "left|through;left|through;right" } } },
        .{ .label = "CBH", .tags = &.{ .{ .key = "highway", .value = "primary" }, .{ .key = "name", .value = "Boston Road" } } },
        .{ .label = "BDE", .tags = &.{ trunk, parkway, one_way, .{ .key = "lanes", .value = "3" }, .{ .key = "turn:lanes", .value = "through|through|through" } } },
        .{ .label = "BFG", .tags = &.{ .{ .key = "highway", .value = "tertiary" }, .{ .key = "name", .value = "Pelham Parkway South" }, one_way, .{ .key = "lanes", .value = "1" }, .{ .key = "turn:lanes", .value = "through" } } },
    }, &.{}, &.{});
}

pub fn levelChange(arena: Allocator) !gurka.Map {
    return gurka.Map.init(arena, try gurka.mapToCoordinatesAt("A---B---C---D", 1, .{ .lng = 5.1079374, .lat = 52.0887174 }), &.{
        .{ .label = "AB", .tags = indoorTags("corridor", "0", null) },
        .{ .label = "BC", .tags = indoorTags("corridor", "0;1", null) },
        .{ .label = "CD", .tags = indoorTags("corridor", "1", null) },
    }, &.{}, &.{});
}

pub fn ferry(arena: Allocator) !gurka.Map {
    const shore: gurka.Tags = &.{
        .{ .key = "highway", .value = "trunk" },
        .{ .key = "name", .value = "" },
        .{ .key = "ref", .value = "A1" },
    };
    return gurka.Map.init(arena, try gurka.mapToCoordinatesAt("A--B----C--D", 1000, .{ .lng = 5.1079374, .lat = 52.0887174 }), &.{
        .{ .label = "AB", .tags = shore },
        .{ .label = "BC", .tags = &.{
            .{ .key = "motor_vehicle", .value = "yes" },
            .{ .key = "motorcar", .value = "yes" },
            .{ .key = "bicycle", .value = "yes" },
            .{ .key = "foot", .value = "yes" },
            .{ .key = "horse", .value = "no" },
            .{ .key = "duration", .value = "01:25" },
            .{ .key = "route", .value = "ferry" },
            .{ .key = "operator", .value = "Cape May-Lewes Ferry" },
            .{ .key = "name", .value = "Cape May-Lewes Ferry" },
            .{ .key = "ref", .value = "A1" },
            .{ .key = "destination:forward", .value = "Cape May" },
            .{ .key = "destination:backward", .value = "Lewes" },
        } },
        .{ .label = "CD", .tags = shore },
    }, &.{}, &.{});
}

pub const Pair = struct {
    from: []const u8,
    to: []const u8,
    elevator_penalty: ?f32 = null,
    levels: [2]?f32 = .{ null, null },
    radius: ?u32 = null,
};
pub const indoor_routes: []const Pair = &.{
    .{ .from = "F", .to = "J" },
    .{ .from = "F", .to = "A" },
    .{ .from = "E", .to = "O" },
    .{ .from = "F", .to = "M" },
    .{ .from = "D", .to = "F" },
    .{ .from = "F", .to = "D" },
    .{ .from = "F", .to = "J", .elevator_penalty = 3600 },
    .{ .from = "B", .to = "C", .levels = .{ 0, 1 } },
};
pub const lane_routes: []const Pair = &.{ .{ .from = "D", .to = "C" }, .{ .from = "A", .to = "D" }, .{ .from = "C", .to = "D" } };
pub const split_routes: []const Pair = &.{ .{ .from = "A", .to = "C" }, .{ .from = "A", .to = "E" }, .{ .from = "A", .to = "G" }, .{ .from = "A", .to = "H" } };
pub const level_change_routes: []const Pair = &.{.{ .from = "A", .to = "D", .radius = 1 }};
pub const ferry_routes: []const Pair = &.{ .{ .from = "A", .to = "D" }, .{ .from = "D", .to = "A" } };

pub fn corpus(arena: Allocator, fixture: gurka.Map, path: []const u8, costing: []const u8, pairs: []const Pair) !void {
    const io = @import("routing").infra.io;
    const Location = struct {
        lat: f64,
        lon: f64,
        minimum_reachability: u32 = 0,
        search_filter: struct { level: ?f32 },
        radius: ?u32,
        node_snap_tolerance: ?f32,
    };
    var rows: std.ArrayList(u8) = .empty;
    for (pairs) |pair| {
        var locations: [2]Location = undefined;
        for ([_][]const u8{ pair.from, pair.to }, pair.levels, &locations) |name, level, *location| {
            const point = fixture.layout.get(name) orelse return error.InvalidFixtureLocation;
            location.* = .{
                .lat = point.lat,
                .lon = point.lng,
                .search_filter = .{ .level = level },
                .radius = pair.radius,
                .node_snap_tolerance = if (pair.radius != null) 0 else null,
            };
        }
        const line = try std.json.Stringify.valueAlloc(arena, .{
            .locations = locations,
            .costing = costing,
            .directions_type = "instructions",
            .costing_options = .{ .pedestrian = .{ .elevator_penalty = pair.elevator_penalty } },
        }, .{ .emit_null_optional_fields = false });
        try rows.appendSlice(arena, "/route\t");
        try rows.appendSlice(arena, line);
        try rows.append(arena, '\n');
    }
    try io.writeFile(path, rows.items);
}
