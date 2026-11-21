// Ported from src/sif/pedestriancost.cc (Valhalla 3.9.3).
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
pub const Type = graph.constants.PedestrianType;

const grade_speed = [16]f32{ 1.33, 1.22, 1.08, 0.97, 0.88, 0.92, 1, 1.10, 1.20, 1.33, 1.43, 1.57, 1.83, 2.03, 2.23, 2.50 };
const hill_strength = [16]f32{ 2, 1, 0.5, 0.2, 0.1, 0, 0, 0, 0.1, 0.3, 0.4, 0.5, 0.7, 1, 3, 5 };
const sac_speed = [7]f32{ 1, 1.11, 1.25, 1.54, 2.5, 4, 6.67 };
const sac_cost = [7]f32{ 0, 0.25, 0.75, 1.25, 2, 2.5, 3 };
const crossing_costs = [8]f32{ 0, 0, 1, 1, 2, 3, 5, 15 };
const kmh_seconds: f32 = @as(f32, 3600) * @as(f32, 0.001);
const inf = std.math.inf(f32);

pub const Options = struct {
    shared: base.Options,
    transport: Type = .foot,
    max_distance: u32 = 100_000,
    walking_speed: f32 = 5.1,
    step_penalty: f32 = 30,
    max_grade: u32 = 90,
    max_hiking_difficulty: u3 = 1,
    mode_factor: f32 = 1.5,
    walkway_factor: f32 = 1,
    sidewalk_factor: f32 = 1,
    alley_factor: f32 = 2,
    driveway_factor: f32 = 5,
    transit_start_end_max_distance: u32 = 2415,
    transit_transfer_max_distance: u32 = 805,
    bss_rent_cost: f32 = 120,
    bss_rent_penalty: f32 = 0,
    use_hills: f32 = 0.5,
    elevator_penalty: f32 = 5,
    multimodal_start_end_max_distance: u32 = 2415,
    /// Request-local linear features are checked during relaxation. These
    /// fields describe the maximum change they can make to the static metric.
    may_allow_edges: bool = false,
    min_linear_factor: f32 = 1,
};

fn sharedConfig() base.Config {
    var config: base.Config = .{ .disable_toll_booth = true, .disable_rail_ferry = true };
    config.ranges.set(.gate_penalty, .penalty(10));
    config.ranges.set(.private_access_penalty, .penalty(600));
    config.ranges.set(.service_penalty, .penalty(0));
    config.ranges.set(.use_ferry, .preference(1));
    config.ranges.set(.use_living_streets, .preference(0.6));
    return config;
}

/// ParsePedestrianCostOptions. The input is costing_options.pedestrian.
pub fn parse(arena: std.mem.Allocator, input: json.Value, warnings: *std.ArrayList(base.Warning), deadline: Deadline) !Options {
    const shared = try base.parse(arena, input, sharedConfig(), warnings, deadline);
    const name = json.get([]const u8, input, "/type", "foot");
    const transport: Type = if (std.ascii.eqlIgnoreCase(name, "wheelchair"))
        .wheelchair
    else if (std.ascii.eqlIgnoreCase(name, "blind"))
        .blind
    else
        .foot;
    const chair = transport == .wheelchair;
    return .{
        .shared = shared,
        .transport = transport,
        .max_distance = try base.rangedUnsigned(arena, input, "max_distance", if (chair) 10_000 else 100_000, 100_000, warnings),
        .walking_speed = try base.rangedFloat(arena, input, "walking_speed", .{ .min = 0.5, .default = if (chair) 4 else 5.1, .max = 25 }, warnings),
        .step_penalty = try base.rangedFloat(arena, input, "step_penalty", .penalty(if (chair) 600 else 30), warnings),
        .max_grade = try base.rangedUnsigned(arena, input, "max_grade", if (chair) 12 else 90, 90, warnings),
        .max_hiking_difficulty = @intCast(try base.rangedUnsigned(arena, input, "max_hiking_difficulty", 1, 6, warnings)),
        .mode_factor = try base.rangedFloat(arena, input, "mode_factor", .factor(1.5), warnings),
        .walkway_factor = try base.rangedFloat(arena, input, "walkway_factor", .factor(1), warnings),
        .sidewalk_factor = try base.rangedFloat(arena, input, "sidewalk_factor", .factor(1), warnings),
        .alley_factor = try base.rangedFloat(arena, input, "alley_factor", .factor(2), warnings),
        .driveway_factor = try base.rangedFloat(arena, input, "driveway_factor", .factor(5), warnings),
        .transit_start_end_max_distance = try base.rangedUnsigned(arena, input, "transit_start_end_max_distance", 2415, 100_000, warnings),
        .transit_transfer_max_distance = try base.rangedUnsigned(arena, input, "transit_transfer_max_distance", 805, 50_000, warnings),
        .bss_rent_cost = try base.rangedFloat(arena, input, "bss_rent_cost", .penalty(120), warnings),
        .bss_rent_penalty = try base.rangedFloat(arena, input, "bss_rent_penalty", .penalty(0), warnings),
        .use_hills = try base.rangedFloat(arena, input, "use_hills", .preference(0.5), warnings),
        .elevator_penalty = try base.rangedFloat(arena, input, "elevator_penalty", .penalty(5), warnings),
        .multimodal_start_end_max_distance = try base.rangedUnsigned(arena, input, "multimodal_start_end_max_distance", 2415, 100_000, warnings),
    };
}

