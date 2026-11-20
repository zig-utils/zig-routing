// Ported from src/sif/autocost.cc (Valhalla 3.9.3).
const std = @import("std");
const base = @import("base.zig");
const compiled = @import("compiled.zig");
const graph = @import("../graph/root.zig");
const json = @import("../api/json.zig");
const Deadline = @import("../infra/io.zig").Deadline;

const EdgeClass = graph.class_table.EdgeClass;
const NodeHot = graph.format.NodeHot;
const EdgeHot = graph.format.EdgeHot;
const AccessMask = graph.constants.AccessMask;
const Restriction = graph.cold.access_restriction.Entry;
const Cost = compiled.Cost;
const Use = graph.constants.Use;
const Surface = graph.constants.Surface;

pub const Mode = enum {
    auto,
    bus,
    taxi,

    fn access(self: Mode) AccessMask {
        return switch (self) {
            .auto => .{ .auto = true, .hov = true },
            .bus => .{ .bus = true },
            .taxi => .{ .taxi = true },
        };
    }
};

const assumed_speed = 140;
const highest_speed = base.fixed_speed_max;
const alley_range: base.Range = .factor(1);
const auto_config: base.Config = blk: {
    var config: base.Config = .{};
    config.ranges.set(.service_penalty, .penalty(75));
    config.ranges.set(.use_tracks, .preference(0));
    break :blk config;
};

pub const Options = struct {
    mode: Mode,
    shared: base.Options,
    alley_factor: f32,
    use_highways: f32,
    use_tolls: f32,
    restriction_probability: u8,
    top_speed: u8,
    filter_closures: bool = false,
    min_linear_factor: f32 = 1,
    may_allow_edges: bool = false,
};

pub fn parse(arena: std.mem.Allocator, mode: Mode, input: json.Value, warnings: *std.ArrayList(base.Warning), deadline: Deadline) !Options {
    return .{
        .mode = mode,
        .shared = try base.parse(arena, input, auto_config, warnings, deadline),
        .alley_factor = try base.rangedFloat(arena, input, "alley_factor", alley_range, warnings),
        .use_highways = try base.rangedFloat(arena, input, "use_highways", .preference(0.5), warnings),
        .use_tolls = try base.rangedFloat(arena, input, "use_tolls", .preference(0.5), warnings),
        .restriction_probability = @intCast(try base.rangedUnsigned(arena, input, "restriction_probability", 100, 100, warnings)),
        .top_speed = @intCast(try base.rangedUnsignedIn(arena, input, "top_speed", 10, assumed_speed, highest_speed, warnings)),
    };
}

const speed_factors: [highest_speed + 1]f32 = blk: {
    var factors: [highest_speed + 1]f32 = undefined;
    factors[0] = 3600;
    for (factors[1..], 1..) |*factor, speed| {
        factor.* = (3600.0 * @as(f32, 0.001)) / @as(f32, @floatFromInt(speed));
    }
    break :blk factors;
};

const highway_class = [8]f32{ 1, 0.5, 0, 0, 0, 0, 0, 0 };
const surface_weight = [8]f32{ 0, 0, 0, 0.1, 0.2, 0.5, 1, 0 };
const taxi_factor: f32 = 0.85;
const turn_channel_factor: f32 = 0.6;

