// Ported from src/sif/motorcyclecost.cc and src/sif/motorscootercost.cc (Valhalla 3.9.3).
const std = @import("std");
const base = @import("base.zig");
const compiled = @import("compiled.zig");
const motor = @import("motor.zig");
const graph = @import("../graph/root.zig");
const json = @import("../api/json.zig");
const Deadline = @import("../infra/io.zig").Deadline;

const EdgeClass = graph.class_table.EdgeClass;
const EdgeHot = graph.format.EdgeHot;
const NodeHot = graph.format.NodeHot;
const Use = graph.constants.Use;
const Surface = graph.constants.Surface;
const AccessMask = graph.constants.AccessMask;
const Cost = compiled.Cost;
const ferry = @backingInt(Use.ferry);

pub const Mode = enum {
    motorcycle,
    motor_scooter,

    fn access(self: Mode) AccessMask {
        return switch (self) {
            .motorcycle => .{ .motorcycle = true },
            .motor_scooter => .{ .moped = true },
        };
    }

    fn maximumSurface(self: Mode) Surface {
        return if (self == .motor_scooter) .dirt else .impassable;
    }

    fn optionsConfig(self: Mode) base.Config {
        var result: base.Config = .{ .disable_rail_ferry = true };
        if (self == .motor_scooter) {
            result.disable_toll_booth = true;
            result.ranges.set(.destination_only_penalty, .penalty(120));
        }
        return result;
    }
};

const scooter_road_factor = [8]f32{ 1, 0.5, 0.2, 0.1, 0.05, 0.05, 0, 0.5 };
const scooter_hill_penalty = [16]f32{ 1, 0.8, 0.5, 0.2, 0.1, 0, 0.05, 0.1, 0.3, 0.8, 2, 3, 4.5, 6, 8, 10 };
const scooter_grade_speed = [16]f32{ 1.25, 1.2, 1.15, 1.1, 1.05, 1, 1, 1, 0.95, 0.75, 0.6, 0.5, 0.45, 0.4, 0.35, 0.25 };
const scooter_surface_speed = [8]f32{ 1, 1, 0.9, 0.6, 0.1, 0, 0, 0 };
const scooter_destination_factor: f32 = 0.2;

pub const Options = struct {
    mode: Mode,
    shared: base.Options,
    top_speed: u8,
    use_highways: f32 = 0.5,
    use_tolls: f32 = 0.5,
    use_trails: f32 = 0,
    use_hills: f32 = 0.5,
    use_primary: f32 = 0.5,
    filter_closures: bool = false,
    min_linear_factor: f32 = 1,
    may_allow_edges: bool = false,
};

pub fn parse(arena: std.mem.Allocator, mode: Mode, input: json.Value, warnings: *std.ArrayList(base.Warning), deadline: Deadline) !Options {
    const shared = try base.parse(arena, input, mode.optionsConfig(), warnings, deadline);
    return switch (mode) {
        .motorcycle => .{
            .mode = mode,
            .shared = shared,
            .use_highways = try base.rangedFloat(arena, input, "use_highways", .preference(0.5), warnings),
            .use_tolls = try base.rangedFloat(arena, input, "use_tolls", .preference(0.5), warnings),
            .use_trails = try base.rangedFloat(arena, input, "use_trails", .preference(0), warnings),
            .top_speed = @intCast(try base.rangedUnsignedIn(arena, input, "top_speed", 10, motor.assumed_speed, base.fixed_speed_max, warnings)),
        },
        .motor_scooter => .{
            .mode = mode,
            .shared = shared,
            .top_speed = @intCast(try base.rangedUnsignedIn(arena, input, "top_speed", 20, 45, 120, warnings)),
            .use_hills = try base.rangedFloat(arena, input, "use_hills", .preference(0.5), warnings),
            .use_primary = try base.rangedFloat(arena, input, "use_primary", .preference(0.5), warnings),
        },
    };
}

