// Ported from proto/descriptors/trip.proto, common.proto, sign.proto and incidents.proto (Valhalla 3.9.3).
//! Values borrowed from the request arena for trip construction and narration.

const std = @import("std");
const io = @import("../infra/io.zig");
const mirror = @import("model_schema.zig");
const trip_schema = @import("proto/trip.zig");
const common_schema = @import("proto/common.zig");
const sign_schema = @import("proto/sign.zig");
const incidents_schema = @import("proto/incidents.zig");

/// Write a leg for diagnostics without allocating a second model.
pub fn dump(leg: *const TripLeg, writer: *io.Writer) io.Writer.Error!void {
    try std.json.Stringify.value(leg.*, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
}

comptime {
    mirror.checkCoverage(@This(), trip_schema);
    mirror.checkCoverage(@This(), common_schema);
    mirror.checkCoverage(@This(), sign_schema);
}

pub const Traversability = trip_schema.TripLeg_Traversability;
pub const Use = trip_schema.TripLeg_Use;
pub const Surface = trip_schema.TripLeg_Surface;
pub const CycleLane = trip_schema.TripLeg_CycleLane;
pub const SacScale = trip_schema.TripLeg_SacScale;
pub const Sidewalk = trip_schema.TripLeg_Sidewalk;
pub const HovType = trip_schema.TripLeg_HovType;
pub const SpeedType = trip_schema.TripLeg_SpeedType;
pub const DayDowType = trip_schema.TripLeg_TimeDomain_DayDowType;
pub const NodeType = trip_schema.TripLeg_Node_Type;
pub const MatchType = trip_schema.TripRoute_MatchedPoint_MatchType;

pub const TripLeg = struct {
    osm_changeset: u64 = 0,
    trip_id: u64 = 0,
    leg_id: u32 = 0,
    leg_count: u32 = 0,
    location: []const Location = &.{},
    node: []const Node = &.{},
    admin: []const Admin = &.{},
    shape: []const u8 = "",
    bbox: ?BoundingBox = null,
    shape_attributes: ?ShapeAttributes = null,
    incidents: []const Incident = &.{},
    algorithms: []const []const u8 = &.{},
    closures: []const Closure = &.{},
    summary: ?Summary = null,
    level_changes: []const LevelChange = &.{},

    pub const Schema = trip_schema.TripLeg;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 });
    }
};

pub const LaneConnectivity = struct {
    from_way_id: u64 = 0,
    from_lanes: []const u8 = "",
    to_lanes: []const u8 = "",

    pub const Schema = trip_schema.TripLeg_LaneConnectivity;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3 });
    }
};

pub const TrafficSegment = struct {
    segment_id: u64 = 0,
    begin_percent: f32 = 0,
    end_percent: f32 = 0,
    starts_segment: bool = false,
    ends_segment: bool = false,

    pub const Schema = trip_schema.TripLeg_TrafficSegment;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5 });
    }
};

pub const Speeds = struct {
    predicted_flow: f32 = 0,
    constrained_flow: f32 = 0,
    free_flow: f32 = 0,
    current_flow: f32 = 0,
    no_flow: f32 = 0,

    pub const Schema = trip_schema.TripLeg_Speeds;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5 });
    }
};

pub const Restriction = struct {
    type: u32 = 0,

    pub const Schema = trip_schema.TripLeg_Restriction;
    comptime {
        mirror.check(@This(), &.{1});
    }
};

pub const TimeDomain = struct {
    day_dow_type: DayDowType = .kDayOfMonth,
    dow_mask: u32 = 0,
    begin_hrs: u32 = 0,
    begin_mins: u32 = 0,
    begin_month: u32 = 0,
    begin_day_dow: u32 = 0,
    begin_week: u32 = 0,
    end_hrs: u32 = 0,
    end_mins: u32 = 0,
    end_month: u32 = 0,
    end_day_dow: u32 = 0,
    end_week: u32 = 0,

    pub const Schema = trip_schema.TripLeg_TimeDomain;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 });
    }
};