pub const Profile = struct {
    mode: Mode,
    shared: base.Shared,
    permission: base.Permission,
    highway_bias: [8]f32,
    toll_bias: f32,
    alley_factor: f32,
    top_speed: u8,
    fixed_speed: u8,
    restriction_probability: u8,
    dimensions: Dimensions,
    min_linear_factor: f32,
    may_allow_edges: bool,

    pub fn allowedNode(self: *const Profile, node: *const NodeHot) bool {
        return self.permission.allowedNode(node);
    }

    pub fn allowedCandidate(self: *const Profile, class: *const EdgeClass, state: base.EdgeState, disallow: base.Disallow, allowed_by_linear_feature: bool) bool {
        if (allowed_by_linear_feature) return true;
        if (state.closed and self.permission.flow.current and (self.permission.filter_closures or disallow.closure)) return false;
        var open = state;
        open.closed = false;
        return self.permission.allowedEdge(class, open, disallow) and !class.flags.bike_share_connection and self.hovAllowed(class);
    }

    pub fn astarCostFactor(self: *const Profile) f32 {
        return speed_factors[self.top_speed] * self.min_linear_factor;
    }

    /// Valhalla's speed selection without a time of week or live speed.
    pub fn untimedSpeed(self: *const Profile, edge: EdgeHot) Speed {
        if (self.fixed_speed != 0) return .{ .kph = self.fixed_speed, .non_current_kph = self.fixed_speed };
        if (self.permission.flow.constrained and edge.speed[2] != 0)
            return .{ .kph = edge.speed[2], .non_current_kph = edge.speed[2], .sources = .{ .constrained = true } };
        if (self.permission.flow.freeflow and edge.speed[1] != 0)
            return .{ .kph = edge.speed[1], .non_current_kph = edge.speed[1], .sources = .{ .freeflow = true } };
        return .{ .kph = edge.speed[0], .non_current_kph = edge.speed[0] };
    }

    fn hovAllowed(self: *const Profile, class: *const EdgeClass) bool {
        const flags = self.permission.flags;
        return !class.isHovOnly() or flags.contains(.include_hov3) or
            (flags.contains(.include_hov2) and !class.flags.hov3) or
            (flags.contains(.include_hot) and class.flags.toll);
    }

    fn pathClassAllowed(self: *const Profile, class: *const EdgeClass) bool {
        return class.category.surface != @backingInt(Surface.impassable) and
            self.permission.accessibleClass(class) and self.hovAllowed(class);
    }

    pub fn useFactor(self: *const Profile, class: *const EdgeClass, measured: bool) f32 {
        return switch (class.category.use) {
            @backingInt(Use.alley) => self.alley_factor,
            @backingInt(Use.track) => self.shared.tracks.factor,
            @backingInt(Use.living_street) => self.shared.living_streets.factor,
            @backingInt(Use.service_road) => self.shared.service_factor,
            @backingInt(Use.turn_channel) => if (measured and self.mode != .taxi) turn_channel_factor else 1,
            else => 1,
        };
    }

    fn classWeight(self: *const Profile, class: *const EdgeClass, speed_penalty: f32) f32 {
        const use = class.category.use;
        const density = base.density_factor[class.category.density];
        const weight = if (use == @backingInt(Use.ferry)) self.shared.ferry_factor else density;
        if (self.mode == .taxi) {
            const access = class.forwardAccess();
            return (weight + speed_penalty) * (if (access.taxi and !access.auto) taxi_factor else @as(f32, 1));
        }
        const starting = if (use == @backingInt(Use.rail_ferry)) self.shared.rail_ferry_factor else weight;
        const surface = 0.5 * surface_weight[class.category.surface];
        const toll = if (class.flags.toll) self.toll_bias else 0;
        return starting + (self.highway_bias[class.category.road_class] + surface + speed_penalty + toll);
    }
};

pub const Dimensions = struct {
    height: f32,
    width: f32,
    length: f32,
    weight: f32,

    pub fn allowed(self: Dimensions, limit: Restriction) bool {
        const measured: f32 = switch (limit.attr.kind) {
            .maxheight => self.height,
            .maxwidth => self.width,
            .maxlength => self.length,
            .maxweight => self.weight,
            else => return true,
        };
        const hundredths: f64 = @floatFromInt(limit.value);
        return measured <= @as(f32, @floatCast(hundredths * 0.01));
    }
};