pub const Profile = struct {
    mode: Mode,
    shared: base.Shared,
    permission: base.Permission,
    road_bias: [8]f32,
    surface_bias: [8]f32,
    grade_penalty: [16]f32,
    curvature_factor: [16]f32,
    toll_bias: f32,
    top_speed: u8,
    fixed_speed: u8,
    min_linear_factor: f32,
    may_allow_edges: bool,

    pub fn allowedNode(self: *const Profile, node: *const NodeHot) bool {
        return self.permission.allowedNode(node);
    }

    pub fn allowedCandidate(self: *const Profile, class: *const EdgeClass, state: base.EdgeState, disallow: base.Disallow, allowed_by_linear_feature: bool) bool {
        if (allowed_by_linear_feature) return true;
        return self.permission.allowedEdge(class, state, disallow) and !class.flags.bike_share_connection;
    }

    pub fn untimedSpeed(self: *const Profile, edge: EdgeHot) Speed {
        return motor.untimedSpeed(self.permission.flow, edge, self.fixed_speed, false);
    }

    pub fn resolvedSpeed(self: *const Profile, edge: EdgeHot, id: graph.format.EdgeId, time: ?graph.speed.Time, overlays: anytype) Speed {
        return motor.resolvedSpeed(self, edge, id, false, time, overlays);
    }

    fn pathClassAllowed(self: *const Profile, class: *const EdgeClass) bool {
        return class.category.surface <= @backingInt(self.mode.maximumSurface()) and self.permission.accessibleClass(class);
    }

    fn secondsPerMetre(self: *const Profile, class: *const EdgeClass, edge: EdgeHot, kph: u8) f32 {
        if (self.mode == .motorcycle) return motor.speed_factors[@min(self.top_speed, kph)];
        if (class.category.use == ferry) return motor.speed_factors[kph];
        const capped: f32 = @floatFromInt(@min(self.top_speed, kph));
        const effective: u16 = @intFromFloat(@max(1, capped * scooter_surface_speed[class.category.surface] * scooter_grade_speed[edge.geom.grade]));
        return motor.speed_factors[effective];
    }

    fn motorcycleWeight(self: *const Profile, class: *const EdgeClass, penalty: f32) f32 {
        var factor = base.density_factor[class.category.density] + self.road_bias[class.category.road_class] +
            self.surface_bias[class.category.surface];
        factor += penalty;
        if (class.flags.toll) factor += self.toll_bias;
        return factor;
    }

    fn curvatureWeight(self: *const Profile, class: *const EdgeClass, curvature: u4) f32 {
        if (self.mode != .motorcycle or self.shared.curvature_strength == 0) return 1;
        const density = class.category.density;
        if (density >= 7) return self.shared.urban_curvature_factor;
        const varied = class.category.use == @backingInt(Use.road) and
            !class.flags.link and !class.flags.roundabout and !class.flags.internal;
        const factor = self.curvature_factor[if (varied) curvature else 0];
        return if (density < 3) factor else self.shared.suburban_curvature_factor * factor;
    }
};

