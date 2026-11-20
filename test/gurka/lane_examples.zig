// Ported from test/gurka/test_turn_lanes.cc (Valhalla 3.9.3).
const std = @import("std");
const gurka = @import("gurka.zig");
const Pair = @import("narrative_examples.zig").Pair;
const Allocator = std.mem.Allocator;

const Fixture = struct { map: gurka.Map, routes: []const Pair };
const Scenario = enum { @"shared-lanes", @"short-arrival-lanes", @"uturn-lanes", @"internal-lanes", @"restricted-lanes", @"fork-lanes", @"short-fork-lanes" };

pub fn find(arena: Allocator, name: []const u8) !?Fixture {
    const scenario = std.meta.stringToEnum(Scenario, name) orelse return null;
    return switch (scenario) {
        .@"shared-lanes" => .{ .map = try sharedLanes(arena), .routes = &.{ .{ .from = "A", .to = "G" }, .{ .from = "A", .to = "C" }, .{ .from = "A", .to = "F" } } },
        .@"short-arrival-lanes" => .{ .map = try shortArrivalLanes(arena), .routes = &.{ .{ .from = "A", .to = "1" }, .{ .from = "A", .to = "2" }, .{ .from = "A", .to = "E" }, .{ .from = "A", .to = "3" }, .{ .from = "A", .to = "4" }, .{ .from = "A", .to = "F" }, .{ .from = "A", .to = "G" } } },
        .@"uturn-lanes" => .{ .map = try uturnLanes(arena), .routes = &.{ .{ .from = "A", .to = "H" }, .{ .from = "E", .to = "D" } } },
        .@"internal-lanes" => .{ .map = try internalLanes(arena), .routes = &.{.{ .from = "A", .to = "L" }} },
        .@"restricted-lanes" => .{ .map = try restrictedLanes(arena), .routes = &.{ .{ .from = "A", .to = "H" }, .{ .from = "E", .to = "D" }, .{ .from = "K", .to = "J" } } },
        .@"fork-lanes" => .{ .map = try forkLanes(arena, 500), .routes = &.{ .{ .from = "A", .to = "E" }, .{ .from = "A", .to = "F" } } },
        .@"short-fork-lanes" => .{ .map = try forkLanes(arena, 20), .routes = &.{ .{ .from = "A", .to = "E" }, .{ .from = "A", .to = "F" } } },
    };
}

fn sharedLanes(arena: Allocator) !gurka.Map {
    return gurka.Map.init(arena, try gurka.mapToCoordinates(
        \\A---B---D---E---G
        \\    |       |
        \\    C       F
    , 10), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "lanes:forward", .value = "3" },
            .{ .key = "turn:lanes:forward", .value = "through|through|right" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "residential" },
        } },
        .{ .label = "BD", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "lanes:forward", .value = "3" },
            .{ .key = "turn:lanes:forward", .value = "through|through|right" },
        } },
        .{ .label = "DE", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "lanes:forward", .value = "3" },
            .{ .key = "turn:lanes:forward", .value = "through|through|right" },
        } },
        .{ .label = "EF", .tags = &.{
            .{ .key = "highway", .value = "residential" },
        } },
        .{ .label = "EG", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "lanes:forward", .value = "2" },
            .{ .key = "turn:lanes:forward", .value = "through|through" },
        } },
    }, &.{}, &.{});
}

fn shortArrivalLanes(arena: Allocator) !gurka.Map {
    return gurka.Map.init(arena, try gurka.mapToCoordinates(
        \\        E
        \\        |
        \\   1    |    2
        \\        |
        \\        |
        \\        |
        \\        |
        \\A---B---C---D
        \\        |
        \\        |
        \\      3 F 4
        \\        |
        \\        |
        \\        G
    , 100), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "lanes:forward", .value = "5" },
            .{ .key = "driving_side", .value = "right" },
            .{ .key = "turn:lanes:forward", .value = "left|left|through|right|right" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "lanes:forward", .value = "5" },
            .{ .key = "driving_side", .value = "right" },
            .{ .key = "turn:lanes:forward", .value = "left|left|through|right|right" },
        } },
        .{ .label = "CD", .tags = &.{
            .{ .key = "highway", .value = "trunk" },
            .{ .key = "driving_side", .value = "right" },
        } },
        .{ .label = "ECFG", .tags = &.{
            .{ .key = "highway", .value = "trunk" },
            .{ .key = "driving_side", .value = "right" },
        } },
    }, &.{}, &.{});
}

fn uturnLanes(arena: Allocator) !gurka.Map {
    return gurka.Map.init(arena, try gurka.mapToCoordinatesAt(
        \\     E D
        \\     | |
        \\     | |
        \\     | |
        \\     | |
        \\L----F-C----K
        \\     | |
        \\I----G-B----J
        \\     | |
        \\     | |
        \\     | |
        \\     | |
        \\     H A
    , 10, .{ .lng = 5.1079374, .lat = 52.0887174 }), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
            .{ .key = "lanes", .value = "5" },
            .{ .key = "turn:lanes", .value = "left|left|through|right|right" },
        } },
        .{ .label = "EF", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
            .{ .key = "lanes", .value = "4" },
            .{ .key = "turn:lanes", .value = "reverse|left|through|right" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "CD", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "FG", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "GH", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "IG", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
        } },
        .{ .label = "GB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "BJ", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "KC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "CF", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "FL", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
        } },
    }, &.{}, &.{});
}