pub const ConditionalSpeedLimit = struct {
    speed_limit: u32 = 0,
    condition: ?TimeDomain = null,

    pub const Schema = trip_schema.TripLeg_ConditionalSpeedLimit;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const Edge = struct {
    name: []const StreetName = &.{},
    length_km: f32 = 0,
    speed: f32 = 0,
    road_class: RoadClass = .kMotorway,
    begin_heading: u32 = 0,
    end_heading: u32 = 0,
    begin_shape_index: u32 = 0,
    end_shape_index: u32 = 0,
    traversability: Traversability = .kNone,
    use: Use = .kRoadUse,
    toll: bool = false,
    unpaved: bool = false,
    tunnel: bool = false,
    bridge: bool = false,
    roundabout: bool = false,
    internal_intersection: bool = false,
    drive_on_left: bool = false,
    surface: Surface = .kPavedSmooth,
    sign: ?Sign = null,
    travel_mode: TravelMode = .kDrive,
    vehicle_type: VehicleType = .kCar,
    pedestrian_type: PedestrianType = .kFoot,
    bicycle_type: BicycleType = .kRoad,
    transit_type: TransitType = .kTram,
    transit_route_info: ?TransitRouteInfo = null,
    id: u64 = 0,
    way_id: u64 = 0,
    weighted_grade: f32 = 0,
    max_upward_grade: i32 = 0,
    max_downward_grade: i32 = 0,
    lane_count: u32 = 0,
    cycle_lane: CycleLane = .kNoCycleLane,
    bicycle_network: bool = false,
    sidewalk: Sidewalk = .kNoSidewalk,
    density: u32 = 0,
    speed_limit: u32 = 0,
    truck_speed: f32 = 0,
    truck_route: bool = false,
    lane_connectivity: []const LaneConnectivity = &.{},
    mean_elevation: i32 = 0,
    traffic_segment: []const TrafficSegment = &.{},
    // Odin marks the arena-owned lane records as valid or active.
    turn_lanes: []TurnLane = &.{},
    has_time_restrictions: bool = false,
    default_speed: f32 = 0,
    restriction: ?Restriction = null,
    destination_only: bool = false,
    is_urban: bool = false,
    tagged_value: []const TaggedValue = &.{},
    source_along_edge: f32 = 0,
    target_along_edge: f32 = 0,
    sac_scale: SacScale = .kNoSacScale,
    shoulder: bool = false,
    indoor: bool = false,
    landmarks: []const RouteLandmark = &.{},
    tunnel_name: []const StreetName = &.{},
    elevation_sampling_interval: f32 = 0,
    elevation: []const f32 = &.{},
    country_crossing: bool = false,
    forward: bool = false,
    conditional_speed_limits: []const ConditionalSpeedLimit = &.{},
    levels: []const Level = &.{},
    level_precision: u32 = 0,
    speeds_faded: ?Speeds = null,
    speeds_non_faded: ?Speeds = null,
    speed_type: SpeedType = .kTagged,
    traffic_signal: bool = false,
    hov_type: HovType = .kHOV2,
    curvature: u32 = 0,
    begin_osm_node_id: ?u64 = null,
    end_osm_node_id: ?u64 = null,

    pub const Schema = trip_schema.TripLeg_Edge;
    comptime {
        mirror.check(@This(), &.{
            1,  2,  3,  4,  5,  6,  7,  8,  9,  10,
            11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
            21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
            31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
            41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
            51, 52, 53, 54, 55, 56, 57, 58, 59, 60,
            61, 62, 63, 64, 65, 66, 67, 68, 70, 71,
        });
    }
};

pub const Level = struct {
    start: f32 = 0,
    end: f32 = 0,

    pub const Schema = trip_schema.TripLeg_Edge_Level;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const IntersectingEdge = struct {
    begin_heading: u32 = 0,
    prev_name_consistency: bool = false,
    curr_name_consistency: bool = false,
    driveability: Traversability = .kNone,
    cyclability: Traversability = .kNone,
    walkability: Traversability = .kNone,
    use: Use = .kRoadUse,
    road_class: RoadClass = .kMotorway,
    lane_count: u32 = 0,
    sign: ?Sign = null,
    name: []const StreetName = &.{},

    pub const Schema = trip_schema.TripLeg_IntersectingEdge;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 21 });
    }
};

