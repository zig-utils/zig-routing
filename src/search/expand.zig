// Ported from src/thor/dijkstras.cc (Valhalla 3.9.3).
const std = @import("std");
const core = @import("search.zig");
const memory = @import("../infra/arena.zig");
const View = @import("../graph/reader.zig").View;

pub const Request = core.ExpansionRequest;
pub const Bounds = core.ExpansionBounds;
pub const Visit = core.ExpansionVisit;
pub const EdgeVisit = core.ExpansionEdgeVisit;
pub const Decision = core.ExpansionDecision;
pub const Stats = core.SweepStats;

/// A bounded Dijkstra over the route engine's edge and restriction states.
pub fn Expansion(comptime K: type, comptime Q: type) type {
    return struct {
        const Self = @This();

        search: core.Search(K, Q),

        pub fn init(allocator: std.mem.Allocator, view: *const View) !Self {
            return .{ .search = try .init(allocator, view) };
        }

        pub fn deinit(self: *Self) void {
            self.search.deinit();
        }

        /// The visitor can continue, prune the current label, or stop. Pass
        /// void to collect only counts. Request allocations live in the arena.
        pub fn run(self: *Self, arena: *memory.Arena, kernel: K, request: Request, visitor: anytype, control: core.Control) !Stats {
            return self.search.expand(arena, kernel, request, visitor, control);
        }

        pub fn runDistance(self: *Self, arena: *memory.Arena, kernel: K, request: Request, visitor: anytype, ordering: anytype, control: core.Control) !core.Result {
            return self.search.expandDistance(arena, kernel, request, visitor, ordering, control);
        }
    };
}

const graph = @import("../graph/root.zig");
const queue = @import("queue.zig");
const Cost = @import("../costing/compiled.zig").Cost;
const NodeId = graph.format.NodeId;
const EdgeId = graph.format.EdgeId;
const Edge = graph.format.EdgeHot;

const FixtureKernel = struct {
    check_dead_ends: bool = false,

    pub fn edgeCost(_: FixtureKernel, _: *const View, _: EdgeId, edge: *const Edge, _: core.Direction) !Cost {
        const metres: f32 = @floatFromInt(edge.geom.len_m);
        return .{ .cost = metres / 10, .secs = metres / 20 };
    }

    pub fn edgeCostAt(self: FixtureKernel, view: *const View, id: EdgeId, edge: *const Edge, direction: core.Direction, time: graph.time_info.TimeInfo) !core.Traversal {
        var cost = try self.edgeCost(view, id, edge, direction);
        if (@backingInt(id) == 2 and time.unix_time >= 1004) {
            cost = cost.add(.{ .cost = 6, .secs = 3 });
        }
        return .{ .cost = cost };
    }

    pub fn turnCost(_: FixtureKernel, _: *const View, _: core.Transition, _: core.Label, _: core.Direction) !Cost {
        return .{};
    }

    pub fn allowedTurn(self: FixtureKernel, view: *const View, movement: core.Transition, _: core.Label, direction: core.Direction) !bool {
        if (!self.check_dead_ends or movement.incoming_edge.cls.opp_local != movement.outgoing_edge.cls.local) return true;
        const previous = if (direction == .forward) movement.incoming_edge else movement.outgoing_edge;
        return movement.predecessorAtDeadEnd(view, try view.class(previous.cls.class_id));
    }
};

fn fixtureEdge(head: u32, metres: u24, local: u5, opposite: u5) Edge {
    return .{
        .head = head,
        .geom = .{ .len_m = metres, .grade = 6, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = local, .opp_local = opposite, .cold_checks = 0, .pred_speed = 0 },
        .speed = @splat(0),
    };
}

const fixture: View = .{
    .headers = .initFill(null),
    .dataset_uuid = @splat(0),
    .nodes = &(@as([4]graph.format.NodeHot, @splat(.{
        .turn_off = 0,
        .attr = .{ .access = 0xfff, .type = 0, .density = 0, .signal = 0 },
    }))),
    .edges = &.{
        fixtureEdge(1, 80, 0, 0),
        fixtureEdge(0, 80, 0, 0),
        fixtureEdge(2, 160, 1, 0),
        fixtureEdge(1, 160, 0, 1),
        fixtureEdge(3, 320, 1, 0),
        fixtureEdge(2, 320, 0, 1),
    },
    .first_edge = &.{ 0, 1, 3, 5, 6 },
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
};

