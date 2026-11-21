// Ported from src/sif/dynamiccost.cc and valhalla/sif/dynamiccost.h (Valhalla 3.9.3).
const std = @import("std");
const json = @import("../api/json.zig");
const graph = @import("../graph/root.zig");
const compiled = @import("compiled.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Cost = compiled.Cost;
const EdgeClass = graph.class_table.EdgeClass;
const NodeHot = graph.format.NodeHot;
const Use = graph.constants.Use;

pub const max_penalty: f32 = 43_200;
pub const max_ferry_penalty: f32 = 21_600;
pub const fixed_speed_max: u32 = graph.speed.max_traffic_kph;
pub const unlimited_transitions = std.math.maxInt(u32);
pub const unlimited_distance = std.math.floatMax(f32);

pub const FloatOption = enum {
    destination_only_penalty,
    maneuver_penalty,
    alley_penalty,
    gate_cost,
    gate_penalty,
    private_access_penalty,
    country_crossing_cost,
    country_crossing_penalty,
    toll_booth_cost,
    toll_booth_penalty,
    ferry_cost,
    use_ferry,
    rail_ferry_cost,
    use_rail_ferry,
    service_penalty,
    use_distance,
    service_factor,
    use_tracks,
    use_living_streets,
    use_lit,
    use_curvature,
    closure_factor,
    speed_penalty_factor,
    height,
    width,
    length,
    weight,
};

pub const Flag = enum {
    ignore_restrictions,
    ignore_oneways,
    ignore_access,
    ignore_closures,
    ignore_construction,
    ignore_non_vehicular_restrictions,
    shortest,
    disable_hierarchy_pruning,
    exclude_unpaved,
    exclude_bridges,
    exclude_tunnels,
    exclude_tolls,
    exclude_highways,
    exclude_ferries,
    exclude_cash_only_tolls,
    include_hot,
    include_hov2,
    include_hov3,
};

pub const Range = struct {
    min: f32,
    default: f32,
    max: f32,

    pub fn penalty(value: f32) Range {
        return .{ .min = 0, .default = value, .max = max_penalty };
    }

    pub fn preference(value: f32) Range {
        return .{ .min = 0, .default = value, .max = 1 };
    }

    pub fn factor(value: f32) Range {
        return .{ .min = 0.1, .default = value, .max = 100_000 };
    }
};

pub const Config = struct {
    ranges: std.EnumArray(FloatOption, Range) = .init(.{
        .destination_only_penalty = .penalty(600),
        .maneuver_penalty = .penalty(5),
        .alley_penalty = .penalty(5),
        .gate_cost = .penalty(30),
        .gate_penalty = .penalty(300),
        .private_access_penalty = .penalty(450),
        .country_crossing_cost = .penalty(600),
        .country_crossing_penalty = .penalty(0),
        .toll_booth_cost = .penalty(15),
        .toll_booth_penalty = .penalty(0),
        .ferry_cost = .penalty(300),
        .use_ferry = .preference(0.5),
        .rail_ferry_cost = .penalty(300),
        .use_rail_ferry = .preference(0.4),
        .service_penalty = .penalty(15),
        .use_distance = .preference(0),
        .service_factor = .{ .min = 0.1, .default = 1, .max = 100_000 },
        .use_tracks = .preference(0.5),
        .use_living_streets = .preference(0.1),
        .use_lit = .preference(0),
        .use_curvature = .preference(0.5),
        .closure_factor = .{ .min = 1, .default = 9, .max = 10 },
        .speed_penalty_factor = .preference(0.05),
        .height = .{ .min = 0, .default = 1.6, .max = 10 },
        .width = .{ .min = 0, .default = 1.9, .max = 10 },
        .length = .{ .min = 0, .default = 2.7, .max = 50 },
        .weight = .{ .min = 0, .default = 0.8, .max = 100 },
    }),
    flags: std.EnumSet(Flag) = .empty,
    disable_toll_booth: bool = false,
    disable_ferry: bool = false,
    disable_rail_ferry: bool = false,

    fn disabled(self: Config, option: FloatOption) bool {
        return switch (option) {
            .toll_booth_cost, .toll_booth_penalty => self.disable_toll_booth,
            .ferry_cost, .use_ferry => self.disable_ferry,
            .rail_ferry_cost, .use_rail_ferry => self.disable_rail_ferry,
            else => false,
        };
    }
};

pub const Flow = graph.speed.Flow;

pub const HierarchyLimit = struct {
    max_up_transitions: u32 = unlimited_transitions,
    expand_within_distance: f32 = unlimited_distance,
};

pub const Options = struct {
    floats: std.EnumArray(FloatOption, f32),
    flags: std.EnumSet(Flag),
    flow: Flow = .all,
    hierarchy_limits: [3]?HierarchyLimit = @splat(null),
    fixed_speed: u32 = 0,
    name: ?[]const u8 = null,

    pub fn value(self: Options, option: FloatOption) f32 {
        return self.floats.get(option);
    }

    pub fn flag(self: Options, option: Flag) bool {
        return self.flags.contains(option);
    }
};

pub const Warning = struct {
    option: []const u8,
    reset_to: union(enum) { float: f32, integer: u32 },

    pub const code = 500;

    pub fn description(self: Warning, arena: std.mem.Allocator) ![]const u8 {
        return switch (self.reset_to) {
            .float => |value| std.fmt.allocPrint(arena, "'/{s}' has been clamped to {d:.6}", .{ self.option, value }),
            .integer => |value| std.fmt.allocPrint(arena, "'/{s}' has been clamped to {d}", .{ self.option, value }),
        };
    }
};

/// The input is the mode's subobject of costing_options. Warnings borrow
/// stable option names and are emitted in upstream order.
pub fn parse(arena: std.mem.Allocator, input: json.Value, config: Config, warnings: *std.ArrayList(Warning), deadline: Deadline) !Options {
    if (deadline.expired()) return error.DeadlineExceeded;
    var result: Options = .{
        .floats = .initFill(0),
        .flags = config.flags,
        .flow = try parseFlow(json.pointer(input, "/speed_types"), deadline),
        .name = json.getOptional([]const u8, input, "/name"),
    };
    inline for (std.enums.values(Flag)) |flag| {
        result.flags.setPresent(flag, json.get(bool, input, "/" ++ @tagName(flag), config.flags.contains(flag)));
    }
    inline for (0..result.hierarchy_limits.len) |i| {
        const prefix = std.fmt.comptimePrint("/hierarchy_limits/{d}", .{i});
        const max_up = unsigned(input, prefix ++ "/max_up_transitions", unlimited_transitions);
        const within = json.get(f32, input, prefix ++ "/expand_within_distance", unlimited_distance);
        if (max_up != unlimited_transitions or within != unlimited_distance)
            result.hierarchy_limits[i] = .{ .max_up_transitions = max_up, .expand_within_distance = within };
    }
    inline for (std.enums.values(FloatOption)) |option| {
        if (option == .height) try parseFixedSpeed(arena, input, warnings, &result);
        if (!config.disabled(option)) {
            result.floats.set(option, try rangedFloat(arena, input, @tagName(option), config.ranges.get(option), warnings));
        }
    }
    return result;
}

pub fn rangedFloat(arena: std.mem.Allocator, input: json.Value, comptime name: []const u8, range: Range, warnings: *std.ArrayList(Warning)) !f32 {
    const value = json.get(f32, input, "/" ++ name, range.default);
    if (value < range.min or value > range.max) {
        try warnings.append(arena, .{ .option = name, .reset_to = .{ .float = range.default } });
        return range.default;
    }
    return if (value == 0) 0 else value;
}

pub fn rangedUnsigned(arena: std.mem.Allocator, input: json.Value, comptime name: []const u8, default: u32, maximum: u32, warnings: *std.ArrayList(Warning)) !u32 {
    return rangedUnsignedIn(arena, input, name, 0, default, maximum, warnings);
}

pub fn rangedUnsignedIn(arena: std.mem.Allocator, input: json.Value, comptime name: []const u8, minimum: u32, default: u32, maximum: u32, warnings: *std.ArrayList(Warning)) !u32 {
    const value = unsigned(input, "/" ++ name, default);
    if (minimum <= value and value <= maximum) return value;
    try warnings.append(arena, .{ .option = name, .reset_to = .{ .integer = default } });
    return default;
}

fn unsigned(input: json.Value, path: []const u8, default: u32) u32 {
    const value = json.pointer(input, path) orelse return default;
    switch (value) {
        .integer => |number| return @truncate(@as(u64, @bitCast(number))),
        .float => |number| return unsignedFloat(number, default),
        .number_string => |number| {
            if (std.fmt.parseInt(u64, number, 10)) |integer| return @truncate(integer) else |_| {}
            if (std.fmt.parseInt(i64, number, 10)) |integer| return @truncate(@as(u64, @bitCast(integer))) else |_| {}
            return unsignedFloat(std.fmt.parseFloat(f64, number) catch return default, default);
        },
        .string => |number| {
            if (std.mem.indexOfScalar(u8, number, '_') != null) return default;
            // Boost lexical_cast allows a leading sign for unsigned input.
            if (number.len > 1 and number[0] == '-') {
                if (std.fmt.parseInt(u32, number[1..], 10)) |integer| return 0 -% integer else |_| {}
            }
        },
        else => {},
    }
    return json.convert(u32, value) orelse default;
}

fn unsignedFloat(value: f64, default: u32) u32 {
    // RapidJSON's conversion truncates fractional numbers before narrowing.
    if (!(value >= -0x1p63 and value < 0x1p63)) return default;
    return @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(value)))));
}

