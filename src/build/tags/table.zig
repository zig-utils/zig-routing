//! Collision-free lookup for the known tag vocabulary. Free-form values
//! retain a borrowed slice of the original input.

const std = @import("std");

pub const Key = enum(u8) {
    highway,
    construction,
    area,
    route,
    railway,
    access,
    emergency,
    service,
    impassable,
    smoothness,
    vehicle,
    motor_vehicle,
    motorcar,
    hgv,
    bus,
    taxi,
    psv,
    @"lanes:psv:forward",
    @"lanes:psv:backward",
    @"lanes:bus",
    @"lanes:psv",
    foot,
    pedestrian,
    bicycle,
    bicycle_road,
    cyclestreet,
    cycleway,
    @"cycleway:left",
    @"cycleway:right",
    @"cycleway:both",
    moped,
    mofa,
    motorcycle,
    motorroad,
    sac_scale,
    oneway,
    @"oneway:bicycle",
    @"oneway:bus",
    @"oneway:taxi",
    @"oneway:psv",
    @"oneway:moped",
    @"oneway:mofa",
    @"oneway:motorcycle",
    @"oneway:foot",
    junction,
    busway,
    @"busway:left",
    @"busway:right",
    @"vehicle:forward",
    @"vehicle:backward",
    @"motor_vehicle:forward",
    @"motor_vehicle:backward",
    @"motorcar:forward",
    @"motorcar:backward",
    @"hgv:forward",
    @"hgv:backward",
    @"bus:forward",
    @"bus:backward",
    @"taxi:forward",
    @"taxi:backward",
    @"psv:forward",
    @"psv:backward",
    @"moped:forward",
    @"moped:backward",
    @"mofa:forward",
    @"mofa:backward",
    @"motorcycle:forward",
    @"motorcycle:backward",
    @"foot:forward",
    @"foot:backward",
    @"bicycle:forward",
    @"bicycle:backward",
    truck_forward,
    taxi_backward,
    bus_backward,
    bike_backward,
    pedestrian_backward,
    moped_backward,
    motorcycle_backward,
    name,
    @"name:en",
    alt_name,
    official_name,
    ref,
    int_ref,
    unsigned_ref,
    int_direction,
    @"tunnel:name",
    @"bridge:name",
    destination,
    @"destination:forward",
    @"destination:backward",
    @"destination:ref",
    @"destination:ref:to",
    @"destination:street",
    @"destination:street:to",
    @"destination:int_ref",
    @"destination:int_ref:to",
    @"junction:ref",
    @"junction:name",
    exit_to,
    surface,
    tracktype,
    @"mtb:scale",
    @"mtb:scale:uphill",
    link,
    turn_channel,
    tagged_internal_intersection,
    pedestrian_area,
    maxspeed,
    @"maxspeed:hgv",
    @"maxspeed:advisory",
    @"maxspeed:practical",
    @"maxspeed:forward",
    @"maxspeed:backward",
    lanes,
    @"lanes:forward",
    @"lanes:backward",
    @"turn:lanes",
    @"turn:lanes:forward",
    @"turn:lanes:backward",
    bridge,
    tunnel,
    lit,
    sidewalk,
    @"sidewalk:left",
    @"sidewalk:right",
    shoulder,
    indoor,
    wheelchair,
    barrier,
    layer,
    level,
    level_ref,
    footway,
    conveying,
    hov,
    @"hov:lanes",
    @"hov:minimum",
    @"oneway:conditional",
    @"access:conditional",
    auto_tag,
    truck_tag,
    foot_tag,
    bike_tag,
    @"mtb:scale:imba",
    @"mtb:description",
    bollard,
    crossing,
    entrance,
    amenity,
    public_transport,
    reference_point,
    direction,
    @"traffic_signals:direction",
    stop,
    give_way,
    forward_signal,
    backward_signal,
    forward_stop,
    backward_stop,
    forward_yield,
    backward_yield,
    toll,
    toll_booth,
    border_control,
    toll_gantry,
    building_entrance,
    elevator,
    cash_only_toll,
    @"cycleway:both:buffer",
    @"cycleway:left:buffer",
    @"cycleway:right:buffer",
    segregated,
    ncn,
    rcn,
    lcn,
    icn,
    mtb,
    ncn_ref,
    rcn_ref,
    lcn_ref,
    icn_ref,
    trail_visibility,
    step_count,
    tactile_paving,
    @"shoulder:both",
    @"shoulder:left",
    @"shoulder:right",
    duration,
};