pub const Profile = struct {
    shared: base.Shared,
    permission: base.Permission,
    transport: Type,
    surface_limit: Surface,
    max_hiking_difficulty: u3,
    max_distance: u32,
    walking_seconds_per_metre: f32,
    step_penalty: f32,
    elevator_penalty: f32,
    walkway_factor: f32,
    sidewalk_factor: f32,
    alley_factor: f32,
    driveway_factor: f32,
    hills: [16]f32,
    may_allow_edges: bool,
    min_linear_factor: f32,
    allow_transit_connections: bool = false,

    /// PedestrianCost::Allowed for candidate/reach search.
    pub fn allowed(self: *const Profile, edge: DirectedEdge) bool {
        return self.allowedCandidate(edge.class, .{}, .{}, false);
    }

    pub fn allowedNode(self: *const Profile, node: *const NodeHot) bool {
        return self.permission.allowedNode(node);
    }

    pub fn allowedCandidate(self: *const Profile, edge: *const EdgeClass, state: base.EdgeState, disallow: base.Disallow, project_on_bss: bool) bool {
        return edge.category.use < @backingInt(Use.rail_ferry) and
            edge.category.sac_scale <= self.max_hiking_difficulty and
            (!edge.flags.bike_share_connection or project_on_bss) and
            self.permission.allowedCandidate(edge, state, disallow);
    }

    pub fn pathClassAllowed(self: *const Profile, edge: *const EdgeClass) bool {
        return self.permission.accessibleClass(edge) and
            edge.category.surface <= @backingInt(self.surface_limit) and
            edge.category.sac_scale <= self.max_hiking_difficulty and
            (self.allow_transit_connections or !isTransitConnection(edge.category.use));
    }

    fn useFactor(self: *const Profile, use: u6) f32 {
        return switch (use) {
            @backingInt(Use.footway) => self.walkway_factor,
            @backingInt(Use.sidewalk) => self.sidewalk_factor,
            @backingInt(Use.alley) => self.alley_factor,
            @backingInt(Use.driveway) => self.driveway_factor,
            @backingInt(Use.track) => self.shared.tracks.factor,
            @backingInt(Use.living_street) => self.shared.living_streets.factor,
            @backingInt(Use.service_road) => self.shared.service_factor,
            else => 0,
        };
    }

    /// PedestrianCost::AStarCostFactor, for comparing upstream passes.
    pub fn upstreamAStarCostFactor(self: *const Profile, pass: u8) f32 {
        if (pass != 0) return (kmh_seconds / 40.0) * self.min_linear_factor;
        var factor: f32 = 1;
        for ([_]f32{
            self.walkway_factor,       self.sidewalk_factor,              self.alley_factor,          self.driveway_factor,
            self.shared.tracks.factor, self.shared.living_streets.factor, self.shared.service_factor,
        }) |value| factor *= @min(1, value);
        return (self.walking_seconds_per_metre * factor) * self.min_linear_factor;
    }

    /// L2 lower bound for every allowed grade, use and ferry speed. Pass the
    /// graph's verified maximum ferry speed, or 255 for any encoded speed.
    pub fn l2CostFactor(self: *const Profile, ferry_upper: u8) f32 {
        const use_floor = @min(1, self.walkway_factor, self.sidewalk_factor, self.alley_factor, self.driveway_factor, self.shared.tracks.factor, self.shared.living_streets.factor, self.shared.service_factor);
        const walking = if (self.shared.shortest)
            1
        else
            self.walking_seconds_per_metre * grade_speed[4] * use_floor * self.min_linear_factor;
        const ferry = if (ferry_upper == 0)
            std.math.inf(f32)
        else
            (kmh_seconds / @as(f32, @floatFromInt(ferry_upper))) * self.shared.ferry_factor;
        // Round toward zero with the same margin used by the tick bounds.
        return @min(walking, ferry) * (1 - 0x1p-20);
    }

    /// The upstream choice with no departure time or traffic data.
    pub fn untimedFerrySpeed(self: *const Profile, edge: EdgeHot) u8 {
        return graph.speed.untimed(edge, self.permission.flow, false).kph;
    }
};