fn parseFixedSpeed(arena: std.mem.Allocator, input: json.Value, warnings: *std.ArrayList(Warning), result: *Options) !void {
    result.fixed_speed = try rangedUnsigned(arena, input, "fixed_speed", 0, fixed_speed_max, warnings);
}

fn parseFlow(input: ?json.Value, deadline: Deadline) !Flow {
    const value = input orelse return .all;
    if (value != .array) return .all;
    var result: Flow = .{};
    for (value.array.items, 0..) |item, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (item != .string) continue;
        if (std.meta.stringToEnum(enum { freeflow, constrained, predicted, current }, item.string)) |kind| {
            switch (kind) {
                inline else => |tag| @field(result, @tagName(tag)) = true,
            }
        }
    }
    return result;
}

/// Access-changing options belong in the compiled profile if they can
/// admit edges. Exclusions and additive penalties only tighten the result.
pub const BoundEffect = enum { additive, static_factor, static_access, exclusion, speed, search_only };

pub fn floatBoundEffect(option: FloatOption) BoundEffect {
    return switch (option) {
        .use_ferry, .use_rail_ferry, .use_distance, .service_factor, .use_tracks, .use_living_streets, .use_lit, .use_curvature => .static_factor,
        .height, .width, .length, .weight => .static_access,
        else => .additive,
    };
}

pub fn flagBoundEffect(option: Flag) BoundEffect {
    return switch (option) {
        .ignore_restrictions, .ignore_oneways, .ignore_access, .ignore_closures, .ignore_construction, .ignore_non_vehicular_restrictions, .include_hot, .include_hov2, .include_hov3 => .static_access,
        .shortest => .static_factor,
        .disable_hierarchy_pruning => .search_only,
        else => .exclusion,
    };
}

