//! Tables and field types for the GTFS Schedule feed.
const std = @import("std");

pub const Text = enum(u32) { _ };
pub const Namespace = enum { agency, stop, route, trip, service, shape, pathway, level };

pub fn Id(comptime tag: Namespace) type {
    return struct {
        pub const namespace = tag;
        value: u32,
    };
}

pub const Time = struct { seconds: u32 };
pub const Date = struct { yyyymmdd: u32 };

pub const LocationType = enum(u8) { stop, station, entrance, node, boarding_area };
pub const Availability = enum(u8) { unknown, available, unavailable };
pub const Direction = enum(u8) { outbound, inbound };
pub const RouteType = enum(u8) {
    tram = 0,
    subway = 1,
    rail = 2,
    bus = 3,
    ferry = 4,
    cable_tram = 5,
    aerial_lift = 6,
    funicular = 7,
    trolleybus = 11,
    monorail = 12,
};
pub const Pickup = enum(u8) { regular, unavailable, call_agency, coordinate_with_driver };
pub const Exception = enum(u8) { added = 1, removed = 2 };
pub const TransferType = enum(u8) { recommended, timed, minimum_time, forbidden, in_seat, forced_alight };
pub const PathwayMode = enum(u8) { walkway = 1, stairs, moving_walkway, escalator, elevator, fare_gate, exit_gate };

pub const Agency = struct {
    agency_id: ?Id(.agency) = null,
    agency_name: Text,
    agency_url: Text,
    agency_timezone: Text,
    agency_lang: ?Text = null,
    agency_phone: ?Text = null,
    agency_fare_url: ?Text = null,
    agency_email: ?Text = null,
};

pub const Stop = struct {
    stop_id: Id(.stop),
    stop_code: ?Text = null,
    stop_name: ?Text = null,
    tts_stop_name: ?Text = null,
    stop_desc: ?Text = null,
    stop_lat: ?f64 = null,
    stop_lon: ?f64 = null,
    zone_id: ?Text = null,
    stop_url: ?Text = null,
    location_type: ?LocationType = null,
    parent_station: ?Id(.stop) = null,
    stop_timezone: ?Text = null,
    wheelchair_boarding: ?Availability = null,
    level_id: ?Id(.level) = null,
    platform_code: ?Text = null,
};

pub const Route = struct {
    route_id: Id(.route),
    agency_id: ?Id(.agency) = null,
    route_short_name: ?Text = null,
    route_long_name: ?Text = null,
    route_desc: ?Text = null,
    route_type: RouteType,
    route_url: ?Text = null,
    route_color: ?Text = null,
    route_text_color: ?Text = null,
    route_sort_order: ?u32 = null,
    continuous_pickup: ?Pickup = null,
    continuous_drop_off: ?Pickup = null,
    network_id: ?Text = null,
};

pub const Trip = struct {
    trip_id: Id(.trip),
    route_id: Id(.route),
    service_id: Id(.service),
    trip_headsign: ?Text = null,
    trip_short_name: ?Text = null,
    direction_id: ?Direction = null,
    block_id: ?Text = null,
    shape_id: ?Id(.shape) = null,
    wheelchair_accessible: ?Availability = null,
    bikes_allowed: ?Availability = null,
};

pub const StopTime = struct {
    trip_id: Id(.trip),
    arrival_time: ?Time = null,
    departure_time: ?Time = null,
    stop_id: ?Id(.stop) = null,
    stop_sequence: u32,
    stop_headsign: ?Text = null,
    pickup_type: ?Pickup = null,
    drop_off_type: ?Pickup = null,
    continuous_pickup: ?Pickup = null,
    continuous_drop_off: ?Pickup = null,
    shape_dist_traveled: ?f64 = null,
    timepoint: ?bool = null,
    location_group_id: ?Text = null,
    location_id: ?Text = null,
    start_pickup_drop_off_window: ?Time = null,
    end_pickup_drop_off_window: ?Time = null,
    pickup_booking_rule_id: ?Text = null,
    drop_off_booking_rule_id: ?Text = null,
};

pub const Calendar = struct {
    service_id: Id(.service),
    monday: bool,
    tuesday: bool,
    wednesday: bool,
    thursday: bool,
    friday: bool,
    saturday: bool,
    sunday: bool,
    start_date: Date,
    end_date: Date,
};

pub const CalendarDate = struct {
    service_id: Id(.service),
    date: Date,
    exception_type: Exception,
};

pub const Shape = struct {
    shape_id: Id(.shape),
    shape_pt_lat: f64,
    shape_pt_lon: f64,
    shape_pt_sequence: u32,
    shape_dist_traveled: ?f64 = null,
};

pub const Frequency = struct {
    trip_id: Id(.trip),
    start_time: Time,
    end_time: Time,
    headway_secs: u32,
    exact_times: ?bool = null,
};