const RequestOptions = Options;

pub const Model = struct {
    pub const Options = RequestOptions;
    pub const Canonical = Profile;

    pub fn canonicalize(options: RequestOptions) !Profile {
        for (options.shared.floats.values) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPedestrianOptions;
        }
        for ([_]f32{
            options.walking_speed,   options.step_penalty,     options.elevator_penalty,  options.walkway_factor,
            options.sidewalk_factor, options.alley_factor,     options.driveway_factor,   options.use_hills,
            options.bss_rent_cost,   options.bss_rent_penalty, options.min_linear_factor,
        }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPedestrianOptions;
        }
        if (options.walking_speed < 0.5 or options.walking_speed > 25 or options.use_hills > 1 or
            options.min_linear_factor > 1 or options.max_hiking_difficulty > 6) return error.InvalidPedestrianOptions;

        var shared: base.Shared = .init(options.shared);
        shared.bike_share = .{ .cost = options.bss_rent_cost + options.bss_rent_penalty, .secs = options.bss_rent_cost };
        var hills: [16]f32 = undefined;
        for (&hills, hill_strength) |*penalty, strength| penalty.* = (1 - options.use_hills) * strength;
        const chair = options.transport == .wheelchair;
        const mask: graph.constants.AccessMask = if (chair) .{ .wheelchair = true } else .{ .pedestrian = true };
        return .{
            .shared = shared,
            .permission = .init(options.shared, mask, false),
            .transport = options.transport,
            .surface_limit = if (chair) .compacted else .path,
            .max_hiking_difficulty = if (options.transport == .foot) options.max_hiking_difficulty else 0,
            .max_distance = options.max_distance,
            .walking_seconds_per_metre = kmh_seconds / options.walking_speed,
            .step_penalty = options.step_penalty,
            .elevator_penalty = options.elevator_penalty,
            .walkway_factor = options.walkway_factor,
            .sidewalk_factor = options.sidewalk_factor,
            .alley_factor = options.alley_factor,
            .driveway_factor = options.driveway_factor,
            .hills = hills,
            .may_allow_edges = options.may_allow_edges,
            .min_linear_factor = options.min_linear_factor,
        };
    }

    pub fn rules(profile: Profile) !compiled.Rules {
        var hash = std.crypto.hash.Blake3.init(.{});
        hash.update("pedestrian");
        hash.update(&.{@intFromBool(profile.shared.shortest)});
        if (profile.allow_transit_connections) hash.update("transit-connections");
        if (!profile.shared.shortest) {
            hash.update(std.mem.asBytes(&profile.walking_seconds_per_metre));
            hash.update(std.mem.asBytes(&profile.hills));
        }
        var key: compiled.MetricKey = undefined;
        hash.final(&key);
        return .{ .floors = .{ .edge_factor = profile.min_linear_factor }, .model_metric_key = key };
    }

    pub fn classFactor(profile: Profile, edge: EdgeClass) !f32 {
        if (!profile.may_allow_edges and !profile.pathClassAllowed(&edge)) return inf;
        if (isUse(&edge, .ferry)) return profile.shared.ferry_factor;
        if (profile.shared.shortest) return 1;
        var factor = profile.useFactor(edge.category.use);
        if (factor == 0) {
            factor = if (edge.flags.sidewalk_left or edge.flags.sidewalk_right)
                profile.sidewalk_factor
            else if (edge.flags.roundabout)
                2
            else
                1;
        }
        return factor * if (edge.flags.lit) @as(f32, 1) else profile.shared.unlit_factor;
    }
};

pub const Cache = compiled.Cache(Model);

pub const PathCheck = struct {
    previous_distance: u32 = 0,
    previous_dead_end: bool = false,
    previous_pedestrian: bool = true,
    backtrack: bool = false,
    shortcut: bool = false,
    avoided: bool = false,
    restricted: bool = false,
    allowed_by_linear_feature: bool = false,
};

