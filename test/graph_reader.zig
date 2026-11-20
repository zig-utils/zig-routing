const std = @import("std");
const routing = @import("routing");
const format = routing.graph.format;
const reader = routing.graph.reader;
const io = routing.infra.io;
const testing = std.testing;
const sample = @import("graph_fixture.zig");
const transit = routing.graph.transit;
const edges = sample.records(.edges);

const Fixture = struct {
    parent: io.Directory,
    root: io.Directory,
    name: io.Directory.TempName,

    fn create() !Fixture {
        return createWithTransit(false);
    }

    fn createWithTransit(include_transit: bool) !Fixture {
        const parent = try io.Directory.open(".");
        errdefer parent.close();
        const root = try parent.temporaryChild();
        errdefer {
            root.dir.close();
            parent.deleteDir(&root.name) catch {};
        }
        const fixture: Fixture = .{ .parent = parent, .root = root.dir, .name = root.name };
        var buf: [80]u8 = undefined;
        if (include_transit) {
            try sample.writeTransit(testing.allocator, fixture.path(&buf));
        } else {
            try sample.write(fixture.path(&buf));
        }
        return fixture;
    }

    fn path(self: *const Fixture, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/bundle", .{self.name}) catch unreachable;
    }

    fn section(self: *const Fixture, file: format.SectionKind) !io.File {
        var buf: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "{s}/bundle/{s}", .{ self.name, file.filename() });
        return io.File.open(name, .read_write);
    }

    fn deinit(self: Fixture) void {
        if (self.root.child("bundle")) |dir| {
            for (std.enums.values(format.SectionKind)) |kind| dir.deleteFile(kind.filename()) catch {};
            dir.close();
            self.root.deleteDir("bundle") catch {};
        } else |_| {}
        self.root.close();
        self.parent.deleteDir(&self.name) catch {};
        self.parent.close();
    }
};

test "mapped records have checked typed accessors and offline checksums" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    var bundle = try reader.Bundle.open(fixture.path(&buf));
    defer bundle.close();
    const view = &bundle.view;
    try view.verify(.none, null);
    try testing.expectEqual(null, view.transit_index);
    try testing.expectEqual(null, view.header(.transit_departures));
    try testing.expectEqual(sample.header(.nodes).dataset_uuid, view.dataset_uuid);
    try testing.expectEqual(1234, (try view.edge(@fromBackingInt(@intCast(0)))).geom.len_m);
    try testing.expectEqual(5, (try view.node(@fromBackingInt(@intCast(1)))).attr.density);
    try testing.expectEqualSlices(format.EdgeHot, edges[1..], try view.outEdges(@fromBackingInt(@intCast(1))));
    try testing.expectEqual(@as(format.EdgeId, @fromBackingInt(@intCast(1))), try view.oppEdge(@fromBackingInt(@intCast(0))));
    try testing.expectEqual(@as(format.EdgeId, @fromBackingInt(@intCast(0))), try view.oppEdge(@fromBackingInt(@intCast(1))));
    try testing.expectEqualSlices(u8, &.{0x72}, try view.turnRow(@fromBackingInt(@intCast(1)), 0));
    try testing.expectError(error.InvalidNodeId, view.node(@fromBackingInt(@intCast(2))));
    try testing.expectError(error.InvalidEdgeId, view.edge(@fromBackingInt(@intCast(2))));
    try testing.expectError(error.InvalidLocalEdge, view.turnRow(@fromBackingInt(@intCast(1)), 1));
    try testing.expectEqual(3, (try view.class(edges[0].cls.class_id)).access.forward);
    try testing.expectEqual(7, (try view.class(edges[1].cls.class_id)).access.forward);
    try testing.expectError(error.InvalidClassId, view.class(2));
    const sign_api = routing.graph.signs;
    try testing.expect(try sign_api.hasSigns(view, @fromBackingInt(0)));
    try testing.expect(!try sign_api.hasSigns(view, @fromBackingInt(1)));
    const edge_signs = try sign_api.signsForEdge(view, @fromBackingInt(0));
    const node_signs = try sign_api.signsForNode(view, @fromBackingInt(0));
    try testing.expectEqual(1, edge_signs.len);
    try testing.expectEqual(1, node_signs.len);
    try testing.expect(edge_signs[0].attr.route_number and node_signs[0].attr.tagged);
    try testing.expectEqualStrings("Main", try edge_signs[0].text(view.cold_data.?));
    try testing.expectEqualStrings("Main", try node_signs[0].text(view.cold_data.?));
    const lane_api = routing.graph.lanes;
    try testing.expectEqualSlices(u16, &.{ 8, 66, 0 }, try lane_api.turnLanes(view, @fromBackingInt(0)));
    try testing.expectEqual(0, (try lane_api.turnLanes(view, @fromBackingInt(1))).len);
    const connectivity = try lane_api.laneConnectivity(view, @fromBackingInt(0));
    try testing.expectEqual(1, connectivity.len);
    try testing.expectEqual(0x1234_5678_9abc, connectivity[0].from_way);
    try testing.expectEqual(0, (try lane_api.laneConnectivity(view, @fromBackingInt(1))).len);
    const slopes = try view.edgeSlopes(@fromBackingInt(@as(u32, 1)));
    try testing.expectEqual(15, slopes.maxUp());
    try testing.expectEqual(-24, slopes.maxDown());
    const zone = try view.nodeTimezone(@fromBackingInt(0));
    try testing.expectEqual(@as(routing.graph.timezone.Id, 292), zone);
    try testing.expectEqualStrings("Europe/Amsterdam", (try view.tz_rules.?.name(zone)).?);
    try testing.expectEqual(@as(routing.graph.timezone.Id, 0), try view.nodeTimezone(@fromBackingInt(1)));
    const stamp = try routing.graph.time_info.TimeInfo.fromNode(view, @fromBackingInt(0), "2019-11-06T17:15", 1573056900, .none);
    try testing.expect(stamp.valid);
    try testing.expectEqual(zone, stamp.zone);
    try testing.expectEqual(1573056900, stamp.unix_time);

    const dir = try fixture.root.child("bundle");
    defer dir.close();
    try dir.deleteFile(format.SectionKind.signs.filename());
    try dir.deleteFile(format.SectionKind.turnlanes.filename());
    try dir.deleteFile(format.SectionKind.lane_connectivity.filename());
    try dir.deleteFile(format.SectionKind.classes.filename());
    var topology = try reader.Bundle.open(fixture.path(&buf));
    defer topology.close();
    try topology.view.verify(.none, null);
    try testing.expectError(error.MissingClassSection, topology.view.class(0));
}