pub const Cost = struct {
    seconds: f64 = 0,
    cost: f64 = 0,

    pub const Schema = trip_schema.TripLeg_Cost;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const PathCost = struct {
    elapsed_cost: ?Cost = null,
    transition_cost: ?Cost = null,

    pub const Schema = trip_schema.TripLeg_PathCost;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const Node = struct {
    edge: ?Edge = null,
    intersecting_edge: []const IntersectingEdge = &.{},
    admin_index: u32 = 0,
    type: NodeType = .kStreetIntersection,
    fork: bool = false,
    transit_platform_info: ?TransitPlatformInfo = null,
    transit_station_info: ?TransitStationInfo = null,
    transit_egress_info: ?TransitEgressInfo = null,
    time_zone: []const u8 = "",
    cost: ?PathCost = null,
    recosts: []const PathCost = &.{},
    bss_info: ?BikeShareStationInfo = null,
    traffic_signal: bool = false,
    stop_impact: ?u32 = null,

    pub const Schema = trip_schema.TripLeg_Node;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 14, 21, 22 });
    }
};

pub const Admin = struct {
    country_code: []const u8 = "",
    country_text: []const u8 = "",
    state_code: []const u8 = "",
    state_text: []const u8 = "",

    pub const Schema = trip_schema.TripLeg_Admin;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4 });
    }
};

pub const ShapeAttributes = struct {
    time: []const u32 = &.{},
    length: []const u32 = &.{},
    speed: []const u32 = &.{},
    speed_limit: []const u32 = &.{},
    congestion: []const u32 = &.{},

    pub const Schema = trip_schema.TripLeg_ShapeAttributes;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 5, 6 });
    }
};

pub const Incident = struct {
    metadata: ?IncidentMetadata = null,
    begin_shape_index: u32 = 0,
    end_shape_index: u32 = 0,

    pub const Schema = trip_schema.TripLeg_Incident;
    comptime {
        mirror.check(@This(), &.{ 1, 3, 4 });
    }
};

pub const Closure = struct {
    begin_shape_index: ?u32 = null,
    end_shape_index: ?u32 = null,

    pub const Schema = trip_schema.TripLeg_Closure;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const TripRoute = struct {
    legs: []const TripLeg = &.{},
    matched_points: []const MatchedPoint = &.{},
    confidence_score: f32 = 0,
    raw_score: f32 = 0,
    is_best: bool = false,

    pub const Schema = trip_schema.TripRoute;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5 });
    }
};

pub const MatchedPoint = struct {
    type: MatchType = .kUnmatched,
    edge_index: ?u32 = null,
    begins_discontinuity: bool = false,
    ends_discontinuity: bool = false,
    distance_along_edge: ?f64 = null,
    distance_from_trace_point: ?f64 = null,
    latlng: ?LatLng = null,

    pub const Schema = trip_schema.TripRoute_MatchedPoint;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7 });
    }
};

pub const Trip = struct {
    routes: []const TripRoute = &.{},

    pub const Schema = trip_schema.Trip;
    comptime {
        mirror.check(@This(), &.{1});
    }
};

pub const LandmarkType = common_schema.RouteLandmark_Type;
pub const LocationType = common_schema.Location_Type;
pub const PreferredSide = common_schema.Location_PreferredSide;
pub const SideOfStreet = common_schema.Location_SideOfStreet;
pub const TransitPlatformType = common_schema.TransitPlatformInfo_Type;
pub const Alphabet = common_schema.Pronunciation_Alphabet;
pub const LanguageTag = common_schema.LanguageTag;
pub const TurnLaneState = common_schema.TurnLane_State;
pub const RoadClass = common_schema.RoadClass;
pub const TaggedValueType = common_schema.TaggedValue_Type;
pub const TravelMode = common_schema.TravelMode;
pub const VehicleType = common_schema.VehicleType;
pub const PedestrianType = common_schema.PedestrianType;
pub const BicycleType = common_schema.BicycleType;
pub const TransitType = common_schema.TransitType;

