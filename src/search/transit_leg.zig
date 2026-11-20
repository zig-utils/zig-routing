// Ported from src/thor/triplegbuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const attrs = @import("../api/attributes.zig");
const model = @import("../api/trip.zig");
const multimodal = @import("multimodal.zig");
const Allocator = std.mem.Allocator;
const Ride = multimodal.Ride;
const View = graph.reader.View;
const Transit = graph.transit;
const NodeId = graph.format.NodeId;

pub const Ends = struct { from: u32, to: u32 };

pub fn stops(table: Transit.View, ride: Ride) !Ends {
    if (ride.departure.line >= table.lines.len) return error.InvalidTransitLine;
    const line = table.lines[ride.departure.line];
    if (line.origin >= table.stops.len or line.destination >= table.stops.len) return error.InvalidTransitStop;
    return .{ .from = line.origin, .to = line.destination };
}

pub fn node(table: Transit.View, id: u32) !NodeId {
    if (id >= table.stops.len or table.stops[id].place.graph_node == Transit.no_id) return error.InvalidTransitStop;
    return @fromBackingInt(table.stops[id].place.graph_node);
}

pub fn routeInfo(table: Transit.View, ride: Ride, controller: attrs.Controller) !model.TransitRouteInfo {
    const departure = ride.departure;
    if (departure.route >= table.routes.len) return error.InvalidTransitRoute;
    if (departure.trip == Transit.no_id) return error.InvalidTransitTrip;
    const route = table.routes[departure.route];
    var result: model.TransitRouteInfo = .{};
    if (controller.has(.@"edge.transit_route_info.onestop_id")) result.onestop_id = try text(table, route.one_stop_id);
    if (controller.has(.@"edge.transit_route_info.block_id") and departure.block != Transit.no_id) result.block_id = departure.block + 1;
    if (controller.has(.@"edge.transit_route_info.trip_id")) result.trip_id = departure.trip + 1;
    if (controller.has(.@"edge.transit_route_info.short_name")) result.short_name = try text(table, route.short_name);
    if (controller.has(.@"edge.transit_route_info.long_name")) result.long_name = try text(table, route.long_name);
    if (controller.has(.@"edge.transit_route_info.headsign")) result.headsign = try text(table, departure.headsign);
    if (controller.has(.@"edge.transit_route_info.color")) result.color = try color(table, route.color);
    if (controller.has(.@"edge.transit_route_info.text_color")) result.text_color = try color(table, route.text_color);
    if (controller.has(.@"edge.transit_route_info.description")) result.description = try text(table, route.description);
    if (controller.has(.@"edge.transit_route_info.operator_onestop_id")) result.operator_onestop_id = try text(table, route.operator_one_stop_id);
    if (controller.has(.@"edge.transit_route_info.operator_name")) result.operator_name = try text(table, route.operator_name);
    if (controller.has(.@"edge.transit_route_info.operator_url")) result.operator_url = try text(table, route.operator_website);
    return result;
}

pub fn platformInfo(a: Allocator, view: *const View, id: u32, arrival: ?Ride, departure: ?Ride, controller: attrs.Controller) !model.TransitPlatformInfo {
    const table = view.transit_index orelse return error.MissingTransitSection;
    const graph_node = try node(table, id);
    const stop = table.stops[id];
    var result: model.TransitPlatformInfo = .{};
    if (controller.has(.@"node.transit_platform_info.type")) {
        if (departure orelse arrival) |ride| {
            const route = ride.departure.route;
            if (route >= table.routes.len) return error.InvalidTransitRoute;
            const use = @import("../costing/transit.zig").vehicleUse(table.routes[route].flags.vehicle);
            result.type = if (use == .rail) .kStation else .kStop;
        }
    }
    if (controller.has(.@"node.transit_platform_info.onestop_id")) result.onestop_id = try text(table, stop.place.one_stop_id);
    if (controller.has(.@"node.transit_platform_info.name")) result.name = try text(table, stop.place.name);
    if (controller.has(.@"node.transit_platform_info.lat_lon")) {
        const point = stop.place.coordinate.toTilePoint();
        result.ll = .{ .lat = point.lat, .lng = point.lng };
    }
    if (stop.station != Transit.no_id) {
        if (stop.station >= table.stations.len) return error.InvalidTransitStation;
        const station = table.stations[stop.station].place;
        if (controller.has(.@"node.transit_platform_info.station_onestop_id")) result.station_onestop_id = try text(table, station.one_stop_id);
        if (controller.has(.@"node.transit_platform_info.station_name")) result.station_name = try text(table, station.name);
    }
    const zone = try view.nodeTimezone(graph_node);
    const rules = if (view.tz_rules) |*present| present else null;
    if (controller.has(.@"node.transit_platform_info.arrival_date_time")) {
        if (arrival) |ride| result.arrival_date_time = try dateTime(a, rules, zone, ride.ready_time, ride.arrival_time);
    }
    if (controller.has(.@"node.transit_platform_info.departure_date_time")) {
        if (departure) |ride| result.departure_date_time = try dateTime(a, rules, zone, ride.ready_time, ride.departure_time);
    }
    if (controller.has(.@"node.transit_platform_info.assumed_schedule")) {
        if (departure orelse arrival) |ride| {
            const schedule = ride.departure.schedule;
            if (schedule >= table.schedules.len) return error.InvalidTransitSchedule;
            const day = @as(i64, ride.service_day) - table.metadata.start_day;
            result.assumed_schedule = day < 0 or day >= table.schedules[schedule].day_count;
        }
    }
    return result;
}

fn dateTime(a: Allocator, rules: ?*const graph.timezone.Rules, zone: graph.timezone.Id, ready: i64, instant: i64) ![]const u8 {
    const offset = if (rules) |present| try present.offsetAt(zone, instant) else null;
    const shift = if (offset) |value| value.seconds else 0;
    // Valhalla formats the ready time at minute precision and rounds the
    // duration up to the next full minute before displaying the event.
    const delta = instant - ready;
    const rounded = ready - @mod(ready + shift, 60) + delta + @mod(-delta, 60);
    return graph.datetime.formatIso(try a.alloc(u8, 22), rounded, shift, true);
}

fn text(table: Transit.View, id: Transit.Text) ![]const u8 {
    return (try table.text(id)) orelse "";
}

fn color(table: Transit.View, id: Transit.Text) !u32 {
    const value = try text(table, id);
    return if (value.len == 0) 0 else std.fmt.parseInt(u24, value, 16) catch 0;
}
