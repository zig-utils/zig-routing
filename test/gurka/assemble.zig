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
        const stats = try build.assemble.build(testing.allocator, try build.pbf.file.Stream.init(file), &writer, .{
            .scratch_dir = &root.name,
            .workers = workers,
        });
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

    var result = try Built.assemble(fixture.osm, 4);
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
                for (try view.turnRow(id, edge.cls.local)) |entry| {
                    try testing.expectEqual(build.turns.encode(.straight, 0, true), entry);
                }
            } else real += 1;
        }
    }
    try testing.expectEqual(3, aliases);
    try testing.expectEqual(leaves, real);
    try testing.expectEqual(4, connectors);
}
