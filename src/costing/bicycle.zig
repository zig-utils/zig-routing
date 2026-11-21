// Ported from src/sif/bicyclecost.cc (Valhalla 3.9.3).
const std = @import("std");
const base = @import("base.zig");
const compiled = @import("compiled.zig");
const graph = @import("../graph/root.zig");
const json = @import("../api/json.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const DirectedEdge = @import("../snap/edge.zig").DirectedEdge;
const Cost = compiled.Cost;
const EdgeClass = graph.class_table.EdgeClass;
const EdgeHot = graph.format.EdgeHot;
const NodeHot = graph.format.NodeHot;
const Use = graph.constants.Use;
const Surface = graph.constants.Surface;
const inf = std.math.inf(f32);
pub const Turn = base.IntersectionTurn;

pub const Type = enum(u2) { road, cross, hybrid, mountain };

const cruise_speed = [4]f32{ 25, 20, 18, 16 };
const surface_speed = [4][8]f32{
    .{ 1, 1, 0.9, 0.6, 0.5, 0.3, 0.2, 0 },
    .{ 1, 1, 1, 0.8, 0.7, 0.5, 0.4, 0 },
    .{ 1, 1, 1, 0.8, 0.6, 0.4, 0.25, 0 },
    .{ 1, 1, 1, 1, 0.9, 0.75, 0.55, 0 },
};
const grade_speed = [16]f32{ 2.2, 2, 1.9, 1.7, 1.4, 1.2, 1, 0.95, 0.85, 0.75, 0.65, 0.55, 0.5, 0.45, 0.4, 0.3 };
const hill_strength = [16]f32{ 2, 1, 0.5, 0.2, 0.1, 0, 0.05, 0.1, 0.3, 0.8, 2, 3, 4.5, 6.5, 10, 12 };
const surface_threshold = [4]Surface{ .compacted, .gravel, .dirt, .path };
const surface_penalty = [4]f32{ 1, 2.5, 4.5, 7 };
const classification_stress = [8]f32{ 1, 0.4, 0.2, 0.1, 0.05, 0.05, 0, 0.5 };
const turn_lane = [8]f32{ 1, 0.5, 0.25, 0.1, 0.4, 0.5, 0.25, 0.1 };
const turn_time = [2][8]f32{
    .{ 0.15, 0.2, 0.3, 0.5, 5, 1.5, 1, 0.4 },
    .{ 0.15, 0.4, 1, 1.5, 5, 0.5, 0.3, 0.2 },
};
const turn_penalty = [2][8]f32{
    .{ 0, 0.25, 0.75, 1, 4, 2.25, 1.75, 0.75 },
    .{ 0, 0.75, 1.75, 2.25, 4, 1, 0.75, 0.25 },
};

const kmh_seconds: f32 = @as(f32, 3600) * @as(f32, 0.001);
const seconds_per_metre = blk: {
    var table: [256]f32 = undefined;
    table[0] = 3600;
    for (1..table.len) |speed| table[speed] = kmh_seconds / @as(f32, @floatFromInt(speed));
    break :blk table;
};

pub const Options = struct {
    shared: base.Options,
    bicycle_type: Type = .hybrid,
    cycling_speed: f32 = 18,
    use_roads: f32 = 0.25,
    use_hills: f32 = 0.25,
    avoid_bad_surfaces: f32 = 0.25,
    steps_factor: f32 = 8,
    bss_return_cost: f32 = 120,
    bss_return_penalty: f32 = 0,
    may_allow_edges: bool = false,
    min_linear_factor: f32 = 1,
};

fn sharedConfig() base.Config {
    var config: base.Config = .{ .disable_toll_booth = true, .disable_rail_ferry = true };
    config.ranges.set(.alley_penalty, .penalty(60));
    config.ranges.set(.gate_penalty, .penalty(300));
    config.ranges.set(.use_living_streets, .preference(0.5));
    return config;
}

/// ParseBicycleCostOptions. The input is costing_options.bicycle.
pub fn parse(arena: std.mem.Allocator, input: json.Value, warnings: *std.ArrayList(base.Warning), deadline: Deadline) !Options {
    const shared = try base.parse(arena, input, sharedConfig(), warnings, deadline);
    const roads = try base.rangedFloat(arena, input, "use_roads", .preference(0.25), warnings);
    const hills = try base.rangedFloat(arena, input, "use_hills", .preference(0.25), warnings);
    const surfaces = try base.rangedFloat(arena, input, "avoid_bad_surfaces", .preference(0.25), warnings);
    const steps = try base.rangedFloat(arena, input, "steps_factor", .factor(8), warnings);
    const name = json.get([]const u8, input, "/bicycle_type", "hybrid");
    const bike: Type = if (std.ascii.eqlIgnoreCase(name, "road"))
        .road
    else if (std.ascii.eqlIgnoreCase(name, "cross"))
        .cross
    else if (std.ascii.eqlIgnoreCase(name, "mountain"))
        .mountain
    else
        .hybrid;
    return .{
        .shared = shared,
        .bicycle_type = bike,
        .cycling_speed = try base.rangedFloat(arena, input, "cycling_speed", .{ .min = 5, .default = cruise_speed[@backingInt(bike)], .max = 60 }, warnings),
        .use_roads = roads,
        .use_hills = hills,
        .avoid_bad_surfaces = surfaces,
        .steps_factor = steps,
        .bss_return_cost = try base.rangedFloat(arena, input, "bss_return_cost", .penalty(120), warnings),
        .bss_return_penalty = try base.rangedFloat(arena, input, "bss_return_penalty", .penalty(0), warnings),
    };
}

pub const Profile = struct {
    shared: base.Shared,
    permission: base.Permission,
    bicycle_type: Type,
    cycling_speed: f32,
    use_roads: f32,
    road_factor: f32,
    sidepath_factor: f32,
    livingstreet_factor: f32,
    cyclestreet_factor: f32,
    track_factor: f32,
    avoid_bad_surfaces: f32,
    surface_threshold: Surface,
    surface_limit: Surface,
    steps_factor: f32,
    lanes: [8]f32,
    path_lanes: [4]f32,
    bike_speeds: [8][16]u8,
    speed_stress: [256]f32,
    hills: [16]f32,
    may_allow_edges: bool,
    min_linear_factor: f32,

    /// BicycleCost::Allowed for candidate/reach search.
    pub fn allowed(self: *const Profile, edge: DirectedEdge) bool {
        return self.allowedCandidate(edge.class, .{}, .{});
    }

    pub fn allowedNode(self: *const Profile, node: *const NodeHot) bool {
        return self.permission.allowedNode(node);
    }

    pub fn allowedCandidate(self: *const Profile, class: *const EdgeClass, state: base.EdgeState, disallow: base.Disallow) bool {
        return !class.flags.bike_share_connection and
            (self.avoid_bad_surfaces != 1 or class.category.surface <= @backingInt(self.surface_limit)) and
            self.permission.allowedCandidate(class, state, disallow);
    }

    pub fn pathClassAllowed(self: *const Profile, class: *const EdgeClass) bool {
        return self.permission.accessibleClass(class) and class.category.surface <= @backingInt(self.surface_limit) and
            switch (class.category.use) {
                @backingInt(Use.transit_connection), @backingInt(Use.egress_connection), @backingInt(Use.platform_connection) => false,
                else => true,
            };
    }

    /// BicycleCost::AStarCostFactor.
    pub fn upstreamAStarCostFactor(self: *const Profile) f32 {
        const speed: u8 = @intFromFloat(2 * self.cycling_speed);
        return seconds_per_metre[speed] * self.min_linear_factor;
    }

    pub fn l2CostFactor(self: *const Profile, ferry_upper: u8) f32 {
        if (self.shared.shortest) return 1 - 0x1p-20;
        const speed = @max(5, self.bike_speeds[0][0]);
        const rolling = seconds_per_metre[speed] * self.min_linear_factor;
        const steps = seconds_per_metre[1] * self.steps_factor;
        const ferry = if (ferry_upper == 0) inf else seconds_per_metre[ferry_upper] * self.shared.ferry_factor;
        return @min(rolling, steps, ferry) * (1 - 0x1p-20);
    }
};

const RequestOptions = Options;
pub const Model = struct {
    pub const Options = RequestOptions;
    pub const Canonical = Profile;

    /// BicycleCost::BicycleCost.
    pub fn canonicalize(options: RequestOptions) !Profile {
        for (options.shared.floats.values) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidBicycleOptions;
        }
        for ([_]f32{ options.use_roads, options.use_hills, options.avoid_bad_surfaces, options.min_linear_factor }) |fraction| {
            if (!(0 <= fraction and fraction <= 1)) return error.InvalidBicycleOptions;
        }
        if (!(5 <= options.cycling_speed and options.cycling_speed <= 60) or
            !(0.1 <= options.steps_factor and options.steps_factor <= 100_000) or
            !(0 <= options.bss_return_cost and options.bss_return_cost <= base.max_penalty) or
            !(0 <= options.bss_return_penalty and options.bss_return_penalty <= base.max_penalty))
            return error.InvalidBicycleOptions;

        var shared: base.Shared = .init(options.shared);
        shared.bike_share = .{ .cost = options.bss_return_cost + options.bss_return_penalty, .secs = options.bss_return_cost };
        const roads = options.use_roads;
        const avoid = 1 - roads;
        const threshold = surface_threshold[@backingInt(options.bicycle_type)];
        const lane_shared = 0.9 + roads * 0.05;
        const lane_dedicated = 0.4 + roads * 0.45;
        const lane_separated = 0.15 + roads * 0.6;
        const path_shared = 0.2 + roads;
        var hills: [16]f32 = undefined;
        for (&hills, hill_strength) |*result, strength| result.* = (1 - options.use_hills) * strength;
        var bike_speeds: [8][16]u8 = undefined;
        for (&bike_speeds, surface_speed[@backingInt(options.bicycle_type)]) |*row, surface| {
            for (row, grade_speed) |*speed, grade|
                speed.* = @intFromFloat(options.cycling_speed * surface * grade + 0.5);
        }
        var speed_stress: [256]f32 = undefined;
        speed_stress[0] = 0;
        const avoid_weight = avoid * 0.75 + 0.25;
        for (1..speed_stress.len) |s| {
            const speed: f32 = @floatFromInt(s);
            const penalty = if (s <= 40) speed / 40 else if (s <= 65) speed / 25 - 0.6 else speed / 50 + 0.7;
            speed_stress[s] = (penalty - 1) * avoid_weight + 1;
        }
        return .{
            .shared = shared,
            .permission = .init(options.shared, .{ .bicycle = true }, false),
            .bicycle_type = options.bicycle_type,
            .cycling_speed = options.cycling_speed,
            .use_roads = roads,
            .road_factor = if (roads >= 0.5) 1.5 - roads else 2 - roads * 2,
            .sidepath_factor = 3 * avoid,
            .livingstreet_factor = 0.2 + roads * 0.8,
            .cyclestreet_factor = 0.2 + roads * 0.5,
            .track_factor = 0.5 + roads,
            .avoid_bad_surfaces = options.avoid_bad_surfaces,
            .surface_threshold = threshold,
            .surface_limit = if (options.avoid_bad_surfaces == 1) threshold else .path,
            .steps_factor = options.steps_factor,
            .lanes = .{ 1, lane_shared, lane_dedicated, lane_separated, 0.7 + roads * 0.2, lane_shared, lane_dedicated, lane_separated },
            .path_lanes = .{ path_shared, path_shared, 0.1 + roads * 0.9, roads * 0.8 },
            .bike_speeds = bike_speeds,
            .speed_stress = speed_stress,
            .hills = hills,
            .may_allow_edges = options.may_allow_edges,
            .min_linear_factor = options.min_linear_factor,
        };
    }

    pub fn rules(profile: Profile) !compiled.Rules {
        var hash = std.crypto.hash.Blake3.init(.{});
        hash.update("bicycle");
        hash.update(&.{@intFromBool(profile.shared.shortest)});
        if (!profile.shared.shortest) {
            hash.update(&.{@backingInt(profile.bicycle_type)});
            hash.update(std.mem.asBytes(&profile.cycling_speed));
            hash.update(std.mem.asBytes(&profile.use_roads));
            hash.update(std.mem.asBytes(&profile.avoid_bad_surfaces));
            hash.update(std.mem.asBytes(&profile.hills));
        }
        var key: compiled.MetricKey = undefined;
        hash.final(&key);
        return .{ .floors = .{ .edge_factor = profile.min_linear_factor }, .model_metric_key = key };
    }

    /// The static part of BicycleCost::EdgeCost's roadway stress. The
    /// remaining speed and grade terms are read from each directed edge.
    pub fn classFactor(profile: Profile, class: EdgeClass) !f32 {
        if (!profile.may_allow_edges and (class.category.surface == @backingInt(Surface.impassable) or
            !profile.pathClassAllowed(&class))) return inf;
        if (profile.shared.shortest) return 1;
        const use = class.category.use;
        if (use == @backingInt(Use.steps)) return profile.steps_factor;
        if (use == @backingInt(Use.ferry)) return profile.shared.ferry_factor;
        var stress: f32 = 1;
        var accommodation: f32 = 1;
        if (isPath(use)) {
            accommodation = profile.path_lanes[class.category.cycle_lane];
        } else if (use == @backingInt(Use.mountain_bike) and profile.bicycle_type == .mountain) {
            accommodation = 0.3 + profile.use_roads;
        } else if (use == @backingInt(Use.living_street)) {
            stress = profile.livingstreet_factor;
        } else if (use == @backingInt(Use.cycle_street)) {
            stress = profile.cyclestreet_factor;
        } else if (use == @backingInt(Use.track)) {
            stress = profile.track_factor;
        } else {
            accommodation = profile.lanes[laneIndex(&class)];
            const extra_lanes: f32 = @floatFromInt(class.category.lanes -| 1);
            stress += extra_lanes * 0.05 * profile.road_factor;
            if (class.flags.truck_route) stress += 0.5;
            stress += profile.road_factor * classification_stress[class.category.road_class];
        }
        if (class.flags.use_sidepath) accommodation += profile.sidepath_factor;
        if (class.onBikeNetwork()) accommodation *= 0.95;
        return accommodation * stress;
    }
};

