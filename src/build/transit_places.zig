// Ported from src/mjolnir/ingest_transit.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/point.zig");
const transit = @import("../graph/transit.zig");
const io = @import("../infra/io.zig");
const gtfs = @import("gtfs/model.zig");
const names = @import("tags/names.zig");
const timetable = @import("transit_timetable.zig");
const Allocator = std.mem.Allocator;

pub const Location = union(enum) {
    stop: u32,
    station: u32,
    egress: u32,
    passage: u32,
};

pub const FeedLocations = struct {
    /// Indexed by the feed's stop ID namespace.
    locations: []const ?Location,
    timetable_ids: timetable.FeedIds,
};

pub const Passage = struct {
    place: transit.Place,
    station: u32,
};

pub const Places = struct {
    stops: []transit.Stop,
    stations: []transit.Station,
    egresses: []transit.Egress,
    passages: []Passage,
    routes: []transit.Route,
    nodes: []const Location,
    feeds: []const FeedLocations,
    platforms_without_coordinates: u64,

    pub fn place(self: Places, location: Location) *transit.Place {
        return switch (location) {
            .stop => |id| &self.stops[id].place,
            .station => |id| &self.stations[id].place,
            .egress => |id| &self.egresses[id].place,
            .passage => |id| &self.passages[id].place,
        };
    }

    pub fn stationOf(self: Places, location: Location) u32 {
        return switch (location) {
            .stop => |id| self.stops[id].station,
            .station => |id| id,
            .egress => |id| self.egresses[id].station,
            .passage => |id| self.passages[id].station,
        };
    }
};

const Feed = struct {
    source: *const gtfs.Feed,
    index: usize,
    default_timezone: transit.Text,
    locations: []?Location,
    coordinates: []?geo.FixedLL,
    native_stops: []u32,
    local_rows: []const ?*const gtfs.Stop,

    fn parent(self: Feed, row: gtfs.Stop, expected: gtfs.LocationType) !?Location {
        const parent_id = row.parent_station orelse return null;
        if (parent_id.value >= self.local_rows.len) return error.InvalidTransitParent;
        const entry = self.local_rows[parent_id.value] orelse return error.InvalidTransitParent;
        if ((entry.location_type orelse .stop) != expected) return error.InvalidTransitParent;
        return self.locations[parent_id.value];
    }
};

