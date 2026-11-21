// Ported from src/loki/search.cc and src/loki/worker.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/point.zig");
const line = @import("../geo/line.zig");
const grid = @import("../geo/grid.zig");
const meters_per_degree_lat = @import("../geo/constants.zig").meters_per_degree_lat;
const graph = @import("../graph/root.zig");
const request = @import("../api/request.zig");
const Reach = @import("reach.zig");
const paged = @import("../search/paged.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;
const EdgeId = graph.format.EdgeId;
const Use = graph.constants.Use;

pub const Defaults = struct {
    radius: u32 = 0,
    max_radius: u32 = 200,
    minimum_reachability: u32 = 50,
    max_reachability: u32 = 100,
    search_cutoff: u32 = 35_000,
    heading_tolerance: i32 = 60,
    node_snap_tolerance: f32 = 5,
    street_side_tolerance: u32 = 5,
    street_side_max_distance: u32 = 1000,
};

pub const Side = enum {
    none,
    left,
    right,

    fn opposite(self: Side) Side {
        return switch (self) {
            .none => .none,
            .left => .right,
            .right => .left,
        };
    }
};

pub const PathEdge = struct {
    id: EdgeId,
    projected: geo.PointLL,
    distance: f64,
    percent_along: f32,
    heading: f32,
    reach: Reach.Counts = .{},
    side: Side = .none,
    node: enum { none, begin, end } = .none,
};

pub const PathLocation = struct {
    edges: []const PathEdge,
    filtered_edges: []const PathEdge,
    rank_candidates: bool,
    exclude_closures: ?bool = null,
};

pub const DirectedEdge = @import("edge.zig").DirectedEdge;

/// Access-only predicate for graph inspection. Cost models supply their own
/// concrete allowed predicate. An optional closed method checks active
/// closures. An optional meetsAccessRestrictions method evaluates the
/// request-time mode and vehicle restrictions.
pub const Access = struct {
    mask: graph.constants.AccessMask,

    pub fn allowed(self: Access, edge: DirectedEdge) bool {
        const access = edge.class.access.forward;
        return access & @as(u16, @bitCast(self.mask)) != 0;
    }
    pub fn allowedNode(self: Access, node: *const graph.format.NodeHot) bool {
        return node.attr.access & @as(u16, @bitCast(self.mask)) != 0;
    }
};

/// Geometry-only correlation for NoCost and linear feature walking.
pub const NoCost = struct {
    pub fn allowed(_: NoCost, edge: DirectedEdge) bool {
        const use = edge.class.category.use;
        return use != @backingInt(Use.rail) and use != @backingInt(Use.bus);
    }

    pub fn allowedNode(_: NoCost, _: *const graph.format.NodeHot) bool {
        return true;
    }
};

pub const Projection = struct {
    point: geo.PointLL,
    squared: f64,
    segment: usize,
};

const Hit = struct {
    projection: Projection,
    edge: DirectedEdge,
    order: union(enum) { native: BinOrder, tile: usize },

    fn compare(_: void, a: Hit, b: Hit) std.math.Order {
        const distance = std.math.order(a.projection.squared, b.projection.squared);
        if (distance != .eq) return distance;
        return switch (a.order) {
            .native => |native| native.compare(b.order.native),
            .tile => |index| std.math.order(index, b.order.tile),
        };
    }
};

// Ported from the deterministic bin ordering in src/mjolnir/graphvalidator.cc.
const upstream_tiles = [_]grid.Tiles{
    .initGrid(.init(-180, -90), 4, 90, 45, 5, true),
    .initGrid(.init(-180, -90), 1, 360, 180, 5, true),
    .initGrid(.init(-180, -90), 0.25, 1440, 720, 5, true),
};

const BinOrder = struct {
    distance: f64,
    subdivision: i32,
    originating: bool,
    direction: DirectionOrder,

    fn compare(self: BinOrder, other: BinOrder) std.math.Order {
        if (self.distance != other.distance) return std.math.order(self.distance, other.distance);
        if (self.subdivision != other.subdivision) return std.math.order(self.subdivision, other.subdivision);
        if (self.originating != other.originating) return if (self.originating) .lt else .gt;
        return self.direction.compare(other.direction);
    }
};

const NearestBin = struct {
    point: geo.PointLL,
    local: grid.Tiles = upstream_tiles[2],
    previous: ?i32 = null,
    tile: i32 = -1,
    subdivision: i32 = std.math.maxInt(i32),
    distance: f64 = std.math.inf(f64),

    pub fn emit(self: *NearestBin, cell: grid.Cell) error{}!void {
        if (self.distance == 0) return;
        const subdivision = self.local.subdivision(cell);
        if (self.previous == subdivision) return;
        self.previous = subdivision;
        const distance = self.local.binOrderDistance(self.point, subdivision);
        if (distance < self.distance or (distance == self.distance and subdivision < self.subdivision)) {
            self.tile = cell.tile;
            self.subdivision = subdivision;
            self.distance = distance;
        }
    }
};

const DirectionOrder = struct {
    level: usize,
    tile: i32,
    node: u64,
    rank: u5,
    edge: EdgeId,

    fn init(edge: DirectedEdge, start: geo.PointLL) DirectionOrder {
        const level = hierarchyLevel(edge);
        const tiles = upstream_tiles[level];
        const tile = tiles.tileIdOf(start);
        const base = tiles.base(tile);
        const step = @as(f64, tiles.tilesize) / 65_536.0;
        const x: u32 = @intFromFloat(std.math.clamp((start.lng - base.lng) / step, 0, 65_535));
        const y: u32 = @intFromFloat(std.math.clamp((start.lat - base.lat) / step, 0, 65_535));
        return .{
            .level = level,
            .tile = tile,
            .node = grid.hilbertIndex(16, x, y),
            .rank = incidentRank(edge),
            .edge = edge.id,
        };
    }

    fn compare(self: DirectionOrder, other: DirectionOrder) std.math.Order {
        const left = .{ other.level, self.tile, self.node, self.rank, @backingInt(self.edge) };
        const right = .{ self.level, other.tile, other.node, other.rank, @backingInt(other.edge) };
        inline for (left, right) |a, b| {
            if (a != b) return std.math.order(a, b);
        }
        return .eq;
    }
};

fn hierarchyLevel(edge: DirectedEdge) usize {
    if (edge.graph_view.snap_bin_index != null) return 2;
    const rc = edge.class.category.road_class;
    return if (rc <= 2) 0 else if (rc <= 4) 1 else 2;
}

fn incidentRank(edge: DirectedEdge) u5 {
    if (edge.graph_view.snap_bin_index != null) return 0;
    return graph.constants.incidentEdgeRank(edge.class.forwardAccess().auto, edge.class.category.road_class, edge.class.flags.named);
}

/// Graph reads and costing are shared with routing. All transient storage
/// comes from the caller's request arena.
pub fn search(view: *const graph.reader.View, arena: Allocator, location: request.Location, defaults: Defaults, costing: anytype, deadline: Deadline) !PathLocation {
    const threshold = thresholds(location, defaults);
    var finder: Reach.Finder = .{
        .view = view,
        .arena = arena,
        .limit = @max(threshold.inbound, threshold.outbound),
        .deadline = deadline,
    };
    return searchWithReach(&finder, location, defaults, costing);
}

pub fn thresholds(location: request.Location, defaults: Defaults) Reach.Counts {
    if (location.minimum_reachability) |common| {
        const limit = @min(common, defaults.max_reachability);
        return .{ .inbound = limit, .outbound = limit };
    }
    if (location.minimum_inbound_reachability != null or location.minimum_outbound_reachability != null) {
        return .{
            .inbound = @min(location.minimum_inbound_reachability orelse 0, defaults.max_reachability),
            .outbound = @min(location.minimum_outbound_reachability orelse 0, defaults.max_reachability),
        };
    }
    return .{ .inbound = defaults.minimum_reachability, .outbound = defaults.minimum_reachability };
}

pub fn searchWithReach(finder: *Reach.Finder, location: request.Location, defaults: Defaults, costing: anytype) !PathLocation {
    const view = finder.view;
    const arena = finder.arena;
    const deadline = finder.deadline;
    if (deadline.expired()) return error.DeadlineExceeded;
    if (view.cold_idx == null or view.coordinates == null or view.classes == null) return error.MissingSnapData;
    const index = view.spatial_index orelse return error.MissingSnapData;
    const point: geo.PointLL = .init(location.lng, location.lat);
    if (!point.inRange()) return error.InvalidCoordinate;
    const indoor = location.search_filter.level != request.max_level;
    const cutoff: f64 = @floatFromInt(if (indoor) @min(location.search_cutoff orelse 300, 1000) else location.search_cutoff orelse defaults.search_cutoff);
    const state: Query = .{
        .location = location,
        .defaults = defaults,
        .arena = arena,
        .deadline = deadline,
        .point = point,
        .approx = .init(point),
        .cutoff = cutoff,
        .radius = @floatFromInt(@min(location.radius orelse defaults.radius, defaults.max_radius)),
        .required = thresholds(location, defaults),
    };
    var work: Work = .{ .query = state, .finder = finder };
    defer work.deinit();
    try work.find(index, view, costing);
    return work.finish(costing);
}

const Query = struct {
    location: request.Location,
    defaults: Defaults,
    arena: Allocator,
    deadline: Deadline,
    point: geo.PointLL,
    approx: geo.DistanceApproximator,
    cutoff: f64,
    radius: f64,
    required: Reach.Counts,

    fn check(self: Query) error{DeadlineExceeded}!void {
        if (self.deadline.expired()) return error.DeadlineExceeded;
    }

    fn allows(self: Query, costing: anytype, edge: DirectedEdge) !bool {
        const class = edge.class;
        const rc = class.category.road_class;
        const flags = class.flags;
        const filter = self.location.search_filter;
        if (flags.node_connector or rc > @backingInt(filter.min_road_class) or rc < @backingInt(filter.max_road_class) or
            (filter.exclude_tunnel and flags.tunnel) or (filter.exclude_bridge and flags.bridge) or
            (filter.exclude_toll and flags.toll) or (filter.exclude_ramp and class.category.use == @backingInt(Use.ramp)) or
            (filter.exclude_ferry and (class.category.use == @backingInt(Use.ferry) or class.category.use == @backingInt(Use.rail_ferry))) or
            (filter.exclude_steps and class.category.use == @backingInt(Use.steps)) or !costing.allowed(edge)) return false;
        if (comptime @import("edge.zig").hasPolicy(@TypeOf(costing), "closed")) {
            if (filter.exclude_closures and costing.closed(edge)) return false;
        }
        if (comptime @import("edge.zig").hasPolicy(@TypeOf(costing), "meetsAccessRestrictionsWithin")) {
            if (filter.exclude_restricted and !try costing.meetsAccessRestrictionsWithin(edge, self.deadline)) return false;
        } else if (comptime @import("edge.zig").hasPolicy(@TypeOf(costing), "meetsAccessRestrictions")) {
            if (filter.exclude_restricted and !costing.meetsAccessRestrictions(edge)) return false;
        }
        if (filter.level != request.max_level) {
            const record = try edge.graph_view.coldRecord(edge.id);
            return record.indoor.includes(filter.level, self.deadline);
        }
        return true;
    }

    fn softFilter(self: Query, edge: PathEdge, opposite: DirectedEdge) !bool {
        if (self.location.heading) |preferred| {
            const diff = @abs(@as(f32, @floatFromInt(preferred)) - edge.heading);
            const tolerance: f32 = @floatFromInt(self.location.heading_tolerance orelse self.defaults.heading_tolerance);
            if (@min(diff, 360 - diff) > tolerance) return true;
        }
        if (self.location.preferred_layer) |layer| {
            const record = try opposite.graph_view.coldRecord(opposite.id);
            if (layer != record.indoor.layer) return true;
        }
        const preferred = self.location.preferred_side;
        const cutoff = self.location.street_side_cutoff orelse .service_other;
        if (edge.side == .none or preferred == .either or opposite.class.category.road_class > @backingInt(cutoff)) return false;
        const tail = try opposite.graph_view.node(@fromBackingInt(opposite.hot.head));
        return (tail.attr.drive_on_left == (edge.side == .left)) != (preferred == .same);
    }

    fn streetSide(self: Query, projection: Projection, heading: f32) Side {
        const min: f64 = @floatFromInt(self.location.street_side_tolerance orelse self.defaults.street_side_tolerance);
        const max: f64 = @floatFromInt(self.location.street_side_max_distance orelse self.defaults.street_side_max_distance);
        var point = self.point;
        var squared = projection.squared;
        if (self.location.display_lat != null and self.location.display_lng != null) {
            point = .init(self.location.display_lng.?, self.location.display_lat.?);
            const approx: geo.DistanceApproximator = .init(point);
            squared = approx.distanceSquared(.init(point.lng + geo.wrappedLongitudeDelta(projection.point.lng, point.lng), projection.point.lat));
        }
        if (squared < min * min or squared > max * max) return .none;
        const angle = @mod(projection.point.heading(point) - heading, 360);
        if (10 < angle and angle < 170) return .right;
        if (190 < angle and angle < 350) return .left;
        return .none;
    }
};

const Batch = struct {
    hits: std.PriorityQueue(Hit, void, Hit.compare) = .initContext({}),
    nearest: ?Hit = null,

    fn retain(self: *Batch, arena: Allocator, hit: Hit, in_radius: bool) !void {
        if (in_radius) try self.hits.push(arena, hit);
        if (self.nearest == null or Hit.compare({}, hit, self.nearest.?) == .lt) self.nearest = hit;
    }

    fn fillNearest(self: *Batch, arena: Allocator) !void {
        if (self.hits.peek() == null) if (self.nearest) |nearest| try self.hits.push(arena, nearest);
    }
};

const projected_flag = 1;
const correlated_flag = 2;

const Work = struct {
    query: Query,
    finder: *Reach.Finder,
    fixed: std.ArrayList(geo.FixedLL) = .empty,
    shape: std.ArrayList(geo.PointLL) = .empty,
    seen: paged.Array(u8, 0) = .{},
    eligible: Batch = .{},
    fallback: Batch = .{},
    closest_external: f64 = std.math.inf(f64),
    edges: std.ArrayList(PathEdge) = .empty,
    filtered: std.ArrayList(PathEdge) = .empty,
    through_ends: std.ArrayList(PathEdge) = .empty,

    fn deinit(self: *Work) void {
        const arena = self.query.arena;
        self.edges.deinit(arena);
        self.filtered.deinit(arena);
        self.through_ends.deinit(arena);
        self.fixed.deinit(arena);
        self.shape.deinit(arena);
        self.eligible.hits.deinit(arena);
        self.fallback.hits.deinit(arena);
    }

    fn decode(self: *Work, edge: DirectedEdge) ![]const geo.PointLL {
        var record = try edge.graph_view.coldRecord(edge.id);
        record.reverse = false;
        const len = record.header.point_count;
        try self.fixed.resize(self.query.arena, len);
        try record.decodeShape(self.fixed.items, self.query.deadline);
        try self.shape.resize(self.query.arena, len);
        for (self.fixed.items, self.shape.items, 0..) |fixed, *point, i| {
            if (i % 256 == 0) try self.query.check();
            point.* = fixed.toTilePoint();
        }
        return self.shape.items;
    }

    fn find(self: *Work, index: graph.spatial.View, view: *const graph.reader.View, costing: anytype) !void {
        if (view.snap_bin_index) |bins| return self.findTileBins(bins, view, costing);
        const q = self.query;
        // Rounding E7 shape coordinates to the E6 used for projection moves
        // the whole segment by at most half a microdegree per axis (< 0.08 m).
        const padding = 0.08;
        const limit = graph.spatial.projectionLimit(q.point, q.approx, q.cutoff) + padding;
        var scanned: f64 = -1;
        var extent = @min(limit, @max(128, q.radius + padding));
        while (true) {
            var cells = try index.projectionRings(q.arena, q.approx, extent, q.deadline);
            defer cells.deinit();
            while (cells.next()) |cell| {
                try q.check();
                if (cell.distance <= scanned) continue;
                if (self.eligible.nearest) |nearest| {
                    const needed = @max(q.radius, @sqrt(nearest.projection.squared)) + padding;
                    if (cell.distance > needed) return;
                }
                var edges = cell.cell.edges();
                while (try edges.next()) |id| {
                    try q.check();
                    const status = try self.seen.at(q.arena, @backingInt(id));
                    if (status.* & projected_flag != 0) continue;
                    status.* |= projected_flag;
                    const edge = try DirectedEdge.read(view, id);
                    const opposite = try DirectedEdge.read(view, try view.oppEdge(id));
                    const forward_allowed = try q.allows(costing, edge);
                    const reverse_allowed = try q.allows(costing, opposite);
                    if (!forward_allowed and !reverse_allowed) continue;
                    const projection = try project(q.approx, try self.decode(edge), q.deadline);
                    const in_radius = projection.squared < q.radius * q.radius;
                    // Reachable candidates outside the retained radius can
                    // tighten the distance at which an island is discarded.
                    if (!in_radius and self.eligible.nearest != null and
                        projection.squared > self.eligible.nearest.?.projection.squared and
                        (self.fallback.nearest == null or projection.squared >= self.closest_external)) continue;
                    if (q.point.distance(projection.point) > q.cutoff) continue;
                    const hit = try self.orderHit(projection, edge, opposite, forward_allowed, reverse_allowed);
                    const twin = if (hit.edge.id == edge.id) opposite else edge;
                    const twin_allowed = if (hit.edge.id == edge.id) reverse_allowed else forward_allowed;
                    try self.collect(costing, hit, if (twin_allowed) twin else null);
                }
            }
            if (extent == limit) return;
            if (self.eligible.nearest) |nearest| {
                if (extent >= @max(q.radius, @sqrt(nearest.projection.squared)) + padding) return;
            }
            scanned = extent;
            extent = @min(limit, 2 * extent);
        }
    }

    fn findTileBins(self: *Work, bins: graph.snap_bins.View, view: *const graph.reader.View, costing: anytype) !void {
        const q = self.query;
        const tiles = upstream_tiles[2];
        var closest = try grid.ClosestFirst.init(q.arena, tiles, q.point);
        defer closest.deinit();
        var order: usize = 0;
        while (try closest.next()) |bin| {
            try q.check();
            if (bin.distance > q.cutoff) break;
            if (self.eligible.nearest) |nearest| {
                if (bin.distance > @max(q.radius, @sqrt(nearest.projection.squared))) break;
            }
            const edges = try bins.edgesIn(@intCast(bin.tile), bin.bin);
            const base = tiles.base(bin.tile);
            const bin_x: f32 = @floatFromInt(bin.bin % tiles.nsubdivisions);
            const bin_y: f32 = @floatFromInt(bin.bin / tiles.nsubdivisions);
            const step = tiles.subdivision_size;
            const center: geo.DistanceApproximator = .init(.init(base.lng + @as(f64, bin_x * step + step / 2), base.lat + @as(f64, bin_y * step + step / 2)));
            for (edges) |entry| {
                try q.check();
                if (entry.circle.valid() and self.outsideCircle(entry.circle, center)) continue;
                const index = entry.edge;
                const id: EdgeId = @fromBackingInt(index);
                const opposing = try view.oppEdge(id);
                const slot = @min(index, @backingInt(opposing));
                const status = try self.seen.at(q.arena, slot);
                if (status.* & projected_flag != 0) continue;
                status.* |= projected_flag;
                const edge = try DirectedEdge.read(view, id);
                const twin = try DirectedEdge.read(view, opposing);
                const forward_allowed = try q.allows(costing, edge);
                const reverse_allowed = try q.allows(costing, twin);
                if (!forward_allowed and !reverse_allowed) continue;
                const projection = try project(q.approx, try self.decode(edge), q.deadline);
                try self.collect(costing, .{
                    .projection = projection,
                    .edge = if (forward_allowed) edge else twin,
                    .order = .{ .tile = order },
                }, if (forward_allowed and reverse_allowed) twin else null);
                order += 1;
            }
        }
    }

    fn outsideCircle(self: *const Work, circle: graph.snap_bins.Circle, bin_center: geo.DistanceApproximator) bool {
        const q = self.query;
        var center = circle.center(bin_center);
        center.lng = q.point.lng + geo.wrappedLongitudeDelta(center.lng, q.point.lng);
        const squared = q.approx.distanceSquared(center);
        const radius = circle.radius();
        const cutoff = q.cutoff + radius;
        if (squared > cutoff * cutoff) return true;
        const nearest = self.eligible.nearest orelse return false;
        const search_radius = q.radius + radius;
        if (nearest.projection.squared < q.radius * q.radius and squared > search_radius * search_radius) return true;
        const lower = @sqrt(squared) - radius;
        return lower >= q.cutoff or (lower >= q.radius and lower >= @sqrt(nearest.projection.squared));
    }

    fn collect(self: *Work, costing: anytype, candidate: Hit, twin: ?DirectedEdge) !void {
        const q = self.query;
        var hit = candidate;
        var reachable = try self.candidateReachable(costing, hit);
        if (!reachable) {
            if (twin) |opposite| {
                var other = hit;
                other.edge = opposite;
                if (try self.candidateReachable(costing, other)) {
                    hit = other;
                    reachable = true;
                }
            }
        }
        const squared = hit.projection.squared;
        const radius = q.radius * q.radius;
        const in_radius = squared < radius;
        if (!reachable) return self.fallback.retain(q.arena, hit, in_radius);
        if (squared < self.closest_external) {
            if (self.eligible.nearest) |nearest| {
                const previous = nearest.projection.squared;
                if (previous >= radius and squared < previous) {
                    self.closest_external = previous;
                } else if (!in_radius and squared >= previous) {
                    self.closest_external = squared;
                }
            } else {
                self.closest_external = squared;
            }
        }
        try self.eligible.retain(q.arena, hit, in_radius);
    }

    fn candidateReachable(self: *Work, costing: anytype, hit: Hit) !bool {
        const required = self.query.required;
        if (hit.order == .tile) {
            if (self.finder.cached(hit.edge.id)) |reach| return reach.satisfies(required);
            if (self.eligible.nearest) |nearest| {
                // The tile search only expands uncached reach when a hit can
                // replace the closest reachable one. The exterior cutoff uses
                // this provisional classification. Emitted edges get measured
                // counts in append.
                if (hit.projection.squared >= nearest.projection.squared) return true;
            }
        }
        return (try self.finder.counts(hit.edge.id, costing)).satisfies(required);
    }

    fn orderHit(self: *const Work, projection: Projection, edge: DirectedEdge, opposing: DirectedEdge, edge_allowed: bool, opposing_allowed: bool) !Hit {
        const points = self.fixed.items;
        const tail = points[if (edge.reverse) points.len - 1 else 0].toOsmPoint();
        const head = points[if (edge.reverse) 0 else points.len - 1].toOsmPoint();
        const a = DirectionOrder.init(edge, tail);
        const b = DirectionOrder.init(opposing, head);
        var bin: NearestBin = .{ .point = self.query.point };
        try bin.local.visitIntersectLine(self.shape.items, &bin, self.query.deadline);
        const a_local = bin.local.tileIdOf(self.shape.items[if (edge.reverse) points.len - 1 else 0]);
        const b_local = bin.local.tileIdOf(self.shape.items[if (edge.reverse) 0 else points.len - 1]);
        const a_first = if (a_local == b_local) a.compare(b) != .gt else (bin.tile == a_local or (bin.tile != b_local and a_local < b_local));
        const forward = edge_allowed and (!opposing_allowed or a_first);
        const first = if (a_first) a else b;
        return .{
            .projection = projection,
            .edge = if (forward) edge else opposing,
            .order = .{ .native = .{
                .distance = bin.distance,
                .subdivision = bin.subdivision,
                .originating = first.level == 2 and bin.tile == (if (a_first) a_local else b_local),
                .direction = first,
            } },
        };
    }

    fn finish(self: *Work, costing: anytype) !PathLocation {
        const q = self.query;
        try self.eligible.fillNearest(q.arena);
        try self.fallback.fillNearest(q.arena);
        while (self.fallback.hits.pop()) |hit| {
            try q.check();
            if (hit.projection.squared > self.closest_external) break;
            try self.eligible.hits.push(q.arena, hit);
        }
        while (self.eligible.hits.pop()) |hit| {
            try q.check();
            // Imported bins apply the cutoff to the circle before projecting.
            // A projection outside the cutoff can still set the exterior
            // fallback bound, but only in-range projections are returned.
            if (hit.order == .tile and q.point.distance(hit.projection.point) > q.cutoff) continue;
            try self.correlate(costing, hit);
        }
        for (self.through_ends.items) |edge| {
            try q.check();
            try self.filtered.append(q.arena, edge);
        }
        return .{
            .edges = try self.edges.toOwnedSlice(q.arena),
            .filtered_edges = try self.filtered.toOwnedSlice(q.arena),
            .rank_candidates = !q.location.skip_ranking_candidates,
            .exclude_closures = q.location.search_filter.exclude_closures,
        };
    }

    fn append(self: *Work, input: PathEdge, opposite: DirectedEdge, costing: anytype) !void {
        const q = self.query;
        const filtered = try q.softFilter(input, opposite);
        // A filtered interior projection does not consume the edge ID.
        // Valhalla can subsequently correlate that edge at a snapped node.
        if (!filtered or input.node != .none) {
            const status = try self.seen.at(q.arena, @backingInt(input.id));
            if (status.* & correlated_flag != 0) return;
            status.* |= correlated_flag;
        }
        var edge = input;
        edge.reach = try self.finder.counts(edge.id, costing);
        const output = if (filtered) &self.filtered else if (edge.node == .end and
            q.location.heading != null and (q.location.type == .through or q.location.type == .break_through))
            &self.through_ends
        else
            &self.edges;
        try output.append(q.arena, edge);
    }

    fn correlate(self: *Work, costing: anytype, hit: Hit) !void {
        const q = self.query;
        const edge = hit.edge;
        const view = edge.graph_view;
        const opposite = try DirectedEdge.read(view, try view.oppEdge(edge.id));
        const projection = hit.projection;
        const shape = try self.decode(edge);
        const first = shape[0];
        const last = shape[shape.len - 1];
        const snap: f64 = q.location.node_snap_tolerance orelse q.defaults.node_snap_tolerance;
        const front = projection.point.eql(first) or q.point.distance(first) < snap;
        const back = projection.point.eql(last) or q.point.distance(last) < snap;
        if (if (edge.reverse) back else front) return self.correlateNode(costing, view, opposite.hot.head, projection.point, hierarchyLevel(edge));
        if (if (edge.reverse) front else back) return self.correlateNode(costing, view, edge.hot.head, projection.point, hierarchyLevel(edge));

        var length: f64 = 0;
        for (0..projection.segment) |i| {
            if (i % 256 == 0) try q.check();
            length += shape[i].distance(shape[i + 1]);
        }
        length += shape[projection.segment].distance(projection.point);
        const edge_length: f64 = @floatFromInt(edge.hot.geom.len_m);
        const fraction = @min(length, edge_length) / edge_length;
        const ratio = if (edge.reverse) 1 - fraction else fraction;
        const angle = try edgeHeading(q.deadline, edge, shape, projection.segment, projection.point);
        const side = q.streetSide(projection, angle);
        const distance = q.point.distance(projection.point);
        try self.append(.{
            .id = edge.id,
            .projected = projection.point,
            .distance = distance,
            .percent_along = @floatCast(ratio),
            .heading = angle,
            .side = side,
        }, opposite, costing);
        if (try q.allows(costing, opposite)) try self.append(.{
            .id = opposite.id,
            .projected = projection.point,
            .distance = distance,
            .percent_along = @floatCast(1 - ratio),
            .heading = reverseHeading(angle),
            .side = side.opposite(),
        }, edge, costing);
    }

    fn edgeHeading(deadline: Deadline, edge: DirectedEdge, shape: []const geo.PointLL, segment: usize, projected: geo.PointLL) !f32 {
        const category = edge.class.category;
        return line.tangentAngle(shape, segment, projected, graph.constants.headingOffset(category.road_class, category.use), !edge.reverse, deadline);
    }

    const NodeEdge = struct {
        edge: DirectedEdge,
        level: usize,
        rank: u5,

        fn compare(_: void, a: NodeEdge, b: NodeEdge) std.math.Order {
            if (a.level != b.level) return std.math.order(a.level, b.level);
            if (a.rank != b.rank) return std.math.order(a.rank, b.rank);
            return std.math.order(@backingInt(a.edge.id), @backingInt(b.edge.id));
        }
    };

    fn correlateNode(self: *Work, costing: anytype, view: *const graph.reader.View, node_id: u32, projected: geo.PointLL, level: usize) !void {
        const q = self.query;
        const coordinate = try view.coordinate(@fromBackingInt(node_id));
        const tiles = upstream_tiles[level];
        const corner = tiles.base(tiles.tileIdOf(coordinate.toPoint()));
        const point = coordinate.toTileNodePoint(corner);
        const distance = q.point.distance(point);
        var node = node_id;
        while (try view.aliasNeighbor(node, false)) |prev| {
            try q.check();
            node = prev;
        }
        var arcs: std.PriorityQueue(NodeEdge, void, NodeEdge.compare) = .initContext({});
        defer arcs.deinit(q.arena);
        while (true) {
            try q.check();
            const range = try view.outEdgeRange(@fromBackingInt(node));
            for (range.first..range.end) |i| {
                const edge = try DirectedEdge.read(view, @fromBackingInt(@as(u32, @intCast(i))));
                if (edge.class.flags.node_connector) continue;
                const other_level = hierarchyLevel(edge);
                try arcs.push(q.arena, .{ .edge = edge, .level = if (level == other_level) 0 else other_level + 1, .rank = incidentRank(edge) });
            }
            node = (try view.aliasNeighbor(node, true)) orelse break;
        }
        while (arcs.pop()) |arc| {
            try q.check();
            const edge = arc.edge;
            const opposite = try DirectedEdge.read(view, try view.oppEdge(edge.id));
            const outgoing = try q.allows(costing, edge);
            const incoming = try q.allows(costing, opposite);
            if (!outgoing and !incoming) continue;
            if (self.seen.get(@backingInt(edge.id)) & self.seen.get(@backingInt(opposite.id)) & correlated_flag != 0) continue;
            const shape = try self.decode(edge);
            const segment = if (edge.reverse) shape.len - 2 else 0;
            const heading = try edgeHeading(q.deadline, edge, shape, segment, projected);
            if (outgoing) try self.append(.{
                .id = edge.id,
                .projected = point,
                .distance = distance,
                .percent_along = 0,
                .node = .begin,
                .heading = heading,
            }, opposite, costing);
            if (incoming) try self.append(.{
                .id = opposite.id,
                .projected = point,
                .distance = distance,
                .percent_along = 1,
                .node = .end,
                .heading = reverseHeading(heading),
            }, edge, costing);
        }
    }
};

fn reverseHeading(heading: f32) f32 {
    return @mod(heading + 180, 360);
}

/// Project onto the closest segment while preserving the first tie.
pub fn project(approx: geo.DistanceApproximator, shape: []const geo.PointLL, deadline: Deadline) !Projection {
    const lanes = std.simd.suggestVectorLength(f64) orelse 4;
    var best: Projection = .{ .point = .invalid, .squared = std.math.inf(f64), .segment = 0 };
    var i: usize = 0;
    while (i + lanes < shape.len) : (i += lanes) {
        if (deadline.expired()) return error.DeadlineExceeded;
        projectBatch(lanes, approx, shape[i..][0 .. lanes + 1], i, &best);
    }
    while (i + 1 < shape.len) : (i += 1) projectBatch(1, approx, shape[i..][0..2], i, &best);
    return best;
}

// Preserve the scalar projector's endpoint values and first-minimum
// behaviour, including coincident vertices and the antimeridian.
fn projectBatch(comptime lanes: usize, approx: geo.DistanceApproximator, shape: *const [lanes + 1]geo.PointLL, base: usize, best: *Projection) void {
    const V = @Vector(lanes, f64);
    var ax: V = undefined;
    var ay: V = undefined;
    var bx: V = undefined;
    var by: V = undefined;
    inline for (0..lanes) |j| {
        const a = shape[j];
        const b = shape[j + 1];
        const delta = geo.wrappedLongitudeDelta(b.lng, a.lng);
        const midpoint = a.lng + 0.5 * delta;
        const center = approx.center_lng;
        const shift: f64 = if (midpoint - center > 180) -360 else if (midpoint - center < -180) 360 else 0;
        ax[j] = a.lng + shift;
        bx[j] = b.lng + shift + if (b.lng - a.lng > 180) @as(f64, -360) else if (a.lng - b.lng > 180) @as(f64, 360) else 0;
        ay[j] = a.lat;
        by[j] = b.lat;
    }
    const px: V = @splat(approx.center_lng);
    const py: V = @splat(approx.center_lat);
    const scale: V = @splat(approx.lng_scale);
    const zero: V = @splat(0);
    const dx = bx - ax;
    const dy = by - ay;
    const sx = dx * scale;
    const dot = ((px - ax) * scale) * sx + (py - ay) * dy;
    const length = sx * sx + dy * dy;
    const t = dot / length;
    const x = @select(f64, dot <= zero, ax, @select(f64, dot >= length, bx, ax + dx * t));
    const y = @select(f64, dot <= zero, ay, @select(f64, dot >= length, by, ay + dy * t));
    const mx = (x - px) * @as(V, @splat(approx.m_per_lng_degree));
    const my = (y - py) * @as(V, @splat(meters_per_degree_lat));
    const squared = my * my + mx * mx;
    inline for (0..lanes) |j| {
        if (squared[j] < best.squared) {
            // Keep the original endpoint bits when clamping an unwrapped segment.
            const longitude = x[j];
            const point = if (dot[j] <= 0) shape[j] else if (dot[j] >= length[j]) shape[j + 1] else geo.PointLL.init(if (longitude > 180) longitude - 360 else if (longitude < -180) longitude + 360 else longitude, y[j]);
            best.* = .{ .point = point, .squared = squared[j], .segment = base + j };
        }
    }
}

test "vector projection keeps the first equal segment and snaps across the seam" {
    const testing = std.testing;
    const line_points = [_]geo.PointLL{
        .init(8, 47),    .init(8.01, 47), .init(8.01, 47), .init(8.02, 47),
        .init(8.03, 47), .init(8.04, 47), .init(8.05, 47), .init(8.06, 47),
        .init(8.07, 47), .init(8.08, 47), .init(8.09, 47), .init(8.1, 47),
    };
    const q: geo.PointLL = .init(8.01, 47.001);
    const approx: geo.DistanceApproximator = .init(q);
    const best = try project(approx, &line_points, .none);
    try testing.expectEqual(0, best.segment);
    try testing.expectEqual(line_points[1], best.point);
    try testing.expectEqual(approx.distanceSquared(best.point), best.squared);
    const seam: geo.DistanceApproximator = .init(.init(-180, 47.001));
    const crossing = try project(seam, &.{ .init(179.999, 47), .init(-179.999, 47) }, .none);
    try testing.expectEqual(@as(f64, 180), @abs(crossing.point.lng));
    try testing.expectEqual(@as(f64, 47), crossing.point.lat);
    try testing.expectEqual(seam.distanceSquared(.init(-180, 47)), crossing.squared);
}
