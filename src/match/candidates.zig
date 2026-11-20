// Ported from src/meili/candidate_search.cc, src/meili/geometry_helpers.cc
// and measurement handling in src/meili/map_matcher.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");
const snap = @import("../snap/search.zig");
const request = @import("../api/request.zig");
const memory = @import("../infra/arena.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;
const EdgeId = graph.format.EdgeId;
const NodeId = graph.format.NodeId;
const Point = geo.PointLL;
const View = graph.reader.View;

pub const Measurement = struct {
    point: Point,
    gps_accuracy: f32 = 5,
    search_radius: f32 = 50,
    epoch_time: f64 = -1,
    stop_type: request.LocationType = .via,
};

pub const Options = struct {
    max_search_radius: f32 = 100,
    shape_cache_bytes: usize = 8 * 1024 * 1024,
};

pub const Candidate = struct {
    pub const Direction = struct {
        edge: EdgeId,
        percent_along: f32,
        heading: f32,
    };

    point: Point,
    squared_distance: f64,
    node: ?NodeId,
    directions: [2]Direction = undefined,
    direction_count: u2 = 0,

    pub fn arcs(self: *const Candidate) []const Direction {
        return self.directions[0..self.direction_count];
    }

    fn append(self: *Candidate, edge: snap.DirectedEdge, ratio: f64, heading: f32) void {
        self.directions[self.direction_count] = .{
            .edge = edge.id,
            .percent_along = @floatCast(if (edge.reverse) 1 - ratio else ratio),
            .heading = if (edge.reverse) @mod(heading + 180, 360) else heading,
        };
        self.direction_count += 1;
    }
};

const Segment = struct { prefix: f64, heading: f32 };
const Shape = struct {
    points: []const Point,
    segments: []const Segment,
    length: f64,
    bounds: geo.AABB,
    edge: snap.DirectedEdge,
    opposing: snap.DirectedEdge,
    visited: u64,
};

/// Request-local scratch and a byte-bounded cache of physical edge shapes.
/// The spatial index is shared with routing and is never copied.
pub const Finder = struct {
    view: *const View,
    a: Allocator,
    options: Options,
    storage: memory.Arena,
    shapes: std.AutoHashMapUnmanaged(EdgeId, Shape) = .empty,
    uncached: std.AutoHashMapUnmanaged(EdgeId, void) = .empty,
    nodes: std.AutoHashMapUnmanaged(NodeId, void) = .empty,
    fixed: std.ArrayList(graph.format.Coordinate) = .empty,
    points: std.ArrayList(Point) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    candidates: std.ArrayList(Candidate) = .empty,
    pending: Shape = undefined,
    query_number: u64 = 0,

    pub fn init(view: *const View, a: Allocator, options: Options) Finder {
        return .{
            .view = view,
            .a = a,
            .options = options,
            .storage = .init(a, .{ .cap_bytes = options.shape_cache_bytes, .first_chunk_bytes = 4096 }),
        };
    }

    pub fn deinit(self: *Finder) void {
        self.storage.deinit();
        self.uncached.deinit(self.a);
        self.nodes.deinit(self.a);
        self.fixed.deinit(self.a);
        self.points.deinit(self.a);
        self.segments.deinit(self.a);
        self.candidates.deinit(self.a);
    }

    /// Retains its capacity between points. The returned slice expires
    /// at the next query. Copy candidate records to keep them.
    pub fn query(self: *Finder, input: Measurement, costing: anytype, deadline: Deadline) ![]const Candidate {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (!input.point.inRange() or !nonnegative(input.gps_accuracy) or !nonnegative(input.search_radius) or
            !nonnegative(self.options.max_search_radius)) return error.InvalidMeasurement;
        self.query_number += 1;
        self.uncached.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.candidates.clearRetainingCapacity();
        const index = self.view.spatial_index orelse return &.{};
        const radius = @min(self.options.max_search_radius, @max(input.gps_accuracy, input.search_radius));
        const squared: f64 = @as(f32, radius * radius);
        const approx = geo.DistanceApproximator.init(input.point);
        // The graph indexes E7 shapes, while correlation projects onto E6.
        const margin = 0.08;
        const span_lat = (@as(f64, radius) + margin) / geo.constants.meters_per_degree_lat;
        const span_lng = @min(180, (@as(f64, radius) + margin) / @abs(approx.m_per_lng_degree));
        const south = @max(-90, input.point.lat - span_lat);
        const north = @min(90, input.point.lat + span_lat);
        const west = input.point.lng - span_lng;
        const east = input.point.lng + span_lng;
        if (span_lng == 180) {
            try self.collect(index, .init(-180, south, 180, north), approx, squared, false, costing, deadline);
        } else {
            try self.collect(index, .init(@max(-180, west), south, @min(180, east), north), approx, squared, west >= -180 and east <= 180, costing, deadline);
            if (west < -180) try self.collect(index, .init(west + 360, south, 180, north), approx, squared, false, costing, deadline);
            if (east > 180) try self.collect(index, .init(-180, south, east - 360, north), approx, squared, false, costing, deadline);
        }
        return self.candidates.items;
    }

    fn collect(self: *Finder, index: graph.spatial.View, bounds: geo.AABB, approx: geo.DistanceApproximator, squared: f64, check_bounds: bool, costing: anytype, deadline: Deadline) !void {
        var cells = index.intersectingCells(bounds.minpt(), bounds.maxpt());
        while (try cells.next(deadline)) |cell| {
            var edges = cell.edges();
            while (try edges.next()) |id| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const line = (try self.shape(id, deadline)) orelse continue;
                if (check_bounds and !line.bounds.intersects(bounds)) continue;
                const edge = line.edge;
                const opposing = line.opposing;
                const allowed = costing.allowed(edge);
                const opposite_allowed = costing.allowed(opposing);
                if (!allowed and !opposite_allowed) continue;
                var hit = try snap.project(approx, line.points, deadline);
                if (hit.squared > squared) continue;
                const start = line.points[hit.segment];
                const length = line.segments[hit.segment].prefix + start.distance(hit.point);
                const first = if (edge.reverse) edge else opposing;
                const last = if (edge.reverse) opposing else edge;
                var node: ?NodeId = null;
                var ratio: f64 = 0;
                if (length <= 1) {
                    hit.point = line.points[0];
                    hit.segment = 0;
                    node = @fromBackingInt(first.hot.head);
                } else if (line.length - length <= 1) {
                    hit.point = line.points[line.points.len - 1];
                    hit.segment = line.segments.len - 1;
                    ratio = 1;
                    node = @fromBackingInt(last.hot.head);
                } else {
                    ratio = length / line.length;
                }
                if (node) |end| {
                    const dx = geo.point.wrappedLongitudeDelta(hit.point.lng, approx.center_lng) * approx.m_per_lng_degree;
                    const dy = (hit.point.lat - approx.center_lat) * geo.constants.meters_per_degree_lat;
                    hit.squared = dx * dx + dy * dy;
                    if (hit.squared > squared or (try self.nodes.getOrPut(self.a, end)).found_existing) continue;
                }
                var candidate: Candidate = .{ .point = hit.point, .squared_distance = hit.squared, .node = node };
                const heading = line.segments[hit.segment].heading;
                if (allowed) candidate.append(edge, ratio, heading);
                if (opposite_allowed) candidate.append(opposing, ratio, heading);
                try self.candidates.append(self.a, candidate);
            }
        }
    }

    fn shape(self: *Finder, id: EdgeId, deadline: Deadline) !?*const Shape {
        if (self.shapes.getPtr(id)) |cached| {
            if (cached.visited == self.query_number) return null;
            cached.visited = self.query_number;
            return cached;
        }
        if ((try self.uncached.getOrPut(self.a, id)).found_existing) return null;
        const edge = try snap.DirectedEdge.read(self.view, id);
        if (edge.class.flags.node_connector or edge.class.category.use >= @backingInt(graph.constants.Use.egress_connection)) return null;
        const opposing = try snap.DirectedEdge.read(self.view, try self.view.oppEdge(id));
        var record = try self.view.coldRecordWithDeadline(id, deadline);
        record.reverse = false;
        const count = record.header.point_count;
        try self.fixed.resize(self.a, count);
        try record.decodeShape(self.fixed.items, deadline);
        try self.points.resize(self.a, count);
        try self.segments.resize(self.a, count - 1);
        const first = self.fixed.items[0].toTilePoint();
        var bounds = geo.AABB.fromPoints(first, first);
        for (self.points.items, self.fixed.items, 0..) |*point, fixed, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            point.* = fixed.toTilePoint();
            _ = bounds.expandPoint(point.*);
        }
        var length: f64 = 0;
        for (self.segments.items, self.points.items[0 .. count - 1], self.points.items[1..], 0..) |*segment, a, b, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            segment.* = .{ .prefix = length, .heading = @floatCast(a.heading(b)) };
            length += a.distance(b);
        }
        self.pending = .{
            .points = self.points.items,
            .segments = self.segments.items,
            .length = length,
            .bounds = bounds,
            .edge = edge,
            .opposing = opposing,
            .visited = self.query_number,
        };
        if (self.storage.cap_exceeded or self.options.shape_cache_bytes == 0) return &self.pending;
        return self.remember(id) catch |err| {
            if (!self.storage.cap_exceeded) return err;
            return &self.pending;
        };
    }

    fn remember(self: *Finder, id: EdgeId) Allocator.Error!*const Shape {
        const a = self.storage.allocator();
        try self.shapes.ensureUnusedCapacity(a, 1);
        const mark = self.storage.mark();
        const points = try a.dupe(Point, self.pending.points);
        const segments = a.dupe(Segment, self.pending.segments) catch |err| {
            const capped = self.storage.cap_exceeded;
            self.storage.rewind(mark);
            self.storage.cap_exceeded = capped;
            return err;
        };
        const entry = self.shapes.getOrPutAssumeCapacity(id);
        std.debug.assert(!entry.found_existing);
        entry.value_ptr.* = self.pending;
        entry.value_ptr.points = points;
        entry.value_ptr.segments = segments;
        return entry.value_ptr;
    }
};

