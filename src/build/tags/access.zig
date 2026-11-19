// Ported from lua/graph.lua, lines 1770-1776, 1835-1907 and 2022-2365,
// and the access handlers in src/mjolnir/pbfgraphparser.cc and
// src/mjolnir/directededgebuilder.cc (Valhalla 3.9.3).

const std = @import("std");
const constants = @import("../../graph/constants.zig");
const io = @import("../../infra/io.zig");
const attrs = @import("attrs.zig");
const defaults = @import("defaults.zig");
const Scratch = @import("input.zig").Scratch;
const Selection = @import("selection.zig").Selection;
const Key = @import("table.zig").Key;

const Mask = constants.AccessMask;

/// Refine the directional permissions produced by the way retention pass.
/// Classification has already established the surface and use required by
/// the directed edge's wheelchair rule.
pub fn applyWay(tags: *const Scratch, selected: Selection, deadline: io.Deadline, way: *attrs.WayAttrs) !void {
    var forward = selected.forward;
    var backward = selected.backward;
    const hov = tags.id(.hov);
    forward.hov = hov != .no and forward.auto;
    backward.hov = hov != .no and backward.auto;
    if ((tags.get(.hov) != null and hov != .no) or tags.get(.@"hov:lanes") != null or
        tags.get(.@"hov:minimum") != null)
    {
        if (try isHovOnly(tags, selected.roundabout, deadline)) {
            if (!selected.explicit.auto) {
                forward.auto = false;
                backward.auto = false;
            }
            if (!selected.explicit.truck) {
                forward.truck = false;
                backward.truck = false;
            }
            if (!selected.explicit.pedestrian) {
                forward.pedestrian = false;
                backward.pedestrian = false;
            }
            if (!selected.explicit.bicycle) {
                forward.bicycle = false;
                backward.bicycle = false;
            }
        } else {
            forward.hov = false;
            backward.hov = false;
        }
    }

    if (tags.id(.highway) == .construction) {
        forward = .{};
        backward = .{};
    }

    if (way.use != .construction and try mountainBikeAccess(tags, deadline)) {
        if (!way.flags.oneway_reverse) forward.bicycle = true;
        if (!way.flags.oneway) backward.bicycle = true;
    }

    const wheelchair = try defaults.any(.wheelchair, tags.get(.wheelchair), deadline);
    way.flags.wheelchair_tag = wheelchair != null;
    way.flags.wheelchair = wheelchair orelse false;
    if (way.use != .steps and way.use != .ladder and way.use != .construction and way.surface != .impassable) {
        forward.wheelchair = wheelchair orelse forward.pedestrian;
        backward.wheelchair = wheelchair orelse backward.pedestrian;
    }
    way.forward_access = forward;
    way.backward_access = backward;
}

fn isHovOnly(tags: *const Scratch, roundabout: bool, deadline: io.Deadline) !bool {
    const minimum = tags.id(.@"hov:minimum");
    if (tags.id(.hov) != .designated or (minimum != .@"2" and minimum != .@"3")) return false;
    // Lua distinguishes a missing one-way value from the string "false".
    if ((!roundabout and defaults.single(.oneway, tags.id(.oneway)) == false) or
        tags.get(.@"oneway:conditional") != null or tags.get(.@"access:conditional") != null)
        return false;
    const lanes = tags.text(.@"hov:lanes") orelse return true;
    var start: usize = 0;
    for (lanes, 0..) |byte, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (byte != '|') continue;
        if (!std.mem.eql(u8, lanes[start..i], "designated")) return false;
        start = i + 1;
    }
    return std.mem.eql(u8, lanes[start..], "designated");
}

/// The parser enables bicycle access for supported MTB grades, or when
/// only the IMBA scale or description is present.
fn mountainBikeAccess(tags: *const Scratch, deadline: io.Deadline) !bool {
    const downhill = tags.text(.@"mtb:scale");
    const uphill = tags.text(.@"mtb:scale:uphill");
    if (downhill) |text| {
        if (try defaults.nonnegativeIntPrefix(text, deadline)) |scale|
            if (scale < constants.max_mtb_scale) return true;
    }
    if (uphill) |text| {
        if (try defaults.nonnegativeIntPrefix(text, deadline)) |scale|
            if (scale < constants.max_mtb_uphill_scale) return true;
    }
    return downhill == null and uphill == null and
        (tags.get(.@"mtb:scale:imba") != null or tags.get(.@"mtb:description") != null);
}

