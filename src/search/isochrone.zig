// Ported from src/thor/isochrone.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");
const memory = @import("../infra/arena.zig");
const core = @import("search.zig");
const expansion = @import("expand.zig");
const Candidate = @import("endpoints.zig").Candidate;
const flags = @import("paged.zig");
const queue = @import("queue.zig");

const Allocator = std.mem.Allocator;
const View = graph.reader.View;
const NodeId = graph.format.NodeId;
const EdgeId = graph.format.EdgeId;
const Point = geo.PointLL;
const Use = graph.constants.Use;
const units = geo.constants;

pub const Grid = geo.gridded.Grid(2);
pub const Interval = geo.gridded.Interval;
pub const Mode = enum { motor, pedestrian, bicycle, multimodal };
pub const time_metric = 0;
pub const distance_metric = 1;
pub const nodata: f32 = 65535;
const metric_padding: f32 = 10;

pub const Origin = struct {
    location: Point,
    seed: union(enum) {
        node: NodeId,
        edges: []const Candidate,
    },
};

pub const Request = struct {
    origins: []const Origin,
    contours: []const Interval,
    mode: Mode,
    direction: core.Direction = .forward,
    timing: core.Timing = .{},
    excluded: []const core.ExcludedEdge = &.{},
    unit_size: u32 = 1,
};

pub const Result = struct {
    grid: Grid,
    stats: expansion.Stats,
};

/// Builds a grid in minutes and kilometres. The result lives until the
/// request arena rewinds. Generate contours only after this stage completes.
pub fn Isochrone(comptime K: type) type {
    return struct {
        const Self = @This();
        view: *const View,
        engine: expansion.Expansion(K, queue.BucketQueue),

        pub fn init(a: Allocator, view: *const View) !Self {
            return .{ .view = view, .engine = try .init(a, view) };
        }

        pub fn deinit(self: *Self) void {
            self.engine.deinit();
        }

        pub fn run(self: *Self, arena: *memory.Arena, kernel: K, request: Request, control: core.Control) !Result {
            return self.runObserved(arena, kernel, request, {}, control);
        }

        /// Also report settled edges, including the last edge across a bound.
        /// Observations are streamed in generalized-cost order.
        pub fn runObserved(self: *Self, arena: *memory.Arena, kernel: K, request: Request, observer: anytype, control: core.Control) !Result {
            try control.check();
            if (request.mode == .multimodal) return error.UnsupportedMultimodalIsochrone;
            const limits = try Limits.fromContours(request.contours, control);
            const a = arena.allocator();
            var grid = try constructGrid(a, request, limits, control);
            errdefer grid.deinit();
            const scratch = arena.mark();
            defer arena.rewind(scratch);
            const nodes = try a.alloc(NodeId, request.origins.len);
            const groups = try a.alloc([]const Candidate, request.origins.len);
            var node_count: usize = 0;
            var group_count: usize = 0;
            for (request.origins) |origin| {
                try control.check();
                switch (origin.seed) {
                    .node => |node| {
                        nodes[node_count] = node;
                        node_count += 1;
                    },
                    .edges => |group| {
                        if (group.len == 0) return error.NoCandidates;
                        groups[group_count] = group;
                        group_count += 1;
                    },
                }
            }
            var visitor: Rasterizer = .{
                .view = self.view,
                .allocator = a,
                .direction = request.direction,
                .control = control,
                .grid = &grid,
                .max_seconds = limits.seconds(),
                .max_metres = limits.metres(),
                .shape_interval = grid.tiles.tilesize * @as(f32, units.meters_per_degree_lat) * 0.25,
            };
            const sweep: expansion.Request = .{
                .origins = nodes[0..node_count],
                .partial_origins = groups[0..group_count],
                .direction = request.direction,
                .timing = request.timing,
                .excluded = request.excluded,
                .unit_size = request.unit_size,
            };
            const stats = if (@TypeOf(observer) == void)
                try self.engine.run(arena, kernel, sweep, &visitor, control)
            else blk: {
                const Observed = struct {
                    rasterizer: *Rasterizer,
                    observer: @TypeOf(observer),

                    pub fn visit(adapter: *@This(), event: expansion.Visit) !expansion.Decision {
                        try adapter.observer.observe(event);
                        return adapter.rasterizer.visit(event);
                    }
                };
                var observed: Observed = .{ .rasterizer = &visitor, .observer = observer };
                break :blk try self.engine.run(arena, kernel, sweep, &observed, control);
            };
            return .{ .grid = grid, .stats = stats };
        }
    };
}

