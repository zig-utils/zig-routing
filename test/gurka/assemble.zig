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
    var built = try Built.assemble(fixture.osm, 1);
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