pub const Turn = struct {
    base_turn: base.Turn,
    sides: graph.turn_sides.Sides = .{},
    levels: u32 = 1,

    /// Uses the incoming opposing local even during reverse traversal.
    pub fn read(view: *const graph.reader.View, node: graph.format.NodeId, incoming: graph.format.EdgeId, outgoing: graph.format.EdgeId) !Turn {
        const common = try base.IntersectionTurn.read(view, node, incoming, outgoing);
        return .{
            .base_turn = common.base_turn,
            .sides = common.sides,
            .levels = if ((try view.node(node)).attr.type == @backingInt(graph.constants.NodeType.elevator))
                try elevatorLevels(view, incoming, outgoing)
            else
                1,
        };
    }
};

noinline fn elevatorLevels(view: *const graph.reader.View, incoming: graph.format.EdgeId, outgoing: graph.format.EdgeId) !u32 {
    if (view.cold_data == null) return 1;
    const entry = (try view.coldRecord(incoming)).indoor.levels;
    const exit = (try view.coldRecord(outgoing)).indoor.levels;
    if (entry.len != 1 or exit.len != 1) return 1;
    if (entry[0].bounds.first != entry[0].bounds.last or exit[0].bounds.first != exit[0].bounds.last) return 1;
    const delta = @abs(entry[0].bounds.first - exit[0].bounds.first);
    if (!std.math.isFinite(delta)) return error.InvalidColdIndoorData;
    return @intFromFloat(@min(@as(f64, delta), std.math.maxInt(u32)));
}

pub const Kernel = struct {
    /// PedestrianCost::Allowed in forward travel order. Conditional access
    /// restrictions live in the graph's cold policy for the search.
    pub fn allowed(profile: *const Profile, previous: *const EdgeClass, next: *const EdgeClass, edge: EdgeHot, check: PathCheck) bool {
        return allowedPath(profile, previous, next, next, check) and
            (check.allowed_by_linear_feature or profile.allow_transit_connections or
                @as(u64, check.previous_distance) + edge.geom.len_m <= profile.max_distance);
    }

    /// PedestrianCost::AllowedReverse. The limit applies to the completed
    /// route. Valhalla does not apply it when growing the reverse search.
    pub fn allowedReverse(profile: *const Profile, incoming: *const EdgeClass, outgoing: *const EdgeClass, check: PathCheck) bool {
        return allowedPath(profile, incoming, outgoing, incoming, check);
    }

    fn allowedPath(profile: *const Profile, incoming: *const EdgeClass, outgoing: *const EdgeClass, candidate: *const EdgeClass, check: PathCheck) bool {
        if (check.allowed_by_linear_feature) return true;
        return !check.shortcut and !check.avoided and !check.restricted and
            !(check.backtrack and !check.previous_dead_end and check.previous_pedestrian) and
            profile.pathClassAllowed(candidate) and profile.permission.allowedExclusions(incoming, outgoing);
    }

    /// PedestrianCost::EdgeCost. The caller supplies the resolved ferry
    /// speed. Ordinary edges use the walking pace and directional grade.
    pub fn edgeCost(profile: *const Profile, tables: *const compiled.Compiled, class: *const EdgeClass, edge: EdgeHot, ferry_speed: u8, effects: compiled.Effects) Cost {
        const factor = tables.factor(edge.cls.class_id);
        if (effects.forbidden or factor == inf or class.category.sac_scale >= sac_speed.len) return .forbidden;
        const distance: f32 = @floatFromInt(edge.geom.len_m);
        if (isUse(class, .ferry)) {
            if (ferry_speed == 0) return .forbidden;
            const secs = distance * kmh_seconds / @as(f32, @floatFromInt(ferry_speed));
            return .{ .cost = secs * factor, .secs = secs };
        }
        const sac = class.category.sac_scale;
        const grade = edge.geom.grade;
        const secs = distance * profile.walking_seconds_per_metre * sac_speed[sac] * grade_speed[grade];
        if (profile.shared.shortest) return .{ .cost = distance, .secs = secs };
        const slope_factor = 1 + sac_cost[sac] + profile.hills[grade];
        const weighted = secs * (slope_factor * factor);
        std.debug.assert(std.math.isFinite(effects.factor) and effects.factor >= profile.min_linear_factor);
        return (Cost{ .cost = @min(weighted * effects.factor, std.math.floatMax(f32)), .secs = secs }).add(effects.penalty);
    }

    pub fn edgeLowerBound(profile: *const Profile, tables: *const compiled.Compiled, class: *const EdgeClass, edge: EdgeHot, ferry_upper: u8) compiled.Tick {
        const factor = tables.factor(edge.cls.class_id);
        if (factor == inf or class.category.sac_scale >= sac_speed.len) return compiled.forbidden_tick;
        if (isUse(class, .ferry) and ferry_upper == 0) return 0;
        const cost = edgeCost(profile, tables, class, edge, ferry_upper, .{ .factor = profile.min_linear_factor });
        return compiled.floorTicks(cost.cost);
    }

    pub fn turnLowerBound() compiled.Tick {
        // A name-consistent transition with no crossing, or crossing with
        // zero stop impact, has zero cost for every pedestrian profile.
        return 0;
    }

    /// PedestrianCost::TransitionCost and TransitionCostReverse evaluate
    /// the same turn in travel order. Reverse search passes the opposed
    /// edges in travel order and supplies the same incoming/outgoing row.
    pub fn turnCost(profile: *const Profile, node: *const NodeHot, incoming: *const EdgeClass, outgoing: *const EdgeClass, turn: Turn) Cost {
        if (isUse(outgoing, .steps) or isUse(outgoing, .ladder)) return .{ .cost = profile.step_penalty };
        if (isUse(outgoing, .elevator)) return .{ .cost = profile.elevator_penalty };
        if (node.attr.type == @backingInt(graph.constants.NodeType.elevator))
            return .{ .cost = profile.elevator_penalty * @as(f32, @floatFromInt(turn.levels)) };
        var cost = profile.shared.modeTransition(true, node, incoming, outgoing, turn.base_turn);
        if (turn.sides.left and turn.sides.right) {
            const seconds = turn.base_turn.stopSeconds(&crossing_costs);
            cost.secs += seconds;
            if (!profile.shared.shortest) cost.cost += seconds;
        }
        return cost;
    }
};