const Limits = struct {
    minutes: ?f32 = null,
    km: ?f32 = null,

    fn fromContours(contours: []const Interval, control: core.Control) !Limits {
        if (contours.len == 0) return error.NoContours;
        var limits: Limits = .{};
        for (contours) |contour| {
            try control.check();
            if (!std.math.isFinite(contour.value) or contour.value < 0) return error.InvalidContour;
            const padded = contour.value + metric_padding;
            switch (contour.metric) {
                time_metric => limits.minutes = @max(limits.minutes orelse 0, padded),
                distance_metric => limits.km = @max(limits.km orelse 0, padded),
                else => return error.InvalidContour,
            }
        }
        return limits;
    }

    fn seconds(self: Limits) f32 {
        return if (self.minutes) |value| value * units.sec_per_minute else std.math.floatMin(f32);
    }

    fn metres(self: Limits) f32 {
        return if (self.km) |value| value * units.meters_per_km else std.math.floatMin(f32);
    }
};

fn constructGrid(a: Allocator, request: Request, limits: Limits, control: core.Control) !Grid {
    if (request.origins.len == 0) return error.NoOrigins;
    var center = request.origins[0].location;
    var extent = geo.AABB.fromPoints(center, center);
    for (request.origins) |origin| {
        try control.check();
        const point = origin.location;
        if (!point.inRange()) return error.InvalidOrigin;
        _ = extent.expandPoint(point);
    }
    const midpoint = extent.center();
    var best_distance: f32 = @floatCast(center.distance(midpoint));
    for (request.origins[1..]) |origin| {
        try control.check();
        const distance: f32 = @floatCast(origin.location.distance(midpoint));
        if (distance < best_distance) {
            best_distance = distance;
            center = origin.location;
        }
    }
    const speed_mph: f32 = switch (request.mode) {
        .pedestrian => 5,
        .bicycle => 20,
        .motor, .multimodal => 70,
    };
    const span = @max(limits.seconds() * speed_mph * units.mph_to_meters_per_sec, limits.metres());
    const dlat: f32 = @floatCast(@as(f64, span) / units.meters_per_degree_lat);
    const dlng: f32 = @floatCast(@as(f64, span) / geo.DistanceApproximator.metersPerLngDegree(center.lat));
    const cell = @round(std.math.clamp(dlat / 300, 0.001, 0.005) * 1000) * 0.001;
    var grid = try Grid.init(a, .init(extent.minx - dlng, extent.miny - dlat, extent.maxx + dlng, extent.maxy + dlat), cell, .{ nodata, nodata }, control.deadline);
    errdefer grid.deinit();
    const center_cell = grid.tiles.center(grid.tiles.tileIdOf(center));
    const shift = Point.init(center_cell.lng - center.lng, center_cell.lat - center.lat);
    grid.tiles.bounds.minx -= shift.lng;
    grid.tiles.bounds.miny -= shift.lat;
    grid.tiles.bounds.maxx -= shift.lng;
    grid.tiles.bounds.maxy -= shift.lat;
    const initial: Grid.Value = .{
        if (limits.minutes != null) 0 else std.math.floatMin(f32),
        if (limits.km != null) 0 else std.math.floatMin(f32),
    };
    for (request.origins) |origin| {
        try control.check();
        grid.setIfLess(grid.tiles.tileIdOf(origin.location), initial);
    }
    return grid;
}

