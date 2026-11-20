//! Prepare transit timetable and topology inputs before graph ordering.
const std = @import("std");
const graph = @import("../graph/root.zig");
const geo = @import("../geo/point.zig");
const io = @import("../infra/io.zig");
const checkpoint = @import("checkpoint.zig");
const edges = @import("edges.zig");
const gtfs = @import("gtfs/root.zig");
const names = @import("tags/names.zig");
const calendar = @import("transit_calendar.zig");
const places = @import("transit_places.zig");
const timetable = @import("transit_timetable.zig");
const connections = @import("transit_connections.zig");
const links = @import("transit_links.zig");
const transfers = @import("transit_transfers.zig");
const Allocator = std.mem.Allocator;
const format = graph.format;
const transit = graph.transit;
const Access = graph.constants.AccessMask;

pub const Node = extern struct {
    id: i64,
    timezone: transit.Text,
    attr: packed struct(u32) {
        access: Access,
        kind: graph.constants.NodeType,
        reserved: u12 = 0,
    },
};

pub const Way = extern struct {
    id: i64,
    source_way_id: u64,
    access: packed struct(u32) { forward: Access, backward: Access },
    attr: packed struct(u32) { use: graph.constants.Use, reserved: u24 = 0 },
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Node) == 16 and @offsetOf(Node, "attr") == 12);
    std.debug.assert(@sizeOf(Way) == 24 and @offsetOf(Way, "access") == 16);
}

pub const Report = struct {
    platforms: u64 = 0,
    connected: u64 = 0,
    missing_coordinates: u64 = 0,
    no_pedestrian_street: u64 = 0,
    no_pathway_to_street: u64 = 0,
    one_way_only: u64 = 0,
    stations: u64 = 0,
    egresses: u64 = 0,
    disconnected_egresses: u64 = 0,
    street_links: u64 = 0,
    station_links: u64 = 0,
    missing_pathway_endpoints: u64 = 0,
    missing_transfer_endpoints: u64 = 0,
    legs_without_platform: u64 = 0,
    lines: u64 = 0,
    departures: u64 = 0,
};

pub const Layout = struct {
    node_base: i64,
    source: edges.Stats,
    report: Report,
};

const Files = struct {
    segments: io.File,
    shape_points: io.File,
    ways: std.ArrayList(Way) = .empty,
    next_way: i64,
    edges: u64,
    points: u64,

    fn append(self: *Files, a: Allocator, from: i64, to: i64, use: graph.constants.Use, source_way: u64, access: [2]Access, shape: []const geo.FixedLL, meters: f64) !void {
        if (self.edges >= std.math.maxInt(u32) / 2 or shape.len < 2) return error.TooManyTransitEdges;
        const count = std.math.cast(u32, shape.len) orelse return error.TooManyTransitShapePoints;
        const way_id = self.next_way;
        self.next_way = std.math.sub(i64, way_id, 1) catch return error.TooManyTransitIds;
        const segment: edges.Edge = .{
            .from = from,
            .to = to,
            .way_id = way_id,
            .shape_offset = self.points,
            .shape_count = count,
            .length_m = meters,
            .flags = .{},
        };
        try self.shape_points.pwriteAll(std.mem.sliceAsBytes(shape), self.points * @sizeOf(geo.FixedLL));
        try self.segments.pwriteAll(std.mem.asBytes(&segment), self.edges * @sizeOf(edges.Edge));
        try self.ways.append(a, .{
            .id = way_id,
            .source_way_id = source_way,
            .attr = .{ .use = use },
            .access = .{ .forward = access[0], .backward = access[1] },
        });
        self.edges += 1;
        self.points = std.math.add(u64, self.points, count) catch return error.TooManyTransitShapePoints;
    }
};

