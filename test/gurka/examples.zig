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

// Access costs from test_destination_only.cc and a required return through
// the entrance from test_not_thru_pruning.cc (Valhalla 3.9.3).
pub fn accessRegions(arena: Allocator) !gurka.Map {
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    return gurka.Map.init(arena, try gurka.mapToCoordinates(
        \\A---B---C---D---E---F
        \\    |           |
        \\    H-----------G
        \\
        \\K---L---M---N
        \\    |
        \\    P---Q
        \\    |   |
        \\    S---R
    , 100), &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "BC", .tags = &.{ road[0], .{ .key = "motor_vehicle", .value = "destination" } } },
        .{ .label = "CD", .tags = &.{ road[0], .{ .key = "access", .value = "private" } } },
        .{ .label = "DE", .tags = road },
        .{ .label = "EF", .tags = road },
        .{ .label = "BH", .tags = road },
        .{ .label = "HG", .tags = road },
        .{ .label = "GE", .tags = road },
        .{ .label = "KL", .tags = road },
        .{ .label = "LM", .tags = road },
        .{ .label = "MN", .tags = road },
        .{ .label = "LP", .tags = road },
        .{ .label = "PQRSP", .tags = road },
    }, &.{.{ .label = "H", .tags = &.{ .{ .key = "barrier", .value = "gate" }, .{ .key = "access", .value = "private" } } }}, &.{
        .{
            .members = &.{
                .{ .kind = .way, .ref = "KL", .role = "from" },
                .{ .kind = .node, .ref = "L", .role = "via" },
                .{ .kind = .way, .ref = "LM", .role = "to" },
            },
            .tags = &.{ .{ .key = "type", .value = "restriction" }, .{ .key = "restriction", .value = "no_straight_on" } },
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

// Ported from test/gurka/test_only_restrictions.cc (Valhalla 3.9.3).
pub const OnlyTurns = enum { straight, one_neighbour, many_neighbours };

pub fn onlyTurns(arena: Allocator, scenario: OnlyTurns) !gurka.Map {
    const primary: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    const oneway: gurka.Tags = &.{ primary[0], .{ .key = "oneway", .value = "yes" } };
    const ascii = switch (scenario) {
        .straight => "A-B-C-D-E-F",
        .one_neighbour => "      1\n     /\n  B-C---D---E",
        .many_neighbours => "         1   3--5\n         |   |\nA----B---C---D---E-----F\n         |   |\n         2   4",
    };
    const ways: []const gurka.Way = switch (scenario) {
        .straight => &.{
            .{ .label = "AB", .tags = primary }, .{ .label = "BC", .tags = primary }, .{ .label = "CD", .tags = primary },
            .{ .label = "DE", .tags = primary }, .{ .label = "EF", .tags = primary },
        },
        .one_neighbour => &.{
            .{ .label = "BC", .tags = primary }, .{ .label = "CD", .tags = oneway }, .{ .label = "DE", .tags = primary },
            .{ .label = "C1", .tags = primary },
        },
        .many_neighbours => &.{
            .{ .label = "AB", .tags = oneway },  .{ .label = "BC", .tags = primary }, .{ .label = "CD", .tags = primary },
            .{ .label = "DE", .tags = oneway },  .{ .label = "EF", .tags = primary }, .{ .label = "C1", .tags = primary },
            .{ .label = "C2", .tags = primary }, .{ .label = "D3", .tags = primary }, .{ .label = "D4", .tags = primary },
            .{ .label = "35", .tags = primary },
        },
    };
    return gurka.Map.init(arena, try gurka.mapToCoordinates(ascii, 100), ways, &.{}, &.{.{
        .members = &.{
            .{ .kind = .way, .ref = "BC", .role = "from" },
            .{ .kind = .way, .ref = "CD", .role = "via" },
            .{ .kind = .way, .ref = "DE", .role = "to" },
        },
        .tags = &.{
            .{ .key = "type", .value = "restriction" },
            .{ .key = "restriction", .value = switch (scenario) {
                .straight => "only_straight_on",
                .one_neighbour => "only_left_turn",
                .many_neighbours => "only_right_turn",
            } },
        },
    }});
}

pub fn multiViaTurns(arena: Allocator) !gurka.Map {
    const oneway: gurka.Tags = &.{ .{ .key = "highway", .value = "primary" }, .{ .key = "oneway", .value = "yes" } };
    const ascii = "A---B---M---C---D---E\n|       |   |\n|       Z   |\n|           |\nX-----------Y";
    return gurka.Map.init(arena, try gurka.mapToCoordinates(ascii, 100), &.{
        .{ .label = "AB", .tags = oneway }, .{ .label = "BMC", .tags = oneway }, .{ .label = "CD", .tags = oneway },
        .{ .label = "DE", .tags = oneway }, .{ .label = "AX", .tags = oneway },  .{ .label = "XY", .tags = oneway },
        .{ .label = "YC", .tags = oneway }, .{ .label = "MZ", .tags = oneway },
    }, &.{}, &.{.{
        .members = &.{
            .{ .kind = .way, .ref = "AB", .role = "from" },
            .{ .kind = .way, .ref = "BMC", .role = "via" },
            .{ .kind = .way, .ref = "CD", .role = "via" },
            .{ .kind = .way, .ref = "DE", .role = "to" },
        },
        .tags = &.{ .{ .key = "type", .value = "restriction" }, .{ .key = "restriction", .value = "no_straight_on" }, .{ .key = "except", .value = "bicycle" } },
    }});
}

// Ported from test/gurka/test_conditional_restrictions.cc (Valhalla 3.9.3).
pub fn conditionalAccess(arena: Allocator) !gurka.Map {
    const service: gurka.Tag = .{ .key = "highway", .value = "service" };
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const hours = "(Mar 00:00-07:00;Mar 17:30-24:00;Apr 00:00-07:00;Apr 19:00-24:00;Aug 00:00-07:00;Aug 19:00-24:00)";
    const denied = "no @ " ++ hours;
    const allowed = "yes @ " ++ hours;
    const destination = "destination @ " ++ hours;
    const delivery = "delivery @ " ++ hours;
    const private = "private @ " ++ hours;
    const designated = "designated @ " ++ hours;
    return gurka.Map.init(arena, try gurka.mapToCoordinates(
        \\A----B
        \\|    |
        \\D    C
        \\ \  /
        \\  E
        \\
        \\F----G----H----I----J----K----L
        \\                    |    |
        \\                    M----N
        \\
        \\R---S---T---U
    , 100), &.{
        .{ .label = "AD", .tags = &.{ service, .{ .key = "motorcar", .value = "no" }, .{ .key = "bicycle", .value = "yes" }, .{ .key = "foot", .value = "yes" }, .{ .key = "bicycle:conditional", .value = allowed }, .{ .key = "foot:conditional", .value = private } } },
        .{ .label = "AB", .tags = &.{
            service,                                                 .{ .key = "motorcar:conditional", .value = delivery },
            .{ .key = "motorcycle:conditional", .value = delivery }, .{ .key = "moped:conditional", .value = delivery },
            .{ .key = "psv:conditional", .value = delivery },        .{ .key = "taxi:conditional", .value = delivery },
            .{ .key = "bus:conditional", .value = delivery },        .{ .key = "hov:conditional", .value = delivery },
            .{ .key = "emergency:conditional", .value = delivery },  .{ .key = "bicycle:conditional", .value = denied },
            .{ .key = "foot:conditional", .value = designated },
        } },
        .{ .label = "BC", .tags = &.{ service, .{ .key = "motorcar:conditional", .value = destination } } },
        .{ .label = "CD", .tags = &.{ service, .{ .key = "motorcar:conditional", .value = allowed }, .{ .key = "bicycle:conditional", .value = denied }, .{ .key = "foot:conditional", .value = private } } },
        .{ .label = "DE", .tags = &.{ service, .{ .key = "motorcar:conditional", .value = delivery }, .{ .key = "bicycle:conditional", .value = denied }, .{ .key = "foot:conditional", .value = designated } } },
        .{ .label = "CE", .tags = &.{ service, .{ .key = "motorcar:conditional", .value = destination }, .{ .key = "bicycle:conditional", .value = denied }, .{ .key = "foot:conditional", .value = allowed } } },
        .{ .label = "FG", .tags = road },
        .{ .label = "GH", .tags = road },
        .{ .label = "IJ", .tags = road },
        .{ .label = "HI", .tags = &.{ road[0], .{ .key = "motor_vehicle:conditional", .value = destination } } },
        .{ .label = "JK", .tags = &.{ road[0], .{ .key = "motor_vehicle:conditional", .value = destination } } },
        .{ .label = "KL", .tags = road },
        .{ .label = "JM", .tags = road },
        .{ .label = "MN", .tags = road },
        .{ .label = "NK", .tags = road },
        .{ .label = "RS", .tags = road },
        .{ .label = "ST", .tags = &.{ road[0], .{ .key = "access:conditional", .value = denied } } },
        .{ .label = "TU", .tags = road },
    }, &.{}, &.{});
}

// Ported from test/gurka/test_time_dependent_restrictions.cc (Valhalla 3.9.3).
pub fn timedTurns(arena: Allocator, only: bool) !gurka.Map {
    const road: gurka.Tags = if (only) &.{.{ .key = "highway", .value = "primary" }} else &.{.{ .key = "highway", .value = "motorway" }};
    const tags: gurka.Tags = if (only) &.{
        .{ .key = "type", .value = "restriction" },
        .{ .key = "restriction:conditional", .value = "only_straight_on @ (Mo-Fr 07:00-19:00)" },
        .{ .key = "except", .value = "bicycle" },
    } else &.{
        .{ .key = "type", .value = "restriction" },
        .{ .key = "restriction", .value = "no_left_turn" },
        .{ .key = "hour_on", .value = "07:00" },
        .{ .key = "hour_off", .value = "19:00" },
    };
    return gurka.Map.init(arena, try gurka.mapToCoordinates("D----B----A\n|    |\n|    |\nE----C----F", 10), &.{
        .{ .label = "AB", .tags = road }, .{ .label = "BC", .tags = road }, .{ .label = "BD", .tags = road },
        .{ .label = "CF", .tags = road }, .{ .label = "DE", .tags = road }, .{ .label = "EC", .tags = road },
    }, &.{}, &.{.{
        .members = &.{
            .{ .kind = .way, .ref = "AB", .role = "from" },
            .{ .kind = .way, .ref = "BC", .role = "to" },
            .{ .kind = .node, .ref = "B", .role = "via" },
        },
        .tags = tags,
    }});
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

// Sign tags exercise the ramp and fork cases from Valhalla's
// test/gurka/test_instructions_keep_ramp_signs.cc.
pub fn signs(arena: Allocator) !gurka.Map {
    const layout = try gurka.mapToCoordinatesAt(
        \\P-------------------------------Q
        \\
        \\            E              H
        \\            |             /
        \\  A---B-----C---D---F----G----I
        \\      |             |
        \\      J---K         L
        \\
        \\S-------------------------------R
    , 200, .{ .lng = 139.7, .lat = 35.7 });
    const motorway = [_]gurka.Tag{
        .{ .key = "highway", .value = "motorway" },
        .{ .key = "oneway", .value = "yes" },
    };
    const ramp = [_]gurka.Tag{
        .{ .key = "highway", .value = "motorway_link" },
        .{ .key = "oneway", .value = "yes" },
        .{ .key = "maxspeed", .value = "95" },
    };
    const primary = gurka.Tag{ .key = "highway", .value = "primary" };
    return gurka.Map.init(arena, layout, &.{
        .{ .label = "AB", .tags = &motorway },
        .{ .label = "BC", .tags = &motorway },
        .{ .label = "CD", .tags = &motorway },
        .{ .label = "BJ", .tags = &ramp },
        .{ .label = "JK", .tags = &.{primary} },
        .{ .label = "CE", .tags = &(ramp ++ [_]gurka.Tag{
            .{ .key = "junction:ref", .value = "9A;9B" },
            .{ .key = "destination:ref", .value = "A 1;;A 2;" },
            .{ .key = "destination:street", .value = "West Road; West Spur" },
            .{ .key = "destination:ref:to", .value = "B 7" },
            .{ .key = "destination:street:to", .value = "East Road" },
            .{ .key = "destination", .value = "Harbour;Parks;Harbour" },
            .{ .key = "destination:forward", .value = "Suppressed" },
            .{ .key = "junction:name", .value = "Clover Junction" },
        }) },
        .{ .label = "DF", .tags = &.{
            primary,
            .{ .key = "destination:forward", .value = "Museum" },
            .{ .key = "destination:backward", .value = "Old Town" },
        } },
        .{ .label = "FG", .tags = &motorway },
        .{ .label = "FL", .tags = &.{primary} },
        .{ .label = "GH", .tags = &(motorway ++ [_]gurka.Tag{
            .{ .key = "destination:ref", .value = "M 2" },
            .{ .key = "destination", .value = "Coast" },
        }) },
        .{ .label = "GI", .tags = &(motorway ++ [_]gurka.Tag{.{ .key = "destination", .value = "Hills" }}) },
        .{ .label = "PQRSP" },
    }, &.{
        .{ .label = "B", .tags = &.{
            .{ .key = "highway", .value = "motorway_junction" },
            .{ .key = "ref", .value = "5" },
            .{ .key = "exit_to", .value = "I 95 To I 695;TO Airport;Downtown" },
            .{ .key = "name", .value = "West Exit" },
        } },
        .{ .label = "C", .tags = &.{
            .{ .key = "highway", .value = "motorway_junction" },
            .{ .key = "ref", .value = "Should not appear" },
            .{ .key = "exit_to", .value = "Should not appear" },
            .{ .key = "name", .value = "East Exit" },
        } },
        .{ .label = "D", .tags = &.{
            .{ .key = "highway", .value = "traffic_signals" },
            .{ .key = "name", .value = "Central Crossing;North Crossing" },
        } },
        .{ .label = "F", .tags = &.{
            .{ .key = "barrier", .value = "toll_booth" },
            .{ .key = "name", .value = "River Toll" },
        } },
        .{ .label = "G", .tags = &.{
            .{ .key = "highway", .value = "motorway_junction" },
            .{ .key = "ref", .value = "Fork Ref" },
            .{ .key = "name", .value = "Fork Name" },
        } },
    }, &.{.{
        .members = &.{.{ .kind = .way, .ref = "PQRSP", .role = "outer" }},
        .tags = &.{
            .{ .key = "type", .value = "boundary" },
            .{ .key = "boundary", .value = "administrative" },
            .{ .key = "admin_level", .value = "2" },
            .{ .key = "name", .value = "Japan" },
            .{ .key = "ISO3166-1:alpha2", .value = "JP" },
        },
    }});
}

// Ported from test/gurka/test_ramps_tc.cc (Valhalla 3.9.3).
pub const LinkCase = enum { refs, destination_refs, branches, merge, slip_lane, inferred_channels, tagged_channels };

pub fn links(arena: Allocator, scenario: LinkCase) !gurka.Map {
    const motorway: gurka.Tags = &.{.{ .key = "highway", .value = "motorway" }};
    const trunk: gurka.Tags = &.{.{ .key = "highway", .value = "trunk" }};
    const primary: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    const secondary: gurka.Tags = &.{.{ .key = "highway", .value = "secondary" }};
    const tertiary: gurka.Tags = &.{.{ .key = "highway", .value = "tertiary" }};
    const one_way: gurka.Tag = .{ .key = "oneway", .value = "yes" };
    const primary_one_way: gurka.Tags = &.{ primary[0], one_way };
    const primary_link: gurka.Tag = .{ .key = "highway", .value = "primary_link" };
    const motorway_link: gurka.Tag = .{ .key = "highway", .value = "motorway_link" };
    const link: gurka.Tags = &.{ motorway_link, one_way };
    const ascii = switch (scenario) {
        .refs, .destination_refs =>
        \\A------------B-------------C-----------D
        \\              \     G     /
        \\               \    |    K----------L
        \\   I------------J   |   /
        \\                 \  |  /
        \\                  \ | /
        \\                   \|/
        \\                    F
        \\                    |
        \\                    |
        \\                    E
        ,
        .branches =>
        \\A--------B-------------------------------------C
        \\          \                             D
        \\           \                            |
        \\            G-------------H-------------E
        \\            |             |             |
        \\        I---J---K         |             F
        \\                      L---M---N
        ,
        .merge =>
        \\                      A------B-----C
        \\                             |         D
        \\G                M           |         |
        \\|               / \          J---------E
        \\|              /   \        /          |
        \\H-----N-------L-----K-------           F
        \\|     |
        \\|   O-P-R
        \\I
        ,
        .slip_lane =>
        \\              Z
        \\              |
        \\K__M_____W____C____D___E____N
        \\    \         |        /
        \\      \__Y    |      ^
        \\          \   B     /
        \\          |   |   F
        \\          |   | /
        \\           \  A
        \\            \ |
        \\              X
        ,
        .inferred_channels =>
        \\A---B-------------------------------C------D
        \\     \                             /
        \\      \            F J            /
        \\       \           | |           /
        \\        \          | |          /
        \\         \         | |         /
        \\          \        | |        /
        \\           --E-----G-K-----N--
        \\              \    | |    /
        \\               \   | |   /
        \\                \  | |  /
        \\                 \ | | /
        \\                   H L
        \\                   | |
        \\                   | |
        \\                   | |
        \\                   I M
        ,
        .tagged_channels =>
        \\      E D
        \\      | |
        \\      Q P
        \\     /| |\
        \\    / | | \
        \\L--R--F-C--O--K
        \\      | |
        \\I-----G-B--N--J
        \\      | | /
        \\      | |/
        \\      | M
        \\      | |
        \\      H A
        ,
    };
    const start: @import("routing").geo.PointLL = if (scenario == .branches) .{ .lng = -0.001, .lat = 0.001 } else .{ .lng = 0, .lat = 0 };
    const layout = try gurka.mapToCoordinatesAt(ascii, switch (scenario) {
        .slip_lane, .tagged_channels => 100,
        else => 10,
    }, start);
    const ways: []const gurka.Way = switch (scenario) {
        .refs => &.{
            .{ .label = "ABCD", .tags = &.{ motorway[0], .{ .key = "ref", .value = "M1" } } },
            .{ .label = "EFG", .tags = &.{ trunk[0], .{ .key = "ref", .value = "M2" } } },
            .{ .label = "BJF", .tags = &.{ motorway_link, one_way, .{ .key = "ref", .value = "M2" } } },
            .{ .label = "IJ", .tags = tertiary },
            .{ .label = "FKC", .tags = &.{ motorway_link, one_way, .{ .key = "ref", .value = "M2" } } },
            .{ .label = "KL", .tags = tertiary },
        },
        .destination_refs => &.{
            .{ .label = "ABCD", .tags = &.{ motorway[0], .{ .key = "ref", .value = "M1" } } },
            .{ .label = "EFG", .tags = &.{ trunk[0], .{ .key = "ref", .value = "M2" } } },
            .{ .label = "BJF", .tags = &.{ motorway_link, one_way, .{ .key = "destination:ref", .value = "M2" } } },
            .{ .label = "IJ", .tags = tertiary },
            .{ .label = "FKC", .tags = &.{ motorway_link, one_way, .{ .key = "destination:ref", .value = "M1" } } },
            .{ .label = "KL", .tags = tertiary },
        },
        .branches => &.{
            .{ .label = "ABC", .tags = motorway },
            .{ .label = "DEF", .tags = trunk },
            .{ .label = "BGHE", .tags = link },
            .{ .label = "GJ", .tags = link },
            .{ .label = "HM", .tags = link },
            .{ .label = "IJK", .tags = secondary },
            .{ .label = "LMN", .tags = tertiary },
        },
        .merge => &.{
            .{ .label = "GHI", .tags = motorway },
            .{ .label = "ABC", .tags = primary },
            .{ .label = "DEF", .tags = secondary },
            .{ .label = "OPR", .tags = tertiary },
            .{ .label = "BJ", .tags = link },
            .{ .label = "EJ", .tags = link },
            .{ .label = "JK", .tags = link },
            .{ .label = "KL", .tags = link },
            .{ .label = "KM", .tags = link },
            .{ .label = "ML", .tags = link },
            .{ .label = "LN", .tags = link },
            .{ .label = "NH", .tags = link },
            .{ .label = "NP", .tags = link },
        },
        .slip_lane => &.{
            .{ .label = "XABCZ", .tags = &.{ primary[0], .{ .key = "name", .value = "M1" } } },
            .{ .label = "KMWCDEN", .tags = &.{ primary[0], .{ .key = "name", .value = "M2" } } },
            .{ .label = "AFE", .tags = &.{ primary_link, one_way } },
            .{ .label = "XYM", .tags = &.{ primary_link, one_way } },
        },
        .inferred_channels => &.{
            .{ .label = "AB", .tags = &.{ motorway[0], one_way } },
            .{ .label = "BC", .tags = &.{ motorway[0], one_way } },
            .{ .label = "CD", .tags = &.{ motorway[0], one_way } },
            .{ .label = "BE", .tags = link },
            .{ .label = "EG", .tags = link },
            .{ .label = "EH", .tags = link },
            .{ .label = "GK", .tags = link },
            .{ .label = "FG", .tags = primary_one_way },
            .{ .label = "GH", .tags = primary_one_way },
            .{ .label = "HI", .tags = primary_one_way },
            .{ .label = "ML", .tags = primary_one_way },
            .{ .label = "LK", .tags = primary_one_way },
            .{ .label = "KJ", .tags = primary_one_way },
            .{ .label = "KN", .tags = link },
            .{ .label = "LN", .tags = link },
            .{ .label = "NC", .tags = link },
        },
        .tagged_channels => &.{
            .{ .label = "AM", .tags = primary_one_way },
            .{ .label = "MB", .tags = primary_one_way },
            .{ .label = "MN", .tags = &.{ primary_link, one_way, .{ .key = "turn_channel", .value = "true" } } },
            .{ .label = "OP", .tags = &.{ primary[0], one_way, .{ .key = "turn_channel", .value = "true" } } },
            .{ .label = "QR", .tags = &.{ primary_link, one_way, .{ .key = "turn_channel", .value = "false" } } },
            .{ .label = "EQ", .tags = primary_one_way },
            .{ .label = "QF", .tags = primary_one_way },
            .{ .label = "BC", .tags = primary_one_way },
            .{ .label = "CP", .tags = primary_one_way },
            .{ .label = "PD", .tags = primary_one_way },
            .{ .label = "FG", .tags = primary_one_way },
            .{ .label = "GH", .tags = primary_one_way },
            .{ .label = "IG", .tags = primary_one_way },
            .{ .label = "GB", .tags = primary_one_way },
            .{ .label = "BN", .tags = primary_one_way },
            .{ .label = "NJ", .tags = primary_one_way },
            .{ .label = "KO", .tags = primary_one_way },
            .{ .label = "OC", .tags = primary_one_way },
            .{ .label = "CF", .tags = primary_one_way },
            .{ .label = "FR", .tags = primary_one_way },
            .{ .label = "RL", .tags = primary_one_way },
        },
    };
    return gurka.Map.init(arena, layout, ways, if (scenario == .inferred_channels) &.{.{ .label = "B", .tags = &.{
        .{ .key = "highway", .value = "motorway_junction" },
        .{ .key = "ref", .value = "4" },
    } }} else &.{}, &.{});
}

pub fn turnNames(arena: Allocator, us: bool) !gurka.Map {
    const residential: gurka.Tag = .{ .key = "highway", .value = "residential" };
    const layout = try gurka.mapToCoordinatesAt(
        \\P---------------------Q
        \\
        \\    A-------B-----C
        \\            |
        \\            D
        \\
        \\S---------------------R
    , 30, .{ .lng = -76.6, .lat = 40.4 });
    const boundary = [_]gurka.Tag{
        .{ .key = "type", .value = "boundary" },
        .{ .key = "boundary", .value = "administrative" },
        .{ .key = "admin_level", .value = "2" },
    };
    return gurka.Map.init(arena, layout, &.{
        .{ .label = "AB", .tags = &.{ residential, .{ .key = "name", .value = "North Main Street" } } },
        .{ .label = "BC", .tags = &.{ residential, .{ .key = "name", .value = "Main Street South" } } },
        .{ .label = "BD", .tags = &.{ residential, .{ .key = "name", .value = "Market Street" } } },
        .{ .label = "PQRSP" },
    }, &.{}, &.{.{
        .members = &.{.{ .kind = .way, .ref = "PQRSP", .role = "outer" }},
        .tags = if (us) &(boundary ++ [_]gurka.Tag{
            .{ .key = "name", .value = "United States" },
            .{ .key = "ISO3166-1:alpha2", .value = "US" },
        }) else &(boundary ++ [_]gurka.Tag{
            .{ .key = "name", .value = "Canada" },
            .{ .key = "ISO3166-1:alpha2", .value = "CA" },
        }),
    }});
}

pub fn drivingSide(arena: Allocator) !gurka.Map {
    const layout = try gurka.mapToCoordinates("A----B----C", 30);
    return gurka.Map.init(arena, layout, &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "driving_side", .value = "left" },
            .{ .key = "shoulder:right", .value = "yes" },
            .{ .key = "cycleway:left", .value = "track" },
            .{ .key = "cycleway:right", .value = "lane" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "tertiary" },
            .{ .key = "driving_side", .value = "right" },
        } },
    }, &.{}, &.{});
}