const Rasterizer = struct {
    view: *const View,
    allocator: Allocator,
    direction: core.Direction,
    control: core.Control,
    grid: *Grid,
    max_seconds: f32,
    max_metres: f32,
    shape_interval: f32,
    settled: flags.Array(u64, 0) = .{},
    vertices: std.ArrayList(Point) = .empty,
    samples: std.ArrayList(Point) = .empty,

    pub fn visit(self: *Rasterizer, event: expansion.Visit) !expansion.Decision {
        const edge = event.label.edgeId();
        const opposite = try self.view.oppEdge(edge);
        const outward = if (self.direction == .forward) edge else opposite;
        const behind = if (self.direction == .forward) opposite else edge;
        const id = @backingInt(outward);
        const reverse_id = @backingInt(behind);
        const reverse_bit = @as(u64, 1) << @as(u6, @truncate(reverse_id));
        const reverse_settled = self.settled.get(reverse_id / 64) & reverse_bit != 0;
        (try self.settled.at(self.allocator, id / 64)).* |= @as(u64, 1) << @as(u6, @truncate(id));

        const previous = event.previous orelse core.Label{};
        const start_metres: f32 = @floatFromInt(previous.dist_m);
        // Paint the last crossing edge from inside the padded limits. A
        // mixed request continues while either metric can still contribute.
        if (previous.secs > self.max_seconds and start_metres > self.max_metres) return .prune;
        // Valhalla marks forward seeds as origin edges and reverse seeds
        // as ordinary opposing edges.
        const origin = self.direction == .forward and event.previous == null;
        if (reverse_settled and !origin) return .expand;
        const hot = try self.view.edge(outward);
        const use = (try self.view.class(hot.cls.class_id)).category.use;
        if (use == @backingInt(Use.ferry) or use == @backingInt(Use.rail) or use == @backingInt(Use.bus)) return .expand;

        const end = (try self.view.coordinate(event.node)).toTilePoint();
        const traversed: f32 = @floatFromInt(if (origin) event.label.dist_m else hot.geom.len_m);
        const end_metres: f32 = @floatFromInt(event.label.dist_m);
        if (traversed < self.shape_interval * 1.5) {
            const start = if (origin and event.cut.begin != 0)
                (try self.originSuffix(try self.decodeShape(try self.view.coldRecordWithDeadline(outward, self.control.deadline), false), traversed))[0]
            else
                (try self.view.coordinate(@fromBackingInt((try self.view.edge(behind)).head))).toTilePoint();
            try self.markSegment(start, end, self.grid.tiles.tileIdOf(start), self.grid.tiles.tileIdOf(end), event.label.secs, end_metres);
            return .expand;
        }
        const record = try self.view.coldRecordWithDeadline(outward, self.control.deadline);
        const shape = try self.decodeShape(record, record.reverse);
        self.samples.clearRetainingCapacity();
        try geo.line.resamplePolylineWithDeadline(self.allocator, shape, @floatFromInt(hot.geom.len_m), self.shape_interval, &self.samples, self.control.deadline);
        // Valhalla resamples in the stored direction, then paints in the
        // direction of expansion.
        if (record.reverse) {
            const samples = self.samples.items;
            for (samples[0 .. samples.len / 2], 0..) |*point, i| {
                if (i % 256 == 0) try self.control.check();
                std.mem.swap(Point, point, &samples[samples.len - 1 - i]);
            }
        }
        const points = if (origin) try self.originSuffix(self.samples.items, traversed) else self.samples.items;
        const count: f32 = @floatFromInt(points.len - 1);
        const delta_seconds = (event.label.secs - previous.secs) / count;
        const delta_metres = (end_metres - start_metres) / count;
        var seconds = previous.secs;
        var metres = start_metres;
        var from_cell = self.grid.tiles.tileIdOf(points[0]);
        for (points[0 .. points.len - 1], points[1..], 0..) |from, to, i| {
            if (i % 256 == 0) try self.control.check();
            seconds += delta_seconds;
            metres += delta_metres;
            const to_cell = self.grid.tiles.tileIdOf(to);
            try self.markSegment(from, to, from_cell, to_cell, seconds, metres);
            from_cell = to_cell;
        }
        return .expand;
    }

    fn decodeShape(self: *Rasterizer, record: graph.cold.Record, stored_reverse: bool) ![]Point {
        try self.vertices.resize(self.allocator, record.header.point_count);
        var shape = record;
        shape.reverse = record.reverse != stored_reverse;
        try shape.decodeTilePoints(self.vertices.items, self.control.deadline);
        return self.vertices.items;
    }

    fn originSuffix(self: *Rasterizer, points: []Point, distance: f64) ![]Point {
        var i = points.len - 1;
        if (distance == 0) {
            points[i - 1] = points[i];
            return points[i - 1 ..];
        }
        var len: f64 = 0;
        while (i > 0) : (i -= 1) {
            if (i % 256 == 0) try self.control.check();
            const segment = points[i - 1].distance(points[i]);
            len += segment;
            if (len >= distance) {
                points[i - 1] = points[i - 1].pointAlongSegment(points[i], (len - distance) / segment);
                return points[i - 1 ..];
            }
        }
        return points;
    }

    fn markSegment(self: *Rasterizer, from: Point, to: Point, a: i32, b: i32, seconds: f32, metres: f32) !void {
        const value: Grid.Value = .{ seconds * units.min_per_sec, metres * units.km_per_meter };
        if (a == b) {
            self.grid.setIfLess(a, value);
        } else if (self.grid.tiles.areNeighbors(a, b)) {
            self.grid.setCellsIfLess(2, .{ a, b }, value);
        } else {
            var cells: SegmentCells = .{ .grid = self.grid, .value = value };
            try self.grid.tiles.visitIntersectLine(&.{ from, to }, &cells, self.control.deadline);
            cells.flush();
        }
    }
};

const SegmentCells = struct {
    grid: *Grid,
    value: Grid.Value,
    ids: [4]i32 = @splat(-1),
    count: usize = 0,

    pub fn emit(self: *SegmentCells, cell: geo.grid.Cell) error{}!void {
        self.ids[self.count] = cell.tile;
        self.count += 1;
        if (self.count == self.ids.len) self.flush();
    }

    fn flush(self: *SegmentCells) void {
        if (self.count == 0) return;
        self.grid.setCellsIfLess(self.ids.len, self.ids, self.value);
        self.ids = @splat(-1);
        self.count = 0;
    }
};