pub const Cache = compiled.Cache(Model);

pub const PathCheck = struct {
    previous_dead_end: bool = false,
    previous_bicycle: bool = true,
    backtrack: bool = false,
    shortcut: bool = false,
    avoided: bool = false,
    restricted: bool = false,
    allowed_by_linear_feature: bool = false,
};

pub const Kernel = struct {
    /// BicycleCost::Allowed with the two edges in travel order.
    pub fn allowed(profile: *const Profile, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck) bool {
        return allowedPath(profile, from, to, to, turn, check);
    }

    /// BicycleCost::AllowedReverse checks the candidate incoming edge.
    pub fn allowedReverse(profile: *const Profile, from: *const EdgeClass, to: *const EdgeClass, turn: base.Turn, check: PathCheck) bool {
        return allowedPath(profile, from, to, from, turn, check);
    }

    fn allowedPath(profile: *const Profile, from: *const EdgeClass, to: *const EdgeClass, candidate: *const EdgeClass, turn: base.Turn, check: PathCheck) bool {
        if (check.allowed_by_linear_feature) return true;
        return !check.shortcut and !check.avoided and !check.restricted and
            !(check.backtrack and !check.previous_dead_end and check.previous_bicycle) and
            profile.permission.allowsTurnRestriction(turn) and
            profile.pathClassAllowed(candidate) and profile.permission.allowedExclusions(from, to);
    }

    /// BicycleCost::EdgeCost. All speed input is static, including ferry
    /// speed and the road speed used for the roadway stress penalty.
    pub fn edgeCost(profile: *const Profile, tables: *const compiled.Compiled, class: *const EdgeClass, edge: EdgeHot, effects: compiled.Effects) Cost {
        const factor = tables.factor(edge.cls.class_id);
        if (effects.forbidden or factor == inf) return .forbidden;
        const distance: f32 = @floatFromInt(edge.geom.len_m);
        const use = class.category.use;
        if (use == @backingInt(Use.steps) or use == @backingInt(Use.ferry)) {
            const speed = if (use == @backingInt(Use.steps)) 1 else edge.speed[0];
            const secs = distance * seconds_per_metre[speed];
            return .{ .cost = if (profile.shared.shortest) distance else secs * factor, .secs = secs };
        }
        const surface = class.category.surface;
        const grade = edge.geom.grade;
        const speed: u8 = if (class.flags.dismount) 5 else profile.bike_speeds[surface][grade];
        const secs = distance * seconds_per_metre[speed];
        if (profile.shared.shortest) return .{ .cost = distance, .secs = secs };
        const stress = if (usesRoadSpeed(use, profile.bicycle_type)) factor * profile.speed_stress[edge.speed[0]] else factor;
        var weight = 1 + profile.hills[grade] + stress;
        const threshold = @backingInt(profile.surface_threshold);
        if (surface >= threshold) weight += profile.avoid_bad_surfaces * surface_penalty[surface - threshold];
        std.debug.assert(std.math.isFinite(effects.factor) and effects.factor >= profile.min_linear_factor);
        return (Cost{ .cost = @min(secs * (weight * effects.factor), std.math.floatMax(f32)), .secs = secs }).add(effects.penalty);
    }

    pub fn edgeLowerBound(profile: *const Profile, tables: *const compiled.Compiled, class: *const EdgeClass, edge: EdgeHot) compiled.Tick {
        const cost = edgeCost(profile, tables, class, edge, .{ .factor = profile.min_linear_factor });
        return if (cost.cost == inf) compiled.forbidden_tick else compiled.floorTicks(cost.cost);
    }

    pub fn turnLowerBound() compiled.Tick {
        // A name-consistent turn at a junction with no stop impact and no
        // upward class transition can be free.
        return 0;
    }

    /// BicycleCost::TransitionCost and TransitionCostReverse use travel
    /// order; the reverse relaxation takes both classes from opposing edges.
    pub fn turnCost(profile: *const Profile, node: *const NodeHot, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) Cost {
        var cost = profile.shared.transition(node, from, to, turn.base_turn);
        const use = to.category.use;
        const to_class = to.category.road_class;
        const junction = @intFromBool(node.attr.drive_on_left);
        const kind = turn.base_turn.kind();
        const stop: f32 = @floatFromInt(turn.base_turn.stopImpact());
        const duration = if (turn.sides.left and turn.sides.right) @max(0.75, turn_time[junction][kind]) else turn_time[junction][kind];
        const secs = stop * duration;
        if (!profile.shared.shortest) {
            const class_factor: f32 = if (isPath(use)) 0.1 else classification_stress[to_class];
            const avoid = 1 - profile.use_roads;
            var stress = 1 + if (stop > 0) turn_penalty[junction][kind] else @as(f32, 0);
            stress *= class_factor * avoid + profile.use_roads + 1;
            var penalty: f32 = 0;
            if (to_class < from.category.road_class and use != @backingInt(Use.living_street)) {
                const accommodation: f32 = if (isPath(use)) 0.05 else turn_lane[laneIndex(to)];
                const increase: f32 = @floatFromInt(from.category.road_class - to_class);
                penalty = (10 * increase) * (accommodation * avoid + profile.use_roads);
                stress += if (node.attr.signal != 0) @as(f32, 0.4) else 1;
            }
            cost.cost += secs * (stress + 1) + penalty;
        }
        cost.secs += secs;
        return cost;
    }
};

