// Ported from test/gurka/test_centroid.cc, test_zero_length_route.cc, and
// test_instructions_pencilpoint_uturn.cc (Valhalla 3.9.3).

const std = @import("std");
const gurka = @import("gurka.zig");
const Allocator = std.mem.Allocator;

test {
    _ = @import("pbf.zig");
    _ = @import("edges.zig");
    _ = @import("assemble.zig");
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

// Ported from test/gurka/test_simple_restrictions.cc (Valhalla 3.9.3).
pub fn simpleTurns(arena: Allocator) !gurka.Map {
    const primary: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    return gurka.Map.init(arena, try gurka.mapToCoordinates(
        \\A---B----C     K---L---M
        \\|   |              |
        \\D---E----F         N
        \\|
        \\G---H----I
    , 50), &.{
        .{ .label = "AB", .tags = primary },
        .{ .label = "BC", .tags = primary },
        .{ .label = "DEF", .tags = primary },
        .{ .label = "GHI", .tags = primary },
        .{ .label = "ADG", .tags = primary },
        .{ .label = "BE", .tags = primary },
        .{ .label = "KL", .tags = primary },
        .{ .label = "LM", .tags = primary },
        .{ .label = "LN", .tags = primary },
    }, &.{}, &.{
        .{
            .members = &.{
                .{ .kind = .way, .ref = "BC", .role = "from" },
                .{ .kind = .node, .ref = "B", .role = "via" },
                .{ .kind = .way, .ref = "BE", .role = "to" },
            },
            .tags = &.{ .{ .key = "type", .value = "restriction" }, .{ .key = "restriction", .value = "no_left_turn" } },
        },
        .{
            .members = &.{
                .{ .kind = .way, .ref = "KL", .role = "from" },
                .{ .kind = .node, .ref = "L", .role = "via" },
                .{ .kind = .way, .ref = "LM", .role = "to" },
            },
            .tags = &.{ .{ .key = "type", .value = "restriction" }, .{ .key = "restriction", .value = "only_straight_on" } },
        },
        .{
            .members = &.{
                .{ .kind = .way, .ref = "DEF", .role = "from" },
                .{ .kind = .node, .ref = "D", .role = "via" },
                .{ .kind = .way, .ref = "ADG", .role = "to" },
            },
            .tags = &.{ .{ .key = "type", .value = "restriction" }, .{ .key = "restriction:bicycle", .value = "no_right_turn" } },
        },
        .{
            .members = &.{
                .{ .kind = .way, .ref = "ADG", .role = "from" },
                .{ .kind = .node, .ref = "D", .role = "via" },
                .{ .kind = .way, .ref = "DEF", .role = "to" },
            },
            .tags = &.{
                .{ .key = "type", .value = "restriction" },
                .{ .key = "restriction", .value = "no_left_turn" },
                .{ .key = "except", .value = "psv;bicycle" },
            },
        },
        .{
            .members = &.{
                .{ .kind = .way, .ref = "GHI", .role = "from" },
                .{ .kind = .way, .ref = "ADG", .role = "via" },
                .{ .kind = .way, .ref = "AB", .role = "to" },
            },
            .tags = &.{ .{ .key = "type", .value = "restriction" }, .{ .key = "restriction", .value = "no_entry" } },
        },
    });
}

// Ported from test/gurka/test_truck.cc (Valhalla 3.9.3). The middle
// restrictions and the one-way clearance exercise storage in both directions.
pub fn motorVehicle(arena: Allocator) !gurka.Map {
    return gurka.Map.init(arena, try gurka.mapToCoordinates("A---B---C---D", 10), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "residential" },
            .{ .key = "maxheight:forward", .value = "4" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "residential" },
            .{ .key = "name", .value = "Restricted Street" },
            .{ .key = "layer", .value = "1" },
            .{ .key = "maxheight", .value = "5" },
            .{ .key = "maxheight:forward", .value = "13'6\"" },
            .{ .key = "maxwidth", .value = "default" },
            .{ .key = "maxwidth:physical", .value = "300 cm" },
            .{ .key = "maxlength", .value = "25" },
            .{ .key = "maxweight", .value = "12000 lb" },
            .{ .key = "maxweight:conditional", .value = "none @ destination" },
            .{ .key = "maxaxleload", .value = "10 tonnes" },
            .{ .key = "maxaxles", .value = "8" },
            .{ .key = "hazmat", .value = "destination" },
            .{ .key = "hazmat:water:backward", .value = "yes" },
            .{ .key = "hgv", .value = "designated" },
            .{ .key = "toll", .value = "interval" },
        } },
        .{ .label = "CD", .tags = &.{
            .{ .key = "highway", .value = "motorway" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "hov", .value = "designated" },
            .{ .key = "hov:minimum", .value = "3" },
            .{ .key = "hov:lanes", .value = "designated|designated" },
            .{ .key = "hgv", .value = "destination" },
            .{ .key = "motorcycle", .value = "designated" },
            .{ .key = "moped", .value = "designated" },
        } },
    }, &.{.{ .label = "C", .tags = &.{
        .{ .key = "barrier", .value = "toll_booth" },
        .{ .key = "payment:coins", .value = "yes" },
        .{ .key = "payment:credit_cards", .value = "no" },
    } }}, &.{});
}

