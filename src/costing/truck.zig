// Ported from src/sif/truckcost.cc (Valhalla 3.9.3).
const std = @import("std");
const base = @import("base.zig");
const motor = @import("motor.zig");
const compiled = @import("compiled.zig");
const graph = @import("../graph/root.zig");
const json = @import("../api/json.zig");
const Deadline = @import("../infra/io.zig").Deadline;

const EdgeClass = graph.class_table.EdgeClass;
const EdgeHot = graph.format.EdgeHot;
const NodeHot = graph.format.NodeHot;
const EdgeId = graph.format.EdgeId;
const View = graph.reader.View;
const Use = graph.constants.Use;
const Surface = graph.constants.Surface;
const Restriction = graph.cold.access_restriction.Entry;
const Cost = compiled.Cost;

const residential = @backingInt(graph.constants.RoadClass.residential);
const truck_route_factor: f32 = 0.85;
const top_speed_range: base.Range = .{ .min = 10, .default = 120, .max = 252 };
const axle_load_range: base.Range = .{ .min = 0, .default = 9.07, .max = 40 };
const truck_config: base.Config = blk: {
    var config: base.Config = .{};
    config.ranges.set(.service_penalty, .penalty(0));
    config.ranges.set(.use_tracks, .preference(0));
    config.ranges.set(.use_living_streets, .preference(0));
    config.ranges.set(.height, .{ .min = 0, .default = 4.11, .max = 10 });
    config.ranges.set(.width, .{ .min = 0, .default = 2.6, .max = 10 });
    config.ranges.set(.length, .{ .min = 0, .default = 21.64, .max = 50 });
    config.ranges.set(.weight, .{ .min = 0, .default = 21.77, .max = 100 });
    break :blk config;
};

pub const Options = struct {
    shared: base.Options,
    low_class_penalty: f32,
    low_class_factor: f32,
    hazmat: bool,
    axle_load: f32,
    use_tolls: f32,
    use_highways: f32,
    axle_count: u8,
    top_speed: f32,
    hgv_no_access_penalty: f32,
    use_truck_route: f32,
    filter_closures: bool = false,
    min_linear_factor: f32 = 1,
    may_allow_edges: bool = false,
};

pub fn parse(arena: std.mem.Allocator, input: json.Value, warnings: *std.ArrayList(base.Warning), deadline: Deadline) !Options {
    return .{
        .shared = try base.parse(arena, input, truck_config, warnings, deadline),
        .low_class_penalty = try base.rangedFloat(arena, input, "low_class_penalty", .penalty(15), warnings),
        .low_class_factor = try base.rangedFloat(arena, input, "low_class_factor", .factor(1.5), warnings),
        .hazmat = json.get(bool, input, "/hazmat", false),
        .axle_load = try base.rangedFloat(arena, input, "axle_load", axle_load_range, warnings),
        .use_tolls = try base.rangedFloat(arena, input, "use_tolls", .preference(0.5), warnings),
        .use_highways = try base.rangedFloat(arena, input, "use_highways", .preference(0.5), warnings),
        .axle_count = @intCast(try base.rangedUnsignedIn(arena, input, "axle_count", 2, 5, 20, warnings)),
        .top_speed = try base.rangedFloat(arena, input, "top_speed", top_speed_range, warnings),
        .hgv_no_access_penalty = try base.rangedFloat(arena, input, "hgv_no_access_penalty", .penalty(base.max_penalty), warnings),
        .use_truck_route = try base.rangedFloat(arena, input, "use_truck_route", .preference(0), warnings),
    };
}

pub const Vehicle = struct {
    height: f32,
    width: f32,
    length: f32,
    weight: f32,
    axle_load: f32,
    axle_count: u8,
    hazmat: bool,

    pub fn allowed(self: Vehicle, limit: Restriction) bool {
        const size: f32 = switch (limit.attr.kind) {
            .maxheight => self.height,
            .maxwidth => self.width,
            .maxlength => self.length,
            .maxweight => self.weight,
            .maxaxleload => self.axle_load,
            .maxaxles => return self.axle_count <= @as(u8, @truncate(limit.value)),
            .hazmat => return !self.hazmat or limit.value != 0,
            else => return true,
        };
        const hundredths: f64 = @floatFromInt(limit.value);
        return size <= @as(f32, @floatCast(hundredths * 0.01));
    }
};

