// Ported from src/meili/routing.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const geo = @import("../geo/root.zig");
const core = @import("../search/search.zig");
const expand = @import("../search/expand.zig");
const endpoints = @import("../search/endpoints.zig");
const queue = @import("../search/queue.zig");
const memory = @import("../infra/arena.zig");
const request = @import("../api/request.zig");
const transition = @import("transition.zig");
const transition_bounds = @import("transition_bounds.zig");
const candidates = @import("candidates.zig");
const View = graph.reader.View;
const NodeId = graph.format.NodeId;
const EdgeId = graph.format.EdgeId;
const Allocator = std.mem.Allocator;

pub const Origin = struct {
    candidate: candidates.Candidate,
    stop_type: request.LocationType = .via,
    previous_edge: ?EdgeId = null,
};

pub const Measurements = struct {
    left: candidates.Measurement,
    right: candidates.Measurement,
    leave_time: ?f64 = null,
};

pub const Segment = struct {
    edge: EdgeId,
    cut: core.Cut = .{},
};

pub const Route = struct {
    segments: []const Segment,
    metres: f32,
    seconds: f32,
    turn_cost: f32,
    score: f32,
    last_edge: ?EdgeId,
};

const Choice = struct {
    metres: f32,
    seconds: f32,
    predecessor: u32,
    tail: ?Segment = null,
};

const PathIterator = struct {
    labels: []const core.Label,
    index: u32,

    fn next(self: *PathIterator) ?core.Label {
        if (self.index == core.no_index) return null;
        const label = self.labels[self.index];
        self.index = label.pred;
        return label;
    }
};

const Destination = struct {
    key: u64,
    slot: u32,
    next: u32,
    fraction: f32 = 0,
};

const Destinations = struct {
    heads: []u32,
    rows: std.ArrayList(Destination) = .empty,
    present: [2]u64 = @splat(0),

    fn nodeKey(id: NodeId) u64 {
        return @as(u64, @backingInt(id)) << 1;
    }

    fn edgeKey(id: EdgeId) u64 {
        return (@as(u64, @backingInt(id)) << 1) | 1;
    }

    fn bucket(self: Destinations, key: u64) usize {
        const mixed = key *% 0x9e3779b97f4a7c15;
        return @intCast((mixed ^ (mixed >> 32)) & (self.heads.len - 1));
    }

    fn bit(key: u64) u64 {
        return @as(u64, 1) << @as(u6, @truncate(key >> 1));
    }

    fn add(self: *Destinations, key: u64, slot: usize, fraction: f32) void {
        self.present[key & 1] |= bit(key);
        const head = &self.heads[self.bucket(key)];
        self.rows.appendAssumeCapacity(.{ .key = key, .slot = @intCast(slot), .next = head.*, .fraction = fraction });
        head.* = @intCast(self.rows.items.len);
    }

    fn init(a: Allocator, targets: []const candidates.Candidate, control: core.Control) !Destinations {
        if (targets.len > (std.math.maxInt(u32) - 1) / 2) return error.TooManyTraceStates;
        const capacity = targets.len * 2;
        const heads = try a.alloc(u32, try std.math.ceilPowerOfTwo(usize, @max(2, capacity)));
        @memset(heads, 0);
        var self: Destinations = .{ .heads = heads, .rows = .initBuffer(try a.alloc(Destination, capacity)) };
        for (targets, 0..) |*target, i| {
            if (i % 64 == 0) try control.check();
            if (target.node) |node| {
                self.add(nodeKey(node), i, 0);
            } else {
                if (target.direction_count > target.directions.len) return error.InvalidCandidate;
                for (target.arcs()) |arc| {
                    if (!(0 <= arc.percent_along and arc.percent_along <= 1)) return error.InvalidCandidate;
                    self.add(edgeKey(arc.edge), i, arc.percent_along);
                }
            }
        }
        return self;
    }

    const Iterator = struct {
        rows: []const Destination,
        key: u64,
        index: u32,
        visited: usize = 0,

        inline fn next(self: *Iterator, control: core.Control) !?Destination {
            while (self.index != 0) {
                const row = self.rows[self.index - 1];
                self.index = row.next;
                self.visited += 1;
                if (self.visited % 64 == 0) try control.check();
                if (row.key == self.key) return row;
            }
            return null;
        }
    };

    inline fn on(self: Destinations, key: u64) Iterator {
        const index = if (self.present[key & 1] & bit(key) != 0) self.heads[self.bucket(key)] else 0;
        return .{ .rows = self.rows.items, .key = key, .index = index };
    }
};

