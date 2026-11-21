// Ported from test/gurka/test_loops.cc (Valhalla 3.9.3), with native CSR and split tests.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const build = routing.build;
const graph = routing.graph;
const format = graph.format;
const gurka = @import("gurka.zig");
const pbf = @import("pbf.zig");
const testing = std.testing;

const Built = struct {
    parent: io.Directory,
    root: io.Directory,
    name: io.Directory.TempName,
    bundle: graph.reader.Bundle,
    stats: build.assemble.Stats,

    fn assemble(dataset: gurka.Dataset, workers: usize) !Built {
        return assembleWithOptions(dataset, .{ .scratch_dir = "", .workers = workers });
    }

    fn assembleWithOptions(dataset: gurka.Dataset, options: build.assemble.Options) !Built {
        const parent = try io.Directory.open(".");
        errdefer parent.close();
        const root = try parent.temporaryChild();
        errdefer {
            root.dir.close();
            parent.deleteDir(&root.name) catch {};
        }
        var path: [80]u8 = undefined;
        const output = try std.fmt.bufPrint(&path, "{s}/bundle", .{root.name});
        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();
        const file = try io.File.temporary(&root.name);
        defer file.close();
        try file.pwriteAll(try pbf.encode(scratch.allocator(), dataset), 0);
        var writer = try format.BundleWriter.init(output, @splat(42), .none);
        defer writer.deinit();
        var input = options;
        input.scratch_dir = &root.name;
        const stats = try build.assemble.build(testing.allocator, try build.pbf.file.Stream.init(file), &writer, input);
        try writer.commit();
        errdefer deleteBundle(root.dir);
        const bundle = try graph.reader.Bundle.open(output);
        return .{ .parent = parent, .root = root.dir, .name = root.name, .bundle = bundle, .stats = stats };
    }

    fn deinit(self: *Built) void {
        self.bundle.close();
        deleteBundle(self.root);
        self.root.close();
        self.parent.deleteDir(&self.name) catch {};
        self.parent.close();
    }
};

fn deleteBundle(root: io.Directory) void {
    const dir = root.child("bundle") catch return;
    for (std.enums.values(format.SectionKind)) |kind| dir.deleteFile(kind.filename()) catch {};
    dir.close();
    root.deleteDir("bundle") catch {};
}

fn at(view: *const graph.reader.View, point: format.Coordinate) !format.NodeId {
    for (view.coordinates.?, 0..) |candidate, i| {
        if (std.meta.eql(candidate, point)) return @fromBackingInt(@as(u32, @intCast(i)));
    }
    return error.MissingTestNode;
}

fn checkOpposites(view: *const graph.reader.View, directed_edges: usize) !void {
    try testing.expectEqual(directed_edges, view.edges.len);
    try view.verify(.none, null);
    try build.assemble.validate(view.first_edge, view.edges, view.coordinates.?, view.classes.?, .none);
    for (0..view.edges.len) |i| {
        const id: format.EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
        try testing.expectEqual(id, try view.oppEdge(try view.oppEdge(id)));
    }
}

test "explicit internal-intersection tags survive builds with inference disabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B", 20), &.{
        .{ .label = "AB", .tags = &.{ .{ .key = "highway", .value = "primary" }, .{ .key = "internal_intersection", .value = "true" } } },
    }, &.{}, &.{});
    for ([_]bool{ false, true }) |infer| {
        var built = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .workers = 1, .infer_internal_intersections = infer });
        defer built.deinit();
        const view = &built.bundle.view;
        const edge = try view.edge(try directedBetween(view, &fixture, "A", "B"));
        try testing.expectEqual(!infer, (try view.class(edge.cls.class_id)).flags.internal);
    }
}

test "valhalla loop fixtures retain edge counts and opposing involution" {
    const motorway: gurka.Tags = &.{.{ .key = "highway", .value = "motorway" }};
    const cases = [_]struct { map: []const u8, way: []const u8, directed: usize }{
        .{ .map = "A-----B", .way = "ABA", .directed = 2 },
        .{ .map = "A--B--C--D--E", .way = "ABCDEDCBA", .directed = 8 },
        .{ .map = "  C----D\nA-B    |\n  F----E", .way = "ABCDEFBA", .directed = 6 },
        .{ .map = "F--E\n    \\\n     C---D\n    /\nA--B", .way = "ABCDCEF", .directed = 6 },
        .{ .map = "K--J         I----H\n     C--D--E       |\nA--B         F----G", .way = "ABCDEFGHIEDCJK", .directed = 12 },
        .{ .map = "        J----I\nA--B--C        F--G--H\n        D----E", .way = "ABCDEFGHGFIJC", .directed = 10 },
        .{ .map = "        H----G\nA--B--C--------D--E--F", .way = "ABCDEFEDGHC", .directed = 10 },
        .{ .map = "        C----D\nA-----B--------E\n        G----F", .way = "ABCDEFGBE", .directed = 10 },
        .{ .map = "  B   F\nA   C   E\n  G   D", .way = "ABCDEFCGA", .directed = 8 },
        .{ .map = "        F----G\nE--D--C---B----A\n     I-------H", .way = "ABCDEDCFGAHID", .directed = 12 },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const fixture = try gurka.Map.init(arena.allocator(), try gurka.mapToCoordinates(case.map, 10), &.{
            .{ .label = case.way, .tags = motorway },
        }, &.{}, &.{});
        var result = try Built.assemble(fixture.osm, 1);
        defer result.deinit();
        try checkOpposites(&result.bundle.view, case.directed);
    }
}

test "stable road keys distinguish repeated endpoints by source segment order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("    C   D   E\nA---------------B---F", 20), &.{
        .{ .label = "ACBDAEBF", .tags = &.{.{ .key = "highway", .value = "residential" }} },
    }, &.{}, &.{});
    var result = try Built.assemble(fixture.osm, 2);
    defer result.deinit();
    const view = &result.bundle.view;
    const keys = view.edge_key_index.?;
    const refs = fixture.osm.ways[0].refs;
    const way_id = fixture.osm.ways[0].id;
    for (0..2) |occurrence| {
        const key: graph.edge_keys.Key = .{
            .way_id = way_id,
            .begin_node = refs[0],
            .end_node = refs[2],
            .flags = .{ .occurrence = @intCast(occurrence) },
        };
        const edge = (try keys.find(key)) orelse return error.MissingRepeatedEdge;
        const path = try view.shape(edge, a);
        const intermediate = fixture.findNode(if (occurrence == 0) "C" else "E").?.location.toFixed();
        try testing.expectEqualDeep(intermediate, path[1]);
        const reverse = try keys.key(try view.oppEdge(edge));
        try testing.expectEqualDeep(graph.edge_keys.Key{
            .way_id = way_id,
            .begin_node = key.end_node,
            .end_node = key.begin_node,
            .flags = .{ .reversed = true, .occurrence = @intCast(occurrence) },
        }, reverse);
    }
}

test "assemble directs speed and access and preserves node attributes and coordinates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(arena.allocator(), try gurka.mapToCoordinates("A---B---C\n    |\n    D", 20), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "residential" },
            .{ .key = "maxspeed:forward", .value = "45" },
            .{ .key = "maxspeed:backward", .value = "25" },
            .{ .key = "maxspeed:hgv", .value = "20" },
            .{ .key = "oneway", .value = "yes" },
        } },
        .{ .label = "BC", .tags = road },
        .{ .label = "BD", .tags = road },
    }, &.{.{ .label = "B", .tags = &.{
        .{ .key = "barrier", .value = "gate" },
        .{ .key = "highway", .value = "traffic_signals" },
        .{ .key = "bicycle", .value = "no" },
    } }}, &.{});
    var result = try Built.assemble(fixture.osm, 4);
    defer result.deinit();
    const view = &result.bundle.view;
    try checkOpposites(view, 6);
    const a = try at(view, fixture.findNode("A").?.location.toFixed());
    const b = try at(view, fixture.findNode("B").?.location.toFixed());
    try testing.expectEqual(4, view.nodes.len);
    try testing.expectEqual(3, (try view.outEdges(b)).len);
    const attrs = (try view.node(b)).attr;
    try testing.expectEqual(@backingInt(graph.constants.NodeType.gate), attrs.type);
    try testing.expectEqual(1, attrs.signal);
    try testing.expect(!(@as(graph.constants.AccessMask, @bitCast(attrs.access))).bicycle);
    try testing.expectEqual(fixture.findNode("B").?.location.toFixed(), try view.coordinate(b));

    const edge_id: format.EdgeId = @fromBackingInt((try view.outEdgeRange(a)).first);
    const edge = try view.edge(edge_id);
    const reverse = try view.edge(try view.oppEdge(edge_id));
    try testing.expectEqual(@backingInt(b), edge.head);
    try testing.expectEqual(@backingInt(a), reverse.head);
    try testing.expectEqualSlices(u8, &.{ 45, 0, 0, 20 }, &edge.speed);
    try testing.expectEqualSlices(u8, &.{ 25, 0, 0, 20 }, &reverse.speed);
    try testing.expect((try view.class(edge.cls.class_id)).forwardAccess().auto);
    try testing.expect(!(try view.class(reverse.cls.class_id)).forwardAccess().auto);
}

test "duration sets a ferry's speed across all segments of its OSM way" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try gurka.Map.init(arena.allocator(), try gurka.mapToCoordinates("A---B---C\n    |\n    D", 250), &.{
        .{ .label = "ABC", .tags = &.{ .{ .key = "route", .value = "ferry" }, .{ .key = "duration", .value = "00:03:07" } } },
        .{ .label = "BD", .tags = &.{.{ .key = "highway", .value = "residential" }} },
    }, &.{}, &.{});
    var result = try Built.assemble(fixture.osm, 4);
    defer result.deinit();
    const view = &result.bundle.view;
    try checkOpposites(view, 6);
    const a = fixture.findNode("A").?.location.toFixed().toPoint();
    const b = fixture.findNode("B").?.location.toFixed().toPoint();
    const c = fixture.findNode("C").?.location.toFixed().toPoint();
    const expected: u8 = @intFromFloat((a.distance(b) + b.distance(c)) * 3.6 / 187);
    try testing.expect(expected > 20);
    var ferry_edges: usize = 0;
    for (view.edges) |edge| {
        const class = try view.class(edge.cls.class_id);
        if (class.category.use != @backingInt(graph.constants.Use.ferry)) continue;
        try testing.expectEqual(expected, edge.speed[0]);
        try testing.expect(!class.flags.tagged_speed);
        ferry_edges += 1;
    }
    try testing.expectEqual(4, ferry_edges);
}

// Ported from test/gurka/test_config_speed.cc (DefaultSpeedConfig and AdminFallback).
test "configured link speeds use directed signs and the destination admin" {
    const table =
        \\{"way":[26,26,26,26,26,26,26,26],"link_exiting":[77,76,75,74,73],"link_turning":[51,50,49,48,47],
        \\"roundabout":[20,20,20,20,20,20,20,20],"driveway":10,"alley":11,"parking_aisle":12,"drive-through":13}
    ;
    const config = "[{\"iso3166-1\":\"JP\",\"rural\":" ++ table ++
        ",\"suburban\":" ++ table ++ ",\"urban\":" ++ table ++ "}]";
    var rules = try build.speeds.Config.parse(testing.allocator, config, .none);
    defer rules.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").signs(arena.allocator());
    var result = try Built.assembleWithOptions(fixture.osm, .{
        .scratch_dir = "",
        .workers = 4,
        .speed_rules = &rules,
        .reclassify_links = false,
    });
    defer result.deinit();
    const view = &result.bundle.view;
    const ramp = try directedBetween(view, &fixture, "B", "J");
    try testing.expectEqual(95, (try view.coldRecord(ramp)).speedLimit());
    const cases = [_]struct { from: []const u8, to: []const u8, speed: u8, signed: bool }{
        .{ .from = "B", .to = "J", .speed = 77, .signed = true },
        .{ .from = "J", .to = "B", .speed = 51, .signed = false },
        .{ .from = "C", .to = "E", .speed = 77, .signed = true },
        .{ .from = "G", .to = "H", .speed = 26, .signed = true },
        .{ .from = "A", .to = "B", .speed = 26, .signed = false },
    };
    for (cases) |case| {
        const id = try directedBetween(view, &fixture, case.from, case.to);
        const edge = try view.edge(id);
        try testing.expectEqual(case.signed, try graph.signs.hasSigns(view, id));
        try testing.expectEqual(case.speed, edge.speed[0]);
        try testing.expect(!(try view.class(edge.cls.class_id)).flags.tagged_speed);
        try testing.expectEqualStrings("JP", (try view.nodeAdmin(@fromBackingInt(edge.head))).country_iso);
    }
}

test "country and state speed rules follow the destination across the same way" {
    const table =
        \\{"way":[39,39,39,39,39,39,39,39],"link_exiting":[null,null,null,null,null],"link_turning":[null,null,null,null,null],
        \\"roundabout":[null,null,null,null,null,null,null,null],"driveway":null,"alley":null,"parking_aisle":null,"drive-through":null}
    ;
    const state =
        \\{"way":[63,63,63,63,63,63,63,63],"link_exiting":[null,null,null,null,null],"link_turning":[null,null,null,null,null],
        \\"roundabout":[null,null,null,null,null,null,null,null],"driveway":null,"alley":null,"parking_aisle":null,"drive-through":null}
    ;
    const country =
        \\{"way":[48,48,48,48,48,48,48,48],"link_exiting":[null,null,null,null,null],"link_turning":[null,null,null,null,null],
        \\"roundabout":[null,null,null,null,null,null,null,null],"driveway":null,"alley":null,"parking_aisle":null,"drive-through":null}
    ;
    const config = "[{\"rural\":" ++ table ++ ",\"suburban\":" ++ table ++ ",\"urban\":" ++ table ++
        "},{\"iso3166-1\":\"NL\",\"iso3166-2\":\"TST\",\"rural\":" ++ state ++
        ",\"suburban\":" ++ state ++ ",\"urban\":" ++ state ++
        "},{\"iso3166-1\":\"BE\",\"rural\":" ++ country ++ ",\"suburban\":" ++ country ++ ",\"urban\":" ++ country ++ "}]";
    var rules = try build.speeds.Config.parse(testing.allocator, config, .none);
    defer rules.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").countryAccess(arena.allocator());
    var built = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .speed_rules = &rules, .workers = 4 });
    defer built.deinit();
    const view = &built.bundle.view;
    const toward_country = try directedBetween(view, &fixture, "R", "S");
    const toward_state = try view.oppEdge(toward_country);
    try testing.expectEqual(48, (try view.edge(toward_country)).speed[0]);
    try testing.expectEqual(63, (try view.edge(toward_state)).speed[0]);
    const fallback = try directedBetween(view, &fixture, "W", "X");
    try testing.expectEqual(39, (try view.edge(fallback)).speed[0]);
}

test "assembled turn rows use opposing locals, shared names and class-based stops" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try gurka.Map.init(arena.allocator(), try gurka.mapToCoordinates("    D\n    |\nA---B---C\n    |\n    E", 20), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Main;Old Main" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Old Main" },
        } },
        .{ .label = "BD", .tags = &.{.{ .key = "highway", .value = "residential" }} },
        .{ .label = "BE", .tags = &.{.{ .key = "highway", .value = "residential" }} },
    }, &.{.{ .label = "B", .tags = &.{.{ .key = "highway", .value = "traffic_signals" }} }}, &.{});

    var result = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .workers = 4, .drive_side = .right });
    defer result.deinit();
    const view = &result.bundle.view;
    try checkOpposites(view, 8);
    const a = try at(view, fixture.findNode("A").?.location.toFixed());
    const b = try at(view, fixture.findNode("B").?.location.toFixed());
    const ab: format.EdgeId = @fromBackingInt((try view.outEdgeRange(a)).first);
    const row = try view.turnRow(b, (try view.edge(ab)).cls.opp_local);
    // Reverse (3, same name), straight (0, shared name), left (5), right (3).
    for ([_][]const u8{ "A", "C", "D", "E" }, [_]u8{ 0x5c, 0x40, 0x2e, 0x1a }) |label, expected| {
        const target = try at(view, fixture.findNode(label).?.location.toFixed());
        for (try view.outEdges(b)) |edge| {
            if (edge.head != @backingInt(target)) continue;
            try testing.expectEqual(expected, row[edge.cls.local]);
            break;
        } else return error.MissingTestEdge;
    }
    try testing.expectEqualSlices(u8, &.{0x44}, try view.turnRow(a, 0));
    const c = try at(view, fixture.findNode("C").?.location.toFixed());
    try testing.expectEqual((try view.node(a)).turn_off, (try view.node(c)).turn_off);
    const bd = try directedBetween(view, &fixture, "B", "D");
    const Turn = routing.costing.auto.Turn;
    const stored = try Turn.read(view, b, ab, bd, testing.allocator, .none);
    var old_bundle = view.*;
    old_bundle.headings = null;
    try testing.expectEqualDeep(stored, try Turn.read(&old_bundle, b, ab, bd, testing.allocator, .none));
}

test "cold records share names and round trip exact E7 shapes in either direction" {
    const points: [4]format.Coordinate = .{
        .{ .lng = 10000117, .lat = 10000220 },
        .{ .lng = 10000488, .lat = 10000673 },
        .{ .lng = 10000901, .lat = 10000234 },
        .{ .lng = 10001903, .lat = 10000613 },
    };
    var nodes: [points.len]gurka.OsmNode = undefined;
    for (points, &nodes, 1..) |point, *node, id| {
        node.* = .{ .id = @intCast(id), .label = "", .location = point.toPoint(), .tags = &.{} };
    }
    const way_id: i64 = 0x1_0123_4567;
    const ways: []const gurka.OsmWay = &.{
        .{ .id = way_id, .label = "ABC", .refs = &.{ 1, 2, 3 }, .tags = &.{
            .{ .key = "highway", .value = "secondary" },
            .{ .key = "name", .value = "Main;Old Main" },
            .{ .key = "ref", .value = "L 17" },
            .{ .key = "maxspeed", .value = "35" },
        } },
        .{ .id = way_id + 1, .label = "CD", .refs = &.{ 3, 4 }, .tags = &.{
            .{ .key = "highway", .value = "secondary" },
            .{ .key = "name", .value = "Main" },
        } },
    };
    var result = try Built.assemble(.{ .nodes = &nodes, .ways = ways, .relations = &.{} }, 4);
    defer result.deinit();
    const view = &result.bundle.view;
    try checkOpposites(view, 4);
    const a = try at(view, points[0]);
    const c = try at(view, points[2]);
    const d = try at(view, points[3]);
    const ac: format.EdgeId = @fromBackingInt((try view.outEdgeRange(a)).first);
    const ca = try view.oppEdge(ac);
    const dc: format.EdgeId = @fromBackingInt((try view.outEdgeRange(d)).first);
    try testing.expectEqual(@backingInt(c), (try view.edge(dc)).head);
    try testing.expectEqual(2, view.cold_data.?.header.record_count);
    try testing.expectEqual(3, view.cold_data.?.header.name_count);
    try testing.expect(!result.stats.elevation.dem_configured);
    try testing.expectEqual(2, result.stats.elevation.total_edges);
    try testing.expectEqual(6, (try view.edge(ac)).geom.grade);
    try testing.expectEqual(format.Slopes.flat, try view.edgeSlopes(ac));
    try testing.expectEqual(graph.cold.no_elevation, (try view.coldRecord(ac)).meanElevation());
    try testing.expectEqual(@as(u64, @intCast(way_id)), try view.wayId(ac));
    try testing.expectEqual(try view.wayId(ac), try view.wayId(ca));
    try testing.expectEqual(35, (try view.coldRecord(ca)).speedLimit());
    const names = try view.names(ac);
    try testing.expectEqual(3, names.count());
    try testing.expectEqualStrings("Main", (try names.at(0)).text);
    try testing.expectEqualStrings("Old Main", (try names.at(1)).text);
    const ref = try names.at(2);
    try testing.expectEqualStrings("L 17", ref.text);
    try testing.expect(ref.route);
    try testing.expectEqual((try names.at(0)).text.ptr, (try (try view.names(dc)).at(0)).text.ptr);
    const forward = try view.shape(ac, testing.allocator);
    defer testing.allocator.free(forward);
    const backward = try view.shape(ca, testing.allocator);
    defer testing.allocator.free(backward);
    try testing.expectEqualSlices(format.Coordinate, points[0..3], forward);
    try testing.expectEqualSlices(format.Coordinate, &.{ points[2], points[1], points[0] }, backward);
}

test "high-degree node aliases reserve both directions and preserve connectivity" {
    const leaves = 63;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = try a.alloc(gurka.OsmNode, leaves + 1);
    const ways = try a.alloc(gurka.OsmWay, leaves);
    nodes[0] = .{ .id = 1, .label = "", .location = .{ .lat = 0, .lng = 0 }, .tags = &.{} };
    for (ways, 0..) |*way, i| {
        const node = &nodes[i + 1];
        node.* = .{
            .id = @intCast(i + 2),
            .label = "",
            .location = .{ .lat = 0, .lng = @as(f64, @floatFromInt(i + 1)) * 0.001 },
            .tags = &.{},
        };
        way.* = .{
            .id = @intCast(i + 1),
            .label = "",
            .refs = try a.dupe(i64, &.{ 1, node.id }),
            .tags = &.{.{ .key = "highway", .value = "residential" }},
        };
    }
    var result = try Built.assemble(.{ .nodes = nodes, .ways = ways, .relations = &.{} }, 4);
    defer result.deinit();
    const view = &result.bundle.view;
    try checkOpposites(view, 2 * leaves + 4);
    const keys = view.edge_key_index.?;
    try testing.expectEqual(1, result.stats.split_nodes);
    try testing.expectEqual(2, result.stats.connectors);
    try testing.expectEqual(leaves + 3, view.nodes.len);
    try testing.expectEqual(leaves + 2, view.cold_data.?.header.record_count);
    var aliases: usize = 0;
    var real: usize = 0;
    var connectors: usize = 0;
    for (view.coordinates.?, 0..) |point, i| {
        if (point.lat != 0 or point.lng != 0) continue;
        aliases += 1;
        const id: format.NodeId = @fromBackingInt(@as(u32, @intCast(i)));
        const outgoing = try view.outEdges(id);
        try testing.expect(outgoing.len <= 32);
        for (outgoing) |edge| {
            const alias = (try view.class(edge.cls.class_id)).flags.node_connector;
            try testing.expectEqual(alias, edge.geom.len_m == 0);
            if (alias) {
                connectors += 1;
                const directed: format.EdgeId = @fromBackingInt((try view.outEdgeRange(id)).first + edge.cls.local);
                const key = try keys.key(directed);
                const opposite = try keys.key(try view.oppEdge(directed));
                try testing.expectEqual(.node_connector, key.flags.kind);
                try testing.expectEqual(1, key.begin_node);
                try testing.expectEqual(1, key.end_node);
                try testing.expectEqual(key.flags.occurrence, opposite.flags.occurrence);
                try testing.expect(key.flags.reversed != opposite.flags.reversed);
                for (try view.turnRow(id, edge.cls.local)) |entry| {
                    try testing.expectEqual(build.turns.encode(.straight, 0, true), entry);
                }
            } else real += 1;
        }
    }
    try testing.expectEqual(3, aliases);
    try testing.expectEqual(leaves, real);
    try testing.expectEqual(4, connectors);
    const snap = routing.snap.candidates;
    const access: snap.Access = .{ .mask = .{ .auto = true } };
    const correlated = try snap.search(view, a, .{ .lat = 0, .lng = 0 }, .{}, access, .none);
    try testing.expectEqual(2 * leaves, correlated.edges.len);
    for (correlated.edges) |edge| try testing.expect(edge.node != .none);
    var finder: routing.snap.reach.Finder = .{ .view = view, .arena = a, .limit = 100, .deadline = .none };
    const reach = try finder.counts(correlated.edges[0].id, access);
    try testing.expectEqual(leaves + 1, reach.outbound);
    try testing.expectEqual(leaves + 1, reach.inbound);
}

test "enhancer marks dead-end approaches and directed not-thru branches" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const main: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    const local: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const layout = try gurka.mapToCoordinatesAt("A---B---C---D\n    |\n    E---F", 25, .{ .lng = 9.6, .lat = 47.1 });
    const fixture = try gurka.Map.init(arena.allocator(), layout, &.{
        .{ .label = "AB", .tags = main },
        .{ .label = "BC", .tags = main },
        .{ .label = "CD", .tags = main },
        .{ .label = "BE", .tags = local },
        .{ .label = "EF", .tags = local },
    }, &.{}, &.{});
    var result = try Built.assemble(fixture.osm, 4);
    defer result.deinit();
    const view = &result.bundle.view;
    const b = try at(view, fixture.findNode("B").?.location.toFixed());
    const e = try at(view, fixture.findNode("E").?.location.toFixed());
    const f = try at(view, fixture.findNode("F").?.location.toFixed());
    try testing.expectEqual(graph.constants.IntersectionType.regular, (try view.node(b)).attr.intersection);
    try testing.expectEqual(graph.constants.IntersectionType.false_intersection, (try view.node(e)).attr.intersection);
    try testing.expectEqual(graph.constants.IntersectionType.dead_end, (try view.node(f)).attr.intersection);

    const cases = [_]struct { tail: format.NodeId, head: format.NodeId, not_thru: bool, dead_end: bool }{
        .{ .tail = b, .head = e, .not_thru = true, .dead_end = false },
        .{ .tail = e, .head = b, .not_thru = false, .dead_end = false },
        .{ .tail = e, .head = f, .not_thru = true, .dead_end = true },
        .{ .tail = f, .head = e, .not_thru = false, .dead_end = false },
    };
    for (cases) |case| {
        for (try view.outEdges(case.tail)) |edge| {
            if (edge.head != @backingInt(case.head)) continue;
            const class = try view.class(edge.cls.class_id);
            try testing.expectEqual(case.not_thru, class.flags.not_thru);
            try testing.expectEqual(case.dead_end, class.flags.dead_end);
            const tail_density = (try view.node(case.tail)).attr.density;
            const head_density = (try view.node(case.head)).attr.density;
            try testing.expectEqual((@as(u8, tail_density) + head_density) / 2, class.category.density);
            break;
        } else return error.MissingTestEdge;
    }
}

test "enhancer recognizes a motorway-link fork and resolves node driving side" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const link: gurka.Tags = &.{
        .{ .key = "highway", .value = "motorway_link" },
        .{ .key = "oneway", .value = "yes" },
    };
    const fixture = try gurka.Map.init(arena.allocator(), try gurka.mapToCoordinates("A---B---C\n    |\n    D", 30), &.{
        .{ .label = "AB", .tags = link },
        .{ .label = "BC", .tags = link },
        .{ .label = "BD", .tags = link },
    }, &.{}, &.{});
    const junction = fixture.findNode("B").?.location.toFixed();
    const Hook = struct {
        fn driveSide(context: *const anyopaque, point: format.Coordinate) ?build.edge_class.DriveSide {
            const left: *const format.Coordinate = @ptrCast(@alignCast(context));
            return if (std.meta.eql(left.*, point)) .left else null;
        }
    };
    var result = try Built.assembleWithOptions(fixture.osm, .{
        .scratch_dir = "",
        .workers = 2,
        .drive_side = .right,
        .admin_drive_side = .{ .context = &junction, .resolve = Hook.driveSide },
    });
    defer result.deinit();
    const view = &result.bundle.view;
    const b = try at(view, junction);
    const a = try at(view, fixture.findNode("A").?.location.toFixed());
    try testing.expectEqual(graph.constants.IntersectionType.fork, (try view.node(b)).attr.intersection);
    try testing.expect((try view.node(b)).attr.drive_on_left);
    try testing.expect(!(try view.node(a)).attr.drive_on_left);
}

test "cul-de-sac loop classification counts only contacts with other roads" {
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const cycleway: gurka.Tags = &.{.{ .key = "highway", .value = "cycleway" }};
    for ([_]bool{ false, true }) |second_road| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const layout = try gurka.mapToCoordinatesAt("A---B---C---D\n    |   |\n    E---F", 25, .{ .lng = 9.6, .lat = 47.1 });
        const fixture = try gurka.Map.init(arena.allocator(), layout, &.{
            .{ .label = "AB", .tags = road },
            .{ .label = "BCFEB", .tags = road },
            .{ .label = "CD", .tags = if (second_road) road else cycleway },
        }, &.{}, &.{});
        var result = try Built.assemble(fixture.osm, 1);
        defer result.deinit();
        const view = &result.bundle.view;
        const loop_id: u64 = @intCast(fixture.findWay("BCFEB").?.id);
        const expected: graph.constants.Use = if (second_road) .road else .culdesac;
        var count: usize = 0;
        for (view.edges, 0..) |edge, i| {
            const id: format.EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
            if (try view.wayId(id) != loop_id) continue;
            count += 1;
            try testing.expectEqual(@backingInt(expected), (try view.class(edge.cls.class_id)).category.use);
        }
        try testing.expect(count >= 4);
    }
}

test "mapped spatial index covers the curve and enumerates occupied cells by distance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const layout = try gurka.mapToCoordinatesAt("A-----B\n      |\n      |\n      C", 260, .{ .lng = 9.6, .lat = 47.1 });
    const fixture = try gurka.Map.init(gpa, layout, &.{
        .{ .label = "ABC", .tags = &.{.{ .key = "highway", .value = "residential" }} },
    }, &.{}, &.{});
    var result = try Built.assemble(fixture.osm, 4);
    defer result.deinit();
    const view = &result.bundle.view;
    const spatial = view.spatial_index.?;
    const geo = routing.geo;
    const representative: format.EdgeId = @fromBackingInt(@as(u32, 0));
    const shape = try view.shape(representative, gpa);
    try testing.expectEqual(3, shape.len);
    for (shape[0..2], shape[1..3]) |previous, point| {
        const a = previous.toPoint();
        const b = point.toPoint();
        const along = try spatial.cellsAlong(gpa, a, b, .none);
        try testing.expect(along.len >= 2);
        for (0..257) |sample| {
            const t = @as(f64, @floatFromInt(sample)) / 256;
            const p: geo.PointLL = .{ .lng = a.lng + (b.lng - a.lng) * t, .lat = a.lat + (b.lat - a.lat) * t };
            const cell = (try spatial.lookup(geo.grid.snapCell(p))) orelse return error.MissingTestCell;
            var edges = cell.edges();
            try testing.expectEqual(@as(?format.EdgeId, representative), try edges.next());
            try testing.expectEqual(null, try edges.next());
        }
    }

    var rings = try spatial.rings(gpa, shape[1].toPoint(), 2500, .none);
    defer rings.deinit();
    var count: usize = 0;
    var previous: f64 = 0;
    while (rings.next()) |hit| {
        try testing.expect(hit.distance >= previous);
        try testing.expect(hit.distance <= 2500);
        previous = hit.distance;
        count += 1;
    }
    try testing.expectEqual(spatial.directory.len, count);
}

test "Hilbert and encounter bundles preserve the graph and the same shortest route" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const layout = try gurka.mapToCoordinatesAt("A---B-------C\n|           |\n|           |\nD-----------E", 115, .{ .lng = 9.6, .lat = 47.1 });
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(gpa, layout, &.{
        .{ .label = "DE", .tags = road },
        .{ .label = "CE", .tags = road },
        .{ .label = "BC", .tags = road },
        .{ .label = "AD", .tags = road },
        .{ .label = "AB", .tags = road },
    }, &.{}, &.{});
    var original = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .workers = 1, .ordering = .{ .kind = .encounter } });
    defer original.deinit();
    var reordered = try Built.assemble(fixture.osm, 4);
    defer reordered.deinit();
    const before = &original.bundle.view;
    const after = &reordered.bundle.view;
    try checkOpposites(before, 10);
    try checkOpposites(after, 10);
    try testing.expectEqual(format.OrderingKind.encounter, before.metadata.?[0].ordering().?);
    try testing.expectEqual(format.OrderingKind.hilbert, after.metadata.?[0].ordering().?);
    try testing.expect(before.metadata.?[0].order_hash != after.metadata.?[0].order_hash);
    for (before.coordinates.?, 0..) |point, i| {
        const old: format.NodeId = @fromBackingInt(@as(u32, @intCast(i)));
        const new = try at(after, point);
        try testing.expectEqual((try before.node(old)).attr, (try after.node(new)).attr);
        const a = try before.outEdgeRange(old);
        const b = try after.outEdgeRange(new);
        try testing.expectEqual(a.count(), b.count());
        for (0..a.count()) |local| {
            const id1: format.EdgeId = @fromBackingInt(@as(u32, @intCast(a.first + local)));
            const id2: format.EdgeId = @fromBackingInt(@as(u32, @intCast(b.first + local)));
            const e1 = try before.edge(id1);
            const e2 = try after.edge(id2);
            const old_head = try before.coordinate(@fromBackingInt(e1.head));
            try testing.expectEqual(old_head, try after.coordinate(@fromBackingInt(e2.head)));
            try testing.expectEqual(e1.geom, e2.geom);
            try testing.expectEqual(e1.speed, e2.speed);
            try testing.expectEqual((try before.class(e1.cls.class_id)).*, (try after.class(e2.cls.class_id)).*);
            try testing.expectEqualSlices(u8, try before.turnRow(old, @intCast(local)), try after.turnRow(new, @intCast(local)));
            try testing.expectEqual(try before.wayId(id1), try after.wayId(id2));
            const way1 = try before.shape(id1, gpa);
            const way2 = try after.shape(id2, gpa);
            try testing.expectEqualSlices(format.Coordinate, way1, way2);
        }
    }
    const start = fixture.findNode("B").?.location.toFixed();
    const end = fixture.findNode("E").?.location.toFixed();
    const route1 = try fixtureRoute(gpa, before, try at(before, start), try at(before, end));
    const route2 = try fixtureRoute(gpa, after, try at(after, start), try at(after, end));
    try testing.expectEqualSlices(u64, route1, route2);
    try testing.expectEqualSlices(u64, &.{
        @intCast(fixture.findWay("BC").?.id), @intCast(fixture.findWay("CE").?.id),
    }, route2);
}

fn fixtureRoute(arena: std.mem.Allocator, view: *const graph.reader.View, source: format.NodeId, target: format.NodeId) ![]u64 {
    const limit = std.math.maxInt(u64);
    const distances = try arena.alloc(u64, view.nodes.len);
    @memset(distances, limit);
    const visited = try arena.alloc(bool, view.nodes.len);
    @memset(visited, false);
    const parents = try arena.alloc(?format.EdgeId, view.nodes.len);
    @memset(parents, null);
    distances[@backingInt(source)] = 0;
    while (true) {
        var best: u64 = limit;
        var next: usize = 0;
        for (distances, visited, 0..) |d, done, i| {
            if (!done and d < best) {
                next = i;
                best = d;
            }
        }
        if (best == limit) return error.MissingFixtureRoute;
        if (next == @backingInt(target)) break;
        visited[next] = true;
        const node: format.NodeId = @fromBackingInt(@as(u32, @intCast(next)));
        const range = try view.outEdgeRange(node);
        for (view.edges[range.first..range.end], range.first..range.end) |edge, i| {
            const candidate = best + edge.geom.len_m;
            if (candidate >= distances[edge.head]) continue;
            distances[edge.head] = candidate;
            parents[edge.head] = @fromBackingInt(@as(u32, @intCast(i)));
        }
    }

    var way_ids: std.ArrayList(u64) = .empty;
    var node = target;
    while (node != source) {
        const step = parents[@backingInt(node)] orelse return error.MissingFixtureRoute;
        try way_ids.append(arena, try view.wayId(step));
        node = @fromBackingInt((try view.edge(try view.oppEdge(step))).head);
    }
    std.mem.reverse(u64, way_ids.items);
    return try way_ids.toOwnedSlice(arena);
}

// Ported from test/gurka/test_locate.cc and test/gurka/test_search_side_of_street.cc.
test "locate correlates junctions, projects mid-edge, and preserves heading and side fallbacks" {
    var backing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(backing.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "living_street" }};
    // AD crosses a local tile boundary and spans several native snap cells.
    const layout = try gurka.mapToCoordinatesAt("B      \n|  4   \nA--3--D\n|     /\nC----/ ", 100, .{ .lng = 9.495, .lat = 47.1 });
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "AC", .tags = road },
        .{ .label = "AD", .tags = road },
        .{ .label = "CD", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .workers = 1, .drive_side = .right });
    defer built.deinit();
    const view = &built.bundle.view;
    const snap = routing.snap.candidates;
    const auto: snap.Access = .{ .mask = .{ .auto = true } };
    const node_a = fixture.findNode("A").?.location;
    const node_d = fixture.findNode("D").?.location;
    const midpoint = layout.points['3'].?;

    var location: routing.api.request.Location = .{ .lat = node_a.lat, .lng = node_a.lng };
    const at_node = try snap.search(view, a, location, .{}, auto, .none);
    try testing.expectEqual(6, at_node.edges.len);
    for (at_node.edges) |edge| {
        try testing.expect(edge.node != .none);
        try testing.expect(edge.projected.distance(node_a) < 0.02);
        try testing.expectEqual(snap.Side.none, edge.side);
        try testing.expectEqual(@as(f32, if (edge.node == .begin) 0 else 1), edge.percent_along);
    }
    location.heading = 180;
    location.type = .through;
    const through = try snap.search(view, a, location, .{}, auto, .none);
    try testing.expectEqual(1, through.edges.len);
    try testing.expectEqual(.begin, through.edges[0].node);
    try testing.expectEqual(5, through.filtered_edges.len);
    try testing.expectEqual(.end, through.filtered_edges[through.filtered_edges.len - 1].node);

    location = .{ .lat = node_a.lat + 0.0004, .lng = node_a.lng + 0.00008, .search_cutoff = 20, .node_snap_tolerance = 80 };
    const near_a = try snap.search(view, a, location, .{}, auto, .none);
    try testing.expectEqual(6, near_a.edges.len);
    try testing.expect(near_a.edges[0].distance > 20);
    location.search_cutoff = 1;
    try testing.expectEqual(0, (try snap.search(view, a, location, .{}, auto, .none)).edges.len);

    location = .{ .lat = midpoint.lat, .lng = midpoint.lng, .heading = 90, .skip_ranking_candidates = true };
    const east = try snap.search(view, a, location, .{}, auto, .none);
    try testing.expectEqual(1, east.edges.len);
    try testing.expectEqual(1, east.filtered_edges.len);
    try testing.expect(!east.rank_candidates);
    try testing.expectEqual(.none, east.edges[0].node);
    try testing.expectApproxEqAbs(@as(f32, 0.5), east.edges[0].percent_along, 0.002);
    try testing.expectApproxEqAbs(@as(f32, 90), east.edges[0].heading, 0.01);
    try testing.expectEqual(try view.oppEdge(east.edges[0].id), east.filtered_edges[0].id);
    location.heading = 270;
    const west = try snap.search(view, a, location, .{}, auto, .none);
    try testing.expectEqual(east.filtered_edges[0].id, west.edges[0].id);

    location.heading = null;
    location.display_lat = midpoint.lat - 0.0001;
    location.display_lng = midpoint.lng;
    location.preferred_side = .same;
    const same = try snap.search(view, a, location, .{}, auto, .none);
    try testing.expectEqual(east.edges[0].id, same.edges[0].id);
    try testing.expectEqual(.right, same.edges[0].side);
    location.preferred_side = .opposite;
    const opposite = try snap.search(view, a, location, .{}, auto, .none);
    try testing.expectEqual(west.edges[0].id, opposite.edges[0].id);
    try testing.expectEqual(.left, opposite.edges[0].side);
    location.street_side_max_distance = 3;
    try testing.expectEqual(2, (try snap.search(view, a, location, .{}, auto, .none)).edges.len);

    location = .{ .lat = node_d.lat, .lng = node_d.lng + 0.0001 };
    const past_d = try snap.search(view, a, location, .{}, auto, .none);
    try testing.expectEqual(4, past_d.edges.len);
    for (past_d.edges) |edge| try testing.expect(edge.projected.distance(node_d) < 0.02);

    location = .{ .lat = midpoint.lat, .lng = midpoint.lng, .radius = 5000 };
    const normal = try snap.search(view, a, location, .{}, auto, .none);
    const wide: snap.Defaults = .{ .max_radius = 5000 };
    const radius = try snap.search(view, a, location, wide, auto, .none);
    try testing.expect(radius.edges.len > normal.edges.len);
    try testing.expectEqual(8, radius.edges.len);
    try testing.expectError(error.DeadlineExceeded, snap.search(view, a, location, .{}, auto, .{ .at_ns = 0 }));

    try testing.expect(arena.reset(.retain_capacity));
    _ = try snap.search(view, a, location, wide, auto, .none);
    const allocations = backing.allocations;
    const resizes = backing.resize_index;
    for (0..64) |_| {
        try testing.expect(arena.reset(.retain_capacity));
        _ = try snap.search(view, a, location, wide, auto, .none);
    }
    try testing.expectEqual(allocations, backing.allocations);
    try testing.expectEqual(resizes, backing.resize_index);
}