const RequestOptions = Options;
pub const Model = struct {
    pub const Options = RequestOptions;
    pub const Canonical = Profile;

    pub fn canonicalize(options: RequestOptions) !Profile {
        const config = options.mode.optionsConfig();
        for (options.shared.floats.values, config.ranges.values) |value, range| {
            if (!(range.min <= value and value <= range.max)) return error.InvalidMotorcycleOptions;
        }
        for ([_]f32{ options.use_highways, options.use_tolls, options.use_trails, options.use_hills, options.use_primary, options.min_linear_factor }) |value| {
            if (!(0 <= value and value <= 1)) return error.InvalidMotorcycleOptions;
        }
        const shared: base.Shared = .init(options.shared);
        const scooter = options.mode == .motor_scooter;
        const valid_speed = if (scooter) 20 <= options.top_speed and options.top_speed <= 120 else 10 <= options.top_speed and options.top_speed <= base.fixed_speed_max;
        if (!valid_speed or options.shared.fixed_speed > base.fixed_speed_max) return error.InvalidMotorcycleOptions;

        var road_bias = motor.highwayBias(options.use_highways);
        const primary = options.use_primary;
        const road_factor = if (primary >= 0.5) 1.5 - primary else 3 - primary * 5;
        if (scooter) {
            for (&road_bias, scooter_road_factor) |*bias, factor| bias.* = road_factor * factor;
        }
        const trails = options.use_trails;
        const surface_factor: f32 = if (trails >= 0.5) bias: {
            const f = 0.5 - trails;
            break :bias f * f * f;
        } else bias: {
            const f = 1 - trails * 2;
            break :bias @floatFromInt(@as(u8, @intFromFloat(8 * (f * f))));
        };
        var surface_bias: [8]f32 = undefined;
        for (&surface_bias, motor.surface_weight) |*bias, factor| bias.* = surface_factor * factor;
        var grade_penalty: [16]f32 = undefined;
        for (&grade_penalty, scooter_hill_penalty) |*penalty, factor| penalty.* = (1 - options.use_hills) * factor;
        var curvature_factor: [16]f32 = undefined;
        for (&curvature_factor, 0..) |*factor, curvature| factor.* = shared.curvatureFactor(@intCast(curvature));
        const fixed_speed: u8 = @intCast(options.shared.fixed_speed);
        return .{
            .mode = options.mode,
            .shared = shared,
            .permission = .init(options.shared, options.mode.access(), options.filter_closures),
            .road_bias = road_bias,
            .surface_bias = surface_bias,
            .grade_penalty = grade_penalty,
            .curvature_factor = curvature_factor,
            .toll_bias = motor.tollBias(options.use_tolls, 2),
            .top_speed = if (fixed_speed == 0) options.top_speed else fixed_speed,
            .fixed_speed = fixed_speed,
            .min_linear_factor = options.min_linear_factor,
            .may_allow_edges = options.may_allow_edges,
        };
    }

    pub fn rules(profile: Profile) !compiled.Rules {
        var hash = std.crypto.hash.Blake3.init(.{});
        hash.update("motorcycle");
        hash.update(&.{ @backingInt(profile.mode), profile.top_speed, profile.fixed_speed, @intFromBool(profile.shared.shortest) });
        hash.update(std.mem.asBytes(&profile.grade_penalty));
        hash.update(std.mem.asBytes(&profile.curvature_factor));
        const factors = [_]f32{
            profile.shared.time_weight,           profile.shared.distance_weight, profile.shared.speed_penalty_factor,
            profile.shared.closure_factor,        profile.min_linear_factor,      profile.shared.tracks.factor,
            profile.shared.living_streets.factor, profile.shared.service_factor,
        };
        hash.update(std.mem.asBytes(&factors));
        var key: compiled.MetricKey = undefined;
        hash.final(&key);
        const minimum_use = @min(1, profile.shared.tracks.factor, profile.shared.living_streets.factor, profile.shared.service_factor);
        return .{
            .seconds_per_metre = motor.compileSpeeds(if (profile.mode == .motor_scooter) base.fixed_speed_max else profile.top_speed, profile.fixed_speed),
            .floors = .{
                .edge_factor = if (profile.shared.shortest) 0 else minimum_use * profile.shared.time_weight * profile.min_linear_factor,
                .speed_ratio = if (profile.mode == .motor_scooter) 0.8 else 1,
                .turn_factor = 0,
            },
            .node_access_mask = if (profile.permission.flags.contains(.ignore_access)) 0 else @bitCast(profile.permission.access_mask),
            .model_metric_key = key,
        };
    }

    pub fn classFactor(profile: Profile, class: EdgeClass) !f32 {
        // Snapping admits surfaces that through travel excludes. Those
        // classes still need a finite cost for the first partial edge.
        if (!profile.may_allow_edges and
            !profile.permission.accessibleClass(&class) and !profile.permission.allowedClass(&class)) return std.math.inf(f32);
        if (class.category.use == ferry and (profile.mode == .motor_scooter or !profile.shared.shortest)) return profile.shared.ferry_factor;
        if (profile.shared.shortest) return 1;
        return switch (profile.mode) {
            .motorcycle => profile.motorcycleWeight(&class, 0),
            .motor_scooter => 1 + (base.density_factor[class.category.density] - 0.85) + profile.road_bias[class.category.road_class],
        };
    }
};