pub const LatLng = struct {
    lat: ?f64 = null,
    lng: ?f64 = null,

    pub const Schema = common_schema.LatLng;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const RouteLandmark = struct {
    name: []const u8 = "",
    type: LandmarkType = .kUnused,
    lat_lng: ?LatLng = null,
    distance: f64 = 0,
    right: bool = false,

    pub const Schema = common_schema.RouteLandmark;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5 });
    }
};

pub const BoundingBox = struct {
    min_ll: ?LatLng = null,
    max_ll: ?LatLng = null,

    pub const Schema = common_schema.BoundingBox;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const SearchFilter = struct {
    min_road_class: ?RoadClass = null,
    max_road_class: ?RoadClass = null,
    exclude_tunnel: bool = false,
    exclude_bridge: bool = false,
    exclude_ramp: bool = false,
    exclude_closures: ?bool = null,
    exclude_toll: bool = false,
    exclude_ferry: bool = false,
    level: ?f32 = null,
    exclude_steps: ?bool = null,
    exclude_restricted: bool = false,

    pub const Schema = common_schema.SearchFilter;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 });
    }
};

pub const PathEdge = struct {
    graph_id: u64 = 0,
    percent_along: f64 = 0,
    ll: ?LatLng = null,
    side_of_street: SideOfStreet = .kNone,
    distance: f64 = 0,
    begin_node: bool = false,
    end_node: bool = false,
    names: []const []const u8 = &.{},
    outbound_reach: i32 = 0,
    inbound_reach: i32 = 0,
    heading: f32 = 0,
    bounding_circle: ?BoundingCircle = null,

    pub const Schema = common_schema.PathEdge;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 7, 8, 10, 11, 12, 13, 14 });
    }
};

pub const BoundingCircle = struct {
    radius: u32 = 0,
    latlng: ?LatLng = null,

    pub const Schema = common_schema.PathEdge_BoundingCircle;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const Correlation = struct {
    edges: []const PathEdge = &.{},
    filtered_edges: []const PathEdge = &.{},
    original_index: u32 = 0,
    projected_ll: ?LatLng = null,
    leg_shape_index: u32 = 0,
    distance_from_leg_origin: f64 = 0,
    route_index: u32 = 0,
    waypoint_index: u32 = 0,

    pub const Schema = common_schema.Correlation;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    }
};

pub const Location = struct {
    ll: ?LatLng = null,
    type: LocationType = .kBreak,
    heading: ?u32 = null,
    name: []const u8 = "",
    street: []const u8 = "",
    date_time: []const u8 = "",
    side_of_street: SideOfStreet = .kNone,
    heading_tolerance: ?u32 = null,
    node_snap_tolerance: ?u32 = null,
    minimum_reachability: ?u32 = null,
    radius: ?u32 = null,
    accuracy: ?u32 = null,
    time: ?f64 = null,
    skip_ranking_candidates: bool = false,
    preferred_side: PreferredSide = .either,
    display_ll: ?LatLng = null,
    search_cutoff: ?u32 = null,
    street_side_tolerance: ?u32 = null,
    search_filter: ?SearchFilter = null,
    street_side_max_distance: ?u32 = null,
    preferred_layer: ?i32 = null,
    waiting_secs: f32 = 0,
    street_side_cutoff: ?RoadClass = null,
    minimum_inbound_reachability: ?u32 = null,
    minimum_outbound_reachability: ?u32 = null,
    correlation: ?Correlation = null,
    time_zone_offset: []const u8 = "",
    time_zone_name: []const u8 = "",
    transit_available: bool = false,

    pub const Schema = common_schema.Location;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 12, 13, 14, 15, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 90, 91, 92, 93 });
    }
};