pub fn speedFloor(options: Options, table: *const [256]f32, upper_static_speed: u8) f32 {
    if (options.fixed_speed == 0 or upper_static_speed == 0 or options.fixed_speed <= upper_static_speed) return 1;
    const ratio = @as(f64, table[options.fixed_speed]) / table[upper_static_speed];
    const rounded: f32 = @floatCast(ratio);
    // Account for the f32 conversion when the actual ratio rounds upward.
    return @min(1, if (@as(f64, rounded) <= ratio) rounded else @as(f32, @bitCast(@as(u32, @bitCast(rounded)) - 1)));
}

const Preference = struct {
    factor: f32,
    penalty: f32,
};

fn preference(value: f32, min_factor: f32, max_factor: f32, penalty: f32) Preference {
    if (value < 0.5) return .{
        .factor = max_factor - 2 * value * (max_factor - 1),
        .penalty = penalty * (1 - 2 * value),
    };
    return .{ .factor = min_factor + 2 * (1 - value) * (1 - min_factor), .penalty = 0 };
}

fn ferryPreference(value: f32) Preference {
    if (value < 0.5) {
        const penalty: u32 = @intFromFloat(max_ferry_penalty * (1 - value * 2));
        return .{ .factor = 10 - value * 18, .penalty = @floatFromInt(penalty) };
    }
    return .{ .factor = 1.5 - value, .penalty = 0 };
}

fn priced(seconds: f32, penalty: f32) Cost {
    return .{ .cost = seconds + penalty, .secs = seconds };
}

/// The common derived factors and transition penalties. Models choose where
/// to apply each factor when compiling their static class table.
pub const Shared = struct {
    shortest: bool,
    country_crossing: Cost,
    gate: Cost,
    private_access: Cost,
    toll_booth: Cost,
    ferry: Cost,
    rail_ferry: Cost,
    bike_share: Cost = .{},
    destination_only_penalty: f32,
    maneuver_penalty: f32,
    alley_penalty: f32,
    service_penalty: f32,
    service_factor: f32,
    ferry_factor: f32,
    rail_ferry_factor: f32,
    tracks: Preference,
    living_streets: Preference,
    unlit_factor: f32,
    closure_factor: f32,
    speed_penalty_factor: f32,
    distance_weight: f32,
    time_weight: f32,
    curvature_strength: f32,
    suburban_curvature_factor: f32,
    urban_curvature_factor: f32,

    pub fn init(options: Options) Shared {
        const ferry = ferryPreference(options.value(.use_ferry));
        const rail = ferryPreference(options.value(.use_rail_ferry));
        const lit = options.value(.use_lit);
        const step = @round(options.value(.use_curvature) * 20);
        const curvature_weight = @max(0, step - 10) / 10;
        const strength = curvature_weight * curvature_weight;
        return .{
            .shortest = options.flag(.shortest),
            .country_crossing = priced(options.value(.country_crossing_cost), options.value(.country_crossing_penalty)),
            .gate = priced(options.value(.gate_cost), options.value(.gate_penalty)),
            .private_access = priced(options.value(.gate_cost), options.value(.private_access_penalty)),
            .toll_booth = priced(options.value(.toll_booth_cost), options.value(.toll_booth_penalty)),
            .ferry = priced(options.value(.ferry_cost), ferry.penalty),
            .rail_ferry = priced(options.value(.rail_ferry_cost), rail.penalty),
            .destination_only_penalty = options.value(.destination_only_penalty),
            .maneuver_penalty = options.value(.maneuver_penalty),
            .alley_penalty = options.value(.alley_penalty),
            .service_penalty = options.value(.service_penalty),
            .service_factor = options.value(.service_factor),
            .ferry_factor = ferry.factor,
            .rail_ferry_factor = rail.factor,
            .tracks = preference(options.value(.use_tracks), 0.8, 4, 300),
            .living_streets = preference(options.value(.use_living_streets), 0.8, 3, 500),
            .unlit_factor = if (lit < 0.5) 1 + 2 * lit else -4 + 12 * lit,
            .closure_factor = options.value(.closure_factor),
            .speed_penalty_factor = options.value(.speed_penalty_factor),
            .distance_weight = options.value(.use_distance) * (1.0 / 16.0),
            .time_weight = 1 - options.value(.use_distance),
            .curvature_strength = strength,
            .suburban_curvature_factor = 1 + 0.1 * strength,
            .urban_curvature_factor = 2 * (1 + 6 * strength),
        };
    }

    pub fn useFactor(self: *const Shared, use: u6) f32 {
        return switch (use) {
            @backingInt(Use.ferry) => self.ferry_factor,
            @backingInt(Use.rail_ferry) => self.rail_ferry_factor,
            @backingInt(Use.service_road) => self.service_factor,
            @backingInt(Use.track) => self.tracks.factor,
            @backingInt(Use.living_street) => self.living_streets.factor,
            else => 1,
        };
    }

    pub fn curvatureFactor(self: *const Shared, curvature: u4) f32 {
        const straightness = @as(f32, @floatFromInt(15 - curvature)) / 15;
        return 1 + 6 * self.curvature_strength * straightness * straightness;
    }

    /// Used when the way-use factor and time blending are applied while
    /// evaluating an edge. A model that folds them into its class table
    /// keeps the corresponding dynamic floors at one.
    pub fn dynamicFloors(self: *const Shared, minimum_speed_ratio: f32) compiled.Floors {
        const minimum_use = @min(1, self.ferry_factor, self.rail_ferry_factor, self.service_factor, self.tracks.factor, self.living_streets.factor);
        return .{
            .edge_factor = if (self.shortest) 0 else minimum_use * self.time_weight,
            .speed_ratio = minimum_speed_ratio,
            .turn_factor = if (self.shortest) 0 else 1,
        };
    }

    pub fn transition(self: *const Shared, node: *const NodeHot, previous: *const EdgeClass, next: *const EdgeClass, turn: Turn) Cost {
        return self.modeTransition(false, node, previous, next, turn);
    }

    pub fn modeTransition(self: *const Shared, comptime pedestrian: bool, node: *const NodeHot, previous: *const EdgeClass, next: *const EdgeClass, turn: Turn) Cost {
        const kind = node.attr.type;
        const node_type = graph.constants.NodeType;
        const use = next.category.use;
        const prev_use = previous.category.use;
        var result: Cost = .{};
        if (kind == @backingInt(node_type.border_control)) result = result.add(self.country_crossing);
        if (kind == @backingInt(node_type.gate) and !node.attr.tagged_access) result = result.add(self.gate);
        if ((kind == @backingInt(node_type.gate) or (!pedestrian and kind == @backingInt(node_type.bollard))) and node.attr.private_access)
            result = result.add(self.private_access);
        if (kind == @backingInt(node_type.bike_share)) result = result.add(self.bike_share);
        if (!pedestrian and (kind == @backingInt(node_type.toll_booth) or (next.flags.toll and !previous.flags.toll)))
            result = result.add(self.toll_booth);
        if (use == @backingInt(Use.ferry) and prev_use != use) result = result.add(self.ferry);
        if (use == @backingInt(Use.rail_ferry) and prev_use != use) result = result.add(self.rail_ferry);

        if (turn.entersDestinationOnly(previous, next)) result.cost += self.destination_only_penalty;
        if (use == @backingInt(Use.alley) and prev_use != use) result.cost += self.alley_penalty;
        const transit_connection = use == @backingInt(Use.egress_connection) or use == @backingInt(Use.platform_connection);
        if (!next.flags.link and !turn.nameConsistent() and !(pedestrian and transit_connection)) result.cost += self.maneuver_penalty;
        if (use == @backingInt(Use.living_street) and prev_use != use) result.cost += self.living_streets.penalty;
        if (use == @backingInt(Use.track) and prev_use != use) result.cost += self.tracks.penalty;
        if (use == @backingInt(Use.service_road) and prev_use != use and (pedestrian or !next.flags.internal)) result.cost += self.service_penalty;
        if (self.shortest) result.cost = 0;
        return result;
    }
};