fn laneIndex(class: *const EdgeClass) u3 {
    return @as(u3, @intFromBool(class.flags.shoulder)) * 4 + class.category.cycle_lane;
}

fn isPath(use: u6) bool {
    return use == @backingInt(Use.cycleway) or use == @backingInt(Use.footway) or use == @backingInt(Use.path);
}

fn usesRoadSpeed(use: u6, bicycle_type: Type) bool {
    return !isPath(use) and
        !(use == @backingInt(Use.mountain_bike) and bicycle_type == .mountain) and
        use != @backingInt(Use.living_street) and use != @backingInt(Use.cycle_street) and use != @backingInt(Use.track);
}

fn testClass(use: Use) EdgeClass {
    return .{
        .category = .{ .use = @intCast(@backingInt(use)) },
        .access = .{ .forward = @bitCast(@as(graph.constants.AccessMask, .{ .bicycle = true })) },
    };
}

fn testEdge(id: graph.class_table.ClassId, length: u24, grade: u4, speed: u8) EdgeHot {
    return .{
        .head = 0,
        .geom = .{ .len_m = length, .grade = grade, .curvature = 0 },
        .cls = .{ .class_id = id, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = .{ speed, 0, 0, 0 },
    };
}

// Ported from the INLINE_TEST BicycleCost parameter cases.
test "bicycle options match Valhalla ranges and type-specific defaults" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const cases = [_]struct { name: []const u8, bike: Type, speed: f32, threshold: Surface }{
        .{ .name = "road", .bike = .road, .speed = 25, .threshold = .compacted },
        .{ .name = "CrOsS", .bike = .cross, .speed = 20, .threshold = .gravel },
        .{ .name = "hybrid", .bike = .hybrid, .speed = 18, .threshold = .dirt },
        .{ .name = "mountain", .bike = .mountain, .speed = 16, .threshold = .path },
        .{ .name = "other", .bike = .hybrid, .speed = 18, .threshold = .dirt },
    };
    for (cases) |item| {
        const body = try std.fmt.allocPrint(arena, "{{\"bicycle_type\":\"{s}\"}}", .{item.name});
        const options = try parse(arena, try json.parse(arena, body), &warnings, .none);
        const profile = try Model.canonicalize(options);
        try t.expectEqual(item.bike, options.bicycle_type);
        try t.expectEqual(item.speed, options.cycling_speed);
        try t.expectEqual(item.threshold, profile.surface_threshold);
        try t.expectEqual(Surface.path, profile.surface_limit);
        try t.expectEqual(@as(f32, 0.25), options.use_roads);
        try t.expectEqual(@as(f32, 0.25), options.use_hills);
        try t.expectEqual(@as(f32, 0.25), options.avoid_bad_surfaces);
        try t.expectEqual(@as(f32, 8), options.steps_factor);
        try t.expectEqual(@as(f32, 60), profile.shared.alley_penalty);
        try t.expectEqual(Cost{ .cost = 330, .secs = 30 }, profile.shared.gate);
        try t.expectEqual(Cost{ .cost = 120, .secs = 120 }, profile.shared.bike_share);
    }
    try t.expectEqual(0, warnings.items.len);
    const options = try parse(arena, try json.parse(arena,
        \\{"bicycle_type":"road","cycling_speed":60.1,"use_roads":1.1,"use_hills":-0.1,
        \\ "avoid_bad_surfaces":2,"steps_factor":0.05,"bss_return_cost":43201,"bss_return_penalty":-1}
    ), &warnings, .none);
    const names = [_][]const u8{ "use_roads", "use_hills", "avoid_bad_surfaces", "steps_factor", "cycling_speed", "bss_return_cost", "bss_return_penalty" };
    try t.expectEqual(names.len, warnings.items.len);
    for (names, warnings.items) |name, warning| try t.expectEqualStrings(name, warning.option);
    try t.expectEqual(@as(f32, 25), options.cycling_speed);
    try t.expectEqual(@as(f32, 8), options.steps_factor);

    var prng = std.Random.DefaultPrng.init(0);
    for (0..250) |_| {
        const speed = prng.random().float(f32) * 115 - 20;
        const body = try std.fmt.allocPrint(arena, "{{\"cycling_speed\":{d},\"bicycle_type\":\"mountain\"}}", .{speed});
        warnings.clearRetainingCapacity();
        const sampled = try parse(arena, try json.parse(arena, body), &warnings, .none);
        try t.expectEqual(if (speed < 5 or speed > 60) @as(f32, 16) else speed, sampled.cycling_speed);
    }
}