test "transit sections round trip every field with checked timetable access" {
    const fixture = try Fixture.createWithTransit(true);
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    var bundle = try reader.Bundle.openVerified(fixture.path(&buf), .none, null);
    defer bundle.close();
    const view = &bundle.view;
    inline for (format.transit_sections) |kind| {
        const expected = sample.records(kind);
        const actual = @field(view, @tagName(kind)).?;
        try testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |written, read| try testing.expectEqualDeep(written, read);
        try testing.expectEqual(sample.header(kind), view.header(kind).?);
    }

    const timetable = view.transit_index.?;
    try testing.expectEqualDeep(sample.records(.transit_metadata)[0], timetable.metadata);
    const name = (try timetable.text(timetable.stops[0].place.name)).?;
    try testing.expectEqualStrings("Main", name);
    const street_name = try (try view.names(@fromBackingInt(0))).at(0);
    try testing.expectEqual(street_name.text.ptr, name.ptr);
    try testing.expectEqual(null, try timetable.text(timetable.stops[1].place.name));
    try testing.expectError(error.InvalidTransitText, timetable.text(@fromBackingInt(0x8000_0000)));

    const slots = sample.records(.transit_occurrences);
    for (0..132) |i| {
        const time: u32 = @intCast(i);
        const actual = try timetable.nextDeparture(0, time);
        for (slots) |slot| {
            if (slot.time < time) continue;
            try testing.expectEqual(slot.time, actual.?.time);
            try testing.expectEqual(&timetable.departures[slot.departure], actual.?.departure);
            break;
        } else try testing.expectEqual(null, actual);
    }
    const fixed = (try timetable.nextDeparture(1, 90061)).?;
    try testing.expectEqual(90062, fixed.time);
    try testing.expectEqual(&timetable.departures[4], fixed.departure);
    try testing.expectEqual(null, try timetable.nextDeparture(1, 90063));
    try testing.expectError(error.InvalidTransitLine, timetable.nextDeparture(2, 0));

    var repeated = try timetable.departureIterator(0, 120);
    for (slots[5..]) |slot| {
        const actual = (try repeated.next()).?;
        try testing.expectEqual(slot.time, actual.time);
        try testing.expectEqual(&timetable.departures[slot.departure], actual.departure);
    }
    try testing.expectEqual(null, try repeated.next());

    const start = timetable.metadata.start_day;
    try testing.expect(try timetable.scheduleActive(0, start - 4, .sunday));
    try testing.expect(try timetable.scheduleActive(0, start, .sunday));
    try testing.expect(!try timetable.scheduleActive(0, start + 63, .monday));
    try testing.expect(try timetable.scheduleActive(0, start + 64, .sunday));
    try testing.expect(!try timetable.scheduleActive(0, start + 69, .monday));
    try testing.expect(try timetable.scheduleActive(0, start + 99, .sunday));
    try testing.expect(try timetable.scheduleActive(0, start + 100, .monday));
    try testing.expect(!try timetable.scheduleActive(0, start + 100, .sunday));
    try testing.expectError(error.InvalidTransitSchedule, timetable.scheduleActive(1, start, .sunday));
}