const RequestOptions = Options;
pub const Model = struct {
    pub const Options = RequestOptions;
    pub const Canonical = Profile;

    pub fn canonicalize(options: RequestOptions) !Profile {
        for (options.shared.floats.values, auto_config.ranges.values) |value, range| {
            if (!(range.min <= value and value <= range.max)) return error.InvalidAutoOptions;
        }
        for ([_]f32{ options.use_highways, options.use_tolls, options.min_linear_factor }) |value| {
            if (!(0 <= value and value <= 1)) return error.InvalidAutoOptions;
        }
        if (!(alley_range.min <= options.alley_factor and options.alley_factor <= alley_range.max) or
            options.top_speed < 10 or options.top_speed > highest_speed or options.shared.fixed_speed > highest_speed or
            options.restriction_probability > 100) return error.InvalidAutoOptions;
        const highways = options.use_highways;
        const highway_bias = if (highways >= 0.5) bias: {
            const f: f32 = 0.5 - highways;
            break :bias f * f * f;
        } else bias: {
            const f: f32 = 1 - highways * 2;
            break :bias 8 * (f * f);
        };
        const tolls = options.use_tolls;
        const toll_bias = if (tolls < 0.5) 4 - 8 * tolls else (0.5 - tolls) * 0.03;
        var highway: [8]f32 = undefined;
        for (&highway, highway_class) |*adjustment, class| adjustment.* = highway_bias * class;
        return .{
            .mode = options.mode,
            .shared = .init(options.shared),
            .permission = .init(options.shared, options.mode.access(), options.filter_closures),
            .highway_bias = highway,
            .toll_bias = toll_bias,
            .alley_factor = options.alley_factor,
            .top_speed = if (options.shared.fixed_speed != 0) @intCast(options.shared.fixed_speed) else options.top_speed,
            .fixed_speed = @intCast(options.shared.fixed_speed),
            .restriction_probability = options.restriction_probability,
            .dimensions = .{
                .height = options.shared.value(.height),
                .width = options.shared.value(.width),
                .length = options.shared.value(.length),
                .weight = options.shared.value(.weight),
            },
            .min_linear_factor = options.min_linear_factor,
            .may_allow_edges = options.may_allow_edges,
        };
    }

    pub fn rules(profile: Profile) !compiled.Rules {
        var hash = std.crypto.hash.Blake3.init(.{});
        hash.update("auto");
        hash.update(&.{ @backingInt(profile.mode), profile.top_speed, profile.fixed_speed, @intFromBool(profile.shared.shortest) });
        const factors = [_]f32{
            profile.shared.time_weight,          profile.shared.distance_weight,       profile.shared.service_factor,
            profile.shared.tracks.factor,        profile.shared.living_streets.factor, profile.alley_factor,
            profile.shared.speed_penalty_factor, profile.shared.closure_factor,        profile.min_linear_factor,
        };
        hash.update(std.mem.asBytes(&factors));
        var key: compiled.MetricKey = undefined;
        hash.final(&key);
        const minimum_use = @min(1, profile.alley_factor, profile.shared.tracks.factor, profile.shared.living_streets.factor, profile.shared.service_factor, if (profile.mode == .taxi) 1 else turn_channel_factor);
        var speeds: [256]f32 = undefined;
        speeds[0] = std.math.inf(f32);
        for (speeds[1..], 1..) |*factor, speed| {
            const effective = if (profile.fixed_speed != 0) profile.fixed_speed else @min(speed, profile.top_speed);
            factor.* = speed_factors[effective];
        }
        return .{
            .seconds_per_metre = speeds,
            .floors = .{ .edge_factor = if (profile.shared.shortest) 0 else minimum_use * profile.shared.time_weight * profile.min_linear_factor, .turn_factor = 0 },
            .node_access_mask = if (profile.permission.flags.contains(.ignore_access)) 0 else @bitCast(profile.permission.access_mask),
            .model_metric_key = key,
        };
    }

    pub fn classFactor(profile: Profile, class: EdgeClass) !f32 {
        if (class.category.surface == @backingInt(Surface.impassable) or
            (!profile.may_allow_edges and !profile.pathClassAllowed(&class))) return std.math.inf(f32);
        return if (profile.shared.shortest) 1 else profile.classWeight(&class, 0);
    }
};

