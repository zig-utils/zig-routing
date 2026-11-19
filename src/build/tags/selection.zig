// Ported from lua/graph.lua, filter_tags_generic lines 922-1550
// (Valhalla 3.9.3). The initial permissions determine way retention.
// The rule families that follow the filter refine output attributes.

const std = @import("std");
const attr = @import("../../graph/constants.zig");
const io = @import("../../infra/io.zig");
const defaults = @import("defaults.zig");
const table = @import("table.zig");
const Scratch = @import("input.zig").Scratch;
const Key = table.Key;
const Value = table.Value;

const Flag = enum {
    missing,
    deny,
    allow,
    other,

    fn fromBool(value: bool) Flag {
        return if (value) .allow else .deny;
    }

    fn optional(value: ?bool) Flag {
        return if (value) |v| fromBool(v) else .missing;
    }

    fn raw(tags: *const Scratch, key: Key) Flag {
        const value = tags.get(key) orelse return .missing;
        return switch (value.known() orelse return .other) {
            .true => .allow,
            .false => .deny,
            else => .other,
        };
    }

    fn ifUnset(self: Flag, fallback: Flag) Flag {
        return if (self == .missing) fallback else self;
    }
};

const Flags = struct {
    auto: Flag = .deny,
    pedestrian: Flag = .deny,
    bicycle: Flag = .deny,
    truck: Flag = .deny,
    emergency: Flag = .deny,
    taxi: Flag = .deny,
    bus: Flag = .deny,
    moped: Flag = .deny,
    motorcycle: Flag = .deny,

    fn fromMask(access: attr.AccessMask) Flags {
        var result: Flags = undefined;
        inline for (@typeInfo(Flags).@"struct".field_names) |name|
            @field(result, name) = Flag.fromBool(@field(access, name));
        return result;
    }

    fn mask(self: Flags) attr.AccessMask {
        var result: attr.AccessMask = .{};
        inline for (@typeInfo(Flags).@"struct".field_names) |name|
            @field(result, name) = @field(self, name) == .allow;
        return result;
    }

    fn hasAccess(self: Flags) bool {
        // The upstream skip predicate excludes taxi access and compares
        // to the literal string "false". An unset directional tag can
        // therefore also keep the way.
        inline for (@typeInfo(Flags).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "taxi")) {
                if (@field(self, name) != .deny) return true;
            }
        }
        return false;
    }

    fn otherModesDenied(self: Flags) bool {
        return self.auto == .deny and self.truck == .deny and self.bus == .deny and
            self.bicycle == .deny and self.moped == .deny and self.motorcycle == .deny;
    }
};

pub const Selection = struct {
    road_class: attr.RoadClass,
    forward: attr.AccessMask,
    backward: attr.AccessMask,
    ferry: bool,
    rail: bool,
    oneway: bool,
    oneway_reverse: bool,
    roundabout: bool,
    pedestrian_area: bool,
    bicycle_only: bool,
    other_modes_denied: bool,
};

fn any(tags: *const Scratch, kind: defaults.Boolean, key: Key, deadline: io.Deadline) !?bool {
    return defaults.any(kind, tags.get(key), deadline);
}

fn anyChoice(tags: *const Scratch, kind: defaults.Boolean, first: Key, second: Key, deadline: io.Deadline) !?bool {
    return defaults.any(kind, tags.get(first) orelse tags.get(second), deadline);
}

fn inherited(value: ?bool, fallback: Flag) Flag {
    return if (value) |v| Flag.fromBool(v) else fallback;
}

fn cycleReverse(v: ?Value) bool {
    return v == .opposite or v == .opposite_lane or v == .opposite_track;
}

fn busReverse(v: ?Value) bool {
    return v == .opposite or v == .opposite_lane;
}

fn cycleLane(v: ?Value) bool {
    return switch (v orelse return false) {
        .shared_lane, .share_busway, .shared, .opposite_lane, .lane, .buffered_lane, .opposite_track, .track => true,
        else => false,
    };
}

