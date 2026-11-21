const std = @import("std");
const routing = @import("routing");
const gurka = @import("gurka.zig");
const io = routing.infra.io;
const geocode = routing.geocode;

fn node(id: i64, longitude: f64, latitude: f64, tags: gurka.Tags) gurka.OsmNode {
    return .{ .id = id, .label = "", .location = .init(longitude, latitude), .tags = tags };
}

fn way(id: i64, refs: []const i64, tags: gurka.Tags) gurka.OsmWay {
    return .{ .id = id, .label = "", .refs = refs, .tags = tags };
}

test "geocode bundle keeps multilingual labels and merges streets by municipality" {
    const testing = std.testing;
    const a = testing.allocator;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const source = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/source.osm.pbf", .{temp.sub_path});
    defer a.free(source);
    const admin_source = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/admins.osm.pbf", .{temp.sub_path});
    defer a.free(admin_source);
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/geocode", .{temp.sub_path});
    defer a.free(output);
    const primary: gurka.Tag = .{ .key = "name", .value = "Main Street" };
    const highway: gurka.Tag = .{ .key = "highway", .value = "residential" };
    const boundary: gurka.Tag = .{ .key = "boundary", .value = "administrative" };
    const dataset: gurka.Dataset = .{
        .nodes = &.{
            node(1, -1, -1, &.{}), node(2, 8, -1, &.{}), node(3, 8, 5, &.{}),                                        node(4, -1, 5, &.{}),
            node(5, 0, 0, &.{}),   node(6, 3, 0, &.{}),  node(7, 3, 4, &.{}),                                        node(8, 0, 4, &.{}),
            node(9, 7, 0, &.{}),   node(10, 7, 4, &.{}),
            node(11, 1, 1, &.{
                .{ .key = "place", .value = "town" },
                .{ .key = "name", .value = "West" },
                .{ .key = "name:fr", .value = "Ouest" },
                .{ .key = "population", .value = "1023" },
            }),
            node(12, 2, 1, &.{
                .{ .key = "addr:housenumber", .value = "10a" },
                .{ .key = "addr:street", .value = "Main Street" },
                .{ .key = "addr:postcode", .value = "1234" },
            }),
            node(13, 2, 2, &.{}),  node(14, 4, 1, &.{}), node(15, 5, 1, &.{}),                                       node(16, 1, 2, &.{}),
            node(17, 1, 3, &.{}),  node(18, 2, 3, &.{}), node(19, 9, 2, &.{.{ .key = "place", .value = "hamlet" }}),
        },
        .ways = &.{
            way(101, &.{ 1, 2, 3, 4, 1 }, &.{}),
            way(102, &.{ 5, 6, 7, 8, 5 }, &.{}),
            way(103, &.{ 6, 9, 10, 7, 6 }, &.{}),
            way(104, &.{ 11, 12 }, &.{ primary, highway }),
            way(105, &.{ 12, 13 }, &.{ primary, highway, .{ .key = "name:fr", .value = "Rue Principale" } }),
            way(106, &.{ 14, 15 }, &.{ primary, highway }),
            way(107, &.{ 16, 13, 18, 17, 16 }, &.{}),
        },
        .relations = &.{
            .{
                .id = 201,
                .members = &.{.{ .kind = .way, .id = 101, .role = "outer" }},
                .tags = &.{ boundary, .{ .key = "admin_level", .value = "2" }, .{ .key = "name", .value = "Land" } },
            },
            .{
                .id = 202,
                .members = &.{.{ .kind = .way, .id = 102, .role = "outer" }},
                .tags = &.{ boundary, .{ .key = "admin_level", .value = "8" }, .{ .key = "name", .value = "West" }, .{ .key = "name:fr", .value = "Ouest" } },
            },
            .{
                .id = 203,
                .members = &.{.{ .kind = .way, .id = 103, .role = "outer" }},
                .tags = &.{ boundary, .{ .key = "admin_level", .value = "8" }, .{ .key = "name", .value = "East" } },
            },
            .{
                .id = 204,
                .members = &.{
                    .{ .kind = .way, .id = 107, .role = "outer" },
                    .{ .kind = .relation, .id = 205, .role = "" },
                },
                .tags = &.{},
            },
            .{
                .id = 205,
                .members = &.{.{ .kind = .relation, .id = 204, .role = "" }},
                .tags = &.{
                    .{ .key = "type", .value = "multipolygon" },
                    .{ .key = "amenity", .value = "school" },
                    .{ .key = "name", .value = "Primary School" },
                    .{ .key = "addr:housename", .value = "The Schoolhouse" },
                },
            },
        },
    };
    const primary_extract: gurka.Dataset = .{
        .nodes = dataset.nodes,
        .ways = dataset.ways,
        .relations = &.{ dataset.relations[0], dataset.relations[1], dataset.relations[3], dataset.relations[4] },
    };
    const admin_extract: gurka.Dataset = .{
        .nodes = dataset.nodes,
        .ways = dataset.ways[2..3],
        .relations = dataset.relations[2..3],
    };
    try primary_extract.writePbf(a, source);
    try admin_extract.writePbf(a, admin_source);
    const options: geocode.extract.Options = .{ .workers = 2, .admin_sources = &.{admin_source} };
    try testing.expectError(error.DeadlineExceeded, geocode.extract.build(a, source, output, options, .fromNow(0)));
    const report = try geocode.extract.build(a, source, output, options, .none);
    try testing.expectEqual(geocode.extract.Counts{ .places = 2, .street_ways = 3, .addresses = 2, .pois = 1 }, report.tagged);
    try testing.expectEqual(report.tagged, report.located);
    try testing.expectEqual(2, report.streets);
    try testing.expectEqual(6, report.country_and_city);
    try testing.expectEqualStrings(geocode.model.attribution, report.attribution);
    var opened = try geocode.bundle.Bundle.open(output, .none);
    defer opened.close();
    const data = opened.data;
    try testing.expectEqual(3, data.admins.len);
    try testing.expectEqual(201, (try data.admin(data.admins[1].parent)).?.osm_id);
    try testing.expectEqual(1023, data.places[0].population);
    try testing.expectEqual(.unknown, data.places[1].record.hierarchy.country);
    try testing.expectEqual(.unknown, data.places[1].record.hierarchy.city);
    const place_names = try data.places[0].record.names.get(data.names);
    try testing.expectEqualStrings("fr", try place_names[1].language.get(data.text));
    try testing.expectEqualStrings("Ouest", try place_names[1].text.get(data.text));
    try testing.expectEqualSlices(i64, &.{ 104, 105 }, try data.streets[0].ways.get(data.street_ways));
    try testing.expectEqualSlices(i64, &.{106}, try data.streets[1].ways.get(data.street_ways));
    const street_names = try data.streets[0].record.names.get(data.names);
    try testing.expectEqual(2, street_names.len);
    try testing.expectEqualStrings("Rue Principale", try street_names[1].text.get(data.text));
    try testing.expectEqualStrings("1234", try data.addresses[0].record.hierarchy.postcode.get(data.text));
    try testing.expectEqualStrings("The Schoolhouse", try data.addresses[1].house_name.get(data.text));
    try testing.expectEqualStrings("school", try data.pois[0].kind.get(data.text));

    const dir = try io.Directory.open(output);
    defer dir.close();
    _ = try geocode.index_build.build(a, output, 1, .none);
    var serial = try geocode.index.Index.open(dir, opened.uuid, .none);
    defer serial.close();
    const built = try geocode.index_build.build(a, output, 2, .none);
    try testing.expectEqual(2, built.workers);
    var parallel = try geocode.index.Index.open(dir, opened.uuid, .none);
    defer parallel.close();
    try testing.expectEqualSlices(u8, serial.mapping.bytes, parallel.mapping.bytes);
    var index_scratch: [64]u8 = undefined;
    var streets = try parallel.view.prefix(.street, "ma", &index_scratch, .none);
    const main = (try streets.next(.none)).?;
    try testing.expectEqualStrings("main", main.text);
    try testing.expectEqual(3, main.list.count);
    var posted = main.list.iterator();
    for ([_]geocode.index.Document{
        .{ .kind = .street, .row = 0 },
        .{ .kind = .street, .row = 1 },
        .{ .kind = .address, .row = 0 },
    }) |expected| {
        const id = (try posted.next()).?;
        try testing.expectEqual(expected, parallel.view.header.records.document(id).?);
    }
    var postal = try parallel.view.prefix(.postcode, "123", &index_scratch, .none);
    try testing.expectEqualStrings("1234", (try postal.next(.none)).?.text);
    var house_number = try parallel.view.prefix(.house_number, "10", &index_scratch, .none);
    try testing.expectEqualStrings("10a", (try house_number.next(.none)).?.text);

    const query = geocode.query;
    var engine = try query.Engine.open(a, output, .none);
    defer engine.close();
    var requests: std.heap.ArenaAllocator = .init(a);
    defer requests.deinit();
    const request_memory = requests.allocator();
    const street_filter: query.Filters = .{ .layers = .initOne(.street) };
    const no_bias = try engine.search(request_memory, .{ .text = .{ .free = "Main Street" }, .filters = street_filter }, .none);
    try testing.expectEqual(2, no_bias.len);
    try testing.expectEqual(104, no_bias[0].osm_id);
    try testing.expectEqual(1.0, no_bias[0].bounds.west);
    try testing.expectEqual(2.0, no_bias[0].bounds.east);
    try testing.expectEqual(2.0, no_bias[0].bounds.north);
    var near_east = street_filter;
    near_east.near = .init(4.5, 1);
    const biased = try engine.search(request_memory, .{ .text = .{ .free = "Main Street" }, .filters = near_east }, .none);
    try testing.expectEqual(106, biased[0].osm_id);
    var bounded = street_filter;
    bounded.bounds = .{ .west = 3, .south = 0, .east = 6, .north = 2 };
    const inside = try engine.search(request_memory, .{ .text = .{ .free = "Main Street" }, .filters = bounded }, .none);
    try testing.expectEqual(1, inside.len);
    try testing.expectEqual(106, inside[0].osm_id);
    const address = try engine.search(request_memory, .{ .text = .{ .structured = .{
        .house_number = "10A",
        .street = "Main Street",
        .postcode = "1234",
        .city = "West",
        .country = "Land",
    } } }, .none);
    try testing.expectEqual(1, address.len);
    try testing.expectEqual(12, address[0].osm_id);
    try testing.expectEqualStrings("10a Main Street, 1234 West, Land", address[0].formatted_address);
    const localized = try engine.search(request_memory, .{ .text = .{ .free = "West" }, .filters = .{ .language = "fr" } }, .none);
    try testing.expectEqualStrings("Ouest", localized[0].name);
    const fuzzy = try engine.search(request_memory, .{ .text = .{ .free = "Prmiary School" } }, .none);
    try testing.expectEqual(205, fuzzy[0].osm_id);
    const exact = try engine.search(request_memory, .{ .text = .{ .free = "Prmiary School" }, .typos = false }, .none);
    try testing.expectEqual(0, exact.len);
    const trailing_country = try engine.search(request_memory, .{ .text = .{ .free = "Main Street West Land" }, .filters = street_filter }, .none);
    try testing.expectEqual(1, trailing_country.len);
    try testing.expectEqual(104, trailing_country[0].osm_id);
    try testing.expectError(error.DeadlineExceeded, engine.search(request_memory, .{ .text = .{ .free = "West" } }, .fromNow(0)));

    var autocomplete = try geocode.autocomplete.Engine.open(a, output, .none);
    defer autocomplete.close();
    var counted = routing.infra.arena.CountingAllocator.init(a);
    var typing = routing.infra.arena.Arena.init(counted.allocator(), .{});
    defer typing.deinit();
    const pass: []const []const u8 = &.{ "M", "Ma", "Main St", "Main Stre" };
    for (0..2) |round| {
        counted.resetCounts();
        for (pass) |prefix| {
            typing.reset();
            const suggestions = try autocomplete.suggest(typing.allocator(), .{ .text = prefix, .filters = street_filter }, .none);
            try testing.expectEqual(2, suggestions.len);
            try testing.expectEqual(104, suggestions[0].osm_id);
            try testing.expectEqual(106, suggestions[1].osm_id);
        }
        if (round == 1) try testing.expectEqual(0, counted.calls());
    }
    const near_prefix = try autocomplete.suggest(request_memory, .{ .text = "Ma", .filters = near_east }, .none);
    try testing.expectEqual(106, near_prefix[0].osm_id);
    const unfinished_first = try autocomplete.suggest(request_memory, .{ .text = "Mai Street", .filters = street_filter }, .none);
    try testing.expectEqual(0, unfinished_first.len);
    const french_prefix = try autocomplete.suggest(request_memory, .{ .text = "Ou", .filters = .{ .language = "fr" } }, .none);
    try testing.expectEqualStrings("Ouest", french_prefix[0].name);
    try testing.expectError(error.DeadlineExceeded, autocomplete.suggest(request_memory, .{ .text = "Ma" }, .fromNow(0)));

    var reverse = try geocode.reverse.Engine.open(a, output, .none);
    defer reverse.close();
    const at_address = try reverse.lookup(request_memory, .{ .point = .init(2, 1), .limit = 3, .language = "fr" }, .none);
    try testing.expectEqual(12, at_address.results[0].osm_id);
    try testing.expectEqual(0, at_address.results[0].distance_m);
    try testing.expectEqual(.address, at_address.results[0].layer);
    try testing.expectEqualStrings("Ouest", at_address.hierarchy.city.?.name);
    try testing.expectEqual(201, at_address.results[0].hierarchy.country.?.osm_id);
    try testing.expectEqual(.street, at_address.results[1].layer);
    const along_street = try reverse.lookup(request_memory, .{ .point = .init(1.5, 1.0001), .radius_m = 12, .layer = .street }, .none);
    try testing.expectEqual(104, along_street.results[0].osm_id);
    try testing.expectEqual(1.0, along_street.results[0].coordinate.lat);
    try testing.expect(along_street.results[0].distance_m > 11 and along_street.results[0].distance_m < 12);
    const outside_radius = try reverse.lookup(request_memory, .{ .point = .init(1.5, 1.0001), .radius_m = 10, .layer = .street }, .none);
    try testing.expectEqual(0, outside_radius.results.len);
    const by_poi = try reverse.lookup(request_memory, .{ .point = data.pois[0].record.coordinate.toPoint(), .layer = .poi }, .none);
    try testing.expectEqual(205, by_poi.results[0].osm_id);
    const batch = try reverse.batch(request_memory, &.{
        .{ .point = .init(6, 3.5), .radius_m = 0 },
        .{ .point = .init(-140, 0) },
        .{ .point = .init(1.5, 3.5), .layer = .country },
    }, .none);
    try testing.expectEqual(203, batch[0].results[0].osm_id);
    try testing.expectEqual(.city, batch[0].results[0].layer);
    try testing.expectEqual(null, batch[1].hierarchy.country);
    try testing.expectEqual(0, batch[1].results.len);
    try testing.expectEqual(201, batch[2].results[0].osm_id);
    try testing.expectError(error.InvalidCoordinate, reverse.lookup(request_memory, .{ .point = .init(0, 99) }, .none));
    try testing.expectError(error.DeadlineExceeded, reverse.lookup(request_memory, .{ .point = .init(2, 1) }, .fromNow(0)));
}