// Ported from test/gurka/test_search_filter.cc.
test "location search filters levels, classes, steps and mode access and honors preferred layer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const layout = try gurka.mapToCoordinatesAt("A----B\nC----D\nE----F", 30, .{ .lng = 9.6, .lat = 47.1 });
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "steps" },
            .{ .key = "level", .value = "-2;-1;0.5;2-4" },
            .{ .key = "layer", .value = "-1" },
        } },
        .{ .label = "CD", .tags = &.{
            .{ .key = "highway", .value = "residential" },
            .{ .key = "level", .value = "0" },
        } },
        .{ .label = "EF", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "bridge", .value = "yes" },
            .{ .key = "layer", .value = "1" },
            .{ .key = "level", .value = "1" },
        } },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const snap = routing.snap.candidates;
    const foot: snap.Access = .{ .mask = .{ .pedestrian = true } };
    const auto: snap.Access = .{ .mask = .{ .auto = true } };
    const point = fixture.findNode("A").?.location;
    var location: routing.api.request.Location = .{ .lat = point.lat, .lng = point.lng + 0.001, .radius = 100 };
    const all = try snap.search(view, a, location, .{}, foot, .none);
    try testing.expectEqual(6, all.edges.len);
    try testing.expectEqual(4, (try snap.search(view, a, location, .{}, auto, .none)).edges.len);

    const TimedCost = struct {
        access: snap.Access,
        blocked_way: u64,

        pub fn allowed(self: @This(), edge: snap.DirectedEdge) bool {
            return self.access.allowed(edge);
        }

        pub fn closed(self: @This(), edge: snap.DirectedEdge) bool {
            return (edge.graph_view.wayId(edge.id) catch unreachable) == self.blocked_way;
        }

        pub fn meetsAccessRestrictions(self: @This(), edge: snap.DirectedEdge) bool {
            return !self.closed(edge);
        }
    };
    const timed: TimedCost = .{ .access = foot, .blocked_way = try view.wayId(all.edges[0].id) };
    try testing.expectEqual(4, (try snap.search(view, a, location, .{}, timed, .none)).edges.len);
    location.search_filter.exclude_closures = false;
    try testing.expectEqual(6, (try snap.search(view, a, location, .{}, timed, .none)).edges.len);
    location.search_filter.exclude_restricted = true;
    try testing.expectEqual(4, (try snap.search(view, a, location, .{}, timed, .none)).edges.len);
    location.search_filter = .{};

    location.preferred_layer = 1;
    const layer = try snap.search(view, a, location, .{}, foot, .none);
    try testing.expectEqual(2, layer.edges.len);
    try testing.expectEqual(4, layer.filtered_edges.len);
    const way = try view.wayId(layer.edges[0].id);
    try testing.expectEqual(try view.wayId(all.edges[4].id), way);

    location.preferred_layer = null;
    location.search_filter.exclude_steps = true;
    location.search_filter.exclude_bridge = true;
    try testing.expectEqual(2, (try snap.search(view, a, location, .{}, foot, .none)).edges.len);
    location.search_filter.max_road_class = .service_other;
    try testing.expectEqual(0, (try snap.search(view, a, location, .{ .search_cutoff = 100 }, foot, .none)).edges.len);

    location.search_filter = .{ .level = -1 };
    const level = try snap.search(view, a, location, .{}, foot, .none);
    try testing.expectEqual(2, level.edges.len);
    try testing.expectEqual(try view.wayId(all.edges[0].id), try view.wayId(level.edges[0].id));
    location.search_filter.level = 3.5;
    try testing.expectEqual(2, (try snap.search(view, a, location, .{}, foot, .none)).edges.len);
    location.search_filter.level = 1.5;
    try testing.expectEqual(0, (try snap.search(view, a, location, .{}, foot, .none)).edges.len);
}

fn directedBetween(view: *const graph.reader.View, fixture: *const gurka.Map, first: []const u8, last: []const u8) !format.EdgeId {
    const source = try at(view, fixture.findNode(first).?.location.toFixed());
    const target = try at(view, fixture.findNode(last).?.location.toFixed());
    const outgoing = try view.outEdgeRange(source);
    for (outgoing.first..outgoing.end) |i| {
        const id: format.EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
        if ((try view.edge(id)).head == @backingInt(target)) return id;
    }
    return error.TestEdgeNotFound;
}

fn restrictedMovement(view: *const graph.reader.View, incoming: format.EdgeId, outgoing: format.EdgeId) !bool {
    const entry = try view.edge(incoming);
    const exit = try view.edge(outgoing);
    const row = try view.turnRow(@fromBackingInt(entry.head), entry.cls.opp_local);
    return row[exit.cls.local] & 0x80 != 0;
}

test "Gurka no turn and only turn restrictions follow travel direction" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const fixture = try @import("examples.zig").simpleTurns(storage.allocator());
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try view.verify(.none, null);
    const cb = try directedBetween(view, &fixture, "C", "B");
    const be = try directedBetween(view, &fixture, "B", "E");
    const ab = try directedBetween(view, &fixture, "A", "B");
    try testing.expect(try restrictedMovement(view, cb, be));
    try testing.expect(!try restrictedMovement(view, try view.oppEdge(be), try view.oppEdge(cb)));
    try testing.expect(!try restrictedMovement(view, ab, be));
    const kl = try directedBetween(view, &fixture, "K", "L");
    const lm = try directedBetween(view, &fixture, "L", "M");
    const ln = try directedBetween(view, &fixture, "L", "N");
    try testing.expect(!try restrictedMovement(view, kl, lm));
    try testing.expect(try restrictedMovement(view, kl, ln));
    try testing.expect(try restrictedMovement(view, kl, try view.oppEdge(kl)));

    const ad = try directedBetween(view, &fixture, "A", "D");
    const de = try directedBetween(view, &fixture, "D", "E");
    const bike = view.turnRestrictionModes(try view.oppEdge(de), try view.oppEdge(ad));
    try testing.expectEqual(@as(u16, @bitCast(graph.constants.AccessMask{ .bicycle = true })), bike);
    const except: graph.constants.AccessMask = @bitCast(view.turnRestrictionModes(ad, de));
    try testing.expect(except.auto and except.truck and !except.bus and !except.taxi and !except.bicycle);
    try testing.expect(!try restrictedMovement(view, ad, de));
    try testing.expect((try view.node(@fromBackingInt((try view.edge(ad)).head))).attr.has_turn_restrictions);
    try testing.expectEqual(5, built.stats.simple_turns.parsed);
    try testing.expectEqual(4, built.stats.simple_turns.resolved);
    try testing.expectEqual(0, built.stats.simple_turns.deferred);
    try testing.expectEqual(1, built.stats.simple_turns.complex);

    const from = try at(view, fixture.findNode("C").?.location.toFixed());
    const to = try at(view, fixture.findNode("F").?.location.toFixed());
    var engine = try SearchTest.init(testing.allocator, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const request: search.Request = .{ .origin = from, .destination = to, .direction = direction };
        const potential = try search.L2.init(view, if (direction == .forward) to else from, 1);
        const limited = try engine.run(&arena, .{ .seed = 1 }, request, potential, .{});
        const limited_cost = limited.best().cost;
        arena.reset();
        const ignored = try engine.run(&arena, .{ .seed = 1, .ignore_turn_restrictions = true }, request, potential, .{});
        try testing.expect(limited_cost > ignored.best().cost);
        arena.reset();
    }
}

const ClosureCost = struct {
    edges: [2]format.EdgeId,
    ignore: bool = false,
    current: bool = true,
    filter: bool = false,

    pub fn restrictionPermission(self: ClosureCost) routing.costing.base.Permission {
        var permission = (RestrictionMotor{}).restrictionPermission();
        permission.flow.current = self.current;
        permission.filter_closures = self.filter;
        if (self.ignore) permission.flags.insert(.ignore_closures);
        return permission;
    }

    pub fn closed(self: ClosureCost, edge: routing.snap.candidates.DirectedEdge) bool {
        return self.restrictionPermission().usesClosures() and (edge.id == self.edges[0] or edge.id == self.edges[1]);
    }

    pub fn allowed(self: ClosureCost, edge: routing.snap.candidates.DirectedEdge) bool {
        return self.restrictionPermission().allowedCandidate(edge.class, .{ .closed = self.closed(edge) }, .{});
    }

    pub fn edgeCost(_: ClosureCost, view: *const graph.reader.View, edge: format.EdgeId, hot: *const format.EdgeHot, direction: search.Direction) !Cost {
        return (RestrictionMotor{}).edgeCost(view, edge, hot, direction);
    }

    pub fn allowedTurn(_: ClosureCost, view: *const graph.reader.View, turn: search.Transition, previous: search.Label, direction: search.Direction) !bool {
        return (RestrictionMotor{}).allowedTurn(view, turn, previous, direction);
    }

    pub fn turnCost(_: ClosureCost, _: *const graph.reader.View, _: search.Transition, _: search.Label, _: search.Direction) !Cost {
        return .{};
    }
};

// Ported from test_search_filter.cc's closure filtering and costing cases.
fn checkGurkaClosure(view: *const graph.reader.View, fixture: *const gurka.Map, middle: routing.geo.point.PointLL, from: format.NodeId, to: format.NodeId, edges: [2]format.EdgeId) !void {
    const snap = routing.snap.candidates;
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try search.Search(ClosureCost, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();
    var cost: ClosureCost = .{ .edges = edges };
    var location: routing.api.request.Location = .{ .lat = middle.lat, .lng = middle.lng, .minimum_reachability = 0 };
    const filtered = try snap.search(view, arena.allocator(), location, .{}, cost, .none);
    for (filtered.edges) |edge| try testing.expect(edge.id != edges[0] and edge.id != edges[1]);
    location.search_filter.exclude_closures = false;
    const unfiltered = try snap.search(view, arena.allocator(), location, .{}, cost, .none);
    try testing.expectEqual(2, unfiltered.edges.len);
    for (unfiltered.edges) |edge| try testing.expect(edge.id == edges[0] or edge.id == edges[1]);
    arena.reset();

    cost.filter = true;
    const detour = try engine.run(&arena, cost, .{ .origin = from, .destination = to }, search.Zero{}, .{});
    try expectWayPath(view, fixture, detour, .forward, &.{ "AB", "BD", "DE", "EC" });
    arena.reset();
    const b = try at(view, fixture.findNode("B").?.location.toFixed());
    cost.filter = false;
    const from_closed = try engine.run(&arena, cost, .{ .origin = b, .destination = to }, search.Zero{}, .{});
    try expectWayPath(view, fixture, from_closed, .forward, &.{"BC"});
    arena.reset();
    for ([_]ClosureCost{ .{ .edges = edges, .ignore = true }, .{ .edges = edges, .current = false } }) |disabled| {
        const open = try engine.run(&arena, disabled, .{ .origin = from, .destination = to }, search.Zero{}, .{});
        try expectWayPath(view, fixture, open, .forward, &.{ "AB", "BC" });
        arena.reset();
    }
}

const RestrictionMotor = struct {
    modes: u16 = 1,
    probability: u8 = 0,
    ignore: bool = false,
    ignore_access: bool = false,
    allow_destination_only: bool = true,
    destination_penalty: f32 = 0,

    pub fn allowed(self: RestrictionMotor, edge: routing.snap.candidates.DirectedEdge) bool {
        return self.restrictionPermission().allowedClass(edge.class);
    }

    pub fn allowedNode(self: RestrictionMotor, node: *const format.NodeHot) bool {
        return self.restrictionPermission().allowedNode(node);
    }

    pub fn restrictionPermission(self: RestrictionMotor) routing.costing.base.Permission {
        var permission: routing.costing.base.Permission = .{ .flags = .empty, .flow = .{}, .access_mask = @bitCast(self.modes), .filter_closures = false };
        if (self.ignore) permission.flags.insert(.ignore_restrictions);
        if (self.ignore_access) permission.flags.insert(.ignore_access);
        permission.allow_destination_only = self.allow_destination_only;
        permission.restriction_probability = self.probability;
        return permission;
    }

    pub fn edgeCost(self: RestrictionMotor, view: *const graph.reader.View, _: format.EdgeId, edge: *const format.EdgeHot, _: search.Direction) !Cost {
        if (!self.restrictionPermission().allowedClass(try view.class(edge.cls.class_id))) return .forbidden;
        return .{ .cost = @floatFromInt(edge.geom.len_m), .secs = @floatFromInt(edge.geom.len_m) };
    }

    pub fn allowedTurn(self: RestrictionMotor, view: *const graph.reader.View, turn: search.Transition, _: search.Label, direction: search.Direction) !bool {
        if (!self.restrictionPermission().allowedNode(try view.node(turn.node))) return false;
        const backtrack = turn.incoming_edge.cls.opp_local == turn.outgoing_edge.cls.local;
        if (backtrack) {
            const previous = if (direction == .forward) turn.incoming_edge else turn.outgoing_edge;
            if (!try turn.predecessorAtDeadEnd(view, try view.class(previous.cls.class_id))) return false;
        }
        return self.ignore or turn.row & 0x80 == 0;
    }

    pub fn turnCost(self: RestrictionMotor, _: *const graph.reader.View, turn: search.Transition, _: search.Label, direction: search.Direction) !Cost {
        const previous = if (direction == .forward) turn.incoming_access else turn.outgoing_access;
        const next = if (direction == .forward) turn.outgoing_access else turn.incoming_access;
        return .{ .cost = if (!previous.destination_only and next.destination_only) self.destination_penalty else 0 };
    }
};

const RestrictionSearch = search.Search(RestrictionMotor, routing.search.queue.Heap);

// Ported from test/gurka/test_locate.cc for the public locate action.
test "Gurka locate reports directed shapes, snapped nodes and missing matches" {
    const http = routing.server.http;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A----B", 50), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Market St" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "maxheight", .value = "3.8" },
        } },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    var svc: routing.api.service.Service = .{ .graph = &built.bundle.view };
    svc.register(.locate, routing.api.locate_action.handle);
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var ctx: http.Ctx = .{ .worker_id = 0, .arena = &arena, .deadline = .none };
    const end = fixture.findNode("B").?.location;
    const start = fixture.findNode("A").?.location;
    const middle = start.midpoint(end);
    const encoded = try std.fmt.allocPrint(a,
        \\{{"locations":[{{"lat":{d},"lon":{d}}},{{"lat":{d},"lon":{d}}},{{"lat":86,"lon":2}}],
        \\"verbose":true,"costing":"auto"}}
    , .{ middle.lat, middle.lng, end.lat, end.lng });
    var req: http.Request = .{
        .method = .POST,
        .target = "/locate",
        .path = "/locate",
        .query = &.{},
        .headers = &.{},
        .body = encoded,
        .keep_alive = false,
    };
    var res: http.Response = .{ .gpa = arena.allocator() };
    svc.handle(&ctx, &req, &res);
    try testing.expectEqual(200, res.status);
    const verbose = try std.json.parseFromSliceLeaky(std.json.Value, res.gpa, res.body.items, .{});
    const first = verbose.array.items[0].object;
    const edges = first.get("edges").?.array.items;
    try testing.expectEqual(1, edges.len);
    const edge = edges[0].object;
    try testing.expectApproxEqAbs(@as(f64, 0.5), edge.get("percent_along").?.float, 1e-5);
    try testing.expect(edge.get("linear_reference").?.string.len >= 20);
    const info = edge.get("edge_info").?.object;
    try testing.expectEqualStrings("Market St", info.get("names").?.array.items[0].string);
    const restriction = edge.get("access_restrictions").?.array.items[0].object;
    try testing.expectEqualStrings("max_height", restriction.get("type").?.string);
    try testing.expectApproxEqAbs(@as(f64, 3.8), restriction.get("value").?.float, 0.01);
    const nodes = verbose.array.items[1].object.get("nodes").?.array.items;
    try testing.expectEqual(1, nodes.len);
    try testing.expect(nodes[0].object.get("node_id") != null);
    try testing.expectEqual(0, verbose.array.items[2].object.get("edges").?.array.items.len);
    try testing.expectEqual(0, verbose.array.items[2].object.get("nodes").?.array.items.len);

    arena.reset();
    req.body = try std.fmt.allocPrint(a,
        \\{{"locations":[{{"lat":{d},"lon":{d}}}],"format":"osrm","costing":"auto"}}
    , .{ middle.lat, middle.lng });
    res = .{ .gpa = arena.allocator() };
    svc.handle(&ctx, &req, &res);
    try testing.expectEqual(200, res.status);
    const nearest = try std.json.parseFromSliceLeaky(std.json.Value, res.gpa, res.body.items, .{});
    try testing.expectEqualStrings("Ok", nearest.object.get("code").?.string);
    const waypoint = nearest.object.get("waypoints").?.array.items[0].object;
    try testing.expectEqualStrings("Market St", waypoint.get("name").?.string);
    try testing.expectEqual(2, waypoint.get("location").?.array.items.len);
    try testing.expectEqual(2, waypoint.get("nodes").?.array.items.len);

    arena.reset();
    req.body = try std.fmt.allocPrint(a,
        \\{{"locations":[{{"lat":{d},"lon":{d},"search_filter":{{"exclude_restricted":true}}}}],
        \\"format":"osrm","costing":"auto","costing_options":{{"auto":{{"height":4.0}}}}}}
    , .{ middle.lat, middle.lng });
    res = .{ .gpa = arena.allocator() };
    svc.handle(&ctx, &req, &res);
    try testing.expectEqual(400, res.status);
    const missing = try std.json.parseFromSliceLeaky(std.json.Value, res.gpa, res.body.items, .{});
    try testing.expectEqualStrings("NoSegment", missing.object.get("code").?.string);

    for ([_][]const u8{ "{}", "{\"locations\":[]}" }) |body| {
        arena.reset();
        req.body = body;
        res = .{ .gpa = arena.allocator() };
        svc.handle(&ctx, &req, &res);
        try testing.expectEqual(400, res.status);
        const failure = try std.json.parseFromSliceLeaky(std.json.Value, res.gpa, res.body.items, .{});
        try testing.expectEqual(110, failure.object.get("error_code").?.integer);
    }
}

test "Gurka measurements group opposing directions and deduplicate junctions" {
    const match = routing.match.candidates;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A----B----C", 50), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "oneway", .value = "yes" },
        } },
        .{ .label = "BC", .tags = &.{.{ .key = "highway", .value = "primary" }} },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    var backing = routing.infra.arena.CountingAllocator.init(testing.allocator);
    var request_memory = routing.infra.arena.Arena.init(backing.allocator(), .{});
    defer request_memory.deinit();
    var finder = match.Finder.init(view, request_memory.allocator(), .{});
    defer finder.deinit();
    const access: routing.snap.candidates.Access = .{ .mask = .{ .auto = true } };
    const start = fixture.findNode("A").?.location;
    const junction = fixture.findNode("B").?.location;
    const end = fixture.findNode("C").?.location;
    const middle = start.midpoint(junction);
    const forward = try directedBetween(view, &fixture, "A", "B");
    const first = try finder.query(.{ .point = middle }, access, .none);
    try testing.expectEqual(1, first.len);
    try testing.expectEqual(1, first[0].arcs().len);
    try testing.expectEqual(forward, first[0].arcs()[0].edge);
    try testing.expectApproxEqAbs(@as(f32, 0.5), first[0].arcs()[0].percent_along, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 90), first[0].arcs()[0].heading, 1);

    const pair = try finder.query(.{ .point = junction.midpoint(end) }, access, .none);
    try testing.expectEqual(1, pair.len);
    try testing.expectEqual(2, pair[0].arcs().len);
    try testing.expectEqual(try view.oppEdge(pair[0].arcs()[0].edge), pair[0].arcs()[1].edge);
    const at_node = try finder.query(.{ .point = junction, .search_radius = 2 }, access, .none);
    try testing.expectEqual(1, at_node.len);
    try testing.expectEqual(try at(view, junction.toFixed()), at_node[0].node.?);

    var uncached = match.Finder.init(view, a, .{ .shape_cache_bytes = 1, .max_search_radius = 5 });
    defer uncached.deinit();
    var offset = match.Measurement{
        .point = .init(middle.lng, middle.lat + 0.00008),
        .search_radius = 2,
        .gps_accuracy = 12,
    };
    try testing.expectEqual(1, (try finder.query(offset, access, .none)).len);
    try testing.expectEqual(0, (try uncached.query(offset, access, .none)).len);
    offset.point = middle;
    const from_scratch = try uncached.query(offset, access, .none);
    try testing.expectEqual(forward, from_scratch[0].arcs()[0].edge);
    try testing.expect(uncached.storage.reserved <= 1);
    backing.resetCounts();
    for (0..8) |_| {
        try testing.expectEqual(forward, (try finder.query(offset, access, .none))[0].arcs()[0].edge);
    }
    try testing.expectEqual(0, backing.calls());
}

// Ported from test/gurka/test_vector_tiles.cc for the edges and nodes layers.
test "Gurka tile emits graph features and applies zoom and layer filters" {
    const http = routing.server.http;
    const wire = @import("protobuf").wire;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const layout = try gurka.mapToCoordinatesAt("A----B----C", 50, .init(0.0002, -0.0002));
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name:forward", .value = "East Street" },
            .{ .key = "name:backward", .value = "West Street" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "maxspeed", .value = "40" },
        } },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    var svc: routing.api.service.Service = .{ .graph = &built.bundle.view };
    svc.register(.tile, routing.api.tile_action.handle);
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var ctx: http.Ctx = .{ .worker_id = 0, .arena = &arena, .deadline = .none };
    var req: http.Request = .{
        .method = .POST,
        .target = "/tile",
        .path = "/tile",
        .query = &.{},
        .headers = &.{},
        .body =
        \\{"tile":{"x":8192,"y":8192,"z":14},
        \\"filters":{"action":"include","attributes":["edge.speed_forward"]}}
        ,
        .keep_alive = false,
    };
    var res: http.Response = .{ .gpa = arena.allocator() };
    svc.handle(&ctx, &req, &res);
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("application/vnd.mapbox-vector-tile", res.content_type);
    try testing.expectEqualStrings("Cache-Control: public, max-age=1800", res.extra_headers.items[0]);
    var tile = wire.Reader.init(res.body.items);
    var layer = wire.Reader.init((try tile.next(ctx.deadline)).?.value.length_delimited);
    var edge_features: usize = 0;
    var have_speed = false;
    while (try layer.next(ctx.deadline)) |field| switch (field.number) {
        1 => try testing.expectEqualStrings("edges", field.value.length_delimited),
        2 => edge_features += 1,
        3 => if (std.mem.eql(u8, field.value.length_delimited, "speed:fwd")) {
            have_speed = true;
        },
        else => {},
    };
    try testing.expectEqual(3, edge_features);
    try testing.expect(have_speed);
    layer = .init((try tile.next(ctx.deadline)).?.value.length_delimited);
    var node_features: usize = 0;
    while (try layer.next(ctx.deadline)) |field| switch (field.number) {
        1 => try testing.expectEqualStrings("nodes", field.value.length_delimited),
        2 => node_features += 1,
        else => {},
    };
    try testing.expectEqual(3, node_features);
    try testing.expectEqual(null, try tile.next(ctx.deadline));

    arena.reset();
    svc.limits.tile.allow_verbose = true;
    req.body = "{\"tile\":{\"x\":8192,\"y\":8192,\"z\":14},\"verbose\":true}";
    res = .{ .gpa = arena.allocator() };
    svc.handle(&ctx, &req, &res);
    try testing.expectEqual(200, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body.items, "live_speed:bwd:congestion3") != null);

    const cases = [_]struct { body: []const u8, status: u16, code: u16 = 0 }{
        .{ .body = "{\"tile\":{\"x\":64,\"y\":64,\"z\":7}}", .status = 200 },
        .{ .body = "{\"tile\":{\"x\":16384,\"y\":16384,\"z\":15}}", .status = 400, .code = 175 },
        .{ .body = "{\"tile\":{\"x\":16384,\"y\":8192,\"z\":14}}", .status = 400, .code = 174 },
        .{ .body = "{\"tile\":{\"x\":8192,\"y\":8192,\"z\":14},\"tile_options\":{\"exclude_layers\":[\"edges\",\"nodes\"]}}", .status = 200 },
    };
    for (cases) |case| {
        arena.reset();
        req.body = case.body;
        res = .{ .gpa = arena.allocator() };
        svc.handle(&ctx, &req, &res);
        try testing.expectEqual(case.status, res.status);
        if (case.code == 0) {
            try testing.expectEqual(0, res.body.items.len);
        } else {
            const failure = try std.json.parseFromSliceLeaky(std.json.Value, res.gpa, res.body.items, .{});
            try testing.expectEqual(case.code, failure.object.get("error_code").?.integer);
        }
    }
}

// Ported from the Dijkstra cases in test/gurka/test_expansion.cc.
test "Gurka Dijkstra expansion settles the one-way branch only forward" {
    const expansion = routing.search.expand;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road: gurka.Tag = .{ .key = "highway", .value = "primary" };
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates(
        \\   B  F--G
        \\   |  |
        \\E--A--C--H
        \\   |
        \\   D
    , 10), &.{
        .{ .label = "DAB", .tags = &.{road} },
        .{ .label = "EACH", .tags = &.{road} },
        .{ .label = "CFG", .tags = &.{ road, .{ .key = "oneway", .value = "yes" } } },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const start = try at(view, fixture.findNode("A").?.location.toFixed());
    const one_way = try directedBetween(view, &fixture, "C", "G");
    const opposing = try view.oppEdge(one_way);
    const Observer = struct {
        view: *const graph.reader.View,
        edges: u16 = 0,
        pairs: u16 = 0,
        previous_cost: f32 = 0,

        pub fn visit(self: *@This(), event: expansion.Visit) !expansion.Decision {
            try testing.expect(event.label.cost >= self.previous_cost);
            self.previous_cost = event.label.cost;
            const edge = event.label.edgeId();
            const reverse_edge = try self.view.oppEdge(edge);
            const bit = @as(u16, 1) << @intCast(@backingInt(edge));
            try testing.expect(self.edges & bit == 0);
            self.edges |= bit;
            self.pairs |= @as(u16, 1) << @intCast(@min(@backingInt(edge), @backingInt(reverse_edge)));
            return .expand;
        }
    };
    var engine = try expansion.Expansion(RestrictionMotor, routing.search.queue.BucketQueue).init(testing.allocator, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        var seen: Observer = .{ .view = view };
        const stats = try engine.run(&arena, .{}, .{ .origins = &.{start}, .direction = direction }, &seen, .{});
        const forward = direction == .forward;
        try testing.expectEqual(@as(usize, if (forward) 11 else 10), stats.settled);
        try testing.expectEqual(@as(u16, if (forward) 6 else 5), @popCount(seen.pairs));
        try testing.expectEqual(forward, seen.edges & (@as(u16, 1) << @intCast(@backingInt(one_way))) != 0);
        try testing.expect(seen.edges & (@as(u16, 1) << @intCast(@backingInt(opposing))) == 0);
        arena.reset();
    }
}

// Ported from Isochrones.OriginEdge and Isochrones.LongEdge in test/isochrone.cc.
test "Gurka isochrone paints clipped origins and reaches partway along a long edge" {
    const iso = routing.search.isochrone;
    const Candidate = routing.search.endpoints.Candidate;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    var counting = routing.infra.arena.CountingAllocator.init(testing.allocator);
    var arena = routing.infra.arena.Arena.init(counting.allocator(), .{});
    defer arena.deinit();
    {
        const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A-B-C", 2000), &.{
            .{ .label = "ABC", .tags = road },
        }, &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        const left = fixture.findNode("A").?.location;
        const middle = fixture.findNode("B").?.location;
        const right = fixture.findNode("C").?.location;
        const east = try directedBetween(view, &fixture, "A", "C");
        const west = try view.oppEdge(east);
        const seeds = [_]Candidate{
            .{ .edge = east, .fraction = 0.5, .score = 0, .begin_node = false, .end_node = false },
            .{ .edge = west, .fraction = 0.5, .score = 0, .begin_node = false, .end_node = false },
        };
        var engine = try iso.Isochrone(RestrictionMotor).init(counting.allocator(), view);
        defer engine.deinit();
        const result = try engine.run(&arena, .{}, .{
            .origins = &.{.{ .location = middle, .seed = .{ .edges = &seeds } }},
            .contours = &.{.{ .metric = iso.time_metric, .value = 10 }},
            .mode = .pedestrian,
        }, .{});
        const grid = result.grid;
        try testing.expectEqual(@as(f32, 0), grid.dataAt(grid.tiles.tileIdOf(middle), iso.time_metric).?);
        for ([_]routing.geo.PointLL{ left, right }) |end| {
            const nearby = middle.pointAlongSegment(end, 0.1);
            const value = grid.dataAt(grid.tiles.tileIdOf(nearby), iso.time_metric).?;
            try testing.expect(value > 0 and value < 10);
            try testing.expect((grid.dataAt(grid.tiles.tileIdOf(end), iso.time_metric) orelse iso.nodata) > 10);
        }
        arena.reset();
    }
    {
        const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates(
            \\   C----D
            \\  /
            \\A-B--------------F
        , 100), &.{
            .{ .label = "AB", .tags = road },
            .{ .label = "BC", .tags = road },
            .{ .label = "CD", .tags = road },
            .{ .label = "BF", .tags = road },
        }, &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        const origin = fixture.findNode("A").?.location;
        const start = try at(view, origin.toFixed());
        const branch = fixture.findNode("B").?.location;
        const far = fixture.findNode("F").?.location;
        var engine = try iso.Isochrone(RestrictionMotor).init(counting.allocator(), view);
        defer engine.deinit();
        const result = try engine.run(&arena, .{}, .{
            .origins = &.{.{ .location = origin, .seed = .{ .node = start } }},
            .contours = &.{ .{ .metric = iso.time_metric, .value = 16 }, .{ .metric = iso.distance_metric, .value = 2 } },
            .mode = .pedestrian,
        }, .{});
        const grid = result.grid;
        const far_cell = grid.tiles.tileIdOf(far);
        const partway = grid.tiles.tileIdOf(branch.pointAlongSegment(far, 0.4));
        try testing.expect(grid.dataAt(partway, iso.time_metric).? < 16);
        try testing.expect(grid.dataAt(far_cell, iso.time_metric).? > 16);
        try testing.expect(grid.dataAt(far_cell, iso.distance_metric).? < 2);
        arena.reset();

        const other = fixture.findNode("D").?.location;
        const target = try at(view, other.toFixed());
        const origins: []const iso.Origin = &.{
            .{ .location = origin, .seed = .{ .node = start } },
            .{ .location = other, .seed = .{ .node = target } },
        };
        var reverse: iso.Request = .{
            .origins = origins,
            .contours = &.{.{ .metric = iso.distance_metric, .value = 1 }},
            .direction = .reverse,
            .mode = .pedestrian,
        };
        const return_grid = (try engine.run(&arena, .{}, reverse, .{})).grid;
        for (origins) |entry| {
            const cell = return_grid.tiles.tileIdOf(entry.location);
            try testing.expectEqual(@as(f32, 0), return_grid.dataAt(cell, iso.distance_metric).?);
            try testing.expectEqual(std.math.floatMin(f32), return_grid.dataAt(cell, iso.time_metric).?);
        }
        const branch_cell = return_grid.tiles.tileIdOf(branch);
        try testing.expect(return_grid.dataAt(branch_cell, iso.distance_metric).? < 1);
        arena.reset();
        counting.resetCounts();
        _ = try engine.run(&arena, .{}, reverse, .{});
        try testing.expectEqual(0, counting.calls());
        arena.reset();
        try testing.expectError(error.Cancelled, engine.run(&arena, .{}, reverse, .{ .deadline = .{ .at_ns = 0 } }));
        reverse.mode = .multimodal;
        try testing.expectError(error.UnsupportedMultimodalIsochrone, engine.run(&arena, .{}, reverse, .{}));
    }
}

// Ported from the polygon and location detours in test_avoids.cc.
test "Gurka exclusions detour around polygon and snapped directed edges" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates(
        \\A---B---C
        \\    |   |
        \\    D---E
    , 30), &.{
        .{ .label = "AB", .tags = road }, .{ .label = "BC", .tags = &.{ road[0], .{ .key = "level", .value = "2" } } },
        .{ .label = "BD", .tags = road }, .{ .label = "DE", .tags = road },
        .{ .label = "EC", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    const middle = fixture.findNode("B").?.location.midpoint(fixture.findNode("C").?.location);
    const delta = 0.00005;
    const ring: routing.api.exclusions.Ring = .{ .points = &.{
        .init(middle.lng - delta, middle.lat - delta),
        .init(middle.lng + delta, middle.lat - delta),
        .init(middle.lng + delta, middle.lat + delta),
        .init(middle.lng - delta, middle.lat + delta),
    } };
    const bc = try directedBetween(view, &fixture, "B", "C");
    const cb = try view.oppEdge(bc);
    const from = try at(view, fixture.findNode("A").?.location.toFixed());
    const to = try at(view, fixture.findNode("C").?.location.toFixed());
    var engine = try RestrictionSearch.init(testing.allocator, view);
    defer engine.deinit();
    var counting = routing.infra.arena.CountingAllocator.init(testing.allocator);
    var arena = routing.infra.arena.Arena.init(counting.allocator(), .{});
    defer arena.deinit();
    const Cases = routing.api.request.Options;
    const correct = &.{ "AB", "BD", "DE", "EC" };
    var avoid = [_]routing.api.request.Location{.{ .lat = middle.lat, .lng = middle.lng, .minimum_reachability = 0 }};
    const inputs = [_]Cases{
        .{ .exclude_polygons = &.{ring} },
        .{ .exclude_polygons = &.{.{ .points = ring.points, .levels = &.{2} }} },
        .{ .exclude_locations = &avoid },
    };
    for (inputs) |options| {
        const excluded = try routing.snap.exclusions.resolve(view, a, &options, &.{}, .{}, routing.snap.candidates.Access{ .mask = .{ .auto = true } }, .none);
        try testing.expectEqual(2, excluded.len);
        for (excluded) |edge| try testing.expect(edge.id == bc or edge.id == cb);
        for ([_]search.Direction{ .forward, .reverse }) |direction| {
            const result = try engine.run(&arena, .{}, .{ .origin = from, .destination = to, .direction = direction, .excluded = excluded }, search.Zero{}, .{});
            try expectWayPath(view, &fixture, result, direction, correct);
            arena.reset();
        }
    }
    const other_level: Cases = .{ .exclude_polygons = &.{.{ .points = ring.points, .levels = &.{3} }} };
    const kept = try routing.snap.exclusions.resolve(view, a, &other_level, &.{}, .{}, routing.snap.candidates.Access{ .mask = .{ .auto = true } }, .none);
    try testing.expectEqual(0, kept.len);
    const result = try engine.run(&arena, .{}, .{ .origin = from, .destination = to }, search.Zero{}, .{});
    try expectWayPath(view, &fixture, result, .forward, &.{ "AB", "BC" });
    arena.reset();

    const endpoints = routing.search.endpoints;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const ce = try directedBetween(view, &fixture, "C", "E");
    const start = snapLocation(&.{snapEdge(ab, 0.25, 0)}, &.{});
    const before = snapLocation(&.{snapEdge(bc, 0.25, 0)}, &.{});
    const after = snapLocation(&.{snapEdge(bc, 0.75, 0)}, &.{});
    const finish = snapLocation(&.{snapEdge(ce, 0.5, 0)}, &.{});
    const excluded = &[_]search.ExcludedEdge{.{ .id = bc, .percent_along = 0.5 }};
    const same_node = try engine.run(&arena, .{}, .{ .origin = from, .destination = from, .excluded = excluded }, search.Zero{}, .{});
    try testing.expectEqual(@as(f32, 0), same_node.best().cost);
    arena.reset();
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const opts: endpoints.Options = .{ .costing = .auto, .direction = direction, .excluded = excluded };
        const arrives = try endpoints.route(&engine, &arena, RestrictionMotor{}, start, before, opts, search.Zero{}, .{});
        try testing.expectEqual(@as(f32, 0.25), arrives.segments[arrives.segments.len - 1].end);
        arena.reset();
        try testing.expectError(error.NoPath, endpoints.route(&engine, &arena, RestrictionMotor{}, start, after, opts, search.Zero{}, .{}));
        arena.reset();
        const leaves = try endpoints.route(&engine, &arena, RestrictionMotor{}, after, finish, opts, search.Zero{}, .{});
        try testing.expectEqual(@as(f32, 0.75), leaves.segments[0].begin);
        arena.reset();
        try testing.expectError(error.NoPath, endpoints.route(&engine, &arena, RestrictionMotor{}, before, finish, opts, search.Zero{}, .{}));
        arena.reset();
    }
    counting.resetCounts();
    _ = try endpoints.route(&engine, &arena, RestrictionMotor{}, start, before, .{ .costing = .auto, .excluded = excluded }, search.Zero{}, .{});
    try testing.expectEqual(0, counting.calls());
    arena.reset();
    try checkGurkaClosure(view, &fixture, middle, from, to, .{ bc, cb });
}

fn restrictionTiming(text: []const u8, invariant: bool) !search.Timing {
    return .{ .start = try graph.time_info.TimeInfo.fromLocal(null, text, graph.timezone.utc, graph.timezone.utc, 0, .none), .invariant = invariant };
}

fn expectWayPath(view: *const graph.reader.View, fixture: *const gurka.Map, result: search.Result, direction: search.Direction, expected: []const []const u8) !void {
    var index = result.index;
    for (0..expected.len) |i| {
        try testing.expect(index != search.no_index);
        const label = result.labels[index];
        const position = if (direction == .forward) expected.len - 1 - i else i;
        try testing.expectEqual(@as(u64, @intCast(fixture.findWay(expected[position]).?.id)), try view.wayId(label.edgeId()));
        index = label.pred;
    }
    try testing.expectEqual(search.no_index, index);
}