pub const Profile = struct {
    shared: base.Shared,
    permission: base.Permission,
    vehicle: Vehicle,
    highway_bias: [8]f32,
    toll_bias: f32,
    low_class_penalty: f32,
    low_class_adjustment: f32,
    non_truck_route_factor: f32,
    hgv_no_access_penalty: f32,
    min_linear_factor: f32,
    may_allow_edges: bool,
    top_speed: u8,
    fixed_speed: u8,

    pub fn init(options: Options) !Profile {
        for (options.shared.floats.values, truck_config.ranges.values) |value, range| {
            if (!(range.min <= value and value <= range.max)) return error.InvalidTruckOptions;
        }
        for ([_]f32{ options.use_highways, options.use_tolls, options.use_truck_route, options.min_linear_factor }) |value| {
            if (!(0 <= value and value <= 1)) return error.InvalidTruckOptions;
        }
        if (!(0 <= options.low_class_penalty and options.low_class_penalty <= base.max_penalty) or
            !(0.1 <= options.low_class_factor and options.low_class_factor <= 100_000) or
            !(axle_load_range.min <= options.axle_load and options.axle_load <= axle_load_range.max) or
            !(0 <= options.hgv_no_access_penalty and options.hgv_no_access_penalty <= base.max_penalty) or
            options.axle_count < 2 or options.axle_count > 20 or
            !(top_speed_range.min <= options.top_speed and options.top_speed <= top_speed_range.max) or
            options.shared.fixed_speed > base.fixed_speed_max) return error.InvalidTruckOptions;
        const allow_car_access = options.hgv_no_access_penalty != base.max_penalty;
        const fixed_speed: u8 = @intCast(options.shared.fixed_speed);
        return .{
            .shared = .init(options.shared),
            .permission = .init(options.shared, .{ .truck = true, .auto = allow_car_access }, options.filter_closures),
            .vehicle = .{
                .height = options.shared.value(.height),
                .width = options.shared.value(.width),
                .length = options.shared.value(.length),
                .weight = options.shared.value(.weight),
                .hazmat = options.hazmat,
                .axle_load = options.axle_load,
                .axle_count = options.axle_count,
            },
            .highway_bias = motor.highwayBias(options.use_highways),
            .toll_bias = motor.tollBias(options.use_tolls, 2),
            .low_class_penalty = options.low_class_penalty,
            .low_class_adjustment = options.low_class_factor - 1,
            .non_truck_route_factor = if (options.use_truck_route < 0.5) 1 + 2 * options.use_truck_route else -4 + 12 * options.use_truck_route,
            .hgv_no_access_penalty = if (allow_car_access) options.hgv_no_access_penalty else 0,
            .min_linear_factor = options.min_linear_factor,
            .may_allow_edges = options.may_allow_edges,
            .top_speed = if (fixed_speed != 0) fixed_speed else @intFromFloat(options.top_speed),
            .fixed_speed = fixed_speed,
        };
    }

    pub fn allowedNode(self: *const Profile, node: *const NodeHot) bool {
        return self.permission.allowedNode(node);
    }

    pub fn allowedCandidate(self: *const Profile, class: *const EdgeClass, state: base.EdgeState, disallow: base.Disallow, allowed_by_linear_feature: bool) bool {
        if (allowed_by_linear_feature) return true;
        if (state.closed and self.permission.flow.current and (self.permission.filter_closures or disallow.closure)) return false;
        var open = state;
        open.closed = false;
        return self.permission.allowedEdge(class, open, disallow) and !class.flags.bike_share_connection;
    }

    pub fn untimedSpeed(self: *const Profile, edge: EdgeHot) motor.Speed {
        return motor.untimedSpeed(self.permission.flow, edge, self.fixed_speed, true);
    }

    pub fn resolvedSpeed(self: *const Profile, edge: EdgeHot, id: EdgeId, time: ?graph.speed.Time, overlays: anytype) Speed {
        return motor.resolvedSpeed(self, edge, id, true, time, overlays);
    }

    pub fn astarCostFactor(self: *const Profile) f32 {
        return motor.speed_factors[self.top_speed] * self.min_linear_factor;
    }

    fn pathClassAllowed(self: *const Profile, class: *const EdgeClass) bool {
        return class.category.surface != @backingInt(Surface.impassable) and self.permission.accessibleClass(class);
    }

    fn hasClassCost(self: *const Profile, class: *const EdgeClass) bool {
        return class.category.surface != @backingInt(Surface.impassable) and
            (self.may_allow_edges or self.pathClassAllowed(class));
    }

    fn capSpeed(self: *const Profile, edge: EdgeHot, kph: u8) u8 {
        const truck_speed = edge.speed[3];
        return @min(kph, self.top_speed, if (truck_speed == 0) self.top_speed else truck_speed);
    }

    fn classWeight(self: *const Profile, class: *const EdgeClass, speed_penalty: f32) f32 {
        const use = class.category.use;
        var weight = switch (use) {
            @backingInt(Use.ferry) => self.shared.ferry_factor,
            @backingInt(Use.rail_ferry) => self.shared.rail_ferry_factor,
            else => base.density_factor[class.category.density],
        };
        const surface = motor.surface_weight[class.category.surface];
        const toll: f32 = if (class.flags.toll) self.toll_bias else 0;
        const low: f32 = if (class.category.road_class >= residential) self.low_class_adjustment else 0;
        weight += self.highway_bias[class.category.road_class] + surface + speed_penalty + toll + low;
        weight *= if (class.flags.truck_route) truck_route_factor else self.non_truck_route_factor;
        return weight * motor.roadUseFactor(&self.shared, use);
    }
};