fn isUse(edge: *const EdgeClass, use: Use) bool {
    return edge.category.use == @backingInt(use);
}

fn isTransitConnection(use: u6) bool {
    return use == @backingInt(Use.egress_connection) or use == @backingInt(Use.platform_connection) or use == @backingInt(Use.transit_connection);
}

fn testClass(use: Use) EdgeClass {
    return .{
        .category = .{ .use = @intCast(@backingInt(use)) },
        .access = .{ .forward = @bitCast(@as(graph.constants.AccessMask, .{ .pedestrian = true, .wheelchair = true })) },
    };
}

fn testEdge(id: graph.class_table.ClassId, length: u24, grade: u4) EdgeHot {
    return .{
        .head = 0,
        .geom = .{ .len_m = length, .grade = grade, .curvature = 0 },
        .cls = .{ .class_id = id, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = @splat(20),
    };
}

// Ported from the INLINE_TEST PedestrianCost parameter cases.
test "pedestrian option ranges and transport defaults match Valhalla" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const cases = [_]struct { type_name: []const u8, transport: Type, speed: f32, dist: u32, grade: u32, steps: f32, hiking: u3 }{
        .{ .type_name = "foot", .transport = .foot, .speed = 5.1, .dist = 100_000, .grade = 90, .steps = 30, .hiking = 1 },
        .{ .type_name = "WHEELCHAIR", .transport = .wheelchair, .speed = 4, .dist = 10_000, .grade = 12, .steps = 600, .hiking = 0 },
        .{ .type_name = "blind", .transport = .blind, .speed = 5.1, .dist = 100_000, .grade = 90, .steps = 30, .hiking = 0 },
        .{ .type_name = "other", .transport = .foot, .speed = 5.1, .dist = 100_000, .grade = 90, .steps = 30, .hiking = 1 },
    };
    for (cases) |item| {
        const body = try std.fmt.allocPrint(arena, "{{\"type\":\"{s}\"}}", .{item.type_name});
        const options = try parse(arena, try json.parse(arena, body), &warnings, .none);
        const profile = try Model.canonicalize(options);
        try t.expectEqual(item.transport, profile.transport);
        try t.expectEqual(item.speed, options.walking_speed);
        try t.expectEqual(item.dist, profile.max_distance);
        try t.expectEqual(item.grade, options.max_grade);
        try t.expectEqual(item.steps, profile.step_penalty);
        try t.expectEqual(item.hiking, profile.max_hiking_difficulty);
        try t.expectEqual(Cost{ .cost = 40, .secs = 30 }, profile.shared.gate);
        try t.expectEqual(Cost{ .cost = 630, .secs = 30 }, profile.shared.private_access);
        try t.expectEqual(Cost{}, profile.shared.toll_booth);
        try t.expectEqual(@as(f32, 0.5), profile.shared.ferry_factor);
        try t.expectEqual(2415, options.transit_start_end_max_distance);
        try t.expectEqual(805, options.transit_transfer_max_distance);
        try t.expectEqual(2415, options.multimodal_start_end_max_distance);
    }
    try t.expectEqual(0, warnings.items.len);
    const options = try parse(arena, try json.parse(arena,
        \\{"type":"wheelchair","walking_speed":50,"max_distance":100001,"max_grade":91,
        \\ "step_penalty":-1,"max_hiking_difficulty":7,"mode_factor":0,"walkway_factor":100001,
        \\ "sidewalk_factor":0,"alley_factor":100001,"driveway_factor":0,"transit_start_end_max_distance":100001,
        \\ "transit_transfer_max_distance":50001,"bss_rent_cost":43201,"bss_rent_penalty":-1,"use_hills":1.1,
        \\ "elevator_penalty":43201,"multimodal_start_end_max_distance":100001}
    ), &warnings, .none);
    const fields = [_][]const u8{
        "max_distance",   "walking_speed",    "step_penalty", "max_grade",        "max_hiking_difficulty",             "mode_factor",
        "walkway_factor", "sidewalk_factor",  "alley_factor", "driveway_factor",  "transit_start_end_max_distance",    "transit_transfer_max_distance",
        "bss_rent_cost",  "bss_rent_penalty", "use_hills",    "elevator_penalty", "multimodal_start_end_max_distance",
    };
    try t.expectEqual(fields.len, warnings.items.len);
    for (fields, warnings.items) |field, warning| try t.expectEqualStrings(field, warning.option);
    try t.expectEqual(@as(f32, 4), options.walking_speed);
    try t.expectEqual(@as(f32, 600), options.step_penalty);

    // The upstream test samples each range well below and above its limits.
    var random = std.Random.DefaultPrng.init(0);
    for (0..250) |_| {
        const speed = random.random().float(f32) * 49.5 - 12;
        const body = try std.fmt.allocPrint(arena, "{{\"walking_speed\":{d}}}", .{speed});
        warnings.clearRetainingCapacity();
        const sampled = try parse(arena, try json.parse(arena, body), &warnings, .none);
        try t.expectEqual(if (speed < 0.5 or speed > 25) @as(f32, 5.1) else speed, sampled.walking_speed);
    }
}