fn allowsNode(costing: anytype, node: *const graph.format.NodeHot) bool {
    if (comptime @hasDecl(@TypeOf(costing), "allowedNode")) return costing.allowedNode(node);
    return true;
}

const TraceOrder = struct {
    const Estimate = struct { node: u32 = core.no_index, value: f32 = 0 };
    const Cache = [32]Estimate;

    coordinates: ?[]const graph.format.Coordinate,
    approx: geo.DistanceApproximator,
    radius: f32,
    cache: ?*Cache = null,

    pub fn estimate(self: TraceOrder, node: NodeId) f32 {
        if (self.cache) |cache| {
            const index = @backingInt(node);
            const entry = &cache[@as(u5, @truncate(index))];
            if (entry.node == index) return entry.value;
            const value = self.calculate(node);
            entry.* = .{ .node = index, .value = value };
            return value;
        }
        return self.calculate(node);
    }

    fn calculate(self: TraceOrder, node: NodeId) f32 {
        const coordinates = self.coordinates orelse return 0;
        const point = coordinates[@backingInt(node)].toPoint();
        const squared: f32 = @floatCast(self.approx.distanceSquared(point));
        return if (squared < self.radius * self.radius) 0 else @max(0, @sqrt(squared) - self.radius);
    }
};

pub const DestinationColumn = struct {
    target_count: usize,
    targets: Destinations,
    observed: f32,
    limits: transition.Limits,
    ordering: TraceOrder,
    first_popped: ?usize = null,
    bounds: ?transition_bounds.Bounds = null,
    built_bounds: bool = false,

    pub fn needsBounds(self: DestinationColumn) bool {
        // Short sweeps are cheaper than building a second search frontier.
        return !self.built_bounds and (self.first_popped orelse 0) >= 32;
    }

    pub fn cacheOrdering(self: *DestinationColumn, a: Allocator) !void {
        if (self.ordering.coordinates == null) return;
        const entries = try a.create(TraceOrder.Cache);
        entries.* = @splat(.{});
        self.ordering.cache = entries;
    }
};

fn Collector(comptime K: type) type {
    return struct {
        const Self = @This();
        view: *const View,
        kernel: K,
        limits: transition.Limits,
        targets: Destinations,
        choices: []?Choice,
        outstanding: usize,
        greatest: f32 = 0,
        bounds: ?transition_bounds.Bounds,
        control: core.Control,

        fn record(self: *Self, i: usize, choice: Choice) !void {
            const previous = self.choices[i];
            if (previous) |current| {
                if (current.metres <= choice.metres) return;
            } else {
                self.outstanding -= 1;
            }
            self.choices[i] = choice;
            if (self.outstanding != 0) return;
            if (previous) |current| if (current.metres != self.greatest) return;
            var greatest: f32 = 0;
            for (self.choices, 1..) |target, index| {
                if (index % 64 == 0) try self.control.check();
                greatest = @max(greatest, target.?.metres);
            }
            self.greatest = greatest;
        }

        fn node(self: *Self, id: NodeId, choice: Choice) !void {
            var targets = self.targets.on(Destinations.nodeKey(id));
            while (try targets.next(self.control)) |row| {
                try self.record(row.slot, choice);
            }
        }

        pub inline fn visit(self: *Self, event: expand.Visit) !expand.Decision {
            // Later queue entries can still have shorter routed distances.
            if (self.prunesAtDistance(event.label.cost)) return .prune;
            if (self.bounds) |bounds| {
                if (bounds.rulesOut(event.node, event.label.cost, self.distanceLimit())) return .prune;
            }
            if (self.limits.allows(event.label.cost, event.label.secs)) {
                try self.node(event.node, .{ .metres = event.label.cost, .seconds = event.label.secs, .predecessor = event.index });
            }
            if (core.linearCosts(self.kernel)) |costs| if (costs.has_allow) return .expand;
            return if (allowsNode(self.kernel, try self.view.node(event.node))) .expand else .prune;
        }

        pub fn distanceLimit(self: *const Self) f32 {
            return if (self.outstanding == 0) self.greatest else self.limits.metres;
        }

        pub inline fn prunesAtDistance(self: *const Self, metres: f32) bool {
            return metres >= self.distanceLimit();
        }

        pub fn observesEdge(self: *const Self, id: EdgeId) !bool {
            var targets = self.targets.on(Destinations.edgeKey(id));
            return (try targets.next(self.control)) != null;
        }

        pub inline fn visitEdge(self: *Self, event: expand.EdgeVisit) !void {
            var targets = self.targets.on(Destinations.edgeKey(event.edge));
            while (try targets.next(self.control)) |row| {
                if (row.fraction < event.cut.begin or row.fraction > event.cut.end) continue;
                const portion = row.fraction - event.cut.begin;
                if (event.exclusion) |avoid| if (row.fraction >= avoid) continue;
                const cut: core.Cut = .{ .begin = event.cut.begin, .end = row.fraction };
                const traversal = try core.priceCut(event.full, event.feature, cut, portion, true, self.control);
                const metres = event.before.cost + traversal.cost;
                const seconds = event.before.secs + traversal.secs;
                if (!self.limits.allows(metres, seconds)) continue;
                try self.record(row.slot, .{
                    .metres = metres,
                    .seconds = seconds,
                    .predecessor = event.predecessor,
                    .tail = .{ .edge = event.edge, .cut = cut },
                });
            }
        }
    };
}