const RequestOptions = Options;
pub const Model = struct {
    pub const Options = RequestOptions;
    pub const Canonical = Profile;
    pub const canonicalize = Profile.init;

    pub fn rules(profile: Profile) !compiled.Rules {
        var hash = std.crypto.hash.Blake3.init(.{});
        hash.update("truck");
        hash.update(&.{ profile.top_speed, profile.fixed_speed, @intFromBool(profile.shared.shortest) });
        const factors = [_]f32{
            profile.shared.time_weight,           profile.shared.distance_weight, profile.shared.speed_penalty_factor,
            profile.shared.closure_factor,        profile.min_linear_factor,      profile.low_class_penalty,
            profile.hgv_no_access_penalty,        profile.non_truck_route_factor, profile.shared.tracks.factor,
            profile.shared.living_streets.factor, profile.shared.service_factor,
        };
        hash.update(std.mem.asBytes(&factors));
        var key: compiled.MetricKey = undefined;
        hash.final(&key);
        return .{
            .seconds_per_metre = motor.compileSpeeds(profile.top_speed, 0),
            .floors = .{ .edge_factor = if (profile.shared.shortest) 0 else profile.shared.time_weight * profile.min_linear_factor, .turn_factor = 0 },
            .node_access_mask = if (profile.permission.flags.contains(.ignore_access)) 0 else @bitCast(profile.permission.access_mask),
            .model_metric_key = key,
        };
    }

    pub fn classFactor(profile: Profile, class: EdgeClass) !f32 {
        if (!profile.hasClassCost(&class)) return std.math.inf(f32);
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
    time: ?graph.datetime.Local = null,
};

pub const Speed = motor.Speed;
pub const Turn = motor.Turn;
pub const InternalTurn = motor.InternalTurn;

pub const Kernel = struct {
    pub const internalTurn = motor.internalTurn;

    pub fn allowed(profile: *const Profile, view: *const View, id: EdgeId, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck, deadline: Deadline) !base.AccessEvaluation {
        return allowedPath(true, profile, view, id, from, to, turn, check, deadline);
    }

    pub fn allowedReverse(profile: *const Profile, view: *const View, candidate_id: EdgeId, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck, deadline: Deadline) !base.AccessEvaluation {
        return allowedPath(false, profile, view, candidate_id, from, to, turn, check, deadline);
    }

    fn allowedPath(comptime forward: bool, profile: *const Profile, view: *const View, id: EdgeId, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck, deadline: Deadline) !base.AccessEvaluation {
        if (check.allowed_by_linear_feature) return .{ .state = check.previous_access };
        const candidate = if (forward) to else from;
        const previous = if (forward) from else to;
        var permission = profile.permission;
        permission.allow_destination_only = check.allow_destination_only;
        const previous_destination = previous.flags.destination_only or check.previous_access.destination_only;
        const compacted = @backingInt(Surface.compacted);
        if (!profile.pathClassAllowed(candidate) or (check.backtrack and !check.previous_dead_end) or
            !permission.allowsTurnRestriction(turn) or check.avoided or
            (!permission.allow_destination_only and !previous_destination and candidate.flags.destination_only_hgv) or
            (check.closure_pruning and check.closed and permission.usesClosures()) or
            (permission.flags.contains(.exclude_unpaved) and previous.category.surface < compacted and candidate.category.surface >= compacted) or
            !permission.allowedExclusions(from, to)) return .{ .allowed = false };

        const edge = try view.edge(id);
        if (edge.cls.cold_checks == 0 or permission.flags.contains(.ignore_restrictions))
            return .{ .state = .{ .destination_only = candidate.flags.destination_only_hgv } };
        var previous_access = check.previous_access;
        previous_access.destination_only = previous_destination;
        var result = try slowAllowed(profile.vehicle, permission, view, id, previous_access, check.time, deadline);
        result.state.destination_only = result.state.destination_only or candidate.flags.destination_only_hgv;
        return result;
    }

    noinline fn slowAllowed(vehicle: Vehicle, permission: base.Permission, view: *const View, id: EdgeId, previous: base.AccessState, time: ?graph.datetime.Local, deadline: Deadline) !base.AccessEvaluation {
        const limits = (try view.coldRecordWithDeadline(id, deadline)).restrictions();
        return permission.evaluateRestrictions(limits.remaining, limits.forward, time, previous, vehicle, deadline);
    }

    /// Evaluate the pinned formula directly, including signed costs.
    pub fn rawEdgeCost(profile: *const Profile, class: *const EdgeClass, edge: EdgeHot, speed: Speed, effects: compiled.Effects) Cost {
        if (effects.forbidden or !profile.hasClassCost(class)) return .forbidden;
        return edgeCostWithWeight(profile, class, edge, speed, effects, profile.classWeight(class, 0));
    }

    pub fn edgeCost(profile: *const Profile, tables: *const compiled.Compiled, class: *const EdgeClass, edge: EdgeHot, speed: Speed, effects: compiled.Effects) Cost {
        const weight = tables.factor(edge.cls.class_id);
        if (effects.forbidden or weight == std.math.inf(f32)) return .forbidden;
        return edgeCostWithWeight(profile, class, edge, speed, effects, weight);
    }

    fn edgeCostWithWeight(profile: *const Profile, class: *const EdgeClass, edge: EdgeHot, speed: Speed, effects: compiled.Effects, static_weight: f32) Cost {
        const kph = if (profile.fixed_speed == 0) speed.kph else profile.fixed_speed;
        const length: f32 = @floatFromInt(edge.geom.len_m);
        const secs = length * motor.speed_factors[profile.capSpeed(edge, kph)];
        if (profile.shared.shortest) return .{ .cost = length, .secs = secs };
        const speed_penalty = motor.speedPenalty(profile.top_speed, profile.shared.speed_penalty_factor, kph, speed);
        var factor = if (speed_penalty == 0) static_weight else profile.classWeight(class, speed_penalty);
        std.debug.assert(std.math.isFinite(effects.factor) and effects.factor >= profile.min_linear_factor);
        factor *= effects.factor;
        if (speed.closed and profile.permission.usesClosures()) factor *= profile.shared.closure_factor;
        const cost = (secs * profile.shared.time_weight + length * profile.shared.distance_weight) * factor;
        return .{
            .cost = @min(cost + effects.penalty.cost, std.math.floatMax(f32)),
            .secs = @min(secs + effects.penalty.secs, std.math.floatMax(f32)),
        };
    }

    pub fn edgeLowerBound(profile: *const Profile, tables: *const compiled.Compiled, edge: EdgeHot, upper_kph: u8) compiled.Tick {
        const factor = tables.factor(edge.cls.class_id);
        if (factor == std.math.inf(f32)) return compiled.forbidden_tick;
        const length: f64 = @floatFromInt(edge.geom.len_m);
        if (profile.shared.shortest) return compiled.floorTicks(length);
        const upper = if (profile.fixed_speed != 0) profile.fixed_speed else if (upper_kph == 0) profile.top_speed else upper_kph;
        const secs = length * tables.seconds_per_metre[profile.capSpeed(edge, upper)];
        const units = secs * profile.shared.time_weight + length * profile.shared.distance_weight;
        return compiled.floorTicks(@min(units * factor * profile.min_linear_factor, std.math.floatMax(f32)));
    }

    pub fn turnLowerBound() compiled.Tick {
        return 0;
    }

    pub fn turnCost(profile: *const Profile, node: *const NodeHot, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) Cost {
        if (from.flags.node_connector or to.flags.node_connector) return .{};
        var entry = turn.movement.base_turn;
        entry.hgv = true;
        var cost = profile.shared.transition(node, from, to, entry);
        cost.secs += motor.carTurnDuration(node, turn.degrees, turn.more_than_two_roads);
        if (!profile.shared.shortest and from.category.road_class < residential and to.category.road_class >= residential)
            cost.cost += profile.low_class_penalty;
        if (from.forwardAccess().truck and !to.forwardAccess().truck) cost.cost += profile.hgv_no_access_penalty;
        if (!profile.shared.shortest) cost.cost += motor.turnPenalty(node, from, to, turn);
        cost.cost *= profile.shared.time_weight;
        return cost;
    }

    pub fn turnCostReverse(profile: *const Profile, node: *const NodeHot, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) Cost {
        return turnCost(profile, node, from, to, turn);
    }
};

test "truck raw cost preserves the signed factor in the Utrecht oracle sample" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const options = try parse(arena, try json.parse(arena, "{\"low_class_factor\":0.1,\"use_tolls\":1}"), &warnings, .none);
    const profile = try Profile.init(options);
    const edge: EdgeHot = .{
        .head = 0,
        .geom = .{ .len_m = 9, .grade = 6, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = .{ 30, 0, 0, 0 },
    };
    const class: EdgeClass = .{
        .category = .{ .road_class = residential },
        .access = .{ .forward = @bitCast(@as(graph.constants.AccessMask, .{ .truck = true })) },
    };
    const cost = Kernel.rawEdgeCost(&profile, &class, edge, profile.untimedSpeed(edge), .{});
    try std.testing.expectApproxEqAbs(@as(f32, -0.053999949), cost.cost, 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.080000043), cost.secs, 0.0000001);
    try std.testing.expectEqual(0, warnings.items.len);
}