pub const density_factor = blk: {
    var table: [16]f32 = undefined;
    for (&table, 0..) |*factor, i| {
        const density: f32 = @floatFromInt(i);
        factor.* = 0.85 + density * 0.025;
    }
    break :blk table;
};
pub const transition_density_factor = [16]f32{ 1, 1, 1, 1, 1, 1.1, 1.2, 1.3, 1.4, 1.6, 1.9, 2.2, 2.5, 2.8, 3.1, 3.5 };

pub const Turn = struct {
    row: graph.format.TurnEntry,
    next_destination_only: bool = false,
    previous_destination_only: bool = false,
    hgv: bool = false,

    pub fn kind(self: Turn) u3 {
        return @truncate(self.row);
    }

    pub fn stopImpact(self: Turn) u3 {
        return @truncate(self.row >> 3);
    }

    pub fn nameConsistent(self: Turn) bool {
        return self.row & 0x40 != 0;
    }

    pub fn restricted(self: Turn) bool {
        return self.row & 0x80 != 0;
    }

    fn entersDestinationOnly(self: Turn, previous: *const EdgeClass, next: *const EdgeClass) bool {
        const destonly = self.next_destination_only or if (self.hgv) next.flags.destination_only_hgv else next.flags.destination_only;
        return destonly and !(self.previous_destination_only or previous.flags.destination_only);
    }

    pub fn turnSeconds(self: Turn, seconds: *const [8]f32) f32 {
        return seconds[self.kind()];
    }

    pub fn stopSeconds(self: Turn, seconds: *const [8]f32) f32 {
        return seconds[self.stopImpact()];
    }
};

pub const IntersectionTurn = struct {
    base_turn: Turn,
    sides: graph.turn_sides.Sides = .{},

    pub fn read(view: *const graph.reader.View, node: graph.format.NodeId, incoming: graph.format.EdgeId, outgoing: graph.format.EdgeId) !IntersectionTurn {
        const previous = try view.edge(incoming);
        const next = try view.edge(outgoing);
        const range = try view.outEdgeRange(node);
        const index = @backingInt(outgoing);
        if (previous.head != @backingInt(node) or index < range.first or index >= range.end or index - range.first != next.cls.local)
            return error.InvalidTransition;
        const row = try view.turnRow(node, previous.cls.opp_local);
        if (next.cls.local >= row.len) return error.InvalidLocalEdge;
        return .{
            .base_turn = .{ .row = row[next.cls.local] },
            .sides = try view.turnSides(node, previous.cls.opp_local, next.cls.local),
        };
    }
};

pub const Disallow = packed struct(u8) {
    start_restriction: bool = false,
    end_restriction: bool = false,
    simple_restriction: bool = false,
    closure: bool = false,
    shortcut: bool = false,
    reserved: u3 = 0,
};

pub const EdgeState = struct {
    closed: bool = false,
    simple_restriction: bool = false,
    shortcut: bool = false,
};