test "pedestrian costs and bounds cover legal speeds, factors, grades and transport types" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const options = try parse(arena_state.allocator(), .null, &warnings, .none);
    var classes = [_]EdgeClass{
        testClass(.road),     testClass(.footway),      testClass(.sidewalk),      testClass(.alley), testClass(.driveway),
        testClass(.track),    testClass(.service_road), testClass(.living_street), testClass(.ferry), testClass(.steps),
        testClass(.elevator), testClass(.ladder),       testClass(.road),          testClass(.road),  testClass(.road),
    };
    classes[0].flags.lit = true;
    classes[12].access.forward = 0;
    classes[13].category.surface = @backingInt(Surface.gravel);
    classes[14].category.sac_scale = 4;
    const intersection: NodeHot = .{ .turn_off = 0, .attr = .{ .access = 0xffff, .type = 0, .density = 0, .signal = 0 } };
    var cache: Cache = try .init(t.allocator, &classes, 2);
    defer cache.deinit();
    var prng = std.Random.DefaultPrng.init(0xb119_462e);
    const random = prng.random();
    for (0..2048) |_| {
        var raw = options;
        raw.transport = @fromBackingInt(@intCast(random.uintLessThan(u8, 3)));
        raw.walking_speed = 0.5 + random.float(f32) * 24.5;
        raw.walkway_factor = 0.1 + random.float(f32) * 1.9;
        raw.sidewalk_factor = 0.1 + random.float(f32) * 1.9;
        raw.alley_factor = 0.1 + random.float(f32) * 99.9;
        raw.driveway_factor = 0.1 + random.float(f32) * 99.9;
        raw.use_hills = random.float(f32);
        raw.step_penalty = random.float(f32) * base.max_penalty;
        raw.elevator_penalty = random.float(f32) * base.max_penalty;
        raw.max_hiking_difficulty = random.uintLessThan(u3, 7);
        raw.min_linear_factor = random.float(f32);
        raw.shared.floats.set(.use_ferry, random.float(f32));
        raw.shared.floats.set(.use_lit, random.float(f32));
        raw.shared.floats.set(.use_tracks, random.float(f32));
        raw.shared.floats.set(.use_living_streets, random.float(f32));
        raw.shared.floats.set(.service_factor, 0.1 + random.float(f32) * 99999.9);
        raw.shared.flags.setPresent(.shortest, random.boolean());
        var lease = try cache.acquire(raw, .none);
        defer lease.release();
        const profile = lease.profile();
        const tables = lease.tables();
        for (&classes, 0..) |*class, i| {
            const speed = random.intRangeAtMost(u8, 1, 100);
            const edge = testEdge(@intCast(i), random.int(u24), random.int(u4));
            const factor = @max(raw.min_linear_factor, random.float(f32) * 2);
            const cost = Kernel.edgeCost(profile, tables, class, edge, speed, .{ .factor = factor });
            const bound = Kernel.edgeLowerBound(profile, tables, class, edge, 100);
            if (class.access.forward == 0 or class.category.surface > @backingInt(profile.surface_limit) or
                class.category.sac_scale > profile.max_hiking_difficulty)
            {
                try t.expectEqual(Cost.forbidden, cost);
                try t.expectEqual(compiled.forbidden_tick, bound);
                continue;
            }
            try t.expect(std.math.isFinite(cost.cost) and cost.cost >= 0 and cost.secs >= 0);
            try t.expect(compiled.costUnits(bound) <= cost.cost);
            const l2 = @as(f64, profile.l2CostFactor(100)) * @as(f64, @floatFromInt(edge.geom.len_m));
            try t.expect(l2 <= cost.cost);
            const delay = Kernel.turnCost(profile, &intersection, &classes[0], class, .{
                .base_turn = .{ .row = random.int(u7) },
                .sides = .{ .left = random.boolean(), .right = random.boolean() },
            });
            try t.expect(std.math.isFinite(delay.cost) and delay.secs >= 0);
            try t.expect(compiled.costUnits(Kernel.turnLowerBound()) <= delay.cost);
        }
    }
}