fn yesOrDesignated(v: ?Value) bool {
    return v == .yes or v == .designated;
}

fn oneWayForward(opposite: Flag, restriction: ?bool, forward: Flag) Flag {
    if (opposite != .allow) return forward;
    return if (restriction) |oneway| Flag.fromBool(!oneway) else forward;
}

fn fillBackward(backward: *Flag, forward: Flag, use_default: bool) void {
    if (backward.* == .deny and use_default) backward.* = forward;
}

const Direction = enum { forward, backward };
fn direction(tags: *const Scratch, flags: *Flags, comptime dir: Direction, deadline: io.Deadline) !void {
    const key = struct {
        fn of(comptime base: []const u8) Key {
            return @field(Key, base ++ ":" ++ @tagName(dir));
        }
    }.of;
    const motor = try anyChoice(tags, .motor_vehicle, key("motor_vehicle"), key("vehicle"), deadline);
    const psv = try any(tags, .psv, key("psv"), deadline);
    flags.auto = inherited(try any(tags, .motor_vehicle, key("motorcar"), deadline) orelse motor, flags.auto);
    flags.truck = inherited(try any(tags, .truck, key("hgv"), deadline) orelse motor, flags.truck);
    flags.bus = inherited(try any(tags, .bus_taxi, key("bus"), deadline) orelse psv orelse motor, flags.bus);
    flags.taxi = inherited(try any(tags, .bus_taxi, key("taxi"), deadline) orelse psv orelse motor, flags.taxi);
    flags.moped = inherited(try any(tags, .moped, key("moped"), deadline) orelse
        try any(tags, .moped, key("mofa"), deadline) orelse motor, flags.moped);
    flags.motorcycle = inherited(try any(tags, .motor_vehicle, key("motorcycle"), deadline) orelse motor, flags.motorcycle);
    if (tags.get(key("foot"))) |foot| flags.pedestrian = .optional(try defaults.any(.foot, foot, deadline));
    if (tags.get(key("bicycle")) orelse tags.get(key("vehicle"))) |bike|
        flags.bicycle = .optional(try defaults.any(.bicycle, bike, deadline));
}

