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
    slot: usize,
    next: usize,
    fraction: f32 = 0,
};

const Destinations = struct {
    nodes: std.AutoHashMapUnmanaged(NodeId, usize) = .empty,
    edges: std.AutoHashMapUnmanaged(EdgeId, usize) = .empty,
    rows: std.ArrayList(Destination) = .empty,

    fn add(self: *Destinations, a: Allocator, heads: anytype, key: anytype, slot: usize, fraction: f32) !void {
        const entry = try heads.getOrPutValue(a, key, 0);
        try self.rows.append(a, .{ .slot = slot, .next = entry.value_ptr.*, .fraction = fraction });
        entry.value_ptr.* = self.rows.items.len;
    }

    fn init(a: Allocator, targets: []const candidates.Candidate, control: core.Control) !Destinations {
        var self: Destinations = .{};
        for (targets, 0..) |*target, i| {
            if (i % 64 == 0) try control.check();
            if (target.node) |node| {
                try self.add(a, &self.nodes, node, i, 0);
            } else {
                if (target.direction_count > target.directions.len) return error.InvalidCandidate;
                for (target.arcs()) |arc| {
                    if (!(0 <= arc.percent_along and arc.percent_along <= 1)) return error.InvalidCandidate;
                    try self.add(a, &self.edges, arc.edge, i, arc.percent_along);
                }
            }
        }
        return self;
    }
};

fn allowsNode(costing: anytype, node: *const graph.format.NodeHot) bool {
    if (comptime @hasDecl(@TypeOf(costing), "allowedNode")) return costing.allowedNode(node);
    return true;
}

const TraceOrder = struct {
    coordinates: ?[]const graph.format.Coordinate,
    approx: geo.DistanceApproximator,
    radius: f32,

    pub fn estimate(self: TraceOrder, node: NodeId) f32 {
        const coordinates = self.coordinates orelse return 0;
        const point = coordinates[@backingInt(node)].toPoint();
        const squared: f32 = @floatCast(self.approx.distanceSquared(point));
        return if (squared < self.radius * self.radius) 0 else @max(0, @sqrt(squared) - self.radius);
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
        control: core.Control,

        fn record(self: *Self, i: usize, choice: Choice) void {
            if (self.choices[i]) |previous| {
                if (previous.metres <= choice.metres) return;
            } else {
                self.outstanding -= 1;
            }
            self.greatest = @max(self.greatest, choice.metres);
            self.choices[i] = choice;
        }

        fn node(self: *Self, id: NodeId, choice: Choice) !void {
            var index = self.targets.nodes.get(id) orelse return;
            var visited: usize = 0;
            while (index != 0) : (visited += 1) {
                if (visited % 64 == 0) try self.control.check();
                const row = self.targets.rows.items[index - 1];
                self.record(row.slot, choice);
                index = row.next;
            }
        }

        pub fn visit(self: *Self, event: expand.Visit) !expand.Decision {
            // Later queue entries can still have shorter routed distances.
            if (self.outstanding == 0 and event.label.cost >= self.greatest) return .prune;
            if (self.limits.allows(event.label.cost, event.label.secs)) {
                try self.node(event.node, .{ .metres = event.label.cost, .seconds = event.label.secs, .predecessor = event.index });
            }
            return if (allowsNode(self.kernel, try self.view.node(event.node))) .expand else .prune;
        }

        pub fn visitEdge(self: *Self, event: expand.EdgeVisit) !void {
            var index = self.targets.edges.get(event.edge) orelse return;
            var visited: usize = 0;
            while (index != 0) : (visited += 1) {
                if (visited % 64 == 0) try self.control.check();
                const row = self.targets.rows.items[index - 1];
                index = row.next;
                if (row.fraction < event.cut.begin or row.fraction > event.cut.end) continue;
                const portion = row.fraction - event.cut.begin;
                const metres = event.before.cost + event.full.cost * portion;
                const seconds = event.before.secs + event.full.secs * portion;
                if (!self.limits.allows(metres, seconds)) continue;
                self.record(row.slot, .{
                    .metres = metres,
                    .seconds = seconds,
                    .predecessor = event.predecessor,
                    .tail = .{ .edge = event.edge, .cut = .{ .begin = event.cut.begin, .end = row.fraction } },
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
        const Engine = expand.Expansion(K, queue.BucketQueue);
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
            const mark = output.mark();
            errdefer output.rewind(mark);
            return self.connectWithin(output.allocator(), kernel, model, from, targets, measurements, control) catch |err| {
                if (self.scratch.cap_exceeded) return error.TransitionMemoryLimit;
                return err;
            };
        }

        fn connectWithin(self: *Self, a: Allocator, kernel: K, model: *const transition.Model, from: Origin, targets: []const candidates.Candidate, measurements: Measurements, control: core.Control) ![]const ?Route {
            try control.check();
            if (!measurements.left.point.inRange() or !measurements.right.point.inRange()) return error.InvalidMeasurement;
            if (!std.math.isFinite(measurements.right.search_radius) or measurements.right.search_radius < 0) return error.InvalidMeasurement;
            const observed: f32 = @floatCast(measurements.left.point.distance(measurements.right.point));
            const limits = model.limits(observed, measurements.leave_time orelse measurements.left.epoch_time, measurements.right.epoch_time);
            const results = try a.alloc(?Route, targets.len);
            @memset(results, null);
            if (targets.len == 0) return results;
            const scratch = self.scratch.allocator();
            const choices = try scratch.alloc(?Choice, targets.len);
            @memset(choices, null);
            var collector: Collector(K) = .{
                .view = self.view,
                .kernel = kernel,
                .limits = limits,
                .targets = try .init(scratch, targets, control),
                .choices = choices,
                .outstanding = targets.len,
                .control = control,
            };
            var origins: [1]NodeId = undefined;
            var starts: [2]endpoints.Candidate = undefined;
            var expansion: expand.Request = .{ .bounds = .{
                .cost = limits.metres,
                .seconds = limits.seconds orelse std.math.inf(f32),
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
            } else {
                if (from.candidate.direction_count > from.candidate.directions.len) return error.InvalidCandidate;
                var count: usize = 0;
                for (from.candidate.arcs()) |arc| {
                    if (from.previous_edge) |arrival| {
                        if (!try self.allowedDeparture(kernel, arrival, arc.edge, from.stop_type)) continue;
                    }
                    starts[count] = .{ .edge = arc.edge, .fraction = arc.percent_along, .score = 0, .begin_node = false, .end_node = false };
                    count += 1;
                }
                seeds[0] = starts[0..count];
                expansion.partial_origins = &seeds;
            }
            const found = try self.search.runDistance(&self.scratch, kernel, expansion, &collector, TraceOrder{
                .coordinates = self.view.coordinates,
                .approx = .init(measurements.right.point),
                .radius = measurements.right.search_radius,
            }, control);
            for (choices, results, 0..) |choice, *result, i| {
                if (i % 64 == 0) try control.check();
                if (choice) |path| result.* = try self.route(a, found, path, from, observed, model, control);
            }
            return results;
        }

        /// Meili carries the predecessor label across a fractional origin.
        /// Continuing on its edge is allowed. Other directions are subject to
        /// the costing's turn admission before the new traversal is seeded.
        fn allowedDeparture(self: *const Self, kernel: K, arrival: EdgeId, next: EdgeId, stop_type: request.LocationType) !bool {
            if (arrival == next) return true;
            const before = try self.view.edge(arrival);
            const after = try self.view.edge(next);
            if (forbidUturn(stop_type) and next == try self.view.oppEdge(arrival)) return false;
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
