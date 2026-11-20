// Ported from proto/descriptors/directions.proto (Valhalla 3.9.3).
//! Native maneuver and directions values sharing the trip model.

const trip = @import("trip.zig");
const mirror = @import("model_schema.zig");
const directions_schema = @import("proto/directions.zig");

pub const Summary = trip.Summary;
pub const TransitInfo = trip.TransitRouteInfo;

comptime {
    mirror.checkCoverage(@This(), directions_schema);
}

pub const GuidanceViewType = directions_schema.DirectionsLeg_GuidanceView_Type;
pub const CardinalDirection = directions_schema.DirectionsLeg_Maneuver_CardinalDirection;
pub const ManeuverType = directions_schema.DirectionsLeg_Maneuver_Type;
pub const BssManeuverType = directions_schema.DirectionsLeg_Maneuver_BssManeuverType;

pub const DirectionsLeg = struct {
    trip_id: u64 = 0,
    leg_id: u32 = 0,
    leg_count: u32 = 0,
    location: []const trip.Location = &.{},
    summary: ?Summary = null,
    maneuver: []const Maneuver = &.{},
    shape: []const u8 = "",
    level_changes: []const trip.LevelChange = &.{},

    pub const Schema = directions_schema.DirectionsLeg;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    }
};

pub const GuidanceView = struct {
    data_id: []const u8 = "",
    type: GuidanceViewType = .kJunction,
    base_id: []const u8 = "",
    overlay_ids: []const []const u8 = &.{},

    pub const Schema = directions_schema.DirectionsLeg_GuidanceView;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4 });
    }
};

pub const Maneuver = struct {
    type: ManeuverType = .kNone,
    text_instruction: []const u8 = "",
    street_name: []const trip.StreetName = &.{},
    length: f32 = 0,
    time: f64 = 0,
    begin_cardinal_direction: CardinalDirection = .kNorth,
    begin_heading: u32 = 0,
    begin_shape_index: u32 = 0,
    end_shape_index: u32 = 0,
    portions_toll: bool = false,
    portions_unpaved: bool = false,
    verbal_transition_alert_instruction: []const u8 = "",
    verbal_pre_transition_instruction: []const u8 = "",
    verbal_post_transition_instruction: []const u8 = "",
    begin_street_name: []const trip.StreetName = &.{},
    sign: ?trip.Sign = null,
    roundabout_exit_count: u32 = 0,
    depart_instruction: []const u8 = "",
    verbal_depart_instruction: []const u8 = "",
    arrive_instruction: []const u8 = "",
    verbal_arrive_instruction: []const u8 = "",
    transit_info: ?TransitInfo = null,
    verbal_multi_cue: bool = false,
    travel_mode: trip.TravelMode = .kDrive,
    vehicle_type: trip.VehicleType = .kCar,
    pedestrian_type: trip.PedestrianType = .kFoot,
    bicycle_type: trip.BicycleType = .kRoad,
    transit_type: trip.TransitType = .kTram,
    begin_path_index: u32 = 0,
    end_path_index: u32 = 0,
    to_stay_on: bool = false,
    roundabout_exit_street_names: []const trip.StreetName = &.{},
    turn_degree: u32 = 0,
    has_time_restrictions: bool = false,
    guidance_views: []const GuidanceView = &.{},
    bss_maneuver_type: BssManeuverType = .kNoneAction,
    verbal_succinct_transition_instruction: []const u8 = "",
    bss_info: ?trip.BikeShareStationInfo = null,
    portions_highway: bool = false,
    portions_ferry: bool = false,
    landmarks: []const trip.RouteLandmark = &.{},

    pub const Schema = directions_schema.DirectionsLeg_Maneuver;
    comptime {
        mirror.check(@This(), &.{
            1,  2,  3,  4,  5,  6,  7,  8,  9,  10,
            11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
            21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
            31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
            41,
        });
    }
};

pub const DirectionsRoute = struct {
    legs: []const DirectionsLeg = &.{},

    pub const Schema = directions_schema.DirectionsRoute;
    comptime {
        mirror.check(@This(), &.{1});
    }
};

pub const Directions = struct {
    routes: []const DirectionsRoute = &.{},

    pub const Schema = directions_schema.Directions;
    comptime {
        mirror.check(@This(), &.{1});
    }
};
