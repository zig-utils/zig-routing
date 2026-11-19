const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const build = routing.build;
const graph = routing.graph;
const dem = routing.elevation;
const geo = routing.geo;
const open_budget_ns = 50 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const input = args.next() orelse return usage();
    const output = args.next() orelse return usage();
    const scratch = args.next() orelse return usage();
    const workers = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 0;
    const drive_side = if (args.next()) |text|
        std.meta.stringToEnum(build.edge_class.DriveSide, text) orelse return usage()
    else
        .right;
    var require_sub_byte_turns = false;
    var require_spatial_budget = false;
    var dem_dir: ?[]const u8 = null;
    var pack: ?dem.@"packed".Pack = null;
    defer if (pack) |*present| present.close();
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--sub-byte-turns")) {
            require_sub_byte_turns = true;
        } else if (std.mem.eql(u8, flag, "--spatial-budget")) {
            require_spatial_budget = true;
        } else if (std.mem.eql(u8, flag, "--dem") and dem_dir == null and pack == null) {
            dem_dir = args.next() orelse return usage();
        } else if (std.mem.eql(u8, flag, "--dem-pack") and dem_dir == null and pack == null) {
            pack = try dem.@"packed".Pack.open(args.next() orelse return usage());
        } else return usage();
    }
    const dem_source: ?build.elevation.Source = if (pack) |*present|
        .{ .pack = present }
    else if (dem_dir) |dir|
        .{ .tiles = dir }
    else
        null;

    const file = try io.File.open(input, .read_only);
    defer file.close();
    const uuid = try datasetId(file, drive_side, dem_source != null);
    var writer = try graph.format.BundleWriter.init(output, uuid, .none);
    defer writer.deinit();

    const timer = io.Timer.start();
    const stats = try build.assemble.build(init.gpa, try build.pbf.file.Stream.init(file), &writer, .{
        .scratch_dir = scratch,
        .drive_side = drive_side,
        .workers = workers,
        .dem_source = dem_source,
    });
    try writer.commit();
    const elapsed_ns = timer.read();
    {
        var warm = try graph.reader.Bundle.open(output);
        defer warm.close();
        try warm.view.verify(.none, null);
        try build.assemble.validate(warm.view.first_edge, warm.view.edges, warm.view.coordinates.?, warm.view.classes.?, .none);
        try validateTurns(&warm.view, stats.turn_pool_bytes);
        try validateCold(init.gpa, &warm.view, stats.cold_records, stats.cold_payload_bytes);
        try validateSpatial(&warm.view, stats.spatial);
        try validateElevation(&warm.view, stats.elevation);
        try validateEnhancement(&warm.view, drive_side);
    }

    var times: [32]u64 = undefined;
    for (&times) |*sample| {
        const start = io.Timer.start();
        var bundle = try graph.reader.Bundle.open(output);
        sample.* = start.read();
        bundle.close();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));

    var buf: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buf);
    const cold_bytes = stats.cold_payload_bytes + @as(u64, stats.directed_edges) * @sizeOf(u32);
    try std.json.Stringify.value(.{
        .stats = stats,
        .elapsed_ns = elapsed_ns,
        .edges_per_second = rate(stats.directed_edges, stats.assembly_ns),
        .turn_bytes_per_node = @as(f64, @floatFromInt(stats.turn_pool_bytes)) / @as(f64, @floatFromInt(@max(stats.nodes, 1))),
        .cold_bytes_per_directed_edge = @as(f64, @floatFromInt(cold_bytes)) / @as(f64, @floatFromInt(@max(stats.directed_edges, 1))),
        .spatial_bytes_per_undirected_edge = @as(f64, @floatFromInt(stats.spatial.payload_bytes)) / @as(f64, @floatFromInt(@max(stats.cold_records, 1))),
        .peak_rss_bytes = try io.peakRssBytes(),
        .warm_open_median_ns = times[times.len / 2],
        .warm_open_max_ns = times[times.len - 1],
        .validation_errors = @as(u32, 0),
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    if (times[times.len - 1] >= open_budget_ns) return error.BundleOpenTooSlow;
    if (require_sub_byte_turns and stats.turn_pool_bytes >= stats.nodes) return error.TurnPoolTooLarge;
    if (require_spatial_budget and stats.spatial.payload_bytes > 3 * @as(u64, stats.cold_records)) return error.SpatialBudgetExceeded;
}

fn validateTurns(view: *const graph.reader.View, expected_bytes: usize) !void {
    if (view.turns.len != expected_bytes) return error.TurnPoolSizeMismatch;
    for (0..view.nodes.len) |i| {
        const node: graph.format.NodeId = @fromBackingInt(@as(u32, @intCast(i)));
        const degree = (try view.outEdgeRange(node)).count();
        for (0..degree) |local| {
            const row = try view.turnRow(node, @intCast(local));
            for (row) |entry| {
                if (entry & 0x80 != 0) return error.UnexpectedTurnRestriction;
            }
        }
    }
}

fn validateCold(allocator: std.mem.Allocator, view: *const graph.reader.View, records: u32, payload_bytes: u64) !void {
    const table = view.cold_data orelse return error.MissingColdData;
    const spatial = view.spatial_index orelse return error.MissingSpatialIndex;
    if (table.header.record_count != records or table.bytes.len != payload_bytes) return error.ColdSizeMismatch;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    for (0..view.nodes.len) |i| {
        const node: graph.format.NodeId = @fromBackingInt(@as(u32, @intCast(i)));
        const range = try view.outEdgeRange(node);
        for (range.first..range.end) |j| {
            const id: graph.format.EdgeId = @fromBackingInt(@as(u32, @intCast(j)));
            const opposite = @backingInt(try view.oppEdge(id));
            const indexes = view.cold_idx.?;
            if (indexes[j] ^ indexes[opposite] != graph.cold.directedIndex(0, true)) return error.ColdOpposingIndexMismatch;
            if (j > opposite) continue;
            const points = try view.shape(id, arena.allocator());
            const head: graph.format.NodeId = @fromBackingInt((try view.edge(id)).head);
            if (!std.meta.eql(points[0], try view.coordinate(node)) or
                !std.meta.eql(points[points.len - 1], try view.coordinate(head))) return error.ColdShapeEndpointMismatch;
            try validateSpatialPoint(spatial, points[0].toPoint(), id);
            for (points[0 .. points.len - 1], points[1..]) |previous, point| {
                const a = previous.toPoint();
                const b = point.toPoint();
                var lng = b.lng - a.lng;
                if (lng > 180) lng -= 360;
                if (lng < -180) lng += 360;
                const midpoint: geo.PointLL = .{ .lng = @mod(a.lng + lng / 2 + 180, 360) - 180, .lat = (a.lat + b.lat) / 2 };
                try validateSpatialPoint(spatial, midpoint, id);
                try validateSpatialPoint(spatial, b, id);
            }
            const names = try view.names(id);
            for (0..names.count()) |name| _ = try names.at(name);
            _ = arena.reset(.retain_capacity);
        }
    }
}

fn validateSpatialPoint(index: graph.spatial.View, point: geo.PointLL, representative: graph.format.EdgeId) !void {
    const cell = (try index.lookup(geo.grid.snapCell(point))) orelse return error.MissingShapeCell;
    var edges = cell.edges();
    while (try edges.next()) |edge| {
        if (edge == representative) return;
        if (@backingInt(edge) > @backingInt(representative)) break;
    }
    return error.MissingSpatialEdge;
}

fn validateSpatial(view: *const graph.reader.View, stats: graph.spatial.Stats) !void {
    const index = view.spatial_index orelse return error.MissingSpatialIndex;
    if (view.spatial.?.len != stats.payload_bytes or index.directory.len != stats.cells) return error.SpatialSizeMismatch;
    var previous: ?u32 = null;
    for (0..index.directory.len) |i| {
        const cell = try index.at(i);
        if (previous) |last| if (cell.id <= last) return error.UnsortedSpatialCells;
        previous = cell.id;
        var edges = cell.edges();
        while (try edges.next()) |edge| {
            if (@backingInt(edge) >= @backingInt(try view.oppEdge(edge))) return error.NonCanonicalSpatialEdge;
        }
    }
}

fn validateElevation(view: *const graph.reader.View, coverage: build.elevation.Coverage) !void {
    if (coverage.dem_configured != (view.slopes != null)) return error.ElevationSectionMismatch;
    if (coverage.dem_configured and coverage.fully_covered + coverage.partially_covered + coverage.missing != coverage.total_edges)
        return error.InvalidElevationCoverage;
    for (view.edges, 0..) |edge, i| {
        const id: graph.format.EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
        const slopes = try view.edgeSlopes(id);
        if (!coverage.dem_configured and (edge.geom.grade != 6 or slopes.code != 0 or
            (try view.coldRecord(id)).meanElevation() != graph.cold.no_elevation)) return error.UnexpectedElevation;
    }
}

fn validateEnhancement(view: *const graph.reader.View, drive_side: build.edge_class.DriveSide) !void {
    for (view.nodes, 0..) |node, i| {
        if (node.attr.drive_on_left != (drive_side == .left)) return error.InvalidDrivingSide;
        const id: graph.format.NodeId = @fromBackingInt(@as(u32, @intCast(i)));
        for (try view.outEdges(id)) |edge| {
            const class = try view.class(edge.cls.class_id);
            const target = try view.node(@fromBackingInt(edge.head));
            if (class.category.density != (@as(u8, node.attr.density) + target.attr.density) / 2) return error.InvalidEdgeDensity;
            if (class.flags.node_connector) continue;
            if (class.flags.dead_end != (target.attr.intersection == .dead_end)) return error.InvalidDeadEnd;
            if (class.flags.not_thru and class.category.road_class <= @backingInt(graph.constants.RoadClass.tertiary)) return error.InvalidNotThru;
        }
    }
}

fn datasetId(file: io.File, side: build.edge_class.DriveSide, has_dem: bool) !graph.format.DatasetUuid {
    const mapped = try io.Mapping.mapFd(file, .read_only);
    defer mapped.unmap();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(@tagName(side));
    if (has_dem) hash.update("\x00elevation");
    hash.update(mapped.bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var id = digest[0..16].*;
    id[6] = (id[6] & 0x0f) | 0x80;
    id[8] = (id[8] & 0x3f) | 0x80;
    return id;
}

fn rate(count: u32, ns: u64) f64 {
    return @as(f64, @floatFromInt(count)) * std.time.ns_per_s / @as(f64, @floatFromInt(@max(ns, 1)));
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build check-assembly -- INPUT.osm.pbf OUTPUT_BUNDLE SCRATCH_DIR [WORKERS] [right|left] [--sub-byte-turns] [--spatial-budget] [--dem DIR | --dem-pack FILE]\n", .{});
    return error.InvalidArguments;
}