/// One distance-ordered expansion from a candidate to the next column.
/// The arena holding search labels is capped and rewound between origins.
pub fn Router(comptime K: type) type {
    return struct {
        const Self = @This();
        const Engine = expand.Expansion(K, queue.Heap);
        pub const default_scratch_bytes: usize = 8 * 1024 * 1024;

        view: *const View,
        search: Engine,
        scratch: memory.Arena,

        pub fn init(a: Allocator, view: *const View, scratch_bytes: usize) !Self {
            return .{
                .view = view,
                .search = try Engine.init(a, view),
                .scratch = .init(a, .{ .cap_bytes = scratch_bytes }),
            };
        }

        pub fn deinit(self: *Self) void {
            self.search.deinit();
            self.scratch.deinit();
        }

        pub fn connect(self: *Self, output: *memory.Arena, kernel: K, model: *const transition.Model, from: Origin, targets: []const candidates.Candidate, measurements: Measurements, control: core.Control) ![]const ?Route {
            self.scratch.reset();
            var column = self.prepareColumn(self.scratch.allocator(), model, targets, measurements, control) catch |err| {
                if (self.scratch.cap_exceeded) return error.TransitionMemoryLimit;
                return err;
            };
            return self.connectInto(output, kernel, model, from, &column, control);
        }

        pub fn connectPrepared(self: *Self, output: *memory.Arena, kernel: K, model: *const transition.Model, from: Origin, column: *DestinationColumn, control: core.Control) ![]const ?Route {
            self.scratch.reset();
            return self.connectInto(output, kernel, model, from, column, control);
        }

        fn connectInto(self: *Self, output: *memory.Arena, kernel: K, model: *const transition.Model, from: Origin, column: *DestinationColumn, control: core.Control) ![]const ?Route {
            const mark = output.mark();
            errdefer output.rewind(mark);
            return self.connectWithin(output.allocator(), kernel, model, from, column, control) catch |err| {
                if (self.scratch.cap_exceeded) return error.TransitionMemoryLimit;
                return err;
            };
        }

        pub fn prepareColumn(self: *const Self, a: Allocator, model: *const transition.Model, targets: []const candidates.Candidate, measurements: Measurements, control: core.Control) !DestinationColumn {
            try control.check();
            if (!measurements.left.point.inRange() or !measurements.right.point.inRange()) return error.InvalidMeasurement;
            if (!std.math.isFinite(measurements.right.search_radius) or measurements.right.search_radius < 0) return error.InvalidMeasurement;
            const observed: f32 = @floatCast(measurements.left.point.distance(measurements.right.point));
            return .{
                .target_count = targets.len,
                .targets = if (targets.len == 0) .{ .heads = &.{} } else try .init(a, targets, control),
                .observed = observed,
                .limits = model.limits(observed, measurements.leave_time orelse measurements.left.epoch_time, measurements.right.epoch_time),
                .ordering = .{
                    .coordinates = self.view.coordinates,
                    .approx = .init(measurements.right.point),
                    .radius = measurements.right.search_radius,
                },
            };
        }

        pub fn prepareBounds(self: *Self, a: Allocator, column: *const DestinationColumn, control: core.Control) !?transition_bounds.Bounds {
            self.scratch.reset();
            var builder = transition_bounds.Builder.init(self.scratch.allocator(), self.view, column.limits.metres) orelse return null;
            for (column.targets.rows.items, 0..) |target, i| {
                if (i % 64 == 0) try control.check();
                const id: u32 = @intCast(target.key >> 1);
                if (target.key & 1 == 0)
                    try builder.addNode(@fromBackingInt(id))
                else
                    try builder.addEdge(@fromBackingInt(id), target.fraction);
            }
            return builder.finish(a, control);
        }

        fn connectWithin(self: *Self, a: Allocator, kernel: K, model: *const transition.Model, from: Origin, column: *DestinationColumn, control: core.Control) ![]const ?Route {
            try control.check();
            const results = try a.alloc(?Route, column.target_count);
            @memset(results, null);
            if (column.target_count == 0) return results;
            const scratch = self.scratch.allocator();
            const choices = try scratch.alloc(?Choice, column.target_count);
            @memset(choices, null);
            var collector: Collector(K) = .{
                .view = self.view,
                .kernel = kernel,
                .limits = column.limits,
                .targets = column.targets,
                .choices = choices,
                .outstanding = column.target_count,
                .bounds = column.bounds,
                .control = control,
            };
            var origins: [1]NodeId = undefined;
            var starts: [2]endpoints.Candidate = undefined;
            var expansion: expand.Request = .{ .bounds = .{
                .cost = column.limits.metres,
                .seconds = column.limits.seconds orelse std.math.inf(f32),
            } };
            var seeds: [1][]const endpoints.Candidate = undefined;
            if (from.candidate.node) |node| {
                if (!allowsNode(kernel, try self.view.node(node))) return results;
                try collector.node(node, .{ .metres = 0, .seconds = 0, .predecessor = core.no_index });
                if (from.previous_edge) |arrival| {
                    if ((try self.view.edge(arrival)).head != @backingInt(node)) return error.InvalidTracePredecessor;
                    starts[0] = .{ .edge = arrival, .fraction = 1, .score = 0, .begin_node = false, .end_node = true };
                    seeds[0] = starts[0..1];
                    expansion.partial_origins = &seeds;
                } else {
                    origins[0] = node;
                    expansion.origins = &origins;
                }
                if (column.bounds) |bounds| if (bounds.rulesOut(node, 0, column.limits.metres)) return results;
            } else {
                if (from.candidate.direction_count > from.candidate.directions.len) return error.InvalidCandidate;
                var count: usize = 0;
                for (from.candidate.arcs()) |arc| {
                    if (from.previous_edge) |arrival| {
                        if (!try self.allowedDeparture(kernel, arrival, arc.edge, from.stop_type)) continue;
                    }
                    if (column.bounds) |bounds| if (try excludesSeed(&collector, arc, bounds)) continue;
                    starts[count] = .{ .edge = arc.edge, .fraction = arc.percent_along, .score = 0, .begin_node = false, .end_node = false };
                    count += 1;
                }
                if (count == 0) return results;
                seeds[0] = starts[0..count];
                expansion.partial_origins = &seeds;
            }
            const found = try self.search.runDistance(&self.scratch, kernel, expansion, &collector, column.ordering, control);
            if (column.first_popped == null) column.first_popped = found.popped;
            for (choices, results, 0..) |choice, *result, i| {
                if (i % 64 == 0) try control.check();
                if (choice) |path| result.* = try self.route(a, found, path, from, column.observed, model, control);
            }
            return results;
        }

        fn excludesSeed(collector: *const Collector(K), arc: candidates.Candidate.Direction, bounds: transition_bounds.Bounds) !bool {
            if (!(0 <= arc.percent_along and arc.percent_along <= 1)) return error.InvalidCandidate;
            const edge = try collector.view.edge(arc.edge);
            const metres = @as(f32, @floatFromInt(edge.geom.len_m)) * (1 - arc.percent_along);
            if (!bounds.rulesOut(@fromBackingInt(edge.head), metres, collector.limits.metres)) return false;
            var targets = collector.targets.on(Destinations.edgeKey(arc.edge));
            while (try targets.next(collector.control)) |target| {
                if (target.fraction >= arc.percent_along) return false;
            }
            return true;
        }

        /// Meili carries the predecessor label across a fractional origin.
        /// Continuing on its edge is allowed. Other directions are subject to
        /// the costing's turn admission before the new traversal is seeded.
        fn allowedDeparture(self: *const Self, kernel: K, arrival: EdgeId, next: EdgeId, stop_type: request.LocationType) !bool {
            if (arrival == next) return true;
            const before = try self.view.edge(arrival);
            const after = try self.view.edge(next);
            if (forbidUturn(stop_type) and next == try self.view.oppEdge(arrival)) return false;
            if (core.linearCosts(kernel)) |costs| if (costs.allows(next)) return true;
            if (comptime @hasDecl(K, "allowedTurn")) {
                const node: NodeId = @fromBackingInt(before.head);
                const row = try self.view.turnRow(node, before.cls.opp_local);
                return kernel.allowedTurn(self.view, .{
                    .node = node,
                    .incoming = arrival,
                    .incoming_edge = before,
                    .outgoing = next,
                    .outgoing_edge = after,
                    .row = if (after.cls.local < row.len) row[after.cls.local] else 0,
                    .predecessor_dead_end = if (self.view.classes != null) (try self.view.class(before.cls.class_id)).flags.dead_end else null,
                }, .{ .edge = @backingInt(arrival) }, .forward);
            }
            return true;
        }

        fn route(self: *Self, a: Allocator, found: core.Result, choice: Choice, from: Origin, observed: f32, model: *const transition.Model, control: core.Control) !Route {
            var count: usize = @intFromBool(choice.tail != null);
            var walk: PathIterator = .{ .labels = found.labels, .index = choice.predecessor };
            while (walk.next()) |label| {
                if (count % 64 == 0) try control.check();
                const cut = label.cut(found.cuts);
                if (cut.begin != cut.end) count += 1;
            }
            const path = try a.alloc(Segment, count);
            var end = count;
            if (choice.tail) |tail| {
                end -= 1;
                path[end] = tail;
            }
            walk.index = choice.predecessor;
            while (walk.next()) |label| {
                if (end % 64 == 0) try control.check();
                const cut = label.cut(found.cuts);
                if (cut.begin != cut.end) {
                    end -= 1;
                    path[end] = .{ .edge = label.edgeId(), .cut = cut };
                }
            }
            var turns: f32 = 0;
            var previous = if (from.candidate.node != null) from.previous_edge else null;
            if (model.turn_penalties[0] != 0) {
                for (path, 0..) |part, i| {
                    if (i % 64 == 0) try control.check();
                    if (previous) |before| {
                        const inbound = try self.heading(try self.view.oppEdge(before), control);
                        const outbound = try self.heading(part.edge, control);
                        turns += model.turnPenalty(inbound, outbound);
                    }
                    previous = part.edge;
                }
            }
            return .{
                .segments = path,
                .metres = choice.metres,
                .seconds = choice.seconds,
                .turn_cost = turns,
                .score = model.cost(turns, choice.metres, observed),
                .last_edge = if (path.len != 0) path[path.len - 1].edge else from.previous_edge,
            };
        }

        fn heading(self: *Self, id: EdgeId, control: core.Control) !u16 {
            if ((try self.view.edge(id)).cls.local < 8) {
                if (self.view.headings) |headings| return graph.headings.decode(headings[@backingInt(id)]);
            }
            const mark = self.scratch.mark();
            defer self.scratch.rewind(mark);
            const record = try self.view.coldRecordWithDeadline(id, control.deadline);
            const shape = try record.shape(self.scratch.allocator(), control.deadline);
            if (shape.len < 2) return 0;
            const degrees: f32 = @floatCast(shape[0].toTilePoint().heading(shape[1].toTilePoint()));
            return @intFromFloat(std.math.clamp(degrees, 0, 359));
        }
    };
}