/// Street access and geometry come from the same segment source used by
/// assembly. Its shape method omits segments ineligible for walking.
pub fn prepare(
    gpa: Allocator,
    tx: *checkpoint.Transaction,
    scratch_dir: []const u8,
    feeds: []const gtfs.Feed,
    road_files: edges.Output,
    road: anytype,
    original: edges.Stats,
) !Layout {
    const deadline = tx.deadline;
    var memory: std.heap.ArenaAllocator = .init(gpa);
    defer memory.deinit();
    const a = memory.allocator();
    var strings: names.StringTable = .init(a);
    defer strings.deinit();
    const model = try places.compile(a, gpa, feeds, &strings, deadline);
    const calendars = try calendar.compile(a, feeds, deadline);
    const feed_ids = try a.alloc(timetable.FeedIds, feeds.len);
    for (model.feeds, feed_ids) |feed, *ids| {
        if (deadline.expired()) return error.DeadlineExceeded;
        ids.* = feed.timetable_ids;
    }
    const schedule = try timetable.compile(a, gpa, feeds, feed_ids, calendars, &strings, deadline);
    const paths = try links.compile(a, feeds, model, deadline);
    const transfer_rows = try transfers.compile(a, gpa, feeds, model, paths.paths, deadline);

    const segment_file = try tx.create(.segments);
    defer segment_file.close();
    const shapes_file = try tx.create(.shape_points);
    defer shapes_file.close();
    _ = try checkpoint.transfer(road_files.edges, segment_file, deadline);
    _ = try checkpoint.transfer(road_files.shapes, shapes_file, deadline);
    var min_node = road.min_node;
    var min_way = road.min_way;
    for (road.segments, 0..) |record, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        min_node = @min(min_node, record.from, record.to);
        min_way = @min(min_way, record.way_id);
    }
    const node_base = std.math.sub(i64, min_node, @intCast(model.nodes.len)) catch return error.TooManyTransitIds;
    var files: Files = .{
        .segments = segment_file,
        .shape_points = shapes_file,
        .edges = original.edges,
        .points = original.shape_points,
        .next_way = std.math.sub(i64, min_way, 1) catch return error.TooManyTransitIds,
    };
    const used = try a.alloc(bool, model.nodes.len);
    @memset(used, false);
    for (paths.paths) |path| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const from = model.place(model.nodes[path.from]).coordinate;
        const to = model.place(model.nodes[path.to]).coordinate;
        try files.append(a, node_base + path.from, node_base + path.to, path.use, 0, path.access, &.{ from, to }, path.meters);
        used[path.from] = true;
        used[path.to] = true;
    }
    const street_links = try attachStreets(gpa, a, tx, scratch_dir, &files, road, model, used, node_base);
    try segment_file.sync();
    try shapes_file.sync();
    var node_rows: std.ArrayList(Node) = .empty;
    for (model.nodes, used, 0..) |location, in_graph, i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (!in_graph) continue;
        const place = model.place(location);
        const kind: graph.constants.NodeType = switch (location) {
            .stop => .multi_use_transit_platform,
            .station => .transit_station,
            .egress => .transit_egress,
            .passage => .building_entrance,
        };
        try node_rows.append(a, .{
            .id = node_base + @as(u32, @intCast(i)),
            .timezone = place.timezone,
            .attr = .{ .kind = kind, .access = .{ .pedestrian = true, .bicycle = true, .wheelchair = place.flags.wheelchair_boarding } },
        });
    }
    try tx.writeArray(node_rows.items, .transit_nodes);
    try tx.writeArray(files.ways.items, .transit_ways);
    try writeStrings(tx, &strings);
    try tx.writeArray(&[_]transit.Metadata{.{ .start_day = calendars.start_day }}, .transit_metadata_rows);
    try tx.writeArray(model.stops, .transit_stops_rows);
    try tx.writeArray(model.stations, .transit_stations_rows);
    try tx.writeArray(model.egresses, .transit_egresses_rows);
    try tx.writeArray(model.routes, .transit_routes_rows);
    try tx.writeArray(schedule.lines, .transit_lines_rows);
    try tx.writeArray(schedule.departures, .transit_departures_rows);
    try tx.writeArray(schedule.occurrences, .transit_occurrences_rows);
    try tx.writeArray(calendars.schedules, .transit_schedules_rows);
    try tx.writeArray(calendars.days, .transit_days_rows);
    try tx.writeArray(calendars.exceptions, .transit_exceptions_rows);
    try tx.writeArray(transfer_rows.records, .transit_transfers_rows);
    var source = original;
    source.edges = files.edges;
    source.shape_points = files.points;
    source.nodes += node_rows.items.len;

    var report = try connectivity(a, model, paths.paths, street_links, deadline);
    report.legs_without_platform = schedule.missing_stop_legs;
    report.lines = schedule.lines.len;
    report.departures = schedule.departures.len;
    report.missing_pathway_endpoints = paths.missing_pathway_endpoints;
    report.missing_transfer_endpoints = transfer_rows.missing_endpoints;
    return .{ .node_base = node_base, .source = source, .report = report };
}

const StreetLinks = struct {
    inbound: []const u32,
    outbound: []const u32,
    count: u64,
    unmatched: u64,
};