// Ported from test/gurka/test_time_dependent_restrictions.cc (Valhalla 3.9.3).
test "Gurka timed turn conditions switch the legal movement only within the window" {
    for ([_]bool{ false, true }) |only| {
        var storage: std.heap.ArenaAllocator = .init(testing.allocator);
        defer storage.deinit();
        const fixture = try @import("examples.zig").timedTurns(storage.allocator(), only);
        var built = try Built.assemble(fixture.osm, 2);
        defer built.deinit();
        const view = &built.bundle.view;
        try view.verify(.none, null);
        try testing.expect(view.restriction_conditions != null);
        try testing.expectEqual(1, built.stats.simple_turns.resolved);
        try testing.expectEqual(0, built.stats.simple_turns.deferred);
        const a = try at(view, fixture.findNode("A").?.location.toFixed());
        const finish = try at(view, fixture.findNode(if (only) "D" else "F").?.location.toFixed());
        const first = try directedBetween(view, &fixture, "A", "B");
        const last = try directedBetween(view, &fixture, if (only) "B" else "C", if (only) "D" else "F");
        var engine = try RestrictionSearch.init(testing.allocator, view);
        defer engine.deinit();
        var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
        defer arena.deinit();
        const cases = [_]struct { text: []const u8, active: bool }{
            .{ .text = "", .active = false },
            .{ .text = "2021-04-02T06:30", .active = false },
            .{ .text = "2021-04-02T14:00", .active = true },
            .{ .text = "2021-04-02T19:20", .active = false },
        };
        for (cases) |case| {
            for ([_]search.Direction{ .forward, .reverse }) |direction| {
                for ([_]bool{ false, true }) |invariant| {
                    errdefer std.debug.print("\nonly={any} date={s} direction={s} invariant={any}\n", .{ only, case.text, @tagName(direction), invariant });
                    const request: search.Request = .{ .origin = a, .destination = finish, .direction = direction, .timing = try restrictionTiming(case.text, invariant) };
                    const result = try engine.run(&arena, .{}, request, search.Zero{}, .{});
                    const path: []const []const u8 = if (only)
                        (if (case.active) &.{ "AB", "BC", "EC", "DE" } else &.{ "AB", "BD" })
                    else if (case.active)
                        &.{ "AB", "BD", "DE", "EC", "CF" }
                    else
                        &.{ "AB", "BC", "CF" };
                    try expectWayPath(view, &fixture, result, direction, path);
                    arena.reset();
                    if (!only) {
                        const endpoints = routing.search.endpoints;
                        const options: endpoints.Options = .{ .costing = .auto, .direction = direction, .timing = request.timing };
                        const from = snapLocation(&.{snapEdge(first, 0.25, 0)}, &.{});
                        const to = snapLocation(&.{snapEdge(last, 0.75, 0)}, &.{});
                        const partial = try endpoints.route(&engine, &arena, RestrictionMotor{}, from, to, options, search.Zero{}, .{});
                        try testing.expectEqual(path.len, partial.segments.len);
                        for (partial.segments, path) |segment, way| {
                            try testing.expectEqual(@as(u64, @intCast(fixture.findWay(way).?.id)), try view.wayId(segment.edge));
                        }
                        try testing.expectEqual(@as(f32, 0.25), partial.segments[0].begin);
                        try testing.expectEqual(@as(f32, 0.75), partial.segments[partial.segments.len - 1].end);
                        arena.reset();
                    }
                    if (only and case.active) {
                        const bicycle = try engine.run(&arena, .{ .modes = 4 }, request, search.Zero{}, .{});
                        try expectWayPath(view, &fixture, bicycle, direction, &.{ "AB", "BD" });
                        arena.reset();
                    }
                }
            }
        }
        if (!only) {
            const memory = storage.allocator();
            const bytes = try io.readFileAlloc(memory, "src/graph/timezones/iana-2026f.ztz", 4 << 20);
            const aligned = try memory.alignedAlloc(u8, .@"8", bytes.len);
            @memcpy(aligned, bytes);
            const rules = try graph.timezone.Rules.parse(aligned);
            const zones = try memory.alloc(graph.timezone.Id, view.nodes.len);
            @memset(zones, graph.timezone.utc);
            zones[(try view.edge(first)).head] = try rules.id("America/Los_Angeles");
            var zoned = view.*;
            zoned.node_timezones = zones;
            zoned.tz_rules = rules;
            var zoned_engine = try RestrictionSearch.init(testing.allocator, &zoned);
            defer zoned_engine.deinit();
            const zoned_cases = [_]struct { utc: []const u8, path: []const []const u8 }{
                .{ .utc = "2021-04-02T11:00", .path = &.{ "AB", "BC", "CF" } }, // 04:00 at B
                .{ .utc = "2021-04-02T17:00", .path = &.{ "AB", "BD", "DE", "EC", "CF" } }, // 10:00 at B
                .{ .utc = "2021-04-03T03:00", .path = &.{ "AB", "BC", "CF" } }, // 20:00 at B
            };
            for (zoned_cases) |case| {
                for ([_]search.Direction{ .forward, .reverse }) |direction| {
                    const result = try zoned_engine.run(&arena, .{}, .{
                        .origin = a,
                        .destination = finish,
                        .direction = direction,
                        .timing = try restrictionTiming(case.utc, false),
                    }, search.Zero{}, .{});
                    try expectWayPath(&zoned, &fixture, result, direction, case.path);
                    arena.reset();
                }
            }
        }
    }
}

// Ported from test/gurka/test_time_dependent_tags.cc (Valhalla 3.9.3).
test "Gurka legacy turn windows support hours, weekdays and wrapping dates" {
    const cases = [_]struct { tags: gurka.Tags, active: [5]bool = @splat(false) }{
        .{
            .tags = &.{ .{ .key = "restriction", .value = "no_left_turn" }, .{ .key = "hour_on", .value = "07:00" }, .{ .key = "hour_off", .value = "19:00" } },
            .active = .{ false, true, false, true, false },
        },
        .{
            .tags = &.{ .{ .key = "restriction", .value = "no_left_turn" }, .{ .key = "day_on", .value = "Monday" }, .{ .key = "day_off", .value = "Friday" } },
            .active = .{ true, true, true, false, false },
        },
        .{
            .tags = &.{
                .{ .key = "restriction", .value = "no_left_turn" }, .{ .key = "day_on", .value = "Monday" },  .{ .key = "day_off", .value = "Friday" },
                .{ .key = "hour_on", .value = "07:00" },            .{ .key = "hour_off", .value = "19:00" },
            },
            .active = .{ false, true, false, false, false },
        },
        .{
            .tags = &.{.{ .key = "restriction:conditional", .value = "no_left_turn @ (Apr 24-Apr 21 7:00-19:00)" }},
            .active = .{ false, false, false, true, false },
        },
        .{ .tags = &.{ .{ .key = "restriction", .value = "no_left_turn" }, .{ .key = "day_on", .value = "Thursday" } } },
        .{ .tags = &.{ .{ .key = "restriction", .value = "no_left_turn" }, .{ .key = "day_off", .value = "Thursday" } } },
        .{ .tags = &.{ .{ .key = "restriction", .value = "no_left_turn" }, .{ .key = "hour_on", .value = "07:00" } } },
        .{ .tags = &.{ .{ .key = "restriction", .value = "no_left_turn" }, .{ .key = "hour_off", .value = "19:00" } } },
    };
    const dates = [_][]const u8{ "2021-04-22T06:30", "2021-04-22T14:00", "2021-04-22T23:00", "2021-04-25T14:00", "2021-04-25T23:00" };
    for (cases) |case| {
        var storage: std.heap.ArenaAllocator = .init(testing.allocator);
        defer storage.deinit();
        const a = storage.allocator();
        const motorway: gurka.Tags = &.{.{ .key = "highway", .value = "motorway" }};
        const layout = try gurka.mapToCoordinates("D----B----A\n|    |\n|    |\nE----C----F", 10);
        const tags = try a.alloc(gurka.Tag, case.tags.len + 1);
        tags[0] = .{ .key = "type", .value = "restriction" };
        @memcpy(tags[1..], case.tags);
        const fixture = try gurka.Map.init(a, layout, &.{
            .{ .label = "AB", .tags = motorway }, .{ .label = "BC", .tags = motorway }, .{ .label = "BD", .tags = motorway },
            .{ .label = "CF", .tags = motorway }, .{ .label = "DE", .tags = motorway }, .{ .label = "EC", .tags = motorway },
        }, &.{}, &.{.{
            .tags = tags,
            .members = &.{ .{ .kind = .way, .ref = "AB", .role = "from" }, .{ .kind = .node, .ref = "B", .role = "via" }, .{ .kind = .way, .ref = "BC", .role = "to" } },
        }});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        const from = try at(view, fixture.findNode("A").?.location.toFixed());
        const to = try at(view, fixture.findNode("F").?.location.toFixed());
        var engine = try RestrictionSearch.init(testing.allocator, view);
        defer engine.deinit();
        var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
        defer arena.deinit();
        for (dates, case.active) |date, active| {
            const clock = try restrictionTiming(date, false);
            for ([_]search.Direction{ .forward, .reverse }) |direction| {
                const path = try engine.run(&arena, .{}, .{ .origin = from, .destination = to, .direction = direction, .timing = clock }, search.Zero{}, .{});
                try expectWayPath(view, &fixture, path, direction, if (active) &.{ "AB", "BD", "DE", "EC", "CF" } else &.{ "AB", "BC", "CF" });
                arena.reset();
            }
        }
    }
}

test "time-dependent search keeps distinct arrival times in both directions" {
    const TimedCost = struct {
        shortcut: format.EdgeId,
        start: u32,
        forward_gate: format.EdgeId,
        reverse_gate: format.EdgeId,

        pub fn edgeCost(self: @This(), view: *const graph.reader.View, id: format.EdgeId, edge: *const format.EdgeHot, _: search.Direction) !Cost {
            if (!(try view.class(edge.cls.class_id)).forwardAccess().auto) return .forbidden;
            return if (id == self.shortcut) .{ .cost = 1, .secs = 10 } else .{ .cost = 2, .secs = 40 };
        }

        pub fn edgeCostAt(self: @This(), view: *const graph.reader.View, id: format.EdgeId, edge: *const format.EdgeHot, direction: search.Direction, time: graph.time_info.TimeInfo) !search.Traversal {
            var cost = try self.edgeCost(view, id, edge, direction);
            const costly = switch (direction) {
                .forward => id == self.forward_gate and time.second_of_week < self.start + 160,
                .reverse => id == self.reverse_gate and time.second_of_week > self.start - 160,
            };
            if (cost.cost != std.math.inf(f32) and costly) cost.cost += 50;
            return .{ .cost = cost };
        }

        pub fn turnCost(_: @This(), _: *const graph.reader.View, _: search.Transition, _: search.Label, _: search.Direction) !Cost {
            return .{};
        }
    };
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road: gurka.Tags = &.{ .{ .key = "highway", .value = "residential" }, .{ .key = "oneway", .value = "yes" } };
    const layout = try gurka.mapToCoordinates(
        \\A--V--W-----X--Y--Z
        \\      |    /
        \\      B----
    , 10);
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AV", .tags = road },
        .{ .label = "VW", .tags = road },
        .{ .label = "WX", .tags = road },
        .{ .label = "WB", .tags = road },
        .{ .label = "BX", .tags = road },
        .{ .label = "XY", .tags = road },
        .{ .label = "YZ", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const from = try at(view, fixture.findNode("A").?.location.toFixed());
    const to = try at(view, fixture.findNode("Z").?.location.toFixed());
    const timing = try restrictionTiming("2026-11-02T12:00", false);
    const kernel: TimedCost = .{
        .shortcut = try directedBetween(view, &fixture, "W", "X"),
        .start = timing.start.second_of_week,
        .forward_gate = try directedBetween(view, &fixture, "Y", "Z"),
        .reverse_gate = try directedBetween(view, &fixture, "A", "V"),
    };
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try search.Search(TimedCost, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        var request: search.Request = .{ .origin = from, .destination = to, .direction = direction };
        const untimed = try engine.run(&arena, kernel, request, search.Zero{}, .{});
        try expectWayPath(view, &fixture, untimed, direction, &.{ "AV", "VW", "WX", "XY", "YZ" });
        arena.reset();
        request.timing = timing;
        const timed = try engine.run(&arena, kernel, request, search.Zero{}, .{});
        try expectWayPath(view, &fixture, timed, direction, &.{ "AV", "VW", "WB", "BX", "XY", "YZ" });
        try testing.expectEqual(@as(f32, 12), timed.best().cost);
        arena.reset();
        request.timing.invariant = true;
        const invariant = try engine.run(&arena, kernel, request, search.Zero{}, .{});
        try expectWayPath(view, &fixture, invariant, direction, &.{ "AV", "VW", "WX", "XY", "YZ" });
        arena.reset();
    }
}

test "via-way relation annotations follow the pinned untimed representation" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    var fixture = try @import("examples.zig").multiViaTurns(a);
    const relations = try a.dupe(gurka.OsmRelation, fixture.osm.relations);
    const tags = try a.alloc(gurka.Tag, relations[0].tags.len + 1);
    @memcpy(tags[0 .. tags.len - 1], relations[0].tags);
    tags[tags.len - 1] = .{ .key = "restriction:conditional", .value = "no_straight_on @ (Mo-Fr 07:00-19:00)" };
    relations[0].tags = tags;
    fixture.osm.relations = relations;
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try testing.expect(view.restriction_conditions == null);
    const states = view.restriction_automaton orelse return error.MissingTestRestriction;
    var ordinary: usize = 0;
    for (states) |state| {
        if (state.attr.forbidden & 1 != 0) ordinary += 1;
    }
    try testing.expectEqual(2, ordinary);
}

test "probable via ways use the mode mask and threshold without a clock" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    var fixture = try @import("examples.zig").multiViaTurns(a);
    const relations = try a.dupe(gurka.OsmRelation, fixture.osm.relations);
    relations[0].tags = &.{
        .{ .key = "type", .value = "restriction" },
        .{ .key = "restriction:probable", .value = "no_straight_on @ probability=75" },
        .{ .key = "except", .value = "bus" },
    };
    fixture.osm.relations = relations;
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try view.verify(.none, null);
    const conditions = view.restriction_conditions orelse return error.MissingTestRestriction;
    try testing.expectEqual(2, conditions.len);
    const bus: u16 = @bitCast(graph.constants.AccessMask{ .bus = true });
    for (conditions) |condition| {
        try testing.expectEqual(75, condition.attr.probability);
        try testing.expectEqual(0, condition.domain);
        try testing.expectEqual(0, condition.attr.modes & bus);
    }
    const from = try at(view, fixture.findNode("A").?.location.toFixed());
    const to = try at(view, fixture.findNode("E").?.location.toFixed());
    var engine = try RestrictionSearch.init(testing.allocator, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const request: search.Request = .{ .origin = from, .destination = to, .direction = direction };
        for ([_]RestrictionMotor{ .{ .probability = 0 }, .{ .probability = 75 }, .{ .probability = 76 }, .{ .probability = 75, .modes = bus } }) |kernel| {
            const result = try engine.run(&arena, kernel, request, search.Zero{}, .{});
            const blocked = kernel.modes != bus and kernel.probability == 75;
            try expectWayPath(view, &fixture, result, direction, if (blocked)
                &.{ "AX", "XY", "YC", "CD", "DE" }
            else
                &.{ "AB", "BMC", "BMC", "CD", "DE" });
            arena.reset();
        }
    }
}

// Ported from test/gurka/test_conditional_restrictions.cc.
test "Gurka conditional access distinguishes unknown time, modes and destination traffic" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const fixture = try @import("examples.zig").conditionalAccess(storage.allocator());
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try view.verify(.none, null);
    const ab = try directedBetween(view, &fixture, "A", "B");
    try testing.expect((try view.coldRecord(ab)).access_limits.len > 17);
    const all = try directedBetween(view, &fixture, "S", "T");
    const all_class = try view.class((try view.edge(all)).cls.class_id);
    try testing.expectEqual(4095, all_class.detail.access_restriction);
    try testing.expectEqual(1, (try view.edge(all)).cls.cold_checks);
    var engine = try RestrictionSearch.init(testing.allocator, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();

    const cases = [_]struct {
        from: []const u8,
        to: []const u8,
        date: []const u8,
        modes: u16 = 1,
        path: ?[]const []const u8,
        forward_only: bool = false,
    }{
        .{ .from = "A", .to = "E", .date = "", .path = &.{ "AB", "BC", "CE" } },
        .{ .from = "A", .to = "E", .date = "2020-04-15T06:00", .path = &.{ "AB", "BC", "CE" } },
        .{ .from = "A", .to = "E", .date = "2020-04-02T12:00", .path = &.{ "AB", "BC", "CE" }, .forward_only = true },
        .{ .from = "A", .to = "E", .date = "", .modes = 4, .path = &.{ "AD", "DE" } },
        .{ .from = "A", .to = "E", .date = "2020-04-02T12:00", .modes = 4, .path = &.{ "AD", "DE" }, .forward_only = true },
        .{ .from = "A", .to = "E", .date = "2020-04-02T20:00", .modes = 4, .path = null, .forward_only = true },
        .{ .from = "A", .to = "E", .date = "", .modes = 2, .path = &.{ "AD", "DE" } },
        .{ .from = "A", .to = "E", .date = "2020-04-02T20:00", .modes = 2, .path = &.{ "AD", "DE" }, .forward_only = true },
        .{ .from = "A", .to = "E", .date = "2020-04-02T12:00", .modes = 2, .path = null, .forward_only = true },
        .{ .from = "F", .to = "I", .date = "2020-04-04T20:00", .path = &.{ "FG", "GH", "HI" } },
        .{ .from = "F", .to = "I", .date = "2020-04-04T12:00", .path = &.{ "FG", "GH", "HI" } },
        .{ .from = "F", .to = "J", .date = "2020-04-04T20:00", .path = &.{ "FG", "GH", "HI", "IJ" } },
        .{ .from = "F", .to = "J", .date = "2020-04-04T12:00", .path = &.{ "FG", "GH", "HI", "IJ" } },
        .{ .from = "I", .to = "L", .date = "2020-04-04T20:00", .path = &.{ "IJ", "JM", "MN", "NK", "KL" } },
        .{ .from = "I", .to = "L", .date = "2020-04-04T12:00", .path = &.{ "IJ", "JK", "KL" } },
    };
    for (cases) |case| {
        errdefer std.debug.print("\n{s} to {s}, {s}, mode {d}\n", .{ case.from, case.to, case.date, case.modes });
        const origin = try at(view, fixture.findNode(case.from).?.location.toFixed());
        const destination = try at(view, fixture.findNode(case.to).?.location.toFixed());
        for ([_]search.Direction{ .forward, .reverse }) |direction| {
            // These pinned cases supply departure time. The other cases exercise both directions.
            if (case.forward_only and direction == .reverse) continue;
            const request: search.Request = .{ .origin = origin, .destination = destination, .direction = direction, .timing = try restrictionTiming(case.date, false) };
            const kernel: RestrictionMotor = .{ .modes = case.modes, .destination_penalty = if (case.modes == 1) 2000 else 0 };
            const result = engine.run(&arena, kernel, request, search.Zero{}, .{});
            if (case.path) |expected| {
                try expectWayPath(view, &fixture, try result, direction, expected);
            } else try testing.expectError(error.NoPath, result);
            arena.reset();
        }
    }
    const r = try at(view, fixture.findNode("R").?.location.toFixed());
    const u = try at(view, fixture.findNode("U").?.location.toFixed());
    for ([_]u16{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024 }) |mode| {
        for ([_]search.Direction{ .forward, .reverse }) |direction| {
            var request: search.Request = .{ .origin = r, .destination = u, .direction = direction };
            const kernel: RestrictionMotor = .{ .modes = mode, .ignore_access = true };
            const expected = &.{ "RS", "ST", "TU" };
            const unknown = try engine.run(&arena, kernel, request, search.Zero{}, .{});
            try expectWayPath(view, &fixture, unknown, direction, expected);
            arena.reset();
            request.timing = try restrictionTiming("2020-04-02T12:00", false);
            const outside = try engine.run(&arena, kernel, request, search.Zero{}, .{});
            try expectWayPath(view, &fixture, outside, direction, expected);
            arena.reset();
            request.timing = try restrictionTiming("2020-04-02T20:00", false);
            try testing.expectError(error.NoPath, engine.run(&arena, kernel, request, search.Zero{}, .{}));
            arena.reset();
            const ignored = try engine.run(&arena, .{ .modes = mode, .ignore = true, .ignore_access = true }, request, search.Zero{}, .{});
            try expectWayPath(view, &fixture, ignored, direction, expected);
            arena.reset();
        }
    }
    try checkTimedDeadEnd(view, &fixture);
}

const ExpansionProbe = struct {
    target: format.NodeId,
    edge: ?format.EdgeId = null,
    cost: ?f32 = null,
    arrivals: usize = 0,

    pub fn visit(self: *ExpansionProbe, event: search.ExpansionVisit) !search.ExpansionDecision {
        if (event.node == self.target and self.cost == null) self.cost = event.label.cost;
        if (self.edge != null and self.edge.? == event.label.edgeId()) self.arrivals += 1;
        return .expand;
    }
};

fn checkTimedDeadEnd(view: *const graph.reader.View, fixture: *const gurka.Map) !void {
    const tu = try directedBetween(view, fixture, "T", "U");
    const ut = try view.oppEdge(tu);
    try testing.expect((try view.class((try view.edge(tu)).cls.class_id)).flags.dead_end);
    try testing.expect(!(try view.class((try view.edge(ut)).cls.class_id)).flags.dead_end);

    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try RestrictionSearch.init(testing.allocator, view);
    defer engine.deinit();
    const origin = try at(view, fixture.findNode("R").?.location.toFixed());
    const destination = try at(view, fixture.findNode("U").?.location.toFixed());
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        var request: search.Request = .{ .origin = origin, .destination = destination, .direction = direction };
        const from = if (direction == .forward) origin else destination;
        const to = if (direction == .forward) destination else origin;
        request.timing = try restrictionTiming("2026-03-09T06:00", false);
        try testing.expectError(error.NoPath, engine.run(&arena, .{}, request, search.Zero{}, .{}));
        arena.reset();
        var blocked: ExpansionProbe = .{ .target = to };
        const expansion_request: search.ExpansionRequest = .{ .origins = &.{from}, .direction = direction, .timing = request.timing };
        _ = try engine.expand(&arena, .{}, expansion_request, &blocked, .{});
        try testing.expectEqual(@as(?f32, null), blocked.cost);
        arena.reset();
        request.timing = try restrictionTiming("2026-01-12T08:00", false);
        const open = try engine.run(&arena, .{}, request, search.Zero{}, .{});
        try expectWayPath(view, fixture, open, direction, &.{ "RS", "ST", "TU" });
        const expected = open.best().cost;
        arena.reset();
        var reachable: ExpansionProbe = .{ .target = to };
        var timed = expansion_request;
        timed.timing = request.timing;
        _ = try engine.expand(&arena, .{}, timed, &reachable, .{});
        try testing.expectEqual(expected, reachable.cost.?);
        arena.reset();
        try testing.expectError(error.Cancelled, engine.expand(&arena, .{}, timed, &reachable, .{ .deadline = .{ .at_ns = 0 } }));
    }
}

// Ported from test/gurka/test_only_restrictions.cc (Valhalla 3.9.3).
test "Gurka complex only turns forbid leaving every prefix in both searches" {
    const examples = @import("examples.zig");
    for (std.enums.values(examples.OnlyTurns)) |scenario| {
        var storage: std.heap.ArenaAllocator = .init(testing.allocator);
        defer storage.deinit();
        const fixture = try examples.onlyTurns(storage.allocator(), scenario);
        var built = try Built.assemble(fixture.osm, 2);
        defer built.deinit();
        const view = &built.bundle.view;
        try view.verify(.none, null);
        try testing.expect(view.restriction_automaton != null);
        var engine = try RestrictionSearch.init(testing.allocator, view);
        defer engine.deinit();
        var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
        defer arena.deinit();
        const cases = switch (scenario) {
            .straight => "ABCDEF",
            .one_neighbour => "BCDE1",
            .many_neighbours => "ABCDEF12345",
        };
        for (cases) |from| {
            for (cases) |to| {
                if (from == to) continue;
                const blocked = switch (scenario) {
                    .straight => false,
                    .one_neighbour => from == 'B' and to == '1',
                    .many_neighbours => (from == 'A' or from == 'B') and std.ascii.isDigit(to),
                };
                if (!blocked and scenario != .straight and to != 'E') continue;
                const origin = try at(view, fixture.findNode(&.{from}).?.location.toFixed());
                const destination = try at(view, fixture.findNode(&.{to}).?.location.toFixed());
                for ([_]search.Direction{ .forward, .reverse }) |direction| {
                    const request: search.Request = .{ .origin = origin, .destination = destination, .direction = direction };
                    const result = engine.run(&arena, .{}, request, search.Zero{}, .{});
                    if (blocked) {
                        try testing.expectError(error.NoPath, result);
                        _ = try engine.run(&arena, .{ .ignore = true }, request, search.Zero{}, .{});
                    } else {
                        try testing.expect((try result).best().cost > 0);
                    }
                    arena.reset();
                }
            }
        }
    }
}

test "Gurka split via ways preserve a more expensive legal label on the same edge" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const fixture = try @import("examples.zig").multiViaTurns(storage.allocator());
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try view.verify(.none, null);
    const states = view.restriction_automaton orelse return error.MissingTestRestriction;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const ax = try directedBetween(view, &fixture, "A", "X");
    const bm = try directedBetween(view, &fixture, "B", "M");
    const mc = try directedBetween(view, &fixture, "M", "C");
    const cd = try directedBetween(view, &fixture, "C", "D");
    const de = try directedBetween(view, &fixture, "D", "E");
    const first = try view.class((try view.edge(ab)).cls.class_id);
    const last = try view.class((try view.edge(de)).cls.class_id);
    try testing.expect(first.restrictions.start & 1 != 0 and last.restrictions.end & 1 != 0);
    try testing.expect(first.restrictions.start & 4 == 0 and last.restrictions.end & 4 == 0);
    var complete: usize = 0;
    for (states) |state| {
        if (state.attr.forbidden & 1 != 0) {
            try testing.expectEqual(5, state.attr.depth);
            complete += 1;
        }
    }
    try testing.expectEqual(2, complete);
    const origin = try at(view, fixture.findNode("A").?.location.toFixed());
    const destination = try at(view, fixture.findNode("E").?.location.toFixed());
    var engine = try RestrictionSearch.init(testing.allocator, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    const endpoints = routing.search.endpoints;
    const from = snapLocation(&.{snapEdge(ab, 0.25, 0)}, &.{});
    const midway = snapLocation(&.{snapEdge(cd, 0.75, 0)}, &.{});
    const after = snapLocation(&.{snapEdge(de, 0.75, 0)}, &.{});
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const request: search.Request = .{ .origin = origin, .destination = destination, .direction = direction };
        const limited = try engine.run(&arena, .{}, request, search.Zero{}, .{});
        const cost = limited.best().cost;
        var at_label = limited.best();
        while (at_label.pred != search.no_index and direction == .forward) at_label = &limited.labels[at_label.pred];
        try testing.expectEqual(ax, at_label.edgeId());
        arena.reset();
        var probe: ExpansionProbe = .{
            .target = if (direction == .forward) destination else origin,
            .edge = if (direction == .forward) cd else null,
        };
        _ = try engine.expand(&arena, .{}, .{
            .origins = &.{if (direction == .forward) origin else destination},
            .direction = direction,
        }, &probe, .{});
        try testing.expectEqual(cost, probe.cost.?);
        if (direction == .forward) try testing.expect(probe.arrivals >= 2);
        arena.reset();
        const ignored = try engine.run(&arena, .{ .ignore = true }, request, search.Zero{}, .{});
        try testing.expect(ignored.best().cost < cost);
        arena.reset();
        const bicycle = try engine.run(&arena, .{ .modes = 4 }, request, search.Zero{}, .{});
        try testing.expect(bicycle.best().cost < cost);
        arena.reset();
        const options: endpoints.Options = .{ .costing = .auto, .direction = direction };
        const partial = try endpoints.route(&engine, &arena, RestrictionMotor{}, from, midway, options, search.Zero{}, .{});
        try testing.expectEqualSlices(endpoints.Segment, &.{
            .{ .edge = ab, .begin = 0.25, .end = 1 },
            .{ .edge = bm, .begin = 0, .end = 1 },
            .{ .edge = mc, .begin = 0, .end = 1 },
            .{ .edge = cd, .begin = 0, .end = 0.75 },
        }, partial.segments);
        arena.reset();
        try testing.expectError(error.NoPath, endpoints.route(&engine, &arena, RestrictionMotor{}, from, after, options, search.Zero{}, .{}));
        arena.reset();
    }
}

test "turn restriction history crosses junction aliases without steady-state heap calls" {
    const leaf_count = 34;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const nodes = try a.alloc(gurka.OsmNode, leaf_count + 2);
    for (nodes, 0..) |*node, i| {
        node.* = .{
            .id = @intCast(i + 1),
            .label = "",
            .location = .{ .lat = 0, .lng = @as(f64, @floatFromInt(i)) * 0.001 },
            .tags = &.{},
        };
    }
    const tags: gurka.Tags = &.{ .{ .key = "highway", .value = "primary" }, .{ .key = "oneway", .value = "yes" } };
    const ways = try a.alloc(gurka.OsmWay, leaf_count + 1);
    for (ways[0..leaf_count], nodes[1 .. leaf_count + 1], 0..) |*way, node, i| {
        const refs: [2]i64 = if (i == 0) .{ node.id, nodes[0].id } else .{ nodes[0].id, node.id };
        way.* = .{ .id = @intCast(i + 1), .label = "", .tags = tags, .refs = try a.dupe(i64, &refs) };
    }
    ways[leaf_count] = .{ .id = leaf_count + 1, .label = "", .tags = tags, .refs = &.{ leaf_count + 1, leaf_count + 2 } };
    for ([_]bool{ false, true }) |node_via| {
        var built = try Built.assemble(.{ .nodes = nodes, .ways = ways, .relations = &.{.{
            .id = 1,
            .members = &.{
                .{ .kind = .way, .id = 1, .role = "from" },
                .{ .kind = if (node_via) .node else .way, .id = if (node_via) 1 else leaf_count, .role = "via" },
                .{ .kind = .way, .id = if (node_via) leaf_count else leaf_count + 1, .role = "to" },
            },
            .tags = &.{ .{ .key = "type", .value = "restriction" }, .{ .key = if (node_via) "restriction:motorcar" else "restriction", .value = "no_right_turn" } },
        }} }, 2);
        defer built.deinit();
        const view = &built.bundle.view;
        try testing.expectEqual(1, built.stats.connectors);
        try testing.expect(if (node_via) view.turn_restrictions != null else view.restriction_automaton != null);
        const origin = try at(view, nodes[1].location.toFixed());
        const destination = try at(view, nodes[nodes.len - 1].location.toFixed());
        var counting = routing.infra.arena.CountingAllocator.init(testing.allocator);
        var engine = try RestrictionSearch.init(counting.allocator(), view);
        defer engine.deinit();
        var arena = routing.infra.arena.Arena.init(counting.allocator(), .{});
        defer arena.deinit();
        for (0..3) |round| {
            if (round == 1) counting.resetCounts();
            for ([_]search.Direction{ .forward, .reverse }) |direction| {
                const request: search.Request = .{ .origin = origin, .destination = destination, .direction = direction };
                try testing.expectError(error.NoPath, engine.run(&arena, .{}, request, search.Zero{}, .{}));
                arena.reset();
                const expansion_request: search.ExpansionRequest = .{
                    .origins = &.{if (direction == .forward) origin else destination},
                    .direction = direction,
                };
                var probe: ExpansionProbe = .{ .target = if (direction == .forward) destination else origin };
                _ = try engine.expand(&arena, .{}, expansion_request, &probe, .{});
                try testing.expectEqual(@as(?f32, null), probe.cost);
                arena.reset();
                _ = try engine.expand(&arena, .{ .ignore = true }, expansion_request, &probe, .{});
                try testing.expect(probe.cost != null);
                arena.reset();
                const path = try engine.run(&arena, .{ .ignore = true }, request, search.Zero{}, .{});
                var label = path.best();
                var crossed = false;
                while (label.pred != search.no_index) : (label = &path.labels[label.pred]) {
                    const edge = try view.edge(label.edgeId());
                    crossed = crossed or (try view.class(edge.cls.class_id)).flags.node_connector;
                }
                try testing.expect(crossed);
                arena.reset();
            }
        }
        try testing.expectEqual(0, counting.calls());
    }
}

test "country defaults apply within borders and preserve explicitly tagged modes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").countryAccess(arena.allocator());
    var built = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .workers = 2, .drive_side = .left });
    defer built.deinit();
    const view = &built.bundle.view;
    const qr = try directedBetween(view, &fixture, "Q", "R");
    const uv = try directedBetween(view, &fixture, "U", "V");
    const st = try directedBetween(view, &fixture, "S", "T");
    const rs = try directedBetween(view, &fixture, "R", "S");
    const wx = try directedBetween(view, &fixture, "W", "X");
    const cycleway = try view.class((try view.edge(qr)).cls.class_id);
    try testing.expectEqual(774, cycleway.access.forward);
    try testing.expectEqual(774, cycleway.access.reverse);
    const oneway = try view.class((try view.edge(uv)).cls.class_id);
    try testing.expectEqual(774, oneway.access.forward);
    try testing.expectEqual(258, oneway.access.reverse);

    const trunk = try view.class((try view.edge(st)).cls.class_id);
    const trunk_access: graph.constants.AccessMask = @bitCast(trunk.access.forward);
    try testing.expect(trunk_access.pedestrian and trunk_access.wheelchair and !trunk_access.bicycle and !trunk_access.moped);
    try testing.expect(!trunk.flags.country_crossing);
    const crossing = try view.class((try view.edge(rs)).cls.class_id);
    const opposing = try view.class((try view.edge(try view.oppEdge(rs))).cls.class_id);
    const crossing_access: graph.constants.AccessMask = @bitCast(crossing.access.forward);
    try testing.expect(crossing.flags.country_crossing and opposing.flags.country_crossing and crossing_access.bicycle);
    const motorroad = try view.class((try view.edge(wx)).cls.class_id);
    const motorroad_access: graph.constants.AccessMask = @bitCast(motorroad.access.forward);
    try testing.expect(!motorroad_access.pedestrian and !motorroad_access.bicycle and !motorroad_access.moped);
    const q = try at(view, fixture.findNode("Q").?.location.toFixed());
    try testing.expect(!(try view.node(q)).attr.drive_on_left);

    var disabled = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .apply_country_overrides = false });
    defer disabled.deinit();
    const other = &disabled.bundle.view;
    const other_cycleway = try other.class((try other.edge(try directedBetween(other, &fixture, "Q", "R"))).cls.class_id);
    try testing.expectEqual(516, other_cycleway.access.forward);
    const other_border = try other.class((try other.edge(try directedBetween(other, &fixture, "R", "S"))).cls.class_id);
    try testing.expect(other_border.flags.country_crossing);
}

test "assembled admin assignments follow stitched boundaries, holes and islands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").adminBoundaries(arena.allocator());
    var result = try Built.assemble(fixture.osm, 4);
    defer result.deinit();
    const view = &result.bundle.view;
    try view.verify(.none, null);
    try testing.expectEqual(3, view.admin_index.?.regions.len);
    const cases = [_]struct { label: []const u8, iso: []const u8, state: []const u8, left: bool }{
        .{ .label = "Q", .iso = "GB", .state = "TST", .left = true },
        .{ .label = "S", .iso = "BE", .state = "", .left = false },
        .{ .label = "U", .iso = "GB", .state = "", .left = true },
        .{ .label = "W", .iso = "GB", .state = "", .left = true },
    };
    for (cases) |case| {
        const point = fixture.findNode(case.label).?.location;
        const id = try at(view, point.toFixed());
        const area = try view.nodeAdmin(id);
        try testing.expectEqualStrings(case.iso, area.country_iso);
        try testing.expectEqualStrings(case.state, area.state_iso);
        // Valhalla gives W its tile's sole region. The point is outside the polygon.
        const at_point = try view.adminAt(point, .none);
        if (std.mem.eql(u8, case.label, "W"))
            try testing.expectEqualStrings("", at_point.country_iso)
        else
            try testing.expectEqualDeep(area, at_point);
        try testing.expectEqual(case.left, (try view.node(id)).attr.drive_on_left);
    }
    try testing.expectEqualStrings("TST", (try view.adminAt(.init(2, 44.6), .none)).state_iso);
    try testing.expectEqualStrings("GB", (try view.adminAt(.init(4, 44.6), .none)).country_iso);
    try testing.expectEqualStrings("", (try view.adminAt(.init(4, 45.1), .none)).country_iso);
}

test "driving side follows admin mode, tagged ways and the configured fallback" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").drivingSide(arena.allocator());
    const cases = [_]struct { options: build.assemble.Options, left: [3]bool, forward_left: bool }{
        .{ .options = .{ .scratch_dir = "" }, .left = .{ true, true, true }, .forward_left = true },
        .{ .options = .{ .scratch_dir = "", .drive_side = .right }, .left = .{ false, false, false }, .forward_left = false },
        .{ .options = .{ .scratch_dir = "", .use_admin_db = false }, .left = .{ true, false, false }, .forward_left = true },
    };
    for (cases) |case| {
        var result = try Built.assembleWithOptions(fixture.osm, case.options);
        defer result.deinit();
        const view = &result.bundle.view;
        for ([_][]const u8{ "A", "B", "C" }, case.left) |label, expected| {
            const node = try at(view, fixture.findNode(label).?.location.toFixed());
            try testing.expectEqual(expected, (try view.node(node)).attr.drive_on_left);
        }
        const arc = try view.edge(try directedBetween(view, &fixture, "A", "B"));
        const forward = try view.class(arc.cls.class_id);
        const cycle_lane: graph.constants.CycleLane = if (case.forward_left) .separated else .dedicated;
        try testing.expectEqual(@backingInt(cycle_lane), forward.category.cycle_lane);
        try testing.expectEqual(!case.forward_left, forward.flags.shoulder);
    }
}