test "transit groups require all sections, a supported version and valid checksums" {
    const fixture = try Fixture.createWithTransit(true);
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path = fixture.path(&buf);
    var diagnostic: reader.Diagnostic = .{};
    const metadata = try fixture.section(.transit_metadata);
    defer metadata.close();
    try metadata.pwriteAll(&.{2}, format.payload_offset);
    try testing.expectError(error.UnsupportedTransitVersion, reader.Bundle.openDescribed(path, &diagnostic));
    try testing.expectEqual(.transit_metadata, diagnostic.section.?);
    try metadata.pwriteAll(&.{1}, format.payload_offset);

    const transfers = try fixture.section(.transit_transfers);
    defer transfers.close();
    try transfers.pwriteAll(&.{2}, format.payload_offset);
    try testing.expectError(error.PayloadHashMismatch, reader.Bundle.openVerified(path, .none, &diagnostic));
    try testing.expectEqual(.transit_transfers, diagnostic.section.?);

    const dir = try fixture.root.child("bundle");
    defer dir.close();
    try dir.deleteFile(format.SectionKind.transit_occurrences.filename());
    try testing.expectError(error.MissingSection, reader.Bundle.openDescribed(path, &diagnostic));
    try testing.expectEqual(.transit_occurrences, diagnostic.section.?);
}

test "edge key indexes map both directions and validate optional sections together" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path = fixture.path(&buf);
    var diagnostic: reader.Diagnostic = .{};
    {
        var bundle = try reader.Bundle.openVerified(path, .none, &diagnostic);
        defer bundle.close();
        const index = bundle.view.edge_key_index.?;
        try testing.expect(index.hash != null);
        for (sample.records(.edge_keys)) |row| {
            const id: format.EdgeId = @fromBackingInt(row.edge);
            try testing.expectEqualDeep(row.key, try index.key(id));
            try testing.expectEqual(@as(?format.EdgeId, id), try index.find(row.key));
        }
    }
    {
        const slots = try fixture.section(.edge_key_hash_slots);
        defer slots.close();
        var header = sample.header(.edge_key_hash_slots);
        const corrupt = std.mem.sliceAsBytes(&[_]u32{ std.math.maxInt(u32), 1 });
        header.payload_hash = std.hash.XxHash3.hash(0, corrupt);
        try slots.pwriteAll(std.mem.asBytes(&header), 0);
        try slots.pwriteAll(corrupt, format.payload_offset);
        try testing.expectError(error.InvalidEdgeKeyHash, reader.Bundle.openVerified(path, .none, &diagnostic));
    }
    const directory = try fixture.root.child("bundle");
    defer directory.close();
    try directory.deleteFile(format.SectionKind.edge_key_hash_slots.filename());
    try testing.expectError(error.MissingSection, reader.Bundle.openDescribed(path, &diagnostic));
    try testing.expectEqual(.edge_key_hash_slots, diagnostic.section.?);
    try directory.deleteFile(format.SectionKind.edge_key_hash_header.filename());
    try directory.deleteFile(format.SectionKind.edge_key_hash_buckets.filename());
    {
        var bundle = try reader.Bundle.openVerified(path, .none, null);
        defer bundle.close();
        const index = bundle.view.edge_key_index.?;
        try testing.expectEqual(null, index.hash);
        try testing.expectEqual(@as(?format.EdgeId, @fromBackingInt(1)), try index.find(sample.records(.edge_keys)[1].key));
    }
    try directory.deleteFile(format.SectionKind.edge_key_inverse.filename());
    try testing.expectError(error.MissingSection, reader.Bundle.openDescribed(path, &diagnostic));
    try testing.expectEqual(.edge_key_inverse, diagnostic.section.?);
    try directory.deleteFile(format.SectionKind.edge_keys.filename());
    var legacy = try reader.Bundle.openVerified(path, .none, null);
    defer legacy.close();
    try testing.expectEqual(null, legacy.view.edge_key_index);
}

