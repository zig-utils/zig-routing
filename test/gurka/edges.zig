const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const build = routing.build;
const edge = build.edges;
const gurka = @import("gurka.zig");
const pbf = @import("pbf.zig");
const testing = std.testing;

const road: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};

const Result = struct {
    stats: edge.Stats,
    edges: []edge.Edge,
    shapes: []routing.geo.FixedLL,
    way_ids: []i64,
};

fn run(arena: std.mem.Allocator, dataset: gurka.Dataset, workers: usize) !Result {
    const input = try io.File.temporary(".");
    defer input.close();
    const edge_file = try io.File.temporary(".");
    defer edge_file.close();
    const shape_file = try io.File.temporary(".");
    defer shape_file.close();
    try input.pwriteAll(try pbf.encode(arena, dataset), 0);

    var sink: WaySink = .{ .arena = arena };
    const stats = try edge.build(testing.allocator, try build.pbf.file.Stream.init(input), .{
        .edges = edge_file,
        .shapes = shape_file,
    }, .{ .scratch_dir = ".", .workers = workers }, &sink, WaySink.append);

    const edges = try arena.alloc(edge.Edge, @intCast(stats.edges));
    const shapes = try arena.alloc(routing.geo.FixedLL, @intCast(stats.shape_points));
    try testing.expectEqual(@as(u64, edges.len * @sizeOf(edge.Edge)), try edge_file.size());
    try testing.expectEqual(@as(u64, shapes.len * @sizeOf(routing.geo.FixedLL)), try shape_file.size());
    try edge_file.preadAll(std.mem.sliceAsBytes(edges), 0);
    try shape_file.preadAll(std.mem.sliceAsBytes(shapes), 0);
    return .{ .stats = stats, .edges = edges, .shapes = shapes, .way_ids = sink.ids.items };
}

const WaySink = struct {
    arena: std.mem.Allocator,
    ids: std.ArrayList(i64) = .empty,

    fn append(self: *WaySink, id: i64, attrs: build.tags.WayAttrs, raw: build.pbf.block.TagIterator) !void {
        try testing.expectEqual(.residential, attrs.road_class);
        var iter = raw;
        var street = false;
        while (try iter.next()) |tag| {
            if (std.mem.eql(u8, tag.key, "highway") and std.mem.eql(u8, tag.value, "residential")) street = true;
        }
        try testing.expect(street);
        try self.ids.append(self.arena, id);
    }
};

test "ways split at intersections, loop midpoints, barriers and dead ends" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const layout = try gurka.mapToCoordinates(
        \\A---B---C---D
        \\        |
        \\        E
        \\
        \\F---G
        \\|  /
        \\H
        \\
        \\I---J---K
        \\
        \\L---M
        \\
        \\N---O---P
        \\
        \\Q---R---S
    , 10);
    const fixture = try gurka.Map.init(arena, layout, &.{
        .{ .label = "ABCD", .tags = road },
        .{ .label = "CE", .tags = road },
        .{ .label = "FGHF", .tags = road },
        .{ .label = "IJJK", .tags = road },
        .{ .label = "LM", .tags = road },
        .{ .label = "ML", .tags = road },
        .{ .label = "NOP", .tags = road },
        .{ .label = "QRSRQ", .tags = road },
    }, &.{
        .{ .label = "B", .tags = &.{
            .{ .key = "highway", .value = "traffic_signals" },
            .{ .key = "traffic_signals:direction", .value = "forward" },
        } },
        .{ .label = "O", .tags = &.{.{ .key = "barrier", .value = "gate" }} },
    }, &.{});

    const result = try run(arena, fixture.osm, 1);
    try testing.expectEqual(17, result.stats.nodes);
    try testing.expectEqual(13, result.stats.edges);
    try testing.expectEqual(1, result.stats.self_edges);
    try testing.expectEqual(1, result.stats.zero_length_edges);
    try testing.expectEqual(1, result.stats.duplicate_edges);
    try testing.expectEqual(8, result.way_ids.len);

    const pairs = [_][]const u8{ "AC", "CD", "CE", "FG", "GF", "IJ", "JK", "LM", "ML", "NO", "OP", "QR", "RS" };
    for (result.edges, pairs) |record, pair| {
        try testing.expectEqual(fixture.findNode(pair[0..1]).?.id, record.from);
        try testing.expectEqual(fixture.findNode(pair[1..2]).?.id, record.to);
    }
    const first = result.edges[0];
    try testing.expectEqual(fixture.findWay("ABCD").?.id, first.way_id);
    try testing.expectEqual(3, first.shape_count);
    try testing.expect(first.flags.way_begin and !first.flags.way_end);
    try testing.expect(first.flags.traffic_signal and first.flags.forward_signal and !first.flags.backward_signal);
    try testing.expect(result.edges[1].flags.way_end and !result.edges[1].flags.traffic_signal);
    try testing.expectEqual(3, result.edges[4].shape_count);
    const start: usize = @intCast(first.shape_offset);
    const shape = result.shapes[start..][0..first.shape_count];
    try testing.expectEqual(layout.get("B").?.toFixed(), shape[1]);
    try testing.expectEqual(
        shape[0].toPoint().distance(shape[1].toPoint()) + shape[1].toPoint().distance(shape[2].toPoint()),
        first.length_m,
    );

    const shuffled = try arena.dupe(gurka.OsmNode, fixture.osm.nodes);
    std.mem.reverse(gurka.OsmNode, shuffled);
    var unsorted = fixture.osm;
    unsorted.nodes = shuffled;
    const replay = try run(arena, unsorted, 1);
    try testing.expectEqual(result.stats, replay.stats);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(result.edges), std.mem.sliceAsBytes(replay.edges));
}

