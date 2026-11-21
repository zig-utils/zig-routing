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
            const id: graph.format.EdgeId = @fromBackingInt(@as(u32, @intCast(slot)));
            try testing.expectEqual(9001, try first.view.wayId(id));
            const keys = first.view.edge_key_index.?;
            const key = try keys.key(id);
            try testing.expectEqual(.transit, key.flags.kind);
            try testing.expectEqual(9001, key.way_id);
            try testing.expectEqual(@as(?graph.format.EdgeId, id), try keys.find(key));
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

    try checkScheduledRoute(&first.view);

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

fn checkScheduledRoute(view: *const graph.reader.View) !void {
    const routing_search = routing.search;
    const transit = view.transit_index.?;
    const from: graph.format.NodeId = @fromBackingInt(transit.stops[0].place.graph_node);
    const to: graph.format.NodeId = @fromBackingInt(transit.stops[1].place.graph_node);
    const departure_edge = try view.oppEdge(@fromBackingInt((try view.outEdgeRange(from)).first));
    const arrival_edge: graph.format.EdgeId = @fromBackingInt((try view.outEdgeRange(to)).first);
    const origin: routing_search.endpoints.Ranked = .{
        .all = &.{.{ .edge = departure_edge, .fraction = 1, .score = 0, .begin_node = false, .end_node = true }},
        .preferred_count = 1,
        .ignored_filter = false,
    };
    const destination: routing_search.endpoints.Ranked = .{
        .all = &.{.{ .edge = arrival_edge, .fraction = 0, .score = 0, .begin_node = true, .end_node = false }},
        .preferred_count = 1,
        .ignored_filter = false,
    };
    var counter = routing.infra.arena.CountingAllocator.init(testing.allocator);
    var scratch = routing.infra.arena.Arena.init(counter.allocator(), .{});
    defer scratch.deinit();
    const a = scratch.allocator();
    const rules = &view.tz_rules.?;
    const london = try rules.id("Europe/London");
    const amsterdam = try rules.id("Europe/Amsterdam");
    for (0..3) |pass| {
        scratch.reset();
        if (pass != 0) counter.resetCounts();
        var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
        var model = try routing.costing.multimodal.parse(a, .null, &warnings, .none);
        model.pedestrian.transit_start_end_max_distance = 0;
        model.transit.wheelchair = true;
        const kernel = try routing.costing.multimodal.Kernel.init(a, view, model, .none);
        const search = try routing_search.multimodal.Search.init(a, view, &kernel, .{});
        const start = try graph.time_info.TimeInfo.fromLocal(rules, "2026-03-09T06:59", london, graph.timezone.utc, 0, .none);
        var options: routing_search.endpoints.Options = .{ .costing = .multimodal, .timing = .{ .start = start } };
        const path = try search.run(&scratch, origin, destination, options, .{});
        try testing.expectEqual(3, path.steps.len);
        const ride = path.steps[1].movement.ride;
        const scheduled = try graph.time_info.TimeInfo.fromLocal(rules, "2026-03-09T08:00", amsterdam, graph.timezone.utc, 0, .none);
        try testing.expectEqual(scheduled.unix_time, ride.departure_time);
        try testing.expectEqual(scheduled.unix_time + 300, ride.arrival_time);
        try testing.expectEqual(360, path.total.secs);
        try checkTripLeg(a, view, path, departure_edge, arrival_edge, start);
        if (pass == 0) {
            var cut = destination.all[0];
            cut.score = 10_000;
            var scored = destination;
            scored.all = &.{cut};
            const signed = try search.run(&scratch, origin, scored, options, .{});
            try testing.expect(signed.total.cost < 0);
            try checkTripLeg(a, view, signed, departure_edge, arrival_edge, start);
        }
        options.timing.start = try graph.time_info.TimeInfo.fromLocal(rules, "2026-03-10T06:59", london, graph.timezone.utc, 0, .none);
        try testing.expectError(error.NoPath, search.run(&scratch, origin, destination, options, .{}));
        try testing.expectError(error.Cancelled, search.run(&scratch, origin, destination, options, .{ .deadline = .{ .at_ns = 0 } }));
        if (pass != 0) try testing.expectEqual(0, counter.calls());
    }

    scratch.reset();
    try checkOvertaking(&scratch, view, origin, destination, london);
    scratch.reset();
    try checkOriginWalkCost(&scratch, view, london);
}

fn checkOriginWalkCost(arena: *routing.infra.arena.Arena, view: *const graph.reader.View, london: graph.timezone.Id) !void {
    const a = arena.allocator();
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    var model = try routing.costing.multimodal.parse(a, .null, &warnings, .none);
    model.pedestrian.mode_factor = 2;
    const kernel = try routing.costing.multimodal.Kernel.init(a, view, model, .none);
    const engine = try routing.search.multimodal.Search.init(a, view, &kernel, .{});
    const start = try graph.time_info.TimeInfo.fromLocal(&view.tz_rules.?, "2026-03-09T06:59", london, graph.timezone.utc, 0, .none);
    const id: graph.format.EdgeId = for (view.edges, 0..) |edge, i| {
        const class = try view.class(edge.cls.class_id);
        if (edge.geom.len_m == 0 or class.category.use != @backingInt(graph.constants.Use.road) or
            !kernel.walking.allowedCandidate(class, .{}, .{}, false)) continue;
        break @fromBackingInt(@as(u32, @intCast(i)));
    } else return error.MissingWalkingStreet;
    const origin: routing.search.endpoints.Ranked = .{
        .all = &.{.{ .edge = id, .fraction = 0.25, .score = 0, .begin_node = false, .end_node = false }},
        .preferred_count = 1,
        .ignored_filter = false,
    };
    const destination: routing.search.endpoints.Ranked = .{
        .all = &.{.{ .edge = id, .fraction = 0.75, .score = 0, .begin_node = false, .end_node = false }},
        .preferred_count = 1,
        .ignored_filter = false,
    };
    const path = try engine.run(arena, origin, destination, .{ .costing = .multimodal, .timing = .{ .start = start } }, .{});
    try testing.expectEqual(1, path.steps.len);
    const edge = try view.edge(id);
    const class = try view.class(edge.cls.class_id);
    const base_cost = routing.costing.pedestrian.Kernel.edgeCost(&kernel.walking, &kernel.walking_table, class, edge.*, 0, .{});
    try testing.expectEqual(base_cost.cost * 0.5, path.total.cost);
    try testing.expectEqual(base_cost.secs * 0.5, path.total.secs);
}