test "bicycle directional and snap restrictions use upstream surface and turn rules" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    var options = try parse(arena, try json.parse(arena,
        \\{"bicycle_type":"road","avoid_bad_surfaces":1,"exclude_bridges":true}
    ), &warnings, .none);
    var profile = try Model.canonicalize(options);
    const from = testClass(.road);
    var to = testClass(.road);
    const normal: base.Turn = .{ .row = 0x40 };
    const restricted: base.Turn = .{ .row = 0xc0 };
    try t.expect(Kernel.allowed(&profile, &from, &to, normal, .{}));
    try t.expect(!Kernel.allowed(&profile, &from, &to, restricted, .{}));
    try t.expect(!Kernel.allowedReverse(&profile, &from, &to, restricted, .{}));
    options.shared.flags.insert(.ignore_non_vehicular_restrictions);
    profile = try Model.canonicalize(options);
    try t.expect(Kernel.allowedReverse(&profile, &from, &to, restricted, .{}));
    try t.expect(!Kernel.allowed(&profile, &from, &to, normal, .{ .backtrack = true }));
    try t.expect(Kernel.allowed(&profile, &from, &to, normal, .{ .backtrack = true, .previous_dead_end = true }));
    to.category.surface = @backingInt(Surface.gravel);
    try t.expect(!profile.allowedCandidate(&to, .{}, .{}));
    try t.expect(!Kernel.allowed(&profile, &from, &to, normal, .{}));
    try t.expect(!Kernel.allowedReverse(&profile, &to, &from, normal, .{}));
    try t.expect(Kernel.allowed(&profile, &from, &to, normal, .{ .allowed_by_linear_feature = true }));
    options.avoid_bad_surfaces = 0.99;
    profile = try Model.canonicalize(options);
    try t.expect(profile.allowedCandidate(&to, .{}, .{}));
    try t.expect(Kernel.allowed(&profile, &from, &to, normal, .{}));
    to.flags.bridge = true;
    try t.expect(!Kernel.allowed(&profile, &from, &to, normal, .{}));
    try t.expect(!Kernel.allowedReverse(&profile, &from, &to, normal, .{}));
    try t.expect(Kernel.allowedReverse(&profile, &to, &from, normal, .{}));
    to.flags.bike_share_connection = true;
    try t.expect(!profile.allowedCandidate(&to, .{}, .{}));
}