test "mapped live traffic updates reach existing graph readers and expire" {
    const live = routing.traffic.live;
    const speed = routing.graph.speed;
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path = fixture.path(&buf);
    const dir = try fixture.root.child("bundle");
    defer dir.close();
    var base = try reader.Bundle.open(path);
    defer base.close();
    try testing.expectEqual(null, base.view.live_traffic);
    const graph = try base.view.liveTrafficGraph();
    var written = try live.Writer.create(dir, graph, .none);
    defer written.close();
    defer dir.deleteFile(live.filename) catch {};
    try testing.expectError(error.LiveTrafficWriterBusy, live.Writer.open(dir, graph, .none));
    try testing.expectError(error.PathAlreadyExists, live.Writer.create(dir, graph, .none));
    var bundle = try reader.Bundle.open(path);
    defer bundle.close();
    const view = &bundle.view;
    const id: format.EdgeId = @fromBackingInt(0);
    const query: speed.Query = .{ .time = .{ .seconds_of_week = 0 } };
    const original = speed.resolve(edges[0], id, query, base.view.speedOverlays(200, live.default_max_age_seconds));
    try testing.expectEqual(50, original.kph);
    try testing.expectEqual(original, speed.resolve(edges[0], id, query, view.speedOverlays(200, live.default_max_age_seconds)));
    const record: live.Record = .{ .overall = 49, .speed1 = 49, .breakpoint1 = 255 };
    const metadata = try written.update(&.{.{ .edge = id, .record = record }}, 200, .none);
    try testing.expectEqual(live.Metadata{ .epoch = 1, .last_update = 200, .live_to_bound = 1 }, metadata);
    try testing.expectEqual(metadata, view.live_traffic.?.metadata().?);
    try testing.expectEqual(record, view.live_traffic.?.record(id).?);
    const resolved = speed.resolve(edges[0], id, query, view.speedOverlays(200, live.default_max_age_seconds));
    try testing.expectEqual(speed.Result{ .kph = 98, .sources = .{ .current = true } }, resolved);
    try testing.expectEqual(original, speed.resolve(edges[0], id, query, view.speedOverlays(501, live.default_max_age_seconds)));
    try testing.expectEqual(original, speed.resolve(edges[0], id, query, view.speedOverlays(199, live.default_max_age_seconds)));
    try testing.expectError(error.EdgeNotDrivable, written.update(&.{
        .{ .edge = id, .record = .unknown },
        .{ .edge = @fromBackingInt(2), .record = record },
    }, 201, .none));
    try testing.expectEqual(record, view.live_traffic.?.record(id).?);
    try testing.expectEqual(metadata, view.live_traffic.?.metadata().?);
    const closure: live.Record = .{ .overall = 0, .speed1 = 0, .breakpoint1 = 255 };
    _ = try written.update(&.{.{ .edge = id, .record = closure }}, 201, .none);
    try testing.expect(speed.resolve(edges[0], id, query, view.speedOverlays(201, live.default_max_age_seconds)).closed);
    try testing.expectEqual(original, speed.resolve(edges[0], id, query, view.speedOverlays(502, live.default_max_age_seconds)));
}

test "loading a graph rejects a traffic overlay for another dataset" {
    const live = routing.traffic.live;
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path = fixture.path(&buf);
    const dir = try fixture.root.child("bundle");
    defer dir.close();
    var bundle = try reader.Bundle.open(path);
    defer bundle.close();
    var graph = try bundle.view.liveTrafficGraph();
    graph.uuid[0] ^= 1;
    const writer = try live.Writer.create(dir, graph, .none);
    writer.close();
    defer dir.deleteFile(live.filename) catch {};
    try testing.expectError(error.LiveTrafficDatasetUuidMismatch, reader.Bundle.open(path));
}