fn addressTags(allocator: std.mem.Allocator, number: []const u8) !gurka.Tags {
    return allocator.dupe(gurka.Tag, &.{
        .{ .key = "addr:housenumber", .value = number },
        .{ .key = "addr:street", .value = "Curve Road" },
        .{ .key = "addr:postcode", .value = "L-1234" },
    });
}

test "extract postcode areas and linked interpolation ranges from a PBF" {
    const testing = std.testing;
    const a = testing.allocator;
    var owned = std.heap.ArenaAllocator.init(a);
    defer owned.deinit();
    const arena = owned.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const source = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/address.osm.pbf", .{temporary.sub_path});
    const output = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/geocode", .{temporary.sub_path});
    var nodes: std.ArrayList(gurka.OsmNode) = .empty;
    try nodes.appendSlice(arena, &.{
        node(1, 0, 0, &.{}),       node(2, 4, 0, &.{}),       node(3, 4, 4, &.{}),       node(4, 0, 4, &.{}),
        node(5, 1.01, 1.01, &.{}), node(6, 1.02, 1.01, &.{}), node(7, 1.02, 1.02, &.{}), node(8, 1.01, 1.02, &.{}),
    });
    var ways: std.ArrayList(gurka.OsmWay) = .empty;
    try ways.appendSlice(arena, &.{
        way(101, &.{ 1, 2, 3, 4, 1 }, &.{}),
        way(102, &.{ 5, 6, 7, 8, 5 }, &.{}),
    });
    const samples = [_]struct { scheme: []const u8, low: []const u8, high: []const u8, requested: []const u8 }{
        .{ .scheme = "all", .low = "1", .high = "5", .requested = "4" },
        .{ .scheme = "even", .low = "2", .high = "10", .requested = "8" },
        .{ .scheme = "odd", .low = "17", .high = "9", .requested = "11" },
        .{ .scheme = "alphabetic", .low = "25", .high = "25D", .requested = "25C" },
    };
    for (samples, 0..) |sample, i| {
        const start: i64 = @intCast(20 + i * 3);
        const refs = try arena.dupe(i64, &.{ start, start + 1, start + 2 });
        const tags = try arena.dupe(gurka.Tag, &.{.{ .key = "addr:interpolation", .value = sample.scheme }});
        try nodes.appendSlice(arena, &.{
            node(start, 1, 1, try addressTags(arena, sample.low)),
            node(start + 1, 1.001, 1, if (i == 0) try addressTags(arena, "3") else &.{}),
            node(start + 2, 1.001, 1.001, try addressTags(arena, sample.high)),
        });
        try ways.append(arena, way(@intCast(110 + i), refs, tags));
    }
    try ways.append(arena, way(120, &.{ 20, 21, 22 }, &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "name", .value = "Curve Road" },
    }));
    const dataset: gurka.Dataset = .{
        .nodes = nodes.items,
        .ways = ways.items,
        .relations = &.{
            .{
                .id = 201,
                .members = &.{.{ .kind = .way, .id = 101, .role = "outer" }},
                .tags = &.{
                    .{ .key = "boundary", .value = "administrative" },
                    .{ .key = "admin_level", .value = "2" },
                    .{ .key = "ISO3166-1:alpha2", .value = "lu" },
                    .{ .key = "name", .value = "Land" },
                },
            },
            .{
                .id = 202,
                .members = &.{.{ .kind = .way, .id = 102, .role = "outer" }},
                .tags = &.{
                    .{ .key = "boundary", .value = "postal_code" },
                    .{ .key = "postal_code", .value = "2345" },
                },
            },
        },
    };
    try dataset.writePbf(a, source);
    const report = try geocode.extract.build(a, source, output, .{ .workers = 2 }, .none);
    try testing.expectEqual(5, report.interpolations);
    try testing.expectEqual(14, report.house_links);
    try testing.expectEqual(2, report.postcodes);
    var opened = try geocode.bundle.Bundle.open(output, .none);
    defer opened.close();
    const data = opened.data;
    const country: geocode.model.AdminId = @fromBackingInt(@intCast(1));
    try testing.expectEqualStrings("LU", try data.countryIso(country));
    const from_addresses = (try data.lookupPostcode(country, "L-1234")).?;
    try testing.expectEqual(9, from_addresses.address_count);
    try testing.expectEqual(routing.geo.PointLL.init(1.0005556, 1.0004444).toFixed(), from_addresses.center);
    try testing.expect(!from_addresses.attr.from_boundary);
    const from_area = (try data.lookupPostcode(country, "2345")).?;
    try testing.expectEqual(0, from_area.address_count);
    try testing.expectEqual(routing.geo.PointLL.init(1.015, 1.015).toFixed(), from_area.center);
    try testing.expectEqual(routing.geo.PointLL.init(1.01, 1.01).toFixed(), from_area.min);
    try testing.expectEqual(routing.geo.PointLL.init(1.02, 1.02).toFixed(), from_area.max);
    try testing.expect(from_area.attr.from_boundary);
    const extensions = data.address_data.?;
    try testing.expectEqual(14, extensions.street_houses[0].len);
    const expected = routing.geo.PointLL.init(1.001, 1.0005);
    for (samples) |sample| {
        const scheme = geocode.interpolation.Mode.fromTag(sample.scheme).?;
        var matches: usize = 0;
        for (extensions.interpolations, 0..) |row, i| {
            if (row.attr.mode != scheme) continue;
            const number = try geocode.house_number.parse(sample.requested, "");
            const estimate = try data.estimateInterpolation(@intCast(i), number, .none) orelse continue;
            try testing.expect(estimate.approximate);
            try testing.expect(estimate.coordinate.toPoint().distance(expected) < 10);
            matches += 1;
        }
        try testing.expectEqual(1, matches);
    }
    var reverse = try geocode.reverse.Engine.open(a, output, .none);
    defer reverse.close();
    const nearby = try reverse.lookup(arena, .{ .point = expected, .radius_m = 30, .layer = .address, .limit = 10 }, .none);
    try testing.expectEqual(4, nearby.results.len);
    for (nearby.results, 0..) |result, i| {
        try testing.expect(result.approximate);
        try testing.expect(result.distance_m < 10);
        try testing.expect(result.osm_id >= 110 and result.osm_id <= 113);
        try testing.expect(std.mem.indexOf(u8, result.address, "Curve Road") != null);
        if (i != 0) try testing.expect(nearby.results[i - 1].distance_m <= result.distance_m);
    }
    const folder = try io.Directory.open(output);
    defer folder.close();
    try folder.deleteFile(geocode.model.Section.admin_rings.filename());
    try testing.expectError(error.IncompleteGeocodeAdminGeometry, geocode.bundle.Bundle.open(output, .none));
    try folder.deleteFile(geocode.model.Section.postcodes.filename());
    try testing.expectError(error.IncompleteGeocodeAddressIndex, geocode.bundle.Bundle.open(output, .none));
}