// Ported from test/gurka/test_hov.cc (HOV2Test, HOV3Test and HOTTest).
test "decoded motorway classes admit the requested HOV or toll variant" {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const motorway = [_]gurka.Tag{
        .{ .key = "highway", .value = "motorway" },
        .{ .key = "oneway", .value = "yes" },
    };
    const hov = motorway ++ [_]gurka.Tag{.{ .key = "hov", .value = "designated" }};
    const fixture = try gurka.Map.init(arena, try gurka.mapToCoordinates(
        \\A-------------------C
        \\D-------------------F
        \\G-------------------I
        \\J-------------------L
    , 10), &.{
        .{ .label = "AC", .tags = &motorway },
        .{ .label = "DF", .tags = &(hov ++ [_]gurka.Tag{.{ .key = "hov:minimum", .value = "2" }}) },
        .{ .label = "GI", .tags = &(hov ++ [_]gurka.Tag{.{ .key = "hov:minimum", .value = "3" }}) },
        .{ .label = "JL", .tags = &(hov ++ [_]gurka.Tag{
            .{ .key = "hov:minimum", .value = "3" },
            .{ .key = "toll", .value = "yes" },
        }) },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 4);
    defer built.deinit();
    const view = &built.bundle.view;
    const auto = routing.costing.auto;
    const cases = [_]struct { body: []const u8, allowed: [4]bool }{
        .{ .body = "{\"costing\":\"auto\"}", .allowed = .{ true, false, false, false } },
        .{ .body = "{\"costing\":\"auto\",\"costing_options\":{\"auto\":{\"include_hov2\":true}}}", .allowed = .{ true, true, false, false } },
        .{ .body = "{\"costing\":\"auto\",\"costing_options\":{\"auto\":{\"include_hov3\":true}}}", .allowed = .{ true, true, true, true } },
        .{ .body = "{\"costing\":\"auto\",\"costing_options\":{\"auto\":{\"include_hot\":true}}}", .allowed = .{ true, false, false, true } },
        .{ .body = "{\"costing\":\"hov\",\"costing_options\":{\"hov\":{\"include_hov2\":false}}}", .allowed = .{ true, true, false, false } },
    };
    for (cases) |case| {
        const request = (try routing.api.request.parseHttp(arena, "/route", &.{}, case.body)).ok;
        try testing.expectEqual(.auto, request.costing);
        const config = if (request.costing_options) |settings| routing.api.json.pointer(settings, "/auto") orelse .null else .null;
        var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
        const profile = try auto.Model.canonicalize(try auto.parse(arena, .auto, config, &warnings, .none));
        for ([_][]const u8{ "AC", "DF", "GI", "JL" }, case.allowed) |labels, allowed| {
            const id = try directedBetween(view, &fixture, labels[0..1], labels[1..2]);
            const edge = try view.edge(id);
            const class = try view.class(edge.cls.class_id);
            try testing.expectEqual(allowed, profile.allowedCandidate(class, .{}, .{}, false));
        }
    }
}

test "assembled motor vehicle limits follow the original way direction" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").motorVehicle(arena.allocator());
    var result = try Built.assemble(fixture.osm, 2);
    defer result.deinit();
    const view = &result.bundle.view;
    try view.verify(.none, null);
    const ab = try directedBetween(view, &fixture, "A", "B");
    const ba = try view.oppEdge(ab);
    try testing.expectEqual(1, (try view.edge(ab)).cls.cold_checks);
    try testing.expectEqual(0, (try view.edge(ba)).cls.cold_checks);
    var ba_limits = (try view.coldRecord(ba)).restrictions();
    try testing.expectEqual(null, ba_limits.next());

    const Kind = graph.cold.access_restriction.Kind;
    const bc = try directedBetween(view, &fixture, "B", "C");
    const cb = try view.oppEdge(bc);
    for ([_]format.EdgeId{ bc, cb }) |id| {
        const edge = try view.edge(id);
        const class = try view.class(edge.cls.class_id);
        try testing.expectEqual(1, edge.cls.cold_checks);
        try testing.expectEqual(Kind.maxheight.modes(), class.detail.access_restriction);
        try testing.expect(class.flags.truck_route and class.flags.toll);
        const record = try view.coldRecord(id);
        try testing.expectEqual(1, record.indoor.layer);
        try testing.expectEqualStrings("Restricted Street", (try (try view.names(id)).at(0)).text);
        var limits = record.restrictions();
        const expected = [_]struct { kind: Kind, value: u64 }{
            .{ .kind = .hazmat, .value = 0 },
            .{ .kind = .maxheight, .value = 500 },
            .{ .kind = .maxwidth, .value = 300 },
            .{ .kind = .maxlength, .value = 2500 },
            .{ .kind = .maxweight, .value = 600 },
            .{ .kind = .maxaxleload, .value = 1000 },
            .{ .kind = .maxaxles, .value = 8 },
            if (id == bc) .{ .kind = .maxheight, .value = 411 } else .{ .kind = .hazmat, .value = 1 },
        };
        for (expected) |want| {
            const limit = limits.next().?;
            try testing.expectEqual(want.kind, limit.attr.kind);
            try testing.expectEqual(want.value, limit.value);
            try testing.expectEqual(want.kind == .maxweight, limit.attr.except_destination);
        }
        try testing.expectEqual(null, limits.next());
    }
    const cd = try directedBetween(view, &fixture, "C", "D");
    const hov = try view.class((try view.edge(cd)).cls.class_id);
    const access: graph.constants.AccessMask = @bitCast(hov.access.forward);
    try testing.expect(hov.flags.hov3 and hov.flags.destination_only_hgv);
    try testing.expect(access.hov and !access.auto and access.motorcycle and access.moped);
    const booth = try view.node(try at(view, fixture.findNode("C").?.location.toFixed()));
    try testing.expect(booth.attr.cash_only_toll);
}

const LiveClosures = struct {
    edges: []const format.EdgeId = &.{},

    pub fn live(self: LiveClosures, id: format.EdgeId) ?graph.speed.Live {
        if (std.mem.indexOfScalar(format.EdgeId, self.edges, id) == null) return null;
        return .{ .overall = 0, .segments = @splat(0), .breakpoints = .{ 255, 0 } };
    }

    pub fn predicted(_: LiveClosures, _: format.EdgeId, _: graph.speed.Bucket) ?f32 {
        return null;
    }
};

fn MotorTestCost(comptime model: type) type {
    const compiled = routing.costing.compiled;
    const truck = model == routing.costing.truck;
    return struct {
        const Self = @This();
        profile: *const model.Profile,
        tables: *const compiled.Compiled,
        closures: LiveClosures = .{},

        pub fn restrictionPermission(self: Self) routing.costing.base.Permission {
            return self.profile.permission;
        }

        pub fn edgeCost(self: Self, view: *const graph.reader.View, edge_id: format.EdgeId, edge: *const format.EdgeHot, direction: search.Direction) !Cost {
            return (try self.edgeTraversal(view, edge_id, edge, direction)).cost;
        }

        pub fn closed(self: Self, edge: routing.snap.candidates.DirectedEdge) bool {
            return self.closures.live(edge.id) != null;
        }

        pub fn edgeTraversal(self: Self, view: *const graph.reader.View, edge_id: format.EdgeId, edge: *const format.EdgeHot, _: search.Direction) !search.Traversal {
            return self.traversal(view, edge, self.profile.resolvedSpeed(edge.*, edge_id, null, self.closures));
        }

        pub fn edgeCostAt(self: Self, view: *const graph.reader.View, edge_id: format.EdgeId, edge: *const format.EdgeHot, _: search.Direction, time: graph.time_info.TimeInfo) !search.Traversal {
            const speed = self.profile.resolvedSpeed(edge.*, edge_id, graph.speed.Time.fromTimeInfo(time), self.closures);
            return self.traversal(view, edge, speed);
        }

        pub fn timeDependentCosts(self: Self, available: graph.speed.Flow) bool {
            const selected = self.profile.permission.flow;
            return self.profile.fixed_speed == 0 and ((available.freeflow and selected.freeflow) or (available.constrained and selected.constrained));
        }

        fn traversal(self: Self, view: *const graph.reader.View, edge: *const format.EdgeHot, speed: model.Speed) !search.Traversal {
            const class = try view.class(edge.cls.class_id);
            const cost = model.Kernel.edgeCost(self.profile, self.tables, class, edge.*, speed, .{});
            return .{ .cost = cost, .measured_speed = @as(u8, @bitCast(speed.sources)) != 0 };
        }

        pub fn slowAllowed(self: Self, view: *const graph.reader.View, id: format.EdgeId, _: *const format.EdgeHot, previous: ?search.Label, _: search.Direction) !bool {
            // Full-edge seeds have no turn on which to check dimensional limits.
            if (previous != null) return true;
            const vehicle = if (truck) self.profile.vehicle else if (model == routing.costing.auto) self.profile.dimensions else return true;
            const record = try view.coldRecord(id);
            const admission = try self.profile.permission.evaluateRestrictions(record.access_limits, !record.reverse, null, .{}, vehicle, .none);
            return admission.allowed;
        }

        pub fn allowedTurn(self: Self, view: *const graph.reader.View, movement: search.Transition, _: search.Label, direction: search.Direction) !bool {
            const backtrack = movement.incoming_edge.cls.opp_local == movement.outgoing_edge.cls.local;
            const barrier = !self.profile.permission.allowedNode(try view.node(movement.node));
            // A denied node still permits a return along the edge used to reach it.
            if (barrier and !backtrack) return false;
            const from = try view.class(movement.incoming_edge.cls.class_id);
            const to = try view.class(movement.outgoing_edge.cls.class_id);
            const previous = if (direction == .forward) from else to;
            var check: model.PathCheck = .{
                .backtrack = backtrack,
                .previous_dead_end = barrier or previous.flags.dead_end or (try view.outEdgeRange(movement.node)).count() == 1,
                .previous_access = if (direction == .forward) movement.incoming_access else movement.outgoing_access,
            };
            if (!truck) {
                const edge = if (direction == .forward) movement.outgoing_edge else movement.incoming_edge;
                if (edge.cls.cold_checks != 0) {
                    const id = if (direction == .forward) movement.outgoing else movement.incoming;
                    const record = try view.coldRecord(id);
                    check.limits = record.access_limits;
                    check.original_forward = !record.reverse;
                }
            }
            const turn: routing.costing.base.Turn = .{ .row = movement.row };
            const admission = if (truck) switch (direction) {
                .forward => try model.Kernel.allowed(self.profile, view, movement.outgoing, from, to, turn, check, .none),
                .reverse => try model.Kernel.allowedReverse(self.profile, view, movement.incoming, from, to, turn, check, .none),
            } else switch (direction) {
                .forward => try model.Kernel.allowed(self.profile, from, to, turn, check, .none),
                .reverse => try model.Kernel.allowedReverse(self.profile, from, to, turn, check, .none),
            };
            return admission.allowed;
        }

        pub fn turnCost(self: Self, view: *const graph.reader.View, movement: search.Transition, _: search.Label, direction: search.Direction) !Cost {
            const from = try view.class(movement.incoming_edge.cls.class_id);
            const to = try view.class(movement.outgoing_edge.cls.class_id);
            var turn = try model.Turn.read(view, movement.node, movement.incoming, movement.outgoing, testing.allocator, .none);
            turn.movement.base_turn.previous_destination_only = movement.incoming_access.destination_only;
            turn.movement.base_turn.next_destination_only = movement.outgoing_access.destination_only;
            turn.measured_speed = movement.measured_speed;
            const node = try view.node(movement.node);
            return switch (direction) {
                .forward => model.Kernel.turnCost(self.profile, node, from, to, turn),
                .reverse => model.Kernel.turnCostReverse(self.profile, node, from, to, turn),
            };
        }
    };
}

// Ported from test/gurka/test_probable_restrictions.cc (Valhalla 3.9.3).
test "Gurka probable turn restrictions respect thresholds and timed precedence" {
    const auto = routing.costing.auto;
    const Adapter = MotorTestCost(auto);
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const fixture = try @import("examples.zig").probableTurns(a);
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try view.verify(.none, null);
    try testing.expectEqual(1, built.stats.simple_turns.invalid_probability);
    try testing.expectEqual(0, built.stats.simple_turns.deferred);
    try testing.expectEqual(4, built.stats.simple_turns.resolved);
    const Condition = format.SectionKind.restriction_conditions.Record();
    const section = built.bundle.mappings.get(.restriction_conditions).bytes;
    const corrupt = try a.alignedAlloc(u8, .of(Condition), section.len);
    @memcpy(corrupt, section);
    for (std.mem.bytesAsSlice(Condition, corrupt[format.payload_offset..])) |*row| {
        if (row.domain != 0) continue;
        row.attr.probability = 101;
        break;
    } else return error.MissingTestRestriction;
    var files: graph.reader.Files = .initFill(null);
    for (std.enums.values(format.SectionKind)) |kind| {
        const bytes = built.bundle.mappings.get(kind).bytes;
        if (bytes.len != 0) files.set(kind, bytes);
    }
    files.set(.restriction_conditions, corrupt);
    try testing.expectError(error.InvalidRestrictionConditions, graph.reader.View.parse(files, null));

    const from = try at(view, fixture.findNode("A").?.location.toFixed());
    const to = try at(view, fixture.findNode("F").?.location.toFixed());
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try search.Search(Adapter, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();

    const direct: []const []const u8 = &.{ "AB", "BC", "CF" };
    const via_g: []const []const u8 = &.{ "AB", "BD", "DG", "GH", "HE", "EC", "CF" };
    const via_i: []const []const u8 = &.{ "AB", "BD", "DG", "GI", "IJ", "JH", "HE", "EC", "CF" };
    const Case = struct { date: []const u8, options: []const u8 = "{}", threshold: u8 = 100, path: []const []const u8 };
    for ([_]Case{
        .{ .date = "2021-04-02T06:30", .path = direct },
        .{ .date = "2021-04-02T14:00", .path = via_g },
        .{ .date = "2021-04-02T14:00", .options = "{\"restriction_probability\":40}", .threshold = 40, .path = via_i },
        .{ .date = "2021-04-02T14:00", .options = "{\"restriction_probability\":1040}", .path = via_g },
        .{ .date = "2021-04-02T06:30", .options = "{\"restriction_probability\":0}", .threshold = 0, .path = direct },
        .{ .date = "2021-04-02T19:20", .path = direct },
        .{ .date = "", .options = "{\"restriction_probability\":40}", .threshold = 40, .path = direct },
    }) |case| {
        const options = try std.json.parseFromSliceLeaky(std.json.Value, a, case.options, .{});
        var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
        const profile = try auto.Model.canonicalize(try auto.parse(a, .auto, options, &warnings, .none));
        try testing.expectEqual(case.threshold, profile.permission.restriction_probability);
        const classes = view.classes.?;
        const tables = try routing.costing.compiled.compileInto(auto.Model, profile, classes, try a.alloc(f32, classes.len), .none);
        const cost: Adapter = .{ .profile = &profile, .tables = &tables };
        for ([_]search.Direction{ .forward, .reverse }) |direction| {
            for ([_]bool{ false, true }) |invariant| {
                errdefer std.debug.print("\ndate={s} threshold={d} direction={s} invariant={any}\n", .{ case.date, case.threshold, @tagName(direction), invariant });
                const req: search.Request = .{
                    .origin = from,
                    .destination = to,
                    .direction = direction,
                    .timing = try restrictionTiming(case.date, invariant),
                };
                const result = try engine.run(&arena, cost, req, search.Zero{}, .{});
                try expectWayPath(view, &fixture, result, direction, case.path);
                arena.reset();
            }
        }
    }
}

test "Gurka timed motor routes use free flow at night and constrained flow by day" {
    const auto = routing.costing.auto;
    const Adapter = MotorTestCost(auto);
    const Recost = routing.search.legs.Recost;
    const Segment = routing.search.endpoints.Segment;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const tags: gurka.Tags = &.{ .{ .key = "highway", .value = "residential" }, .{ .key = "oneway", .value = "yes" } };
    const layout = try gurka.mapToCoordinates(
        \\A---B
        \\|   |
        \\D---C
    , 10);
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AB", .tags = tags },
        .{ .label = "BC", .tags = tags },
        .{ .label = "AD", .tags = tags },
        .{ .label = "DC", .tags = tags },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    var view = built.bundle.view;
    const edges = try a.dupe(format.EdgeHot, view.edges);
    view.edges = edges;
    for (edges, 0..) |*edge, i| {
        const id: format.EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
        const way = try view.wayId(id);
        const upper = way == fixture.findWay("AB").?.id or way == fixture.findWay("BC").?.id;
        edge.speed = if (upper) .{ 50, 100, 10, 0 } else .{ 20, 10, 100, 0 };
    }

    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const profile = try auto.Model.canonicalize(try auto.parse(a, .auto, .null, &warnings, .none));
    const classes = view.classes.?;
    const tables = try routing.costing.compiled.compileInto(auto.Model, profile, classes, try a.alloc(f32, classes.len), .none);
    const cost: Adapter = .{ .profile = &profile, .tables = &tables };
    const from = try at(&view, fixture.findNode("A").?.location.toFixed());
    const to = try at(&view, fixture.findNode("C").?.location.toFixed());
    var counting = routing.infra.arena.CountingAllocator.init(testing.allocator);
    var arena = routing.infra.arena.Arena.init(counting.allocator(), .{});
    defer arena.deinit();
    var engine = try search.Search(Adapter, routing.search.queue.Heap).init(counting.allocator(), &view);
    defer engine.deinit();
    const cases = [_]struct { time: search.Timing, path: []const []const u8 }{
        .{ .time = .{}, .path = &.{ "AD", "DC" } },
        .{ .time = try restrictionTiming("2026-11-02T06:00", false), .path = &.{ "AB", "BC" } },
        .{ .time = try restrictionTiming("2026-11-02T12:00", false), .path = &.{ "AD", "DC" } },
        .{ .time = try restrictionTiming("2026-11-02T20:00", true), .path = &.{ "AB", "BC" } },
    };
    for (0..2) |round| {
        if (round == 1) counting.resetCounts();
        for ([_]search.Direction{ .forward, .reverse }) |direction| {
            for (cases) |case| {
                const result = try engine.run(&arena, cost, .{ .origin = from, .destination = to, .direction = direction, .timing = case.time }, search.Zero{}, .{});
                try expectWayPath(&view, &fixture, result, direction, case.path);
                var segments: [2]Segment = undefined;
                var index = result.index;
                for (0..segments.len) |i| {
                    const label = result.labels[index];
                    segments[if (direction == .forward) segments.len - 1 - i else i] = .{ .edge = label.edgeId(), .begin = 0, .end = 1 };
                    index = label.pred;
                }
                var steps: [segments.len]Recost.Step = undefined;
                const recosted = switch (direction) {
                    .forward => try Recost.walk(&view, cost, &segments, &steps, .forward, .{ .timing = case.time, .ignore_access = false }),
                    .reverse => try Recost.walk(&view, cost, &segments, &steps, .reverse, .{ .timing = case.time, .ignore_access = false }),
                };
                try testing.expectApproxEqRel(result.best().cost, recosted.cost, 1e-4);
                try testing.expectApproxEqRel(result.best().secs, recosted.secs, 1e-4);
                try testing.expectEqual(recosted, steps[if (direction == .forward) 1 else 0].elapsed);
                arena.reset();
            }
        }
    }
    try testing.expectEqual(0, counting.calls());
}

fn checkMotorTrip(comptime model: type, mode: if (model == routing.costing.truck) void else model.Mode, a: std.mem.Allocator, view: *const graph.reader.View, fixture: *const gurka.Map, origin: []const u8, destination: []const u8, settings: []const u8, expected: ?[]const []const u8) !void {
    const Adapter = MotorTestCost(model);
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const input = try routing.api.json.parse(a, settings);
    const options = if (model == routing.costing.truck) try model.parse(a, input, &warnings, .none) else try model.parse(a, mode, input, &warnings, .none);
    try testing.expectEqual(0, warnings.items.len);
    const profile = try model.Model.canonicalize(options);
    const classes = view.classes orelse return error.MissingClasses;
    const tables = try routing.costing.compiled.compileInto(model.Model, profile, classes, try a.alloc(f32, classes.len), .none);
    const cost: Adapter = .{ .profile = &profile, .tables = &tables };
    const from = try at(view, fixture.findNode(origin).?.location.toFixed());
    const to = try at(view, fixture.findNode(destination).?.location.toFixed());
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try search.Search(Adapter, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        errdefer std.debug.print("{s} to {s}, {s}, {s}\n", .{ origin, destination, @tagName(direction), settings });
        const result = engine.run(&arena, cost, .{ .origin = from, .destination = to, .direction = direction }, search.Zero{}, .{});
        if (expected) |ways| {
            try expectWayPath(view, fixture, try result, direction, ways);
        } else {
            try testing.expectError(error.NoPath, result);
        }
        arena.reset();
    }
}

fn checkTruckTrip(a: std.mem.Allocator, view: *const graph.reader.View, fixture: *const gurka.Map, origin: []const u8, destination: []const u8, settings: []const u8, expected: ?[]const []const u8) !void {
    return checkMotorTrip(routing.costing.truck, {}, a, view, fixture, origin, destination, settings, expected);
}

// Ported from test/gurka/test_barrier_uturns.cc (Valhalla 3.9.3).
test "barriers permit the forced return without admitting through traffic" {
    const auto = routing.costing.auto;
    const Adapter = MotorTestCost(auto);
    const endpoints = routing.search.endpoints;
    const multi = routing.search.multi;
    const api = routing.api.request;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B---C\n    |   |\n    D   |\n    |   |\n    E---F", 25), &.{
        .{ .label = "AB", .tags = road }, .{ .label = "BC", .tags = road }, .{ .label = "BD", .tags = road },
        .{ .label = "DE", .tags = road }, .{ .label = "EF", .tags = road }, .{ .label = "CF", .tags = road },
    }, &.{.{ .label = "D", .tags = &.{ .{ .key = "barrier", .value = "fence" }, .{ .key = "access", .value = "no" } } }}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const bc = try directedBetween(view, &fixture, "B", "C");
    const bd = try directedBetween(view, &fixture, "B", "D");
    const db = try view.oppEdge(bd);
    const cf = try directedBetween(view, &fixture, "C", "F");
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const profile = try auto.Model.canonicalize(try auto.parse(a, .auto, .null, &warnings, .none));
    const classes = view.classes.?;
    const tables = try routing.costing.compiled.compileInto(auto.Model, profile, classes, try a.alloc(f32, classes.len), .none);
    const motor: Adapter = .{ .profile = &profile, .tables = &tables };
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try search.Search(Adapter, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();
    const correlations = [_]routing.snap.candidates.PathLocation{
        snapLocation(&.{snapEdge(ab, 0, 0)}, &.{}),
        snapLocation(&.{ snapEdge(bd, 0.5, 0), snapEdge(db, 0.5, 0) }, &.{}),
        snapLocation(&.{snapEdge(cf, 1, 0)}, &.{}),
    };
    var locations: [3]api.Location = @splat(.{ .lat = 0, .lng = 0 });
    for ([_]api.LocationType{ .@"break", .break_through }) |kind| {
        locations[1].type = kind;
        const route = try multi.route(&engine, &arena, motor, &locations, &correlations, .{ .search = .{ .costing = .auto } }, .{});
        try testing.expectEqual(2, route.legs.len);
        try testing.expectEqual(2, route.legs[0].segments.len);
        try testing.expectEqual(ab, route.legs[0].segments[0].edge);
        try testing.expectEqual(bd, route.legs[0].segments[1].edge);
        const second: []const format.EdgeId = if (kind == .@"break") &.{ db, bc, cf } else &.{ bd, db, bc, cf };
        try testing.expectEqual(second.len, route.legs[1].segments.len);
        for (second, route.legs[1].segments) |id, segment| try testing.expectEqual(id, segment.edge);
        arena.reset();
    }
    const forced_heading = snapLocation(&.{snapEdge(bd, 0.5, 0)}, &.{});
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const route = try endpoints.route(&engine, &arena, motor, forced_heading, correlations[2], .{
            .costing = .auto,
            .direction = direction,
            .timing = try restrictionTiming("2020-10-30T09:00", false),
        }, search.Zero{}, .{});
        const expected = [_]format.EdgeId{ bd, db, bc, cf };
        try testing.expectEqual(expected.len, route.segments.len);
        for (expected, route.segments) |id, segment| try testing.expectEqual(id, segment.edge);
        arena.reset();
    }
}

// Ported from test_closure_penalty.cc and test_search_filter.cc using a pinned
// live closure observation on each directed edge (Valhalla 3.9.3).
test "live closure penalties find the earliest exit from a closed stretch" {
    const auto = routing.costing.auto;
    const Adapter = MotorTestCost(auto);
    const endpoints = routing.search.endpoints;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B---C---D---E\n    |       |\n    F-------G", 100), &.{
        .{ .label = "AB", .tags = road }, .{ .label = "BC", .tags = road }, .{ .label = "CD", .tags = road },
        .{ .label = "DE", .tags = road }, .{ .label = "BF", .tags = road }, .{ .label = "FG", .tags = road },
        .{ .label = "GD", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const bc = try directedBetween(view, &fixture, "B", "C");
    const cd = try directedBetween(view, &fixture, "C", "D");
    const de = try directedBetween(view, &fixture, "D", "E");
    const bf = try directedBetween(view, &fixture, "B", "F");
    const start = snapLocation(&.{snapEdge(ab, 0.5, 0)}, &.{});
    const goal = snapLocation(&.{snapEdge(de, 0.5, 0)}, &.{});
    const closures = [_]format.EdgeId{ ab, bc, cd };
    const classes = view.classes.?;
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try search.Search(Adapter, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();
    const cases = [_]struct { profile: []const u8, next: format.EdgeId }{
        .{ .profile = "{\"closure_factor\":1}", .next = bc },
        .{ .profile = "{\"closure_factor\":9}", .next = bf },
        .{ .profile = "{\"closure_factor\":9,\"ignore_closures\":true}", .next = bc },
        .{ .profile = "{\"closure_factor\":9,\"speed_types\":[\"constrained\"]}", .next = bc },
    };
    const options: endpoints.Options = .{ .costing = .auto, .timing = try restrictionTiming("2026-11-02T12:00", true) };
    for (cases) |case| {
        var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
        const input = try routing.api.json.parse(a, case.profile);
        var profile = try auto.Model.canonicalize(try auto.parse(a, .auto, input, &warnings, .none));
        profile.permission.filter_closures = false;
        const tables = try routing.costing.compiled.compileInto(auto.Model, profile, classes, try a.alloc(f32, classes.len), .none);
        const cost: Adapter = .{ .profile = &profile, .tables = &tables, .closures = .{ .edges = &closures } };
        const route = try endpoints.route(&engine, &arena, cost, start, goal, options, search.Zero{}, .{});
        try testing.expectEqual(ab, route.segments[0].edge);
        try testing.expectEqual(case.next, route.segments[1].edge);
        try testing.expectEqual(de, route.segments[route.segments.len - 1].edge);
        arena.reset();
    }
}

fn closureSnap(edges: []const routing.snap.candidates.PathEdge, exclude: bool) routing.snap.candidates.PathLocation {
    var location = snapLocation(edges, &.{});
    location.exclude_closures = exclude;
    return location;
}

fn expectClosurePath(view: *const graph.reader.View, fixture: *const gurka.Map, path: routing.search.endpoints.Path, names: []const []const u8) !void {
    errdefer {
        std.debug.print("\nActual ways", .{});
        for (path.segments) |segment| {
            const id = view.wayId(segment.edge) catch continue;
            for (fixture.osm.ways) |way| {
                if (way.id == id) std.debug.print(" {s}", .{way.label});
            }
        }
        std.debug.print("\n", .{});
    }
    try testing.expectEqual(names.len, path.segments.len);
    for (path.segments, names) |segment, name| {
        const way = fixture.findWay(name).?;
        try testing.expectEqual(@as(u64, @intCast(way.id)), try view.wayId(segment.edge));
    }
}

fn checkClosurePenalty(comptime model: type, a: std.mem.Allocator, view: *const graph.reader.View, fixture: *const gurka.Map, mode: anytype, costing: routing.api.request.Costing, edges: []const format.EdgeId) !void {
    const endpoints = routing.search.endpoints;
    const Adapter = MotorTestCost(model);
    const qt = try directedBetween(view, fixture, "T", "Q");
    const be = try directedBetween(view, fixture, "B", "E");
    const fc = try directedBetween(view, fixture, "F", "C");
    const da = try directedBetween(view, fixture, "D", "A");
    const from = closureSnap(&.{ snapEdge(qt, 1.0 / 3.0, 0), snapEdge(try view.oppEdge(qt), 2.0 / 3.0, 0) }, false);
    const closed_goal = closureSnap(&.{ snapEdge(be, 1.0 / 3.0, 0), snapEdge(try view.oppEdge(be), 2.0 / 3.0, 0) }, false);
    const cases = [_]struct {
        factor: []const u8,
        goal: routing.snap.candidates.PathLocation,
        path: []const []const u8,
    }{
        .{ .factor = "1", .goal = closed_goal, .path = &.{ "QT", "NQ", "KN", "HK", "EH", "BE" } },
        .{ .factor = "9", .goal = closed_goal, .path = &.{ "QT", "TU", "RU", "OR", "LO", "IL", "FI", "CF", "BC", "BE" } },
        .{ .factor = "9", .goal = closureSnap(&.{snapEdge(fc, 1, 0)}, true), .path = &.{ "QT", "TU", "RU", "OR", "LO", "IL", "FI", "CF" } },
        .{ .factor = "9", .goal = closureSnap(&.{snapEdge(da, 1, 0)}, true), .path = &.{ "QT", "ST", "PS", "MP", "JM", "GJ", "DG", "AD" } },
    };
    var engine = try search.Search(Adapter, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    for (cases) |case| {
        const json = try std.fmt.allocPrint(a, "{{\"closure_factor\":{s},\"speed_types\":[\"freeflow\",\"constrained\",\"predicted\",\"current\"]}}", .{case.factor});
        const input = try routing.api.json.parse(a, json);
        var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
        const request = if (comptime model == routing.costing.truck)
            try model.parse(a, input, &warnings, .none)
        else
            try model.parse(a, mode, input, &warnings, .none);
        const profile = try model.Model.canonicalize(request);
        const classes = view.classes.?;
        const tables = try routing.costing.compiled.compileInto(model.Model, profile, classes, try a.alloc(f32, classes.len), .none);
        const adapter: Adapter = .{ .profile = &profile, .tables = &tables, .closures = .{ .edges = edges } };
        for ([_]search.Direction{ .forward, .reverse }) |direction| {
            errdefer std.debug.print("\nclosure costing={s} factor={s} direction={s} goal={s}\n", .{ @tagName(costing), case.factor, @tagName(direction), case.path[case.path.len - 1] });
            const options: endpoints.Options = .{
                .costing = costing,
                .direction = direction,
                .timing = try restrictionTiming("2026-11-02T12:00", true),
            };
            const path = try endpoints.route(&engine, &arena, adapter, from, case.goal, options, search.Zero{}, .{});
            try expectClosurePath(view, fixture, path, case.path);
            arena.reset();
        }
    }
}

// Ported from test/gurka/test_closure_penalty.cc (Valhalla 3.9.3).
test "closure penalties choose between a closed road and an open bypass in six motor modes" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const fixture = try @import("examples.zig").closurePenalty(a);
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    var closed: [12]format.EdgeId = undefined;
    for ([_][]const u8{ "BE", "EH", "HK", "NQ", "QT", "KN" }, 0..) |name, i| {
        closed[2 * i] = try directedBetween(view, &fixture, name[0..1], name[1..2]);
        closed[2 * i + 1] = try view.oppEdge(closed[2 * i]);
    }
    // The upstream test leaves KN open. Also close it to exercise a fully
    // closed route between the admitted endpoints.
    for ([_][]const format.EdgeId{ closed[0..10], &closed }) |edges| {
        for (std.enums.values(routing.costing.auto.Mode)) |mode| {
            const costing = std.meta.stringToEnum(routing.api.request.Costing, @tagName(mode)).?;
            try checkClosurePenalty(routing.costing.auto, a, view, &fixture, mode, costing, edges);
        }
        for (std.enums.values(routing.costing.motorcycle.Mode)) |mode| {
            const costing = std.meta.stringToEnum(routing.api.request.Costing, @tagName(mode)).?;
            try checkClosurePenalty(routing.costing.motorcycle, a, view, &fixture, mode, costing, edges);
        }
        try checkClosurePenalty(routing.costing.truck, a, view, &fixture, {}, .truck, edges);
    }
}

// Extends the closure waypoint cases in test/gurka/test_search_filter.cc.
test "waypoint closure filters admit adjacent terminal closures and reject intermediate closures" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const one_way: gurka.Tags = &.{ .{ .key = "highway", .value = "primary" }, .{ .key = "oneway", .value = "yes" } };
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B---C---D---E---F\n    |       |\n    X-------Y", 100), &.{
        .{ .label = "AB", .tags = one_way }, .{ .label = "BC", .tags = one_way }, .{ .label = "CD", .tags = one_way },
        .{ .label = "DE", .tags = one_way }, .{ .label = "EF", .tags = one_way }, .{ .label = "BX", .tags = one_way },
        .{ .label = "XY", .tags = one_way }, .{ .label = "YD", .tags = one_way },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const bc = try directedBetween(view, &fixture, "B", "C");
    const de = try directedBetween(view, &fixture, "D", "E");
    const ef = try directedBetween(view, &fixture, "E", "F");
    const Auto = routing.costing.auto;
    const Adapter = MotorTestCost(Auto);
    const endpoints = routing.search.endpoints;
    const input = try routing.api.json.parse(a, "{\"closure_factor\":1}");
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const profile = try Auto.Model.canonicalize(try Auto.parse(a, .auto, input, &warnings, .none));
    const classes = view.classes.?;
    const tables = try routing.costing.compiled.compileInto(Auto.Model, profile, classes, try a.alloc(f32, classes.len), .none);
    const adapter: Adapter = .{ .profile = &profile, .tables = &tables, .closures = .{ .edges = &.{ bc, de, ef } } };
    var counting = routing.infra.arena.CountingAllocator.init(testing.allocator);
    var engine = try search.Search(Adapter, routing.search.queue.Heap).init(counting.allocator(), view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(counting.allocator(), .{});
    defer arena.deinit();
    const from = closureSnap(&.{snapEdge(ab, 0.5, 0)}, true);
    const finish = closureSnap(&.{snapEdge(ef, 0.75, 0)}, false);
    var denied_finish = finish;
    denied_finish.exclude_closures = true;
    const on_finish = closureSnap(&.{snapEdge(ef, 0.25, 0)}, false);
    var denied_start = on_finish;
    denied_start.exclude_closures = true;

    const point = fixture.findNode("E").?.location.midpoint(fixture.findNode("F").?.location);
    const snap = routing.snap.candidates;
    const snap_cost: ClosureCost = .{ .edges = .{ ef, try view.oppEdge(ef) } };
    const correlated = try snap.search(view, a, .{
        .lat = point.lat,
        .lng = point.lng,
        .minimum_reachability = 0,
        .search_filter = .{ .exclude_closures = false },
    }, .{}, snap_cost, .none);
    const ranked = try endpoints.rank(a, correlated, .auto, .{});
    for (ranked.all) |candidate| {
        if (candidate.edge != ef) continue;
        try testing.expect(candidate.allowsClosure(true));
        break;
    } else return error.MissingTestEdge;

    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const options: endpoints.Options = .{ .costing = .auto, .direction = direction };
        const path = try endpoints.route(&engine, &arena, adapter, from, finish, options, search.Zero{}, .{});
        try expectClosurePath(view, &fixture, path, &.{ "AB", "BX", "XY", "YD", "DE", "EF" });
        arena.reset();
        try testing.expectError(error.NoPath, endpoints.route(&engine, &arena, adapter, from, denied_finish, options, search.Zero{}, .{}));
        arena.reset();
        const same = try endpoints.route(&engine, &arena, adapter, on_finish, finish, options, search.Zero{}, .{});
        try expectClosurePath(view, &fixture, same, &.{"EF"});
        try testing.expectEqual(@as(f32, 0.25), same.segments[0].begin);
        try testing.expectEqual(@as(f32, 0.75), same.segments[0].end);
        arena.reset();
        try testing.expectError(error.NoPath, endpoints.route(&engine, &arena, adapter, denied_start, finish, options, search.Zero{}, .{}));
        arena.reset();
        try testing.expectError(error.NoPath, endpoints.route(&engine, &arena, adapter, on_finish, denied_finish, options, search.Zero{}, .{}));
        arena.reset();
    }
    counting.resetCounts();
    _ = try endpoints.route(&engine, &arena, adapter, from, finish, .{ .costing = .auto }, search.Zero{}, .{});
    try testing.expectEqual(0, counting.calls());
}

test "closed edge labels retain whether they can still leave the origin closure" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const primary: gurka.Tag = .{ .key = "highway", .value = "primary" };
    const one_way: gurka.Tag = .{ .key = "oneway", .value = "yes" };
    const usual: gurka.Tags = &.{ primary, one_way, .{ .key = "maxspeed", .value = "45" } };
    const bypass: gurka.Tags = &.{ primary, one_way, .{ .key = "maxspeed", .value = "90" } };
    const layout = try gurka.mapToCoordinates("S---A---B---C---D---T\n\n      X       Y", 100);
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "SA", .tags = usual },
        .{ .label = "AB", .tags = &.{ primary, one_way, .{ .key = "maxspeed", .value = "25" } } },
        .{ .label = "AXB", .tags = bypass },
        .{ .label = "BC", .tags = usual },
        .{ .label = "CD", .tags = &.{ primary, one_way, .{ .key = "maxspeed", .value = "10" } } },
        .{ .label = "CYD", .tags = bypass },
        .{ .label = "DT", .tags = usual },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    var closed: [5]format.EdgeId = undefined;
    for ([_][]const u8{ "SA", "AB", "BC", "CD", "DT" }, &closed) |name, *id| {
        id.* = try directedBetween(view, &fixture, name[0..1], name[1..2]);
    }
    const Auto = routing.costing.auto;
    const Adapter = MotorTestCost(Auto);
    const endpoints = routing.search.endpoints;
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const profile = try Auto.Model.canonicalize(try Auto.parse(a, .auto, .null, &warnings, .none));
    const classes = view.classes.?;
    const tables = try routing.costing.compiled.compileInto(Auto.Model, profile, classes, try a.alloc(f32, classes.len), .none);
    const adapter: Adapter = .{ .profile = &profile, .tables = &tables, .closures = .{ .edges = &closed } };
    var engine = try search.Search(Adapter, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    const from = closureSnap(&.{snapEdge(closed[0], 0.5, 0)}, false);
    const to = closureSnap(&.{snapEdge(closed[4], 0.5, 0)}, false);
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const options: endpoints.Options = .{ .costing = .auto, .direction = direction, .timing = try restrictionTiming("2026-11-02T12:00", true) };
        const result = try endpoints.route(&engine, &arena, adapter, from, to, options, search.Zero{}, .{});
        // AXB reaches BC more cheaply, but that label entered a terminal
        // closure and cannot take CYD. The more expensive arrival can.
        try expectClosurePath(view, &fixture, result, &.{ "SA", "AB", "BC", "CYD", "DT" });
        arena.reset();
    }
}