pub const Cache = compiled.Cache(Model);

pub const PathCheck = struct {
    allowed_by_linear_feature: bool = false,
    avoided: bool = false,
    backtrack: bool = false,
    previous_dead_end: bool = false,
    closed: bool = false,
    closure_pruning: bool = false,
    allow_destination_only: bool = true,
    previous_access: base.AccessState = .{},
    limits: []align(1) const Restriction = &.{},
    original_forward: bool = true,
    time: ?graph.datetime.Local = null,
};

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

pub const Kernel = struct {
    /// Retain a turn onto a short internal edge for the next transition.
    pub fn internalTurn(node: *const NodeHot, class: *const EdgeClass, edge: EdgeHot, turn: base.Turn) InternalTurn {
        if (!class.flags.internal or edge.geom.len_m > 8) return .none;
        const kind = turn.kind();
        if (node.attr.drive_on_left) return if (kind == 2 or kind == 3) .right else .none;
        return if (kind == 5 or kind == 6) .left else .none;
    }

    /// Edges are supplied in travel order for both search directions.
    pub fn allowed(profile: *const Profile, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck, deadline: Deadline) !base.AccessEvaluation {
        return allowedPath(true, profile, from, to, turn, check, deadline);
    }

    pub fn allowedReverse(profile: *const Profile, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck, deadline: Deadline) !base.AccessEvaluation {
        return allowedPath(false, profile, from, to, turn, check, deadline);
    }

    fn allowedPath(comptime forward: bool, profile: *const Profile, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck, deadline: Deadline) !base.AccessEvaluation {
        if (check.allowed_by_linear_feature) return .{ .state = check.previous_access };
        const candidate = if (forward) to else from;
        const previous = if (forward) from else to;
        var permission = profile.permission;
        permission.allow_destination_only = check.allow_destination_only;
        const flags = permission.flags;
        const allow_turn = if (forward and profile.mode == .bus)
            !turn.restricted() or flags.contains(.ignore_restrictions)
        else
            permission.allowsTurnRestriction(turn);
        const previous_destination = previous.flags.destination_only or check.previous_access.destination_only;
        const compacted = @backingInt(Surface.compacted);
        if (!profile.pathClassAllowed(candidate) or (check.backtrack and !check.previous_dead_end) or !allow_turn or check.avoided or
            (!permission.allow_destination_only and !previous_destination and candidate.flags.destination_only) or
            (check.closure_pruning and check.closed and permission.usesClosures()) or
            (flags.contains(.exclude_unpaved) and previous.category.surface < compacted and candidate.category.surface >= compacted) or
            !permission.allowedExclusions(from, to)) return .{ .allowed = false };

        var previous_access = check.previous_access;
        previous_access.destination_only = previous_destination;
        var result = try permission.evaluateRestrictions(check.limits, check.original_forward, check.time, previous_access, profile.dimensions, deadline);
        result.state.destination_only = result.state.destination_only or candidate.flags.destination_only;
        return result;
    }

    pub fn edgeCost(profile: *const Profile, tables: *const compiled.Compiled, class: *const EdgeClass, edge: EdgeHot, speed: Speed, effects: compiled.Effects) Cost {
        const static_weight = tables.factor(edge.cls.class_id);
        if (effects.forbidden or static_weight == std.math.inf(f32)) return .forbidden;
        const kph = if (profile.fixed_speed == 0) speed.kph else profile.fixed_speed;
        const length: f32 = @floatFromInt(edge.geom.len_m);
        const secs = length * (if (kph == 0) speed_factors[0] else tables.seconds_per_metre[kph]);
        if (profile.shared.shortest) return .{ .cost = length, .secs = secs };
        const expected = if (profile.top_speed != assumed_speed and speed.sources.current) speed.non_current_kph else kph;
        const excess: f32 = @floatFromInt(expected -| profile.top_speed);
        const speed_penalty = excess * profile.shared.speed_penalty_factor;
        const weight = if (speed_penalty == 0) static_weight else profile.classWeight(class, speed_penalty);
        const measured = @as(u8, @bitCast(speed.sources)) & @as(u8, @bitCast(base.Flow.all)) != 0;
        var factor = weight * profile.useFactor(class, measured);
        const closure: f32 = if (speed.closed and profile.permission.usesClosures()) profile.shared.closure_factor else 1;
        std.debug.assert(std.math.isFinite(effects.factor) and effects.factor >= profile.min_linear_factor);
        if (profile.mode == .taxi) {
            factor *= closure;
            factor *= effects.factor;
        } else {
            factor *= effects.factor;
            factor *= closure;
        }
        const cost = (secs * profile.shared.time_weight + length * profile.shared.distance_weight) * factor;
        return (Cost{ .cost = @min(cost, std.math.floatMax(f32)), .secs = secs }).add(effects.penalty);
    }

    pub fn edgeLowerBound(profile: *const Profile, tables: *const compiled.Compiled, class: *const EdgeClass, edge: EdgeHot, upper_kph: u8) compiled.Tick {
        const factor = tables.factor(edge.cls.class_id);
        if (factor == std.math.inf(f32)) return compiled.forbidden_tick;
        const length: f64 = @floatFromInt(edge.geom.len_m);
        if (profile.shared.shortest) return compiled.floorTicks(length);
        const maximum = if (profile.fixed_speed != 0) profile.fixed_speed else if (upper_kph == 0) profile.top_speed else upper_kph;
        const secs = length * tables.seconds_per_metre[maximum];
        const units = secs * profile.shared.time_weight + length * profile.shared.distance_weight;
        const weight = @as(f64, factor) * profile.useFactor(class, true) * profile.min_linear_factor;
        return compiled.floorTicks(@min(units * weight, std.math.floatMax(f32)));
    }

    pub fn turnLowerBound() compiled.Tick {
        return 0;
    }

    pub fn turnCost(profile: *const Profile, node: *const NodeHot, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) Cost {
        if (from.flags.node_connector or to.flags.node_connector) return .{};
        const entry = turn.movement.base_turn;
        var result = profile.shared.transition(node, from, to, entry);
        result.secs += carTurnDuration(node, turn.degrees, turn.more_than_two_roads);
        const impact: f32 = @floatFromInt(entry.stopImpact());
        const kind = entry.kind();
        const sides = turn.movement.sides;
        const drive_left = node.attr.drive_on_left;
        if (impact > 0 and !profile.shared.shortest) {
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
            result.cost += seconds;
        }
        result.cost *= profile.shared.time_weight;
        return result;
    }

    pub fn turnCostReverse(profile: *const Profile, node: *const NodeHot, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) Cost {
        return turnCost(profile, node, from, to, turn);
    }
};

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