// Ported from TruckCost.testTruckCostParams in src/sif/truckcost.cc.
test "truck options retain range endpoints and restore the defaults in warning order" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const defaults = try Profile.init(try parse(arena, .null, &warnings, .none));
    try std.testing.expectEqual(Vehicle{
        .height = 4.11,
        .width = 2.6,
        .length = 21.64,
        .weight = 21.77,
        .axle_load = 9.07,
        .axle_count = 5,
        .hazmat = false,
    }, defaults.vehicle);
    try std.testing.expectEqual(@as(f32, 15), defaults.low_class_penalty);
    try std.testing.expect(!defaults.permission.access_mask.auto and defaults.permission.access_mask.truck);

    const bounds = try json.parse(arena,
        \\{"height":10,"width":10,"length":50,"weight":100,"axle_load":40,"axle_count":20,
        \\ "top_speed":252,"low_class_penalty":43200,"low_class_factor":100000,"use_truck_route":1,
        \\ "hgv_no_access_penalty":43199,"hazmat":true}
    );
    const last = try Profile.init(try parse(arena, bounds, &warnings, .none));
    try std.testing.expectEqual(0, warnings.items.len);
    try std.testing.expectEqual(@as(u8, 252), last.top_speed);
    try std.testing.expectEqual(@as(u8, 20), last.vehicle.axle_count);
    try std.testing.expectEqual(@as(f32, 8), last.non_truck_route_factor);
    try std.testing.expectEqual(@as(f32, 43199), last.hgv_no_access_penalty);
    try std.testing.expect(last.permission.access_mask.auto and last.permission.access_mask.truck and last.vehicle.hazmat);

    const invalid = try json.parse(arena,
        \\{"height":11,"low_class_factor":0,"axle_load":41,"axle_count":1,"top_speed":253,
        \\ "hgv_no_access_penalty":-1,"use_truck_route":2}
    );
    const reset = try Profile.init(try parse(arena, invalid, &warnings, .none));
    try std.testing.expectEqual(defaults.vehicle, reset.vehicle);
    try std.testing.expectEqual(defaults.top_speed, reset.top_speed);
    try std.testing.expectEqual(defaults.low_class_adjustment, reset.low_class_adjustment);
    const names = [_][]const u8{ "height", "low_class_factor", "axle_load", "axle_count", "top_speed", "hgv_no_access_penalty", "use_truck_route" };
    try std.testing.expectEqual(names.len, warnings.items.len);
    for (names, warnings.items) |name, warning| try std.testing.expectEqualStrings(name, warning.option);

    const fraction = try parse(arena, try json.parse(arena, "{\"top_speed\":110.9}"), &warnings, .none);
    try std.testing.expectEqual(@as(u8, 110), (try Profile.init(fraction)).top_speed);
    const nan = try parse(arena, try json.parse(arena, "{\"top_speed\":\"NaN\"}"), &warnings, .none);
    try std.testing.expectError(error.InvalidTruckOptions, Profile.init(nan));
}