pub const Permission = struct {
    flags: std.EnumSet(Flag),
    flow: Flow,
    access_mask: graph.constants.AccessMask,
    filter_closures: bool,
    allow_destination_only: bool = true,
    restriction_probability: u8 = 0,

    pub fn init(options: Options, access_mask: graph.constants.AccessMask, filter_closures: bool) Permission {
        return .{
            .flags = options.flags,
            .flow = options.flow,
            .access_mask = access_mask,
            .filter_closures = filter_closures and !options.flag(.ignore_closures),
        };
    }

    pub fn allowedNode(self: Permission, node: *const NodeHot) bool {
        const access: u16 = @bitCast(self.access_mask);
        return (node.attr.access & access != 0 or self.flags.contains(.ignore_access)) and
            !(self.flags.contains(.exclude_cash_only_tolls) and node.attr.cash_only_toll);
    }

    pub fn allowedClass(self: Permission, edge: *const EdgeClass) bool {
        const access: u16 = if (self.flags.contains(.ignore_access)) 0x0fff else @bitCast(self.access_mask);
        const forward = edge.access.forward & access != 0;
        const reverse = self.flags.contains(.ignore_oneways) and edge.access.reverse & access != 0;
        return (forward or reverse) and
            (edge.category.use != @backingInt(Use.construction) or self.flags.contains(.ignore_construction));
    }

    /// Directional accessibility during path expansion. Construction can be
    /// traversed on request even if the edge carries no ordinary access.
    pub fn accessibleClass(self: Permission, edge: *const EdgeClass) bool {
        const access: u16 = @bitCast(self.access_mask);
        return edge.access.forward & access != 0 or
            (self.flags.contains(.ignore_access) and edge.access.forward & 0x0fff != 0) or
            (self.flags.contains(.ignore_oneways) and edge.access.reverse & access != 0) or
            (self.flags.contains(.ignore_construction) and edge.category.use == @backingInt(Use.construction));
    }

    pub fn allowedEdge(self: Permission, edge: *const EdgeClass, state: EdgeState, disallow: Disallow) bool {
        return self.allowedClass(edge) and
            !(disallow.shortcut and state.shortcut) and
            !(disallow.start_restriction and edge.restrictions.start != 0) and
            !(disallow.end_restriction and edge.restrictions.end != 0) and
            !(disallow.simple_restriction and state.simple_restriction) and
            !(state.closed and self.usesClosures() and (self.filter_closures or disallow.closure));
    }

    pub fn usesClosures(self: Permission) bool {
        return self.flow.current and !self.flags.contains(.ignore_closures);
    }

    pub fn allowedCandidate(self: Permission, edge: *const EdgeClass, state: EdgeState, disallow: Disallow) bool {
        var mask = disallow;
        mask.closure = false;
        return self.allowedEdge(edge, state, mask);
    }

    pub fn allowsTurnRestriction(self: Permission, turn: Turn) bool {
        return !turn.restricted() or self.ignoresTurnRestrictions();
    }

    pub fn restrictionModes(self: Permission) u16 {
        if (self.ignoresTurnRestrictions()) return 0;
        return @bitCast(self.access_mask);
    }

    pub inline fn destinationOnly(self: Permission, edge: *const EdgeClass) bool {
        return if (self.access_mask.truck) edge.flags.destination_only_hgv else edge.flags.destination_only;
    }

    fn ignoresTurnRestrictions(self: Permission) bool {
        return self.flags.contains(.ignore_restrictions) or self.flags.contains(.ignore_non_vehicular_restrictions);
    }

    pub noinline fn startingAccess(self: Permission, limits: []align(1) const graph.cold.access_restriction.Entry, forward: bool, local: ?graph.datetime.Local, deadline: Deadline) !AccessState {
        if (self.flags.contains(.ignore_restrictions)) return .{};
        const modes: u16 = @bitCast(self.access_mask);
        var result: AccessState = .{};
        for (limits, 0..) |limit, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (!limit.applies(forward) or limit.modes() & modes == 0) continue;
            if (limit.attr.kind == .destination_allowed) {
                if (local) |now| {
                    const domain: graph.time_domain.TimeDomain = @bitCast(limit.value);
                    result.destination_only = result.destination_only or domain.active(now);
                }
            }
            if (limit.attr.except_destination and !self.allow_destination_only)
                result.vehicle_exceptions |= limit.attr.kind.exceptionMask();
        }
        return result;
    }

    /// EvaluateRestrictions uses upstream record ordering. An active allow or
    /// destination condition stops later time checks while dimensional limits
    /// continue to the costing's mode-specific checks.
    pub noinline fn evaluateRestrictions(
        self: Permission,
        limits: []align(1) const graph.cold.access_restriction.Entry,
        forward: bool,
        local: ?graph.datetime.Local,
        previous: AccessState,
        predicate: anytype,
        deadline: Deadline,
    ) !AccessEvaluation {
        if (self.flags.contains(.ignore_restrictions)) return .{};
        const modes: u16 = @bitCast(self.access_mask);
        const check_time = !self.flags.contains(.ignore_non_vehicular_restrictions);
        var result: AccessEvaluation = .{};
        var time_allowed = false;
        var time_in_range = false;
        var index: usize = 0;
        for (limits, 0..) |limit, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (!limit.applies(forward) or limit.modes() & modes == 0) continue;
            defer index += 1;
            const kind = limit.attr.kind;
            if (kind.timed() and !time_in_range and check_time) {
                result.restriction_index = @truncate(index);
                if (local) |now| {
                    time_allowed = time_allowed or kind == .timed_allowed;
                    const domain: graph.time_domain.TimeDomain = @bitCast(limit.value);
                    if (domain.active(now)) {
                        if (kind == .timed_denied) return result.deny();
                        if (kind == .destination_allowed) {
                            result.state.destination_only = true;
                            if (!self.allow_destination_only and !previous.destination_only) return result.deny();
                        }
                        time_in_range = true;
                    }
                }
            }
            if (limit.attr.except_destination) {
                const mask = kind.exceptionMask();
                result.state.vehicle_exceptions |= mask;
                if (self.allow_destination_only or previous.vehicle_exceptions & mask != 0) continue;
            }
            if (comptime @TypeOf(predicate) != @TypeOf(null)) {
                if (!predicate.allowed(limit)) return result.deny();
            }
        }
        if (time_allowed and !time_in_range) return result.deny();
        return result;
    }

    /// Check a transition in travel order. Reverse search swaps its operands.
    pub fn allowedTransition(self: Permission, from: *const EdgeClass, to: *const EdgeClass, turn: Turn) bool {
        if (!self.allowsTurnRestriction(turn)) return false;
        if (!self.allow_destination_only and turn.entersDestinationOnly(from, to)) return false;
        return self.allowedExclusions(from, to) and
            !(self.flags.contains(.exclude_unpaved) and to.category.surface >= @backingInt(graph.constants.Surface.compacted) and
                from.category.surface < @backingInt(graph.constants.Surface.compacted));
    }

    pub fn allowedExclusions(self: Permission, from: *const EdgeClass, to: *const EdgeClass) bool {
        return !(self.flags.contains(.exclude_bridges) and to.flags.bridge and !from.flags.bridge) and
            !(self.flags.contains(.exclude_tunnels) and to.flags.tunnel and !from.flags.tunnel) and
            !(self.flags.contains(.exclude_tolls) and to.flags.toll and !from.flags.toll) and
            !(self.flags.contains(.exclude_highways) and to.category.road_class == 0 and from.category.road_class != 0) and
            !(self.flags.contains(.exclude_ferries) and isFerry(to.category.use) and !isFerry(from.category.use));
    }
};