pub const TransitEgressInfo = struct {
    onestop_id: []const u8 = "",
    name: []const u8 = "",
    ll: ?LatLng = null,

    pub const Schema = common_schema.TransitEgressInfo;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3 });
    }
};

pub const TransitStationInfo = struct {
    onestop_id: []const u8 = "",
    name: []const u8 = "",
    ll: ?LatLng = null,

    pub const Schema = common_schema.TransitStationInfo;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3 });
    }
};

pub const BikeShareStationInfo = struct {
    name: []const u8 = "",
    ref: []const u8 = "",
    capacity: u32 = 0,
    network: []const u8 = "",
    operator: []const u8 = "",
    rent_cost: f32 = 0,
    return_cost: f32 = 0,

    pub const Schema = common_schema.BikeShareStationInfo;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7 });
    }
};

pub const TransitPlatformInfo = struct {
    type: TransitPlatformType = .kStop,
    onestop_id: []const u8 = "",
    name: []const u8 = "",
    arrival_date_time: []const u8 = "",
    departure_date_time: []const u8 = "",
    assumed_schedule: bool = false,
    ll: ?LatLng = null,
    station_onestop_id: []const u8 = "",
    station_name: []const u8 = "",

    pub const Schema = common_schema.TransitPlatformInfo;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    }
};

pub const TransitRouteInfo = struct {
    onestop_id: []const u8 = "",
    block_id: u32 = 0,
    trip_id: u32 = 0,
    short_name: []const u8 = "",
    long_name: []const u8 = "",
    headsign: []const u8 = "",
    color: u32 = 0,
    text_color: u32 = 0,
    description: []const u8 = "",
    operator_onestop_id: []const u8 = "",
    operator_name: []const u8 = "",
    operator_url: []const u8 = "",
    transit_stops: []const TransitPlatformInfo = &.{},

    pub const Schema = common_schema.TransitRouteInfo;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 });
    }
};

pub const Pronunciation = struct {
    alphabet: Alphabet = .kNone,
    value: []const u8 = "",

    pub const Schema = common_schema.Pronunciation;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const StreetName = struct {
    value: []const u8 = "",
    is_route_number: bool = false,
    pronunciation: ?Pronunciation = null,
    language_tag: LanguageTag = .kUnspecified,

    pub const Schema = common_schema.StreetName;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4 });
    }
};

pub const TurnLane = struct {
    directions_mask: u32 = 0,
    state: TurnLaneState = .kInvalid,
    active_direction: u32 = 0,

    pub const Schema = common_schema.TurnLane;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3 });
    }
};

pub const TaggedValue = struct {
    value: []const u8 = "",
    type: TaggedValueType = .kNone,

    pub const Schema = common_schema.TaggedValue;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

pub const Summary = struct {
    length: f32 = 0,
    time: f64 = 0,
    bbox: ?BoundingBox = null,
    has_time_restrictions: bool = false,
    has_toll: bool = false,
    has_ferry: bool = false,
    has_highway: bool = false,

    pub const Schema = common_schema.Summary;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7 });
    }
};

pub const LevelChange = struct {
    shape_index: u32 = 0,
    level: f32 = 0,
    precision: u32 = 0,

    pub const Schema = common_schema.LevelChange;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3 });
    }
};

pub const SignElement = struct {
    text: []const u8 = "",
    is_route_number: bool = false,
    consecutive_count: u32 = 0,
    pronunciation: ?Pronunciation = null,
    language_tag: LanguageTag = .kUnspecified,

    pub const Schema = sign_schema.TripSignElement;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5 });
    }
};

pub const Sign = struct {
    exit_numbers: []const SignElement = &.{},
    exit_onto_streets: []const SignElement = &.{},
    exit_toward_locations: []const SignElement = &.{},
    exit_names: []const SignElement = &.{},
    guide_onto_streets: []const SignElement = &.{},
    guide_toward_locations: []const SignElement = &.{},
    junction_names: []const SignElement = &.{},
    guidance_view_junctions: []const SignElement = &.{},
    guidance_view_signboards: []const SignElement = &.{},

    pub const Schema = sign_schema.TripSign;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    }
};

