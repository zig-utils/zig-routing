// Ported from src/mjolnir/countryaccess.cc and
// valhalla/mjolnir/adminconstants.h (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/constants.zig");
const EdgeClass = @import("../graph/class_table.zig").EdgeClass;
const admin = @import("../graph/admin.zig");
const io = @import("../infra/io.zig");
const Access = graph.AccessMask;

const Road = enum { trunk, trunk_link, track, footway, pedestrian, bridleway, cycleway, path, motorroad };
const Rules = [@typeInfo(Road).@"enum".field_names.len]u16;
const RuleId = enum(u8) { none, _ };
const inherit = std.math.maxInt(u16);
const empty_rules: Rules = @splat(inherit);
const Pair = @TypeOf(@as(EdgeClass, .{}).access);

const foot = mask(.{ .pedestrian = true, .wheelchair = true });
const bike = mask(.{ .bicycle = true });
const moped = mask(.{ .moped = true });
const foot_bike_moped = foot | bike | moped;
const vehicle_modes = mask(.{ .auto = true, .truck = true, .emergency = true, .taxi = true, .bus = true, .hov = true, .moped = true, .motorcycle = true });

fn defaults(name: []const u8, english_name: []const u8) RuleId {
    var english: RuleId = .none;
    for (&countries, 1..) |*country, i| {
        const id: RuleId = @fromBackingInt(@intCast(i));
        if (std.mem.eql(u8, country.name, name)) return id;
        if (std.mem.eql(u8, country.name, english_name)) english = id;
    }
    return english;
}

pub const Country = struct {
    iso: u16 = 0,
    rules: RuleId = .none,
};

/// Resolve the country's rules once per admin. State IDs use their
/// country, and index zero represents an unassigned node.
pub fn compile(gpa: std.mem.Allocator, input: ?admin.View, deadline: io.Deadline) ![]Country {
    const index = input orelse return &.{};
    const result = try gpa.alloc(Country, index.regions.len + 1);
    errdefer gpa.free(result);
    result[0] = .{};
    for (index.regions, result[1..], 0..) |region, *out, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        out.* = .{};
        const country = switch (region.attr.level) {
            2 => region,
            4 => (try index.region(region.attr.parent)) orelse continue,
            else => continue,
        };
        const iso = try index.text(country.iso_code);
        if (iso.len != 2 or iso[0] == 0) continue;
        out.* = .{
            .iso = std.mem.readInt(u16, iso[0..2], .little),
            .rules = defaults(try index.text(country.name), try index.text(country.english_name)),
        };
    }
    return result;
}

/// Apply one country's rules to a directed edge and its opposing access
/// mask. Directional protection is calculated from the original pair.
pub noinline fn apply(class: *EdgeClass, rules: RuleId, explicit: Access, motorroad_tag: bool) void {
    if (rules != .none and class.category.use == @backingInt(graph.Use.ferry)) return;
    const table = if (rules == .none) &empty_rules else &countries[@backingInt(rules) - 1].rules;
    const pair = class.access;
    const motorroad = motorroad_tag and class.category.road_class <= @backingInt(graph.RoadClass.primary);
    const motorroad_override = if (motorroad) table[@backingInt(Road.motorroad)] else inherit;
    const trunk_override = if (class.category.road_class == @backingInt(graph.RoadClass.trunk)) access: {
        const main = table[@backingInt(Road.trunk)];
        const link = table[@backingInt(Road.trunk_link)];
        break :access if (class.flags.link and link != inherit) link else main;
    } else inherit;
    const tags = mask(explicit);
    var result = pair;
    const allowed = if (motorroad_override != inherit) motorroad_override else trunk_override;
    if (allowed != inherit)
        result = applyPair(result, .{ .forward = allowed, .reverse = allowed }, pair, tags);
    if (motorroad and motorroad_override == inherit) {
        const motorroad_access: Pair = .{ .forward = result.forward & ~foot_bike_moped, .reverse = result.reverse & ~foot_bike_moped };
        result = applyPair(result, motorroad_access, pair, tags);
    }
    const use: ?Road = switch (class.category.use) {
        @backingInt(graph.Use.track) => .track,
        @backingInt(graph.Use.footway), @backingInt(graph.Use.sidewalk), @backingInt(graph.Use.pedestrian_crossing) => .footway,
        @backingInt(graph.Use.pedestrian) => .pedestrian,
        @backingInt(graph.Use.bridleway) => .bridleway,
        @backingInt(graph.Use.cycleway) => .cycleway,
        @backingInt(graph.Use.path) => .path,
        else => null,
    };
    if (use) |road| {
        const use_access = table[@backingInt(road)];
        if (use_access != inherit)
            result = applyPair(result, .{ .forward = use_access, .reverse = use_access }, pair, tags);
    }
    class.access = result;
}