// Ported from TruckSpeed.MaxTruckSpeed and TruckSpeed.TopSpeed in test/gurka/test_truck.cc.
test "truck speed cap follows the vehicle limit across resolved sources" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    var options = try parse(arena, .null, &warnings, .none);
    const class: EdgeClass = .{ .access = .{ .forward = @bitCast(@as(graph.constants.AccessMask, .{ .truck = true })) } };
    var edge: EdgeHot = .{
        .head = 0,
        .geom = .{ .len_m = 5500, .grade = 6, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = .{ 120, 105, 100, 110 },
    };
    var profile = try Profile.init(options);
    const live: Speed = .{ .kph = 140, .non_current_kph = 120, .sources = .{ .current = true } };
    try std.testing.expectApproxEqAbs(@as(f32, 180), Kernel.rawEdgeCost(&profile, &class, edge, live, .{}).secs, 0.0001);
    const slower: Speed = .{ .kph = 50, .non_current_kph = 120, .sources = .{ .current = true } };
    try std.testing.expectApproxEqAbs(@as(f32, 396), Kernel.rawEdgeCost(&profile, &class, edge, slower, .{}).secs, 0.0001);
    try std.testing.expectEqual(@as(u8, 100), profile.untimedSpeed(edge).kph);
    edge.speed[1] = 0;
    edge.speed[2] = 0;
    try std.testing.expectEqual(@as(u8, 110), profile.untimedSpeed(edge).kph);
    options.shared.fixed_speed = 140;
    profile = try Profile.init(options);
    try std.testing.expectApproxEqAbs(@as(f32, 180), Kernel.rawEdgeCost(&profile, &class, edge, slower, .{}).secs, 0.0001);
    options.shared.fixed_speed = 0;
    options.top_speed = 70;
    profile = try Profile.init(options);
    try std.testing.expectApproxEqAbs(@as(f32, 282.85715), Kernel.rawEdgeCost(&profile, &class, edge, live, .{}).secs, 0.0001);
    edge.speed[3] = 0;
    options.top_speed = 120;
    profile = try Profile.init(options);
    try std.testing.expectApproxEqAbs(@as(f32, 165), Kernel.rawEdgeCost(&profile, &class, edge, live, .{}).secs, 0.0001);
}