pub const AccessState = struct {
    destination_only: bool = false,
    vehicle_exceptions: u7 = 0,
};

pub const AccessEvaluation = struct {
    allowed: bool = true,
    state: AccessState = .{},
    restriction_index: ?u8 = null,

    fn deny(self: AccessEvaluation) AccessEvaluation {
        var denied = self;
        denied.allowed = false;
        return denied;
    }
};

// Ported from the mixed timed and dimensional cases in
// test/gurka/test_conditional_restrictions.cc (Valhalla 3.9.3).
test "a scheduled opening preserves the mode-specific and local access checks" {
    const t = std.testing;
    const Entry = graph.cold.access_restriction.Entry;
    const Domain = graph.time_domain.TimeDomain;
    const Predicate = struct {
        fn allowed(_: @This(), entry: Entry) bool {
            return entry.attr.kind != .maxheight;
        }
    };
    const limits = &[_]Entry{
        .{ .value = @bitCast(Domain{ .begin_hour = 9, .end_hour = 12 }), .attr = .{ .kind = .timed_allowed, .direction = .both, .modes = 8 } },
        .{ .value = 400, .attr = .{ .kind = .maxheight, .direction = .both, .except_destination = true } },
        .{ .value = @bitCast(Domain{ .begin_hour = 13, .end_hour = 14 }), .attr = .{ .kind = .timed_denied, .direction = .both, .modes = 4095 } },
    };
    var permission: Permission = .{ .flags = .empty, .flow = .{}, .access_mask = .{ .truck = true }, .filter_closures = false, .allow_destination_only = false };
    const opening = graph.datetime.Local.parse("2020-10-10T10:00").?;
    const closed = graph.datetime.Local.parse("2020-10-10T16:00").?;
    const exempt = try permission.startingAccess(limits, true, null, .none);
    try t.expectEqual(2, exempt.vehicle_exceptions);
    try t.expect(!(try permission.evaluateRestrictions(limits, true, opening, .{}, Predicate{}, .none)).allowed);
    try t.expect((try permission.evaluateRestrictions(limits, true, opening, exempt, Predicate{}, .none)).allowed);
    try t.expect(!(try permission.evaluateRestrictions(limits, true, closed, exempt, Predicate{}, .none)).allowed);
    try t.expect((try permission.evaluateRestrictions(limits, true, null, exempt, Predicate{}, .none)).allowed);
    permission.flags.insert(.ignore_non_vehicular_restrictions);
    try t.expect((try permission.evaluateRestrictions(limits, true, closed, exempt, Predicate{}, .none)).allowed);
    try t.expect(!(try permission.evaluateRestrictions(limits, true, closed, .{}, Predicate{}, .none)).allowed);
}

fn isFerry(use: u6) bool {
    return use == @backingInt(Use.ferry) or use == @backingInt(Use.rail_ferry);
}