pub const Transfer = struct {
    from_stop_id: ?Id(.stop) = null,
    to_stop_id: ?Id(.stop) = null,
    from_route_id: ?Id(.route) = null,
    to_route_id: ?Id(.route) = null,
    from_trip_id: ?Id(.trip) = null,
    to_trip_id: ?Id(.trip) = null,
    transfer_type: TransferType,
    min_transfer_time: ?u32 = null,
};

pub const FeedInfo = struct {
    feed_publisher_name: Text,
    feed_publisher_url: Text,
    feed_lang: Text,
    default_lang: ?Text = null,
    feed_start_date: ?Date = null,
    feed_end_date: ?Date = null,
    feed_version: ?Text = null,
    feed_contact_email: ?Text = null,
    feed_contact_url: ?Text = null,
};

pub const Pathway = struct {
    pathway_id: Id(.pathway),
    from_stop_id: Id(.stop),
    to_stop_id: Id(.stop),
    pathway_mode: PathwayMode,
    is_bidirectional: bool,
    length: ?f64 = null,
    traversal_time: ?u32 = null,
    stair_count: ?i32 = null,
    max_slope: ?f64 = null,
    min_width: ?f64 = null,
    signposted_as: ?Text = null,
    reversed_signposted_as: ?Text = null,
};

pub const Level = struct {
    level_id: Id(.level),
    level_index: f64,
    level_name: ?Text = null,
};

pub const Table = enum {
    agency,
    stops,
    routes,
    trips,
    stop_times,
    calendar,
    calendar_dates,
    shapes,
    frequencies,
    transfers,
    feed_info,
    pathways,
    levels,

    pub fn rowType(comptime self: Table) type {
        return switch (self) {
            .agency => Agency,
            .stops => Stop,
            .routes => Route,
            .trips => Trip,
            .stop_times => StopTime,
            .calendar => Calendar,
            .calendar_dates => CalendarDate,
            .shapes => Shape,
            .frequencies => Frequency,
            .transfers => Transfer,
            .feed_info => FeedInfo,
            .pathways => Pathway,
            .levels => Level,
        };
    }

    pub fn name(comptime self: Table) []const u8 {
        return @tagName(self) ++ ".txt";
    }
};

const Pool = struct {
    by_text: std.StringHashMapUnmanaged(Text) = .empty,
    values: std.ArrayList([]const u8) = .empty,
};

pub const IdIndex = struct {
    by_text: std.StringHashMapUnmanaged(u32) = .empty,
    names: std.ArrayList(Text) = .empty,
};

pub const Feed = struct {
    arena: std.heap.ArenaAllocator,
    pool: Pool = .{},
    ids: std.EnumArray(Namespace, IdIndex) = .initFill(.{}),
    agency: []const Agency = &.{},
    stops: []const Stop = &.{},
    routes: []const Route = &.{},
    trips: []const Trip = &.{},
    stop_times: std.MultiArrayList(StopTime) = .empty,
    calendar: []const Calendar = &.{},
    calendar_dates: []const CalendarDate = &.{},
    shapes: []const Shape = &.{},
    frequencies: []const Frequency = &.{},
    transfers: []const Transfer = &.{},
    feed_info: []const FeedInfo = &.{},
    pathways: []const Pathway = &.{},
    levels: []const Level = &.{},

    pub fn init(backing: std.mem.Allocator) Feed {
        return .{ .arena = .init(backing) };
    }

    pub fn deinit(self: *Feed) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Feed, table: Table) usize {
        return switch (table) {
            inline else => |kind| @field(self, @tagName(kind)).len,
        };
    }

    pub fn text(self: *const Feed, id: Text) []const u8 {
        return self.pool.values.items[@backingInt(id)];
    }

    pub fn idName(self: *const Feed, id: anytype) []const u8 {
        return self.text(self.ids.getPtrConst(@TypeOf(id).namespace).names.items[id.value]);
    }

    pub fn findId(self: *const Feed, comptime namespace: Namespace, text_value: []const u8) ?Id(namespace) {
        return .{ .value = self.ids.getPtrConst(namespace).by_text.get(text_value) orelse return null };
    }

    pub fn internText(self: *Feed, value: []const u8) !Text {
        const a = self.arena.allocator();
        if (self.pool.by_text.get(value)) |id| return id;
        const id: Text = @fromBackingInt(std.math.cast(u32, self.pool.values.items.len) orelse return error.TooManyStrings);
        const copy = try a.dupe(u8, value);
        try self.pool.by_text.put(a, copy, id);
        try self.pool.values.append(a, copy);
        return id;
    }

    pub fn internId(self: *Feed, comptime namespace: Namespace, value: []const u8) !Id(namespace) {
        if (self.findId(namespace, value)) |id| return id;
        const a = self.arena.allocator();
        const text_id = try self.internText(value);
        const index = self.ids.getPtr(namespace);
        const id = std.math.cast(u32, index.names.items.len) orelse return error.TooManyIds;
        try index.names.append(a, text_id);
        try index.by_text.put(a, self.text(text_id), id);
        return .{ .value = id };
    }
};