// Ported from test/gurka/test_exclude_cash_only_tolls.cc (Valhalla 3.9.3).
test "cash-only toll exclusions route around the booth or reject the gravel alternative" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const primary: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    const layout = try gurka.mapToCoordinates(
        \\A-----------B-------------C-------------D-------------E
        \\            |                           |
        \\            |                           |
        \\            |                           |
        \\            F---------------------------G
    , 10);
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AB", .tags = primary },                                                                                       .{ .label = "BC", .tags = primary }, .{ .label = "CD", .tags = primary },
        .{ .label = "DE", .tags = primary },                                                                                       .{ .label = "BF", .tags = primary }, .{ .label = "GD", .tags = primary },
        .{ .label = "FG", .tags = &.{ .{ .key = "highway", .value = "residential" }, .{ .key = "surface", .value = "gravel" } } },
    }, &.{.{ .label = "C", .tags = &.{ .{ .key = "barrier", .value = "toll_booth" }, .{ .key = "payment:coins", .value = "true" } } }}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const cases = [_]struct { settings: []const u8, path: ?[]const []const u8 }{
        .{ .settings = "{}", .path = &.{ "AB", "BC", "CD", "DE" } },
        .{ .settings = "{\"exclude_cash_only_tolls\":false}", .path = &.{ "AB", "BC", "CD", "DE" } },
        .{ .settings = "{\"exclude_cash_only_tolls\":true}", .path = &.{ "AB", "BF", "FG", "GD", "DE" } },
        .{ .settings = "{\"exclude_cash_only_tolls\":true,\"exclude_unpaved\":true}", .path = null },
    };
    for (cases) |case| {
        for ([_]routing.costing.auto.Mode{ .auto, .bus, .taxi }) |mode| {
            try checkMotorTrip(routing.costing.auto, mode, a, view, &fixture, "A", "E", case.settings, case.path);
        }
        try checkTruckTrip(a, view, &fixture, "A", "E", case.settings, case.path);
    }
}

// Ported from the routed cases in test_hard_exclusions_highways.cc and
// test_hard_exclusions_bridge_tunnel_tolls.cc (Valhalla 3.9.3).
test "hard edge exclusions permit leaving an excluded stretch and forbid entering it" {
    const ordinary = gurka.Tag{ .key = "highway", .value = "residential" };
    const cases = [_]struct { tags: gurka.Tags, options: []const u8 }{
        .{ .tags = &.{.{ .key = "highway", .value = "motorway" }}, .options = "{\"shortest\":true,\"exclude_highways\":true}" },
        .{ .tags = &.{ ordinary, .{ .key = "bridge", .value = "yes" } }, .options = "{\"shortest\":true,\"exclude_bridges\":true}" },
        .{ .tags = &.{ ordinary, .{ .key = "tunnel", .value = "yes" } }, .options = "{\"shortest\":true,\"exclude_tunnels\":true}" },
        .{ .tags = &.{ ordinary, .{ .key = "toll", .value = "yes" } }, .options = "{\"shortest\":true,\"exclude_tolls\":true}" },
    };
    for (cases) |case| {
        var storage: std.heap.ArenaAllocator = .init(testing.allocator);
        defer storage.deinit();
        const a = storage.allocator();
        const road: gurka.Tags = &.{ordinary};
        const layout = try gurka.mapToCoordinates("E----F----G----H----I----A----J----K----L\n                              |    |\n                              M----N", 100);
        const fixture = try gurka.Map.init(a, layout, &.{
            .{ .label = "EF", .tags = case.tags }, .{ .label = "FG", .tags = case.tags }, .{ .label = "GH", .tags = road },
            .{ .label = "HI", .tags = road },      .{ .label = "IA", .tags = road },      .{ .label = "AJ", .tags = road },
            .{ .label = "JK", .tags = case.tags }, .{ .label = "KL", .tags = road },      .{ .label = "JM", .tags = road },
            .{ .label = "MN", .tags = road },      .{ .label = "NK", .tags = road },
        }, &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        for ([_]routing.costing.auto.Mode{ .auto, .bus, .taxi }) |mode| {
            const model = routing.costing.auto;
            try checkMotorTrip(model, mode, a, view, &fixture, "I", "L", "{\"shortest\":true}", &.{ "IA", "AJ", "JK", "KL" });
            try checkMotorTrip(model, mode, a, view, &fixture, "I", "L", case.options, &.{ "IA", "AJ", "JM", "MN", "NK", "KL" });
            try checkMotorTrip(model, mode, a, view, &fixture, "E", "H", case.options, &.{ "EF", "FG", "GH" });
            try checkMotorTrip(model, mode, a, view, &fixture, "H", "E", case.options, null);
        }
        try checkTruckTrip(a, view, &fixture, "I", "L", case.options, &.{ "IA", "AJ", "JM", "MN", "NK", "KL" });
        try checkMotorTrip(routing.costing.motorcycle, .motorcycle, a, view, &fixture, "I", "L", case.options, &.{ "IA", "AJ", "JM", "MN", "NK", "KL" });
    }
}

// Ported from the interior exclusions and smoothness cases in
// test/gurka/test_exclude_unpaved_smoothness.cc (Valhalla 3.9.3).
test "smoothness adds an unpaved exclusion unless a surface or track grade takes precedence" {
    const road = gurka.Tag{ .key = "highway", .value = "residential" };
    const layout = try gurka.mapToCoordinates("A---B---C---D\n    |   |\n    E---F", 100);
    const cases = [_]struct { tags: gurka.Tags, ordinary: bool = true, excluded: bool }{
        .{ .tags = &.{ road, .{ .key = "smoothness", .value = "bad" } }, .excluded = true },
        .{ .tags = &.{ road, .{ .key = "smoothness", .value = "bad" }, .{ .key = "surface", .value = "asphalt" } }, .excluded = false },
        .{ .tags = &.{ road, .{ .key = "smoothness", .value = "bad" }, .{ .key = "tracktype", .value = "grade1" } }, .excluded = false },
        .{ .tags = &.{ road, .{ .key = "smoothness", .value = "impassable" } }, .ordinary = false, .excluded = true },
    };
    const direct: []const []const u8 = &.{ "AB", "BC", "CD" };
    const detour: []const []const u8 = &.{ "AB", "BE", "EF", "FC", "CD" };
    for (cases) |case| {
        var storage: std.heap.ArenaAllocator = .init(testing.allocator);
        defer storage.deinit();
        const a = storage.allocator();
        const fixture = try gurka.Map.init(a, layout, &.{
            .{ .label = "AB", .tags = &.{road} }, .{ .label = "BC", .tags = case.tags }, .{ .label = "CD", .tags = &.{road} },
            .{ .label = "BE", .tags = &.{road} }, .{ .label = "EF", .tags = &.{road} },  .{ .label = "FC", .tags = &.{road} },
        }, &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        for ([_]routing.costing.auto.Mode{ .auto, .bus, .taxi }) |mode| {
            try checkMotorTrip(routing.costing.auto, mode, a, view, &fixture, "A", "D", "{}", if (case.ordinary) direct else detour);
            try checkMotorTrip(routing.costing.auto, mode, a, view, &fixture, "A", "D", "{\"exclude_unpaved\":true}", if (case.excluded) detour else direct);
        }
        try checkTruckTrip(a, view, &fixture, "A", "D", "{\"exclude_unpaved\":true}", if (case.excluded) detour else direct);
    }
}

// Ported from test/gurka/test_construction.cc (Valhalla 3.9.3).
test "construction edges require build inclusion and a routing override" {
    const auto = routing.costing.auto;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const construction: gurka.Tag = .{ .key = "highway", .value = "construction" };
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---------B--------C\n                   |\n                   D", 100), &.{
        .{ .label = "AB", .tags = &.{.{ .key = "highway", .value = "primary" }} },
        .{ .label = "BC", .tags = &.{ construction, .{ .key = "construction", .value = "primary" } } },
        .{ .label = "CD", .tags = &.{construction} },
    }, &.{}, &.{});
    var excluded = try Built.assemble(fixture.osm, 1);
    defer excluded.deinit();
    try testing.expectEqual(2, excluded.bundle.view.edges.len);

    var included = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .workers = 1, .include_construction = true });
    defer included.deinit();
    const view = &included.bundle.view;
    try testing.expectEqual(4, view.edges.len);
    const bc = try directedBetween(view, &fixture, "B", "C");
    const attributes = try view.class((try view.edge(bc)).cls.class_id);
    try testing.expectEqual(@backingInt(graph.constants.Use.construction), attributes.category.use);
    try testing.expectEqual(0, attributes.access.forward);
    try testing.expectEqual(0, attributes.access.reverse);
    try checkMotorTrip(auto, .auto, a, view, &fixture, "A", "C", "{}", null);
    try checkMotorTrip(auto, .auto, a, view, &fixture, "A", "C", "{\"ignore_construction\":true}", &.{ "AB", "BC" });
}

// Ported from test/gurka/test_sump_buster.cc (Valhalla 3.9.3).
test "sump buster barriers respect the mode mask and explicit access" {
    const barrier: gurka.Tags = &.{.{ .key = "barrier", .value = "sump_buster" }};
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const defaults: []const gurka.Node = &.{ .{ .label = "F", .tags = barrier }, .{ .label = "G", .tags = barrier } };
    const overrides: []const gurka.Node = &.{
        .{ .label = "F", .tags = &.{
            barrier[0],                              .{ .key = "bus", .value = "no" },   .{ .key = "hgv", .value = "no" },
            .{ .key = "motorcycle", .value = "no" }, .{ .key = "moped", .value = "no" }, .{ .key = "foot", .value = "no" },
            .{ .key = "bicycle", .value = "no" },
        } },
        .{ .label = "G", .tags = &.{ barrier[0], .{ .key = "motorcar", .value = "yes" } } },
    };
    for ([_]bool{ false, true }) |override| {
        var storage: std.heap.ArenaAllocator = .init(testing.allocator);
        defer storage.deinit();
        const a = storage.allocator();
        const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates(
            \\A----B----C----D------------E
            \\     |         |            |
            \\     F         G            H
            \\     |         |            |
            \\     I----J----K------------L
        , 100), &.{
            .{ .label = "AB", .tags = road }, .{ .label = "BC", .tags = road }, .{ .label = "CD", .tags = road }, .{ .label = "DE", .tags = road },
            .{ .label = "BF", .tags = road }, .{ .label = "DG", .tags = road }, .{ .label = "EH", .tags = road }, .{ .label = "FI", .tags = road },
            .{ .label = "GK", .tags = road }, .{ .label = "HL", .tags = road }, .{ .label = "IJ", .tags = road }, .{ .label = "JK", .tags = road },
            .{ .label = "KL", .tags = road },
        }, if (override) overrides else defaults, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        const short: []const []const u8 = &.{ "AB", "BF", "FI" };
        const long: []const []const u8 = &.{ "AB", "BC", "CD", "DE", "EH", "HL", "KL", "JK", "IJ" };
        const through: []const []const u8 = &.{ "AB", "BC", "CD", "DG", "GK", "JK", "IJ" };
        const unrestricted = if (override) through else short;
        for ([_]routing.costing.auto.Mode{ .auto, .bus, .taxi }) |mode| {
            try checkMotorTrip(routing.costing.auto, mode, a, view, &fixture, "A", "I", "{}", if (override or mode == .bus) unrestricted else long);
        }
        try checkTruckTrip(a, view, &fixture, "A", "I", "{}", unrestricted);
        for ([_]routing.costing.motorcycle.Mode{ .motorcycle, .motor_scooter }) |mode| {
            try checkMotorTrip(routing.costing.motorcycle, mode, a, view, &fixture, "A", "I", "{}", unrestricted);
        }
        const from = try at(view, fixture.findNode("A").?.location.toFixed());
        const to = try at(view, fixture.findNode("I").?.location.toFixed());
        var engine = try RestrictionSearch.init(testing.allocator, view);
        defer engine.deinit();
        var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
        defer arena.deinit();
        for ([_]graph.constants.AccessMask{ .{ .pedestrian = true }, .{ .bicycle = true } }) |access| {
            const path = try engine.run(&arena, .{ .modes = @bitCast(access) }, .{ .origin = from, .destination = to }, search.Zero{}, .{});
            try expectWayPath(view, &fixture, path, .forward, unrestricted);
            arena.reset();
        }
    }
}

// Ported from AccessPsvWay, AccessPsvNode and the directional overrides in
// test/gurka/test_access.cc (Valhalla 3.9.3).
test "public-service access applies on both ways and barrier nodes" {
    const auto = routing.costing.auto;
    const road = gurka.Tag{ .key = "highway", .value = "residential" };
    const denied = gurka.Tag{ .key = "access", .value = "no" };
    const psv = gurka.Tag{ .key = "psv", .value = "yes" };
    const layout = try gurka.mapToCoordinates("A---B---C---D---E\n    |       |\n    F-------G", 100);
    for ([_]bool{ false, true }) |node_restriction| {
        var storage: std.heap.ArenaAllocator = .init(testing.allocator);
        defer storage.deinit();
        const a = storage.allocator();
        const fixture = try gurka.Map.init(a, layout, &.{
            .{ .label = "AB", .tags = &.{road} },
            .{ .label = "BC", .tags = if (node_restriction) &.{road} else &.{ road, denied, psv } },
            .{ .label = "CD", .tags = &.{road} },
            .{ .label = "DE", .tags = &.{road} },
            .{ .label = "BF", .tags = &.{road} },
            .{ .label = "FG", .tags = &.{road} },
            .{ .label = "GD", .tags = &.{road} },
        }, if (node_restriction) &.{.{ .label = "C", .tags = &.{ .{ .key = "barrier", .value = "gate" }, denied, psv } }} else &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        try checkMotorTrip(auto, .auto, a, view, &fixture, "A", "E", "{}", &.{ "AB", "BF", "FG", "GD", "DE" });
        for ([_]auto.Mode{ .bus, .taxi }) |mode| {
            try checkMotorTrip(auto, mode, a, view, &fixture, "A", "E", "{}", &.{ "AB", "BC", "CD", "DE" });
        }
    }
}

// Ported from the access and oneway cases in test_access.cc, test_oneways.cc
// and test_route.cc (Valhalla 3.9.3).
test "motorcar access overrides for each direction remain distinct from oneways" {
    const auto = routing.costing.auto;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road = gurka.Tag{ .key = "highway", .value = "residential" };
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B---C---D---E\n            |\n            F", 10), &.{
        .{ .label = "AB", .tags = &.{road} },
        .{ .label = "BC", .tags = &.{
            road,                                           .{ .key = "motor_vehicle:forward", .value = "no" }, .{ .key = "motorcar:forward", .value = "yes" },
            .{ .key = "motorcar:backward", .value = "no" },
        } },
        .{ .label = "CD", .tags = &.{road} },
        .{ .label = "DE", .tags = &.{ road, .{ .key = "oneway", .value = "yes" } } },
        .{ .label = "DF", .tags = &.{road} },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    try checkMotorTrip(auto, .auto, a, view, &fixture, "A", "D", "{}", &.{ "AB", "BC", "CD" });
    try checkMotorTrip(auto, .auto, a, view, &fixture, "D", "A", "{}", null);
    try checkMotorTrip(auto, .auto, a, view, &fixture, "D", "A", "{\"ignore_access\":true}", &.{ "CD", "BC", "AB" });
    try checkMotorTrip(auto, .auto, a, view, &fixture, "D", "E", "{}", &.{"DE"});
    try checkMotorTrip(auto, .auto, a, view, &fixture, "E", "D", "{}", null);
    try checkMotorTrip(auto, .auto, a, view, &fixture, "E", "D", "{\"ignore_oneways\":true}", &.{"DE"});
    try checkMotorTrip(auto, .bus, a, view, &fixture, "A", "D", "{}", null);
    try checkMotorTrip(auto, .bus, a, view, &fixture, "D", "A", "{}", &.{ "CD", "BC", "AB" });
}

// Ported from test/gurka/test_oneways_foot_bike.cc (Valhalla 3.9.3).
test "foot and bicycle one-ways keep their own direction on shared roads and paths" {
    const road = gurka.Tag{ .key = "highway", .value = "unclassified" };
    const layout = try gurka.mapToCoordinates("A---B---C---D\n    |   |\n    E---F", 100);
    const cases = [_]struct { highway: []const u8, oneway: []const u8, forward: bool, backward: bool, motor: bool }{
        .{ .highway = "unclassified", .oneway = "yes", .forward = true, .backward = false, .motor = true },
        .{ .highway = "footway", .oneway = "yes", .forward = true, .backward = false, .motor = false },
        .{ .highway = "footway", .oneway = "-1", .forward = false, .backward = true, .motor = false },
    };
    for (cases) |case| {
        var storage: std.heap.ArenaAllocator = .init(testing.allocator);
        defer storage.deinit();
        const fixture = try gurka.Map.init(storage.allocator(), layout, &.{
            .{ .label = "AB", .tags = &.{road} }, .{ .label = "CD", .tags = &.{road} },
            .{ .label = "BE", .tags = &.{road} }, .{ .label = "EF", .tags = &.{road} },
            .{ .label = "FC", .tags = &.{road} },
            .{ .label = "BC", .tags = &.{
                .{ .key = "highway", .value = case.highway },
                .{ .key = "oneway", .value = "yes" },
                .{ .key = "bicycle", .value = "yes" },
                .{ .key = "oneway:bicycle", .value = case.oneway },
                .{ .key = "oneway:foot", .value = case.oneway },
            } },
        }, &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        const left = try at(view, fixture.findNode("A").?.location.toFixed());
        const right = try at(view, fixture.findNode("D").?.location.toFixed());
        var engine = try RestrictionSearch.init(testing.allocator, view);
        defer engine.deinit();
        var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
        defer arena.deinit();
        for ([_]graph.constants.AccessMask{ .{ .auto = true }, .{ .bicycle = true }, .{ .pedestrian = true } }) |mask| {
            const costing: RestrictionMotor = .{ .modes = @bitCast(mask) };
            const shortcut_forward = if (mask.auto) case.motor else case.forward;
            const shortcut_backward = !mask.auto and case.backward;
            for ([_]search.Direction{ .forward, .reverse }) |direction| {
                const outbound = try engine.run(&arena, costing, .{ .origin = left, .destination = right, .direction = direction }, search.Zero{}, .{});
                try expectWayPath(view, &fixture, outbound, direction, if (shortcut_forward) &.{ "AB", "BC", "CD" } else &.{ "AB", "BE", "EF", "FC", "CD" });
                arena.reset();
                const inbound = try engine.run(&arena, costing, .{ .origin = right, .destination = left, .direction = direction }, search.Zero{}, .{});
                try expectWayPath(view, &fixture, inbound, direction, if (shortcut_backward) &.{ "CD", "BC", "AB" } else &.{ "CD", "FC", "EF", "BE", "AB" });
                arena.reset();
            }
        }
    }
}

// Ported from test/gurka/test_permissible_dimensions.cc and the dimensional
// cases in test_ignore_restrictions.cc (Valhalla 3.9.3).
test "motor dimensions select roads at their inclusive limits" {
    const dimensions = [_]struct { tag: []const u8, option: []const u8, unit: []const u8 }{
        .{ .tag = "maxwidth", .option = "width", .unit = "m" },
        .{ .tag = "maxheight", .option = "height", .unit = "m" },
        .{ .tag = "maxlength", .option = "length", .unit = "m" },
        .{ .tag = "maxweight", .option = "weight", .unit = "t" },
    };
    const road = gurka.Tag{ .key = "highway", .value = "residential" };
    const layout = try gurka.mapToCoordinates("A----B----C----D----E\n     |         |    |\n     |         |    |\n     I----H----G----F", 100);
    for (dimensions) |dimension| {
        var storage: std.heap.ArenaAllocator = .init(testing.allocator);
        defer storage.deinit();
        const a = storage.allocator();
        const upper = try std.fmt.allocPrint(a, "2.0{s}", .{dimension.unit});
        const lower = try std.fmt.allocPrint(a, "1.9{s}", .{dimension.unit});
        const fixture = try gurka.Map.init(a, layout, &.{
            .{ .label = "AB", .tags = &.{road} },
            .{ .label = "BC", .tags = &.{ road, .{ .key = dimension.tag, .value = "2.0" } } },
            .{ .label = "CD", .tags = &.{ road, .{ .key = dimension.tag, .value = upper } } },
            .{ .label = "DE", .tags = &.{road} },
            .{ .label = "EF", .tags = &.{road} },
            .{ .label = "FG", .tags = &.{road} },
            .{ .label = "GH", .tags = &.{road} },
            .{ .label = "HI", .tags = &.{road} },
            .{ .label = "DG", .tags = &.{ road, .{ .key = dimension.tag, .value = "1.9" } } },
            .{ .label = "BI", .tags = &.{ road, .{ .key = dimension.tag, .value = lower } } },
        }, &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        const cases = [_]struct { value: []const u8, path: ?[]const []const u8 }{
            .{ .value = "1.8", .path = &.{ "AB", "BI" } },
            .{ .value = "1.9", .path = &.{ "AB", "BI" } },
            .{ .value = "2.0", .path = &.{ "AB", "BC", "CD", "DE", "EF", "FG", "GH", "HI" } },
            .{ .value = "2.1", .path = null },
        };
        for (cases) |case| {
            // The non-vehicular override leaves vehicle dimensions active.
            const settings = try std.fmt.allocPrint(a, "{{\"{s}\":{s},\"ignore_non_vehicular_restrictions\":true}}", .{ dimension.option, case.value });
            for ([_]routing.costing.auto.Mode{ .auto, .bus, .taxi }) |mode| {
                try checkMotorTrip(routing.costing.auto, mode, a, view, &fixture, "A", "I", settings, case.path);
            }
            try checkTruckTrip(a, view, &fixture, "A", "I", settings, case.path);
        }
        for ([_]routing.costing.motorcycle.Mode{ .motorcycle, .motor_scooter }) |mode| {
            try checkMotorTrip(routing.costing.motorcycle, mode, a, view, &fixture, "A", "I", "{}", &.{ "AB", "BI" });
        }
    }
}

// Ported from test/gurka/test_destination_only.cc.
test "destination-only shortcuts compete at their entry cost in both directions" {
    const auto = routing.costing.auto;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road = gurka.Tag{ .key = "highway", .value = "unclassified" };
    const layout = try gurka.mapToCoordinates(
        \\A----B----C----D----E
        \\     |         |    |
        \\     |         |    |
        \\     I----H----G----F
    , 100);
    const regular: []const []const u8 = &.{ "AB", "BC", "CD", "DE", "EF", "FG", "GH", "HI" };
    for ([_][]const u8{ "motor_vehicle", "hgv" }) |mode_tag| {
        const fixture = try gurka.Map.init(a, layout, &.{
            .{ .label = "AB", .tags = &.{road} },
            .{ .label = "BC", .tags = &.{road} },
            .{ .label = "CD", .tags = &.{road} },
            .{ .label = "DE", .tags = &.{road} },
            .{ .label = "EF", .tags = &.{road} },
            .{ .label = "FG", .tags = &.{road} },
            .{ .label = "GH", .tags = &.{road} },
            .{ .label = "HI", .tags = &.{road} },
            .{ .label = "DG", .tags = &.{ road, .{ .key = mode_tag, .value = "destination" } } },
            .{ .label = "BI", .tags = &.{ road, .{ .key = "access", .value = "private" } } },
        }, &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        const hgv = std.mem.eql(u8, mode_tag, "hgv");
        try checkMotorTrip(auto, .auto, a, view, &fixture, "A", "I", "{}", if (hgv) &.{ "AB", "BC", "CD", "DG", "GH", "HI" } else regular);
        try checkMotorTrip(auto, .auto, a, view, &fixture, "A", "I", "{\"destination_only_penalty\":0}", &.{ "AB", "BI" });
        if (hgv) try checkTruckTrip(a, view, &fixture, "A", "I", "{}", regular);
    }
}

test "consecutive destination-only edges charge one entry in either direction" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const fixture = try @import("examples.zig").accessRegions(storage.allocator());
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const from = try at(view, fixture.findNode("A").?.location.toFixed());
    const to = try at(view, fixture.findNode("F").?.location.toFixed());
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try RestrictionSearch.init(testing.allocator, view);
    defer engine.deinit();
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const request: search.Request = .{ .origin = from, .destination = to, .direction = direction };
        const baseline = (try engine.run(&arena, RestrictionMotor{}, request, search.Zero{}, .{})).best().*;
        arena.reset();
        const priced = try engine.run(&arena, RestrictionMotor{ .destination_penalty = 17 }, request, search.Zero{}, .{});
        try expectWayPath(view, &fixture, priced, direction, &.{ "AB", "BC", "CD", "DE", "EF" });
        try testing.expectEqual(baseline.cost + 17, priced.best().cost);
        try testing.expectEqual(baseline.secs, priced.best().secs);
        arena.reset();
    }
}

// Ported from test/gurka/test_access.cc and test/gurka/test_deadend_barrier.cc.
test "private driveways admit their endpoints while tagged barriers retain access" {
    const auto = routing.costing.auto;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    const layout = try gurka.mapToCoordinates("A---B---C\n    |   |\n    D   E", 10);
    for ([_][]const u8{ "private", "no" }) |access| {
        const fixture = try gurka.Map.init(a, layout, &.{
            .{ .label = "AB", .tags = road },
            .{ .label = "BC", .tags = road },
            .{ .label = "BD", .tags = &.{ .{ .key = "highway", .value = "service" }, .{ .key = "service", .value = "driveway" }, .{ .key = "access", .value = "private" } } },
            .{ .label = "CE", .tags = road },
        }, &.{.{ .label = "C", .tags = &.{ .{ .key = "barrier", .value = "gate" }, .{ .key = "access", .value = access } } }}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        try checkMotorTrip(auto, .auto, a, view, &fixture, "A", "D", "{}", &.{ "AB", "BD" });
        try checkMotorTrip(auto, .auto, a, view, &fixture, "D", "A", "{}", &.{ "BD", "AB" });
        try checkMotorTrip(auto, .auto, a, view, &fixture, "A", "E", "{}", if (std.mem.eql(u8, access, "private")) &.{ "AB", "BC", "CE" } else null);
    }
}

// As in test/gurka/test_not_thru_pruning.cc, mark directed edges to model
// existing bundles with not-thru regions whose only entrance is required.
test "not-thru labels do not remove routes through a required entrance" {
    const auto = routing.costing.auto;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B---C---D---E", 25), &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "BC", .tags = road },
        .{ .label = "CD", .tags = road },
        .{ .label = "DE", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    var view = built.bundle.view;
    const base_classes = view.classes.?;
    const classes = try a.alloc(graph.class_table.EdgeClass, base_classes.len + 1);
    @memcpy(classes[0..base_classes.len], base_classes);
    view.classes = classes;
    const edges = try a.dupe(format.EdgeHot, view.edges);
    view.edges = edges;
    const bc = try directedBetween(&view, &fixture, "B", "C");
    const bc_edge = &edges[@backingInt(bc)];
    classes[base_classes.len] = base_classes[bc_edge.cls.class_id];
    classes[base_classes.len].flags.not_thru = true;
    bc_edge.cls.class_id = @intCast(base_classes.len);
    try checkMotorTrip(auto, .auto, a, &view, &fixture, "A", "E", "{}", &.{ "AB", "BC", "CD", "DE" });
    try checkMotorTrip(auto, .auto, a, &view, &fixture, "A", "C", "{}", &.{ "AB", "BC" });
    try checkMotorTrip(auto, .auto, a, &view, &fixture, "B", "E", "{}", &.{ "BC", "CD", "DE" });

    const loop = try @import("examples.zig").accessRegions(a);
    var built_loop = try Built.assemble(loop.osm, 1);
    defer built_loop.deinit();
    const loop_view = &built_loop.bundle.view;
    const lp = try directedBetween(loop_view, &loop, "L", "P");
    try testing.expect((try loop_view.class((try loop_view.edge(lp)).cls.class_id)).flags.not_thru);
    try checkMotorTrip(auto, .auto, a, loop_view, &loop, "K", "N", "{}", &.{ "KL", "LP", "PQRSP", "PQRSP", "LP", "LM", "MN" });
}

test "a destination-only endpoint still respects a timed access denial" {
    const endpoints = routing.search.endpoints;
    const Recost = routing.search.legs.Recost;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road = gurka.Tag{ .key = "highway", .value = "residential" };
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B---C", 10), &.{
        .{ .label = "AB", .tags = &.{road} },
        .{ .label = "BC", .tags = &.{
            road,
            .{ .key = "access", .value = "private" },
            .{ .key = "motor_vehicle:conditional", .value = "no @ (Mo-Fr 07:00-09:00)" },
        } },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const bc = try directedBetween(view, &fixture, "B", "C");
    const origin = snapLocation(&.{snapEdge(ab, 0.5, 0)}, &.{});
    const target = snapLocation(&.{snapEdge(bc, 0.5, 0)}, &.{});
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try RestrictionSearch.init(testing.allocator, view);
    defer engine.deinit();
    var options: endpoints.Options = .{ .costing = .auto, .timing = try restrictionTiming("2026-11-02T06:00", false) };
    const open = try endpoints.route(&engine, &arena, RestrictionMotor{}, origin, target, options, search.Zero{}, .{});
    try testing.expectEqual(bc, open.segments[open.segments.len - 1].edge);
    try testing.expect(!open.retried);
    const open_cost = try Recost.walk(view, RestrictionMotor{}, open.segments, null, .forward, .{ .timing = options.timing, .ignore_access = false });
    try testing.expectApproxEqRel(open.cost, open_cost.cost, 1e-4);
    const sections = [2]endpoints.Segment{ open.segments[0], open.segments[1] };
    arena.reset();
    options.timing = try restrictionTiming("2026-11-02T08:00", false);
    try testing.expectError(error.NoPath, endpoints.route(&engine, &arena, RestrictionMotor{}, origin, target, options, search.Zero{}, .{}));
    try testing.expectError(error.InvalidRouteAccess, Recost.walk(view, RestrictionMotor{}, &sections, null, .forward, .{ .timing = options.timing, .ignore_access = false }));
}

// Ported from test/gurka/test_truck.cc.
test "Gurka truck dimension and hazmat limits in both search directions" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road = gurka.Tag{ .key = "highway", .value = "residential" };
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B---C---D", 10), &.{
        .{ .label = "AB", .tags = &.{road} },
        .{ .label = "BC", .tags = &.{
            road,
            .{ .key = "maxheight:forward", .value = "5" },
            .{ .key = "maxwidth", .value = "3" },
            .{ .key = "maxlength", .value = "25" },
            .{ .key = "maxweight", .value = "35" },
            .{ .key = "maxaxleload", .value = "10" },
            .{ .key = "maxaxles", .value = "8" },
            .{ .key = "hazmat", .value = "destination" },
        } },
        .{ .label = "CD", .tags = &.{road} },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try checkTruckTrip(a, view, &fixture, "A", "D", "{}", &.{ "AB", "BC", "CD" });
    for ([_][]const u8{
        "{\"height\":6}",    "{\"width\":4}",      "{\"length\":30}",     "{\"weight\":36}",
        "{\"hazmat\":true}", "{\"axle_load\":11}", "{\"axle_count\":10}",
    }) |options| {
        try checkTruckTrip(a, view, &fixture, "A", "D", options, null);
    }
    try checkTruckTrip(a, view, &fixture, "D", "A", "{\"height\":6}", &.{ "CD", "BC", "AB" });
    try checkTruckTrip(a, view, &fixture, "A", "D", "{\"height\":6,\"ignore_restrictions\":true}", &.{ "AB", "BC", "CD" });
    try checkTruckTrip(a, view, &fixture, "A", "D", "{\"height\":5,\"width\":3,\"length\":25,\"weight\":35,\"axle_load\":10,\"axle_count\":8}", &.{ "AB", "BC", "CD" });
}

// Ported from test/gurka/test_truck.cc.
test "Gurka truck route preference selects the designated detour" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road = gurka.Tag{ .key = "highway", .value = "residential" };
    const layout = try gurka.mapToCoordinates(
        \\A------B
        \\|      |
        \\|      |
        \\|      |
        \\|      |
        \\|      C
        \\|      |
        \\E------D
    , 500);
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AB", .tags = &.{road} },
        .{ .label = "AE", .tags = &.{ road, .{ .key = "hgv", .value = "designated" } } },
        .{ .label = "BC", .tags = &.{road} },
        .{ .label = "CD", .tags = &.{road} },
        .{ .label = "ED", .tags = &.{road} },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try checkTruckTrip(a, view, &fixture, "A", "C", "{}", &.{ "AB", "BC" });
    try checkTruckTrip(a, view, &fixture, "A", "C", "{\"use_truck_route\":1}", &.{ "AE", "ED", "CD" });
}

// Ported from the low-road-class detours in test/gurka/test_truck.cc.
test "Gurka truck low class entry penalty selects the higher class detour" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const speed = gurka.Tag{ .key = "maxspeed", .value = "30" };
    const primary: gurka.Tags = &.{ .{ .key = "highway", .value = "primary" }, speed };
    const local: gurka.Tags = &.{ .{ .key = "highway", .value = "residential" }, speed };
    const detour: gurka.Tags = &.{ .{ .key = "highway", .value = "unclassified" }, speed };
    const layout = try gurka.mapToCoordinates(
        \\    D---E
        \\    |   |
        \\S---A-B-C---T
    , 10);
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "SA", .tags = primary },
        .{ .label = "AB", .tags = local },
        .{ .label = "BC", .tags = local },
        .{ .label = "CT", .tags = primary },
        .{ .label = "AD", .tags = detour },
        .{ .label = "DE", .tags = detour },
        .{ .label = "EC", .tags = detour },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try checkTruckTrip(a, view, &fixture, "S", "T", "{\"low_class_factor\":1,\"low_class_penalty\":0}", &.{ "SA", "AB", "BC", "CT" });
    try checkTruckTrip(a, view, &fixture, "S", "T", "{\"low_class_factor\":1,\"low_class_penalty\":120}", &.{ "SA", "AD", "DE", "EC", "CT" });
}

// Ported from the motorcycle cases in test/gurka/test_use_options.cc.
test "Gurka motorcycle curvature preference takes the twisty road" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const layout = try gurka.mapToCoordinates(
        \\A---------G
        \\|        /
        \\B     E-F
        \\ \   /
        \\  C-D
    , 50);
    const road = gurka.Tag{ .key = "highway", .value = "primary" };
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AG", .tags = &.{ road, .{ .key = "name", .value = "Straight Road" } } },
        .{ .label = "ABCDEFG", .tags = &.{ road, .{ .key = "name", .value = "Twisty Road" } } },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    const model = routing.costing.motorcycle;
    try checkMotorTrip(model, .motorcycle, a, view, &fixture, "A", "G", "{}", &.{"AG"});
    try checkMotorTrip(model, .motorcycle, a, view, &fixture, "A", "G", "{\"use_curvature\":1}", &.{"ABCDEFG"});
    try checkMotorTrip(model, .motorcycle, a, view, &fixture, "A", "G", "{\"use_curvature\":0.75}", &.{"ABCDEFG"});
}

// Ported from ScooterTopSpeed and MotorcycleTopSpeed in test/gurka/test_speeds.cc.
test "Gurka motorcycle and scooter top speed switch the selected road" {
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const layout = try gurka.mapToCoordinates(
        \\B------C
        \\|      |
        \\|      |
        \\A      D
        \\|      |
        \\E------F
    , 10);
    const road = gurka.Tag{ .key = "highway", .value = "residential" };
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "ABCD", .tags = &.{ road, .{ .key = "maxspeed", .value = "45" } } },
        .{ .label = "AEFD", .tags = &.{ road, .{ .key = "maxspeed", .value = "20" } } },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    const model = routing.costing.motorcycle;
    for ([_]model.Mode{ .motorcycle, .motor_scooter }) |mode| {
        try checkMotorTrip(model, mode, a, view, &fixture, "A", "D", "{}", &.{"ABCD"});
        try checkMotorTrip(model, mode, a, view, &fixture, "A", "D", "{\"top_speed\":20}", &.{"AEFD"});
    }
}

test "assembled gates and tolls retain shared costing attributes" {
    const base = routing.costing.base;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A--G--B--T--C", 20), &.{
        .{ .label = "AG", .tags = road },
        .{ .label = "GB", .tags = road },
        .{ .label = "BT", .tags = &.{ road[0], .{ .key = "toll", .value = "yes" } } },
        .{ .label = "TC", .tags = road },
    }, &.{
        .{ .label = "G", .tags = &.{
            .{ .key = "barrier", .value = "gate" },
            .{ .key = "access", .value = "private" },
        } },
        .{ .label = "T", .tags = &.{
            .{ .key = "barrier", .value = "toll_booth" },
            .{ .key = "payment:notes", .value = "yes" },
            .{ .key = "payment:credit_cards", .value = "no" },
        } },
    }, &.{});
    var result = try Built.assemble(fixture.osm, 1);
    defer result.deinit();
    const view = &result.bundle.view;
    const gate = try view.node(try at(view, fixture.findNode("G").?.location.toFixed()));
    const booth = try view.node(try at(view, fixture.findNode("T").?.location.toFixed()));
    try testing.expect(gate.attr.tagged_access);
    try testing.expect(gate.attr.private_access);
    try testing.expect(booth.attr.cash_only_toll);

    const approach = try view.class((try view.edge(try directedBetween(view, &fixture, "A", "G"))).cls.class_id);
    const exit = try view.class((try view.edge(try directedBetween(view, &fixture, "G", "B"))).cls.class_id);
    const toll_id = try directedBetween(view, &fixture, "B", "T");
    const toll = try view.class((try view.edge(toll_id)).cls.class_id);
    const toll_reverse = try view.class((try view.edge(try view.oppEdge(toll_id))).cls.class_id);
    try testing.expect(!approach.flags.toll);
    try testing.expect(toll.flags.toll);
    try testing.expect(toll_reverse.flags.toll);

    var warnings: std.ArrayList(base.Warning) = .empty;
    const object = try routing.api.json.parse(a,
        \\{"exclude_cash_only_tolls":true,"exclude_tolls":true}
    );
    const options = try base.parse(a, object, .{}, &warnings, .none);
    const shared: base.Shared = .init(options);
    const turn: base.Turn = .{ .row = 0x40 };
    const gate_cost = shared.transition(gate, approach, exit, turn);
    try testing.expectEqual(@as(f32, 480), gate_cost.cost);
    try testing.expectEqual(@as(f32, 30), gate_cost.secs);
    const junction = try view.node(try at(view, fixture.findNode("B").?.location.toFixed()));
    const toll_cost = shared.transition(junction, exit, toll, turn);
    try testing.expectEqual(@as(f32, 15), toll_cost.cost);
    try testing.expectEqual(@as(f32, 15), toll_cost.secs);
    const permission: base.Permission = .init(options, .{ .auto = true }, true);
    try testing.expect(!permission.allowedNode(booth));
    try testing.expect(!permission.allowedTransition(exit, toll, turn));
}