// Recorded from CreatePedestrianCost in the pinned Valhalla 3.9.3 oracle.
// These fixtures retain the options and directed-edge inputs to each call.
test "pedestrian edge and transition calls match the pinned Valhalla oracle" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const settings = [_][]const u8{
        \\{"type":"foot","shortest":true,"walking_speed":0.5,"use_ferry":0,"use_living_streets":0,
        \\ "use_tracks":0.1,"use_hills":0,"use_lit":0.3,"walkway_factor":0.1,"sidewalk_factor":0.1,
        \\ "driveway_factor":0.1,"alley_factor":0.1,"service_factor":0.1,"service_penalty":0,
        \\ "step_penalty":100,"elevator_penalty":4,"max_hiking_difficulty":6}
        ,
        \\{"type":"foot","walking_speed":2,"use_ferry":0.3,"use_living_streets":1,
        \\ "use_tracks":1,"use_hills":0.9,"use_lit":0.2,"walkway_factor":0.4,"sidewalk_factor":0.7,
        \\ "driveway_factor":1,"alley_factor":1.6,"service_factor":0.5,"service_penalty":3,
        \\ "step_penalty":121,"elevator_penalty":7,"max_hiking_difficulty":6}
        ,
    };
    const uses = [_]Use{ .road, .footway, .sidewalk, .alley, .driveway, .track, .living_street, .service_road, .ferry, .steps, .ladder, .elevator, .rail_ferry };
    const nodes = [_]graph.constants.NodeType{ .street_intersection, .gate, .bollard, .toll_booth, .border_control, .bike_share };
    const cases = [_]struct { profile: usize, index: usize, edge_cost: Cost, turn_cost: Cost }{
        .{ .profile = 0, .index = 8, .edge_cost = .{ .cost = 7239.6001, .secs = 723.960022 }, .turn_cost = .{ .secs = 300 } },
        .{ .profile = 0, .index = 9, .edge_cost = .{ .cost = 2262, .secs = 19869.4082 }, .turn_cost = .{ .cost = 100 } },
        .{ .profile = 0, .index = 11, .edge_cost = .{ .cost = 2764, .secs = 24278.9766 }, .turn_cost = .{ .cost = 4 } },
        .{ .profile = 0, .index = 19, .edge_cost = .{ .cost = 4772, .secs = 41188.8555 }, .turn_cost = .{ .secs = 1 } },
        .{ .profile = 3, .index = 11, .edge_cost = .{ .cost = 9626.55762, .secs = 23828.1113 }, .turn_cost = .{ .cost = 121, .secs = 121 } },
        .{ .profile = 3, .index = 53, .edge_cost = .{ .cost = 147352.328, .secs = 82319.7344 }, .turn_cost = .{ .cost = 128, .secs = 123 } },
        .{ .profile = 3, .index = 193, .edge_cost = .{ .cost = 382882.781, .secs = 375375.25 }, .turn_cost = .{ .cost = 5 } },
    };
    for (cases) |example| {
        const id = example.index;
        const profile = try Model.canonicalize(try parse(arena, try json.parse(arena, settings[example.profile / 3]), &warnings, .none));
        var class = testClass(uses[(id + example.profile) % uses.len]);
        class.category.sac_scale = @intCast((id / 19) % 7);
        class.flags.lit = id % 2 != 0;
        class.flags.sidewalk_left = id % 3 == 0;
        class.flags.roundabout = id % 5 == 0;
        class.flags.destination_only = id % 17 == 0;
        class.flags.internal = id % 19 == 0;
        class.flags.link = id % 11 == 0;
        var previous = testClass(uses[(id / 5) % uses.len]);
        previous.flags.destination_only = id % 23 == 0;

        const edge = testEdge(0, @intCast(3 + ((id * 251 + example.profile * 4093) % 70000)), @intCast((id / 7 + example.profile) % 16));
        const node: NodeHot = .{
            .turn_off = 0,
            .attr = .{ .access = 0, .signal = 0, .density = 0, .type = @backingInt(nodes[id % nodes.len]), .tagged_access = id % 3 != 0, .private_access = id % 7 == 0 },
        };
        var factors: [1]f32 = undefined;
        const tables = try compiled.compileInto(Model, profile, &.{class}, &factors, .none);
        const cost = Kernel.edgeCost(&profile, &tables, &class, edge, @intCast(2 + id % 39), .{});
        const turn = Kernel.turnCost(&profile, &node, &previous, &class, .{
            .base_turn = .{ .row = @as(u8, @intCast((id % 8) * 8)) | (if (id % 7 == 0) @as(u8, 0x40) else 0) },
            .sides = .{ .left = id % 3 != 0, .right = id % 5 != 0 },
        });
        try t.expectApproxEqRel(example.edge_cost.cost, cost.cost, 1e-5);
        try t.expectApproxEqRel(example.edge_cost.secs, cost.secs, 1e-5);
        try t.expectEqual(example.turn_cost, turn);
    }
    try t.expectEqual(0, warnings.items.len);
}

