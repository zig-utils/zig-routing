// Ported from src/sif/autocost.cc, src/sif/truckcost.cc and valhalla/sif/osrm_car_duration.h (Valhalla 3.9.3).
const std = @import("std");
const base = @import("base.zig");
const Cost = @import("compiled.zig").Cost;
const graph = @import("../graph/root.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const EdgeClass = graph.class_table.EdgeClass;
const NodeHot = graph.format.NodeHot;
const EdgeHot = graph.format.EdgeHot;
const Use = graph.constants.Use;
const highest_speed = base.fixed_speed_max;
pub const assumed_speed = 140;
// Scooter grade factors can raise a fixed speed by up to 25 percent.
const highest_effective_speed = highest_speed * 5 / 4;

pub const speed_factors: [highest_effective_speed + 1]f32 = blk: {
    var factors: [highest_effective_speed + 1]f32 = undefined;
    factors[0] = 3600;
    for (factors[1..], 1..) |*factor, speed| {
        factor.* = (3600.0 * @as(f32, 0.001)) / @as(f32, @floatFromInt(speed));
    }
    break :blk factors;
};

const highway_class = [8]f32{ 1, 0.5, 0, 0, 0, 0, 0, 0 };
pub const surface_weight = [8]f32{ 0, 0, 0, 0.1, 0.2, 0.5, 1, 0 };
pub fn highwayBias(use_highways: f32) [8]f32 {
    const bias = if (use_highways >= 0.5) preference: {
        const f: f32 = 0.5 - use_highways;
        break :preference f * f * f;
    } else preference: {
        const f: f32 = 1 - use_highways * 2;
        break :preference 8 * (f * f);
    };
    var adjustments: [8]f32 = undefined;
    for (&adjustments, highway_class) |*value, class| value.* = bias * class;
    return adjustments;
}

pub fn tollBias(use_tolls: f32, comptime max_penalty: f32) f32 {
    return if (use_tolls < 0.5) max_penalty - 2 * max_penalty * use_tolls else (0.5 - use_tolls) * 0.03;
}

pub fn compileSpeeds(top_speed: u8, fixed_speed: u8) [256]f32 {
    var speeds: [256]f32 = undefined;
    speeds[0] = std.math.inf(f32);
    for (speeds[1..], 1..) |*factor, speed| {
        const effective = if (fixed_speed != 0) fixed_speed else @min(speed, top_speed);
        factor.* = speed_factors[effective];
    }
    return speeds;
}

pub fn untimedSpeed(flow: base.Flow, edge: EdgeHot, fixed_speed: u8, comptime truck: bool) Speed {
    if (fixed_speed != 0) return .{ .kph = fixed_speed, .non_current_kph = fixed_speed };
    const speed = graph.speed.untimed(edge, flow, truck);
    return .{ .kph = speed.kph, .non_current_kph = speed.kph, .sources = speed.sources };
}

pub fn resolvedSpeed(profile: anytype, edge: EdgeHot, id: graph.format.EdgeId, comptime truck: bool, time: ?graph.speed.Time, overlays: anytype) Speed {
    const flow = profile.permission.flow;
    if (profile.fixed_speed != 0) {
        const closed = if (flow.current) if (overlays.live(id)) |live| live.closed() else false else false;
        return .{ .kph = profile.fixed_speed, .non_current_kph = profile.fixed_speed, .closed = closed };
    }
    const speed = graph.speed.resolve(edge, id, .{ .flow = flow, .time = time, .truck = truck }, overlays);
    var non_current = speed.kph;
    if (speed.sources.current and profile.top_speed != assumed_speed) {
        var static_flow = flow;
        static_flow.current = false;
        non_current = graph.speed.resolve(edge, id, .{ .flow = static_flow, .time = time }, overlays).kph;
    }
    return .{ .kph = speed.kph, .non_current_kph = non_current, .sources = speed.sources, .closed = speed.closed };
}

/// Resolved speed and its source bits. The non-current value is used for
/// the optional top-speed penalty when live traffic supplied the speed.
pub const Speed = struct {
    kph: u8,
    non_current_kph: u8,
    sources: base.Flow = .{},
    closed: bool = false,
};

pub fn speedPenalty(top_speed: u8, factor: f32, kph: u8, speed: Speed) f32 {
    const expected = if (top_speed != assumed_speed and speed.sources.current) speed.non_current_kph else kph;
    const excess: f32 = @floatFromInt(expected -| top_speed);
    return excess * factor;
}

pub const InternalTurn = enum { none, left, right };

pub const PathCheck = struct {
    allowed_by_linear_feature: bool = false,
    avoided: bool = false,
    backtrack: bool = false,
    previous_dead_end: bool = false,
    closed: bool = false,
    closure_pruning: bool = false,
    allow_destination_only: bool = true,
    previous_access: base.AccessState = .{},
    limits: []align(1) const graph.cold.access_restriction.Entry = &.{},
    original_forward: bool = true,
    time: ?graph.datetime.Local = null,
};

pub fn roadUseFactor(shared: *const base.Shared, use: u6) f32 {
    return switch (use) {
        @backingInt(Use.track) => shared.tracks.factor,
        @backingInt(Use.living_street) => shared.living_streets.factor,
        @backingInt(Use.service_road) => shared.service_factor,
        else => 1,
    };
}

pub const Turn = struct {
    movement: base.IntersectionTurn,
    degrees: u16,
    more_than_two_roads: bool,
    measured_speed: bool = false,
    internal_turn: InternalTurn = .none,

    pub fn read(view: *const graph.reader.View, node: graph.format.NodeId, incoming: graph.format.EdgeId, outgoing: graph.format.EdgeId, arena: std.mem.Allocator, deadline: Deadline) !Turn {
        const movement = try base.IntersectionTurn.read(view, node, incoming, outgoing);
        const range = try view.outEdgeRange(node);
        const opposing = try view.oppEdge(incoming);
        return readGeometry(view, range, opposing, outgoing, movement, arena, deadline);
    }

    /// Price a movement whose local turn row has already been read by search.
    pub fn fromRow(view: *const graph.reader.View, node: graph.format.NodeId, from: u5, to: u5, row: graph.format.TurnEntry, arena: std.mem.Allocator, deadline: Deadline) !Turn {
        const range = try view.outEdgeRange(node);
        const movement: base.IntersectionTurn = .{
            .base_turn = .{ .row = row },
            .sides = try view.turnSidesAtDegree(node, range.count(), from, to),
        };
        return readGeometry(view, range, @fromBackingInt(range.first + from), @fromBackingInt(range.first + to), movement, arena, deadline);
    }

    fn readGeometry(view: *const graph.reader.View, range: graph.reader.View.EdgeRange, opposing: graph.format.EdgeId, outgoing: graph.format.EdgeId, movement: base.IntersectionTurn, arena: std.mem.Allocator, deadline: Deadline) !Turn {
        const approach = (try heading(view, opposing, arena, deadline) + 180) % 360;
        const departure = try heading(view, outgoing, arena, deadline);
        return .{
            .movement = movement,
            .degrees = (departure + 360 - approach) % 360,
            .more_than_two_roads = range.count() > 2 or (try view.class(view.edges[range.end - 1].cls.class_id)).flags.node_connector,
        };
    }

    fn heading(view: *const graph.reader.View, id: graph.format.EdgeId, arena: std.mem.Allocator, deadline: Deadline) !u16 {
        if (view.headings) |headings| return graph.headings.decode(headings[@backingInt(id)]);
        const edge = try view.edge(id);
        const class = try view.class(edge.cls.class_id);
        if (class.flags.node_connector) return 0;
        const points = try view.shapeWithDeadline(id, arena, deadline);
        defer arena.free(points);
        return graph.headings.decode(graph.headings.encode(try graph.headings.sample(points, true, class, deadline)));
    }
};

const right_turn_cost = [8]f32{ 0.5, 0.75, 1, 1.5, 9.5, 3.5, 2.5, 0.75 };
const left_turn_cost = [8]f32{ 0.5, 0.75, 2.5, 3.5, 9.5, 1.5, 1, 0.75 };

/// Retain a turn onto a short internal edge for the next transition.
pub fn internalTurn(node: *const NodeHot, class: *const EdgeClass, edge: EdgeHot, turn: base.Turn) InternalTurn {
    if (!class.flags.internal or edge.geom.len_m > 8) return .none;
    const kind = turn.kind();
    if (node.attr.drive_on_left) return if (kind == 2 or kind == 3) .right else .none;
    return if (kind == 5 or kind == 6) .left else .none;
}

pub fn turnPenalty(node: *const NodeHot, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) f32 {
    const entry = turn.movement.base_turn;
    const impact: f32 = @floatFromInt(entry.stopImpact());
    if (impact == 0) return 0;
    const kind = entry.kind();
    const sides = turn.movement.sides;
    const drive_left = node.attr.drive_on_left;
    var seconds: f32 = if (sides.left and sides.right) 2 else if (drive_left) left_turn_cost[kind] else right_turn_cost[kind];
    const ramp = @backingInt(Use.ramp);
    if ((from.category.use == ramp) != (to.category.use == ramp)) {
        seconds += 1.5;
        if (to.flags.roundabout) seconds += 0.5;
    }
    const left = kind == 5 or kind == 6;
    const right = kind == 2 or kind == 3;
    const reverse = kind == 4;
    const is_turn = left or right or reverse;
    if (is_turn) seconds *= impact;
    if (reverse and !entry.nameConsistent()) {
        seconds += 10;
    } else if (reverse or (if (drive_left) turn.internal_turn == .right and right else turn.internal_turn == .left and left)) {
        seconds += 600;
    } else if (to.flags.named and entry.nameConsistent() and
        (if (drive_left) kind == 3 and sides.left and !sides.right else kind == 5 and sides.right and !sides.left))
    {
        seconds *= 15;
    }
    if (!turn.measured_speed) {
        if (!is_turn) seconds *= impact;
        seconds *= base.transition_density_factor[node.attr.density];
    }
    return seconds;
}

// Ported from valhalla/sif/osrm_car_duration.h.
const car_turn_duration = blk: {
    @setEvalBranchQuota(5000);
    var result: [2][360]f64 = undefined;
    const bias: f64 = 1.075;
    for (&result, 0..) |*table, side| {
        for (table, 0..) |*duration, angle| {
            const symmetric: i32 = @as(i32, @intCast(angle)) - if (angle > 180) @as(i32, 360) else 0;
            const near_side = (symmetric >= 0) == (side == 1);
            const multiplier = if (near_side) bias else 1 / bias;
            const offset = if (near_side) 1 / bias else bias;
            const degrees: f64 = @floatFromInt(@abs(symmetric));
            duration.* = 7.5 / (1 + @exp(-((13 * multiplier) * degrees / 180 - 6.5 * offset)));
        }
    }
    break :blk result;
};

pub fn carTurnDuration(node: *const NodeHot, degrees: u16, more_than_two_roads: bool) f32 {
    std.debug.assert(degrees < 360);
    const reverse = degrees >= 160 and degrees <= 200;
    var duration: f64 = if (node.attr.signal != 0) 2 else 0;
    if (more_than_two_roads or reverse) duration += car_turn_duration[@intFromBool(node.attr.drive_on_left)][degrees];
    if (reverse) duration += 20;
    return @floatCast(duration);
}

pub fn turnCost(shared: *const base.Shared, node: *const NodeHot, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) Cost {
    if (from.flags.node_connector or to.flags.node_connector) return .{};
    var result = shared.transition(node, from, to, turn.movement.base_turn);
    result.secs += carTurnDuration(node, turn.degrees, turn.more_than_two_roads);
    if (!shared.shortest) result.cost += turnPenalty(node, from, to, turn);
    result.cost *= shared.time_weight;
    return result;
}
