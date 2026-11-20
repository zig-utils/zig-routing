// Ported from src/sif/autocost.cc, src/sif/truckcost.cc and valhalla/sif/osrm_car_duration.h (Valhalla 3.9.3).
const std = @import("std");
const base = @import("base.zig");
const graph = @import("../graph/root.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const EdgeClass = graph.class_table.EdgeClass;
const NodeHot = graph.format.NodeHot;
const EdgeHot = graph.format.EdgeHot;
const Use = graph.constants.Use;
const highest_speed = base.fixed_speed_max;

pub const speed_factors: [highest_speed + 1]f32 = blk: {
    var factors: [highest_speed + 1]f32 = undefined;
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
    if (flow.constrained and edge.speed[2] != 0)
        return .{ .kph = edge.speed[2], .non_current_kph = edge.speed[2], .sources = .{ .constrained = true } };
    if (flow.freeflow and edge.speed[1] != 0)
        return .{ .kph = edge.speed[1], .non_current_kph = edge.speed[1], .sources = .{ .freeflow = true } };
    const kph = if (truck and edge.speed[3] != 0) @min(edge.speed[0], edge.speed[3]) else edge.speed[0];
    return .{ .kph = kph, .non_current_kph = kph };
}

/// Resolved speed and its source bits. The non-current value is used for
/// the optional top-speed penalty when live traffic supplied the speed.
pub const Speed = struct {
    kph: u8,
    non_current_kph: u8,
    sources: base.Flow = .{},
    closed: bool = false,
};

pub const InternalTurn = enum { none, left, right };

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
        const approach = (try heading(view, opposing, arena, deadline) + 180) % 360;
        const departure = try heading(view, outgoing, arena, deadline);
        const last = try view.edge(@fromBackingInt(range.end - 1));
        return .{
            .movement = movement,
            .degrees = (departure + 360 - approach) % 360,
            .more_than_two_roads = range.count() > 2 or (try view.class(last.cls.class_id)).flags.node_connector,
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