test "truck entry charges low class, destination-only and HGV access penalties once" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const input = try json.parse(arena, "{\"hgv_no_access_penalty\":30}");
    const profile = try Profile.init(try parse(arena, input, &warnings, .none));
    const node: NodeHot = .{ .turn_off = 0, .attr = .{ .access = 0, .type = 0, .density = 0, .signal = 0, .drive_on_left = false } };
    const primary: EdgeClass = .{
        .category = .{ .road_class = @backingInt(graph.constants.RoadClass.primary) },
        .access = .{ .forward = @bitCast(@as(graph.constants.AccessMask, .{ .truck = true })) },
    };
    const local: EdgeClass = .{
        .category = .{ .road_class = residential },
        .flags = .{ .destination_only_hgv = true },
        .access = .{ .forward = @bitCast(@as(graph.constants.AccessMask, .{ .auto = true })) },
    };
    var turn: Turn = .{ .movement = .{ .base_turn = .{ .row = 0x40 }, .sides = .{} }, .degrees = 0, .more_than_two_roads = false };
    try std.testing.expectEqual(@as(f32, 645), Kernel.turnCost(&profile, &node, &primary, &local, turn).cost);
    turn.movement.base_turn.previous_destination_only = true;
    try std.testing.expectEqual(@as(f32, 45), Kernel.turnCost(&profile, &node, &primary, &local, turn).cost);
    try std.testing.expectEqual(@as(f32, 0), Kernel.turnCost(&profile, &node, &local, &local, turn).cost);
}

