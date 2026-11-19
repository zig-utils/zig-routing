// Ported from lua/graph.lua, lines 1557-1775 and 1835-1930, and from
// src/mjolnir/pbfgraphparser.cc's surface and way-use handlers (Valhalla 3.9.3).

const std = @import("std");
const constants = @import("../../graph/constants.zig");
const io = @import("../../infra/io.zig");
const attrs = @import("attrs.zig");
const defaults = @import("defaults.zig");
const Scratch = @import("input.zig").Scratch;
const Selection = @import("selection.zig").Selection;

const Surface = constants.Surface;
const Use = constants.Use;

pub fn classify(tags: *const Scratch, selected: Selection, deadline: io.Deadline, out: *attrs.WayAttrs) !void {
    const highway = tags.id(.highway);
    const effective_highway = if (highway == .construction) tags.text(.construction) else tags.text(.highway);
    out.use = useFor(tags, selected);
    if (out.use == .platform) out.road_class = .service_other;
    out.surface = try surface(tags, out.road_class, out.use, deadline);
    // ParseWays assigns the highway tile level after choosing the surface.
    if (selected.ferry or selected.rail) out.road_class = .primary;
    out.flags.link = tags.id(.link) == .true or if (effective_highway) |text|
        try contains(text, "_link", false, deadline)
    else
        false;
    out.flags.bridge = tags.id(.bridge) == .yes or tags.id(.bridge) == .@"1";
    out.flags.tunnel = switch (tags.id(.tunnel) orelse .unknown) {
        .yes, .@"1", .building_passage, .avalanche_protector => true,
        else => false,
    };
    out.flags.lit = switch (tags.id(.lit) orelse .unknown) {
        .yes, .@"24/7", .automatic, .@"dusk-dawn", .@"sunset-sunrise" => true,
        else => false,
    };
    out.flags.tagged_internal_intersection = tags.id(.junction) == .intersection or tags.id(.tagged_internal_intersection) == .true;
    out.flags.turn_channel = tags.id(.turn_channel) == .true;
    out.flags.pedestrian_area = out.flags.pedestrian_area or tags.id(.pedestrian_area) == .true;
    const no_thru = try defaults.any(.no_thru_traffic, tags.get(.access), deadline);
    const is_private = try defaults.any(.private, tags.get(.access), deadline) orelse
        try defaults.any(.private, tags.get(.motor_vehicle), deadline) orelse
        try defaults.any(.private, tags.get(.motorcar), deadline) orelse
        try defaults.any(.private, tags.get(.vehicle), deadline) orelse false;
    const service_destination = switch (out.use) {
        .driveway, .parking_aisle, .drive_through => true,
        else => false,
    };
    out.flags.destination_only = service_destination or is_private;
    out.flags.destination_only_hgv = service_destination or
        (try defaults.any(.private, tags.get(.hgv), deadline) orelse is_private);
    out.flags.no_thru_traffic = no_thru orelse false;
}

/// graph.lua (1579-1652) applies the more specific highway cases over
/// service tags, then cycle-street and emergency-only overrides.
fn useFor(tags: *const Scratch, selected: Selection) Use {
    const highway = tags.id(.highway);
    const service: ?Use = switch (tags.id(.service) orelse .unknown) {
        .driveway => .driveway,
        .alley => .alley,
        .parking_aisle => .parking_aisle,
        .emergency_access => .emergency_access,
        .@"drive-through" => .drive_through,
        else => null,
    };
    var use: ?Use = service;
    if (tags.get(.highway) != null) {
        if (highway == .construction) {
            use = .construction;
        } else if (highway == .track) {
            use = .track;
        } else if (highway == .living_street) {
            use = .living_street;
        } else if (highway == .service and use == null) {
            use = .service_road;
        } else if (highway == .cycleway or selected.bicycle_only) {
            use = .cycleway;
        } else {
            use = switch (highway orelse .unknown) {
                .footway => switch (tags.id(.footway) orelse .unknown) {
                    .sidewalk => .sidewalk,
                    .crossing => .pedestrian_crossing,
                    else => .footway,
                },
                .elevator => .elevator,
                .steps => if (tags.get(.conveying) != null) .escalator else .steps,
                .ladder => .ladder,
                .path => .path,
                .pedestrian => .pedestrian,
                .platform => .platform,
                else => if (selected.forward.pedestrian and selected.other_modes_denied)
                    .pedestrian
                else if (highway == .bridleway)
                    .bridleway
                else
                    use,
            };
        }
    }
    var result: Use = use orelse if (tags.get(.service) != null) .other else .road;
    if (defaults.single(.bicycle, tags.id(.cyclestreet)) == true or
        defaults.single(.bicycle, tags.id(.bicycle_road)) == true)
        result = .cycle_street;
    if (result != .construction and (tags.id(.access) == .emergency or tags.id(.emergency) == .yes) and
        selected.other_modes_denied)
        result = .emergency_access;
    return result;
}

