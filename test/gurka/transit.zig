const std = @import("std");
const routing = @import("routing");
const gurka = @import("gurka.zig");
const io = routing.infra.io;
const build = routing.build;
const graph = routing.graph;
const testing = std.testing;
const feed = @embedFile("transit.zip");

test "GTFS transit prepares a restartable graph with the same bytes across worker counts" {
    var memory: std.heap.ArenaAllocator = .init(testing.allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const parent = try io.Directory.open(".");
    defer parent.close();
    const scratch = try parent.temporaryChild();
    defer parent.deleteDir(&scratch.name) catch {};
    defer scratch.dir.close();
    defer {
        for ([_][:0]const u8{ "serial", "parallel" }) |name| deleteWork(scratch.dir, name);
        for ([_][:0]const u8{ "bundle-serial", "bundle-parallel" }) |name| deleteBundle(scratch.dir, name);
        for ([_][:0]const u8{ "street.osm.pbf", "feed.zip", "zones.json" }) |name| scratch.dir.deleteFile(name) catch {};
    }
    const base = &scratch.name;
    const street = try std.fs.path.join(a, &.{ base, "street.osm.pbf" });
    const feed_path = try std.fs.path.join(a, &.{ base, "feed.zip" });
    const zone_path = try std.fs.path.join(a, &.{ base, "zones.json" });
    const serial = try std.fs.path.join(a, &.{ base, "serial" });
    const parallel = try std.fs.path.join(a, &.{ base, "parallel" });
    const first_bundle = try std.fs.path.join(a, &.{ base, "bundle-serial" });
    const second_bundle = try std.fs.path.join(a, &.{ base, "bundle-parallel" });
    const map = try gurka.Map.init(a, try gurka.mapToCoordinatesAt("A---B---C", 20, .{ .lng = 1, .lat = 1 }), &.{
        .{ .label = "AB", .tags = &.{ .{ .key = "highway", .value = "residential" }, .{ .key = "osm_id", .value = "9001" }, .{ .key = "name", .value = "Main Street" } } },
        .{ .label = "BC", .tags = &.{ .{ .key = "highway", .value = "residential" }, .{ .key = "foot", .value = "no" } } },
    }, &.{}, &.{});
    try map.osm.writePbf(a, street);
    try io.writeFile(feed_path, feed);
    try io.writeFile(zone_path,
        \\{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"tzid":"Europe/London"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[3,0],[3,3],[0,3],[0,0]]]}}]}
    );

    var diagnostic: build.driver.Diagnostic = .{};
    const common: build.driver.Options = .{
        .inputs = &.{street},
        .gtfs_inputs = &.{feed_path},
        .timezone_geojson = zone_path,
        .timezone_rules = "test/fuzz/seeds/timezone-rules.bin",
        .work_dir = serial,
        .workers = 1,
        .to = .transit,
    };
    const prepared = try build.driver.run(testing.allocator, common, null, &diagnostic);
    defer prepared.deinit(testing.allocator);
    const report = prepared.transit.?;
    try testing.expectEqual(3, report.platforms);
    try testing.expectEqual(2, report.connected);
    try testing.expectEqual(1, report.no_pedestrian_street);
    try testing.expectEqual(2, report.street_links);
    try testing.expectEqual(4, report.station_links);
    try testing.expectEqual(1, report.lines);
    try testing.expectEqual(2, report.departures);

    try scratch.dir.deleteFile("feed.zip");
    const resumed = try build.driver.run(testing.allocator, .{
        .work_dir = serial,
        .output = first_bundle,
        .workers = 1,
        .from = .order,
    }, null, &diagnostic);
    defer resumed.deinit(testing.allocator);
    try testing.expectEqualDeep(report, resumed.transit.?);
    var first = try graph.reader.Bundle.openVerified(first_bundle, .none, null);
    defer first.close();
    const transit = first.view.transit_index.?;
    try testing.expectEqual(2, transit.stations.len);
    try testing.expectEqual(2, transit.egresses.len);
    try testing.expectEqual(0, transit.stops[0].station);
    try testing.expectEqual(0, transit.stops[1].station);
    try testing.expectEqual(1, transit.stops[2].station);
    try testing.expectEqualStrings("Market Station", (try transit.text(transit.stations[0].place.name)).?);
    try testing.expectEqualStrings("193B58", (try transit.text(transit.routes[0].color)).?);
    try testing.expectEqualStrings("Europe/Amsterdam", (try transit.text(transit.stops[0].place.timezone)).?);
    const expected_timezone = try first.view.tz_rules.?.id("Europe/Amsterdam");
    try testing.expect(expected_timezone != graph.timezone.unknown);
    try testing.expectEqual(expected_timezone, try first.view.nodeTimezone(@fromBackingInt(transit.stops[0].place.graph_node)));
    try testing.expectEqual(0, transit.lines[0].origin);
    try testing.expectEqual(1, transit.lines[0].destination);
    const fixed = (try transit.nextDeparture(0, 7 * 3600)).?;
    try testing.expectEqual(8 * 3600, fixed.time);
    try testing.expectEqual(300, fixed.departure.elapsed_time);
    try testing.expect(fixed.departure.flags.wheelchair);
    const frequency = (try transit.nextDeparture(0, 9 * 3600 + 5)).?;
    try testing.expectEqual(9 * 3600 + 1800, frequency.time);
    try testing.expect(frequency.departure.flags.bicycle);
    try testing.expectEqualStrings("Express", (try transit.text(frequency.departure.headsign)).?);
    try testing.expect(try transit.scheduleActive(fixed.departure.schedule, transit.metadata.start_day + 64, .friday));
    try testing.expect(!try transit.scheduleActive(fixed.departure.schedule, transit.metadata.start_day + 68, .tuesday));
    try testing.expectEqual(2, transit.transfers.len);
    try testing.expectEqual(.forbidden, transit.transfers[0].flags.kind);
    try testing.expectEqual(.minimum_time, transit.transfers[1].flags.kind);
    try testing.expectEqual(9, transit.transfers[1].minimum_time);
    try testing.expectEqual(1, transit.transfers[1].origin);
    try testing.expectEqual(0, transit.transfers[1].destination);

    const entrance = transit.egresses[0];
    try testing.expect(entrance.flags.has_connecting_point and entrance.flags.has_connecting_way);
    try testing.expectEqual(9001, entrance.connecting_way);
    const incident = try first.view.outEdgeRange(@fromBackingInt(entrance.place.graph_node));
    var street_links: usize = 0;
    var connector: ?graph.format.EdgeHot = null;
    for (incident.first..incident.end) |slot| {
        const edge = first.view.edges[slot];
        const class = try first.view.class(edge.cls.class_id);
        if (class.category.use == @backingInt(graph.constants.Use.transit_connection)) {
            street_links += 1;
            connector = edge;
            try testing.expect(class.forwardAccess().pedestrian and !class.forwardAccess().auto);
            try testing.expectEqual(9001, try first.view.wayId(@fromBackingInt(@as(u32, @intCast(slot)))));
        }
    }
    try testing.expectEqual(2, street_links);

    const costing = routing.costing;
    const costing_json = try routing.api.json.parse(a,
        \\{"pedestrian":{"mode_factor":2,"transit_start_end_max_distance":9,"transit_transfer_max_distance":7},
        \\"transit":{"wheelchair":true,"filters":{
        \\"stops":{"action":"include","ids":["gtfs:0:stop:S","gtfs:0:stop:P1","gtfs:0:stop:P2"]},
        \\"routes":{"action":"include","ids":["gtfs:0:route:R"]},
        \\"operators":{"action":"exclude","ids":["another-agency"]}}}}
    );
    var warnings: std.ArrayList(costing.base.Warning) = .empty;
    var model = try costing.multimodal.parse(a, costing_json, &warnings, .none);
    try testing.expectEqual(0, warnings.items.len);
    var allocation_counter: routing.infra.arena.CountingAllocator = .init(testing.allocator);
    var request_memory: std.heap.ArenaAllocator = .init(allocation_counter.allocator());
    defer request_memory.deinit();
    const multimodal = try costing.multimodal.Kernel.init(request_memory.allocator(), &first.view, model, .none);
    allocation_counter.resetCounts();
    try testing.expect(try multimodal.allowsStation(&first.view, 0));
    try testing.expect(!try multimodal.allowsStation(&first.view, 1));
    try testing.expect(try multimodal.allowsStop(&first.view, 0));
    try testing.expect(!try multimodal.allowsStop(&first.view, 2));
    try testing.expect(try multimodal.allowsDeparture(&first.view, fixed.departure));
    try testing.expect(!try multimodal.allowsDeparture(&first.view, frequency.departure));
    var walk_edge = connector.?;
    walk_edge.geom.len_m = 8;
    const walk_class = try first.view.class(walk_edge.cls.class_id);
    try testing.expect(multimodal.allowsWalk(.start_or_end, walk_class, walk_class, walk_edge, .{}));
    try testing.expect(!multimodal.allowsWalk(.transfer, walk_class, walk_class, walk_edge, .{}));
    walk_edge.geom.len_m = 7;
    try testing.expect(multimodal.allowsWalk(.transfer, walk_class, walk_class, walk_edge, .{}));
    const walk_cost = multimodal.walkCost(walk_class, walk_edge, 0, .{});
    const ordinary = costing.pedestrian.Kernel.edgeCost(&multimodal.walking, &multimodal.walking_table, walk_class, walk_edge, 0, .{});
    try testing.expectEqual(ordinary.cost * 2, walk_cost.cost);
    try testing.expectEqual(ordinary.secs, walk_cost.secs);
    try testing.expectEqual(0, multimodal.modeChangeCost(.pedestrian, .transit).cost);
    try testing.expectEqual(60, multimodal.transferCost(.between_stations).secs);
    try testing.expectEqual(0, allocation_counter.calls());
    model.transit.operators = .{ .action = .exclude, .ids = &.{"gtfs:0:agency:operator"} };
    const restricted = try costing.multimodal.Kernel.init(a, &first.view, model, .none);
    try testing.expect(!try restricted.allowsDeparture(&first.view, fixed.departure));

    try io.writeFile(feed_path, feed);
    var options = common;
    options.work_dir = parallel;
    options.output = second_bundle;
    options.workers = 4;
    options.to = .finalize;
    const other = try build.driver.run(testing.allocator, options, null, &diagnostic);
    defer other.deinit(testing.allocator);
    try testing.expectEqualDeep(report, other.transit.?);
    try testing.expectEqual(resumed.dataset_uuid, other.dataset_uuid);
    var second = try graph.reader.Bundle.openVerified(second_bundle, .none, null);
    defer second.close();
    for (std.enums.values(graph.format.SectionKind)) |kind|
        try testing.expectEqualSlices(u8, first.mappings.get(kind).bytes, second.mappings.get(kind).bytes);

    const serial_dir = try scratch.dir.child("serial");
    defer serial_dir.close();
    const parallel_dir = try scratch.dir.child("parallel");
    defer parallel_dir.close();
    const stage1 = try build.checkpoint.Existing.open(testing.allocator, serial_dir, .transit, resumed.dataset_uuid);
    defer stage1.close();
    const stage4 = try build.checkpoint.Existing.open(testing.allocator, parallel_dir, .transit, other.dataset_uuid);
    defer stage4.close();
    try testing.expectEqualDeep(stage1.manifest.files, stage4.manifest.files);
}

fn deleteWork(root: io.Directory, name: [:0]const u8) void {
    const work = root.child(name) catch return;
    defer work.close();
    for (std.enums.values(build.driver.Stage)) |stage| {
        const dir = work.child(stage.folder()) catch continue;
        var buffer: [96]u8 = undefined;
        for (std.enums.values(build.checkpoint.Artifact)) |artifact| {
            const filename = std.fmt.bufPrint(&buffer, "{s}.bin\x00", .{@tagName(artifact)}) catch unreachable;
            dir.deleteFile(filename[0 .. filename.len - 1 :0]) catch {};
        }
        dir.deleteFile("manifest.json") catch {};
        dir.close();
        work.deleteDir(stage.folder()) catch {};
    }
    work.deleteFile("build-stats.json") catch {};
    root.deleteDir(name) catch {};
}

fn deleteBundle(root: io.Directory, name: [:0]const u8) void {
    const dir = root.child(name) catch return;
    for (std.enums.values(graph.format.SectionKind)) |kind| dir.deleteFile(kind.filename()) catch {};
    dir.close();
    root.deleteDir(name) catch {};
}