fn forbidUturn(stop_type: request.LocationType) bool {
    return stop_type == .through or stop_type == .break_through;
}

const FixtureKernel = struct {
    allow_backtrack: bool = true,

    pub fn allowedTurn(self: FixtureKernel, _: *const View, movement: core.Transition, _: core.Label, _: core.Direction) !bool {
        return self.allow_backtrack or movement.incoming_edge.cls.opp_local != movement.outgoing_edge.cls.local;
    }

    pub fn edgeCost(_: FixtureKernel, _: *const View, _: EdgeId, edge: *const graph.format.EdgeHot, _: core.Direction) !@import("../costing/compiled.zig").Cost {
        const metres: f32 = @floatFromInt(edge.geom.len_m);
        const metres_per_second: f32 = if (edge.speed[0] == 0) 20 else @floatFromInt(edge.speed[0]);
        return .{ .cost = metres * 2, .secs = metres / metres_per_second };
    }

    pub fn turnCost(_: FixtureKernel, _: *const View, _: core.Transition, _: core.Label, _: core.Direction) !@import("../costing/compiled.zig").Cost {
        return .{ .cost = 100, .secs = 100 };
    }
};

fn fixtureEdge(head: u32, local: u5, opposite: u5) graph.format.EdgeHot {
    return .{
        .head = head,
        .geom = .{ .len_m = 100, .grade = 6, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = local, .opp_local = opposite, .cold_checks = 0, .pred_speed = 0 },
        .speed = @splat(0),
    };
}