/// Optional explicit mode choices from nodes_proc. False is a real
/// override and must survive fallback, as zero is truthy in Lua.
const NodeChoices = struct {
    auto: ?bool,
    pedestrian: ?bool,
    bicycle: ?bool,
    truck: ?bool,
    emergency: ?bool,
    taxi: ?bool,
    bus: ?bool,
    hov: ?bool,
    wheelchair: ?bool,
    moped: ?bool,
    motorcycle: ?bool,

    fn withDefaults(self: NodeChoices, base: Mask) Mask {
        var result: Mask = base;
        inline for (@typeInfo(NodeChoices).@"struct".field_names) |name|
            @field(result, name) = @field(self, name) orelse @field(base, name);
        return result;
    }

    fn any(self: NodeChoices) bool {
        inline for (@typeInfo(NodeChoices).@"struct".field_names) |name| {
            if (@field(self, name) != null) return true;
        }
        return false;
    }
};

fn any(tags: *const Scratch, kind: defaults.Boolean, key: Key, deadline: io.Deadline) !?bool {
    return defaults.any(kind, tags.get(key), deadline);
}

fn chooseModes(tags: *const Scratch, emergency: bool, deadline: io.Deadline) !NodeChoices {
    const motor = try any(tags, .motor_vehicle, .motor_vehicle, deadline);
    const auto = try any(tags, .motor_vehicle, .motorcar, deadline) orelse motor;
    const foot = try any(tags, .foot, .foot, deadline);
    const psv = tags.id(.access) == .psv;
    const restrictions = tags.get(.@"hov:lanes") != null or tags.get(.@"hov:minimum") != null;
    const hov = restrictions or (tags.get(.hov) != null and tags.id(.hov) != .no);
    const bike = try any(tags, .bicycle, .bicycle, deadline);
    const enabled_by_auto: ?bool = if (auto == true) true else null;
    const tag_deny_motor: ?bool = if (motor == false) false else null;

    return .{
        .auto = auto,
        .pedestrian = foot,
        .bicycle = if (bike == false and tags.id(.highway) == .crossing) true else bike,
        .truck = try any(tags, .truck, .hgv, deadline) orelse enabled_by_auto orelse tag_deny_motor,
        .emergency = if (emergency) true else null,
        .taxi = if (psv) true else try any(tags, .bus_taxi, .taxi, deadline) orelse
            try any(tags, .psv_taxi_node, .psv, deadline) orelse enabled_by_auto orelse tag_deny_motor,
        .bus = if (psv) true else try any(tags, .bus_taxi, .bus, deadline) orelse
            try any(tags, .psv_bus_node, .psv, deadline) orelse enabled_by_auto orelse tag_deny_motor,
        .hov = if (hov) true else enabled_by_auto orelse tag_deny_motor,
        .wheelchair = try any(tags, .wheelchair, .wheelchair, deadline) orelse if (foot == true) true else null,
        .moped = try any(tags, .moped, .moped, deadline) orelse try any(tags, .moped, .mofa, deadline) orelse tag_deny_motor,
        .motorcycle = try any(tags, .motorcycle_node, .motorcycle, deadline) orelse tag_deny_motor,
    };
}

const Barrier = struct {
    gate: bool = false,
    bollard: bool = false,
    sump_buster: bool = false,
    wall: bool = false,

    fn read(tags: *const Scratch) Barrier {
        const barrier = tags.id(.barrier);
        if (switch (barrier orelse .unknown) {
            .gate, .yes, .lift_gate, .swing_gate, .sliding_beam => true,
            else => false,
        }) return .{ .gate = true };
        const bollard = tags.id(.bollard);
        var result: Barrier = .{
            .bollard = bollard == .removable or switch (barrier orelse .unknown) {
                .bollard, .block, .kissing_gate, .motorcycle_barrier, .cycle_barrier, .chain, .bar => true,
                else => false,
            },
            .sump_buster = barrier == .sump_buster,
            .wall = switch (barrier orelse .unknown) {
                .fence, .barrier_board, .wall, .jersey_barrier, .debris => true,
                else => false,
            },
        };
        if (result.bollard and bollard == .rising) {
            result.gate = true;
            result.bollard = false;
        }
        return result;
    }
};

fn isCrossing(tags: *const Scratch) bool {
    const keys: []const Key = &.{ .highway, .railway, .footway, .cycleway, .foot, .bicycle, .pedestrian };
    for (keys) |key| {
        if (tags.id(key) == .crossing) return true;
    }
    return tags.get(.crossing) != null;
}