const Recorder = struct {
    entries: [16]Visit = undefined,
    count: usize = 0,
    stop_after: ?usize = null,
    prune_at: ?NodeId = null,

    pub fn visit(self: *Recorder, event: Visit) !Decision {
        if (self.count == self.entries.len) return error.TooManyFixtureLabels;
        self.entries[self.count] = event;
        self.count += 1;
        if (self.stop_after == self.count) return .stop;
        return if (self.prune_at == event.node) .prune else .expand;
    }
};

test "expansion backtracks on stored dead ends in forward and reverse" {
    const testing = std.testing;
    var edges = fixture.edges[0..6].*;
    edges[4].cls.class_id = 1;
    var classes: [2]graph.class_table.EdgeClass = @splat(std.mem.zeroes(graph.class_table.EdgeClass));
    classes[1].flags.dead_end = true;
    var view = fixture;
    view.edges = &edges;
    view.classes = &classes;
    var arena = memory.Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var engine = try Expansion(FixtureKernel, queue.BucketQueue).init(testing.allocator, &view);
    defer engine.deinit();
    for ([_]core.Direction{ .forward, .reverse }) |direction| {
        var seen: Recorder = .{};
        _ = try engine.run(&arena, .{ .check_dead_ends = true }, .{ .origins = &.{@fromBackingInt(1)}, .direction = direction }, &seen, .{});
        var visited: std.StaticBitSet(edges.len) = .empty;
        for (seen.entries[0..seen.count]) |event| visited.set(event.label.edge);
        try testing.expect(visited.isSet(if (direction == .forward) 5 else 4));
        try testing.expect(!visited.isSet(if (direction == .forward) 0 else 1));
        arena.reset();
    }
}

// Ported from Isochrones.OriginEdge and Isochrones.LongEdge. The contour
// tests belong to the isochrone builder. These assertions check its inputs.
test "bounded expansion mixes node and fractional edge origins" {
    const t = std.testing;
    var counting = memory.CountingAllocator.init(t.allocator);
    var arena = memory.Arena.init(counting.allocator(), .{});
    defer arena.deinit();
    var engine = try Expansion(FixtureKernel, queue.BucketQueue).init(counting.allocator(), &fixture);
    defer engine.deinit();
    var seen: Recorder = .{};
    const request: Request = .{
        .origins = &.{ @fromBackingInt(0), @fromBackingInt(1) },
        .partial_origins = &.{&.{.{ .edge = @fromBackingInt(2), .fraction = 0.5, .score = 0, .begin_node = false, .end_node = false }}},
        .bounds = .{ .distance_m = 80, .cost = 8, .seconds = 4 },
    };
    const stats = try engine.run(&arena, .{}, request, &seen, .{});
    try t.expectEqual(3, stats.settled);
    try t.expectEqual(3, stats.popped);
    try t.expectEqual(3, seen.count);
    try t.expectEqualSlices(u32, &.{ 2, 1, 0 }, &.{
        @backingInt(seen.entries[0].node),
        @backingInt(seen.entries[1].node),
        @backingInt(seen.entries[2].node),
    });
    try t.expectEqual(core.Cut{ .begin = 0.5 }, seen.entries[0].cut);
    for (seen.entries[0..seen.count]) |event| {
        try t.expectEqual(@as(f32, 8), event.label.cost);
        try t.expectEqual(@as(f32, 4), event.label.secs);
        try t.expectEqual(80, event.label.dist_m);
    }

    arena.reset();
    counting.resetCounts();
    seen = .{};
    _ = try engine.run(&arena, .{}, request, &seen, .{});
    try t.expectEqual(0, counting.calls());

    arena.reset();
    seen = .{
        .prune_at = @fromBackingInt(1),
    };
    const pruned = try engine.run(&arena, .{}, .{ .origins = &.{@fromBackingInt(0)} }, &seen, .{});
    try t.expectEqual(1, pruned.settled);
    arena.reset();
    seen = .{ .stop_after = 2 };
    const stopped = try engine.run(&arena, .{}, .{ .origins = &.{@fromBackingInt(0)} }, &seen, .{});
    try t.expectEqual(2, stopped.settled);

    arena.reset();
    seen = .{};
    const Candidate = @import("endpoints.zig").Candidate;
    const inbound: Candidate = .{ .edge = @fromBackingInt(0), .fraction = 1, .score = 0, .begin_node = false, .end_node = true };
    const outbound: Candidate = .{ .edge = @fromBackingInt(2), .fraction = 0, .score = 0, .begin_node = true, .end_node = false };
    const at_node = try engine.run(&arena, .{}, .{
        .partial_origins = &.{ &.{ inbound, outbound }, &.{inbound} },
        .bounds = .{ .distance_m = 0 },
    }, &seen, .{});
    try t.expectEqual(1, at_node.settled);
    try t.expectEqual(@as(f32, 4) * std.math.floatEps(f32), seen.entries[0].label.secs);
    try t.expectEqual(0, seen.entries[0].label.dist_m);

    arena.reset();
    const with_departure = try engine.run(&arena, .{}, .{
        .partial_origins = &.{&.{ inbound, outbound }},
        .bounds = .{ .distance_m = 0 },
    }, {}, .{});
    try t.expectEqual(0, with_departure.settled);

    arena.reset();
    seen = .{};
    var fractional = outbound;
    fractional.fraction = 0.49609375;
    fractional.begin_node = false;
    const under_metres = try engine.run(&arena, .{}, .{
        .partial_origins = &.{&.{fractional}},
        .bounds = .{ .distance_m = 80 },
    }, &seen, .{});
    try t.expectEqual(1, under_metres.settled);
    try t.expectEqual(80, seen.entries[0].label.dist_m);
}