pub fn adminBoundaries(arena: Allocator) !gurka.Map {
    var layout: gurka.NodeLayout = .{};
    const vertices = [_]struct { label: u8, lng: f64, lat: f64 }{
        .{ .label = 'A', .lng = 1, .lat = 44.2 },
        .{ .label = 'B', .lng = 3, .lat = 44.2 },
        .{ .label = 'C', .lng = 3, .lat = 45.8 },
        .{ .label = 'D', .lng = 1, .lat = 45.8 },
        .{ .label = 'E', .lng = 1.8, .lat = 44.8 },
        .{ .label = 'F', .lng = 2.2, .lat = 44.8 },
        .{ .label = 'G', .lng = 2.2, .lat = 45.2 },
        .{ .label = 'H', .lng = 1.8, .lat = 45.2 },
        .{ .label = 'I', .lng = 4, .lat = 44.4 },
        .{ .label = 'J', .lng = 4.5, .lat = 44.4 },
        .{ .label = 'K', .lng = 4.5, .lat = 45.0 },
        .{ .label = 'L', .lng = 4, .lat = 45.0 },
        .{ .label = 'M', .lng = 1.4, .lat = 44.4 },
        .{ .label = 'N', .lng = 2.6, .lat = 44.4 },
        .{ .label = 'O', .lng = 2.6, .lat = 45.6 },
        .{ .label = 'P', .lng = 1.4, .lat = 45.6 },
        .{ .label = 'Q', .lng = 1.5, .lat = 44.5 },
        .{ .label = 'R', .lng = 1.6, .lat = 44.6 },
        .{ .label = 'S', .lng = 1.9, .lat = 44.9 },
        .{ .label = 'T', .lng = 2.1, .lat = 45.0 },
        .{ .label = 'U', .lng = 4.25, .lat = 44.6 },
        .{ .label = 'V', .lng = 4.3, .lat = 44.7 },
        .{ .label = 'W', .lng = 3.05, .lat = 45 },
        .{ .label = 'X', .lng = 3.1, .lat = 45.01 },
    };
    for (vertices) |v| layout.points[v.label] = .{ .lng = v.lng, .lat = v.lat };
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const boundary = [_]gurka.Tag{ .{ .key = "type", .value = "boundary" }, .{ .key = "boundary", .value = "administrative" } };
    return gurka.Map.init(arena, layout, &.{
        .{ .label = "AB" },               .{ .label = "CB" },               .{ .label = "CD" },               .{ .label = "AD" },
        .{ .label = "EFGHE" },            .{ .label = "IJKLI" },            .{ .label = "MNOPM" },            .{ .label = "QR", .tags = road },
        .{ .label = "ST", .tags = road }, .{ .label = "UV", .tags = road }, .{ .label = "WX", .tags = road },
    }, &.{}, &.{
        .{ .tags = &(boundary ++ [_]gurka.Tag{
            .{ .key = "admin_level", .value = "2" },
            .{ .key = "name", .value = "United Kingdom" },
            .{ .key = "ISO3166-1:alpha2", .value = "GB" },
        }), .members = &.{
            .{ .kind = .way, .ref = "CD", .role = "outer" },
            .{ .kind = .way, .ref = "EFGHE", .role = "inner" },
            .{ .kind = .way, .ref = "IJKLI", .role = "outer" },
            .{ .kind = .way, .ref = "AB", .role = "outer" },
            .{ .kind = .way, .ref = "CB", .role = "outer" },
            .{ .kind = .way, .ref = "AD", .role = "outer" },
        } },
        .{ .tags = &(boundary ++ [_]gurka.Tag{
            .{ .key = "admin_level", .value = "4" },
            .{ .key = "name", .value = "Testshire" },
            .{ .key = "ISO3166-2", .value = "GB-TST" },
        }), .members = &.{
            .{ .kind = .way, .ref = "MNOPM", .role = "outer" },
            .{ .kind = .way, .ref = "EFGHE", .role = "inner" },
        } },
        .{ .tags = &(boundary ++ [_]gurka.Tag{
            .{ .key = "admin_level", .value = "2" },
            .{ .key = "name", .value = "Belgium" },
            .{ .key = "ISO3166-1", .value = "BE" },
        }), .members = &.{.{ .kind = .way, .ref = "EFGHE", .role = "outer" }} },
        .{ .tags = &(boundary ++ [_]gurka.Tag{
            .{ .key = "admin_level", .value = "2" },
            .{ .key = "name", .value = "Unclosed" },
        }), .members = &.{.{ .kind = .way, .ref = "WX", .role = "outer" }} },
    });
}