fn contains(text: []const u8, needle: []const u8, ignore_case: bool, deadline: io.Deadline) !bool {
    if (text.len < needle.len) return false;
    for (0..text.len - needle.len + 1) |i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const part = text[i..][0..needle.len];
        if (if (ignore_case) std.ascii.eqlIgnoreCase(part, needle) else std.mem.eql(u8, part, needle))
            return true;
    }
    return false;
}

const surface_patterns = [_]struct { surface: Surface, values: []const []const u8 }{
    .{ .surface = .gravel, .values = &.{"unpaved"} },
    .{ .surface = .paved_smooth, .values = &.{ "paved", "pavement", "asphalt", "concrete", "cement", "chipseal", "metal" } },
    .{ .surface = .paved, .values = &.{ "tartan", "pavingstone", "paving_stones", "sett", "grass_paver", "rubber", "acrylic", "plastic" } },
    .{ .surface = .paved_rough, .values = &.{ "cobblestone", "brick" } },
    .{ .surface = .compacted, .values = &.{ "compacted", "wood", "boardwalk" } },
    .{ .surface = .dirt, .values = &.{ "dirt", "natural", "earth", "ground", "mud", "clay", "laterite", "soil" } },
    .{ .surface = .gravel, .values = &.{ "gravel", "pebblestone", "sand" } },
    .{ .surface = .path, .values = &.{ "grass", "artificial_turf", "rock", "stepping_stones" } },
};

fn namedSurface(text: []const u8, deadline: io.Deadline) !?Surface {
    if (std.ascii.eqlIgnoreCase(text, "stone")) return .paved_rough;
    for (surface_patterns) |group| {
        for (group.values) |needle| {
            if (try contains(text, needle, true, deadline)) return group.surface;
        }
    }
    return null;
}

/// The parser checks precedence by tag presence. An unrecognized surface
/// suppresses tracktype and smoothness, then falls back to the class/use.
fn taggedSurface(tags: *const Scratch, deadline: io.Deadline) !?Surface {
    if (tags.text(.surface)) |text| return namedSurface(text, deadline);
    if (tags.get(.tracktype) != null) {
        return switch (tags.id(.tracktype) orelse .unknown) {
            .grade1 => .paved_rough,
            .grade2 => .compacted,
            .grade3 => .dirt,
            .grade4 => .gravel,
            .grade5 => .path,
            else => null,
        };
    }
    return switch (tags.id(.smoothness) orelse .unknown) {
        .excellent, .good => .paved_smooth,
        .intermediate => .paved_rough,
        .bad => .compacted,
        .very_bad => .dirt,
        .horrible => .gravel,
        .very_horrible => .path,
        .impassable => .impassable,
        else => null,
    };
}

fn surface(tags: *const Scratch, road_class: constants.RoadClass, use: Use, deadline: io.Deadline) !Surface {
    if (tags.text(.@"mtb:scale")) |text| {
        if (try defaults.nonnegativeIntPrefix(text, deadline)) |scale| {
            return switch (scale) {
                0 => .dirt,
                1 => .gravel,
                else => .path,
            };
        }
    } else if (tags.text(.@"mtb:scale:uphill")) |text| {
        if (try defaults.nonnegativeIntPrefix(text, deadline)) |scale| return if (scale < 2) .gravel else .path;
    }
    if (try taggedSurface(tags, deadline)) |value| return value;
    if (tags.get(.sac_scale) != null or tags.id(.highway) == .via_ferrata) return .path;
    if (@backingInt(road_class) < @backingInt(constants.RoadClass.service_other)) return .paved_smooth;
    return switch (use) {
        .footway, .pedestrian, .sidewalk, .path, .bridleway => .compacted,
        .track => .dirt,
        .road, .parking_aisle, .driveway, .alley, .emergency_access, .drive_through, .living_street, .service_road, .cycle_street => .paved_smooth,
        else => .paved,
    };
}