test "traffic feed applies keys and preserves individual expiry across reopen" {
    const live = routing.traffic.live;
    const feed = routing.traffic.feed;
    const a = testing.allocator;
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path = fixture.path(&buf);
    const dir = try fixture.root.child("bundle");
    defer dir.close();
    defer dir.deleteFile(live.filename) catch {};
    defer dir.deleteFile("traffic-expiry.bin") catch {};
    var base = try reader.Bundle.open(path);
    defer base.close();
    const graph = try base.view.liveTrafficGraph();
    const index = base.view.edge_key_index.?;
    var writer = try feed.Feeder.open(a, dir, graph, index, 100, .none);
    {
        defer writer.close();
        const report = try writer.apply(a,
            \\edge_key,speed
            \\"12,42,43,forward",98
            \\"12,43,42,reverse",0
            \\"999,42,43,forward",88
            \\"999,42,43,forward",86
            \\"12,43,42,reverse",253
            \\incomplete
        , .csv, 1000, .none);
        defer report.deinit(a);
        try testing.expectEqual(6, report.rows);
        try testing.expectEqual(2, report.applied);
        try testing.expectEqual(2, report.unknown);
        try testing.expectEqual(1, report.unknown_keys.len);
        try testing.expectEqual(999, report.unknown_keys[0].way_id);
        try testing.expectEqual(1, report.out_of_range);
        try testing.expectEqual(1, report.invalid_rows);
        try testing.expectEqual(1, report.metadata.?.epoch);

        var opened = try reader.Bundle.open(path);
        defer opened.close();
        const overlay = opened.view.live_traffic.?;
        try testing.expectEqual(98, overlay.record(@fromBackingInt(0)).?.overallKph());
        try testing.expect(overlay.record(@fromBackingInt(1)).?.closed());
        const next = try writer.apply(a,
            \\{"edge_key":"12,42,43,forward","speed":60,"speed1":44,"speed2":22,"speed3":38,"breakpoint1":128,"breakpoint2":220,"congestion3":8,"observed_at":1040}
            \\{"edge_key":"12,43,42,reverse","speed":80,"observed_at":995}
        , .jsonl, 1050, .none);
        defer next.deinit(a);
        try testing.expectEqual(1, next.applied);
        try testing.expectEqual(1, next.older_observations);
        try testing.expectEqual(2, next.metadata.?.epoch);
        try testing.expectEqual(38, overlay.record(@fromBackingInt(0)).?.subsegmentKph(.third));
        try testing.expectEqual(8, overlay.record(@fromBackingInt(0)).?.congestion3);
        try testing.expect(overlay.record(@fromBackingInt(1)).?.closed());
    }
    var restarted = try feed.Feeder.open(a, dir, graph, index, 100, .none);
    defer restarted.close();
    try testing.expectEqual(0, try restarted.expire(1100, .none));
    try testing.expectEqual(1, try restarted.expire(1101, .none));
    try testing.expectEqual(live.Record.unknown, restarted.writer.view.record(@fromBackingInt(1)).?);
    try testing.expectEqual(60, restarted.writer.view.record(@fromBackingInt(0)).?.overallKph());
    try testing.expectEqual(1, try restarted.expire(1141, .none));
    try testing.expectEqual(live.Record.unknown, restarted.writer.view.record(@fromBackingInt(0)).?);
    try testing.expectEqual(4, restarted.writer.view.metadata().?.epoch);
}

test "timetable references can exceed Valhalla's twelve-bit indices" {
    const fixture = try Fixture.createWithTransit(true);
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    var bundle = try reader.Bundle.open(fixture.path(&buf));
    defer bundle.close();
    var timetable = bundle.view.transit_index.?;
    const wide_id = 4096;

    const routes = try testing.allocator.alloc(transit.Route, wide_id + 1);
    defer testing.allocator.free(routes);
    @memset(routes, timetable.routes[0]);
    timetable.routes = routes;
    const schedules = try testing.allocator.alloc(transit.Schedule, wide_id + 1);
    defer testing.allocator.free(schedules);
    @memset(schedules, timetable.schedules[0]);
    timetable.schedules = schedules;

    var lines = sample.records(.transit_lines)[0..2].*;
    var timetable_records = sample.records(.transit_departures)[0..5].*;
    lines[1].route = wide_id;
    timetable_records[4].route = wide_id;
    timetable_records[4].schedule = wide_id;
    timetable.lines = &lines;
    timetable.departures = &timetable_records;
    try timetable.verify(bundle.view.nodes.len, .none);
    const next = (try timetable.nextDeparture(1, 90062)).?;
    try testing.expectEqual(wide_id, next.departure.route);
    try testing.expectEqual(wide_id, next.departure.schedule);
    try testing.expect(try timetable.scheduleActive(next.departure.schedule, timetable.metadata.start_day + 64, .sunday));
}

test "timezone sections are optional together" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const dir = try fixture.root.child("bundle");
    defer dir.close();
    try dir.deleteFile(format.SectionKind.timezone_rules.filename());
    try testing.expectError(error.InvalidNodeTimezoneCount, reader.Bundle.open(fixture.path(&buf)));
    try dir.deleteFile(format.SectionKind.node_timezones.filename());
    var bundle = try reader.Bundle.open(fixture.path(&buf));
    defer bundle.close();
    try testing.expectEqual(@as(routing.graph.timezone.Id, 0), try bundle.view.nodeTimezone(@fromBackingInt(0)));
}

test "speed bounds reject invalid values and support bundles built before the section" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path = fixture.path(&buf);
    const first: format.EdgeId = @fromBackingInt(0);
    const overlay_limit = routing.graph.speed.max_traffic_kph;
    {
        var bundle = try reader.Bundle.open(path);
        defer bundle.close();
        try testing.expectEqual(overlay_limit, try bundle.view.lbSpeed(first));
        try testing.expectError(error.InvalidEdgeId, bundle.view.lbSpeed(@fromBackingInt(2)));
    }
    const file = try fixture.section(.lb_speeds);
    defer file.close();
    try file.pwriteAll(&.{overlay_limit - 1}, format.payload_offset);
    try testing.expectError(error.InvalidSpeedBound, reader.Bundle.open(path));
    const dir = try fixture.root.child("bundle");
    defer dir.close();
    try dir.deleteFile(format.SectionKind.lb_speeds.filename());
    var older = try reader.Bundle.open(path);
    defer older.close();
    try testing.expectEqual(overlay_limit, try older.view.lbSpeed(first));
}