fn carTurnDuration(node: *const NodeHot, degrees: u16, more_than_two_roads: bool) f32 {
    std.debug.assert(degrees < 360);
    const reverse = degrees >= 160 and degrees <= 200;
    var duration: f64 = if (node.attr.signal != 0) 2 else 0;
    if (more_than_two_roads or reverse) duration += car_turn_duration[@intFromBool(node.attr.drive_on_left)][degrees];
    if (reverse) duration += 20;
    return @floatCast(duration);
}

// Ported from the INLINE_TEST AutoCost parameter cases.
test "auto parses default service and track preferences and bounds the new options" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const defaults = try parse(arena, .auto, .null, &warnings, .none);
    try std.testing.expectEqual(75, defaults.shared.value(.service_penalty));
    try std.testing.expectEqual(0, defaults.shared.value(.use_tracks));
    try std.testing.expectEqual(140, defaults.top_speed);
    try std.testing.expectEqual(0, warnings.items.len);

    const input = try json.parse(arena,
        \\{"alley_factor":0,"use_highways":1.1,"use_tolls":-0.1,"restriction_probability":101,"top_speed":9}
    );
    const clamped = try parse(arena, .auto, input, &warnings, .none);
    try std.testing.expectEqual(1, clamped.alley_factor);
    try std.testing.expectEqual(0.5, clamped.use_highways);
    try std.testing.expectEqual(0.5, clamped.use_tolls);
    try std.testing.expectEqual(100, clamped.restriction_probability);
    try std.testing.expectEqual(140, clamped.top_speed);
    try std.testing.expectEqual(5, warnings.items.len);
    const fixed = try parse(arena, .auto, try json.parse(arena, "{\"fixed_speed\":184,\"top_speed\":137}"), &warnings, .none);
    const profile = try Model.canonicalize(fixed);
    try std.testing.expectEqual(184, profile.top_speed);
    try std.testing.expectEqual(speed_factors[184], profile.astarCostFactor());
}