// Ported from test/gurka/test_reach.cc.
test "bounded reach matches the nine-node grid and upstream live closure cases" {
    const snap = routing.snap;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const layout = try gurka.mapToCoordinatesAt("A---B---C\n|   |   |\nD---E---F\n|   |   |\nG---H---I\n\nK--L--M--N--O", 10, .{ .lng = 0.05, .lat = 0.2 });
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    var ways: [16]gurka.Way = undefined;
    for ([_][]const u8{ "AB", "BC", "AD", "BE", "CF", "DE", "EF", "DG", "EH", "FI", "GH", "HI", "KL", "LM", "MN", "NO" }, &ways) |label, *way| {
        way.* = .{ .label = label, .tags = road };
    }
    const fixture = try gurka.Map.init(a, layout, &ways, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const hi = try directedBetween(view, &fixture, "H", "I");
    const auto: snap.candidates.Access = .{ .mask = .{ .auto = true } };

    var finder: snap.reach.Finder = .{ .view = view, .arena = a, .limit = 50, .deadline = .none };
    try testing.expectEqual(snap.reach.Counts{ .inbound = 9, .outbound = 9 }, try finder.counts(ab, auto));
    try testing.expectEqual(snap.reach.Counts{ .inbound = 9, .outbound = 9 }, try finder.counts(hi, auto));

    const Traffic = struct {
        base: snap.candidates.Access,
        ids: [4]u64,
        filter_closures: bool,

        pub fn allowed(self: @This(), arc: snap.candidates.DirectedEdge) bool {
            return self.base.allowed(arc) and (!self.filter_closures or !self.closed(arc));
        }

        pub fn closed(self: @This(), arc: snap.candidates.DirectedEdge) bool {
            const way = arc.graph_view.wayId(arc.id) catch unreachable;
            return std.mem.indexOfScalar(u64, &self.ids, way) != null;
        }
    };

    var traffic: Traffic = .{ .base = auto, .ids = undefined, .filter_closures = true };
    for ([_][]const u8{ "AB", "BC", "AD", "BE" }, &traffic.ids) |label, *way| {
        way.* = @intCast(fixture.findWay(label).?.id);
    }
    finder = .{ .view = view, .arena = a, .limit = 50, .deadline = .none };
    try testing.expectEqual(snap.reach.Counts{}, try finder.counts(ab, traffic));
    try testing.expectEqual(snap.reach.Counts{ .inbound = 7, .outbound = 7 }, try finder.counts(hi, traffic));

    traffic.filter_closures = false;
    finder = .{ .view = view, .arena = a, .limit = 50, .deadline = .none };
    try testing.expectEqual(snap.reach.Counts{ .inbound = 8, .outbound = 8 }, try finder.counts(ab, traffic));
    try testing.expectEqual(snap.reach.Counts{ .inbound = 7, .outbound = 7 }, try finder.counts(hi, traffic));

    finder = .{ .view = view, .arena = a, .limit = 3, .deadline = .none };
    try testing.expectEqual(snap.reach.Counts{ .inbound = 3, .outbound = 3 }, try finder.counts(ab, auto));
    finder.deadline = .{ .at_ns = 0 };
    try testing.expectError(error.DeadlineExceeded, finder.counts(ab, auto));
}

test "location correlation counts one-way reach and reports unconnected and unsnappable locations" {
    const snap = routing.snap;
    const Location = routing.api.request.Location;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_way: gurka.Tags = &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "oneway", .value = "yes" },
        .{ .key = "bicycle", .value = "no" },
    };
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const layout = try gurka.mapToCoordinatesAt("A--B--C\n\nK--L--M", 40, .{ .lng = 9.6, .lat = 47.1 });
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AB", .tags = one_way },
        .{ .label = "BC", .tags = one_way },
        .{ .label = "KL", .tags = road },
        .{ .label = "LM", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const auto: snap.candidates.Access = .{ .mask = .{ .auto = true } };
    const bike: snap.candidates.Access = .{ .mask = .{ .bicycle = true } };
    const end = try directedBetween(view, &fixture, "B", "C");
    var finder: snap.reach.Finder = .{ .view = view, .arena = a, .limit = 10, .deadline = .none };
    try testing.expectEqual(snap.reach.Counts{ .inbound = 2, .outbound = 1 }, try finder.counts(end, auto));
    try testing.expectEqual(snap.reach.Counts{}, try finder.counts(try view.oppEdge(end), auto));

    const start = fixture.findNode("A").?.location;
    const dead_end = fixture.findNode("C").?.location;
    const island = fixture.findNode("K").?.location;
    const start_input: Location = .{ .lat = start.lat, .lng = start.lng, .search_cutoff = 5 };
    const dead_end_input: Location = .{ .lat = dead_end.lat, .lng = dead_end.lng, .search_cutoff = 5 };
    const island_input: Location = .{ .lat = island.lat, .lng = island.lng, .search_cutoff = 5 };
    const correlated = try snap.candidates.search(view, a, dead_end_input, .{}, auto, .none);
    try testing.expectEqual(1, correlated.edges.len);
    try testing.expectEqual(end, correlated.edges[0].id);
    try testing.expectEqual(1, correlated.edges[0].reach.outbound);

    const route = try snap.location.route(view, a, &.{ start_input, dead_end_input }, .{}, auto, .none);
    try testing.expectEqual(2, route.ok.len);
    const disconnected = try snap.location.route(view, a, &.{ start_input, island_input }, .{}, auto, .none);
    try testing.expectEqual(170, disconnected.failure.code);
    try testing.expectEqualStrings("Locations are in unconnected regions. Go check/edit the map at osm.org", disconnected.failure.entry().message);
    const no_edge = try snap.location.route(view, a, &.{ island_input, dead_end_input }, .{}, bike, .none);
    try testing.expectEqual(171, no_edge.failure.code);
    try testing.expectEqualStrings("No suitable edges near location", no_edge.failure.entry().message);
    var nearby = island_input;
    nearby.search_cutoff = 120;
    nearby.radius = 120;
    nearby.minimum_reachability = 3;
    const ranked = try snap.candidates.search(view, a, nearby, .{}, auto, .none);
    try testing.expect(ranked.edges.len >= 2);
    for (ranked.edges) |candidate| {
        try testing.expectEqual(snap.reach.Counts{ .inbound = 3, .outbound = 3 }, candidate.reach);
    }
    var inbound_only = dead_end_input;
    inbound_only.minimum_inbound_reachability = 2;
    try testing.expectEqual(snap.reach.Counts{ .inbound = 2, .outbound = 0 }, snap.candidates.thresholds(inbound_only, .{}));
    const one_direction = try snap.candidates.search(view, a, inbound_only, .{}, auto, .none);
    try testing.expectEqual(snap.reach.Counts{ .inbound = 2, .outbound = 1 }, one_direction.edges[0].reach);

    const missing = try snap.location.route(view, a, &.{start_input}, .{}, auto, .none);
    try testing.expectEqual(120, missing.failure.code);
}

test "leased compiled classes drive graph-based snapping and the cold permission hook" {
    const costing = routing.costing.compiled;
    const snap = routing.snap;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const layout = try gurka.mapToCoordinatesAt("A--B--C", 50, .{ .lng = 9.6, .lat = 47.1 });
    const fixture = try gurka.Map.init(a, layout, &.{
        .{ .label = "AB", .tags = &.{.{ .key = "highway", .value = "residential" }} },
        .{ .label = "BC", .tags = &.{.{ .key = "highway", .value = "footway" }} },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const Driver = struct {
        pub const Options = void;
        pub const Canonical = void;
        pub fn canonicalize(_: Options) !Canonical {}
        pub fn rules(_: Canonical) !costing.Rules {
            return .{ .node_access_mask = @bitCast(graph.constants.AccessMask{ .auto = true }) };
        }
        pub fn classFactor(_: Canonical, class: graph.class_table.EdgeClass) !f32 {
            return if (class.forwardAccess().auto) 1 else std.math.inf(f32);
        }
    };
    var cache = try costing.Cache(Driver).init(a, view.classes.?, 1);
    defer cache.deinit();
    var lease = try cache.acquire({}, .none);
    defer lease.release();
    const coordinate = fixture.findNode("B").?.location;
    const location: routing.api.request.Location = .{ .lat = coordinate.lat, .lng = coordinate.lng, .search_cutoff = 10 };
    const result = try snap.candidates.search(view, a, location, .{}, lease.tables(), .none);
    try testing.expectEqual(2, result.edges.len);
    const ab = try directedBetween(view, &fixture, "A", "B");
    const bc = try directedBetween(view, &fixture, "B", "C");
    const Cold = struct {
        blocked: ?format.EdgeId = null,
        pub fn allowed(self: @This(), _: *const graph.reader.View, id: format.EdgeId, _: *const format.EdgeHot) bool {
            return self.blocked != id;
        }
    };
    try testing.expect(costing.Kernel.slowAllowed(lease.tables(), view, ab, Cold{}));
    try testing.expect(!costing.Kernel.slowAllowed(lease.tables(), view, ab, Cold{ .blocked = ab }));
    try testing.expect(!costing.Kernel.slowAllowed(lease.tables(), view, bc, Cold{}));
}

test "pedestrian and bicycle turns use assembled crossing and elevator metadata" {
    const pedestrian = routing.costing.pedestrian;
    const bicycle = routing.costing.bicycle;
    const base = routing.costing.base;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const footway: gurka.Tags = &.{
        .{ .key = "highway", .value = "footway" },
        .{ .key = "name", .value = "Crossing path" },
        .{ .key = "bicycle", .value = "yes" },
    };
    const primary: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    const map = try gurka.mapToCoordinates("    N\n    |\nW---X---E\n    |\n    S", 20);
    const fixture = try gurka.Map.init(a, map, &.{
        .{ .label = "NX", .tags = footway },
        .{ .label = "XS", .tags = footway },
        .{ .label = "WX", .tags = primary },
        .{ .label = "XE", .tags = primary },
    }, &.{}, &.{});
    var bundle = try Built.assemble(fixture.osm, 1);
    defer bundle.deinit();
    const view = &bundle.bundle.view;
    const x = try at(view, fixture.findNode("X").?.location.toFixed());
    const in = try directedBetween(view, &fixture, "N", "X");
    const out = try directedBetween(view, &fixture, "X", "S");
    const from = try view.class((try view.edge(in)).cls.class_id);
    const to = try view.class((try view.edge(out)).cls.class_id);
    const turn = try pedestrian.Turn.read(view, x, in, out);
    try testing.expect(turn.sides.left and turn.sides.right);
    try testing.expectEqual(6, turn.base_turn.stopImpact());

    var warnings: std.ArrayList(base.Warning) = .empty;
    const options = try pedestrian.parse(a, .null, &warnings, .none);
    var cache = try pedestrian.Cache.init(testing.allocator, view.classes.?, 1);
    defer cache.deinit();
    var lease = try cache.acquire(options, .none);
    defer lease.release();
    const crossing = pedestrian.Kernel.turnCost(lease.profile(), try view.node(x), from, to, turn);
    try testing.expectEqual(@as(f32, 5), crossing.secs);
    try testing.expectEqual(@as(f32, 5), crossing.cost);
    try testing.expect(pedestrian.Kernel.allowed(lease.profile(), from, to, (try view.edge(out)).*, .{}));
    const walk = pedestrian.Kernel.edgeCost(lease.profile(), lease.tables(), to, (try view.edge(out)).*, 0, .{});
    try testing.expect(walk.cost > 0 and walk.secs > 0);
    var bike_cache = try bicycle.Cache.init(testing.allocator, view.classes.?, 1);
    defer bike_cache.deinit();
    var bike = try bike_cache.acquire(try bicycle.parse(a, .null, &warnings, .none), .none);
    defer bike.release();
    const bike_turn = try bicycle.Turn.read(view, x, in, out);
    try testing.expect(bicycle.Kernel.allowed(bike.profile(), from, to, bike_turn.base_turn, .{}));
    const bicycle_crossing = bicycle.Kernel.turnCost(bike.profile(), try view.node(x), from, to, bike_turn);
    try testing.expectEqual(@as(f32, 4.5), bicycle_crossing.secs);
    try testing.expectApproxEqAbs(@as(f32, 10.4625), bicycle_crossing.cost, 1e-5);

    const elevator = try gurka.Map.init(a, try gurka.mapToCoordinates("A--K--B", 20), &.{
        .{ .label = "AK", .tags = &.{ footway[0], .{ .key = "level", .value = "2" } } },
        .{ .label = "KB", .tags = &.{ footway[0], .{ .key = "level", .value = "5" } } },
    }, &.{.{ .label = "K", .tags = &.{.{ .key = "highway", .value = "elevator" }} }}, &.{});
    var building = try Built.assemble(elevator.osm, 1);
    defer building.deinit();
    const lift_view = &building.bundle.view;
    const k = try at(lift_view, elevator.findNode("K").?.location.toFixed());
    const entry = try directedBetween(lift_view, &elevator, "A", "K");
    const exit = try directedBetween(lift_view, &elevator, "K", "B");
    const elevator_turn = try pedestrian.Turn.read(lift_view, k, entry, exit);
    try testing.expectEqual(3, elevator_turn.levels);
    const elevator_cost = pedestrian.Kernel.turnCost(lease.profile(), try lift_view.node(k), from, to, elevator_turn);
    try testing.expectEqual(@as(f32, 15), elevator_cost.cost);
    try testing.expectEqual(@as(f32, 0), elevator_cost.secs);
}

const search = routing.search.search;
const Cost = routing.costing.compiled.Cost;
const SearchTestCost = struct {
    seed: u32,
    omit: bool = false,
    ignore_turn_restrictions: bool = false,

    fn lengthCost(kernel: SearchTestCost, edge: format.EdgeId, len: u24) Cost {
        const weight = (@backingInt(edge) *% 2_654_435_761 +% kernel.seed) % 43;
        if (kernel.omit and weight < 6) return .forbidden;
        return .{ .cost = @floatFromInt(@as(u32, len) + weight), .secs = @floatFromInt(len) };
    }

    fn transitionCost(kernel: SearchTestCost, first: format.EdgeId, second: format.EdgeId, row: format.TurnEntry) Cost {
        const a = @backingInt(first);
        const b = @backingInt(second);
        const penalty = (a *% 951_177 +% b *% 37_157 +% kernel.seed) % 103;
        return .{ .cost = @floatFromInt(penalty), .secs = @floatFromInt((row >> 3) & 7) };
    }

    pub fn edgeCost(kernel: SearchTestCost, _: *const graph.reader.View, edge: format.EdgeId, hot: *const format.EdgeHot, _: search.Direction) !Cost {
        return kernel.lengthCost(edge, hot.geom.len_m);
    }

    pub fn allowedTurn(kernel: SearchTestCost, _: *const graph.reader.View, turn: search.Transition, _: search.Label, _: search.Direction) !bool {
        return kernel.ignore_turn_restrictions or turn.row & 0x80 == 0;
    }

    pub fn restrictionModes(kernel: SearchTestCost) u16 {
        return if (kernel.ignore_turn_restrictions) 0 else @bitCast(graph.constants.AccessMask{ .auto = true });
    }

    pub fn turnCost(kernel: SearchTestCost, _: *const graph.reader.View, turn: search.Transition, _: search.Label, _: search.Direction) !Cost {
        return kernel.transitionCost(turn.incoming, turn.outgoing, turn.row);
    }
};

const SearchTest = search.Search(SearchTestCost, routing.search.queue.Heap);

/// Array-scan Dijkstra over explicit directed-edge states. The reference
/// precomputes transitions by checking endpoints of every edge pair.
fn referenceSearch(a: std.mem.Allocator, view: *const graph.reader.View, kernel: SearchTestCost, request: search.Request) !?f32 {
    const reverse = request.direction == .reverse;
    const origin = @backingInt(if (reverse) request.destination else request.origin);
    const destination = @backingInt(if (reverse) request.origin else request.destination);
    if (origin == destination) return 0;
    const starts = try a.alloc(u32, view.edges.len);
    defer a.free(starts);
    for (0..view.nodes.len) |i| {
        const range = try view.outEdgeRange(@fromBackingInt(@as(u32, @intCast(i))));
        @memset(starts[range.first..range.end], @intCast(i));
    }
    const weights = try a.alloc(f32, view.edges.len);
    defer a.free(weights);
    const done = try a.alloc(bool, view.edges.len);
    defer a.free(done);
    @memset(done, false);
    const infinity = std.math.inf(f32);
    for (view.edges, starts, weights, 0..) |edge, start, *weight, i| {
        const begins_at = if (reverse) edge.head else start;
        weight.* = if (begins_at == origin) kernel.lengthCost(@fromBackingInt(@as(u32, @intCast(i))), edge.geom.len_m).cost else infinity;
    }
    while (true) {
        var best: ?usize = null;
        var distance = infinity;
        for (weights, done, 0..) |cost, settled, i| {
            if (!settled and cost < distance) {
                best = i;
                distance = cost;
            }
        }
        const index = best orelse return null;
        const current = view.edges[index];
        const node = if (reverse) starts[index] else current.head;
        if (node == destination) return distance;
        done[index] = true;
        for (view.edges, starts, weights, done, 0..) |next, start, *weight, settled, j| {
            if (settled or node != (if (reverse) next.head else start)) continue;
            const from = if (reverse) next else current;
            const to = if (reverse) current else next;
            const row = try view.turnRow(@fromBackingInt(node), from.cls.opp_local);
            if (row[to.cls.local] & 0x80 != 0) continue;
            const incoming: format.EdgeId = @fromBackingInt(@as(u32, @intCast(if (reverse) j else index)));
            const outgoing: format.EdgeId = @fromBackingInt(@as(u32, @intCast(if (reverse) index else j)));
            const candidate: format.EdgeId = @fromBackingInt(@as(u32, @intCast(j)));
            const delay = kernel.transitionCost(incoming, outgoing, row[to.cls.local]);
            const step = kernel.lengthCost(candidate, next.geom.len_m);
            weight.* = @min(weight.*, distance + (step.cost + delay.cost));
        }
    }
}

test "forward and reverse A* match reference Dijkstra on random ASCII maps" {
    const map_memory = routing.infra.arena;
    const template = "A---B---C\n|   |   |\nD---E---F\n|   |   |\nG---H---I";
    const links = [_][]const u8{ "AB", "BC", "AD", "BE", "CF", "DE", "EF", "DG", "EH", "FI", "GH", "HI" };
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    var prng = std.Random.DefaultPrng.init(0x320f1c6a);
    const random = prng.random();
    for (0..24) |_| {
        var fixture_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer fixture_arena.deinit();
        const a = fixture_arena.allocator();
        var ways: [links.len]gurka.Way = undefined;
        var count: usize = 0;
        for (links) |link| {
            if (count > 0 and random.uintLessThan(u8, 4) == 0) continue;
            ways[count] = .{ .label = link, .tags = road };
            count += 1;
        }
        const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates(template, 20), ways[0..count], &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        const view = &built.bundle.view;
        var engine = try SearchTest.init(testing.allocator, view);
        defer engine.deinit();
        var arena = map_memory.Arena.init(testing.allocator, .{});
        defer arena.deinit();
        for (0..8) |_| {
            const from: format.NodeId = @fromBackingInt(random.uintLessThan(u32, @intCast(view.nodes.len)));
            const to: format.NodeId = @fromBackingInt(random.uintLessThan(u32, @intCast(view.nodes.len)));
            const kernel: SearchTestCost = .{ .seed = random.int(u32), .omit = true };
            for ([_]search.Direction{ .forward, .reverse }) |direction| {
                const request: search.Request = .{ .origin = from, .destination = to, .direction = direction };
                const target = if (direction == .forward) to else from;
                const potential = try search.L2.init(view, target, 1);
                const expected = try referenceSearch(a, view, kernel, request);
                const actual = engine.run(&arena, kernel, request, potential, .{});
                if (expected) |cost| {
                    const result = try actual;
                    try testing.expectEqual(cost, result.best().cost);
                    var label = result.best();
                    while (label.pred != search.no_index) {
                        const predecessor = &result.labels[label.pred];
                        const before = if (direction == .forward) predecessor else label;
                        const after = if (direction == .forward) label else predecessor;
                        const before_edge = try view.edge(before.edgeId());
                        const after_opp = try view.edge(try view.oppEdge(after.edgeId()));
                        try testing.expectEqual(before_edge.head, after_opp.head);
                        label = predecessor;
                    }
                } else {
                    try testing.expectError(error.NoPath, actual);
                }
                arena.reset();
            }
        }
    }
}

const RestrictionPath = struct {
    edges: [4]u32 = undefined,
    len: usize,

    fn blocks(self: RestrictionPath, suffix: [3]u32, next: u32, reverse: bool) bool {
        if (next != self.edges[if (reverse) 0 else self.len - 1]) return false;
        for (suffix[0 .. self.len - 1], 0..) |edge, i| {
            if (edge != self.edges[if (reverse) i + 1 else self.len - i - 2]) return false;
        }
        return true;
    }
};

// Brute-force Dijkstra on the graph expanded by the last three physical
// edges. It compares literal sequences and never reads the compiled automaton.
fn referenceRestricted(a: std.mem.Allocator, view: *const graph.reader.View, patterns: []const RestrictionPath, starts: []const u32, kernel: SearchTestCost, request: search.Request) !?f32 {
    const reverse = request.direction == .reverse;
    const source = @backingInt(if (reverse) request.destination else request.origin);
    const target = @backingInt(if (reverse) request.origin else request.destination);
    if (source == target) return 0;
    const Suffix = [3]u32;
    const Entry = struct { suffix: Suffix, cost: f32, settled: bool = false };
    var queue: std.ArrayList(Entry) = .empty;
    defer queue.deinit(a);
    var index: std.AutoHashMapUnmanaged(Suffix, usize) = .empty;
    defer index.deinit(a);
    for (view.edges, starts, 0..) |edge, start, i| {
        if (source != (if (reverse) edge.head else start)) continue;
        const id: u32 = @intCast(i);
        const weight = kernel.lengthCost(@fromBackingInt(id), edge.geom.len_m).cost;
        const suffix: Suffix = .{ id, search.no_index, search.no_index };
        try index.put(a, suffix, queue.items.len);
        try queue.append(a, .{ .suffix = suffix, .cost = weight });
    }
    while (true) {
        var best: ?usize = null;
        var distance = std.math.inf(f32);
        for (queue.items, 0..) |row, i| {
            if (row.settled or row.cost >= distance) continue;
            best = i;
            distance = row.cost;
        }
        const chosen = best orelse return null;
        queue.items[chosen].settled = true;
        const suffix = queue.items[chosen].suffix;
        const current = suffix[0];
        const node = if (reverse) starts[current] else view.edges[current].head;
        if (node == target) return distance;
        for (view.edges, starts, 0..) |edge, start, i| {
            if (node != (if (reverse) edge.head else start)) continue;
            const next: u32 = @intCast(i);
            for (patterns) |rule| {
                if (rule.blocks(suffix, next, reverse)) break;
            } else {
                const incoming = if (reverse) next else current;
                const outgoing = if (reverse) current else next;
                const row = try view.turnRow(@fromBackingInt(node), view.edges[incoming].cls.opp_local);
                const turn = row[view.edges[outgoing].cls.local];
                const delay = kernel.transitionCost(@fromBackingInt(incoming), @fromBackingInt(outgoing), turn);
                const step = kernel.lengthCost(@fromBackingInt(next), edge.geom.len_m);
                const cost = distance + (step.cost + delay.cost);
                if (!std.math.isFinite(cost)) continue;
                const key: Suffix = .{ next, suffix[0], suffix[1] };
                const entry = try index.getOrPutValue(a, key, queue.items.len);
                if (entry.value_ptr.* == queue.items.len) {
                    try queue.append(a, .{ .suffix = key, .cost = cost });
                } else {
                    const row_cost = &queue.items[entry.value_ptr.*].cost;
                    row_cost.* = @min(row_cost.*, cost);
                }
            }
        }
    }
}

test "complex restriction search matches explicit state expansion on random graphs" {
    const template = "A---B---C\n|   |   |\nD---E---F\n|   |   |\nG---H---I";
    const links = [_][]const u8{ "AB", "BC", "AD", "BE", "CF", "DE", "EF", "DG", "EH", "FI", "GH", "HI" };
    const tags: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    var prng = std.Random.DefaultPrng.init(0x5685849e);
    const random = prng.random();
    for (0..16) |_| {
        var fixture_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer fixture_arena.deinit();
        const a = fixture_arena.allocator();
        var ways: std.ArrayList(gurka.Way) = .empty;
        for (links) |link| {
            if (ways.items.len != 0 and random.uintLessThan(u8, 4) == 0) continue;
            try ways.append(a, .{ .label = link, .tags = tags });
        }
        const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates(template, 20), ways.items, &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 1);
        defer built.deinit();
        var view = built.bundle.view;
        const edges = try a.dupe(format.EdgeHot, view.edges);
        const classes = try a.alloc(graph.class_table.EdgeClass, edges.len);
        for (edges, classes, 0..) |*edge, *class, i| {
            class.* = (try view.class(edge.cls.class_id)).*;
            edge.cls.class_id = @intCast(i);
        }
        const starts = try a.alloc(u32, edges.len);
        for (view.first_edge[0..view.nodes.len], view.first_edge[1..], 0..) |first, end, i| {
            @memset(starts[first..end], @intCast(i));
        }
        var builder: build.restriction_automaton.Builder = .{ .a = a, .deadline = .none };
        defer builder.deinit();
        var patterns: [12]RestrictionPath = undefined;
        for (&patterns) |*path| {
            path.len = random.intRangeAtMost(usize, 2, path.edges.len);
            var edge = random.uintLessThan(u32, @intCast(edges.len));
            for (path.edges[0..path.len]) |*step| {
                step.* = edge;
                const outbound = try view.outEdgeRange(@fromBackingInt(edges[edge].head));
                edge = outbound.first + random.uintLessThan(u32, outbound.count());
            }
            try builder.forbid(path.edges[0..path.len], 1);
            classes[path.edges[0]].restrictions.start = 1;
            classes[path.edges[path.len - 1]].restrictions.end = 1;
        }
        view.edges = edges;
        view.classes = classes;
        const program = try builder.finish(edges.len);
        defer program.deinit(a);
        view.restriction_automaton = program.states;
        var engine = try SearchTest.init(testing.allocator, &view);
        defer engine.deinit();
        var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
        defer arena.deinit();
        for (0..12) |_| {
            const origin: format.NodeId = @fromBackingInt(random.uintLessThan(u32, @intCast(view.nodes.len)));
            const destination: format.NodeId = @fromBackingInt(random.uintLessThan(u32, @intCast(view.nodes.len)));
            const kernel: SearchTestCost = .{ .seed = random.int(u32), .omit = true };
            for ([_]search.Direction{ .forward, .reverse }) |direction| {
                const request: search.Request = .{ .origin = origin, .destination = destination, .direction = direction };
                const cost = try referenceRestricted(testing.allocator, &view, &patterns, starts, kernel, request);
                const actual = engine.run(&arena, kernel, request, search.Zero{}, .{});
                if (cost) |expected| {
                    try testing.expectEqual(expected, (try actual).best().cost);
                } else {
                    try testing.expectError(error.NoPath, actual);
                }
                arena.reset();
            }
        }
    }
}

test "edge search reuses worker request memory and observes cancellation" {
    const mem = routing.infra.arena;
    var fixture_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer fixture_arena.deinit();
    const a = fixture_arena.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B---C", 20), &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "BC", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const origin = try at(view, fixture.findNode("A").?.location.toFixed());
    const destination = try at(view, fixture.findNode("C").?.location.toFixed());
    var counting = mem.CountingAllocator.init(testing.allocator);
    var engine = try SearchTest.init(counting.allocator(), view);
    defer engine.deinit();
    var arena = mem.Arena.init(counting.allocator(), .{});
    defer arena.deinit();
    const request: search.Request = .{ .origin = origin, .destination = destination };
    const potential = try search.L2.init(view, destination, 1);
    const result = try engine.run(&arena, .{ .seed = 42 }, request, potential, .{});
    const cost = result.best().cost;
    arena.reset();
    counting.resetCounts();
    for (0..8) |_| {
        const label = (try engine.run(&arena, .{ .seed = 42 }, request, potential, .{})).best();
        try testing.expectEqual(cost, label.cost);
        arena.reset();
    }
    try testing.expectEqual(0, counting.calls());
    const cancel: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Cancelled, engine.run(&arena, .{ .seed = 42 }, request, potential, .{ .cancel = &cancel }));
    try testing.expectError(error.Cancelled, engine.run(&arena, .{ .seed = 42 }, request, potential, .{ .deadline = .{ .at_ns = 0 } }));
}

fn snapEdge(edge: format.EdgeId, fraction: f32, distance: f64) routing.snap.candidates.PathEdge {
    return .{
        .id = edge,
        .percent_along = fraction,
        .projected = .init(0, 0),
        .distance = distance,
        .heading = 0,
        .node = if (fraction == 0) .begin else if (fraction == 1) .end else .none,
    };
}

fn snapLocation(edges: []const routing.snap.candidates.PathEdge, filtered: []const routing.snap.candidates.PathEdge) routing.snap.candidates.PathLocation {
    return .{ .edges = edges, .filtered_edges = filtered, .rank_candidates = true };
}

test "partial routes retain the travel fractions for direct and out-and-back paths" {
    const endpoints = routing.search.endpoints;
    var fixture_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer fixture_arena.deinit();
    const a = fixture_arena.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B", 20), &.{
        .{ .label = "AB", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const ba = try view.oppEdge(ab);
    var searcher = try SearchTest.init(testing.allocator, view);
    defer searcher.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    const kernel: SearchTestCost = .{ .seed = 47 };
    const start = snapLocation(&.{snapEdge(ab, 0.25, 0)}, &.{});
    const stop = snapLocation(&.{snapEdge(ab, 0.75, 0)}, &.{});
    const len: f32 = @floatFromInt((try view.edge(ab)).geom.len_m);
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const options: endpoints.Options = .{ .costing = .pedestrian, .direction = direction };
        const direct = try endpoints.route(&searcher, &arena, kernel, start, stop, options, search.Zero{}, .{});
        try testing.expectEqualSlices(endpoints.Segment, &.{.{ .edge = ab, .begin = 0.25, .end = 0.75 }}, direct.segments);
        try testing.expectEqual(len * 0.5, direct.secs);
        arena.reset();

        const alternatives = snapLocation(&.{ snapEdge(ab, 0.75, 6), snapEdge(ab, 0.5, 0) }, &.{});
        const ranked = try endpoints.route(&searcher, &arena, kernel, start, alternatives, options, search.Zero{}, .{});
        try testing.expectEqualSlices(endpoints.Segment, &.{.{ .edge = ab, .begin = 0.25, .end = 0.5 }}, ranked.segments);
        arena.reset();

        const back = try endpoints.route(&searcher, &arena, kernel, stop, start, options, search.Zero{}, .{});
        try testing.expectEqualSlices(endpoints.Segment, &.{
            .{ .edge = ab, .begin = 0.75, .end = 1 },
            .{ .edge = ba, .begin = 0, .end = 1 },
            .{ .edge = ab, .begin = 0, .end = 0.25 },
        }, back.segments);
        arena.reset();

        const begin_node = snapLocation(&.{ snapEdge(ba, 1, 0), snapEdge(ab, 0, 0) }, &.{});
        const end_node = snapLocation(&.{ snapEdge(ba, 0, 0), snapEdge(ab, 1, 0) }, &.{});
        const whole = try endpoints.route(&searcher, &arena, kernel, begin_node, end_node, options, search.Zero{}, .{});
        try testing.expectEqualSlices(endpoints.Segment, &.{.{ .edge = ab, .begin = 0, .end = 1 }}, whole.segments);
        arena.reset();
        const still = try endpoints.route(&searcher, &arena, kernel, end_node, end_node, options, search.Zero{}, .{});
        try testing.expectEqual(1, still.segments.len);
        try testing.expectEqual(still.segments[0].begin, still.segments[0].end);
        try testing.expectEqual(0, still.distance);
        arena.reset();
    }
}