test "cold sections are optional as a pair and reject unsafe indexes and offsets" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path_name = fixture.path(&buf);
    const index = try fixture.section(.cold_idx);
    defer index.close();
    const data = try fixture.section(.cold);
    defer data.close();
    const first: format.EdgeId = @fromBackingInt(@as(u32, 0));
    try index.pwriteAll(&.{ 0xff, 0xff, 0xff, 0xff }, format.payload_offset);
    {
        var bundle = try reader.Bundle.open(path_name);
        defer bundle.close();
        try testing.expectError(error.InvalidColdIndex, bundle.view.wayId(first));
    }
    try index.pwriteAll(&.{ 0, 0, 0, 0 }, format.payload_offset);
    // The first record offset follows the cold header and two chunk entries.
    try data.pwriteAll(&.{1}, format.payload_offset + 32);
    {
        var bundle = try reader.Bundle.open(path_name);
        defer bundle.close();
        try testing.expectError(error.InvalidColdChunk, bundle.view.shape(first, testing.allocator));
    }
    const dir = try fixture.root.child("bundle");
    defer dir.close();
    try dir.deleteFile(format.SectionKind.cold.filename());
    try testing.expectError(error.MissingSection, reader.Bundle.open(path_name));
    try dir.deleteFile(format.SectionKind.cold_idx.filename());
    try dir.deleteFile(format.SectionKind.signs.filename());
    var bundle = try reader.Bundle.open(path_name);
    defer bundle.close();
    try testing.expectError(error.MissingColdData, bundle.view.wayId(first));
}

test "reader rejects wrong magic, version, section kind, mixed UUIDs and sizes" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path_name = fixture.path(&buf);
    const file = try fixture.section(.edges);
    defer file.close();
    const good = sample.header(.edges);

    const mutations = [_]struct { off: usize, data: []const u8, failure: anyerror }{
        .{ .off = @offsetOf(format.SectionHeader, "magic_tag"), .data = "X", .failure = error.InvalidMagic },
        .{ .off = @offsetOf(format.SectionHeader, "format_version"), .data = "\x02", .failure = error.UnsupportedFormatVersion },
        .{ .off = @offsetOf(format.SectionHeader, "kind"), .data = "\x01", .failure = error.InvalidSectionKind },
        .{ .off = @offsetOf(format.SectionHeader, "dataset_uuid"), .data = "\xff", .failure = error.DatasetUuidMismatch },
        .{ .off = @offsetOf(format.SectionHeader, "record_size"), .data = "\x08", .failure = error.InvalidRecordSize },
        .{ .off = @offsetOf(format.SectionHeader, "reserved"), .data = "\x01", .failure = error.InvalidReservedBytes },
        .{ .off = @offsetOf(format.SectionHeader, "count"), .data = &@as([8]u8, @splat(0xff)), .failure = error.SectionSizeOverflow },
    };
    for (mutations) |mutation| {
        try file.pwriteAll(mutation.data, mutation.off);
        var diagnostic: reader.Diagnostic = .{};
        try testing.expectError(mutation.failure, reader.Bundle.openDescribed(path_name, &diagnostic));
        try testing.expectEqual(@as(?format.SectionKind, .edges), diagnostic.section);
        try file.pwriteAll(std.mem.asBytes(&good), 0);
    }
    const size = try file.size();
    try file.truncate(size + 1);
    try testing.expectError(error.TrailingSectionData, reader.Bundle.open(path_name));
    try file.truncate(size - 1);
    try testing.expectError(error.TruncatedSection, reader.Bundle.open(path_name));
    try file.truncate(8);
    try testing.expectError(error.TruncatedHeader, reader.Bundle.open(path_name));
}