fn attachStreets(gpa: Allocator, a: Allocator, tx: *checkpoint.Transaction, dir: []const u8, files: *Files, road: anytype, model: places.Places, used: []bool, node_base: i64) !StreetLinks {
    const deadline = tx.deadline;
    var inbound: std.ArrayList(u32) = .empty;
    var outbound: std.ArrayList(u32) = .empty;
    if (model.egresses.len == 0) return .{ .inbound = &.{}, .outbound = &.{}, .count = 0, .unmatched = 0 };
    var pairs: std.ArrayList(graph.spatial.Pair) = .empty;
    defer pairs.deinit(gpa);
    for (road.segments, 0..) |_, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const id: u32 = @intCast(i);
        const shape = (try road.shape(id)) orelse continue;
        try graph.spatial.addShape(gpa, &pairs, id, shape, deadline);
    }
    const scratch = try gpa.alloc(graph.spatial.Pair, pairs.items.len);
    defer gpa.free(scratch);
    const path = try std.fs.path.join(gpa, &.{ dir, &tx.name, "street-spatial" });
    defer gpa.free(path);
    var writer = try format.BundleWriter.init(path, tx.identity, deadline);
    defer writer.deinit();
    _ = try graph.spatial.write(gpa, pairs.items, scratch, dir, &writer, deadline);
    const file = try writer.staging.readFile(format.SectionKind.spatial.filename());
    defer file.close();
    const map = try io.Mapping.mapFd(file, .read_only);
    defer map.unmap();
    const index = try graph.spatial.View.parse(map.bytes[format.payload_offset..], @intCast(road.segments.len));
    var search: connections.Search = .{ .allocator = gpa };
    defer search.deinit();
    var shape: std.ArrayList(geo.FixedLL) = .empty;
    defer shape.deinit(gpa);
    var count: u64 = 0;
    var unmatched: u64 = 0;
    for (model.egresses) |*egress| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const entrance = &egress.place;
        const match = (try search.nearest(index, road, entrance.coordinate, deadline)) orelse {
            unmatched += 1;
            continue;
        };
        const physical = road.segments[match.id];
        const street_shape = (try road.shape(match.id)).?;
        const street_access = (try road.access(match.id)).?;
        const projected = match.projection.point.toFixed();
        const node = entrance.graph_node;
        var can_enter = false;
        var can_exit = false;
        for ([_]connections.Endpoint{ .from, .to }, [_]i64{ physical.from, physical.to }, 0..) |endpoint, roadside, i| {
            const outgoing = @intFromBool(i == 0);
            const stationary = std.meta.eql(projected, if (i == 0) street_shape[0] else street_shape[street_shape.len - 1]);
            const access = .{
                sidewalkAccess(street_access[i], street_access[outgoing], entrance.*, stationary),
                sidewalkAccess(street_access[outgoing], street_access[i], entrance.*, stationary),
            };
            if (!access[0].pedestrian and !access[1].pedestrian) continue;
            const meters = try connections.approachShape(gpa, &shape, street_shape, match.projection, entrance.coordinate, endpoint, deadline);
            try files.append(a, roadside, node_base + node, .transit_connection, @bitCast(physical.way_id), access, shape.items, meters);
            can_enter = can_enter or access[0].pedestrian;
            can_exit = can_exit or access[1].pedestrian;
            count += 1;
        }
        used[node] = can_enter or can_exit or used[node];
        if (can_enter) try inbound.append(a, node);
        if (can_exit) try outbound.append(a, node);
        egress.connecting_way = @bitCast(physical.way_id);
        egress.connecting_point = projected;
        egress.flags.has_connecting_way = true;
        egress.flags.has_connecting_point = true;
    }
    return .{ .inbound = inbound.items, .outbound = outbound.items, .count = count, .unmatched = unmatched };
}

fn sidewalkAccess(street: Access, opposite: Access, place: transit.Place, stationary: bool) Access {
    return .{
        .pedestrian = street.pedestrian or (stationary and opposite.pedestrian),
        .bicycle = street.bicycle or (stationary and opposite.bicycle),
        .wheelchair = place.flags.wheelchair_boarding and (street.wheelchair or (stationary and opposite.wheelchair)),
    };
}

fn connectivity(a: Allocator, model: places.Places, paths: []const links.Link, approaches: StreetLinks, deadline: io.Deadline) !Report {
    const forward = try links.Adjacency.init(a, paths, model.nodes.len, false, deadline);
    const reverse = try links.Adjacency.init(a, paths, model.nodes.len, true, deadline);
    const inbound = try a.alloc(u32, model.nodes.len);
    const outbound = try a.alloc(u32, model.nodes.len);
    @memset(inbound, 0);
    @memset(outbound, 0);
    var todo: std.ArrayList(u32) = .empty;
    try forward.mark(a, approaches.inbound, inbound, 1, &todo, deadline);
    try reverse.mark(a, approaches.outbound, outbound, 1, &todo, deadline);
    const station_has_street = try a.alloc(bool, model.stations.len);
    @memset(station_has_street, false);
    for (approaches.inbound) |node| {
        if (deadline.expired()) return error.DeadlineExceeded;
        station_has_street[model.stationOf(model.nodes[node])] = true;
    }
    for (approaches.outbound) |node| {
        if (deadline.expired()) return error.DeadlineExceeded;
        station_has_street[model.stationOf(model.nodes[node])] = true;
    }
    var result: Report = .{
        .platforms = model.stops.len + model.platforms_without_coordinates,
        .missing_coordinates = model.platforms_without_coordinates,
        .stations = model.stations.len,
        .egresses = model.egresses.len,
        .disconnected_egresses = approaches.unmatched,
        .station_links = paths.len,
        .street_links = approaches.count,
    };
    for (model.stops) |stop| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const node = stop.place.graph_node;
        if (inbound[node] != 0 and outbound[node] != 0) {
            result.connected += 1;
        } else if (inbound[node] != 0 or outbound[node] != 0) {
            result.one_way_only += 1;
        } else if (station_has_street[stop.station]) {
            result.no_pathway_to_street += 1;
        } else {
            result.no_pedestrian_street += 1;
        }
    }
    return result;
}

fn writeStrings(tx: *checkpoint.Transaction, strings: *const names.StringTable) !void {
    const file = try tx.create(.transit_strings);
    defer file.close();
    try strings.save(file, tx.deadline);
}