test "every base option uses the Valhalla 3.9.3 name and range" {
    const testing = std.testing;
    const expected = [_]struct { []const u8, f32, f32, f32 }{
        .{ "destination_only_penalty", 0, 600, 43200 },
        .{ "maneuver_penalty", 0, 5, 43200 },
        .{ "alley_penalty", 0, 5, 43200 },
        .{ "gate_cost", 0, 30, 43200 },
        .{ "gate_penalty", 0, 300, 43200 },
        .{ "private_access_penalty", 0, 450, 43200 },
        .{ "country_crossing_cost", 0, 600, 43200 },
        .{ "country_crossing_penalty", 0, 0, 43200 },
        .{ "toll_booth_cost", 0, 15, 43200 },
        .{ "toll_booth_penalty", 0, 0, 43200 },
        .{ "ferry_cost", 0, 300, 43200 },
        .{ "use_ferry", 0, 0.5, 1 },
        .{ "rail_ferry_cost", 0, 300, 43200 },
        .{ "use_rail_ferry", 0, 0.4, 1 },
        .{ "service_penalty", 0, 15, 43200 },
        .{ "use_distance", 0, 0, 1 },
        .{ "service_factor", 0.1, 1, 100000 },
        .{ "use_tracks", 0, 0.5, 1 },
        .{ "use_living_streets", 0, 0.1, 1 },
        .{ "use_lit", 0, 0, 1 },
        .{ "use_curvature", 0, 0.5, 1 },
        .{ "closure_factor", 1, 9, 10 },
        .{ "speed_penalty_factor", 0, 0.05, 1 },
        .{ "height", 0, 1.6, 10 },
        .{ "width", 0, 1.9, 10 },
        .{ "length", 0, 2.7, 50 },
        .{ "weight", 0, 0.8, 100 },
    };
    const flags = [_][]const u8{
        "ignore_restrictions", "ignore_oneways",                    "ignore_access",           "ignore_closures",
        "ignore_construction", "ignore_non_vehicular_restrictions", "shortest",                "disable_hierarchy_pruning",
        "exclude_unpaved",     "exclude_bridges",                   "exclude_tunnels",         "exclude_tolls",
        "exclude_highways",    "exclude_ferries",                   "exclude_cash_only_tolls", "include_hot",
        "include_hov2",        "include_hov3",
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config: Config = .{};
    var warnings: std.ArrayList(Warning) = .empty;
    const defaults = try parse(a, .null, config, &warnings, .none);
    try testing.expectEqual(0, defaults.fixed_speed);
    try testing.expectEqual(@as(u32, 252), fixed_speed_max);
    try testing.expectEqual(@as(u8, 15), @as(u8, @bitCast(defaults.flow)));
    try testing.expectEqual([_]?HierarchyLimit{ null, null, null }, defaults.hierarchy_limits);
    try testing.expectEqual(0, warnings.items.len);
    try testing.expectEqual(expected.len, std.enums.values(FloatOption).len);
    for (std.enums.values(FloatOption), expected) |field, rule| {
        try testing.expectEqualStrings(rule[0], @tagName(field));
        try testing.expectEqual(Range{ .min = rule[1], .default = rule[2], .max = rule[3] }, config.ranges.get(field));
        try testing.expectEqual(rule[2], defaults.value(field));
        for ([_]f32{ rule[1], rule[3], rule[1] - 1, rule[3] + 1 }, 0..) |number, index| {
            const text = try std.fmt.allocPrint(a, "{{\"{s}\":{d}}}", .{ rule[0], number });
            warnings.clearRetainingCapacity();
            const result = try parse(a, try json.parse(a, text), config, &warnings, .none);
            try testing.expectEqual(if (index >= 2) rule[2] else number, result.value(field));
            try testing.expectEqual(@as(usize, if (index >= 2) 1 else 0), warnings.items.len);
            if (index >= 2) try testing.expectEqualStrings(rule[0], warnings.items[0].option);
        }
    }
    try testing.expectEqual(flags.len, std.enums.values(Flag).len);
    for (std.enums.values(Flag), flags) |flag, name| {
        try testing.expectEqualStrings(name, @tagName(flag));
        try testing.expect(!defaults.flag(flag));
        const text = try std.fmt.allocPrint(a, "{{\"{s}\":true}}", .{name});
        const result = try parse(a, try json.parse(a, text), config, &warnings, .none);
        try testing.expect(result.flag(flag));
    }
}

test "base parser keeps sentinel hierarchy limits and emits upstream warnings in order" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(Warning) = .empty;
    const text =
        \\{"fixed_speed":-1,"gate_cost":43201,"use_tracks":"not-a-number","use_ferry":1.1,
        \\ "speed_types":["predicted",3,"future","freeflow"],
        \\ "name":"sample","ignore_closures":1,"shortest":"1",
        \\ "hierarchy_limits":{"0":{"max_up_transitions":8},"2":{"expand_within_distance":25}}}
    ;
    const result = try parse(a, try json.parse(a, text), .{}, &warnings, .none);
    try testing.expectEqual(3, warnings.items.len);
    try testing.expectEqualStrings("'/gate_cost' has been clamped to 30.000000", try warnings.items[0].description(a));
    try testing.expectEqualStrings("'/use_ferry' has been clamped to 0.500000", try warnings.items[1].description(a));
    try testing.expectEqualStrings("'/fixed_speed' has been clamped to 0", try warnings.items[2].description(a));
    try testing.expectEqual(@as(f32, 0.5), result.value(.use_tracks));
    try testing.expectEqual(0, result.fixed_speed);
    try testing.expectEqual(5, @as(u8, @bitCast(result.flow)));
    try testing.expectEqual(HierarchyLimit{ .max_up_transitions = 8 }, result.hierarchy_limits[0].?);
    try testing.expect(result.hierarchy_limits[1] == null);
    try testing.expectEqual(HierarchyLimit{ .expand_within_distance = 25 }, result.hierarchy_limits[2].?);
    try testing.expectEqualStrings("sample", result.name.?);
    try testing.expect(result.flag(.ignore_closures) and result.flag(.shortest));

    warnings.clearRetainingCapacity();
    var config: Config = .{ .disable_ferry = true };
    config.ranges.set(.gate_cost, .{ .min = 0, .default = 3, .max = 10 });
    config.flags.insert(.exclude_tolls);
    const options = try parse(a, try json.parse(a,
        \\{"ferry_cost":99999,"use_ferry":2,"fixed_speed":252,"gate_cost":11,"speed_types":[]}
    ), config, &warnings, .none);
    try testing.expectEqual(1, warnings.items.len);
    try testing.expectEqual(@as(f32, 3), options.value(.gate_cost));
    try testing.expectEqual(@as(f32, 0), options.value(.use_ferry));
    try testing.expectEqual(252, options.fixed_speed);
    try testing.expectEqual(0, @as(u8, @bitCast(options.flow)));
    try testing.expect(options.flag(.exclude_tolls));
    try testing.expectError(error.DeadlineExceeded, parse(a, .null, config, &warnings, .{ .at_ns = 0 }));

    warnings.clearRetainingCapacity();
    _ = try parse(a, try json.parse(a,
        \\{"fixed_speed":-1.5,"gate_cost":"0x1p20","gate_penalty":"1e100",
        \\ "country_crossing_cost":"1_000000","use_tracks":"inf"}
    ), .{}, &warnings, .none);
    try testing.expectEqual(2, warnings.items.len);
    try testing.expectEqualStrings("'/use_tracks' has been clamped to 0.500000", try warnings.items[0].description(a));
    try testing.expectEqualStrings("'/fixed_speed' has been clamped to 0", try warnings.items[1].description(a));
}