test "unresolved ways and coincident endpoints are counted" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const fixture = try gurka.Map.init(arena, try gurka.mapToCoordinates("A---B", 10), &.{
        .{ .label = "AB", .tags = road },
    }, &.{}, &.{});
    const a = fixture.findNode("A").?;
    const b = fixture.findNode("B").?;
    const nodes = [_]gurka.OsmNode{ a.*, .{ .id = b.id, .label = "B", .location = a.location, .tags = b.tags } };
    const ways = [_]gurka.OsmWay{
        fixture.osm.ways[0],
        .{ .id = fixture.osm.ways[0].id + 1, .label = "AX", .refs = &.{ a.id, 987 }, .tags = road },
        .{ .id = fixture.osm.ways[0].id + 2, .label = "AXB", .refs = &.{ a.id, 987, b.id }, .tags = road },
        .{ .id = fixture.osm.ways[0].id + 3, .label = "A", .refs = &.{a.id}, .tags = road },
    };
    const result = try run(arena, .{ .nodes = &nodes, .ways = &ways, .relations = &.{} }, 1);
    try testing.expectEqual(1, result.stats.edges);
    try testing.expectEqual(2, result.stats.nodes);
    try testing.expectEqual(1, result.stats.zero_length_edges);
    try testing.expectEqual(0, result.edges[0].length_m);
    try testing.expectEqual(0, result.stats.self_edges);
    try testing.expectEqual(2, result.stats.unresolved_ways);
    try testing.expectEqual(2, result.stats.missing_node_refs);
    try testing.expectEqual(2, result.stats.too_short_ways);
}

test "way, edge and shape streams are identical across worker counts" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const fixture = try gurka.Map.init(arena, try gurka.mapToCoordinates("A---B---C", 10), &.{
        .{ .label = "ABC", .tags = road },
    }, &.{}, &.{});
    var ways: [257]gurka.OsmWay = undefined;
    for (&ways, 1..) |*way, i| {
        way.* = fixture.osm.ways[0];
        way.id = @intCast(i);
    }
    var dataset = fixture.osm;
    dataset.ways = &ways;
    const serial = try run(arena, dataset, 1);
    const parallel = try run(arena, dataset, 4);
    try testing.expectEqual(serial.stats, parallel.stats);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(serial.edges), std.mem.sliceAsBytes(parallel.edges));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(serial.shapes), std.mem.sliceAsBytes(parallel.shapes));
    try testing.expectEqualSlices(i64, serial.way_ids, parallel.way_ids);
    try testing.expectEqual(512, parallel.stats.duplicate_edges);
}