pub const Cache = compiled.Cache(Model);
pub const Speed = motor.Speed;
pub const Turn = motor.Turn;
pub const InternalTurn = motor.InternalTurn;
pub const PathCheck = motor.PathCheck;

pub const Kernel = struct {
    pub fn allowed(profile: *const Profile, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck, deadline: Deadline) !base.AccessEvaluation {
        return allowedPath(profile, from, to, to, from, turn, check, deadline);
    }

    pub fn allowedReverse(profile: *const Profile, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck, deadline: Deadline) !base.AccessEvaluation {
        return allowedPath(profile, from, to, from, to, turn, check, deadline);
    }

    fn allowedPath(profile: *const Profile, from: *const EdgeClass, to: *const EdgeClass, candidate: *const EdgeClass, previous: *const EdgeClass, turn: base.Turn, check: PathCheck, deadline: Deadline) !base.AccessEvaluation {
        if (check.allowed_by_linear_feature) return .{ .state = check.previous_access };
        var permission = profile.permission;
        permission.allow_destination_only = check.allow_destination_only;
        var previous_access = check.previous_access;
        previous_access.destination_only = previous_access.destination_only or previous.flags.destination_only;
        if (!profile.pathClassAllowed(candidate) or (check.backtrack and !check.previous_dead_end) or
            !permission.allowsTurnRestriction(turn) or check.avoided or
            (!permission.allow_destination_only and candidate.flags.destination_only and !previous_access.destination_only) or
            (check.closure_pruning and check.closed and permission.usesClosures()) or
            !permission.allowedExclusions(from, to)) return .{ .allowed = false };
        if (check.limits.len == 0) return .{ .state = .{ .destination_only = candidate.flags.destination_only } };
        var result = try permission.evaluateRestrictions(check.limits, check.original_forward, check.time, previous_access, null, deadline);
        result.state.destination_only = result.state.destination_only or candidate.flags.destination_only;
        return result;
    }

    pub fn edgeCost(profile: *const Profile, tables: *const compiled.Compiled, class: *const EdgeClass, edge: EdgeHot, speed: Speed, effects: compiled.Effects) Cost {
        const weight = tables.factor(edge.cls.class_id);
        if (effects.forbidden or weight == std.math.inf(f32)) return .forbidden;
        const kph = if (profile.fixed_speed == 0) speed.kph else profile.fixed_speed;
        const length: f32 = @floatFromInt(edge.geom.len_m);
        const secs = length * profile.secondsPerMetre(class, edge, kph);
        if (class.category.use == ferry and (profile.mode == .motor_scooter or !profile.shared.shortest)) return .{ .cost = secs * weight, .secs = secs };
        if (profile.shared.shortest) return .{ .cost = length, .secs = secs };

        const speed_penalty = motor.speedPenalty(profile.top_speed, profile.shared.speed_penalty_factor, kph, speed);
        var factor = switch (profile.mode) {
            .motorcycle => if (speed_penalty == 0) weight else profile.motorcycleWeight(class, speed_penalty),
            .motor_scooter => weight + profile.grade_penalty[edge.geom.grade] + speed_penalty +
                (if (class.flags.destination_only) scooter_destination_factor else @as(f32, 0)),
        };
        factor *= motor.roadUseFactor(&profile.shared, class.category.use);
        if (speed.closed and profile.permission.usesClosures()) factor *= profile.shared.closure_factor;
        std.debug.assert(std.math.isFinite(effects.factor) and effects.factor >= profile.min_linear_factor);
        factor *= effects.factor;
        factor *= profile.curvatureWeight(class, edge.geom.curvature);
        const cost = (secs * profile.shared.time_weight + length * profile.shared.distance_weight) * factor;
        return (Cost{ .cost = @min(cost, std.math.floatMax(f32)), .secs = secs }).add(effects.penalty);
    }

    pub fn edgeLowerBound(profile: *const Profile, tables: *const compiled.Compiled, class: *const EdgeClass, edge: EdgeHot, upper_kph: u8) compiled.Tick {
        const weight = tables.factor(edge.cls.class_id);
        if (weight == std.math.inf(f32)) return compiled.forbidden_tick;
        const length: f64 = @floatFromInt(edge.geom.len_m);
        const maximum = if (profile.fixed_speed != 0) profile.fixed_speed else if (upper_kph == 0) graph.speed.upperBound(edge) else upper_kph;
        const secs = length * profile.secondsPerMetre(class, edge, maximum);
        if (class.category.use == ferry and (profile.mode == .motor_scooter or !profile.shared.shortest)) return compiled.floorTicks(secs * weight);
        if (profile.shared.shortest) return compiled.floorTicks(length);
        const units = secs * profile.shared.time_weight + length * profile.shared.distance_weight;
        const factor = @as(f64, weight) * motor.roadUseFactor(&profile.shared, class.category.use) * profile.min_linear_factor;
        return compiled.floorTicks(@min(units * factor, std.math.floatMax(f32)));
    }

    pub fn turnLowerBound() compiled.Tick {
        return 0;
    }

    pub fn internalTurn(_: *const NodeHot, _: *const EdgeClass, _: EdgeHot, _: base.Turn) InternalTurn {
        return .none;
    }

    pub fn turnCost(profile: *const Profile, node: *const NodeHot, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) Cost {
        var movement = turn;
        movement.internal_turn = .none;
        return motor.turnCost(&profile.shared, node, from, to, movement);
    }

    pub fn turnCostReverse(profile: *const Profile, node: *const NodeHot, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) Cost {
        return turnCost(profile, node, from, to, turn);
    }
};

