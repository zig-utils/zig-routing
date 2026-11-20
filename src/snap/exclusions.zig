// Ported from src/loki/polygon_search.cc and src/loki/worker.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/point.zig");
const AABB = @import("../geo/aabb.zig").AABB;
const graph = @import("../graph/root.zig");
const request = @import("../api/request.zig");
const Ring = @import("../api/exclusions.zig").Ring;
const snap = @import("search.zig");
const io = @import("../infra/io.zig");
const Allocator = std.mem.Allocator;
const EdgeId = graph.format.EdgeId;
const Point = geo.PointLL;

pub const Edge = struct {
    id: EdgeId,
    percent_along: f32 = 0,
};

/// Explicit directed edges take precedence, followed by polygons and snapped
/// locations. Retain the first fraction for each directed edge.
pub fn resolve(view: *const graph.reader.View, arena: Allocator, options: *const request.Options, explicit: []const Edge, defaults: snap.Defaults, costing: anytype, deadline: io.Deadline) ![]Edge {
    var scratch: Scratch = .{ .arena = arena, .deadline = deadline };
    defer scratch.seen.deinit(arena);
    defer scratch.vertices.deinit(arena);
    defer scratch.segments.deinit(arena);
    var excluded: std.AutoArrayHashMapUnmanaged(EdgeId, f32) = .empty;
    defer excluded.deinit(arena);
    for (explicit, 0..) |edge, i| {
        try scratch.check(i);
        _ = try view.edge(edge.id);
        if (!(0 <= edge.percent_along and edge.percent_along <= 1)) return error.InvalidExclusionFraction;
        _ = try excluded.getOrPutValue(arena, edge.id, edge.percent_along);
    }
    for (options.exclude_polygons, 0..) |ring, i| {
        try scratch.check(i);
        try scratch.collect(view, ring, &excluded, costing);
    }
    for (options.exclude_locations) |location| {
        const correlated = snap.search(view, arena, location, defaults, costing, deadline) catch |err| switch (err) {
            error.InvalidCoordinate => continue,
            else => return err,
        };
        for (correlated.edges, 0..) |edge, i| {
            try scratch.check(i);
            _ = try excluded.getOrPutValue(arena, edge.id, edge.percent_along);
        }
    }
    const result = try arena.alloc(Edge, excluded.count());
    for (excluded.keys(), excluded.values(), result, 0..) |id, along, *edge, i| {
        try scratch.check(i);
        edge.* = .{ .id = id, .percent_along = along };
    }
    return result;
}

const Scratch = struct {
    arena: Allocator,
    deadline: io.Deadline,
    seen: std.AutoHashMapUnmanaged(EdgeId, void) = .empty,
    vertices: std.ArrayList(geo.FixedLL) = .empty,
    segments: std.ArrayList(Segment) = .empty,

    fn check(self: *const Scratch, index: usize) error{DeadlineExceeded}!void {
        if (index % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
    }

    fn collect(self: *Scratch, view: *const graph.reader.View, ring: Ring, excluded: *std.AutoArrayHashMapUnmanaged(EdgeId, f32), costing: anytype) !void {
        const count = ring.segmentCount();
        if (count == 0) return;
        const spatial = view.spatial_index orelse return error.MissingSnapData;
        self.seen.clearRetainingCapacity();
        try self.segments.resize(self.arena, count);
        var bounds = AABB.fromPoints(ring.points[0], ring.points[0]);
        for (self.segments.items, 0..) |*segment, i| {
            try self.check(i);
            const a = ring.points[i];
            const b = ring.points[if (i + 1 == ring.points.len) 0 else i + 1];
            if (!a.inRange() or !b.inRange()) return error.InvalidCoordinate;
            if (@abs(a.lng - b.lng) > 180) return error.AntimeridianPolygon;
            segment.* = .init(a, b);
            bounds.expand(segment.bounds);
        }
        var cells = spatial.cellsInBox(bounds.minpt(), bounds.maxpt());
        while (try cells.next(self.deadline)) |cell| {
            var edges = cell.edges();
            var i: usize = 0;
            while (try edges.next()) |id| : (i += 1) {
                try self.check(i);
                if ((try self.seen.getOrPut(self.arena, id)).found_existing) continue;
                const opposing = try view.oppEdge(id);
                if (excluded.contains(id) and excluded.contains(opposing)) continue;
                const edge = try snap.DirectedEdge.read(view, id);
                if (edge.class.flags.node_connector) continue;
                if (!costing.allowed(edge) and !costing.allowed(try snap.DirectedEdge.read(view, opposing))) continue;
                var record = try view.coldRecordWithDeadline(id, self.deadline);
                if (!try self.matchesLevel(record.indoor.levels, ring.levels)) continue;
                record.reverse = false;
                try self.vertices.resize(self.arena, record.header.point_count);
                try record.decodeShape(self.vertices.items, self.deadline);
                if (!try self.intersectsShape(bounds)) continue;
                _ = try excluded.getOrPutValue(self.arena, id, 0);
                _ = try excluded.getOrPutValue(self.arena, opposing, 0);
            }
        }
    }

    fn matchesLevel(self: *Scratch, levels: []align(1) const graph.cold.LevelRange, wanted: []const f32) !bool {
        if (wanted.len == 0) return true;
        if (levels.len != 1 or levels[0].bounds.first != levels[0].bounds.last) return false;
        for (wanted, 0..) |level, i| {
            try self.check(i);
            if (level == levels[0].bounds.first) return true;
        }
        return false;
    }

    fn intersectsShape(self: *const Scratch, bounds: AABB) !bool {
        const first = self.vertices.items[0].toTilePoint();
        var a = first;
        for (self.vertices.items[1..], 0..) |fixed, i| {
            try self.check(i);
            const b = fixed.toTilePoint();
            const edge: Segment = .init(a, b);
            a = b;
            if (!edge.bounds.intersects(bounds)) continue;
            for (self.segments.items, 0..) |segment, j| {
                try self.check(j);
                if (edge.bounds.intersects(segment.bounds) and edge.crosses(segment)) return true;
            }
        }
        if (!bounds.covers(first)) return false;
        var inside = false;
        for (self.segments.items, 0..) |segment, i| {
            try self.check(i);
            const p = segment.a;
            const q = segment.b;
            if ((p.lat > first.lat) == (q.lat > first.lat)) continue;
            if (first.lng < p.lng + (first.lat - p.lat) * (q.lng - p.lng) / (q.lat - p.lat)) inside = !inside;
        }
        return inside;
    }
};

const Segment = struct {
    a: Point,
    b: Point,
    bounds: AABB,

    fn init(a: Point, b: Point) Segment {
        return .{ .a = a, .b = b, .bounds = .init(@min(a.lng, b.lng), @min(a.lat, b.lat), @max(a.lng, b.lng), @max(a.lat, b.lat)) };
    }

    // Match LineSegment2::Intersect, including its parallel edge rule.
    fn crosses(self: Segment, other: Segment) bool {
        const dx = self.b.lng - self.a.lng;
        const dy = self.b.lat - self.a.lat;
        const ox = other.b.lng - other.a.lng;
        const oy = other.b.lat - other.a.lat;
        const denominator = oy * dx - ox * dy;
        if (denominator == 0) return false;
        const x = other.a.lng - self.a.lng;
        const y = other.a.lat - self.a.lat;
        const t = (oy * x - ox * y) / denominator;
        const u = (dy * x - dx * y) / denominator;
        return 0 <= t and t <= 1 and 0 <= u and u <= 1;
    }
};
