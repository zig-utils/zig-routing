// Ported from src/loki/tile_action.cc (Valhalla 3.9.3).
const std = @import("std");
const attributes = @import("../api/attributes.zig");
const request = @import("../api/request.zig");
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const mvt = @import("mvt.zig");
const props = @import("graph_tile_attributes.zig");
const Allocator = std.mem.Allocator;
const Point = geo.PointLL;
const EdgeId = graph.format.EdgeId;
const NodeId = graph.format.NodeId;
const View = graph.reader.View;

const buffer = 128;
const clip_box = geo.AABB.init(-buffer, -buffer, mvt.extent + buffer, mvt.extent + buffer);
const earth_radius = 6_378_137.0;
const pi: f64 = std.math.pi;
const half_world = pi * earth_radius;
const tolerances = [_]f64{ 9781, 4891, 2445, 1223, 611, 306, 153, 76, 38, 19, 10, 5, 2, 1, 0.6, 0.3, 0.15 };

const Projection = struct {
    bounds: geo.AABB,
    west: f64,
    north: f64,
    pixel: f64,

    fn init(tile: request.Tile) Projection {
        const count: f64 = @floatFromInt(@as(u32, 1) << tile.z);
        const x: f64 = @floatFromInt(tile.x);
        const y: f64 = @floatFromInt(tile.y);
        const width = 2 * half_world / count;
        return .{
            .bounds = geo.AABB.init(x / count * 360 - 180, latitude(y + 1, count), (x + 1) / count * 360 - 180, latitude(y, count)),
            .west = -half_world + x * width,
            .north = half_world - y * width,
            .pixel = width / mvt.extent,
        };
    }

    fn latitude(y: f64, count: f64) f64 {
        return std.math.atan(std.math.sinh(pi * (1 - 2 * y / count))) * (180 / pi);
    }

    fn mercator(p: Point) Point {
        const lat = std.math.clamp(p.lat, -89.999999, 89.999999);
        return .{
            .lng = earth_radius * (p.lng * pi / 180),
            .lat = earth_radius * @log(@tan(pi / 4 + lat * pi / 360)),
        };
    }

    fn project(self: Projection, p: Point) Point {
        return .{
            .lng = @round((p.lng - self.west) / self.pixel),
            .lat = @round((self.north - p.lat) / self.pixel),
        };
    }

    fn point(p: Point) mvt.Point {
        return .{ .x = @intFromFloat(p.lng), .y = @intFromFloat(p.lat) };
    }
};

