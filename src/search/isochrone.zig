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
const compact = @import("compact_movements.zig");
pub const MovementLayout = compact.Layout;
const geometry = @import("isochrone_geometry.zig");
pub const GeometryLayout = geometry.Layout;
pub const RasterStage = enum { graph, decode, resample, paint };
const hasPolicy = @import("../snap/edge.zig").hasPolicy;

const Allocator = std.mem.Allocator;
const View = graph.reader.View;
const NodeId = graph.format.NodeId;
const EdgeId = graph.format.EdgeId;
const Point = geo.PointLL;
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
    return IsochroneWithQueue(K, queue.RadixQueue);
}

pub fn IsochroneWithQueue(comptime K: type, comptime Q: type) type {
    return struct {
        const Self = @This();
        view: *const View,
        engine: expansion.Expansion(K, Q),

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
            const cached_geometry = if (comptime hasGeometry(@TypeOf(observer))) observer.rasterGeometry() else {};
            if (@TypeOf(cached_geometry) != void and cached_geometry.view != self.view) return error.InvalidRasterGeometry;
            const a = arena.allocator();
            var grid = try constructGrid(a, request, limits, control);
            errdefer grid.deinit();
            const scratch = arena.mark();
            defer arena.rewind(scratch);
            const sweep = try prepareSweep(a, request, control);
            var visitor = try Rasterizer.init(self.view, a, request.direction, &grid, limits, control);
            const stats = if (@TypeOf(observer) == void)
                try self.engine.run(arena, kernel, sweep, &visitor, control)
            else blk: {
                const Observed = struct {
                    rasterizer: *Rasterizer,
                    observer: @TypeOf(observer),
                    geometry_layout: @TypeOf(cached_geometry),

                    const profiled = @TypeOf(observer) != void and hasPolicy(@TypeOf(observer), "expansionStage");
                    pub const expansionStage = if (profiled) stage else {};
                    pub const expansionSample = if (profiled) sample else {};
                    pub const movementLayout = if (compact.hasLayout(@TypeOf(observer))) layout else {};

                    fn layout(adapter: *@This()) *const MovementLayout {
                        return adapter.observer.movementLayout();
                    }

                    fn stage(adapter: *@This(), phase: core.ExpansionStage) void {
                        adapter.observer.expansionStage(phase);
                    }

                    fn sample(adapter: *@This(), popped: usize) void {
                        adapter.observer.expansionSample(popped);
                    }

                    pub fn visit(adapter: *@This(), event: expansion.Visit) !expansion.Decision {
                        try adapter.observer.observe(event);
                        return adapter.rasterizer.visitMeasured(event, adapter.geometry_layout, {});
                    }
                };
                var observed: Observed = .{ .rasterizer = &visitor, .observer = observer, .geometry_layout = cached_geometry };
                break :blk try self.engine.run(arena, kernel, sweep, &observed, control);
            };
            return .{ .grid = grid, .stats = stats };
        }

        /// Measure the exact bounded sweep independently of its grid writer.
        pub fn runTraversal(self: *Self, arena: *memory.Arena, kernel: K, request: Request, observer: anytype, control: core.Control) !expansion.Stats {
            try control.check();
            if (request.mode == .multimodal) return error.UnsupportedMultimodalIsochrone;
            const limits = try Limits.fromContours(request.contours, control);
            const scratch = arena.mark();
            defer arena.rewind(scratch);
            const sweep = try prepareSweep(arena.allocator(), request, control);
            const Traversal = struct {
                bounds: Bounds,
                observer: @TypeOf(observer),

                const profiled = @TypeOf(observer) != void and hasPolicy(@TypeOf(observer), "expansionStage");
                pub const expansionStage = if (profiled) stage else {};
                pub const expansionSample = if (profiled) sample else {};
                pub const movementLayout = if (compact.hasLayout(@TypeOf(observer))) layout else {};

                fn stage(adapter: *@This(), phase: core.ExpansionStage) void {
                    adapter.observer.expansionStage(phase);
                }

                fn sample(adapter: *@This(), popped: usize) void {
                    adapter.observer.expansionSample(popped);
                }

                fn layout(adapter: *@This()) *const MovementLayout {
                    return adapter.observer.movementLayout();
                }

                pub fn visit(adapter: *@This(), event: expansion.Visit) !expansion.Decision {
                    if (profiled) adapter.observer.expansionStage(.labels);
                    if (@TypeOf(observer) != void) try adapter.observer.observe(event);
                    return if (adapter.bounds.prunes(event.previous orelse .{})) .prune else .expand;
                }
            };
            var visitor: Traversal = .{ .bounds = limits.bounds(), .observer = observer };
            return self.engine.run(arena, kernel, sweep, &visitor, control);
        }
    };
}

fn hasGeometry(comptime Observer: type) bool {
    if (Observer == void or !hasPolicy(Observer, "rasterGeometry")) return false;
    const T = if (@typeInfo(Observer) == .pointer) @typeInfo(Observer).pointer.child else Observer;
    return @TypeOf(T.rasterGeometry) != void;
}