fn internalLanes(arena: Allocator) !gurka.Map {
    return gurka.Map.init(arena, try gurka.mapToCoordinatesAt(
        \\     E D
        \\     | |
        \\     | |
        \\     | |
        \\     | |
        \\L----F-C-----K
        \\     | |
        \\I----G-B--N--J
        \\     | | /
        \\     | |/
        \\     | M
        \\     | |
        \\     H A
    , 10, .{ .lng = 5.1079374, .lat = 52.0887174 }), &.{
        .{ .label = "AM", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
            .{ .key = "lanes", .value = "5" },
            .{ .key = "turn:lanes", .value = "through|through|right" },
        } },
        .{ .label = "MB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
            .{ .key = "lanes", .value = "5" },
            .{ .key = "internal_intersection", .value = "true" },
            .{ .key = "turn:lanes", .value = "left|through|through" },
        } },
        .{ .label = "EF", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
            .{ .key = "lanes", .value = "4" },
            .{ .key = "turn:lanes", .value = "reverse|left|through|right" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "internal_intersection", .value = "true" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "CD", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "FG", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "internal_intersection", .value = "true" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "GH", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "IG", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
        } },
        .{ .label = "GB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "internal_intersection", .value = "true" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "BN", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "internal_intersection", .value = "true" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "NJ", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "KC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "CF", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "internal_intersection", .value = "true" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "FL", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
        } },
    }, &.{}, &.{});
}

fn restrictedLanes(arena: Allocator) !gurka.Map {
    return gurka.Map.init(arena, try gurka.mapToCoordinatesAt(
        \\               E D
        \\               | |
        \\               | |
        \\     N    P    | |
        \\     |    |    | |
        \\Q----M----L----F-C----K
        \\     |    |    | |
        \\R----O----I----G-B----J
        \\               | |
        \\               | |
        \\               | |
        \\               | |
        \\               H A
    , 10, .{ .lng = 5.1079374, .lat = 52.0887174 }), &.{
        .{ .label = "ABC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
            .{ .key = "lanes", .value = "5" },
            .{ .key = "turn:lanes", .value = "left|left|through|right|right" },
        } },
        .{ .label = "EF", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
            .{ .key = "lanes", .value = "4" },
            .{ .key = "turn:lanes", .value = "reverse|left|through|right" },
        } },
        .{ .label = "CD", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "FG", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "GH", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Broken Land Parkway" },
        } },
        .{ .label = "FL", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
            .{ .key = "lanes", .value = "3" },
            .{ .key = "turn:lanes", .value = "||right" },
        } },
        .{ .label = "LM", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
            .{ .key = "lanes", .value = "3" },
            .{ .key = "turn:lanes", .value = "||right" },
        } },
        .{ .label = "MQ", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
        } },
        .{ .label = "RO", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
        } },
        .{ .label = "OI", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
        } },
        .{ .label = "IG", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Patuxent Woods Drive" },
        } },
        .{ .label = "LI", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Small Internal Street" },
        } },
        .{ .label = "MO", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Small Internal Street" },
        } },
        .{ .label = "LP", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "First Street" },
        } },
        .{ .label = "MN", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Second Street" },
        } },
        .{ .label = "GB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "BJ", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "KC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
        .{ .label = "CF", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "name", .value = "Snowden River Parkway" },
        } },
    }, &.{}, &.{
        .{ .members = &.{
            .{ .kind = .way, .ref = "CF", .role = "from" },
            .{ .kind = .way, .ref = "GB", .role = "to" },
            .{ .kind = .way, .ref = "FG", .role = "via" },
        }, .tags = &.{
            .{ .key = "type", .value = "restriction" },
            .{ .key = "restriction", .value = "no_u_turn" },
        } },
        .{ .members = &.{
            .{ .kind = .way, .ref = "FL", .role = "from" },
            .{ .kind = .way, .ref = "IG", .role = "to" },
            .{ .kind = .way, .ref = "LI", .role = "via" },
        }, .tags = &.{
            .{ .key = "type", .value = "restriction" },
            .{ .key = "restriction", .value = "no_u_turn" },
        } },
    });
}

fn forkLanes(arena: Allocator, spacing: f64) !gurka.Map {
    return gurka.Map.init(arena, try gurka.mapToCoordinatesAt(
        \\    H   J
        \\    |   |          E
        \\A---B---C---D<
        \\    |   |          F
        \\    G   I
    , spacing, .{ .lng = 5.1079374, .lat = 52.0887174 }), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Frankfurter Ring" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "lanes", .value = "3" },
            .{ .key = "turn:lanes", .value = "left|through|through;right" },
        } },
        .{ .label = "BG", .tags = &.{
            .{ .key = "highway", .value = "tertiary" },
            .{ .key = "name", .value = "Knorrstraße" },
        } },
        .{ .label = "BH", .tags = &.{
            .{ .key = "highway", .value = "tertiary" },
            .{ .key = "name", .value = "Knorrstraße" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Frankfurter Ring" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "lanes", .value = "3" },
            .{ .key = "turn:lanes", .value = "left|through|through;right" },
        } },
        .{ .label = "CI", .tags = &.{
            .{ .key = "highway", .value = "tertiary" },
            .{ .key = "name", .value = "Am Nordring" },
        } },
        .{ .label = "CJ", .tags = &.{
            .{ .key = "highway", .value = "tertiary" },
            .{ .key = "name", .value = "Am Nordring" },
        } },
        .{ .label = "CD", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Frankfurter Ring" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "lanes", .value = "2" },
            .{ .key = "turn:lanes", .value = "through|slight_right" },
        } },
        .{ .label = "DE", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Frankfurter Ring" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "lanes", .value = "1" },
        } },
        .{ .label = "DF", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Frankfurter Ring" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "lanes", .value = "2" },
        } },
    }, &.{}, &.{});
}