// Ported from MotorcycleCost.testCurvatureFactorArray in src/sif/motorcyclecost.cc.
test "motorcycle curvature table increases with preference and road straightness" {
    var warnings: std.ArrayList(base.Warning) = .empty;
    defer warnings.deinit(std.testing.allocator);
    var options = try parse(std.testing.allocator, .motorcycle, .null, &warnings, .none);
    var previous: [16]f32 = @splat(1);
    for (0..21) |step| {
        options.shared.floats.set(.use_curvature, @as(f32, @floatFromInt(step)) / 20);
        const profile = try Model.canonicalize(options);
        const factors = profile.curvature_factor;
        try std.testing.expectEqual(@as(f32, 1), factors[15]);
        if (step <= 10) {
            try std.testing.expectEqual(previous, factors);
        } else {
            for (factors[0..15], factors[1..], previous[0..15]) |actual, next, prior| {
                try std.testing.expect(actual > next and actual > prior);
            }
        }
        previous = factors;
    }
}

// Ported from the option tests in src/sif/motorcyclecost.cc and src/sif/motorscootercost.cc.
test "motorcycle and scooter options use their own bounds and defaults" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const a = try parse(arena, .motorcycle, .null, &warnings, .none);
    const b = try parse(arena, .motor_scooter, .null, &warnings, .none);
    try std.testing.expectEqual(@as(u8, 140), a.top_speed);
    try std.testing.expectEqual(@as(u8, 45), b.top_speed);
    const motorcycle = try Model.canonicalize(a);
    const scooter = try Model.canonicalize(b);
    try std.testing.expectEqual(@as(f32, 600), motorcycle.shared.destination_only_penalty);
    try std.testing.expectEqual(@as(f32, 120), scooter.shared.destination_only_penalty);
    try std.testing.expectEqual(@as(f32, 15), motorcycle.shared.toll_booth.secs);
    try std.testing.expectEqual(@as(f32, 0), scooter.shared.toll_booth.secs);
    try std.testing.expectEqual(@as(f32, 8), motorcycle.surface_bias[@backingInt(Surface.path)]);
    try std.testing.expectEqual(@as(f32, 5), scooter.grade_penalty[15]);
    const input = try json.parse(arena, "{\"use_primary\":2,\"top_speed\":121,\"use_hills\":-1,\"toll_booth_cost\":50000}");
    const reset = try parse(arena, .motor_scooter, input, &warnings, .none);
    try std.testing.expectEqual(b.top_speed, reset.top_speed);
    try std.testing.expectEqual(b.use_hills, reset.use_hills);
    try std.testing.expectEqual(b.use_primary, reset.use_primary);
    const names = [_][]const u8{ "top_speed", "use_hills", "use_primary" };
    try std.testing.expectEqual(names.len, warnings.items.len);
    for (names, warnings.items) |name, warning| try std.testing.expectEqualStrings(name, warning.option);
}