test "pedestrian snapping and path expansion preserve their different access checks" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var warnings: std.ArrayList(base.Warning) = .empty;
    const profile = try Model.canonicalize(try parse(arena, try json.parse(arena,
        \\{"type":"wheelchair","exclude_bridges":true,"max_distance":100,"speed_types":["freeflow"]}
    ), &warnings, .none));
    const from = testClass(.footway);
    var to = testClass(.footway);
    var edge = testEdge(0, 20, 6);
    edge.speed = .{ 12, 24, 20, 0 };
    try t.expectEqual(24, profile.untimedFerrySpeed(edge));
    const distant: PathCheck = .{ .previous_distance = 85 };
    try t.expect(!Kernel.allowed(&profile, &from, &to, edge, distant));
    try t.expect(Kernel.allowedReverse(&profile, &to, &from, distant));
    try t.expect(!Kernel.allowed(&profile, &from, &to, edge, .{ .backtrack = true }));
    try t.expect(Kernel.allowed(&profile, &from, &to, edge, .{ .backtrack = true, .previous_dead_end = true }));
    to.category.surface = @backingInt(Surface.gravel);
    try t.expect(profile.allowedCandidate(&to, .{}, .{}, false));
    try t.expect(!Kernel.allowed(&profile, &from, &to, edge, .{}));
    to.category.surface = @backingInt(Surface.compacted);
    to.category.sac_scale = 1;
    try t.expect(!profile.allowedCandidate(&to, .{}, .{}, false));
    try t.expect(!Kernel.allowed(&profile, &from, &to, edge, .{}));
    to.category.sac_scale = 0;
    to.flags.bridge = true;
    try t.expect(!Kernel.allowed(&profile, &from, &to, edge, .{}));
    try t.expect(!Kernel.allowedReverse(&profile, &from, &to, .{}));
    try t.expect(Kernel.allowedReverse(&profile, &to, &from, .{}));
    try t.expect(Kernel.allowed(&profile, &from, &to, edge, .{ .allowed_by_linear_feature = true, .avoided = true }));
}