test "auto and bus favor measured turn channels while taxi favors taxi-only streets" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const channel: EdgeClass = .{
        .category = .{ .use = @backingInt(Use.turn_channel), .road_class = @backingInt(graph.constants.RoadClass.primary) },
        .access = .{ .forward = @bitCast(@as(AccessMask, .{ .auto = true, .bus = true, .taxi = true })) },
    };
    var taxi_only = channel;
    taxi_only.access.forward = @bitCast(@as(AccessMask, .{ .taxi = true }));
    const edge: EdgeHot = .{
        .head = 0,
        .geom = .{ .len_m = 100, .grade = 6, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = .{ 30, 50, 25, 0 },
    };
    for ([_]Mode{ .auto, .bus, .taxi }) |mode| {
        const profile = try Model.canonicalize(try parse(arena, mode, .null, &warnings, .none));
        const class = if (mode == .taxi) taxi_only else channel;
        var factors: [1]f32 = undefined;
        const tables = try compiled.compileInto(Model, profile, &.{class}, &factors, .none);
        const measured = profile.untimedSpeed(edge);
        try std.testing.expect(measured.sources.constrained);
        const cost = Kernel.edgeCost(&profile, &tables, &class, edge, measured, .{});
        const weighting: f32 = if (mode == .taxi) 0.85 else 0.6;
        try std.testing.expectApproxEqAbs(@as(f32, 14.4), cost.secs, 0.00001);
        try std.testing.expectApproxEqAbs(cost.secs * (0.85 * weighting), cost.cost, 0.00001);
        try std.testing.expect(compiled.costUnits(Kernel.edgeLowerBound(&profile, &tables, &class, edge, 50)) <= cost.cost);
    }
}

test "HOV variants and bus forward restrictions follow the selected mode" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const highway: EdgeClass = .{
        .category = .{ .road_class = @backingInt(graph.constants.RoadClass.motorway) },
        .access = .{ .forward = @bitCast(@as(AccessMask, .{ .hov = true, .bus = true })) },
        .flags = .{ .hov3 = true, .toll = true },
    };
    const defaults = try Model.canonicalize(try parse(arena, .auto, .null, &warnings, .none));
    try std.testing.expect(!defaults.allowedCandidate(&highway, .{}, .{}, false));
    const options = try json.parse(arena, "{\"include_hov2\":true,\"include_hot\":true,\"ignore_non_vehicular_restrictions\":true}");
    const profile = try Model.canonicalize(try parse(arena, .bus, options, &warnings, .none));
    try std.testing.expect(profile.allowedCandidate(&highway, .{}, .{}, false));
    const restricted: base.Turn = .{ .row = 0x80 };
    try std.testing.expect(!(try Kernel.allowed(&profile, &highway, &highway, restricted, .{}, .none)).allowed);
    try std.testing.expect((try Kernel.allowedReverse(&profile, &highway, &highway, restricted, .{}, .none)).allowed);
}