test "scooter grade-adjusted speed and snap admission use the stored surface" {
    var warnings: std.ArrayList(base.Warning) = .empty;
    defer warnings.deinit(std.testing.allocator);
    var options = try parse(std.testing.allocator, .motor_scooter, .null, &warnings, .none);
    const gravel: EdgeClass = .{
        .category = .{ .surface = @backingInt(Surface.gravel) },
        .access = .{ .forward = @bitCast(@as(AccessMask, .{ .moped = true })) },
    };
    var pavement = gravel;
    pavement.category.surface = @backingInt(Surface.paved);
    var edge: EdgeHot = .{
        .head = 0,
        .geom = .{ .len_m = 1400, .grade = 0, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = .{ 100, 0, 0, 0 },
    };
    const normal = try Model.canonicalize(options);
    try std.testing.expect(normal.allowedCandidate(&gravel, .{}, .{}, false));
    try std.testing.expect(!(try Kernel.allowed(&normal, &pavement, &gravel, .{ .row = 0 }, .{}, .none)).allowed);
    try std.testing.expect(!(try Kernel.allowedReverse(&normal, &gravel, &pavement, .{ .row = 0 }, .{}, .none)).allowed);
    var factors: [1]f32 = undefined;
    const snap_tables = try compiled.compileInto(Model, normal, &.{gravel}, &factors, .none);
    const snapped = Kernel.edgeCost(&normal, &snap_tables, &gravel, edge, normal.untimedSpeed(edge), .{});
    try std.testing.expectApproxEqAbs(@as(f32, 5040), snapped.secs, 0.001);

    options.shared.fixed_speed = 252;
    const fixed = try Model.canonicalize(options);
    const tables = try compiled.compileInto(Model, fixed, &.{pavement}, &factors, .none);
    const downhill = Kernel.edgeCost(&fixed, &tables, &pavement, edge, fixed.untimedSpeed(edge), .{});
    const expected: f32 = 1400 * (3600.0 * @as(f32, 0.001) / 315);
    try std.testing.expectEqual(expected, downhill.secs);
    try std.testing.expect(compiled.costUnits(Kernel.edgeLowerBound(&fixed, &tables, &pavement, edge, 252)) <= downhill.cost);
    edge.geom.grade = 15;
    const uphill = Kernel.edgeCost(&fixed, &tables, &pavement, edge, fixed.untimedSpeed(edge), .{});
    try std.testing.expect(uphill.secs > downhill.secs);
}