test "ranked endpoint candidates choose between connected alternatives and filtered retries" {
    const endpoints = routing.search.endpoints;
    var fixture_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer fixture_arena.deinit();
    const a = fixture_arena.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B   C---D---E", 20), &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "CD", .tags = road },
        .{ .label = "DE", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const cd = try directedBetween(view, &fixture, "C", "D");
    const de = try directedBetween(view, &fixture, "D", "E");
    var searcher = try SearchTest.init(testing.allocator, view);
    defer searcher.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    const kernel: SearchTestCost = .{ .seed = 47 };
    const end = snapLocation(&.{snapEdge(de, 0.75, 0)}, &.{});
    const starts = [_]routing.snap.candidates.PathEdge{ snapEdge(ab, 0, 0), snapEdge(cd, 0.5, 0), snapEdge(de, 0.5, 100) };
    const path = try endpoints.route(&searcher, &arena, kernel, snapLocation(&starts, &.{}), end, .{ .costing = .pedestrian }, search.Zero{}, .{});
    try testing.expectEqualSlices(endpoints.Segment, &.{
        .{ .edge = cd, .begin = 0.5, .end = 1 },
        .{ .edge = de, .begin = 0, .end = 0.75 },
    }, path.segments);
    try testing.expect(!path.retried);
    arena.reset();

    const filtered = snapLocation(starts[0..1], starts[2..3]);
    const relaxed = try endpoints.route(&searcher, &arena, kernel, filtered, end, .{ .costing = .pedestrian }, search.Zero{}, .{});
    try testing.expectEqualSlices(endpoints.Segment, &.{.{ .edge = de, .begin = 0.5, .end = 0.75 }}, relaxed.segments);
    try testing.expect(relaxed.retried);
    const full = kernel.lengthCost(de, (try view.edge(de)).geom.len_m);
    try testing.expectApproxEqAbs(full.cost * 0.25 + 7200, relaxed.cost, 1e-3);
    arena.reset();
    try testing.expectError(error.NoPath, endpoints.route(&searcher, &arena, kernel, filtered, end, .{ .costing = .bicycle }, search.Zero{}, .{}));
    arena.reset();
    const promoted = try endpoints.route(&searcher, &arena, kernel, snapLocation(&.{}, starts[2..3]), end, .{ .costing = .bicycle }, search.Zero{}, .{});
    try testing.expectEqualDeep([2]bool{ true, false }, promoted.ignored_filter);
    try testing.expectApproxEqAbs(full.cost * 0.25, promoted.cost, 1e-5);
}

// Ported from the route clock and waiting cases in test/gurka/test_time_tracking.cc.
test "timed routes price each leg at its clock, apply break waiting and report local zones" {
    const multi = routing.search.multi;
    const api = routing.api.request;
    const FixedCost = struct {
        expected_times: [2]i64,
        seen: *[2]bool,

        pub fn edgeCost(_: @This(), _: *const graph.reader.View, _: format.EdgeId, _: *const format.EdgeHot, _: search.Direction) !Cost {
            return .{ .cost = 240, .secs = 240 };
        }

        pub fn edgeCostAt(self: @This(), view: *const graph.reader.View, id: format.EdgeId, edge: *const format.EdgeHot, direction: search.Direction, time: graph.time_info.TimeInfo) !search.Traversal {
            for (self.expected_times, self.seen) |instant, *seen| seen.* = seen.* or instant == time.unix_time;
            return .{ .cost = try self.edgeCost(view, id, edge, direction) };
        }

        pub fn turnCost(_: @This(), _: *const graph.reader.View, _: search.Transition, _: search.Label, _: search.Direction) !Cost {
            return .{};
        }
    };
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B---C", 20), &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "BC", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const correlations = [_]routing.snap.candidates.PathLocation{
        snapLocation(&.{snapEdge(ab, 0, 0)}, &.{}),
        snapLocation(&.{snapEdge(ab, 0.5, 0)}, &.{}),
        snapLocation(&.{snapEdge(ab, 1, 0)}, &.{}),
    };
    const origin = "2026-11-02T12:00";
    const departure = (try restrictionTiming(origin, false)).start.unix_time;
    var locations = [_]api.Location{
        .{ .lat = 0, .lng = 0, .date_time = origin, .waiting_secs = 90 },
        .{ .lat = 0, .lng = 0, .waiting_secs = 60 },
        .{ .lat = 0, .lng = 0, .date_time = "2026-11-02T12:05", .waiting_secs = 120 },
    };
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try search.Search(FixedCost, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();
    for ([_]api.DateTimeType{ .depart_at, .arrive_by, .current, .invariant }) |mode| {
        var seen = [2]bool{ false, false };
        const expected: [2]i64 = switch (mode) {
            .arrive_by => .{ departure + 300, departure + 120 },
            .invariant => .{ departure, departure },
            else => .{ departure, departure + 180 },
        };
        locations[0].date_time = if (mode == .current) "current" else origin;
        const route = try multi.route(&engine, &arena, FixedCost{ .expected_times = expected, .seen = &seen }, &locations, &correlations, .{
            .search = .{ .costing = .auto },
            .date_time_type = mode,
            .now = departure + 12,
        }, .{});
        try testing.expectEqual([2]bool{ true, true }, seen);
        try testing.expectEqual(@as(f32, 240), route.total.secs);
        try testing.expectEqualStrings(origin, route.waypoints[0].date_time.?);
        try testing.expectEqualStrings(if (mode == .invariant) origin else "2026-11-02T12:03", route.waypoints[1].date_time.?);
        try testing.expectEqualStrings(if (mode == .invariant) origin else "2026-11-02T12:05", route.waypoints[2].date_time.?);
        try testing.expectEqualStrings("+00:00", route.waypoints[1].time_zone_offset);
        try testing.expectEqual([3]f32{ 0, 60, 0 }, .{ route.waypoints[0].waiting_secs, route.waypoints[1].waiting_secs, route.waypoints[2].waiting_secs });
        try testing.expectEqual(@as(usize, 2), route.legs.len);
        for (route.legs) |leg| {
            try testing.expectEqual(@as(usize, 1), leg.segments.len);
            try testing.expectEqual(ab, leg.segments[0].edge);
        }
        seen = .{ false, false };
        const leg_clocks: [2]i64 = .{ departure, if (mode == .invariant) departure else departure + 180 };
        const trip = try routing.search.legs.build(arena.allocator(), view, FixedCost{ .expected_times = leg_clocks, .seen = &seen }, route, &correlations, .{});
        try testing.expectEqual([2]bool{ true, true }, seen);
        try testing.expectEqual(@as(f64, route.total.secs), trip.summary.time);
        arena.reset();
    }

    locations[0].date_time = origin;
    locations[1].type = .through;
    var seen = [2]bool{ false, false };
    const through = try multi.route(&engine, &arena, FixedCost{ .expected_times = .{ departure, departure + 120 }, .seen = &seen }, &locations, &correlations, .{
        .search = .{ .costing = .auto },
        .date_time_type = .depart_at,
        .now = departure,
    }, .{});
    try testing.expectEqual([2]bool{ true, true }, seen);
    try testing.expectEqual(1, through.legs.len);
    try testing.expectEqual(0, through.waypoints[1].waiting_secs);
    try testing.expectEqualStrings("2026-11-02T12:02", through.waypoints[1].date_time.?);
    try testing.expectEqualStrings("2026-11-02T12:04", through.waypoints[2].date_time.?);
    arena.reset();

    const bytes = try io.readFileAlloc(a, "src/graph/timezones/iana-2026f.ztz", 4 << 20);
    const aligned = try a.alignedAlloc(u8, .@"8", bytes.len);
    @memcpy(aligned, bytes);
    const rules = try graph.timezone.Rules.parse(aligned);
    const ny = try rules.id("America/New_York");
    const la = try rules.id("America/Los_Angeles");
    const bc = try directedBetween(view, &fixture, "B", "C");
    var zoned = view.*;
    const zones = try a.alloc(graph.timezone.Id, view.nodes.len);
    @memset(zones, ny);
    zones[(try view.edge(bc)).head] = la;
    zoned.node_timezones = zones;
    zoned.tz_rules = rules;
    var zoned_engine = try search.Search(FixedCost, routing.search.queue.Heap).init(testing.allocator, &zoned);
    defer zoned_engine.deinit();
    const cross_zone = [_]routing.snap.candidates.PathLocation{
        snapLocation(&.{snapEdge(ab, 0.25, 0)}, &.{}),
        snapLocation(&.{snapEdge(bc, 0.75, 0)}, &.{}),
    };
    const local_start = "2016-03-13T01:57";
    const local_end = "2016-03-12T23:03";
    const start = try graph.time_info.TimeInfo.fromLocal(&rules, local_start, ny, graph.timezone.utc, 0, .none);
    const stops: [2]api.Location = .{
        .{ .lat = 0, .lng = 0, .date_time = local_start },
        .{ .lat = 0, .lng = 0, .date_time = local_end },
    };
    for ([_]api.DateTimeType{ .depart_at, .arrive_by }) |mode| {
        seen = .{ false, false };
        const anchor_time = if (mode == .depart_at) start.unix_time else start.unix_time + 360;
        const route = try multi.route(&zoned_engine, &arena, FixedCost{ .expected_times = .{ anchor_time, start.unix_time + 180 }, .seen = &seen }, &stops, &cross_zone, .{
            .search = .{ .costing = .auto },
            .date_time_type = mode,
            .now = start.unix_time,
        }, .{});
        try testing.expectEqual([2]bool{ true, true }, seen);
        try testing.expectEqual(@as(f32, 360), route.total.secs);
        try testing.expectEqualStrings(local_start, route.waypoints[0].date_time.?);
        try testing.expectEqualStrings("-05:00", route.waypoints[0].time_zone_offset);
        try testing.expectEqualStrings("America/New_York", route.waypoints[0].time_zone_name);
        try testing.expectEqualStrings(local_end, route.waypoints[1].date_time.?);
        try testing.expectEqualStrings("-08:00", route.waypoints[1].time_zone_offset);
        try testing.expectEqualStrings("America/Los_Angeles", route.waypoints[1].time_zone_name);
        arena.reset();
    }
}

test "multi-location route types split legs and preserve through direction" {
    const multi = routing.search.multi;
    var fixture_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer fixture_arena.deinit();
    const a = fixture_arena.allocator();
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B", 20), &.{
        .{ .label = "AB", .tags = &.{.{ .key = "highway", .value = "residential" }} },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const ba = try view.oppEdge(ab);
    const len: f64 = @floatFromInt((try view.edge(ab)).geom.len_m);
    var engine = try SearchTest.init(testing.allocator, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();

    const correlations = [_]routing.snap.candidates.PathLocation{
        snapLocation(&.{ snapEdge(ab, 0.1, 0), snapEdge(ba, 0.9, 0) }, &.{}),
        snapLocation(&.{ snapEdge(ab, 0.5, 0), snapEdge(ba, 0.5, 0) }, &.{}),
        snapLocation(&.{ snapEdge(ab, 0.2, 0), snapEdge(ba, 0.8, 0) }, &.{}),
    };
    var locations = [_]routing.api.request.Location{
        .{ .lat = 0, .lng = 0 },
        .{ .lat = 0, .lng = 0, .waiting_secs = 25, .date_time = "2026-10-02T12:00" },
        .{ .lat = 0, .lng = 0 },
    };
    const cases = [_]struct { kind: routing.api.request.LocationType, legs: usize, distance: f64 }{
        .{ .kind = .@"break", .legs = 2, .distance = 0.7 },
        .{ .kind = .via, .legs = 1, .distance = 0.7 },
        .{ .kind = .through, .legs = 1, .distance = 1.7 },
        .{ .kind = .break_through, .legs = 2, .distance = 1.7 },
    };
    const kernel: SearchTestCost = .{ .seed = 47 };
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        for (cases) |item| {
            locations[1].type = item.kind;
            const route = try multi.route(&engine, &arena, kernel, &locations, &correlations, .{
                .search = .{ .costing = .pedestrian, .direction = direction },
            }, .{});
            try testing.expectEqual(item.legs, route.legs.len);
            try testing.expectEqual(0, route.legs[0].origin);
            try testing.expectEqual(2, route.legs[route.legs.len - 1].destination);
            var distance: f64 = 0;
            for (route.legs) |leg| distance += @as(f64, leg.length_km) * 1000;
            try testing.expectApproxEqAbs(item.distance * len, distance, 1e-4);
            try testing.expectEqual(@as(f32, 25), route.waypoints[1].waiting_secs);
            try testing.expectEqualStrings("2026-10-02T12:00", route.waypoints[1].date_time.?);
            try testing.expect(route.waypoints[1].elapsed_secs > 0);
            try testing.expect(route.waypoints[1].elapsed_secs < route.waypoints[2].elapsed_secs);
            try testing.expectEqual(route.total.secs, route.waypoints[2].elapsed_secs);
            arena.reset();
        }

        const at_end = [_]routing.snap.candidates.PathLocation{
            correlations[0],
            snapLocation(&.{ snapEdge(ab, 1, 0), snapEdge(ba, 0, 0) }, &.{}),
            correlations[2],
        };
        const options: multi.Options = .{ .search = .{ .costing = .pedestrian, .direction = direction } };
        locations[1].type = .through;
        try testing.expectError(error.NoPath, multi.route(&engine, &arena, kernel, &locations, &at_end, options, .{}));
        arena.reset();
        locations[1].type = .via;
        const via = try multi.route(&engine, &arena, kernel, &locations, &at_end, options, .{});
        try testing.expectEqual(1, via.legs.len);
        try testing.expectEqual(2, via.legs[0].segments.len);
        try testing.expectEqual(ab, via.legs[0].segments[0].edge);
        try testing.expectEqual(ba, via.legs[0].segments[1].edge);
        arena.reset();
    }
}

test "route leg recost preserves the intersection turn at a stitched node" {
    const multi = routing.search.multi;
    const legs = routing.search.legs;
    const point = routing.geo.PointLL;
    var fixture_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer fixture_arena.deinit();
    const a = fixture_arena.allocator();
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A   B\n  X |\n    C", 20), &.{
        .{ .label = "AXB", .tags = &.{ .{ .key = "highway", .value = "motorway" }, .{ .key = "toll", .value = "yes" } } },
        .{ .label = "BC", .tags = &.{.{ .key = "route", .value = "ferry" }} },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const bc = try directedBetween(view, &fixture, "B", "C");
    const first = fixture.findNode("A").?.location.toFixed().toTilePoint();
    const bend = fixture.findNode("X").?.location.toFixed().toTilePoint();
    const joint = fixture.findNode("B").?.location.toFixed().toTilePoint();
    const last = fixture.findNode("C").?.location.toFixed().toTilePoint();
    var origin = snapEdge(ab, 0.25, 0);
    origin.projected = first.pointAlongSegment(bend, 0.5);
    var destination = snapEdge(bc, 0.75, 0);
    destination.projected = joint.pointAlongSegment(last, 0.75);
    const correlations = [_]routing.snap.candidates.PathLocation{
        snapLocation(&.{origin}, &.{}),
        snapLocation(&.{ snapEdge(ab, 1, 0), snapEdge(bc, 0, 0) }, &.{}),
        snapLocation(&.{destination}, &.{}),
    };
    const locations = [_]routing.api.request.Location{
        .{ .lng = origin.projected.lng, .lat = origin.projected.lat },
        .{ .lng = joint.lng, .lat = joint.lat, .type = .through },
        .{ .lng = destination.projected.lng, .lat = destination.projected.lat },
    };

    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try SearchTest.init(testing.allocator, view);
    defer engine.deinit();
    const kernel: SearchTestCost = .{ .seed = 47 };
    const ab_hot = try view.edge(ab);
    const bc_hot = try view.edge(bc);
    const row = try view.turnRow(@fromBackingInt(ab_hot.head), ab_hot.cls.opp_local);
    const delay = kernel.transitionCost(ab, bc, row[bc_hot.cls.local]);
    const first_cost = kernel.lengthCost(ab, ab_hot.geom.len_m);
    const last_cost = kernel.lengthCost(bc, bc_hot.geom.len_m);
    try testing.expect(delay.cost > 0);
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const found = try multi.route(&engine, &arena, kernel, &locations, &correlations, .{
            .search = .{ .costing = .pedestrian, .direction = direction },
        }, .{});
        const trip = try legs.build(arena.allocator(), view, kernel, found, &correlations, .{});
        try testing.expectEqual(@as(usize, 1), trip.legs.len);
        const leg = trip.legs[0];
        const expected: []const point = &.{ origin.projected, bend, joint, destination.projected };
        try testing.expectEqualSlices(point, expected, leg.shape);
        const encoded = try routing.geo.polyline.encodeAlloc(arena.allocator(), .polyline, 6, expected);
        try testing.expectEqualStrings(encoded, leg.encoded_shape);
        try testing.expectEqual(routing.geo.AABB.of(expected), trip.summary.bounds);
        try testing.expect(trip.summary.has_toll and trip.summary.has_highway and trip.summary.has_ferry);
        try testing.expectEqual(@as(usize, 2), leg.edges.len);
        try testing.expectEqual(leg.edges[0].shape_end, leg.edges[1].shape_begin);
        try testing.expectEqual(delay, leg.edges[1].transition);
        try testing.expectEqual(first_cost.secs * 0.75, leg.edges[0].elapsed.secs);
        try testing.expectApproxEqAbs(@as(f64, (first_cost.secs + last_cost.secs) * 0.75), trip.summary.length_m, 1e-4);
        try testing.expectEqual(@as(f64, first_cost.secs * 0.75 + (last_cost.secs * 0.75 + delay.secs)), trip.summary.time);
        try testing.expectEqual(@as(f64, first_cost.cost * 0.75 + (last_cost.cost * 0.75 + delay.cost)), trip.summary.cost);
        try testing.expectError(error.Cancelled, legs.build(arena.allocator(), view, kernel, found, &correlations, .{ .deadline = .{ .at_ns = 0 } }));
        arena.reset();
    }

    const ba = try view.oppEdge(ab);
    var from_node = snapEdge(ba, 0, 0);
    from_node.projected = joint;
    var to_node = snapEdge(ba, 1, 0);
    to_node.projected = first;
    const opposing = [_]routing.snap.candidates.PathLocation{
        snapLocation(&.{from_node}, &.{}),
        snapLocation(&.{to_node}, &.{}),
    };
    const from_b: routing.api.request.Location = .{ .lng = joint.lng, .lat = joint.lat };
    const to_a: routing.api.request.Location = .{ .lng = first.lng, .lat = first.lat };
    const reversed = try multi.route(&engine, &arena, kernel, &.{ from_b, to_a }, &opposing, .{
        .search = .{ .costing = .pedestrian },
    }, .{});
    const trip = try legs.build(arena.allocator(), view, kernel, reversed, &opposing, .{});
    try testing.expectEqualSlices(point, &.{ joint, bend, first }, trip.legs[0].shape);
}

test "multi-location continuation retries the route with reachable waypoint candidates" {
    const multi = routing.search.multi;
    var fixture_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer fixture_arena.deinit();
    const a = fixture_arena.allocator();
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A---B   C---D---E", 20), &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "CD", .tags = road },
        .{ .label = "DE", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const cd = try directedBetween(view, &fixture, "C", "D");
    const de = try directedBetween(view, &fixture, "D", "E");
    var engine = try SearchTest.init(testing.allocator, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();

    var high = snapEdge(cd, 0.5, 20);
    high.reach = .{ .inbound = 50, .outbound = 50 };
    const correlations = [_]routing.snap.candidates.PathLocation{
        snapLocation(&.{ snapEdge(ab, 0.25, 0), snapEdge(cd, 0.25, 10) }, &.{}),
        snapLocation(&.{ snapEdge(ab, 0.5, 0), high }, &.{}),
        snapLocation(&.{snapEdge(de, 0.75, 0)}, &.{}),
    };
    const locations = [_]routing.api.request.Location{
        .{ .lat = 0, .lng = 0 },
        .{ .lat = 0, .lng = 0, .type = .through },
        .{ .lat = 0, .lng = 0 },
    };
    const route = try multi.route(&engine, &arena, SearchTestCost{ .seed = 47 }, &locations, &correlations, .{
        .search = .{ .costing = .pedestrian },
    }, .{});
    try testing.expect(route.retried);
    try testing.expectEqual(1, route.legs.len);
    try testing.expectEqual(cd, route.legs[0].segments[0].edge);
    try testing.expectEqual(de, route.legs[0].segments[route.legs[0].segments.len - 1].edge);
}

test "regional registry snaps and routes in one bundle and rejects cross-bundle input" {
    const snap = routing.snap;
    const request = routing.api.request;
    const Point = routing.geo.point.PointLL;
    const roads = [_]gurka.Way{
        .{ .label = "AB", .tags = &.{.{ .key = "highway", .value = "residential" }} },
        .{ .label = "BC", .tags = &.{.{ .key = "highway", .value = "residential" }} },
    };
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const west = try gurka.Map.init(a, try gurka.mapToCoordinatesAt("A---B---C", 20, Point.init(-105, 40)), &roads, &.{}, &.{});
    const east = try gurka.Map.init(a, try gurka.mapToCoordinatesAt("A---B---C", 20, Point.init(10, 51)), &roads, &.{}, &.{});
    var west_bundle = try Built.assemble(west.osm, 1);
    defer west_bundle.deinit();
    var east_bundle = try Built.assemble(east.osm, 1);
    defer east_bundle.deinit();

    const regions = [_]snap.registry.Region{
        try .init("west", &west_bundle.bundle.view, .none),
        try .init("east", &east_bundle.bundle.view, .none),
    };
    const registry: snap.registry.Registry = .{ .regions = &regions };
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    const defaults: snap.candidates.Defaults = .{ .minimum_reachability = 0 };
    const cost: snap.candidates.Access = .{ .mask = .{ .pedestrian = true } };
    var locations: [2][2]request.Location = undefined;
    for ([_]gurka.Map{ west, east }, &regions, &locations) |region, *expected, *inputs| {
        for ([_][]const u8{ "A", "C" }, inputs) |label, *input| {
            const node = region.findNode(label).?.location;
            input.* = .{ .lat = node.lat, .lng = node.lng };
        }
        const selected = (try registry.snap(&arena, inputs, defaults, cost, .none)).ok;
        try testing.expectEqual(expected, selected.region);
        var engine = try SearchTest.init(testing.allocator, selected.region.view);
        defer engine.deinit();
        const route = try routing.search.multi.route(&engine, &arena, SearchTestCost{ .seed = 42 }, inputs, selected.locations, .{
            .search = .{ .costing = .pedestrian },
        }, .{});
        try testing.expectEqual(@as(usize, 1), route.legs.len);
        try testing.expectEqual(@as(usize, 2), route.legs[0].segments.len);
        arena.reset();
    }

    const cross = try registry.snap(&arena, &.{ locations[0][0], locations[1][1] }, defaults, cost, .none);
    try testing.expectEqual(@as(u16, 170), cross.failure.code);
    try testing.expectEqualStrings("locations span multiple graph bundles", cross.failure.extra);
    try testing.expectEqual(@as(usize, 0), arena.used);

    var outside = locations[0][0];
    outside.lat += 0.00002;
    const raw = try snap.candidates.search(regions[0].view, arena.allocator(), outside, defaults, cost, .none);
    try testing.expect(raw.edges.len != 0 or raw.filtered_edges.len != 0);
    arena.reset();
    const uncovered = try registry.snap(&arena, &.{ outside, locations[0][1] }, defaults, cost, .none);
    try testing.expectEqual(@as(u16, 171), uncovered.failure.code);

    var legacy = west_bundle.bundle.view;
    legacy.coverage = null;
    const derived = try snap.registry.Region.init("legacy", &legacy, .none);
    try testing.expectEqual(regions[0].bounds, derived.bounds);
    try testing.expectError(error.DeadlineExceeded, registry.snap(&arena, &locations[0], defaults, cost, .{ .at_ns = 0 }));
}

test "Gurka multilingual direction names and phonemes share the cold string table" {
    const linguistic = graph.linguistics;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const fixture = try @import("examples.zig").streetLinguistics(storage.allocator());
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try view.verify(.none, null);
    const ab = try directedBetween(view, &fixture, "A", "B");
    const bc = try directedBetween(view, &fixture, "B", "C");
    const bd = try directedBetween(view, &fixture, "B", "D");
    for ([_]format.EdgeId{ ab, try view.oppEdge(ab) }) |edge| {
        const bilingual = try view.names(edge);
        try testing.expectEqual(2, bilingual.count());
        const fr = try bilingual.at(0);
        const nl = try bilingual.at(1);
        try testing.expectEqualStrings("Rive droite", fr.text);
        try testing.expectEqual(linguistic.Language.fr, fr.language);
        try testing.expectEqualStrings("riv dʁwat", fr.pronunciation.?.text);
        try testing.expectEqualStrings("Rechteroever", nl.text);
        try testing.expectEqual(linguistic.Language.nl, nl.language);
        try testing.expectEqual(linguistic.Alphabet.nt_sampa, nl.pronunciation.?.alphabet);
        try testing.expectEqualStrings("rExt@ruv@r", nl.pronunciation.?.text);
    }
    const east = try (try view.names(bc)).at(0);
    const west = try (try view.names(try view.oppEdge(bc))).at(0);
    try testing.expectEqualStrings("Place Est", east.text);
    try testing.expectEqual(linguistic.Language.fr, east.language);
    try testing.expectEqualStrings("plas ɛst", east.pronunciation.?.text);
    try testing.expectEqualStrings("Westplein", west.text);
    try testing.expectEqual(linguistic.Language.nl, west.language);
    try testing.expectEqualStrings("ʋɛstplɛin", west.pronunciation.?.text);

    const ce = try directedBetween(view, &fixture, "C", "E");
    for ([_]struct {
        edge: format.EdgeId,
        name: []const u8,
        language: linguistic.Language,
        ref: []const u8,
        phoneme: []const u8,
    }{
        .{ .edge = ce, .name = "Rue Orient", .language = .fr, .ref = "R 12", .phoneme = "ɛʁ duz" },
        .{ .edge = try view.oppEdge(ce), .name = "Weststraat", .language = .nl, .ref = "R 13", .phoneme = "ɛr dɛrtin" },
    }) |expected| {
        const names = try view.names(expected.edge);
        try testing.expectEqual(2, names.count());
        const name = try names.at(0);
        try testing.expectEqualStrings(expected.name, name.text);
        try testing.expectEqual(expected.language, name.language);
        try testing.expectEqual(null, name.pronunciation);
        const ref = try names.at(1);
        try testing.expect(ref.route);
        try testing.expectEqualStrings(expected.ref, ref.text);
        try testing.expectEqual(linguistic.Alphabet.ipa, ref.pronunciation.?.alphabet);
        try testing.expectEqualStrings(expected.phoneme, ref.pronunciation.?.text);
    }

    try testing.expectEqual(2, (try view.names(bd)).count());
    const tags = try view.namesWithOptions(bd, .{ .include_tagged = true });
    try testing.expectEqual(8, tags.count());
    try testing.expectEqualStrings("BD", (try tags.at(0)).text);
    const ref = try tags.at(1);
    try testing.expect(ref.route);
    try testing.expectEqualStrings("N 1", ref.text);
    const first_tunnel = try tags.at(2);
    try testing.expectEqual(linguistic.Tag.tunnel, first_tunnel.tagged.?);
    try testing.expectEqualStrings("Tunnel du Pont", first_tunnel.text);
    try testing.expectEqualStrings("tynɛl dy pɔ̃", first_tunnel.pronunciation.?.text);
    try testing.expectEqualStrings("Brug Tunnel", (try tags.at(3)).text);
    try testing.expectEqual(linguistic.Tag.layer, (try tags.at(4)).tagged.?);
    try testing.expectEqualStrings("\xfe", (try tags.at(4)).text);
    try testing.expectEqual(linguistic.Tag.levels, (try tags.at(5)).tagged.?);
    try testing.expectEqualStrings("\x0e\x02\x00\x28\xfe\xff\x7f\x46", (try tags.at(5)).text);
    try testing.expectEqual(linguistic.Tag.level_ref, (try tags.at(6)).tagged.?);
    try testing.expectEqualStrings("B2", (try tags.at(6)).text);
    try testing.expectEqualStrings("G", (try tags.at(7)).text);
}

test "Gurka lane masks follow directed tags and keep connectivity on each target edge" {
    const lanes = graph.lanes;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const fixture = try @import("examples.zig").turnLanes(storage.allocator());
    var built = try Built.assemble(fixture.osm, 2);
    defer built.deinit();
    const view = &built.bundle.view;
    try view.verify(.none, null);
    const cases = [_]struct {
        from: []const u8,
        to: []const u8,
        count: u4,
        masks: []const lanes.Mask,
        connection: bool,
    }{
        .{ .from = "A", .to = "B", .count = 2, .masks = &.{ lanes.left, lanes.through, lanes.through, lanes.right }, .connection = true },
        .{ .from = "B", .to = "A", .count = 2, .masks = &.{}, .connection = true },
        .{ .from = "B", .to = "C", .count = 2, .masks = &.{ lanes.left, lanes.through, lanes.through, lanes.right }, .connection = true },
        .{ .from = "C", .to = "B", .count = 2, .masks = &.{}, .connection = true },
        .{ .from = "B", .to = "D", .count = 1, .masks = &.{}, .connection = false },
        .{ .from = "D", .to = "B", .count = 3, .masks = &.{ lanes.left, lanes.through, lanes.through | lanes.right }, .connection = false },
    };
    for (cases) |case| {
        const edge = try directedBetween(view, &fixture, case.from, case.to);
        const class = try view.class((try view.edge(edge)).cls.class_id);
        try testing.expectEqual(case.count, class.category.lanes);
        try testing.expectEqual(case.masks.len != 0, class.flags.turnlanes);
        try testing.expectEqual(case.connection, class.flags.lane_conn);
        try testing.expectEqualSlices(lanes.Mask, case.masks, try lanes.turnLanes(view, edge));
        const connectivity = try lanes.laneConnectivity(view, edge);
        try testing.expectEqual(@intFromBool(case.connection), connectivity.len);
        if (case.connection) {
            try testing.expectEqual(@as(u64, @intCast(fixture.findWay("DB").?.id)), connectivity[0].from_way);
            try testing.expectEqual(0x221, connectivity[0].to_lanes);
            try testing.expectEqual(0x321, connectivity[0].from_lanes);
        }
    }
}

test "directional lane tags override general tags and inferred indications honor no turns" {
    const lanes = graph.lanes;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const road = gurka.Tag{ .key = "highway", .value = "primary" };
    const from_ab = gurka.Member{ .kind = .way, .ref = "AB", .role = "from" };
    const from_db = gurka.Member{ .kind = .way, .ref = "DB", .role = "from" };
    const to_bc = gurka.Member{ .kind = .way, .ref = "BC", .role = "to" };
    const fixture = try gurka.Map.init(storage.allocator(), try gurka.mapToCoordinates("A----B----C\n     |\n     D", 100), &.{
        .{ .label = "AB", .tags = &.{
            road,
            .{ .key = "oneway", .value = "-1" },
            .{ .key = "turn:lanes", .value = "through|through" },
            .{ .key = "turn:lanes:forward", .value = "left|right" },
            .{ .key = "turn:lanes:backward", .value = "reverse|merge_to_left" },
        } },
        .{ .label = "BC", .tags = &.{
            road,
            .{ .key = "turn:lanes:backward", .value = "left|right" },
        } },
        .{ .label = "DB", .tags = &.{ road, .{ .key = "turn:lanes", .value = "left|none|none" } } },
    }, &.{}, &.{
        .{
            .members = &.{ from_db, .{ .kind = .node, .ref = "B", .role = "via" }, to_bc },
            .tags = &.{ .{ .key = "type", .value = "restriction" }, .{ .key = "restriction", .value = "no_right_turn" } },
        },
        .{
            .members = &.{ from_ab, to_bc },
            .tags = &.{ .{ .key = "type", .value = "connectivity" }, .{ .key = "from", .value = "1" }, .{ .key = "to", .value = "1" } },
        },
        .{
            .members = &.{ from_db, to_bc },
            .tags = &.{ .{ .key = "type", .value = "connectivity" }, .{ .key = "from", .value = "1|16" }, .{ .key = "to", .value = "1|2" } },
        },
    });
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    try view.verify(.none, null);
    const ab = try directedBetween(view, &fixture, "A", "B");
    const bc = try directedBetween(view, &fixture, "B", "C");
    const db = try directedBetween(view, &fixture, "D", "B");
    try testing.expectEqualSlices(lanes.Mask, &.{ lanes.left, lanes.right }, try lanes.turnLanes(view, ab));
    try testing.expectEqualSlices(lanes.Mask, &.{}, try lanes.turnLanes(view, try view.oppEdge(ab)));
    try testing.expectEqualSlices(lanes.Mask, &.{}, try lanes.turnLanes(view, bc));
    try testing.expectEqualSlices(lanes.Mask, &.{ lanes.left, lanes.right }, try lanes.turnLanes(view, try view.oppEdge(bc)));
    try testing.expectEqualSlices(lanes.Mask, &.{ lanes.left, lanes.through, lanes.through }, try lanes.turnLanes(view, db));
    try testing.expectEqual(0, (try lanes.laneConnectivity(view, bc)).len);
    try testing.expect(view.lane_connectivity == null);
}

test "signs preserve exits, forks, directions and named nodes from PBF" {
    const sign = graph.signs;
    const Expected = struct { kind: sign.Type, text: []const u8, route: bool = false };
    const cases: []const struct { from: []const u8, to: []const u8, signs: []const Expected } = &.{
        .{ .from = "B", .to = "J", .signs = &.{
            .{ .kind = .exit_number, .text = "5" },
            .{ .kind = .exit_branch, .text = "I 95" },
            .{ .kind = .exit_toward, .text = "I 695" },
            .{ .kind = .exit_toward, .text = "Airport" },
            .{ .kind = .exit_toward, .text = "Downtown" },
            .{ .kind = .exit_name, .text = "West Exit" },
        } },
        .{ .from = "J", .to = "B", .signs = &.{} },
        .{ .from = "B", .to = "C", .signs = &.{} },
        .{ .from = "C", .to = "E", .signs = &.{
            .{ .kind = .exit_number, .text = "9A" },
            .{ .kind = .exit_number, .text = "9B" },
            .{ .kind = .exit_branch, .text = "A 1", .route = true },
            .{ .kind = .exit_branch, .text = "A 2", .route = true },
            .{ .kind = .exit_branch, .text = "West Road" },
            .{ .kind = .exit_branch, .text = " West Spur" },
            .{ .kind = .exit_toward, .text = "B 7", .route = true },
            .{ .kind = .exit_toward, .text = "East Road" },
            .{ .kind = .exit_toward, .text = "Harbour" },
            .{ .kind = .exit_toward, .text = "Parks" },
            .{ .kind = .exit_toward, .text = "Harbour" },
            .{ .kind = .exit_name, .text = "East Exit" },
            .{ .kind = .exit_name, .text = "Clover Junction" },
        } },
        .{ .from = "D", .to = "F", .signs = &.{.{ .kind = .guide_toward, .text = "Museum" }} },
        .{ .from = "F", .to = "D", .signs = &.{.{ .kind = .guide_toward, .text = "Old Town" }} },
        .{ .from = "G", .to = "H", .signs = &.{
            .{ .kind = .exit_branch, .text = "M 2", .route = true },
            .{ .kind = .exit_toward, .text = "Coast" },
        } },
        .{ .from = "G", .to = "I", .signs = &.{.{ .kind = .exit_toward, .text = "Hills" }} },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").signs(arena.allocator());
    var result = try Built.assemble(fixture.osm, 4);
    defer result.deinit();
    const view = &result.bundle.view;
    try view.verify(.none, null);
    for (cases) |case| {
        const from = try at(view, fixture.findNode(case.from).?.location.toFixed());
        const to = try at(view, fixture.findNode(case.to).?.location.toFixed());
        const range = try view.outEdgeRange(from);
        const id: format.EdgeId = for (range.first..range.end) |slot| {
            if (view.edges[slot].head == @backingInt(to)) break @fromBackingInt(@as(u32, @intCast(slot)));
        } else return error.MissingTestEdge;
        try testing.expectEqual(case.signs.len != 0, try sign.hasSigns(view, id));
        const rows = try sign.signsForEdge(view, id);
        try testing.expectEqual(case.signs.len, rows.len);
        for (rows, case.signs) |row, expected| {
            try testing.expectEqual(expected.kind, row.attr.sign_type);
            try testing.expectEqual(expected.route, row.attr.route_number);
            try testing.expect(!row.attr.tagged);
            try testing.expectEqualStrings(expected.text, try row.text(view.cold_data.?));
        }
    }
    const junction = try at(view, fixture.findNode("D").?.location.toFixed());
    const junction_signs = try sign.signsForNode(view, junction);
    try testing.expectEqual(2, junction_signs.len);
    for (junction_signs, [_][]const u8{ "Central Crossing", "North Crossing" }) |row, expected| {
        try testing.expectEqual(sign.Type.junction_name, row.attr.sign_type);
        try testing.expectEqualStrings(expected, try row.text(view.cold_data.?));
    }
    const toll = try at(view, fixture.findNode("F").?.location.toFixed());
    const toll_signs = try sign.signsForNode(view, toll);
    try testing.expectEqual(1, toll_signs.len);
    try testing.expectEqual(sign.Type.toll_name, toll_signs[0].attr.sign_type);
    try testing.expectEqualStrings("River Toll", try toll_signs[0].text(view.cold_data.?));
    const exit = try at(view, fixture.findNode("B").?.location.toFixed());
    try testing.expectEqual(0, (try sign.signsForNode(view, exit)).len);
}

// Ported from test/gurka/test_stopimpact.cc (Valhalla 3.9.3).
test "stop impact follows crossings and way changes" {
    const motorway: gurka.Tags = &.{ .{ .key = "highway", .value = "motorway" }, .{ .key = "oneway", .value = "yes" } };
    const primary: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    const residence: gurka.Tag = .{ .key = "highway", .value = "residential" };
    const cycleway: gurka.Tags = &.{.{ .key = "highway", .value = "cycleway" }};
    const crossing = "         D\n         |\nA--------B--------C\n         |\n         E";
    const Movement = struct { from: []const u8, via: []const u8, to: []const u8, stopped: bool };
    const straight: Movement = .{ .from = "A", .via = "B", .to = "C", .stopped = false };
    const straight_with_stop: Movement = .{ .from = "A", .via = "B", .to = "C", .stopped = true };
    const cross: Movement = .{ .from = "D", .via = "B", .to = "E", .stopped = true };
    const cases: []const struct { map: []const u8, ways: []const gurka.Way, turns: []const Movement } = &.{
        .{
            .map = "A-----------B-----------C",
            .ways = &.{ .{ .label = "AB", .tags = motorway }, .{ .label = "BC", .tags = motorway } },
            .turns = &.{straight},
        },
        .{
            .map = "A-----------B-----------C",
            .ways = &.{ .{ .label = "AB", .tags = &.{residence} }, .{ .label = "BC", .tags = &.{residence} } },
            .turns = &.{straight},
        },
        .{
            .map = "         D        F\n         |        |\nA--------B--------C\n         |        |\n         E        G",
            .ways = &.{
                .{ .label = "AB", .tags = primary },       .{ .label = "BC", .tags = primary },
                .{ .label = "BD", .tags = cycleway },      .{ .label = "BE", .tags = cycleway },
                .{ .label = "CF", .tags = &.{residence} }, .{ .label = "CG", .tags = &.{residence} },
            },
            .turns = &.{ straight, cross, .{ .from = "F", .via = "C", .to = "G", .stopped = true } },
        },
        .{
            .map = crossing,
            .ways = &.{
                .{ .label = "AB", .tags = &.{residence} }, .{ .label = "BC", .tags = &.{residence} },
                .{ .label = "BD", .tags = &.{residence} }, .{ .label = "BE", .tags = &.{residence} },
            },
            .turns = &.{ straight_with_stop, cross },
        },
        .{
            .map = "A-----------B-----------C\n            |\n            D",
            .ways = &.{
                .{ .label = "AB", .tags = &.{residence} },
                .{ .label = "BC", .tags = &.{residence} },
                .{ .label = "BD", .tags = &.{ residence, .{ .key = "oneway", .value = "yes" } } },
            },
            .turns = &.{straight_with_stop},
        },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const fixture = try gurka.Map.init(arena.allocator(), try gurka.mapToCoordinates(case.map, 100), case.ways, &.{}, &.{});
        var built = try Built.assemble(fixture.osm, 4);
        defer built.deinit();
        const view = &built.bundle.view;
        for (case.turns) |movement| {
            const incoming = try view.edge(try directedBetween(view, &fixture, movement.from, movement.via));
            const outgoing = try view.edge(try directedBetween(view, &fixture, movement.via, movement.to));
            const row = try view.turnRow(@fromBackingInt(incoming.head), incoming.cls.opp_local);
            const stop: u3 = @truncate(row[outgoing.cls.local] >> 3);
            try testing.expectEqual(movement.stopped, stop != 0);
        }
    }
}

// Ported from test/gurka/test_ramps_tc.cc (Valhalla 3.9.3).
test "link classes follow references, branches, and merging paths" {
    const Class = graph.constants.RoadClass;
    const Expected = struct { nodes: []const u8, class: Class };
    const refs: []const Expected = &.{
        .{ .nodes = "BJ", .class = .trunk }, .{ .nodes = "JF", .class = .trunk },
        .{ .nodes = "FK", .class = .trunk }, .{ .nodes = "KC", .class = .trunk },
    };
    const cases: []const struct { fixture: @import("examples.zig").LinkCase, expected: []const Expected } = &.{
        .{ .fixture = .refs, .expected = refs },
        .{ .fixture = .destination_refs, .expected = refs },
        .{ .fixture = .branches, .expected = &.{
            .{ .nodes = "BG", .class = .trunk }, .{ .nodes = "GJ", .class = .secondary },
            .{ .nodes = "GH", .class = .trunk }, .{ .nodes = "HM", .class = .tertiary },
            .{ .nodes = "HE", .class = .trunk },
        } },
        .{ .fixture = .merge, .expected = &.{
            .{ .nodes = "BJ", .class = .primary },   .{ .nodes = "JK", .class = .primary },
            .{ .nodes = "KL", .class = .primary },   .{ .nodes = "KM", .class = .primary },
            .{ .nodes = "ML", .class = .primary },   .{ .nodes = "LN", .class = .primary },
            .{ .nodes = "NH", .class = .primary },   .{ .nodes = "NP", .class = .tertiary },
            .{ .nodes = "EJ", .class = .secondary },
        } },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const fixture = try @import("examples.zig").links(arena.allocator(), case.fixture);
        var result = try Built.assemble(fixture.osm, 4);
        defer result.deinit();
        const view = &result.bundle.view;
        for (case.expected) |expected| {
            const id = try directedBetween(view, &fixture, expected.nodes[0..1], expected.nodes[1..2]);
            const edge = try view.edge(id);
            const reverse = try view.edge(try view.oppEdge(id));
            try testing.expectEqual(@backingInt(expected.class), (try view.class(edge.cls.class_id)).category.road_class);
            try testing.expectEqual(@backingInt(expected.class), (try view.class(reverse.cls.class_id)).category.road_class);
        }
    }
}

test "turn channels are inferred independently of link reclassification" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").links(arena.allocator(), .inferred_channels);
    for ([_]bool{ false, true }) |reclassify| {
        var result = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .reclassify_links = reclassify });
        defer result.deinit();
        const view = &result.bundle.view;
        for ([_][]const u8{ "BE", "EG", "EH", "GK", "KN", "LN", "NC" }) |labels| {
            const id = try directedBetween(view, &fixture, labels[0..1], labels[1..2]);
            const class = try view.class((try view.edge(id)).cls.class_id);
            if (!reclassify) try testing.expectEqual(@backingInt(graph.constants.RoadClass.motorway), class.category.road_class);
            if (std.mem.eql(u8, labels, "GK")) {
                try testing.expectEqual(@backingInt(graph.constants.Use.turn_channel), class.category.use);
            } else if (std.mem.eql(u8, labels, "BE") or std.mem.eql(u8, labels, "EG")) {
                try testing.expectEqual(@backingInt(graph.constants.Use.ramp), class.category.use);
            }
        }
    }
}

test "manual turn channel tags follow upstream use when inference is disabled" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").links(arena.allocator(), .tagged_channels);
    var result = try Built.assembleWithOptions(fixture.osm, .{
        .scratch_dir = "",
        .reclassify_links = false,
        .infer_turn_channels = false,
    });
    defer result.deinit();
    const view = &result.bundle.view;
    for ([_][]const u8{ "MN", "OP", "QR", "MB" }, [_]graph.constants.Use{ .ramp, .turn_channel, .ramp, .road }) |labels, expected| {
        const id = try directedBetween(view, &fixture, labels[0..1], labels[1..2]);
        const class = try view.class((try view.edge(id)).cls.class_id);
        try testing.expectEqual(@backingInt(expected), class.category.use);
    }
}

test "long slip lanes become turn channels when inference is enabled" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fixture = try @import("examples.zig").links(arena.allocator(), .slip_lane);
    for ([_]bool{ false, true }) |infer| {
        var result = try Built.assembleWithOptions(fixture.osm, .{ .scratch_dir = "", .infer_turn_channels = infer });
        defer result.deinit();
        const view = &result.bundle.view;
        for ([_][]const u8{ "AE", "XM" }) |labels| {
            const id = try directedBetween(view, &fixture, labels[0..1], labels[1..2]);
            const edge = try view.edge(id);
            try testing.expect(edge.geom.len_m >= 200);
            const class = try view.class(edge.cls.class_id);
            const expected: graph.constants.Use = if (infer) .turn_channel else .ramp;
            try testing.expectEqual(@backingInt(expected), class.category.use);
        }
    }
}

test "turn name consistency uses the admin country at the shared node" {
    for ([_]bool{ true, false }) |us| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const fixture = try @import("examples.zig").turnNames(arena.allocator(), us);
        var result = try Built.assemble(fixture.osm, 4);
        defer result.deinit();
        const view = &result.bundle.view;
        const from = try view.edge(try directedBetween(view, &fixture, "A", "B"));
        const to = try view.edge(try directedBetween(view, &fixture, "B", "C"));
        const crossing = try view.edge(try directedBetween(view, &fixture, "B", "D"));
        const via: format.NodeId = @fromBackingInt(from.head);
        try testing.expectEqualStrings(if (us) "US" else "CA", (try view.nodeAdmin(via)).country_iso);
        const row = try view.turnRow(via, from.cls.opp_local);
        try testing.expectEqual(us, row[to.cls.local] & 0x40 != 0);
        try testing.expect(row[crossing.cls.local] & 0x40 == 0);
    }
}