fn checkOvertaking(arena: *routing.infra.arena.Arena, original: *const graph.reader.View, origin: routing.search.endpoints.Ranked, destination: routing.search.endpoints.Ranked, london: graph.timezone.Id) !void {
    const a = arena.allocator();
    var view = original.*;
    var table = original.transit_index.?;
    var lines = [1]graph.transit.Line{table.lines[0]};
    lines[0].departures = .{ .count = 2 };
    lines[0].occurrences = .{};
    var departures = [2]graph.transit.Departure{ table.departures[0], table.departures[0] };
    departures[0].elapsed_time = 20 * 60;
    departures[1].start_time += 2 * 60;
    departures[1].elapsed_time = 60;
    departures[1].trip += 1;
    table.lines = &lines;
    table.departures = &departures;
    table.occurrences = &.{};
    view.transit_index = table;

    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    var options = try routing.costing.multimodal.parse(a, .null, &warnings, .none);
    options.pedestrian.transit_start_end_max_distance = 0;
    const kernel = try routing.costing.multimodal.Kernel.init(a, &view, options, .none);
    const search = try routing.search.multimodal.Search.init(a, &view, &kernel, .{});
    const start = try graph.time_info.TimeInfo.fromLocal(&view.tz_rules.?, "2026-03-09T06:59", london, graph.timezone.utc, 0, .none);
    try testing.expectEqual(departures[0].trip, (try table.nextDeparture(0, 0)).?.departure.trip);
    const path = try search.run(arena, origin, destination, .{ .costing = .transit, .timing = .{ .start = start } }, .{});
    try testing.expectEqual(departures[1].trip, path.steps[1].movement.ride.departure.trip);
    try testing.expectEqual(240, path.total.secs);

    // Valhalla subtracts the destination score with the untraversed tail.
    // A negative total still selects the same minimum-cost departure.
    var terminal = destination.all[0];
    terminal.score = 10_000;
    var scored = destination;
    scored.all = &.{terminal};
    const priced = try search.run(arena, origin, scored, .{ .costing = .transit, .timing = .{ .start = start } }, .{});
    try testing.expectEqual(departures[1].trip, priced.steps[1].movement.ride.departure.trip);
    try testing.expectEqual(path.total.secs, priced.total.secs);
    try testing.expectEqual(path.total.cost - terminal.score, priced.total.cost);
}

fn checkTripLeg(a: std.mem.Allocator, view: *const graph.reader.View, path: routing.search.multimodal.Path, from: graph.format.EdgeId, to: graph.format.EdgeId, start: graph.time_info.TimeInfo) !void {
    const table = view.transit_index.?;
    const origin = table.stops[0].place.coordinate.toTilePoint();
    const destination = table.stops[1].place.coordinate.toTilePoint();
    var locations = [_]routing.api.request.Location{
        .{ .lat = origin.lat, .lng = origin.lng },
        .{ .lat = destination.lat, .lng = destination.lng, .original_index = 1 },
    };
    const opts: routing.api.request.Options = .{ .action = .route, .costing = .multimodal, .locations = &locations };
    const selected: routing.api.route_action.ScheduledRoute = .{
        .paths = &.{path},
        .correlations = &.{
            .{ .edges = &.{.{ .id = from, .projected = origin, .distance = 0, .percent_along = 1, .heading = 0, .node = .end }}, .filtered_edges = &.{}, .rank_candidates = true },
            .{ .edges = &.{.{ .id = to, .projected = destination, .distance = 0, .percent_along = 0, .heading = 0, .node = .begin }}, .filtered_edges = &.{}, .rank_candidates = true },
        },
        .waypoints = &.{
            .{ .elapsed_secs = 0, .waiting_secs = 0, .date_time = null, .ignored_filter = false, .clock = start },
            .{ .elapsed_secs = path.total.secs, .waiting_secs = 0, .date_time = null, .ignored_filter = false },
        },
        .pedestrian_type = .foot,
    };
    const legs = try selected.trip(a, view, &opts, .{});
    try testing.expectEqual(1, legs.len);
    try testing.expectEqual(4, legs[0].node.len);
    const bus = legs[0].node[1];
    try testing.expectEqual(.kTransit, bus.edge.?.travel_mode);
    try testing.expectEqual(.kBus, bus.edge.?.transit_type);
    try testing.expectEqualStrings("gtfs:0:route:R", bus.edge.?.transit_route_info.?.onestop_id);
    try testing.expectEqual(0x193B58, bus.edge.?.transit_route_info.?.color);
    try testing.expectEqualStrings("Platform One", bus.transit_platform_info.?.name);
    try testing.expectEqualStrings("2026-03-09T08:00+01:00", bus.transit_platform_info.?.departure_date_time);
    const exit = legs[0].node[2].transit_platform_info.?;
    try testing.expectEqualStrings("Platform Two", exit.name);
    try testing.expectEqualStrings("2026-03-09T08:05+01:00", exit.arrival_date_time);
    try testing.expectEqualStrings("", exit.departure_date_time);
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