const fixture: View = .{
    .headers = .initFill(null),
    .dataset_uuid = @splat(0),
    .nodes = &(@as([3]graph.format.NodeHot, @splat(.{ .turn_off = 0, .attr = .{ .access = 0xfff, .type = 0, .density = 0, .signal = 0 } }))),
    .edges = &.{ fixtureEdge(1, 0, 0), fixtureEdge(0, 0, 0), fixtureEdge(2, 1, 0), fixtureEdge(1, 0, 1) },
    .first_edge = &.{ 0, 1, 3, 4 },
    .turns = &.{ 0, 0, 0, 0 },
    .classes = null,
    .coordinates = null,
    .cold_idx = null,
    .cold = null,
    .cold_data = null,
    .slopes = null,
    .spatial = null,
    .spatial_index = null,
    .metadata = null,
    .components = null,
    .turn_sides = null,
    .turn_side_index = null,
    .headings = &.{ graph.headings.encode(90), graph.headings.encode(270), graph.headings.encode(0), graph.headings.encode(180) },
};

fn atNode(id: u32) candidates.Candidate {
    return .{ .node = @fromBackingInt(id), .point = .init(0, 0), .squared_distance = 0 };
}

fn onEdge(id: u32, fraction: f32) candidates.Candidate {
    var candidate: candidates.Candidate = .{ .node = null, .point = .init(0, 0), .squared_distance = 0 };
    candidate.directions[0] = .{ .edge = @fromBackingInt(id), .percent_along = fraction, .heading = 0 };
    candidate.direction_count = 1;
    return candidate;
}