fn prepareSweep(a: Allocator, request: Request, control: core.Control) !expansion.Request {
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
    return .{
        .origins = nodes[0..node_count],
        .partial_origins = groups[0..group_count],
        .direction = request.direction,
        .timing = request.timing,
        .excluded = request.excluded,
        .unit_size = request.unit_size,
    };
}

/// Paint recorded settled events in their original order.
pub fn rasterize(view: *const View, arena: *memory.Arena, request: Request, events: []const expansion.Visit, control: core.Control) !Grid {
    return rasterizeObserved(view, arena, request, events, {}, {}, control);
}

pub fn rasterizeObserved(
    view: *const View,
    arena: *memory.Arena,
    request: Request,
    events: []const expansion.Visit,
    layout: anytype,
    observer: anytype,
    control: core.Control,
) !Grid {
    if (@TypeOf(layout) != void and layout.view != view) return error.InvalidRasterGeometry;
    const a = arena.allocator();
    const limits = try Limits.fromContours(request.contours, control);
    var grid = try constructGrid(a, request, limits, control);
    errdefer grid.deinit();
    const scratch = arena.mark();
    defer arena.rewind(scratch);
    var painter = try Rasterizer.init(view, a, request.direction, &grid, limits, control);
    for (events, 0..) |event, i| {
        if (i % 1024 == 0) try control.check();
        if (@TypeOf(observer) != void) observer.rasterSample(i);
        _ = try painter.visitMeasured(event, layout, observer);
    }
    return grid;
}