const Builder = struct {
    a: Allocator,
    strings: *names.StringTable,
    deadline: io.Deadline,
    stops: std.ArrayList(transit.Stop) = .empty,
    stations: std.ArrayList(transit.Station) = .empty,
    egresses: std.ArrayList(transit.Egress) = .empty,
    passages: std.ArrayList(Passage) = .empty,
    routes: std.ArrayList(transit.Route) = .empty,
    nodes: std.ArrayList(Location) = .empty,
    platforms_without_coordinates: u64 = 0,

    fn fromFeed(self: *Builder, source: *const gtfs.Feed, index: usize, scratch: Allocator) !FeedLocations {
        const agencies = source.agency;
        if (agencies.len == 0) return error.MissingTransitAgency;
        const default_timezone = try self.text(source, agencies[0].agency_timezone);
        const count = source.ids.getPtrConst(.stop).names.items.len;
        const local_rows = try scratch.alloc(?*const gtfs.Stop, count);
        @memset(local_rows, null);
        for (source.stops) |*row| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (row.stop_id.value >= count) return error.InvalidTransitStopId;
            if (local_rows[row.stop_id.value] != null) return error.DuplicateTransitStop;
            local_rows[row.stop_id.value] = row;
        }
        const locations = try self.a.alloc(?Location, count);
        const coordinates = try self.a.alloc(?geo.FixedLL, count);
        const native_stops = try self.a.alloc(u32, count);
        @memset(locations, null);
        @memset(coordinates, null);
        @memset(native_stops, transit.no_id);
        const feed: Feed = .{
            .source = source,
            .index = index,
            .default_timezone = default_timezone,
            .locations = locations,
            .coordinates = coordinates,
            .native_stops = native_stops,
            .local_rows = local_rows,
        };
        const station_start = self.stations.items.len;
        const entrance_start = self.egresses.items.len;
        for ([_]gtfs.LocationType{ .station, .stop, .entrance, .node, .boarding_area }) |kind| {
            for (source.stops) |row| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                if ((row.location_type orelse .stop) != kind) continue;
                try self.addLocation(feed, row, kind);
            }
        }
        const has_entrance = try scratch.alloc(bool, self.stations.items.len - station_start);
        @memset(has_entrance, false);
        for (self.egresses.items[entrance_start..]) |entrance| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            has_entrance[entrance.station - station_start] = true;
        }
        for (has_entrance, station_start..) |present, station| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (present) continue;
            var entrance = self.stations.items[station].place;
            entrance.flags.generated = true;
            const location: Location = .{ .egress = try rowId(self.egresses.items.len) };
            entrance.one_stop_id = try self.generated(entrance.one_stop_id, "entrance");
            entrance.graph_node = try self.node(location);
            try self.egresses.append(self.a, .{ .place = entrance, .station = @intCast(station) });
        }
        const route_ids = try self.addRoutes(feed);
        return .{ .locations = locations, .timetable_ids = .{ .stops = native_stops, .routes = route_ids, .coordinates = coordinates } };
    }

    fn addLocation(self: *Builder, feed: Feed, row: gtfs.Stop, kind: gtfs.LocationType) !void {
        const parent = switch (kind) {
            .station => null,
            .stop, .entrance, .node => try feed.parent(row, .station),
            .boarding_area => try feed.parent(row, .stop),
        };
        const parent_place: ?transit.Place = if (parent) |location| switch (location) {
            .station => |id| self.stations.items[id].place,
            .stop => |id| self.stops.items[id].place,
            else => unreachable,
        } else null;
        const can_inherit_coordinate = kind == .node or kind == .boarding_area;
        const coordinate = coordinatesOf(row) orelse
            if (can_inherit_coordinate and parent_place != null) parent_place.?.coordinate else {
                if (kind == .stop or kind == .boarding_area) self.platforms_without_coordinates += 1;
                return;
            };
        feed.coordinates[row.stop_id.value] = coordinate;
        var place: transit.Place = .{
            .coordinate = coordinate,
            .name = try self.text(feed.source, row.stop_name),
            .one_stop_id = try self.scoped(feed, "stop", feed.source.idName(row.stop_id)),
            .timezone = if (parent_place) |ancestor| ancestor.timezone else if (row.stop_timezone) |tz| try self.text(feed.source, tz) else feed.default_timezone,
            .flags = .{
                .wheelchair_boarding = switch (row.wheelchair_boarding orelse .unknown) {
                    .available => true,
                    .unavailable => false,
                    .unknown => if (parent_place) |ancestor| ancestor.flags.wheelchair_boarding else false,
                },
            },
        };
        const location: Location = switch (kind) {
            .station => .{ .station = try rowId(self.stations.items.len) },
            .stop, .boarding_area => .{ .stop = try rowId(self.stops.items.len) },
            .entrance => .{ .egress = try rowId(self.egresses.items.len) },
            .node => .{ .passage = try rowId(self.passages.items.len) },
        };
        if (parent == null and row.parent_station != null) {
            if (kind == .stop or kind == .boarding_area) self.platforms_without_coordinates += 1;
            return;
        }
        if (parent == null and kind != .station and kind != .stop) return error.MissingTransitParent;
        place.graph_node = try self.node(location);
        switch (location) {
            .station => try self.stations.append(self.a, .{ .place = place }),
            .stop => |id| {
                const station = if (parent) |ancestor| switch (ancestor) {
                    .station => |station| station,
                    .stop => |platform| self.stops.items[platform].station,
                    else => unreachable,
                } else try self.addGeneratedStation(place);
                try self.stops.append(self.a, .{ .place = place, .station = station });
                feed.native_stops[row.stop_id.value] = id;
            },
            .egress => try self.egresses.append(self.a, .{ .place = place, .station = parent.?.station }),
            .passage => try self.passages.append(self.a, .{ .place = place, .station = parent.?.station }),
        }
        feed.locations[row.stop_id.value] = location;
    }

    fn addGeneratedStation(self: *Builder, child: transit.Place) !u32 {
        const id = try rowId(self.stations.items.len);
        var parent = child;
        parent.flags.generated = true;
        parent.one_stop_id = try self.generated(parent.one_stop_id, "station");
        parent.graph_node = try self.node(.{ .station = id });
        try self.stations.append(self.a, .{ .place = parent });
        return id;
    }

    fn node(self: *Builder, reference: Location) !u32 {
        const id = try rowId(self.nodes.items.len);
        try self.nodes.append(self.a, reference);
        return id;
    }

    fn addRoutes(self: *Builder, feed: Feed) ![]const u32 {
        const source = feed.source;
        const routes = try self.a.alloc(u32, source.ids.getPtrConst(.route).names.items.len);
        @memset(routes, transit.no_id);
        for (source.routes) |row| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (row.route_id.value >= routes.len or routes[row.route_id.value] != transit.no_id) return error.InvalidTransitRoute;
            routes[row.route_id.value] = try rowId(self.routes.items.len);
            const operator = try self.agency(source, row.agency_id);
            try self.routes.append(self.a, .{
                .one_stop_id = try self.scoped(feed, "route", source.idName(row.route_id)),
                .operator_one_stop_id = if (operator.agency_id) |id| try self.scoped(feed, "agency", source.idName(id)) else .none,
                .operator_name = try self.text(source, operator.agency_name),
                .operator_website = try self.text(source, operator.agency_url),
                .short_name = try self.text(source, row.route_short_name),
                .long_name = try self.text(source, row.route_long_name),
                .description = try self.text(source, row.route_desc),
                .color = try self.text(source, row.route_color),
                .text_color = try self.text(source, row.route_text_color),
                .flags = .{ .vehicle = @fromBackingInt(@backingInt(row.route_type)) },
            });
        }
        return routes;
    }

    fn agency(self: *const Builder, source: *const gtfs.Feed, id: ?gtfs.Id(.agency)) !gtfs.Agency {
        if (id == null and source.agency.len == 1) return source.agency[0];
        const wanted = id orelse return error.MissingTransitRouteAgency;
        for (source.agency) |entry| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (entry.agency_id) |agency_id| if (agency_id.value == wanted.value) return entry;
        }
        return error.MissingTransitRouteAgency;
    }

    fn text(self: *Builder, source: *const gtfs.Feed, value: ?gtfs.Text) !transit.Text {
        return if (value) |id| try self.intern(source.text(id)) else .none;
    }

    fn scoped(self: *Builder, feed: Feed, kind: []const u8, value: []const u8) !transit.Text {
        const text_value = try std.fmt.allocPrint(self.a, "gtfs:{d}:{s}:{s}", .{ feed.index, kind, value });
        defer self.a.free(text_value);
        return self.intern(text_value);
    }

    fn generated(self: *Builder, id: transit.Text, kind: []const u8) !transit.Text {
        const existing = self.strings.get(@fromBackingInt(@backingInt(id))) orelse return error.InvalidTransitText;
        const text_value = try std.fmt.allocPrint(self.a, "{s}:{s}", .{ kind, existing });
        defer self.a.free(text_value);
        return self.intern(text_value);
    }

    fn intern(self: *Builder, value: []const u8) !transit.Text {
        return @fromBackingInt(@backingInt(try self.strings.intern(value)));
    }
};

