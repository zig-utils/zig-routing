// Ported from src/meili/candidate_search.cc, src/meili/geometry_helpers.cc
// and measurement handling in src/meili/map_matcher.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");
const snap = @import("../snap/search.zig");
const request = @import("../api/request.zig");
const memory = @import("../infra/arena.zig");
const encounter = @import("encounter.zig");
const fine = @import("fine_grid.zig");
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

const Window = struct {
    bin: i32,
    first: u32,
    last: u32,
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
    ordered_cells: std.AutoHashMapUnmanaged(u64, []const encounter.Arc) = .empty,
    ordered_windows: std.AutoHashMapUnmanaged(Window, []const encounter.Arc) = .empty,
    window_bytes: usize = 0,
    bin_list: std.ArrayList(i32) = .empty,
    bin_order: encounter.Set = .{},
    candidate_order: encounter.Set = .{},
    cell_arcs: std.ArrayList(encounter.Arc) = .empty,
    square_shapes: std.AutoHashMapUnmanaged(EdgeId, ?EdgeId) = .empty,

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
        self.bin_list.deinit(self.a);
        self.bin_order.deinit(self.a);
        self.candidate_order.deinit(self.a);
        self.cell_arcs.deinit(self.a);
        self.square_shapes.deinit(self.a);
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
        if (self.view.snap_bin_index) |bins| {
            if (bins.source_hashes != null) {
                try self.collectOrdered(index, bins, input.point, approx, radius, squared, costing, deadline);
                return self.candidates.items;
            }
        }
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

    fn collectOrdered(self: *Finder, index: graph.spatial.View, bins: graph.snap_bins.View, point: Point, approx: geo.DistanceApproximator, radius: f32, squared: f64, costing: anytype, deadline: Deadline) !void {
        const span_lat: f32 = radius / @as(f32, geo.constants.meters_per_degree_lat);
        const span_lon: f32 = @floatCast(@min(180, radius / @abs(approx.m_per_lng_degree)));
        const south = @max(-90, point.lat - span_lat);
        const north = @min(90, point.lat + span_lat);
        const bounds: geo.AABB = if (span_lon == 180)
            .init(-180, south, 180, north)
        else
            .init(point.lng - span_lon, south, point.lng + span_lon, north);
        const tiles: geo.grid.Tiles = .initGrid(.init(-180, -90), 0.25, 1440, 720, 5, true);
        const subdivisions: geo.grid.Tiles = .initGrid(.init(-180, -90), tiles.subdivision_size, 7200, 3600, 1, true);
        self.bin_list.clearRetainingCapacity();
        try subdivisions.tileListWithin(self.a, bounds, &self.bin_list, deadline);
        self.candidate_order.clear();
        var window: ?Window = null;
        for (self.bin_list.items) |bin_id| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const rc = subdivisions.rowColumn(bin_id);
            const tile = tiles.tileIdColRow(@divTrunc(rc.col, 5), @divTrunc(rc.row, 5));
            const bin: u16 = @intCast(@mod(rc.col, 5) + 5 * @mod(rc.row, 5));
            const source = try bins.orderedEdgesIn(@intCast(tile), bin);
            if (source.edges.len == 0) continue;
            const grid: fine.Grid = .{ .origin = tiles.base(tile) };
            const start = grid.square(bounds.minpt()).clamp();
            const end = grid.square(bounds.maxpt()).clamp();
            if (self.bin_list.items.len == 1) {
                window = .{ .bin = bin_id, .first = start.id(), .last = end.id() };
                if (self.ordered_windows.get(window.?)) |arcs| {
                    for (arcs) |arc| try self.considerOrdered(arc, approx, squared, costing, deadline);
                    return;
                }
            }
            self.bin_order.clear();
            for (@as(usize, @intCast(start.row))..@as(usize, @intCast(end.row + 1))) |row| {
                for (@as(usize, @intCast(start.column))..@as(usize, @intCast(end.column + 1))) |column| {
                    if (deadline.expired()) return error.DeadlineExceeded;
                    const square: fine.Square = .{ .row = @intCast(row), .column = @intCast(column) };
                    const arcs = try self.orderedCell(index, bin_id, source, grid, square, deadline);
                    for (arcs, 0..) |arc, i| {
                        if (i % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
                        try self.bin_order.insert(self.a, arc, deadline);
                    }
                }
            }
            var arcs = self.bin_order.iterator();
            while (arcs.next()) |arc| {
                if (deadline.expired()) return error.DeadlineExceeded;
                try self.candidate_order.insert(self.a, arc, deadline);
            }
        }
        var arcs = self.candidate_order.iterator();
        if (window) |key| try self.rememberWindow(key, arcs, deadline);
        while (arcs.next()) |arc| {
            try self.considerOrdered(arc, approx, squared, costing, deadline);
        }
    }

    fn considerOrdered(self: *Finder, arc: encounter.Arc, approx: geo.DistanceApproximator, squared: f64, costing: anytype, deadline: Deadline) !void {
        if (deadline.expired()) return error.DeadlineExceeded;
        const line = (try self.cachedShape(arc.shape, deadline)) orelse return;
        return self.consider(line, arc.edge, approx, squared, costing, deadline);
    }

    fn rememberWindow(self: *Finder, key: Window, iterator: encounter.Set.Iterator, deadline: Deadline) !void {
        // The encounter order depends only on graph cells. Bound this index
        // separately within the shape cache to leave room for projection data.
        const count = self.candidate_order.nodes.items.len;
        const bytes = count * @sizeOf(encounter.Arc) + @sizeOf(Window) + @sizeOf([]const encounter.Arc);
        if (self.storage.cap_exceeded or bytes > self.options.shape_cache_bytes / 8 -| self.window_bytes) return;
        const a = self.storage.allocator();
        self.ordered_windows.ensureUnusedCapacity(a, 1) catch |err| {
            if (self.storage.cap_exceeded) return;
            return err;
        };
        const arcs = a.alloc(encounter.Arc, count) catch |err| {
            if (self.storage.cap_exceeded) return;
            return err;
        };
        var items = iterator;
        for (arcs, 0..) |*arc, i| {
            if (i % 64 == 0 and deadline.expired()) {
                a.free(arcs);
                return error.DeadlineExceeded;
            }
            arc.* = items.next().?;
        }
        self.ordered_windows.putAssumeCapacityNoClobber(key, arcs);
        self.window_bytes += bytes;
    }

    fn orderedCell(self: *Finder, index: graph.spatial.View, bin: i32, source: graph.snap_bins.View.OrderedEntries, grid: fine.Grid, square: fine.Square, deadline: Deadline) ![]const encounter.Arc {
        const key = @as(u64, @intCast(bin)) * (fine.side * fine.side) + square.id();
        if (self.ordered_cells.get(key)) |arcs| return arcs;
        self.square_shapes.clearRetainingCapacity();
        const bounds = grid.bounds(square);
        // The shared grid indexes E7 geometry. Meili traverses E6 shapes.
        const margin = 0.0000005;
        const min: Point = .init(bounds.minx - margin, bounds.miny - margin);
        const max: Point = .init(bounds.maxx + margin, bounds.maxy + margin);
        var cells = index.intersectingCells(min, max);
        while (try cells.next(deadline)) |cell| {
            var edges = cell.edges();
            while (try edges.next()) |id| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const entry = try self.square_shapes.getOrPut(self.a, id);
                if (entry.found_existing) continue;
                entry.value_ptr.* = null;
                const line = (try self.cachedShape(id, deadline)) orelse continue;
                if (!line.bounds.intersects(bounds)) continue;
                for (line.points[0 .. line.points.len - 1], line.points[1..]) |from, to| {
                    if (deadline.expired()) return error.DeadlineExceeded;
                    if (!try grid.visits(from, to, square, deadline)) continue;
                    entry.value_ptr.* = id;
                    try self.square_shapes.put(self.a, line.opposing.id, id);
                    break;
                }
            }
        }
        self.cell_arcs.clearRetainingCapacity();
        for (source.edges, source.hashes) |entry, hash| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const id: EdgeId = @fromBackingInt(entry.edge);
            if (self.square_shapes.get(id) orelse null) |representative| {
                try self.cell_arcs.append(self.a, .{ .edge = id, .shape = representative, .hash = hash.value() });
            }
        }
        if (self.storage.cap_exceeded or self.options.shape_cache_bytes == 0) return self.cell_arcs.items;
        return self.rememberCell(key) catch |err| {
            if (!self.storage.cap_exceeded) return err;
            return self.cell_arcs.items;
        };
    }

    fn rememberCell(self: *Finder, key: u64) Allocator.Error![]const encounter.Arc {
        const a = self.storage.allocator();
        try self.ordered_cells.ensureUnusedCapacity(a, 1);
        const arcs = try a.dupe(encounter.Arc, self.cell_arcs.items);
        self.ordered_cells.putAssumeCapacityNoClobber(key, arcs);
        return arcs;
    }

    fn collect(self: *Finder, index: graph.spatial.View, bounds: geo.AABB, approx: geo.DistanceApproximator, squared: f64, check_bounds: bool, costing: anytype, deadline: Deadline) !void {
        var cells = index.intersectingCells(bounds.minpt(), bounds.maxpt());
        while (try cells.next(deadline)) |cell| {
            var edges = cell.edges();
            while (try edges.next()) |id| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const line = (try self.shape(id, deadline)) orelse continue;
                if (check_bounds and !line.bounds.intersects(bounds)) continue;
                try self.consider(line, id, approx, squared, costing, deadline);
            }
        }
    }

    fn consider(self: *Finder, line: *const Shape, first_edge: EdgeId, approx: geo.DistanceApproximator, squared: f64, costing: anytype, deadline: Deadline) !void {
        const edge = if (first_edge == line.edge.id) line.edge else line.opposing;
        const opposing = if (first_edge == line.edge.id) line.opposing else line.edge;
        const allowed = costing.allowed(edge);
        const opposite_allowed = costing.allowed(opposing);
        if (!allowed and !opposite_allowed) return;
        var hit = try snap.project(approx, line.points, deadline);
        if (hit.squared > squared) return;
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
            if (hit.squared > squared or (try self.nodes.getOrPut(self.a, end)).found_existing) return;
        }
        var candidate: Candidate = .{ .point = hit.point, .squared_distance = hit.squared, .node = node };
        const heading = line.segments[hit.segment].heading;
        if (allowed) candidate.append(edge, ratio, heading);
        if (opposite_allowed) candidate.append(opposing, ratio, heading);
        try self.candidates.append(self.a, candidate);
    }

    fn shape(self: *Finder, id: EdgeId, deadline: Deadline) !?*const Shape {
        if (self.shapes.getPtr(id)) |cached| {
            if (cached.visited == self.query_number) return null;
            cached.visited = self.query_number;
            return cached;
        }
        if ((try self.uncached.getOrPut(self.a, id)).found_existing) return null;
        return self.loadShape(id, deadline);
    }

    fn cachedShape(self: *Finder, id: EdgeId, deadline: Deadline) !?*const Shape {
        if (self.shapes.getPtr(id)) |cached| return cached;
        return self.loadShape(id, deadline);
    }

    fn loadShape(self: *Finder, id: EdgeId, deadline: Deadline) !?*const Shape {
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