test "transition targets keep edge and node IDs distinct and preserve duplicate order" {
    const t = std.testing;
    const id = 3;
    var arena = memory.Arena.init(t.allocator, .{});
    defer arena.deinit();
    const targets = try Destinations.init(arena.allocator(), &.{ onEdge(id, 0.2), atNode(id), onEdge(id, 0.8) }, .{});
    var edges = targets.on(Destinations.edgeKey(@fromBackingInt(@as(u32, id))));
    try t.expectEqual(2, (try edges.next(.{})).?.slot);
    try t.expectEqual(0, (try edges.next(.{})).?.slot);
    try t.expectEqual(@as(?Destination, null), try edges.next(.{}));
    var nodes = targets.on(Destinations.nodeKey(@fromBackingInt(@as(u32, id))));
    try t.expectEqual(1, (try nodes.next(.{})).?.slot);
    try t.expectEqual(@as(?Destination, null), try nodes.next(.{}));
}

test "one trace expansion reaches interior destinations before the edge bound" {
    const t = std.testing;
    var engine = try Router(FixtureKernel).init(t.allocator, &fixture, 1024 * 1024);
    defer engine.deinit();
    var output: memory.Arena = .init(t.allocator, .{});
    defer output.deinit();
    const model = try transition.Model.init(.{ .breakage_distance_m = 150 });
    const measurements: Measurements = .{ .left = .{ .point = .init(0, 0) }, .right = .{ .point = .init(0.001, 0) } };
    const results = try engine.connect(&output, .{}, &model, .{ .candidate = atNode(0) }, &.{ atNode(0), onEdge(2, 0.4), atNode(2) }, measurements, .{});
    try t.expectEqual(@as(f32, 0), results[0].?.metres);
    const partial = results[1].?;
    try t.expectEqual(@as(f32, 140), partial.metres);
    try t.expectEqual(@as(f32, 7), partial.seconds);
    try t.expectEqual(model.turnPenalty(270, 0), partial.turn_cost);
    try t.expectEqual(2, partial.segments.len);
    try t.expectEqual(0, @backingInt(partial.segments[0].edge));
    try t.expectEqual(2, @backingInt(partial.segments[1].edge));
    try t.expectEqual(@as(f32, 0.4), partial.segments[1].cut.end);
    try t.expect(results[2] == null);
}