/// Output tables borrow the build arena. Place graph IDs and text references
/// are provisional until mapped to dense nodes and the shared bundle pool.
pub fn compile(a: Allocator, scratch: Allocator, feeds: []const gtfs.Feed, strings: *names.StringTable, deadline: io.Deadline) !Places {
    var builder: Builder = .{ .a = a, .strings = strings, .deadline = deadline };
    const locations = try a.alloc(FeedLocations, feeds.len);
    for (feeds, locations, 0..) |*feed, *slot, index| {
        if (deadline.expired()) return error.DeadlineExceeded;
        var temp: std.heap.ArenaAllocator = .init(scratch);
        defer temp.deinit();
        slot.* = try builder.fromFeed(feed, index, temp.allocator());
    }
    return .{
        .stops = builder.stops.items,
        .stations = builder.stations.items,
        .egresses = builder.egresses.items,
        .passages = builder.passages.items,
        .routes = builder.routes.items,
        .nodes = builder.nodes.items,
        .feeds = locations,
        .platforms_without_coordinates = builder.platforms_without_coordinates,
    };
}

fn coordinatesOf(row: gtfs.Stop) ?geo.FixedLL {
    const point: geo.PointLL = .{ .lat = row.stop_lat orelse return null, .lng = row.stop_lon orelse return null };
    return if (point.inRange()) point.toFixed() else null;
}