// Ported from test/gurka/test_trimming.cc (Valhalla 3.9.3).
test "Gurka trip leg retains a near-end trim, an interior via and the physical intersection" {
    const api = routing.api.request;
    const multi = routing.search.multi;
    const tripleg = routing.search.tripleg;
    const mem = routing.infra.arena;
    var fixture_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer fixture_arena.deinit();
    const a = fixture_arena.allocator();
    const motorway: gurka.Tag = .{ .key = "highway", .value = "motorway" };
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinatesAt(
        \\AB----C
        \\ |
        \\ D
    , 90.857, .{ .lat = 52.0981145, .lng = 5.1309431 }), &.{
        .{ .label = "AB", .tags = &.{
            motorway,
            .{ .key = "ref", .value = "A 1" },
            .{ .key = "maxspeed", .value = "100" },
            .{ .key = "lanes", .value = "2" },
            .{ .key = "turn:lanes:forward", .value = "through|through;right" },
        } },
        .{ .label = "BC", .tags = &.{
            motorway,
            .{ .key = "name", .value = "Rue Orient" },
            .{ .key = "name:pronunciation", .value = "ʁy ɔʁjɑ̃" },
            .{ .key = "tunnel", .value = "yes" },
            .{ .key = "tunnel:name", .value = "East Tunnel" },
            .{ .key = "bicycle", .value = "dismount" },
            .{ .key = "level", .value = "1.2" },
        } },
        .{ .label = "BD", .tags = &.{
            .{ .key = "highway", .value = "motorway_link" },
            .{ .key = "oneway", .value = "yes" },
            .{ .key = "junction:ref", .value = "9A" },
            .{ .key = "destination", .value = "Harbour" },
        } },
    }, &.{}, &.{.{
        .members = &.{
            .{ .kind = .way, .ref = "AB", .role = "from" },
            .{ .kind = .node, .ref = "B", .role = "via" },
            .{ .kind = .way, .ref = "BC", .role = "to" },
        },
        .tags = &.{ .{ .key = "type", .value = "connectivity" }, .{ .key = "from", .value = "2|1" }, .{ .key = "to", .value = "1|2" } },
    }});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");
    const bc = try directedBetween(view, &fixture, "B", "C");
    const p = fixture.findNode("A").?.location.toFixed().toTilePoint();
    const b = fixture.findNode("B").?.location.toFixed().toTilePoint();
    const c = fixture.findNode("C").?.location.toFixed().toPoint();
    const from = routing.geo.PointLL.init(b.lng - 0.0000005, b.lat);
    const via = routing.geo.PointLL.init((b.lng + c.lng) / 2, (b.lat + c.lat) / 2);
    const fraction: f32 = @floatCast(p.distance(from) / p.distance(b));
    var start = snapEdge(ab, fraction, 0);
    start.projected = from;
    var middle = snapEdge(bc, 0.5, 0);
    middle.projected = via;
    var last = snapEdge(bc, 1, 0);
    last.projected = c;
    const correlations = [_]routing.snap.candidates.PathLocation{
        snapLocation(&.{start}, &.{}),
        snapLocation(&.{middle}, &.{}),
        snapLocation(&.{last}, &.{}),
    };
    const locations = [_]api.Location{
        .{ .lat = from.lat, .lng = from.lng },
        .{ .lat = via.lat, .lng = via.lng, .type = .via, .original_index = 1 },
        .{ .lat = c.lat, .lng = c.lng, .original_index = 2 },
    };
    const path: multi.Leg = .{
        .origin = 0,
        .destination = 2,
        .segments = &.{
            .{ .edge = ab, .begin = fraction, .end = 1 },
            .{ .edge = bc, .begin = 0, .end = 0.5 },
            .{ .edge = bc, .begin = 0.5, .end = 1 },
        },
        .segment_contexts = &.{ .{ .pair = 0, .starts_pair = true }, .{ .pair = 0, .starts_pair = false }, .{ .pair = 1, .starts_pair = true } },
        .length_km = @floatCast(from.distance(b) * 0.001 + b.distance(c) * 0.001),
        .cost = .{},
    };
    const waypoints: [3]multi.Waypoint = @splat(.{
        .elapsed_secs = 0,
        .waiting_secs = 0,
        .date_time = null,
        .ignored_filter = false,
    });
    const route: multi.Route = .{ .legs = &.{path}, .waypoints = &waypoints, .total = .{}, .retried = false };

    var counting = mem.CountingAllocator.init(testing.allocator);
    var arena = mem.Arena.init(counting.allocator(), .{});
    defer arena.deinit();
    const geometry = try routing.search.legs.build(arena.allocator(), view, SearchTestCost{ .seed = 5 }, route, &correlations, .{});
    const saved = arena.mark();
    const input: tripleg.Input = .{
        .segments = path.segments,
        .geometry = &geometry.legs[0],
        .locations = .{
            .requested = &locations,
            .correlations = &correlations,
            .waypoints = &waypoints,
            .segment_contexts = path.segment_contexts,
        },
    };
    const leg = try tripleg.build(arena.allocator(), view, input, .{});
    try testing.expectEqual(@as(?u64, 1001), view.datasetId());
    try testing.expectEqual(1001, leg.osm_changeset);
    var legacy = view.*;
    legacy.dataset_id = null;
    const legacy_leg = try tripleg.build(arena.allocator(), &legacy, input, .{});
    try testing.expectEqual(0, legacy_leg.osm_changeset);
    try testing.expectEqual(4, leg.node.len);
    try testing.expectEqual(3, leg.location.len);
    try testing.expectEqual(routing.api.trip.LocationType.kVia, leg.location[1].type);
    const via_index = leg.location[1].correlation.?.leg_shape_index;
    try testing.expect(geometry.legs[0].shape[via_index].eql(via));
    try testing.expect(geometry.legs[0].shape[0].eql(from));
    try testing.expect(geometry.legs[0].shape[geometry.legs[0].shape.len - 1].eql(c));
    try testing.expect(!c.eql(c.toFixed().toTilePoint()));
    try testing.expectApproxEqAbs(b.distance(c), routing.geo.line.length(geometry.legs[0].shape), 1);
    const clipped = leg.node[0].edge.?;
    try testing.expectEqualStrings("A 1", clipped.name[0].value);
    try testing.expect(clipped.name[0].is_route_number);
    try testing.expectEqual(100, clipped.speed_limit);
    try testing.expect(clipped.length_km > 0 and clipped.length_km < 0.001);
    try testing.expectEqual(1, leg.node[1].intersecting_edge.len);
    try testing.expectEqualStrings("BD", leg.node[1].intersecting_edge[0].name[0].value);
    const signs = leg.node[1].intersecting_edge[0].sign.?;
    try testing.expectEqualStrings("9A", signs.exit_numbers[0].text);
    try testing.expectEqualStrings("Harbour", signs.exit_toward_locations[0].text);
    try testing.expectEqual(2, clipped.turn_lanes.len);
    const tunnel = leg.node[1].edge.?;
    try testing.expectEqualStrings("Rue Orient", tunnel.name[0].value);
    try testing.expectEqual(routing.api.trip.Alphabet.kIpa, tunnel.name[0].pronunciation.?.alphabet);
    try testing.expectEqualStrings("ʁy ɔʁjɑ̃", tunnel.name[0].pronunciation.?.value);
    try testing.expectEqualStrings("East Tunnel", tunnel.tunnel_name[0].value);
    try testing.expectEqual(10, tunnel.level_precision);
    try testing.expectEqual(@as(f32, 1.2), tunnel.levels[0].start);
    try testing.expectEqual(@as(f32, 1.2), leg.level_changes[0].level);
    try testing.expectEqual(1, tunnel.lane_connectivity.len);
    try testing.expectEqualStrings("2|1", tunnel.lane_connectivity[0].from_lanes);
    try testing.expectEqualStrings("1|2", tunnel.lane_connectivity[0].to_lanes);
    try testing.expectEqual(@as(f64, geometry.legs[0].edges[2].elapsed.secs), leg.node[3].cost.?.elapsed_cost.?.seconds);

    const parsed = try api.parseHttp(a, "/route", &.{},
        \\{"locations":[{"lat":52.1,"lon":5.1},{"lat":52.2,"lon":5.2}],"costing":"auto",
        \\ "filters":{"action":"include","attributes":["shape","edge.length","shape_attributes.length"]}}
    );
    try testing.expect(parsed == .ok);
    var bike_input = input;
    bike_input.travel = .{ .bicycle = .kMountain };
    const bike_leg = try tripleg.build(arena.allocator(), view, bike_input, .{});
    try testing.expectEqual(.kBicycle, bike_leg.node[0].edge.?.travel_mode);
    try testing.expectEqual(.kMountain, bike_leg.node[0].edge.?.bicycle_type);
    try testing.expectEqual(.kPedestrian, bike_leg.node[1].edge.?.travel_mode);
    try testing.expectEqual(.kFoot, bike_leg.node[1].edge.?.pedestrian_type);

    var narrowed = input;
    narrowed.attributes = try parsed.ok.tripAttributes(true, .none);
    var without_cold = view.*;
    without_cold.cold_data = null;
    const projected = try tripleg.build(arena.allocator(), &without_cold, narrowed, .{});
    try testing.expectEqual(0, projected.osm_changeset);
    try testing.expectEqual(0, projected.node[0].edge.?.name.len);
    try testing.expectEqual(0, projected.node[0].edge.?.speed_limit);
    try testing.expectEqual(0, projected.node[1].intersecting_edge.len);
    try testing.expectEqual(null, projected.node[0].cost);
    try testing.expectEqualStrings(leg.shape, projected.shape);
    try testing.expectEqual(geometry.legs[0].shape.len - 1, projected.shape_attributes.?.length.len);
    try testing.expectEqual(0, projected.shape_attributes.?.time.len);

    arena.rewind(saved);
    counting.resetCounts();
    for (0..4) |_| {
        const replay = try tripleg.build(arena.allocator(), view, input, .{});
        try testing.expectEqual(via_index, replay.location[1].correlation.?.leg_shape_index);
        arena.rewind(saved);
    }
    try testing.expectEqual(0, counting.calls());
    try testing.expectError(error.Cancelled, tripleg.build(arena.allocator(), view, input, .{ .deadline = .{ .at_ns = 0 } }));
}

// Ported from the edge walk and walk-or-snap cases in test/mapmatch.cc.
test "Gurka trace follows an exact shape and falls back after a geometric mismatch" {
    const match = routing.match;
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const fixture = try gurka.Map.init(storage.allocator(), try gurka.mapToCoordinates("A---B---C", 30), &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "BC", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    var trace = [_]match.candidates.Measurement{
        .{ .point = fixture.findNode("A").?.location, .epoch_time = 0, .stop_type = .@"break" },
        .{ .point = fixture.findNode("B").?.location, .epoch_time = 8 },
        .{ .point = fixture.findNode("C").?.location, .epoch_time = 31, .stop_type = .@"break" },
    };
    const east = [_]format.EdgeId{
        try directedBetween(view, &fixture, "A", "B"),
        try directedBetween(view, &fixture, "B", "C"),
    };
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var finder = match.candidates.Finder.init(view, testing.allocator, .{});
    defer finder.deinit();
    const Router = match.routing.Router(RestrictionMotor);
    var router = try Router.init(testing.allocator, view, Router.default_scratch_bytes);
    defer router.deinit();
    const emission = try match.emission.Model.init(match.emission.Model.default_sigma_z);
    const transition = try match.transition.Model.init(.{});
    const kernel: RestrictionMotor = .{};
    const walked = try match.route.resolve(&arena, &finder, &router, kernel, &trace, emission, transition, .{ .shape_match = .edge_walk, .use_timestamps = true }, .{});
    try testing.expectEqual(@as(usize, 1), walked[0].legs.len);
    const leg = walked[0].legs[0];
    try testing.expectEqual(east.len, leg.segments.len);
    for (east, leg.segments) |edge, segment| try testing.expectEqual(edge, segment.edge);
    try testing.expectEqual(@as(f32, 8), leg.steps[0].elapsed.secs);
    try testing.expectEqual(@as(f32, 31), leg.steps[1].elapsed.secs);

    arena.reset();
    trace[1].point.lat += 0.0001;
    trace[1].epoch_time = 90;
    trace[2].epoch_time = 181;
    try testing.expectError(error.NoEdgeWalk, match.route.resolve(&arena, &finder, &router, kernel, &trace, emission, transition, .{ .shape_match = .edge_walk }, .{}));
    const snapped = try match.route.resolve(&arena, &finder, &router, kernel, &trace, emission, transition, .{ .shape_match = .walk_or_snap }, .{});
    try testing.expectEqual(@as(usize, 1), snapped[0].legs.len);
    try testing.expectEqual(east.len, snapped[0].segments.len);
    for (east, snapped[0].segments) |edge, segment| try testing.expectEqual(edge, segment.path.edge);
    try testing.expect(snapped[0].matches[1].distance > 1);
}

// Ported from Mapmatch.interpolation and test_discontinuity_on_same_edge.
test "Gurka trace splits interpolated breaks and preserves discontinuities on the same edge" {
    const match = routing.match;
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const fixture = try gurka.Map.init(storage.allocator(), try gurka.mapToCoordinates("A-------------------Z", 25), &.{
        .{ .label = "AZ", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const a = fixture.findNode("A").?.location;
    const z = fixture.findNode("Z").?.location;
    const edge = try directedBetween(view, &fixture, "A", "Z");
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var finder = match.candidates.Finder.init(view, testing.allocator, .{});
    defer finder.deinit();
    const Router = match.routing.Router(RestrictionMotor);
    var router = try Router.init(testing.allocator, view, Router.default_scratch_bytes);
    defer router.deinit();
    const emission = try match.emission.Model.init(match.emission.Model.default_sigma_z);
    const transition = try match.transition.Model.init(.{});
    const kernel: RestrictionMotor = .{};
    const timed = [_]match.candidates.Measurement{
        .{ .point = a.pointAlongSegment(z, 0.1), .epoch_time = 10 },
        .{ .point = a.pointAlongSegment(z, 0.112), .epoch_time = 15, .stop_type = .@"break" },
        .{ .point = a.pointAlongSegment(z, 0.2), .epoch_time = 80 },
    };
    const interpolated = (try match.route.resolve(&arena, &finder, &router, kernel, &timed, emission, transition, .{ .shape_match = .map_snap, .use_timestamps = true }, .{}))[0];
    try testing.expectEqual(.interpolated, interpolated.matches[1].kind);
    try testing.expectEqual(@as(usize, 2), interpolated.legs.len);
    try testing.expectEqual(edge, interpolated.segments[0].path.edge);
    try testing.expectEqual(interpolated.segments[0].path.end, interpolated.segments[1].path.begin);
    try testing.expectEqual(@as(f32, 5), interpolated.legs[0].steps[0].elapsed.secs);
    try testing.expectEqual(@as(f32, 65), interpolated.legs[1].steps[0].elapsed.secs);

    arena.reset();
    const disjoint = [_]match.candidates.Measurement{
        .{ .point = a.pointAlongSegment(z, 0.1), .epoch_time = 0 },
        .{ .point = a.pointAlongSegment(z, 0.2), .epoch_time = 60 },
        .{ .point = .init(a.lng, a.lat + 0.2), .epoch_time = 120 },
        .{ .point = a.pointAlongSegment(z, 0.7), .epoch_time = 180 },
        .{ .point = a.pointAlongSegment(z, 0.8), .epoch_time = 280 },
    };
    const broken = (try match.route.resolve(&arena, &finder, &router, kernel, &disjoint, emission, transition, .{ .shape_match = .map_snap, .use_timestamps = true }, .{}))[0];
    try testing.expectEqual(.unmatched, broken.matches[2].kind);
    try testing.expectEqual(@as(usize, 2), broken.legs.len);
    try testing.expectEqual(edge, broken.segments[0].path.edge);
    try testing.expectEqual(edge, broken.segments[1].path.edge);
    try testing.expect(broken.segments[0].discontinuity);
    try testing.expect(broken.matches[1].begins_discontinuity);
    try testing.expect(broken.matches[3].ends_discontinuity);
    for (broken.legs) |part| try testing.expectApproxEqAbs(part.steps[0].length_m, part.steps[0].elapsed.secs, 0.0001);
}

// Ported from Mapmatch.test_loop_matching_walk_or_snap.
test "Gurka exact trace revisits the same intersection later in the shape" {
    const match = routing.match;
    const road: gurka.Tags = &.{.{ .key = "highway", .value = "primary" }};
    const oneway: gurka.Tags = &.{ .{ .key = "highway", .value = "primary" }, .{ .key = "oneway", .value = "yes" } };
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const fixture = try gurka.Map.init(storage.allocator(), try gurka.mapToCoordinates(
        \\A---B---C
        \\    |   |
        \\    D---E
    , 30), &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "BC", .tags = oneway },
        .{ .label = "CE", .tags = oneway },
        .{ .label = "ED", .tags = oneway },
        .{ .label = "DB", .tags = oneway },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    var arena = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var finder = match.candidates.Finder.init(view, testing.allocator, .{});
    defer finder.deinit();
    const Router = match.routing.Router(RestrictionMotor);
    var router = try Router.init(testing.allocator, view, Router.default_scratch_bytes);
    defer router.deinit();
    const emission = try match.emission.Model.init(match.emission.Model.default_sigma_z);
    const transition = try match.transition.Model.init(.{});
    const kernel: RestrictionMotor = .{};
    const points = [_][]const u8{ "A", "B", "C", "E", "D", "B", "A" };
    var trace: [points.len]match.candidates.Measurement = undefined;
    for (&trace, points) |*sample, point| sample.* = .{ .point = fixture.findNode(point).?.location };
    try testing.expectError(error.MissingTraceTimestamps, match.route.resolve(&arena, &finder, &router, kernel, &trace, emission, transition, .{ .use_timestamps = true }, .{}));
    const result = (try match.route.resolve(&arena, &finder, &router, kernel, &trace, emission, transition, .{ .shape_match = .edge_walk }, .{}))[0];
    try testing.expectEqual(points.len - 1, result.segments.len);
    for (result.segments, points[0 .. points.len - 1], points[1..]) |segment, from, to| {
        try testing.expectEqual(try directedBetween(view, &fixture, from, to), segment.path.edge);
    }
}

// Ported from test/gurka/test_trace_attributes.cc (Valhalla 3.9.3).
test "Gurka trace attributes filters edge and match fields in JSON and PBF" {
    const http = routing.server.http;
    var storage: std.heap.ArenaAllocator = .init(testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const fixture = try gurka.Map.init(a, try gurka.mapToCoordinates("A----B----C", 10), &.{
        .{ .label = "AB", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "Main Street" },
            .{ .key = "shoulder", .value = "both" },
        } },
        .{ .label = "BC", .tags = &.{
            .{ .key = "highway", .value = "primary" },
            .{ .key = "name", .value = "High Street" },
        } },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const start = fixture.findNode("A").?.location;
    const middle = fixture.findNode("B").?.location;
    const end = fixture.findNode("C").?.location;
    const measurements = [_]routing.geo.PointLL{ start.midpoint(middle), middle, middle.midpoint(end) };
    var body: std.ArrayList(u8) = .empty;
    var svc: routing.api.service.Service = .{ .graph = &built.bundle.view };
    svc.register(.trace_attributes, routing.api.trace_attributes_action.handle);

    var counting = routing.infra.arena.CountingAllocator.init(testing.allocator);
    var arena = routing.infra.arena.Arena.init(counting.allocator(), .{});
    defer arena.deinit();
    var workspace = routing.infra.arena.Arena.init(counting.allocator(), .{});
    defer workspace.deinit();
    var ctx: http.Ctx = .{ .worker_id = 0, .arena = &arena, .scratch = &workspace, .deadline = .none };
    var req: http.Request = .{
        .method = .POST,
        .target = "/trace_attributes",
        .path = "/trace_attributes",
        .query = &.{},
        .headers = &.{},
        .body = "",
        .keep_alive = false,
    };

    const variants = [_]struct { format: []const u8, filters: []const u8 }{
        .{ .format = "json", .filters = "" },
        .{ .format = "osrm", .filters =
        \\,"filters":{"action":"include","attributes":["edge.shoulder","edge.names","matched.type"]}
        },
        .{ .format = "json", .filters =
        \\,"filters":{"action":"exclude","attributes":["edge.names","matched.distance_along_edge"]}
        },
        .{ .format = "pbf", .filters =
        \\,"best_paths":2,"filters":{"action":"include","attributes":["matched.distance_from_trace_point"]}
        },
    };
    for (variants, 0..) |variant, i| {
        body.clearRetainingCapacity();
        try body.print(a, "{{\"shape_match\":\"map_snap\",\"costing\":\"bicycle\",\"format\":\"{s}\",\"shape\":[", .{variant.format});
        for (measurements, 0..) |location, j| {
            if (j != 0) try body.append(a, ',');
            try body.print(a, "{{\"lat\":{d},\"lon\":{d}}}", .{ location.lat + 0.00002, location.lng });
        }
        try body.print(a, "]{s}}}", .{variant.filters});
        req.body = body.items;
        arena.reset();
        workspace.reset();
        var res: http.Response = .{ .gpa = arena.allocator() };
        svc.handle(&ctx, &req, &res);
        try testing.expectEqual(200, res.status);
        if (i == 3) {
            try testing.expectEqualStrings("application/x-protobuf", res.content_type);
            const api = try routing.api.proto.Api.decode(res.body.items, ctx.deadline);
            const info = (try api.get("info", ctx.deadline)).?;
            var warnings = try info.get("warnings", ctx.deadline);
            const warning = (try warnings.next(ctx.deadline)).?;
            try testing.expectEqual(103, try warning.get("code", ctx.deadline));
            const trip = (try api.get("trip", ctx.deadline)).?;
            var routes = try trip.get("routes", ctx.deadline);
            const route = (try routes.next(ctx.deadline)).?;
            var leg_list = try route.get("legs", ctx.deadline);
            const leg = (try leg_list.next(ctx.deadline)).?;
            var location_list = try leg.get("location", ctx.deadline);
            const origin = (try location_list.next(ctx.deadline)).?;
            const correlation = (try origin.get("correlation", ctx.deadline)).?;
            var path_edges = try correlation.get("edges", ctx.deadline);
            try testing.expect((try path_edges.next(ctx.deadline)) != null);
            var points = try route.get("matched_points", ctx.deadline);
            for (measurements) |_| {
                const point = (try points.next(ctx.deadline)).?;
                try testing.expectApproxEqAbs(2.22, (try point.get("distance_from_trace_point", ctx.deadline)).?, 0.05);
                try testing.expectEqual(null, try point.get("latlng", ctx.deadline));
            }
            try testing.expectEqual(null, try points.next(ctx.deadline));
            continue;
        }
        const result = (try std.json.parseFromSliceLeaky(std.json.Value, res.gpa, res.body.items, .{})).object;
        const edges = result.get("edges").?.array.items;
        const points = result.get("matched_points").?.array.items;
        try testing.expectEqual(2, edges.len);
        try testing.expectEqual(3, points.len);
        try testing.expectEqual(true, edges[0].object.get("shoulder").?.bool);
        try testing.expectEqual(false, edges[1].object.get("shoulder").?.bool);
        if (i == 0) {
            try testing.expectEqual(0, points[0].object.get("edge_index").?.integer);
            try testing.expectEqual(1, points[2].object.get("edge_index").?.integer);
        } else if (i == 1) {
            try testing.expectEqualStrings("Main Street", edges[0].object.get("names").?.array.items[0].string);
            try testing.expectEqual(null, edges[0].object.get("way_id"));
            try testing.expectEqual(null, points[0].object.get("edge_index"));
        } else {
            try testing.expectEqual(null, edges[0].object.get("names"));
            try testing.expectEqual(null, points[0].object.get("distance_along_edge"));
        }
    }

    counting.resetCounts();
    for (0..8) |_| {
        arena.reset();
        workspace.reset();
        var res: http.Response = .{ .gpa = arena.allocator() };
        svc.handle(&ctx, &req, &res);
        try testing.expectEqual(200, res.status);
    }
    try testing.expectEqual(0, counting.calls());
}

test "Gurka historical traffic learns an interior edge and publishes an anonymous overlay" {
    const history = routing.traffic.history;
    const a = testing.allocator;
    var storage: std.heap.ArenaAllocator = .init(a);
    defer storage.deinit();
    const raw = storage.allocator();
    const road: gurka.Tags = &.{
        .{ .key = "highway", .value = "primary" },
        .{ .key = "maxspeed", .value = "40" },
    };
    const layout = try gurka.mapToCoordinates("A----B----C----D", 20);
    const fixture = try gurka.Map.init(raw, layout, &.{
        .{ .label = "AB", .tags = road },
        .{ .label = "BC", .tags = road },
        .{ .label = "CD", .tags = road },
    }, &.{}, &.{});
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;

    const ids = [_]format.EdgeId{
        try directedBetween(view, &fixture, "A", "B"),
        try directedBetween(view, &fixture, "B", "C"),
        try directedBetween(view, &fixture, "C", "D"),
    };
    const labels = [_][]const u8{ "A", "B", "C", "D" };
    const start_time: f64 = 1_767_484_800;
    var input: std.ArrayList(u8) = .empty;
    const ground_truth: f64 = 40;
    for ([_]f64{ ground_truth, ground_truth, ground_truth, ground_truth, 110 }) |interior_speed| {
        var instant = start_time;
        try input.appendSlice(raw, "{\"id\":\"discarded\",\"shape\":[");
        for (labels, 0..) |label, i| {
            if (i != 0) {
                const hot = try view.edge(ids[i - 1]);
                const speed = if (i == 2) interior_speed else ground_truth;
                instant += @as(f64, @floatFromInt(hot.geom.len_m)) * 3.6 / speed;
                try input.append(raw, ',');
            }
            const p = fixture.findNode(label).?.location;
            try input.print(raw, "{{\"lat\":{d},\"lon\":{d},\"time\":{d}}}", .{ p.lat, p.lng, instant });
        }
        try input.appendSlice(raw, "]}\n");
    }
    try input.appendSlice(raw, "{\"id\":\"ignored\",\"shape\":[null]}\n");
    const batch = try routing.traffic.history_trace.collect(a, view, input.items, 3, .none);
    defer batch.deinit(a);
    try testing.expectEqual(6, batch.report.traces);
    try testing.expectEqual(1, batch.report.malformed_traces);
    try testing.expectEqual(5, batch.report.contributing_traces);
    try testing.expectEqual(5, batch.samples.len);
    var outliers: usize = 0;
    for (batch.samples) |sample| {
        try testing.expectEqual(ids[1], sample.edge);
        if (sample.kph > 100) {
            outliers += 1;
            try testing.expectApproxEqAbs(110, sample.kph, 0.01);
        } else {
            try testing.expectApproxEqAbs(ground_truth, sample.kph, 0.01);
        }
    }
    try testing.expectEqual(1, outliers);
    const fit = try history.fit(a, view, batch.samples, 3, .none);
    defer fit.deinit(a);
    try testing.expectEqual(1, fit.profiles.len);
    try testing.expectEqual(ids[1], fit.profiles[0].edge);
    const primary = fit.coverage[@backingInt(graph.constants.RoadClass.primary)];
    try testing.expectEqual(1, primary.supported_buckets);
    try testing.expectEqual(4, primary.retained_samples);

    const dir = try built.root.child("bundle");
    defer dir.close();
    defer dir.deleteFile(routing.traffic.predicted.filename) catch {};
    const applied = try routing.traffic.predicted_ingest.applyGenerated(a, dir, view.dataset_uuid, @intCast(view.edges.len), fit.profiles, .none);
    try testing.expectEqual(1, applied.edges_with_profiles);
    const reader = (try routing.traffic.predicted.Reader.open(dir, view.dataset_uuid, view.edges.len, .none)).?;
    defer reader.close();
    try testing.expect(reader.view.entry(ids[0]) == null);
    try testing.expect(reader.view.entry(ids[2]) == null);
    const observed = reader.view.speed(ids[1], @as(u64, batch.samples[0].bucket) * routing.traffic.predicted_codec.bucket_seconds).?;
    try testing.expectApproxEqAbs(ground_truth, observed, ground_truth * 0.05);

    // Verify actual DCT round-trip errors on a full synthetic weekly pattern.
    const codec = routing.traffic.predicted_codec;
    const full = try a.alloc(history.Sample, codec.bucket_count * 6);
    defer a.free(full);
    const perturbation = [_]f32{ -0.8, -0.4, 0, 0.4, 0.8, 0 };
    var expected: [codec.bucket_count]f32 = undefined;
    for (&expected, 0..) |*target, bucket| {
        const phase: f32 = @as(f32, @floatFromInt(bucket)) * (@as(f32, 2 * std.math.pi) / codec.bucket_count);
        target.* = 45 + 8 * @cos(7 * phase) + 3 * @sin(phase);
        for (full[bucket * 6 ..][0..6], perturbation, 0..) |*sample, noise, i| {
            sample.* = .{ .edge = ids[1], .bucket = @intCast(bucket), .kph = if (i == 5) 115 else target.* + noise };
        }
    }
    const full_fit = try history.fit(a, view, full, 5, .none);
    defer full_fit.deinit(a);
    try testing.expectEqual(1, full_fit.profiles.len);
    try testing.expectEqual(codec.bucket_count, full_fit.coverage[@backingInt(graph.constants.RoadClass.primary)].supported_buckets);
    const decode = try codec.Codec.init(.none);
    const profile = codec.StoredProfile.init(full_fit.profiles[0].coefficients);
    for (expected, 0..) |target, bucket|
        try testing.expectApproxEqAbs(target, decode.decodeBucket(&profile, @intCast(bucket)), 0.05 * target);
}

// Ported from test/gurka/test_linear_feature_factors.cc (Valhalla 3.9.3).
test "Gurka linear features resolve directed cuts and price search and recost identically" {
    const linear = routing.snap.linear;
    const endpoints = routing.search.endpoints;
    const Recost = routing.search.legs.Recost;
    const auto = routing.costing.auto;
    const Kernel = routing.match.kernel.Motor(auto);
    const point = routing.geo.PointLL;
    var storage = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer storage.deinit();
    var workspace = routing.infra.arena.Arena.init(testing.allocator, .{});
    defer workspace.deinit();
    const a = storage.allocator();
    const fixture = try @import("examples.zig").accessRegions(a);
    var built = try Built.assemble(fixture.osm, 1);
    defer built.deinit();
    const view = &built.bundle.view;
    const ab = try directedBetween(view, &fixture, "A", "B");

    const parsed = try routing.api.request.parseHttp(a, "/route", &.{},
        \\{"costing":"auto","linear_cost_factors":[{"type":"Feature","geometry":{
        \\"type":"LineString","coordinates":[[0.0008983120447446023,0],[0.002694936134233807,0]]},
        \\"properties":{"factor":0.5}}]}
    );
    const features = parsed.ok.linear_cost_factors;
    const resolved = (try linear.resolve(view, a, &workspace, features, .{}, .{})).ok;
    try testing.expectEqualStrings("", resolved.failed);
    const range = resolved.costs.get(ab).?.ranges.items[0];
    try testing.expectApproxEqAbs(0.25, range.begin, 1e-4);
    try testing.expectApproxEqAbs(0.75, range.end, 1e-4);
    try testing.expectEqual(@as(f64, 0.5), range.factor);
    try testing.expectEqual(@as(?*const routing.costing.linear.Edge, null), resolved.costs.get(try view.oppEdge(ab)));
    try testing.expectApproxEqAbs(0.5, resolved.costs.floor, 1e-6);

    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const raw = try auto.parse(a, .auto, .null, &warnings, .none);
    const profile = try auto.Model.canonicalize(raw);
    const classes = view.classes.?;
    const tables = try routing.costing.compiled.compileInto(auto.Model, profile, classes, try a.alloc(f32, classes.len), .none);
    const baseline: Kernel = .{ .profile = &profile, .tables = &tables, .arena = a, .control = .{} };
    var kernel = baseline;
    kernel.features = &resolved.costs;
    var engine = try search.Search(Kernel, routing.search.queue.Heap).init(testing.allocator, view);
    defer engine.deinit();

    // Valhalla 3.9.3 reports -25% of the baseline on this cut.
    // The actual overlap is 75% of the cut, so the result is 62.5%.
    const plain = try baseline.edgeCost(view, ab, try view.edge(ab), .forward);
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const begin: endpoints.Candidate = .{ .edge = ab, .fraction = 0.2, .score = 0, .begin_node = false, .end_node = false };
        const end: endpoints.Candidate = .{ .edge = ab, .fraction = 0.4, .score = 0, .begin_node = false, .end_node = false };
        const starts = if (direction == .forward) &.{begin} else &.{end};
        const targets = try endpoints.Targets.init(a, if (direction == .forward) &.{end} else &.{begin}, direction, .{});
        const result = try engine.runPartial(&workspace, kernel, .{ .direction = direction, .starts = starts, .targets = &targets }, search.Zero{}, .{});
        const result_cut = result.best().cut(result.cuts);
        try testing.expectApproxEqAbs(plain.cost * 0.125, result.best().cost, 1e-4);
        try testing.expectApproxEqAbs(plain.secs * 0.125, result.best().secs, 1e-4);
        const path: []const endpoints.Segment = &.{.{ .edge = ab, .begin = result_cut.begin, .end = result_cut.end }};
        const priced = switch (direction) {
            .forward => try Recost.walk(view, kernel, path, null, .forward, .{}),
            .reverse => try Recost.walk(view, kernel, path, null, .reverse, .{}),
        };
        try testing.expectApproxEqAbs(priced.cost, result.best().cost, 1e-4);
        try testing.expectApproxEqAbs(priced.secs, result.best().secs, 1e-4);
        workspace.reset();
    }

    // Encoded polyline6, a tiny sliver before the first vertex, and the
    // configured floor on a line that spans more than one path edge.
    const b = fixture.findNode("B").?.location;
    const c = fixture.findNode("C").?.location;
    const near_b: point = .init(b.lng - 0.000004, b.lat);
    var encoded: [84]u8 = undefined;
    const n = try routing.geo.polyline.encode(.polyline, 6, &.{ near_b, b, c }, &encoded);
    const body = try std.fmt.allocPrint(a, "{{\"linear_cost_factors\":[{{\"shape\":{f},\"factor\":0.25,\"allow_types\":[\"ignored\",\"all\"]}}]}}", .{std.json.fmt(encoded[0..n], .{})});
    const encoded_features = (try routing.api.request.parseHttp(a, "/route", &.{}, body)).ok.linear_cost_factors;
    const spanning = (try linear.resolve(view, a, &workspace, encoded_features, .{ .min_factor = 0.6 }, .{})).ok;
    const bc = try directedBetween(view, &fixture, "B", "C");
    try testing.expectEqualStrings("", spanning.failed);
    try testing.expect(spanning.costs.allows(bc));
    try testing.expect(!spanning.costs.allows(ab));
    try testing.expectApproxEqAbs(0.6, spanning.costs.get(bc).?.full, 1e-6);

    const exclude = (try linear.resolve(view, a, &workspace, &.{.{ .points = features[0].points, .factor = 0, .allow = true }}, .{}, .{})).ok;
    try testing.expectEqual(1, exclude.costs.exclusions.items.len);
    try testing.expectApproxEqAbs(0.25, exclude.costs.exclusionAt(ab).?, 1e-4);
    try testing.expect(!exclude.costs.allows(ab));
    kernel.features = &exclude.costs;
    const from = try at(view, fixture.findNode("A").?.location.toFixed());
    const to = try at(view, b.toFixed());
    try testing.expectError(error.NoPath, engine.run(&workspace, kernel, .{ .origin = from, .destination = to }, search.Zero{}, .{}));
    workspace.reset();
    const cd = try directedBetween(view, &fixture, "C", "D");
    const d = fixture.findNode("D").?.location;
    const permission = (try linear.resolve(view, a, &workspace, &.{.{ .points = &.{ c, d }, .allow = true }}, .{}, .{})).ok;
    try testing.expectEqualStrings("", permission.failed);
    try testing.expect(permission.costs.allows(cd));
    try testing.expectEqual(@as(f32, 0), permission.costs.floor);
    var permissive_options = raw;
    permissive_options.may_allow_edges = true;
    const permissive_profile = try auto.Model.canonicalize(permissive_options);
    const permissive_tables = try routing.costing.compiled.compileInto(auto.Model, permissive_profile, classes, try a.alloc(f32, classes.len), .none);
    kernel = .{ .profile = &permissive_profile, .tables = &permissive_tables, .arena = a, .control = .{}, .features = &permission.costs };
    const private_from = try at(view, c.toFixed());
    const private_to = try at(view, d.toFixed());
    const thru = try engine.run(&workspace, kernel, .{ .origin = private_from, .destination = private_to }, search.Zero{}, .{});
    try testing.expectEqual(cd, thru.best().edgeId());
    const recosted = try Recost.walk(view, kernel, &.{.{ .edge = cd, .begin = 0, .end = 1 }}, null, .forward, .{ .ignore_access = false });
    try testing.expectApproxEqAbs(recosted.cost, thru.best().cost, 1e-4);

    workspace.reset();
    const de = try directedBetween(view, &fixture, "D", "E");
    const ef = try directedBetween(view, &fixture, "E", "F");
    const e = fixture.findNode("E").?.location;
    const f = fixture.findNode("F").?.location;
    const span = (try linear.resolve(view, a, &workspace, &.{
        .{ .points = &.{ d.midpoint(e), e, e.midpoint(f) }, .factor = 0.5 },
        .{ .points = &.{ d, e }, .factor = 2 },
    }, .{ .min_factor = 0.001 }, .{})).ok;
    try testing.expectEqualStrings("", span.failed);
    try testing.expectApproxEqAbs(1.75, span.costs.get(de).?.full, 1e-4);
    kernel = baseline;
    kernel.features = &span.costs;
    const begin: endpoints.Candidate = .{ .edge = de, .fraction = 0.2, .score = 0, .begin_node = false, .end_node = false };
    const end: endpoints.Candidate = .{ .edge = ef, .fraction = 0.4, .score = 0, .begin_node = false, .end_node = false };
    for ([_]search.Direction{ .forward, .reverse }) |direction| {
        const rank_begin: endpoints.Ranked = .{ .all = &.{begin}, .preferred_count = 1, .ignored_filter = false };
        const rank_end: endpoints.Ranked = .{ .all = &.{end}, .preferred_count = 1, .ignored_filter = false };
        const result = try endpoints.routeRanked(&engine, &workspace, kernel, rank_begin, rank_end, .{ .direction = direction, .costing = .auto }, search.Zero{}, .{});
        const path = result.segments;
        try testing.expectEqual(2, path.len);
        try testing.expectEqual(de, path[0].edge);
        try testing.expectEqual(ef, path[1].edge);
        const priced = switch (direction) {
            .forward => try Recost.walk(view, kernel, path, null, .forward, .{}),
            .reverse => try Recost.walk(view, kernel, path, null, .reverse, .{}),
        };
        try testing.expectApproxEqAbs(priced.cost, result.cost, 1e-4);
        try testing.expectApproxEqAbs(priced.secs, result.secs, 1e-4);
        workspace.reset();
    }

    const empty = try routing.api.request.parseHttp(a, "/route", &.{}, "{\"linear_cost_factors\":[{\"shape\":\"\"}]}");
    try testing.expectEqual(@as(u16, 173), empty.failure.code);
    try testing.expectEqualStrings("feature coordinates are empty", empty.failure.extra);
    const wrong_type = try routing.api.request.parseHttp(a, "/route", &.{}, "{\"linear_cost_factors\":2}");
    try testing.expectEqualSlices(u16, &.{212}, wrong_type.ok.warnings.items);
    const missing = try linear.resolve(view, a, &workspace, &.{.{ .points = &.{ b, .init(9, 9) } }}, .{}, .{});
    try testing.expectEqual(@as(u16, 173), missing.failure.code);
    const failed = (try linear.resolve(view, a, &workspace, &.{.{ .points = &.{b} }}, .{}, .{})).ok;
    try testing.expectEqualStrings("0", failed.failed);
    try testing.expectEqual(@as(u16, 234), (try linear.resolve(view, a, &workspace, &.{.{ .points = &.{ b, c, d }, .factor = 2 }}, .{ .max_edges = 0 }, .{})).failure.code);
}