test "direct trace cuts obey a separate strict clock bound" {
    const t = std.testing;
    var engine = try Router(FixtureKernel).init(t.allocator, &fixture, 1024 * 1024);
    defer engine.deinit();
    var output: memory.Arena = .init(t.allocator, .{});
    defer output.deinit();
    const model = try transition.Model.init(.{ .breakage_distance_m = 75, .max_route_time_factor = 1 });
    var measurements: Measurements = .{
        .left = .{ .point = .init(0, 0), .epoch_time = 20 },
        .right = .{ .point = .init(0.001, 0), .epoch_time = 24 },
    };
    const origin: Origin = .{ .candidate = onEdge(0, 0.25) };
    const result = try engine.connect(&output, .{}, &model, origin, &.{onEdge(0, 0.75)}, measurements, .{});
    try t.expectEqual(@as(f32, 50), result[0].?.metres);
    try t.expectEqual(@as(f32, 2.5), result[0].?.seconds);
    try t.expectEqual(core.Cut{ .begin = 0.25, .end = 0.75 }, result[0].?.segments[0].cut);
    measurements.leave_time = 22;
    const rejected = try engine.connect(&output, .{}, &model, origin, &.{onEdge(0, 0.75)}, measurements, .{});
    try t.expect(rejected[0] == null);
}

test "shared reverse bounds preserve partial cuts and the actual clock limit" {
    const t = std.testing;
    var engine = try Router(FixtureKernel).init(t.allocator, &fixture, 1024 * 1024);
    defer engine.deinit();
    var prepared_arena: memory.Arena = .init(t.allocator, .{});
    defer prepared_arena.deinit();
    var output: memory.Arena = .init(t.allocator, .{});
    defer output.deinit();
    const model = try transition.Model.init(.{ .breakage_distance_m = 150, .max_route_time_factor = 1 });
    var measurements: Measurements = .{
        .left = .{ .point = .init(0, 0), .epoch_time = 20 },
        .right = .{ .point = .init(0.001, 0), .epoch_time = 27 },
    };
    const targets = &.{ onEdge(2, 0.51), atNode(2) };
    for ([_]f64{ 20, 21.5 }) |leave_time| {
        measurements.leave_time = leave_time;
        var column = try engine.prepareColumn(prepared_arena.allocator(), &model, targets, measurements, .{});
        column.bounds = try engine.prepareBounds(prepared_arena.allocator(), &column, .{});
        try t.expect(column.bounds.?.rulesOut(@fromBackingInt(@as(u32, 0)), 0, column.limits.metres));
        for ([_]Origin{
            .{ .candidate = atNode(0) },
            .{ .candidate = onEdge(0, 0.25) },
            .{ .candidate = onEdge(2, 0.25) },
            .{ .candidate = atNode(1), .previous_edge = @fromBackingInt(@as(u32, 0)) },
        }) |origin| {
            const expected = try engine.connect(&output, .{}, &model, origin, targets, measurements, .{});
            const bounded = try engine.connectPrepared(&output, .{}, &model, origin, &column, .{});
            try t.expectEqualDeep(expected, bounded);
            output.reset();
        }
        prepared_arena.reset();
    }
}

test "fractional trace departure checks arrival direction before seeding" {
    const t = std.testing;
    var engine = try Router(FixtureKernel).init(t.allocator, &fixture, 1024 * 1024);
    defer engine.deinit();
    var output = memory.Arena.init(t.allocator, .{});
    defer output.deinit();
    const model = try transition.Model.init(.{});
    const costs: FixtureKernel = .{ .allow_backtrack = false };
    const measurements: Measurements = .{ .left = .{ .point = .init(0, 0) }, .right = .{ .point = .init(0.001, 0) } };
    var candidate = onEdge(0, 0.5);
    candidate.direction_count = 2;
    candidate.directions[1] = onEdge(1, 0.5).directions[0];
    const targets = [_]candidates.Candidate{ onEdge(0, 0.75), onEdge(1, 0.75) };
    const seeded = try engine.connect(&output, costs, &model, .{ .candidate = candidate }, &targets, measurements, .{});
    try t.expectEqual(@as(f32, 25), seeded[1].?.metres);
    output.reset();
    const continued = try engine.connect(&output, costs, &model, .{ .candidate = candidate, .previous_edge = @fromBackingInt(@as(u32, 0)) }, &targets, measurements, .{});
    try t.expectEqual(@as(f32, 25), continued[0].?.metres);
    try t.expectEqual(@as(?Route, null), continued[1]);
}