test "startup skips hashing while accessors safely reject corrupt payloads" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path_name = fixture.path(&buf);

    const offsets = try fixture.section(.first_edge);
    defer offsets.close();
    try offsets.pwriteAll(&.{ 1, 0, 0, 0 }, format.payload_offset);
    try testing.expectError(error.InvalidCsrEndpoints, reader.Bundle.open(path_name));
    try offsets.pwriteAll(std.mem.sliceAsBytes(sample.records(.first_edge)), format.payload_offset);
    try offsets.pwriteAll(&.{ 0xff, 0xff, 0xff, 0xff }, format.payload_offset + @sizeOf(u32));
    {
        var bundle = try reader.Bundle.open(path_name);
        defer bundle.close();
        var diagnostic: reader.Diagnostic = .{};
        try testing.expectError(error.PayloadHashMismatch, reader.Bundle.openVerified(path_name, .none, &diagnostic));
        try testing.expectEqual(@as(?format.SectionKind, .first_edge), diagnostic.section);
        try testing.expectError(error.PayloadHashMismatch, bundle.view.verify(.none, &diagnostic));
        try testing.expectEqual(@as(?format.SectionKind, .first_edge), diagnostic.section);
        try testing.expectError(error.InvalidCsrRange, bundle.view.outEdges(@fromBackingInt(@intCast(0))));
        try testing.expectError(error.InvalidCsrRange, bundle.view.oppEdge(@fromBackingInt(@intCast(1))));
    }
    try offsets.pwriteAll(std.mem.sliceAsBytes(sample.records(.first_edge)), format.payload_offset);
    const node_file = try fixture.section(.nodes);
    defer node_file.close();
    try node_file.pwriteAll(&.{ 0xff, 0xff, 0xff, 0xff }, format.payload_offset);
    const edge_file = try fixture.section(.edges);
    defer edge_file.close();
    var bad = edges[0];
    bad.cls.opp_local = 31;
    try edge_file.pwriteAll(std.mem.asBytes(&bad), format.payload_offset);
    const class_file = try fixture.section(.classes);
    defer class_file.close();
    try class_file.pwriteAll(&.{0xff}, format.payload_offset);
    const coordinate_file = try fixture.section(.coordinates);
    defer coordinate_file.close();
    try coordinate_file.pwriteAll(&.{ 0, 0, 0, 0x80 }, format.payload_offset);

    var bundle = try reader.Bundle.open(path_name);
    defer bundle.close();
    try testing.expectError(error.InvalidTurnOffset, bundle.view.turnRow(@fromBackingInt(@intCast(0)), 0));
    try testing.expectError(error.InvalidOpposingEdge, bundle.view.oppEdge(@fromBackingInt(@intCast(0))));
    try testing.expectError(error.InvalidEdgeClass, bundle.view.class(0));
    try testing.expectError(error.InvalidCoordinate, bundle.view.coordinate(@fromBackingInt(0)));
}

const range_cache = routing.graph.range_cache;
const range_manifest = routing.graph.range_manifest;
const range_http = routing.graph.range_http;
const http = routing.server.http;

const RangeServer = struct {
    bundle: *const reader.Bundle,
    calls: std.atomic.Value(u32) = .init(0),
    corrupt_edge: std.atomic.Value(bool) = .init(true),
    stall: std.atomic.Value(bool) = .init(false),

    fn handle(context: *anyopaque, _: *http.Ctx, req: *const http.Request, res: *http.Response) void {
        const self: *RangeServer = @ptrCast(@alignCast(context));
        self.reply(req, res) catch {
            res.status = 400;
            res.body.clearRetainingCapacity();
            res.extra_headers.clearRetainingCapacity();
        };
    }

    fn reply(self: *RangeServer, req: *const http.Request, res: *http.Response) !void {
        if (req.method != .GET) return error.InvalidMethod;
        const path = std.fs.path.basename(req.path);
        const kind = for (std.enums.values(format.SectionKind)) |kind| {
            if (std.mem.eql(u8, kind.filename(), path)) break kind;
        } else return error.MissingSection;
        const bytes = self.bundle.mappings.get(kind).bytes;
        const range = req.header("range") orelse return error.MissingRange;
        if (!std.mem.startsWith(u8, range, "bytes=")) return error.InvalidRange;
        const separator = std.mem.indexOfScalar(u8, range, '-') orelse return error.InvalidRange;
        const start = try std.fmt.parseUnsigned(usize, range[6..separator], 10);
        const end = try std.fmt.parseUnsigned(usize, range[separator + 1 ..], 10);
        if (start > end or end >= bytes.len) return error.InvalidRange;
        _ = self.calls.fetchAdd(1, .monotonic);
        if (self.stall.load(.acquire)) io.sleepMs(150);
        res.status = 206;
        res.content_type = "application/octet-stream";
        const header = try std.fmt.allocPrint(res.gpa, "Content-Range: bytes {d}-{d}/{d}", .{ start, end, bytes.len });
        try res.addHeader(header);
        try res.writeBody(bytes[start .. end + 1]);
        if (kind == .edges and self.corrupt_edge.swap(false, .acq_rel)) {
            io.sleepMs(10);
            res.body.items[0] ^= 1;
        }
    }
};