pub const Value = enum(u8) {
    @"-1",
    @"1",
    @"2",
    @"24/7",
    @"3",
    agricultural,
    alley,
    allowed,
    alternating,
    assisted,
    automatic,
    avalanche_protector,
    backward,
    bad,
    bar,
    barrier_board,
    block,
    bollard,
    border_control,
    both,
    bridleway,
    buffered_lane,
    building_passage,
    bus,
    bus_guideway,
    busway,
    chain,
    circular,
    construction,
    corridor,
    crossing,
    customers,
    cycle_barrier,
    cyclestreet,
    cycleway,
    debris,
    delivery,
    designated,
    destination,
    discouraged,
    dismount,
    @"drive-through",
    driveway,
    @"dusk-dawn",
    elevator,
    emergency,
    emergency_access,
    excellent,
    false,
    fence,
    ferry,
    footway,
    forestry,
    forward,
    gate,
    give_way,
    good,
    grade1,
    grade2,
    grade3,
    grade4,
    grade5,
    half,
    hiking,
    horrible,
    hov,
    impassable,
    incorrect,
    intermediate,
    intersection,
    jersey_barrier,
    kissing_gate,
    ladder,
    lane,
    left,
    lift_gate,
    limited,
    living_street,
    local,
    minor,
    motorcycle_barrier,
    motorway,
    motorway_junction,
    motorway_link,
    named,
    no,
    none,
    official,
    only,
    opposite,
    opposite_lane,
    opposite_track,
    parking,
    parking_aisle,
    partial,
    passable,
    path,
    pedestrian,
    permissive,
    permit,
    platform,
    primary,
    primary_link,
    private,
    proposed,
    psv,
    public,
    rail,
    raised,
    removable,
    residential,
    residential_link,
    residents,
    restricted,
    reverse,
    reversible,
    right,
    rising,
    road,
    roundabout,
    secondary,
    secondary_link,
    service,
    share_busway,
    shared,
    shared_lane,
    shuttle_train,
    sidepath,
    sidewalk,
    sliding_beam,
    steps,
    stop,
    sump_buster,
    @"sunset-sunrise",
    swing_gate,
    taxi,
    tertiary,
    tertiary_link,
    toll_booth,
    toll_gantry,
    track,
    traffic_signals,
    true,
    trunk,
    trunk_link,
    unclassified,
    undefined,
    unknown,
    unsuitable,
    urban,
    use_sidepath,
    very_bad,
    very_horrible,
    via_ferrata,
    wall,
    yes,
};

pub fn key(bytes: []const u8) ?Key {
    return KeyTable.get(bytes);
}

pub fn value(bytes: []const u8) ?Value {
    return ValueTable.get(bytes);
}

pub const TagValue = union(enum) {
    id: Value,
    raw: []const u8,

    pub fn init(bytes: []const u8) TagValue {
        return if (value(bytes)) |id| .{ .id = id } else .{ .raw = bytes };
    }

    pub fn known(self: TagValue) ?Value {
        return switch (self) {
            .id => |id| id,
            .raw => null,
        };
    }

    pub fn text(self: TagValue) []const u8 {
        return switch (self) {
            .id => |id| @tagName(id),
            .raw => |bytes| bytes,
        };
    }
};

const KeyTable = PerfectHash(Key);
const ValueTable = PerfectHash(Value);

fn PerfectHash(comptime Id: type) type {
    const enumeration = @typeInfo(Id).@"enum";
    const fields = enumeration.field_names;
    const capacity = @as(usize, 1) << std.math.log2_int_ceil(usize, fields.len * 16);
    const Displacement = @Int(.unsigned, std.math.log2_int_ceil(usize, fields.len + 1));
    comptime {
        for (enumeration.field_values, 0..) |number, index| {
            if (number != index) @compileError("tag IDs must be contiguous from zero");
        }
    }
    const Table = struct {
        seed: u64,
        slots: [capacity]Displacement,
    };
    return struct {
        const table: Table = build();
        const max_length = blk: {
            var longest: usize = 0;
            for (fields) |field| longest = @max(longest, field.len);
            break :blk longest;
        };

        fn index(seed: u64, bytes: []const u8) usize {
            return @as(usize, @truncate(std.hash.Wyhash.hash(seed, bytes))) & (capacity - 1);
        }

        fn build() Table {
            @setEvalBranchQuota(10_000_000);
            for (0..4096) |seed| {
                var slots: [capacity]Displacement = @splat(0);
                for (fields, 1..) |field, ordinal| {
                    const slot = index(seed, field);
                    if (slots[slot] != 0) break;
                    slots[slot] = @intCast(ordinal);
                } else {
                    return .{ .seed = seed, .slots = slots };
                }
            }
            @compileError("no collision-free tag table seed");
        }

        fn get(bytes: []const u8) ?Id {
            if (bytes.len > max_length) return null;
            const slot = table.slots[index(table.seed, bytes)];
            if (slot == 0) return null;
            const id: Id = @fromBackingInt(@intCast(slot - 1));
            return if (std.mem.eql(u8, bytes, @tagName(id))) id else null;
        }
    };
}

test "tag vocabulary hashes without collisions and preserves unknown values" {
    const testing = std.testing;
    inline for (@typeInfo(Key).@"enum".field_names, 0..) |name, i|
        try testing.expectEqual(@as(?Key, @fromBackingInt(@intCast(i))), key(name));
    inline for (@typeInfo(Value).@"enum".field_names, 0..) |name, i|
        try testing.expectEqual(@as(?Value, @fromBackingInt(@intCast(i))), value(name));
    try testing.expectEqual(null, key("unrecognised:key"));
    try testing.expectEqual(null, value("Oude Gracht"));
    try testing.expectEqual(null, value("YES"));
    try testing.expectEqualStrings("Oude Gracht", TagValue.init("Oude Gracht").text());
    try testing.expectEqualStrings("no", TagValue.init("no").text());
}