test "truck live speed uses the ordinary noncurrent source for the speed penalty" {
    const Overlay = struct {
        encoded_speed: u7,

        pub fn live(self: @This(), _: EdgeId) ?graph.speed.Live {
            return .{ .overall = self.encoded_speed, .segments = .{ self.encoded_speed, 127, 127 }, .breakpoints = .{ 255, 0 } };
        }

        pub fn predicted(_: @This(), _: EdgeId, _: graph.speed.Bucket) ?f32 {
            return null;
        }
    };
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const input = try json.parse(arena, "{\"top_speed\":70,\"speed_types\":[\"current\"]}");
    var options = try parse(arena, input, &warnings, .none);
    const profile = try Profile.init(options);
    const edge: EdgeHot = .{
        .head = 0,
        .geom = .{ .len_m = 650, .grade = 6, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = .{ 100, 90, 80, 65 },
    };
    const live = profile.resolvedSpeed(edge, @fromBackingInt(0), .{ .seconds_of_week = 0 }, Overlay{ .encoded_speed = 60 });
    try std.testing.expectEqual(Speed{ .kph = 120, .non_current_kph = 100, .sources = .{ .current = true } }, live);
    try std.testing.expectEqual(@as(f32, 1.5), motor.speedPenalty(profile.top_speed, profile.shared.speed_penalty_factor, live.kph, live));
    const class: EdgeClass = .{ .access = .{ .forward = @bitCast(@as(graph.constants.AccessMask, .{ .truck = true })) } };
    var factors: [1]f32 = undefined;
    const tables = try compiled.compileInto(Model, profile, &.{class}, &factors, .none);
    const actual = Kernel.edgeCost(&profile, &tables, &class, edge, live, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 36), actual.secs, 0.0001);
    try std.testing.expect(compiled.costUnits(Kernel.edgeLowerBound(&profile, &tables, edge, graph.speed.upperBound(edge))) <= actual.cost);

    options.shared.fixed_speed = 90;
    const fixed = try Profile.init(options);
    const closed = fixed.resolvedSpeed(edge, @fromBackingInt(0), null, Overlay{ .encoded_speed = 0 });
    try std.testing.expectEqual(Speed{ .kph = 90, .non_current_kph = 90, .closed = true }, closed);
}