const Bounds = struct {
    seconds: f32,
    metres: f32,

    fn prunes(self: Bounds, previous: core.Label) bool {
        // Paint the last crossing edge from inside the padded limits. A
        // mixed request continues while either metric can still contribute.
        return previous.secs > self.seconds and @as(f32, @floatFromInt(previous.dist_m)) > self.metres;
    }
};

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

    fn bounds(self: Limits) Bounds {
        return .{ .seconds = self.seconds(), .metres = self.metres() };
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
    bounds: Bounds,
    shape_interval: f32,
    cell_index: usize,
    settled_words: []u64,
    settled: flags.Array(u64, 0) = .{},
    vertices: std.ArrayList(Point) = .empty,
    samples: std.ArrayList(Point) = .empty,

    fn init(view: *const View, a: Allocator, direction: core.Direction, grid: *Grid, limits: Limits, control: core.Control) !Rasterizer {
        return .{
            .view = view,
            .allocator = a,
            .direction = direction,
            .control = control,
            .grid = grid,
            .bounds = limits.bounds(),
            .shape_interval = geometry.shapeInterval(grid.tiles.tilesize),
            .cell_index = geometry.cellIndex(grid.tiles.tilesize),
            .settled_words = try settledWords(a, view.edges.len),
        };
    }

    pub fn visit(self: *Rasterizer, event: expansion.Visit) !expansion.Decision {
        return self.visitMeasured(event, {}, {});
    }

    fn visitMeasured(self: *Rasterizer, event: expansion.Visit, layout: anytype, observer: anytype) !expansion.Decision {
        const profiled = @TypeOf(observer) != void;
        const edge = event.label.edgeId();
        const opposite = try self.view.oppEdge(edge);
        const outward = if (self.direction == .forward) edge else opposite;
        const behind = if (self.direction == .forward) opposite else edge;
        const id = @backingInt(outward);
        const reverse_id = @backingInt(behind);
        const reverse_settled = try self.markSettled(id, reverse_id);

        const previous = event.previous orelse core.Label{};
        const start_metres: f32 = @floatFromInt(previous.dist_m);
        if (self.bounds.prunes(previous)) return .prune;
        // Valhalla marks forward seeds as origin edges and reverse seeds
        // as ordinary opposing edges.
        const origin = self.direction == .forward and event.previous == null;
        if (reverse_settled and !origin) return .expand;
        const hot = try self.view.edge(outward);
        if (!geometry.paints((try self.view.class(hot.cls.class_id)).category.use)) return .expand;

        const end = (try self.view.coordinate(event.node)).toTilePoint();
        const traversed: f32 = @floatFromInt(if (origin) event.label.dist_m else hot.geom.len_m);
        const end_metres: f32 = @floatFromInt(event.label.dist_m);
        if (traversed < self.shape_interval * 1.5) {
            const start = if (origin and event.cut.begin != 0) blk: {
                if (profiled) observer.rasterStage(.decode);
                const points = try self.decodeShape(try self.view.coldRecordWithDeadline(outward, self.control.deadline), false);
                if (profiled) observer.rasterStage(.paint);
                break :blk (try self.originSuffix(points, traversed))[0];
            } else (try self.view.coordinate(@fromBackingInt((try self.view.edge(behind)).head))).toTilePoint();
            if (profiled) observer.rasterStage(.paint);
            _ = try self.markSegment(start, end, self.grid.tiles.tileIdOf(start), self.grid.tiles.tileIdOf(end), event.label.secs, end_metres);
            return .expand;
        }
        const cached = if (@TypeOf(layout) != void) layout.shape(outward, self.cell_index) else null;
        self.samples.clearRetainingCapacity();
        const reversed = if (cached) |shape| reversed: {
            if (shape.distances) |distances| {
                if (profiled) observer.rasterStage(.resample);
                try geo.line.resamplePolylineWithDistances(self.allocator, shape.points, @floatFromInt(hot.geom.len_m), self.shape_interval, &self.samples, distances, self.control.deadline);
            } else {
                if (profiled) observer.rasterStage(.paint);
                if (!origin) return if (shape.reverse)
                    self.paintSamples(true, shape.points, previous.secs, event.label.secs, start_metres, end_metres)
                else
                    self.paintSamples(false, shape.points, previous.secs, event.label.secs, start_metres, end_metres);
                try self.samples.appendSlice(self.allocator, shape.points);
            }
            break :reversed shape.reverse;
        } else reversed: {
            if (profiled) observer.rasterStage(.decode);
            const record = try self.view.coldRecordWithDeadline(outward, self.control.deadline);
            const shape = try self.decodeShape(record, record.reverse);
            if (profiled) observer.rasterStage(.resample);
            try geo.line.resamplePolylineWithDeadline(self.allocator, shape, @floatFromInt(hot.geom.len_m), self.shape_interval, &self.samples, self.control.deadline);
            break :reversed record.reverse;
        };
        // Valhalla resamples in storage order before orienting the samples.
        if (reversed) try self.reverseSamples();
        if (profiled) observer.rasterStage(.paint);
        const points = if (origin) try self.originSuffix(self.samples.items, traversed) else self.samples.items;
        return self.paintSamples(false, points, previous.secs, event.label.secs, start_metres, end_metres);
    }

    fn reverseSamples(self: *Rasterizer) !void {
        const samples = self.samples.items;
        for (samples[0 .. samples.len / 2], 0..) |*point, i| {
            if (i % 256 == 0) try self.control.check();
            std.mem.swap(Point, point, &samples[samples.len - 1 - i]);
        }
    }

    fn paintSamples(
        self: *Rasterizer,
        comptime reverse: bool,
        points: []const Point,
        start_seconds: f32,
        end_seconds: f32,
        start_metres: f32,
        end_metres: f32,
    ) !expansion.Decision {
        const count: f32 = @floatFromInt(points.len - 1);
        const delta_seconds = (end_seconds - start_seconds) / count;
        const delta_metres = (end_metres - start_metres) / count;
        const nondecreasing = delta_seconds >= 0 and delta_metres >= 0;
        var seconds = start_seconds;
        var metres = start_metres;
        var from = points[if (reverse) points.len - 1 else 0];
        var from_cell = self.grid.tiles.tileIdOf(from);
        var from_marked = false;
        for (1..points.len) |i| {
            if ((i - 1) % 256 == 0) try self.control.check();
            const to = points[if (reverse) points.len - 1 - i else i];
            seconds += delta_seconds;
            metres += delta_metres;
            const to_cell = self.grid.tiles.tileIdOf(to);
            // The previous segment already contributed an equal or earlier
            // observation to this cell.
            if (from_cell != to_cell or !from_marked or !nondecreasing)
                from_marked = try self.markSegment(from, to, from_cell, to_cell, seconds, metres);
            from = to;
            from_cell = to_cell;
        }
        return .expand;
    }

    fn markSettled(self: *Rasterizer, id: u32, reverse_id: u32) !bool {
        const reverse_bit = @as(u64, 1) << @as(u6, @truncate(reverse_id));
        const bit = @as(u64, 1) << @as(u6, @truncate(id));
        if (self.settled_words.len != 0) {
            const reverse_settled = self.settled_words[reverse_id / 64] & reverse_bit != 0;
            self.settled_words[id / 64] |= bit;
            return reverse_settled;
        }
        const reverse_settled = self.settled.get(reverse_id / 64) & reverse_bit != 0;
        (try self.settled.at(self.allocator, id / 64)).* |= bit;
        return reverse_settled;
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

    fn markSegment(self: *Rasterizer, from: Point, to: Point, a: i32, b: i32, seconds: f32, metres: f32) !bool {
        const value: Grid.Value = .{ seconds * units.min_per_sec, metres * units.km_per_meter };
        if (a == b) {
            self.grid.setIfLess(a, value);
        } else if (self.grid.tiles.areNeighbors(a, b)) {
            self.grid.setCellsIfLess(2, .{ a, b }, value);
        } else {
            try self.markDistantSegment(from, to, value);
            return false;
        }
        return true;
    }

    noinline fn markDistantSegment(self: *Rasterizer, from: Point, to: Point, value: Grid.Value) !void {
        var cells: SegmentCells = .{ .grid = self.grid, .value = value };
        try self.grid.tiles.visitIntersectLine(&.{ from, to }, &cells, self.control.deadline);
        cells.flush();
    }
};

fn settledWords(a: Allocator, edge_count: usize) ![]u64 {
    // Bound request initialization independently of the size of the graph.
    const max_bytes = 64 * 1024;
    if (edge_count > max_bytes * 8) return &.{};
    const words = try a.alloc(u64, (edge_count + 63) / 64);
    @memset(words, 0);
    return words;
}

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