fn rowId(count: usize) !u32 {
    if (count >= transit.no_id) return error.TooManyTransitIds;
    return @intCast(count);
}

test "station children inherit timezone and standalone platforms have a generated entrance" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var feed: gtfs.Feed = .init(a);
    const station = try feed.internId(.stop, "station");
    const platform = try feed.internId(.stop, "platform");
    const entrance = try feed.internId(.stop, "entrance");
    const standalone = try feed.internId(.stop, "standalone");
    const passage = try feed.internId(.stop, "passage");
    const boarding = try feed.internId(.stop, "boarding");
    const missing = try feed.internId(.stop, "unknown-coordinate");
    const timezone = try feed.internText("America/New_York");
    feed.agency = &.{.{
        .agency_name = try feed.internText("Operator"),
        .agency_url = try feed.internText("https://example.com"),
        .agency_timezone = try feed.internText("Etc/UTC"),
    }};
    feed.stops = &.{
        .{ .stop_id = platform, .parent_station = station, .stop_lon = 1, .stop_lat = 1.0001 },
        .{ .stop_id = boarding, .parent_station = platform, .location_type = .boarding_area },
        .{ .stop_id = passage, .parent_station = station, .location_type = .node },
        .{ .stop_id = entrance, .parent_station = station, .location_type = .entrance, .stop_lon = 1, .stop_lat = 1.0002 },
        .{ .stop_id = standalone, .stop_lon = 2, .stop_lat = 2 },
        .{ .stop_id = missing },
        .{ .stop_id = station, .location_type = .station, .stop_lon = 1, .stop_lat = 1, .stop_timezone = timezone, .wheelchair_boarding = .available },
    };
    var strings: names.StringTable = .init(a);
    defer strings.deinit();
    const places = try compile(a, testing.allocator, &.{feed}, &strings, .none);
    try testing.expectEqual(3, places.stops.len);
    try testing.expectEqual(2, places.stations.len);
    try testing.expectEqual(2, places.egresses.len);
    try testing.expectEqual(1, places.passages.len);
    try testing.expectEqual(1, places.platforms_without_coordinates);
    const map = places.feeds[0].locations;
    const stop = places.stops[map[platform.value].?.stop];
    try testing.expectEqual(map[station.value].?.station, stop.station);
    try testing.expectEqual(places.stations[stop.station].place.timezone, stop.place.timezone);
    try testing.expect(stop.place.flags.wheelchair_boarding);
    try testing.expectEqualDeep(stop.place.coordinate, places.place(map[boarding.value].?).coordinate);
    try testing.expectEqual(places.stations[stop.station].place.graph_node, places.place(map[station.value].?).graph_node);
    try testing.expect(places.stations[1].place.flags.generated and places.egresses[1].place.flags.generated);
    try testing.expectEqual(1, places.egresses[1].station);
    try testing.expectEqual(null, map[missing.value]);
}