pub const IncidentType = incidents_schema.IncidentsTile_Metadata_Type;
pub const IncidentImpact = incidents_schema.IncidentsTile_Metadata_Impact;

pub const IncidentMetadata = struct {
    type: IncidentType = .ACCIDENT,
    alertc_codes: []const u32 = &.{},
    description: []const u8 = "",
    sub_type: []const u8 = "",
    sub_type_description: []const u8 = "",
    start_time: u64 = 0,
    end_time: u64 = 0,
    impact: IncidentImpact = .UNKNOWN,
    road_closed: bool = false,
    congestion: ?IncidentCongestion = null,
    lanes_blocked: []const []const u8 = &.{},
    creation_time: u64 = 0,
    long_description: []const u8 = "",
    clear_lanes: []const u8 = "",
    num_lanes_blocked: u64 = 0,
    length: u32 = 0,
    display_ll: ?IncidentPosition = null,
    id: u64 = 0,
    iso_3166_1_alpha2: []const u8 = "",
    iso_3166_1_alpha3: []const u8 = "",

    pub const Schema = incidents_schema.IncidentsTile_Metadata;
    comptime {
        mirror.check(@This(), &.{ 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 128, 129, 130 });
    }
};

pub const IncidentCongestion = struct {
    value: u32 = 0,

    pub const Schema = incidents_schema.IncidentsTile_Metadata_Congestion;
    comptime {
        mirror.check(@This(), &.{1});
    }
};

pub const IncidentPosition = struct {
    lat: ?f64 = null,
    lng: ?f64 = null,

    pub const Schema = incidents_schema.IncidentsTile_Metadata_LatLng;
    comptime {
        mirror.check(@This(), &.{ 1, 2 });
    }
};

test "two-edge trip leg round-trips through the debug dump" {
    var storage: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer storage.deinit();
    const a = storage.allocator();
    const nodes = try a.alloc(Node, 3);
    @memcpy(nodes, &[_]Node{
        .{
            .edge = .{
                .id = 313,
                .name = &.{.{ .value = "Canal Street" }},
                .length_km = 0.25,
                .speed = 30,
                .road_class = .kResidential,
                .traversability = .kBoth,
                .end_shape_index = 1,
                .sign = .{ .guide_onto_streets = &.{.{ .text = "Canal Street" }} },
                .begin_osm_node_id = 0,
            },
            .stop_impact = 0,
        },
        .{
            .edge = .{
                .id = 712,
                .name = &.{.{ .value = "River Road" }},
                .length_km = 0.75,
                .speed = 45,
                .begin_shape_index = 1,
                .end_shape_index = 2,
                .use = @fromBackingInt(123),
                .tagged_value = &.{.{ .value = "\x00\xff" }},
            },
            .intersecting_edge = &.{.{ .begin_heading = 92, .driveability = .kForward }},
            .cost = .{ .elapsed_cost = .{ .seconds = 30, .cost = 35 } },
        },
        .{ .cost = .{ .elapsed_cost = .{ .seconds = 90, .cost = 102 } } },
    });
    const leg: TripLeg = .{
        .trip_id = std.math.maxInt(u64),
        .leg_count = 1,
        .node = nodes,
        .location = &.{ .{ .ll = .{ .lat = 52.1, .lng = 5.2 } }, .{ .ll = .{ .lat = 52.2, .lng = 5.3 } } },
        .admin = &.{.{ .country_code = "NL" }},
        .shape = "_p~iF~ps|U_ulLnnqC_mqNvxq",
        .shape_attributes = .{ .time = &.{ 30_000, 60_000 }, .length = &.{ 250_000, 750_000 } },
        .summary = .{ .length = 1, .time = 90 },
    };
    var output = io.Writer.Allocating.init(a);
    defer output.deinit();
    try dump(&leg, &output.writer);
    const restored = try std.json.parseFromSliceLeaky(TripLeg, a, output.written(), .{ .allocate = .alloc_always });
    try std.testing.expectEqualDeep(leg, restored);
}