const ReadRange = struct {
    cache: *const range_cache.Cache,
    range: range_cache.Range,
    result: anyerror![]const u8 = undefined,

    fn run(self: *ReadRange) void {
        self.result = self.cache.read(self.range, .fromNowMs(2000));
    }
};

fn removeRangeCache(root: io.Directory, key: [:0]const u8) void {
    const cache = root.child(key) catch return;
    for (std.enums.values(format.SectionKind)) |kind| {
        cache.deleteFile(kind.filename()) catch {};
        var name_buf: [64]u8 = undefined;
        const bitmap = std.fmt.bufPrintSentinel(&name_buf, "{s}.fill", .{kind.filename()}, 0) catch unreachable;
        cache.deleteFile(bitmap) catch {};
    }
    cache.close();
    root.deleteDir(key) catch {};
}

test "HTTP range cache shares a verified retry, bounds stalled transfers and recovers across restarts" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    const original = try fixture.root.child("bundle");
    defer original.close();
    var bundle = try reader.Bundle.openInDir(original, null);
    defer bundle.close();
    const bytes = try range_manifest.encode(testing.allocator, &bundle, .none);
    defer testing.allocator.free(bytes);

    // The cache directory begins empty. Cleanup removes the one known
    // content-addressed child and the section files created for this test.
    const parent = try fixture.root.createChild("range-cache");
    defer fixture.root.deleteDir("range-cache") catch {};
    defer parent.close();
    var name: [65]u8 = @splat(0);
    name[0..64].* = std.fmt.bytesToHex(range_manifest.digest(bytes), .lower);
    defer removeRangeCache(parent, name[0..64 :0]);

    var handler: RangeServer = .{ .bundle = &bundle };
    var server = http.Server.init(testing.allocator, .{ .address = .loopback_any_port, .threads = 1 }, .{ .context = &handler, .handle = RangeServer.handle });
    try server.start();
    defer server.stop();
    var url_buf: [80]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/bundle", .{server.port});
    var origin = try range_http.Origin.open(testing.allocator, url);
    defer origin.close(testing.allocator);
    const extent: range_cache.Range = .{ .kind = .edges, .offset = format.payload_offset + 7, .len = 16 };
    {
        var cache = try range_cache.Cache.open(testing.allocator, parent, bytes, origin.source(), .{}, .none);
        defer cache.close();
        var first: ReadRange = .{ .cache = &cache, .range = extent };
        var second: ReadRange = first;
        const t1 = try std.Thread.spawn(.{}, ReadRange.run, .{&first});
        const t2 = std.Thread.spawn(.{}, ReadRange.run, .{&second}) catch |err| {
            t1.join();
            return err;
        };
        t1.join();
        t2.join();
        const expected = bundle.mappings.get(.edges).bytes[extent.offset..][0..extent.len];
        try testing.expectEqualSlices(u8, expected, try first.result);
        try testing.expectEqualSlices(u8, expected, try second.result);
        try testing.expectEqual(@as(u32, 2), handler.calls.load(.acquire));

        handler.stall.store(true, .release);
        const timer = io.Timer.start();
        try testing.expectError(error.DeadlineExceeded, cache.read(.{ .kind = .nodes, .offset = 0, .len = 1 }, .fromNowMs(25)));
        try testing.expect(timer.read() < std.time.ns_per_s);
        handler.stall.store(false, .release);

        const recent = [_]range_cache.Range{.{ .kind = .cold, .offset = format.payload_offset, .len = 4 }};
        try cache.fill(&recent, .fromNowMs(4000));
        var restored = try reader.Bundle.openInDir(cache.dir, null);
        defer restored.close();
        try restored.view.verify(.none, null);
        for (std.enums.values(format.SectionKind)) |kind| {
            try testing.expectEqualSlices(u8, bundle.mappings.get(kind).bytes, restored.mappings.get(kind).bytes);
        }
        try testing.expectEqual(1234, (try restored.view.edge(@fromBackingInt(@as(u32, 0)))).geom.len_m);
    }

    // Keep the persisted fill bit and damage its covering bytes. Reopening
    // must verify the remembered extent, fetch it again and repair the file.
    {
        const cache = try parent.child(name[0..64 :0]);
        defer cache.close();
        const file = try cache.openOrCreateFile(format.SectionKind.edges.filename());
        defer file.close();
        const expected = bundle.mappings.get(.edges).bytes[extent.offset];
        try file.pwriteAll(&.{expected ^ 1}, extent.offset);
    }
    const calls = handler.calls.load(.acquire);
    var cache = try range_cache.Cache.open(testing.allocator, parent, bytes, origin.source(), .{}, .none);
    defer cache.close();
    try cache.fill(&.{}, .fromNowMs(3000));
    try testing.expectEqual(calls + 1, handler.calls.load(.acquire));
}