noinline fn applyPair(current: Pair, allowed: Pair, original: Pair, tags: u16) Pair {
    return .{
        .forward = applyDirection(current.forward, allowed.forward, original.reverse & ~original.forward, tags),
        .reverse = applyDirection(current.reverse, allowed.reverse, original.forward & ~original.reverse, tags),
    };
}

fn applyDirection(current: u16, allowed: u16, opposing_only: u16, tags: u16) u16 {
    var result = current;
    if (opposing_only & mask(.{ .pedestrian = true }) == 0 and tags & mask(.{ .pedestrian = true }) == 0)
        result = setGroup(result, allowed, foot);
    if (opposing_only & bike == 0 and tags & bike == 0) result = setGroup(result, allowed, bike);
    if (opposing_only & vehicle_modes != 0) return result;
    // Emergency access is used to detect a one-way but is never overridden.
    const vehicle_overrides = vehicle_modes & ~mask(.{ .emergency = true }) & ~tags;
    return (result & ~vehicle_overrides) | (allowed & vehicle_overrides);
}

fn setGroup(current: u16, allowed: u16, group: u16) u16 {
    if (allowed & group == group) return current | group;
    return if (current & group == group) current & ~group else current;
}

fn mask(access: Access) u16 {
    return @bitCast(access);
}

const motor_vehicles_except_mopeds = vehicle_modes & ~(moped | mask(.{ .emergency = true }));

// Column order is Road. Inherit keeps the ordinary OSM default.
const countries = [_]struct { name: []const u8, rules: Rules }{
    .{ .name = "Australia", .rules = .{ inherit, inherit, inherit, foot | bike, inherit, inherit, inherit, inherit, inherit } },
    .{ .name = "Austria", .rules = .{ motor_vehicles_except_mopeds, motor_vehicles_except_mopeds, inherit, inherit, inherit, inherit, inherit, foot, inherit } },
    .{ .name = "Belarus", .rules = .{ inherit, inherit, inherit, foot | bike, foot | bike, inherit, foot | bike, inherit, inherit } },
    .{ .name = "Belgium", .rules = .{ motor_vehicles_except_mopeds, motor_vehicles_except_mopeds, foot_bike_moped, inherit, foot | bike, foot, foot_bike_moped, foot_bike_moped, inherit } },
    .{ .name = "Brazil", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, inherit, inherit, inherit } },
    .{ .name = "China", .rules = .{ inherit, inherit, inherit, inherit, foot | bike, inherit, inherit, foot_bike_moped, inherit } },
    .{ .name = "Denmark", .rules = .{ motor_vehicles_except_mopeds, motor_vehicles_except_mopeds, foot | bike, inherit, inherit, inherit, foot | bike, inherit, inherit } },
    .{ .name = "England", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, foot | bike, inherit, inherit } },
    .{ .name = "France", .rules = .{ motor_vehicles_except_mopeds, motor_vehicles_except_mopeds, inherit, inherit, foot | bike, inherit, inherit, foot_bike_moped, inherit } },
    .{ .name = "Finland", .rules = .{ inherit, inherit, inherit, inherit, foot | bike, inherit, foot | bike, inherit, inherit } },
    .{ .name = "Greece", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, foot | bike, inherit, inherit } },
    .{ .name = "Hungary", .rules = .{ motor_vehicles_except_mopeds, motor_vehicles_except_mopeds, inherit, inherit, inherit, inherit, foot | bike, inherit, inherit } },
    .{ .name = "Iceland", .rules = .{ inherit, inherit, inherit, foot | bike, foot | bike, inherit, foot | bike, inherit, inherit } },
    .{ .name = "Ireland", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, inherit, inherit, inherit } },
    .{ .name = "Italy", .rules = .{ inherit, inherit, inherit, inherit, foot | bike, inherit, inherit, inherit, inherit } },
    .{ .name = "Netherlands", .rules = .{ inherit, inherit, inherit, inherit, inherit, inherit, foot | bike, foot_bike_moped, inherit } },
    .{ .name = "Norway", .rules = .{ inherit, inherit, foot_bike_moped, foot | bike, foot | bike, inherit, foot | bike, inherit, inherit } },
    .{ .name = "Northern Ireland", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, inherit, inherit, inherit } },
    .{ .name = "Oman", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, foot | bike, inherit, inherit } },
    .{ .name = "Philippines", .rules = .{ inherit, inherit, inherit, inherit, foot | bike, foot | bike, foot | bike, foot_bike_moped, inherit } },
    .{ .name = "Poland", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, foot | bike, foot_bike_moped, inherit } },
    .{ .name = "Romania", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot_bike_moped, bike | moped, foot_bike_moped, inherit } },
    .{ .name = "Russia", .rules = .{ inherit, inherit, inherit, inherit, inherit, inherit, bike | moped, inherit, inherit } },
    .{ .name = "Alba / Scotland", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, foot | bike, inherit, inherit } },
    .{ .name = "Slovakia", .rules = .{ motor_vehicles_except_mopeds, motor_vehicles_except_mopeds, inherit, inherit, inherit, inherit, inherit, inherit, inherit } },
    .{ .name = "Spain", .rules = .{ inherit, inherit, inherit, inherit, foot | bike, inherit, inherit, foot_bike_moped, inherit } },
    .{ .name = "Sweden", .rules = .{ inherit, inherit, inherit, inherit, foot | bike, foot, foot_bike_moped, inherit, inherit } },
    .{ .name = "Switzerland", .rules = .{ motor_vehicles_except_mopeds, motor_vehicles_except_mopeds, inherit, inherit, inherit, inherit, foot_bike_moped, inherit, inherit } },
    .{ .name = "ประเทศไทย", .rules = .{ inherit, inherit, inherit, inherit, foot | bike, foot | bike, foot | bike, foot_bike_moped, inherit } },
    .{ .name = "Türkiye", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot, foot | bike, inherit, inherit } },
    .{ .name = "United Kingdom", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, foot | bike, inherit, inherit } },
    .{ .name = "United States", .rules = .{ inherit, inherit, inherit, inherit, foot | bike, foot | bike, foot | bike, foot_bike_moped, inherit } },
    .{ .name = "Cymru / Wales", .rules = .{ inherit, inherit, inherit, inherit, inherit, foot | bike, foot | bike, inherit, inherit } },
};