fn nonnegative(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}

pub const State = struct {
    measurement: usize,
    leave_time: ?f64 = null,
};

/// Original indices of measurements for which Meili creates a state.
/// Indices between two states are interpolated along their eventual path.
pub fn interpolate(a: Allocator, trace: []const Measurement, distance: f32, deadline: Deadline) ![]State {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (!nonnegative(distance)) return error.InvalidInterpolationDistance;
    const states = try a.alloc(State, trace.len);
    errdefer a.free(states);
    if (trace.len == 0) return states;
    states[0] = .{ .measurement = 0 };
    var count: usize = 1;
    const threshold = distance * distance;
    for (trace[1..], 1..) |input, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const previous = &states[count - 1];
        const start = trace[previous.measurement].point;
        const squared: f32 = @floatCast(start.distanceSquared(input.point));
        if (i + 1 != trace.len and squared <= threshold) continue;
        if (i > previous.measurement + 1 and trace[i - 1].epoch_time != -1) {
            const p = trace[i - 1].point.project(start, input.point);
            if (p.distance(start) < 0.2 * start.distance(input.point)) previous.leave_time = trace[i - 1].epoch_time;
        }
        states[count] = .{ .measurement = i };
        count += 1;
    }
    return a.realloc(states, count);
}

/// The Loki validation for breakage rejects a trace when every adjacent
/// pair is beyond the configured distance.
pub fn hasMatchablePair(trace: []const Measurement, breakage_distance: f32, deadline: Deadline) !bool {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (!nonnegative(breakage_distance)) return error.InvalidBreakageDistance;
    if (trace.len < 2) return false;
    for (trace[0 .. trace.len - 1], trace[1..], 0..) |a, b, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const distance_m: f32 = @floatCast(a.point.distance(b.point));
        if (distance_m <= breakage_distance) return true;
    }
    return false;
}

// Ported from test/mapmatch.cc's breakage case and Meili measurement grouping.
test "short trace measurements interpolate and a wholly disconnected trace cannot match" {
    const testing = std.testing;
    const start = Point.init(5.0323097, 52.0764279);
    const finish = Point.init(5.1391531, 52.1022785);
    const near = start.pointAlongSegment(finish, 0.0001);
    const trace: []const Measurement = &.{
        .{ .point = start, .epoch_time = 1 },
        .{ .point = near, .epoch_time = 4 },
        .{ .point = finish, .epoch_time = 20 },
    };
    const states = try interpolate(testing.allocator, trace, 10, .none);
    defer testing.allocator.free(states);
    try testing.expectEqualSlices(State, &.{ .{ .measurement = 0, .leave_time = 4 }, .{ .measurement = 2 } }, states);
    try testing.expect(try hasMatchablePair(trace, 2_000, .none));
    try testing.expect(!try hasMatchablePair(&.{ trace[0], trace[2] }, 2_000, .none));
}