test "shared transitions keep elapsed time separate from penalties and apply access policy" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(Warning) = .empty;
    const options = try parse(a, try json.parse(a,
        \\{"exclude_tolls":true,"exclude_unpaved":true,"exclude_cash_only_tolls":true,
        \\ "use_tracks":0,"use_living_streets":1,"use_ferry":1,"fixed_speed":100}
    ), .{}, &warnings, .none);
    const common = Shared.init(options);
    const all: u16 = @bitCast(graph.constants.AccessMask.all_tag_modes);
    const normal: EdgeClass = .{ .access = .{ .forward = all, .reverse = all } };
    var other = normal;
    var node: NodeHot = .{ .turn_off = 0, .attr = .{ .access = all, .type = @backingInt(graph.constants.NodeType.gate), .density = 0, .signal = 0 } };
    const straight: Turn = .{ .row = 0x40 };
    try testing.expectEqual(Cost{ .cost = 330, .secs = 30 }, common.transition(&node, &normal, &other, straight));
    node.attr.private_access = true;
    node.attr.tagged_access = true;
    try testing.expectEqual(Cost{ .cost = 480, .secs = 30 }, common.transition(&node, &normal, &other, straight));
    node.attr.type = @backingInt(graph.constants.NodeType.street_intersection);
    other.flags.toll = true;
    other.flags.destination_only = true;
    other.category.use = @backingInt(Use.track);
    try testing.expectEqual(Cost{ .cost = 920, .secs = 15 }, common.transition(&node, &normal, &other, .{ .row = 0 }));
    var shortest = common;
    shortest.shortest = true;
    try testing.expectEqual(Cost{ .cost = 0, .secs = 15 }, shortest.transition(&node, &normal, &other, .{ .row = 0 }));
    try testing.expectEqual(@as(f32, 0.5), common.ferry_factor);
    try testing.expectEqual(@as(f32, 4), common.tracks.factor);
    try testing.expectEqual(@as(f32, 0.8), common.living_streets.factor);
    try testing.expectEqual(@as(f32, 0.5), common.dynamicFloors(1).edge_factor);
    const table = (compiled.Rules{}).seconds_per_metre;
    const floor = speedFloor(options, &table, 50);
    try testing.expectApproxEqAbs(@as(f32, 0.5), floor, 1e-6);
    try testing.expect(@as(f64, floor) * table[50] <= table[100]);

    const turn: Turn = .{ .row = 0x40 | (3 << 3) | 5 };
    try testing.expectEqual(5, turn.kind());
    try testing.expectEqual(3, turn.stopImpact());
    try testing.expect(turn.nameConsistent());
    try testing.expectEqual(@as(f32, 3.5), transition_density_factor[15]);
    try testing.expectApproxEqAbs(@as(f32, 0.85), density_factor[0], 1e-6);

    var permission: Permission = .init(options, .{ .auto = true }, true);
    try testing.expect(permission.allowedClass(&normal));
    try testing.expect(!permission.allowedEdge(&normal, .{ .closed = true }, .{}));
    permission.filter_closures = false;
    try testing.expect(permission.allowedEdge(&normal, .{ .closed = true }, .{}));
    try testing.expect(!permission.allowedEdge(&normal, .{ .closed = true }, .{ .closure = true }));
    try testing.expect(!permission.allowedTransition(&normal, &other, straight));
    try testing.expect(permission.allowedTransition(&other, &other, straight));
    try testing.expect(!permission.allowedTransition(&other, &other, .{ .row = 0x80 }));
    permission.flags.insert(.ignore_restrictions);
    try testing.expect(permission.allowedTransition(&other, &other, .{ .row = 0x80 }));
    node.attr.cash_only_toll = true;
    try testing.expect(!permission.allowedNode(&node));

    other = normal;
    other.flags.destination_only_hgv = true;
    permission.allow_destination_only = false;
    try testing.expect(permission.allowedTransition(&normal, &other, straight));
    try testing.expect(!permission.allowedTransition(&normal, &other, .{ .row = 0x40, .hgv = true }));
    other.access.forward = 0;
    try testing.expect(!permission.allowedClass(&other));
    permission.flags.insert(.ignore_oneways);
    try testing.expect(permission.allowedClass(&other));
    try testing.expect(permission.accessibleClass(&other));
    other.access.reverse = 0;
    other.category.use = @backingInt(Use.construction);
    try testing.expect(!permission.accessibleClass(&other));
    permission.flags.insert(.ignore_construction);
    try testing.expect(permission.accessibleClass(&other));
    try testing.expect(!permission.allowedClass(&other));
}