test "fractional origins mirror directed edges and advance the label clock" {
    const t = std.testing;
    var arena = memory.Arena.init(t.allocator, .{});
    defer arena.deinit();
    var engine = try Expansion(FixtureKernel, queue.BucketQueue).init(t.allocator, &fixture);
    defer engine.deinit();
    const departure: core.Timing = .{ .start = .{ .valid = true, .zone = graph.timezone.utc, .unix_time = 1000, .second_of_week = 1000 } };
    const partial = [_]@import("endpoints.zig").Candidate{.{ .edge = @fromBackingInt(2), .fraction = 0.75, .score = 0, .begin_node = false, .end_node = false }};
    const cases = [_]struct { direction: core.Direction, node: NodeId, cut: core.Cut, secs: f32, instant: i64 }{
        .{ .direction = .forward, .node = @fromBackingInt(2), .cut = .{ .begin = 0.75 }, .secs = 2, .instant = 1002 },
        .{ .direction = .reverse, .node = @fromBackingInt(1), .cut = .{ .end = 0.75 }, .secs = 6, .instant = 994 },
    };
    for (cases) |case| {
        var seen: Recorder = .{};
        const stats = try engine.run(&arena, .{}, .{
            .partial_origins = &.{&partial},
            .direction = case.direction,
            .timing = departure,
            .bounds = .{ .seconds = case.secs },
        }, &seen, .{});
        try t.expectEqual(1, stats.settled);
        try t.expectEqual(case.node, seen.entries[0].node);
        try t.expectEqual(case.cut, seen.entries[0].cut);
        try t.expectEqual(case.secs, seen.entries[0].label.secs);
        try t.expectEqual(case.instant, seen.entries[0].time.unix_time);
        arena.reset();
    }

    var seen: Recorder = .{};
    _ = try engine.run(&arena, .{}, .{
        .origins = &.{@fromBackingInt(0)},
        .timing = departure,
        .bounds = .{ .seconds = 15 },
    }, &seen, .{});
    for (seen.entries[0..seen.count]) |event| {
        if (event.node == @as(NodeId, @fromBackingInt(2))) {
            try t.expectEqual(@as(f32, 15), event.label.secs);
            try t.expectEqual(1015, event.time.unix_time);
            return;
        }
    }
    return error.MissingTimedLabel;
}
