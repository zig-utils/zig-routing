// Ported from valhalla/baldr/graphconstants.h (Valhalla 3.9.3).

pub const max_mtb_scale = 6;
pub const max_mtb_uphill_scale = 5;
pub const max_assumed_speed = 140;
pub const unlimited_speed_limit = 255;
pub const max_lane_count = 15;

pub const SpeedType = enum(u8) { tagged = 0, classified = 1 };

pub const RoadClass = enum(u8) {
    motorway = 0,
    trunk = 1,
    primary = 2,
    secondary = 3,
    tertiary = 4,
    unclassified = 5,
    residential = 6,
    service_other = 7,
    invalid = 8,
};

pub const Use = enum(u8) {
    road = 0,
    ramp = 1,
    turn_channel = 2,
    track = 3,
    driveway = 4,
    alley = 5,
    parking_aisle = 6,
    emergency_access = 7,
    drive_through = 8,
    culdesac = 9,
    living_street = 10,
    service_road = 11,
    cycle_street = 12,
    cycleway = 20,
    mountain_bike = 21,
    sidewalk = 24,
    footway = 25,
    steps = 26,
    path = 27,
    pedestrian = 28,
    bridleway = 29,
    rest_area = 30,
    service_area = 31,
    pedestrian_crossing = 32,
    elevator = 33,
    escalator = 34,
    platform = 35,
    ladder = 36,
    other = 40,
    ferry = 41,
    rail_ferry = 42,
    construction = 43,
    rail = 50,
    bus = 51,
    egress_connection = 52,
    platform_connection = 53,
    transit_connection = 54,
};

pub const Surface = enum(u3) {
    paved_smooth,
    paved,
    paved_rough,
    compacted,
    dirt,
    gravel,
    path,
    impassable,
};

pub const NodeType = enum(u4) {
    street_intersection,
    gate,
    bollard,
    toll_booth,
    transit_egress,
    transit_station,
    multi_use_transit_platform,
    bike_share,
    parking,
    motorway_junction,
    border_control,
    toll_gantry,
    sump_buster,
    building_entrance,
    elevator,
};

pub const AccessMask = packed struct(u16) {
    auto: bool = false,
    pedestrian: bool = false,
    bicycle: bool = false,
    truck: bool = false,
    emergency: bool = false,
    taxi: bool = false,
    bus: bool = false,
    hov: bool = false,
    wheelchair: bool = false,
    moped: bool = false,
    motorcycle: bool = false,
    reserved: u5 = 0,

    pub const all_tag_modes: AccessMask = @bitCast(@as(u16, 0x07ff));
};

test "attribute discriminants match upstream graph constants" {
    const testing = @import("std").testing;
    try testing.expectEqual(7, @backingInt(RoadClass.service_other));
    try testing.expectEqual(42, @backingInt(Use.rail_ferry));
    try testing.expectEqual(14, @backingInt(NodeType.elevator));
    try testing.expectEqual(7, @backingInt(Surface.impassable));
    try testing.expectEqual(@as(u16, 0x15), @as(u16, @bitCast(AccessMask{ .auto = true, .bicycle = true, .emergency = true })));
}