test "bicycle bounds hold over grade, speed, lane, surface and preference ranges" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const defaults = try parse(arena_state.allocator(), .null, &warnings, .none);
    const uses = [_]Use{ .road, .cycleway, .footway, .path, .mountain_bike, .living_street, .cycle_street, .track, .steps, .ferry, .rail_ferry, .service_road, .alley, .driveway };
    var prng = std.Random.DefaultPrng.init(0x1dea_f060);
    const random = prng.random();
    var classes: [uses.len + 2]EdgeClass = undefined;
    var factors: [classes.len]f32 = undefined;
    for (0..2048) |iteration| {
        var options = defaults;
        options.bicycle_type = @fromBackingInt(random.int(u2));
        options.cycling_speed = 5 + random.float(f32) * 55;
        options.use_roads = random.float(f32);
        options.use_hills = random.float(f32);
        options.avoid_bad_surfaces = if (iteration % 7 == 0) 1 else random.float(f32);
        options.steps_factor = if (iteration % 3 == 0) 0.1 else 0.1 + random.float(f32) * 99999.9;
        options.min_linear_factor = random.float(f32);
        options.shared.floats.set(.use_ferry, random.float(f32));
        options.shared.flags.setPresent(.shortest, iteration % 8 == 0);
        for (classes[0..uses.len], uses) |*class, use| {
            class.* = testClass(use);
            class.category.surface = random.uintLessThan(u3, 7);
            class.category.road_class = random.int(u3);
            class.category.cycle_lane = random.int(u2);
            class.category.lanes = random.int(u4);
            class.category.bike_network = random.int(u5);
            class.flags.shoulder = random.boolean();
            class.flags.dismount = random.boolean();
            class.flags.use_sidepath = random.boolean();
            class.flags.truck_route = random.boolean();
        }
        classes[uses.len] = testClass(.road);
        classes[uses.len].access.forward = 0;
        classes[uses.len + 1] = testClass(.road);
        classes[uses.len + 1].category.surface = @backingInt(Surface.impassable);

        const profile = try Model.canonicalize(options);
        const tables = try compiled.compileInto(Model, profile, &classes, &factors, .none);
        const node: NodeHot = .{
            .turn_off = 0,
            .attr = .{ .access = 0, .type = 0, .density = 0, .signal = random.int(u1), .drive_on_left = random.boolean() },
        };
        for (&classes, 0..) |*class, id| {
            const edge = testEdge(@intCast(id), random.int(u24), random.int(u4), random.int(u8));
            const gain = @max(profile.min_linear_factor, random.float(f32) * 2);
            const actual = Kernel.edgeCost(&profile, &tables, class, edge, .{ .factor = gain });
            const bound = Kernel.edgeLowerBound(&profile, &tables, class, edge);
            if (class.category.surface > @backingInt(profile.surface_limit) or class.access.forward == 0) {
                try t.expectEqual(Cost.forbidden, actual);
                try t.expectEqual(compiled.forbidden_tick, bound);
                continue;
            }
            try t.expect(std.math.isFinite(actual.cost) and actual.cost >= 0 and actual.secs >= 0);
            try t.expect(compiled.costUnits(bound) <= actual.cost);
            const l2 = @as(f64, profile.l2CostFactor(255)) * @as(f64, @floatFromInt(edge.geom.len_m));
            try t.expect(l2 <= actual.cost);
            const turn = Kernel.turnCost(&profile, &node, &classes[(id + 1) % classes.len], class, .{
                .base_turn = .{ .row = random.int(u7) },
                .sides = .{ .left = random.boolean(), .right = random.boolean() },
            });
            try t.expect(std.math.isFinite(turn.cost) and turn.cost >= 0 and turn.secs >= 0);
            try t.expect(compiled.costUnits(Kernel.turnLowerBound()) <= turn.cost);
        }
    }
}