test "a quicker arrival remains eligible under the same edge and turn state" {
    const t = std.testing;
    var view = fixture;
    const nodes = @as([6]graph.format.NodeHot, @splat(fixture.nodes[0]));
    view.nodes = &nodes;
    view.first_edge = &.{ 0, 2, 4, 6, 9, 11, 12 };
    view.turns = &(@as([9]u8, @splat(0)));
    view.headings = null;
    var edges = [_]graph.format.EdgeHot{
        fixtureEdge(1, 0, 0), fixtureEdge(2, 1, 0),
        fixtureEdge(0, 0, 0), fixtureEdge(3, 1, 0),
        fixtureEdge(0, 0, 1), fixtureEdge(3, 1, 1),
        fixtureEdge(1, 0, 1), fixtureEdge(2, 1, 1),
        fixtureEdge(4, 2, 0), fixtureEdge(3, 0, 2),
        fixtureEdge(5, 1, 0), fixtureEdge(4, 0, 1),
    };
    for (&edges) |*edge| edge.geom.len_m = 60;
    for ([_]usize{ 0, 2, 3, 6 }) |i| {
        edges[i].geom.len_m = 50;
        edges[i].speed[0] = 5;
    }
    edges[8].geom.len_m = 50;
    edges[9].geom.len_m = 50;
    view.edges = &edges;
    var engine = try Router(FixtureKernel).init(t.allocator, &view, 1024 * 1024);
    defer engine.deinit();
    var output: memory.Arena = .init(t.allocator, .{});
    defer output.deinit();
    const model = try transition.Model.init(.{ .turn_penalty_factor = 0 });
    const measurements: Measurements = .{
        .left = .{ .point = .init(0, 0), .epoch_time = 0 },
        .right = .{ .point = .init(0.001, 0), .epoch_time = 5 },
    };
    const results = try engine.connect(&output, .{}, &model, .{ .candidate = atNode(0) }, &.{atNode(5)}, measurements, .{});
    const result = results[0].?;
    try t.expectEqual(@as(f32, 230), result.metres);
    try t.expectEqual(@as(f32, 11.5), result.seconds);
    try t.expectEqual(1, @backingInt(result.segments[0].edge));
}

// Ported from Routing.TestRoutePathIterator.
test "shared route predecessors end at their own origin" {
    const t = std.testing;
    const labels = [_]core.Label{
        .{ .edge = 0 },
        .{ .edge = 1 },
        .{ .edge = 2 },
        .{ .edge = 3, .pred = 1 },
        .{ .edge = 4, .pred = 1 },
        .{ .edge = 5, .pred = 3 },
        .{ .edge = 6, .pred = 3 },
    };
    var isolated: PathIterator = .{ .labels = &labels, .index = 0 };
    try t.expectEqual(0, isolated.next().?.edge);
    try t.expect(isolated.next() == null);
    for ([_]u32{ 5, 6 }) |start| {
        var path: PathIterator = .{ .labels = &labels, .index = start };
        for ([_]u32{ start, 3, 1 }) |edge| try t.expectEqual(edge, path.next().?.edge);
        try t.expect(path.next() == null);
    }
}

test "independent trace workers reuse their batch after an error" {
    const t = std.testing;
    const jobs = @import("segments.zig");
    var pool = try jobs.Pool(FixtureKernel).init(t.allocator, &fixture, 2, 1024 * 1024);
    defer pool.deinit();
    const model = try transition.Model.init(.{ .turn_penalty_factor = 0 });
    const measurements: Measurements = .{ .left = .{ .point = .init(0, 0) }, .right = .{ .point = .init(0.001, 0) } };
    const first: jobs.Query = .{ .from = .{ .candidate = atNode(0) }, .targets = &.{atNode(2)}, .measurements = measurements };
    const second: jobs.Query = .{ .from = .{ .candidate = onEdge(0, 0.25) }, .targets = &.{onEdge(0, 0.75)}, .measurements = measurements };
    var invalid = second;
    invalid.measurements.right.point = .init(181, 0);
    var work = [_]jobs.Segment{
        .{ .queries = &.{first}, .output = .init(t.allocator, .{}) },
        .{ .queries = &.{invalid}, .output = .init(t.allocator, .{}) },
    };
    defer for (&work) |*segment| segment.deinit();
    try t.expectError(error.InvalidMeasurement, pool.run(.{}, &model, &work, .{}));
    for (work) |segment| try t.expectEqual(0, segment.routes.len);
    work[1].queries = &.{second};
    try pool.run(.{}, &model, &work, .{});
    try t.expectEqual(@as(f32, 200), work[0].routes[0][0].?.metres);
    try t.expectEqual(@as(f32, 50), work[1].routes[0][0].?.metres);
}