// The Dutch cycleways from test/countryaccess.cc (Valhalla 3.9.3)
// run alongside Belgian and border-crossing trunks in this graph.
pub fn countryAccess(arena: Allocator) !gurka.Map {
    var fixture = try adminBoundaries(arena);
    const ways = try arena.alloc(gurka.OsmWay, fixture.osm.ways.len + 1);
    @memcpy(ways[0..fixture.osm.ways.len], fixture.osm.ways);
    const eql = std.mem.eql;
    for (ways[0..fixture.osm.ways.len]) |*way| {
        if (eql(u8, way.label, "QR")) way.tags = &.{
            .{ .key = "highway", .value = "cycleway" },
            .{ .key = "moped", .value = "designated" },
        };
        if (eql(u8, way.label, "ST")) way.tags = &.{
            .{ .key = "highway", .value = "trunk" },
            .{ .key = "foot", .value = "yes" },
            .{ .key = "moped", .value = "no" },
        };
        if (eql(u8, way.label, "UV")) way.tags = &.{
            .{ .key = "highway", .value = "cycleway" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "moped", .value = "designated" },
        };
        if (eql(u8, way.label, "WX")) way.tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "motorroad", .value = "yes" },
        };
    }
    ways[ways.len - 1] = .{
        .id = ways[ways.len - 2].id + 1,
        .label = "RS",
        .refs = try arena.dupe(i64, &.{ fixture.findNode("R").?.id, fixture.findNode("S").?.id }),
        .tags = &.{.{ .key = "highway", .value = "trunk" }},
    };
    fixture.osm.ways = ways;
    const relations = try arena.dupe(gurka.OsmRelation, fixture.osm.relations);
    for (relations) |*relation| {
        const name = gurka.tagValue(relation.tags, "name").?;
        if (eql(u8, name, "United Kingdom")) relation.tags = &.{
            .{ .key = "type", .value = "boundary" },
            .{ .key = "boundary", .value = "administrative" },
            .{ .key = "admin_level", .value = "2" },
            .{ .key = "name", .value = "Nederland" },
            .{ .key = "name:en", .value = "Netherlands" },
            .{ .key = "ISO3166-1:alpha2", .value = "NL" },
        };
        if (eql(u8, name, "Testshire")) relation.tags = &.{
            .{ .key = "type", .value = "boundary" },
            .{ .key = "boundary", .value = "administrative" },
            .{ .key = "admin_level", .value = "4" },
            .{ .key = "name", .value = "Testshire" },
            .{ .key = "ISO3166-2", .value = "NL-TST" },
        };
    }
    fixture.osm.relations = relations;
    return fixture;
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