test "minimum bicycle speed preserves Valhalla's finite zero-kph table entry" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const profile = try Model.canonicalize(try parse(arena, try json.parse(arena,
        \\{"bicycle_type":"road","cycling_speed":5}
    ), &warnings, .none));
    var class = testClass(.path);
    class.category.surface = @backingInt(Surface.path);
    const edge = testEdge(0, 11, 15, 0);
    var factors: [1]f32 = undefined;
    const table = try compiled.compileInto(Model, profile, &.{class}, &factors, .none);
    const cost = Kernel.edgeCost(&profile, &table, &class, edge, .{});
    try t.expectEqual(@as(f32, 39_600), cost.secs);
    try t.expect(std.math.isFinite(cost.cost));
    class.flags.dismount = true;
    const dismount = Kernel.edgeCost(&profile, &table, &class, edge, .{});
    try t.expectApproxEqAbs(@as(f32, 7.92), dismount.secs, 1e-5);
}

// Recorded from CreateBicycleCost in the pinned Valhalla 3.9.3 oracle.
test "bicycle edges and turns match pinned Valhalla cost tuples" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const settings = [_][]const u8{
        \\{"bicycle_type":"road","shortest":true,"cycling_speed":5,"use_roads":0.3,"use_hills":0,
        \\ "avoid_bad_surfaces":1,"use_ferry":0,"use_living_streets":0,"use_tracks":0.1,"steps_factor":0.1}
        ,
        \\{"bicycle_type":"mountain","cycling_speed":8,"use_roads":0.2,"use_hills":0.9,"avoid_bad_surfaces":0.3,
        \\ "use_ferry":0.3,"use_living_streets":1,"use_tracks":1,"steps_factor":2.2,"bss_return_penalty":30}
        ,
        \\{"bicycle_type":"cross","cycling_speed":14,"use_roads":0,"use_hills":0.5,"avoid_bad_surfaces":1,
        \\ "use_ferry":0.9,"use_living_streets":0.8,"use_tracks":0.6,"steps_factor":6.4,"bss_return_penalty":90}
        ,
    };
    const uses = [_]Use{ .road, .cycleway, .footway, .path, .mountain_bike, .living_street, .cycle_street, .track, .steps, .ferry, .alley, .rail_ferry, .service_road };
    const nodes = [_]graph.constants.NodeType{ .street_intersection, .gate, .bollard, .toll_booth, .border_control, .bike_share };
    const cases = [_]struct { profile: usize, group: usize, index: usize, edge_cost: Cost, turn_cost: Cost }{
        .{ .profile = 0, .group = 0, .index = 8, .edge_cost = .{ .cost = 2011, .secs = 7239.6001 }, .turn_cost = .{ .secs = 1.5 } },
        .{ .profile = 0, .group = 0, .index = 9, .edge_cost = .{ .cost = 2262, .secs = 325.728027 }, .turn_cost = .{ .secs = 300.600006 } },
        .{ .profile = 3, .group = 1, .index = 10, .edge_cost = .{ .cost = 17578.127, .secs = 4841.01855 }, .turn_cost = .{ .cost = 624.002014, .secs = 600.900024 } },
        .{ .profile = 3, .group = 1, .index = 14, .edge_cost = .{ .cost = 16775.3516, .secs = 11373.1201 }, .turn_cost = .{ .cost = 497.200012, .secs = 34 } },
        .{ .profile = 3, .group = 1, .index = 95, .edge_cost = .{ .cost = 13728.2607, .secs = 7225.3999 }, .turn_cost = .{ .cost = 165.639999, .secs = 122.800003 } },
        .{ .profile = 9, .group = 2, .index = 20, .edge_cost = .{ .cost = 81375.8438, .secs = 30139.2012 }, .turn_cost = .{ .cost = 212.5, .secs = 30 } },
        .{ .profile = 9, .group = 2, .index = 65, .edge_cost = .{ .cost = 1114.70679, .secs = 1857.8446 }, .turn_cost = .{ .cost = 543.150024, .secs = 421 } },
        .{ .profile = 9, .group = 2, .index = 88, .edge_cost = .{ .cost = 29373.3418, .secs = 16318.5234 }, .turn_cost = .{ .cost = 620.75, .secs = 603.75 } },
    };
    for (cases) |example| {
        const id = example.index;
        const mode = example.profile;
        const profile = try Model.canonicalize(try parse(arena, try json.parse(arena, settings[example.group]), &warnings, .none));
        const max_surface: usize = if (mode % 9 == 0) @backingInt(profile.surface_limit) else @backingInt(Surface.path);
        var class = testClass(uses[(id + mode) % uses.len]);
        class.category.surface = @intCast((id / 13 + mode) % (max_surface + 1));
        class.category.road_class = @intCast(id % 8);
        class.category.cycle_lane = @intCast((id / 11) % 4);
        class.category.lanes = @intCast(1 + (id / 7) % 15);
        class.category.bike_network = @intFromBool(id % 7 == 0);
        class.flags.shoulder = id % 2 == 0;
        class.flags.dismount = id % 7 == 0;
        class.flags.use_sidepath = id % 11 == 0;
        class.flags.truck_route = id % 4 == 0;
        class.flags.destination_only = id % 17 == 0;
        class.flags.internal = id % 19 == 0;
        class.flags.link = id % 11 == 0;

        var previous = testClass(uses[(id / 5) % uses.len]);
        previous.category.road_class = @intCast((id / 5 + mode) % 8);
        previous.flags.destination_only = id % 23 == 0;
        const edge = testEdge(0, @intCast(3 + ((id * 251 + mode * 4093) % 70000)), @intCast((id / 7 + mode) % 16), @intCast(@min(140, (id * 59 + mode * 7) % 253)));
        const node: NodeHot = .{
            .turn_off = 0,
            .attr = .{
                .access = 0,
                .signal = @intFromBool(id % 7 != 0),
                .density = 0,
                .type = @backingInt(nodes[id % nodes.len]),
                .drive_on_left = id % 11 == 0,
                .tagged_access = id % 3 != 0,
                .private_access = id % 7 == 0,
            },
        };
        var factors: [1]f32 = undefined;
        const tables = try compiled.compileInto(Model, profile, &.{class}, &factors, .none);
        const cost = Kernel.edgeCost(&profile, &tables, &class, edge, .{});
        const turn = Kernel.turnCost(&profile, &node, &previous, &class, .{
            .base_turn = .{ .row = @as(u8, @intCast((id / 3 % 8) * 8 + id % 8)) | (if (id % 7 == 0) @as(u8, 0x40) else 0) },
            .sides = .{ .left = id % 3 != 0, .right = id % 5 != 0 },
        });
        try t.expectApproxEqRel(example.edge_cost.cost, cost.cost, 1e-5);
        try t.expectApproxEqRel(example.edge_cost.secs, cost.secs, 1e-5);
        try t.expectApproxEqRel(example.turn_cost.cost, turn.cost, 1e-5);
        try t.expectApproxEqRel(example.turn_cost.secs, turn.secs, 1e-5);
    }
    try t.expectEqual(0, warnings.items.len);
}