pub fn render(
    a: Allocator,
    view: *const View,
    tile: request.Tile,
    zoom: [8]u8,
    filters: attributes.Controller,
    generalize: f32,
    out: *std.ArrayList(u8),
    deadline: Deadline,
) !void {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (tile.z < zoom[0] or (tile.exclude_nodes and tile.exclude_edges)) return;
    const index = view.spatial_index orelse return;
    const projection: Projection = .init(tile);
    const tolerance = tolerances[@min(tile.z, tolerances.len - 1)] * @exp2(-@as(f64, @floatFromInt(tile.z -| (tolerances.len - 1))));
    const epsilon = @as(f64, generalize) * tolerance;
    var edges: mvt.Layer = .init(a, "edges");
    defer edges.deinit();
    var nodes: mvt.Layer = .init(a, "nodes");
    defer nodes.deinit();
    var seen_edges: std.AutoHashMapUnmanaged(EdgeId, void) = .empty;
    defer seen_edges.deinit(a);
    var seen_nodes: std.AutoHashMapUnmanaged(NodeId, void) = .empty;
    defer seen_nodes.deinit(a);
    var geometry: Geometry = .{};
    defer geometry.deinit(a);

    var cells = index.cellsInBox(.init(projection.bounds.minx, projection.bounds.miny), .init(projection.bounds.maxx, projection.bounds.maxy));
    while (try cells.next(deadline)) |cell| {
        var candidates = cell.edges();
        while (try candidates.next()) |id| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if ((try seen_edges.getOrPut(a, id)).found_existing) continue;
            const edge = try view.edge(id);
            const class = try view.class(edge.cls.class_id);
            if (tile.z < zoom[class.category.road_class]) continue;
            const record = try view.coldRecordWithDeadline(id, deadline);
            try geometry.prepare(a, projection, record, epsilon, deadline);
            if (geometry.parts.items.len == 0) continue;
            const twin_id = try view.oppEdge(id);
            const twin = try view.edge(twin_id);
            var has_line = false;
            if (!tile.exclude_edges) {
                const values = try props.edgeProperties(view, filters, id, edge, class, twin_id, twin, record);
                // A shared shape can have separate directional edge info.
                // Valhalla bins one feature per distinct name record.
                const reverse_values = if (record.reverse_references != null)
                    try props.edgeProperties(view, filters, twin_id, twin, try view.class(twin.cls.class_id), id, edge, record)
                else
                    null;
                for (geometry.parts.items) |part| {
                    if (deadline.expired()) return error.DeadlineExceeded;
                    const points = try geometry.quantize(a, part, deadline);
                    if (points.len < 2) continue;
                    has_line = true;
                    try edges.addLine(@backingInt(id), points, values.slice(), deadline);
                    if (reverse_values) |values_for_twin| {
                        for (0..points.len / 2) |i| {
                            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                            std.mem.swap(mvt.Point, &points[i], &points[points.len - 1 - i]);
                        }
                        try edges.addLine(@backingInt(twin_id), points, values_for_twin.slice(), deadline);
                    }
                }
            } else {
                for (geometry.parts.items) |part| {
                    if (deadline.expired()) return error.DeadlineExceeded;
                    if ((try geometry.quantize(a, part, deadline)).len > 1) {
                        has_line = true;
                        break;
                    }
                }
            }
            if (!tile.exclude_nodes and has_line) {
                for ([_]u32{ edge.head, twin.head }) |raw_node| {
                    const node: NodeId = @fromBackingInt(raw_node);
                    if ((try seen_nodes.getOrPut(a, node)).found_existing) continue;
                    const location = (try view.coordinate(node)).toTilePoint();
                    const position = projection.project(Projection.mercator(location));
                    if (!clip_box.covers(position)) continue;
                    const values = try props.nodeProperties(view, filters, node);
                    try nodes.addPoint(raw_node, Projection.point(position), values.slice(), deadline);
                }
            }
        }
    }
    try edges.write(out, deadline);
    try nodes.write(out, deadline);
}

const Geometry = struct {
    vertices: std.ArrayList(graph.format.Coordinate) = .empty,
    plane: std.ArrayList(Point) = .empty,
    clipped: std.ArrayList(Point) = .empty,
    parts: std.ArrayList(geo.polygon.LineRange) = .empty,
    points: std.ArrayList(mvt.Point) = .empty,

    fn deinit(self: *Geometry, a: Allocator) void {
        self.vertices.deinit(a);
        self.plane.deinit(a);
        self.clipped.deinit(a);
        self.parts.deinit(a);
        self.points.deinit(a);
    }

    fn prepare(self: *Geometry, a: Allocator, p: Projection, record: graph.cold.Record, epsilon: f64, deadline: Deadline) !void {
        self.parts.clearRetainingCapacity();
        self.clipped.clearRetainingCapacity();
        try self.vertices.resize(a, record.header.point_count);
        try record.decodeShape(self.vertices.items, deadline);
        try self.plane.resize(a, self.vertices.items.len);
        var crosses = false;
        var previous = self.vertices.items[0].toTilePoint();
        for (self.vertices.items, self.plane.items, 0..) |fixed, *projected, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const v = fixed.toTilePoint();
            if (!crosses) crosses = p.bounds.covers(v) or geo.polygon.clipSegment(previous, v, p.bounds) != null;
            previous = v;
            projected.* = Projection.mercator(v);
        }
        if (!crosses) return;
        if (epsilon > 0.5) try geo.line.douglasPeuckerPlanar(a, &self.plane, epsilon, deadline);
        for (self.plane.items, 0..) |*v, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            v.* = p.project(v.*);
        }
        try geo.polygon.clipPolyline(a, self.plane.items, clip_box, &self.clipped, &self.parts, deadline);
    }

    fn quantize(self: *Geometry, a: Allocator, part: geo.polygon.LineRange, deadline: Deadline) ![]mvt.Point {
        self.points.clearRetainingCapacity();
        for (self.clipped.items[part.start..part.end], 0..) |p, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const point = Projection.point(.init(@round(p.lng), @round(p.lat)));
            if (self.points.items.len != 0) {
                const prev = self.points.items[self.points.items.len - 1];
                if (point.x == prev.x and point.y == prev.y) continue;
            }
            try self.points.append(a, point);
        }
        return self.points.items;
    }
};