fn nodeType(tags: *const Scratch, barrier: Barrier) constants.NodeType {
    const kind = tags.id(.barrier);
    const highway = tags.id(.highway);
    if (kind == .border_control or tags.id(.border_control) == .true) return .border_control;
    if (kind == .toll_booth or tags.id(.toll_booth) == .true or tags.id(.cash_only_toll) == .true) return .toll_booth;
    if (highway == .toll_gantry or tags.id(.toll_gantry) == .true) return .toll_gantry;
    if (barrier.gate) return .gate;
    if (barrier.bollard) return .bollard;
    if (barrier.sump_buster) return .sump_buster;
    if ((tags.id(.entrance) == .yes and tags.id(.indoor) == .yes) or tags.id(.building_entrance) == .true)
        return .building_entrance;
    if (highway == .elevator or tags.id(.elevator) == .true) return .elevator;
    if (tags.id(.amenity) == .parking) return .parking;
    if (highway == .motorway_junction) return .motorway_junction;
    return .street_intersection;
}

fn signals(tags: *const Scratch, out: *attrs.NodeAttrs) void {
    const highway = tags.id(.highway);
    const direction = tags.id(.direction);
    const signal = tags.id(.@"traffic_signals:direction");
    const forward = direction == .forward or direction == .both;
    const backward = direction == .backward or direction == .reverse or direction == .both;
    const directional = tags.get(.direction) != null;
    const stop = highway == .stop;
    const yield = highway == .give_way;
    out.flags.traffic_signal = highway == .traffic_signals;
    out.flags.stop_sign = stop and (!directional or forward or backward or tags.get(.stop) != null);
    out.flags.yield_sign = yield and (!directional or forward or backward or tags.get(.give_way) != null);
    out.flags.forward_signal = signal == .forward or tags.id(.forward_signal) == .true;
    out.flags.backward_signal = signal == .backward or tags.id(.backward_signal) == .true;
    out.flags.forward_stop = (stop and forward) or tags.id(.forward_stop) == .true;
    out.flags.backward_stop = (stop and backward) or tags.id(.backward_stop) == .true;
    out.flags.forward_yield = (yield and forward) or tags.id(.forward_yield) == .true;
    out.flags.backward_yield = (yield and backward) or tags.id(.backward_yield) == .true;
    out.flags.direction = ((stop or yield) and (forward or backward)) or tags.get(.forward_stop) != null or
        tags.get(.backward_stop) != null or tags.get(.forward_yield) != null or tags.get(.backward_yield) != null;
    out.flags.minor = tags.id(.stop) == .minor or tags.id(.give_way) == .minor;
    const junction = tags.id(.junction);
    const named = junction == .yes or junction == .named or (tags.get(.public_transport) == null and
        (highway == .traffic_signals or signal == .forward or signal == .backward or tags.id(.reference_point) == .yes));
    if (out.name) |name| {
        out.flags.named_intersection = name.len != 0 and
            (named or tags.id(.barrier) == .toll_booth or highway == .toll_gantry);
    }
}

pub fn applyNode(tags: *const Scratch, deadline: io.Deadline, out: *attrs.NodeAttrs) !void {
    const initial = try any(tags, .access, .access, deadline);
    const access = tags.id(.access);
    const emergency = access == .emergency or tags.id(.emergency) == .yes or tags.id(.service) == .emergency_access;
    const allowed = (initial orelse true) and tags.id(.impassable) != .yes and !(access == .private and emergency);
    const choices = try chooseModes(tags, emergency, deadline);
    const hov_only = tags.id(.hov) == .designated;
    const restricted = !allowed or tags.id(.vehicle) == .no or tags.id(.smoothness) == .impassable or hov_only;
    const barrier = Barrier.read(tags);
    const bollard_without_access = barrier.bollard and initial == null;
    const open_crossing = !barrier.gate and !barrier.bollard and !barrier.sump_buster and !barrier.wall and
        allowed and isCrossing(tags);

    const base: Mask = if (bollard_without_access)
        .{ .pedestrian = true, .bicycle = true, .wheelchair = true }
    else if (barrier.sump_buster)
        .{
            .pedestrian = true,
            .bicycle = true,
            .wheelchair = true,
            .truck = true,
            .bus = true,
            .moped = true,
            .motorcycle = true,
            .emergency = true,
        }
    else if (barrier.wall)
        .{}
    else if (open_crossing)
        .all_tag_modes
    else if (restricted)
        .{ .pedestrian = allowed and !hov_only }
    else base: {
        var mask = Mask.all_tag_modes;
        mask.taxi = choices.auto orelse true;
        mask.hov = choices.auto orelse true;
        break :base mask;
    };
    out.access = choices.withDefaults(base);
    out.type = nodeType(tags, barrier);
    out.flags.tagged_access = initial != null or choices.any();
    out.flags.private_access = try any(tags, .private, .access, deadline) orelse
        try any(tags, .private, .motor_vehicle, deadline) orelse false;
    signals(tags, out);
}