// Ported from test/countryaccess.cc, the enhanced Amsterdam cycleways.
test "Dutch cycleways gain foot access and keep the bicycle and moped direction" {
    const testing = std.testing;
    const rules = defaults("Nederland", "Netherlands");
    try testing.expect(rules != .none);
    var road: EdgeClass = .{ .category = .{ .use = @backingInt(graph.Use.cycleway) }, .access = .{ .forward = bike | moped, .reverse = bike | moped } };
    apply(&road, rules, .{ .moped = true, .hov = true }, false);
    try testing.expectEqual(Pair{ .forward = foot_bike_moped, .reverse = foot_bike_moped }, road.access);
    road.access.forward = bike | moped;
    road.access.reverse = 0;
    apply(&road, rules, .{ .moped = true, .hov = true }, false);
    try testing.expectEqual(Pair{ .forward = foot_bike_moped, .reverse = foot }, road.access);
    road.access = .{ .forward = bike, .reverse = bike };
    apply(&road, rules, .{ .hov = true }, false);
    try testing.expectEqual(Pair{ .forward = foot | bike, .reverse = foot | bike }, road.access);
}

test "motorroad preserves explicit access and handles the absent country rule" {
    const testing = std.testing;
    const auto = mask(.{ .auto = true });
    var road: EdgeClass = .{
        .category = .{ .road_class = @backingInt(graph.RoadClass.trunk) },
        .access = .{ .forward = auto | foot_bike_moped, .reverse = foot },
    };
    apply(&road, .none, .{ .pedestrian = true, .moped = true, .motorcycle = true, .hov = true }, true);
    try testing.expectEqual(Pair{ .forward = auto | foot | moped, .reverse = foot }, road.access);
    apply(&road, defaults("Belgium", ""), .{ .hov = true }, false);
    try testing.expectEqual(@as(u16, 0), road.access.reverse);
    try testing.expectEqual(motor_vehicles_except_mopeds & ~mask(.{ .hov = true }), road.access.forward);
}