pub fn select(tags: *const Scratch, deadline: io.Deadline) !?Selection {
    const highway = tags.id(.highway);
    const construction = tags.get(.construction);
    if ((highway == .construction and construction == null) or highway == .proposed) return null;
    const area = tags.id(.area) == .yes;
    if (area and highway != .pedestrian) return null;
    const known = defaults.highway(if (highway == .construction)
        (construction orelse unreachable).known()
    else
        highway);
    const ferry = tags.id(.route) == .ferry;
    const rail = tags.id(.route) == .shuttle_train;
    const access = tags.id(.access);
    const service = tags.id(.service);
    const emergency = tags.id(.emergency);
    const is_emergency = access == .emergency or emergency == .yes or service == .emergency_access;
    const has_highway = tags.get(.highway) != null;

    var forward: Flags = .{ .emergency = Flag.fromBool((has_highway or ferry or rail) and is_emergency) };
    var backward: Flags = .{};
    if (known != null or ferry or rail) {
        const is_ferry_access = known == null;
        const deny = tags.id(.impassable) == .yes or
            try any(tags, .access, .access, deadline) == false or
            (access == .private and (emergency == .yes or (is_ferry_access and service == .emergency_access))) or
            (!is_ferry_access and service == .emergency_access);
        const smoothness = tags.id(.smoothness) == .impassable;
        const base = if (known) |value| value.access else defaults.street;
        const f = if (deny) Flags{} else Flags.fromMask(base);
        forward.auto = if (smoothness) .deny else f.auto;
        forward.truck = if (smoothness) .deny else f.truck;
        forward.bus = if (smoothness) .deny else f.bus;
        forward.taxi = if (smoothness) .deny else f.taxi;
        forward.bicycle = if (smoothness) .deny else f.bicycle;
        forward.moped = if (smoothness) .deny else f.moped;
        forward.motorcycle = if (smoothness) .deny else f.motorcycle;
        forward.pedestrian = f.pedestrian;

        const deny_back = known != null and (deny or smoothness);
        backward.bus = if (deny_back) .deny else .raw(tags, .bus_backward);
        backward.taxi = if (deny_back) .deny else .raw(tags, .taxi_backward);
        backward.bicycle = if (deny_back) .deny else .raw(tags, .bike_backward);
        backward.moped = if (deny_back) .deny else .raw(tags, .moped_backward);
        backward.motorcycle = if (deny_back) .deny else .raw(tags, .motorcycle_backward);
        backward.pedestrian = if (known != null and deny) .deny else .raw(tags, .pedestrian_backward);

        const vehicle = try any(tags, .motor_vehicle, .vehicle, deadline);
        const motor = try any(tags, .motor_vehicle, .motor_vehicle, deadline) orelse vehicle;
        const psv = try any(tags, .psv, .psv, deadline) orelse defaults.single(.psv, tags.id(.@"lanes:psv:forward"));
        const truck = try any(tags, .truck, .hgv, deadline);
        const bike = try any(tags, .bicycle, .bicycle, deadline) orelse
            try any(tags, .cycleway, .cycleway, deadline) orelse
            try any(tags, .bicycle, .bicycle_road, deadline) orelse
            defaults.single(.bicycle, tags.id(.cyclestreet)) orelse vehicle;
        forward.auto = inherited(try any(tags, .motor_vehicle, .motorcar, deadline) orelse motor, forward.auto);
        forward.truck = if (is_ferry_access and truck == null)
            Flag.raw(tags, .truck_forward).ifUnset(inherited(motor, forward.truck))
        else
            inherited(truck orelse motor, forward.truck);
        forward.bus = inherited(try any(tags, .bus_taxi, .bus, deadline) orelse psv orelse motor, forward.bus);
        forward.taxi = inherited(try any(tags, .bus_taxi, .taxi, deadline) orelse psv orelse motor, forward.taxi);
        forward.pedestrian = inherited(try any(tags, .foot, .foot, deadline) orelse
            defaults.single(.foot, tags.id(.pedestrian)), forward.pedestrian);
        forward.bicycle = inherited(bike, forward.bicycle);
        if (bike == null and is_ferry_access and tags.get(.sac_scale) != null)
            forward.bicycle = Flag.fromBool(tags.id(.sac_scale) == .hiking);
        forward.moped = inherited(try any(tags, .moped, .moped, deadline) orelse
            try any(tags, .moped, .mofa, deadline) orelse motor, forward.moped);
        forward.motorcycle = inherited(try any(tags, .motor_vehicle, .motorcycle, deadline) orelse motor, forward.motorcycle);
        if (access == .psv) {
            forward.bus = .allow;
            forward.taxi = .allow;
        }
    }

    // Reversible access and service=driveway overrides precede direction
    // resolution in graph.lua (1165-1194).
    const oneway = tags.id(.oneway);
    if (oneway == .reversible and (access == .permissive or access == .hov or access == .taxi)) {
        if (forward.bus != .allow) return null;
        forward.auto = .deny;
        forward.truck = .deny;
        forward.pedestrian = .deny;
        forward.bicycle = .deny;
        forward.moped = .deny;
        forward.motorcycle = .deny;
    }
    if (service == .driveway and tags.get(.access) == null) {
        const emergency_before = forward.emergency;
        forward = Flags.fromMask(defaults.street);
        forward.emergency = emergency_before;
    }

    const bike_oneway = tags.id(.@"oneway:bicycle");
    const bus_oneway = (tags.get(.@"oneway:bus") orelse tags.get(.@"oneway:psv"));
    const taxi_oneway = (tags.get(.@"oneway:taxi") orelse tags.get(.@"oneway:psv"));
    const bus_id = if (bus_oneway) |v| v.known() else null;
    const taxi_id = if (taxi_oneway) |v| v.known() else null;
    const moped_oneway = tags.id(.@"oneway:moped");
    const mofa_oneway = tags.id(.@"oneway:mofa");
    const moto_oneway = tags.id(.@"oneway:motorcycle");
    const foot_oneway = tags.id(.@"oneway:foot");
    const bike_back = tags.id(.@"bicycle:backward");
    const bus_back = tags.id(.@"bus:backward");
    const taxi_back = tags.id(.@"taxi:backward");
    const yes_oneway = oneway == .yes;
    const bike_both = tags.id(.@"cycleway:both");
    const cycle_left = tags.id(.@"cycleway:left");
    const cycle_right = tags.id(.@"cycleway:right");
    const bus_left = tags.id(.@"busway:left");
    const bus_right = tags.id(.@"busway:right");
    const busway = tags.id(.busway);

    if ((yes_oneway and bike_oneway == .no) or bike_back == .yes or bike_back == .no) backward.bicycle = .allow;
    if (backward.bicycle == .missing or backward.bicycle == .deny)
        backward.bicycle = Flag.fromBool(cycleReverse(tags.id(.cycleway)) or cycleReverse(cycle_left) or cycleReverse(cycle_right));
    if ((yes_oneway and bus_id == .no) or yesOrDesignated(bus_back)) backward.bus = .allow;
    if (backward.bus == .missing or backward.bus == .deny)
        backward.bus = Flag.fromBool(busReverse(busway) or busReverse(bus_left) or busReverse(bus_right) or
            defaults.single(.psv, tags.id(.@"lanes:psv:backward")) == true);
    if ((yes_oneway and taxi_id == .no) or yesOrDesignated(taxi_back)) backward.taxi = .allow;
    if (backward.taxi == .missing or backward.taxi == .deny)
        backward.taxi = Flag.fromBool(defaults.single(.psv, tags.id(.@"lanes:psv:backward")) == true);

    backward.moped = backward.moped.ifUnset(.deny);
    if ((yes_oneway and (moped_oneway == .no or mofa_oneway == .no)) or
        tags.id(.@"moped:backward") == .yes or tags.id(.@"mofa:backward") == .yes)
        backward.moped = .allow;
    backward.motorcycle = backward.motorcycle.ifUnset(.deny);
    if ((yes_oneway and moto_oneway == .no) or tags.id(.@"motorcycle:backward") == .yes)
        backward.motorcycle = .allow;
    backward.pedestrian = backward.pedestrian.ifUnset(.deny);
    if ((yes_oneway and foot_oneway == .no) or tags.id(.@"foot:backward") == .yes)
        backward.pedestrian = .allow;

    const junction = tags.id(.junction);
    const roundabout = junction == .roundabout or junction == .circular;
    const is_oneway = roundabout or defaults.single(.oneway, oneway) == true;
    if (is_oneway) {
        forward.bicycle = oneWayForward(backward.bicycle, defaults.single(.oneway, bike_oneway), forward.bicycle);
        const bus_restriction = defaults.single(.oneway, bus_id);
        const taxi_restriction = defaults.single(.oneway, taxi_id);
        forward.bus = oneWayForward(backward.bus, if (bus_restriction == false and bus_back == .yes) true else bus_restriction, forward.bus);
        forward.taxi = oneWayForward(backward.taxi, if (taxi_restriction == false and taxi_back == .yes) true else taxi_restriction, forward.taxi);
        forward.moped = oneWayForward(backward.moped, defaults.single(.oneway, moped_oneway) orelse defaults.single(.oneway, mofa_oneway), forward.moped);
        forward.motorcycle = oneWayForward(backward.motorcycle, defaults.single(.oneway, moto_oneway), forward.motorcycle);
        if (highway == .footway or highway == .pedestrian or highway == .steps or highway == .path or tags.get(.@"oneway:foot") != null) {
            forward.pedestrian = oneWayForward(backward.pedestrian, defaults.single(.oneway, foot_oneway), forward.pedestrian);
        } else {
            backward.pedestrian = forward.pedestrian;
        }
    } else {
        backward.auto = forward.auto;
        backward.truck = forward.truck;
        backward.emergency = forward.emergency;
        fillBackward(&backward.bicycle, forward.bicycle, tags.get(.@"oneway:bicycle") == null or bike_oneway == .no);
        fillBackward(&backward.bus, forward.bus, bus_oneway == null);
        fillBackward(&backward.taxi, forward.taxi, taxi_oneway == null);
        fillBackward(&backward.moped, forward.moped, (tags.get(.@"oneway:moped") == null or moped_oneway == .no) and
            (tags.get(.@"oneway:mofa") == null or mofa_oneway == .no));
        fillBackward(&backward.motorcycle, forward.motorcycle, tags.get(.@"oneway:motorcycle") == null or moto_oneway == .no);
        fillBackward(&backward.pedestrian, forward.pedestrian, tags.get(.@"oneway:foot") == null or foot_oneway == .no);
    }
    if (cycleLane(bike_both) or (cycleLane(cycle_left) and cycleLane(cycle_right))) {
        forward.bicycle = .allow;
        backward.bicycle = .allow;
    }
    if (busway == .lane or (bus_left == .lane and bus_right == .lane)) {
        forward.bus = .allow;
        backward.bus = .allow;
    }
    try direction(tags, &forward, .forward, deadline);
    try direction(tags, &backward, .backward, deadline);

    const reverse = oneway == .@"-1";
    if (reverse) std.mem.swap(Flags, &forward, &backward);
    if (bike_oneway == .@"-1") std.mem.swap(Flag, &forward.bicycle, &backward.bicycle);
    if (moped_oneway == .@"-1" or mofa_oneway == .@"-1") std.mem.swap(Flag, &forward.moped, &backward.moped);
    if (moto_oneway == .@"-1") std.mem.swap(Flag, &forward.motorcycle, &backward.motorcycle);
    if (foot_oneway == .@"-1") std.mem.swap(Flag, &forward.pedestrian, &backward.pedestrian);
    if (bus_id == .@"-1") std.mem.swap(Flag, &forward.bus, &backward.bus);
    if (taxi_id == .@"-1") std.mem.swap(Flag, &forward.taxi, &backward.taxi);
    switch (tags.id(.@"lanes:bus") orelse .unknown) {
        .@"1", .@"2" => |lanes| {
            forward.bus = .allow;
            backward.bus = Flag.fromBool(lanes == .@"2");
        },
        else => {},
    }
    switch (tags.id(.@"lanes:psv") orelse .unknown) {
        .@"1", .@"2" => |lanes| {
            forward.taxi = .allow;
            backward.taxi = Flag.fromBool(lanes == .@"2");
        },
        else => {},
    }

    if (!forward.hasAccess() and !backward.hasAccess() and highway != .bridleway) return null;
    const road_class: attr.RoadClass = if (!has_highway and (ferry or rail or tags.get(.railway) != null))
        .primary
    else if (known) |value|
        value.road_class
    else
        .service_other;
    return .{
        .road_class = road_class,
        .forward = forward.mask(),
        .backward = backward.mask(),
        .ferry = ferry,
        .rail = forward.auto == .allow and (rail or tags.id(.railway) == .rail),
        .oneway = is_oneway,
        .oneway_reverse = reverse,
        .roundabout = roundabout,
        .pedestrian_area = area,
        .bicycle_only = forward.pedestrian == .deny and forward.auto == .deny and
            backward.auto == .deny and (forward.bicycle == .allow or backward.bicycle == .allow),
        .other_modes_denied = forward.otherModesDenied() and backward.otherModesDenied(),
    };
}
