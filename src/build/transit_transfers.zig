// Ported from valhalla/baldr/transittransfer.h (Valhalla 3.9.3).
const std = @import("std");
const transit = @import("../graph/transit.zig");
const io = @import("../infra/io.zig");
const gtfs = @import("gtfs/model.zig");
const places = @import("transit_places.zig");
const links = @import("transit_links.zig");
const Allocator = std.mem.Allocator;

pub const Transfers = struct {
    records: []const transit.Transfer,
    missing_endpoints: u64,
};

const Stops = std.ArrayList(u32);
const Key = struct {
    origin: u32,
    destination: u32,
    origin_route: u32 = transit.no_id,
    destination_route: u32 = transit.no_id,
    origin_trip: u32 = transit.no_id,
    destination_trip: u32 = transit.no_id,

    fn record(self: Key, kind: transit.TransferType, seconds: u32) transit.Transfer {
        return .{
            .origin = self.origin,
            .destination = self.destination,
            .origin_route = self.origin_route,
            .destination_route = self.destination_route,
            .origin_trip = self.origin_trip,
            .destination_trip = self.destination_trip,
            .minimum_time = seconds,
            .flags = .{ .kind = kind },
        };
    }
};

const Entry = struct { index: usize, specific_platforms: u2 };

pub fn compile(a: Allocator, scratch: Allocator, feeds: []const gtfs.Feed, locations: places.Places, paths: []const links.Link, deadline: io.Deadline) !Transfers {
    if (feeds.len != locations.feeds.len) return error.InvalidTransitFeed;
    var temp: std.heap.ArenaAllocator = .init(scratch);
    defer temp.deinit();
    const work = temp.allocator();
    const children = try work.alloc(Stops, locations.stations.len);
    @memset(children, .empty);
    for (locations.stops, 0..) |stop, id| {
        if (deadline.expired()) return error.DeadlineExceeded;
        try children[stop.station].append(work, @intCast(id));
    }
    var records: std.ArrayList(transit.Transfer) = .empty;
    errdefer records.deinit(a);
    var explicit: std.AutoHashMapUnmanaged(Key, Entry) = .empty;
    var missing: u64 = 0;
    var trip_base: u32 = 0;
    for (feeds, locations.feeds) |*feed, map| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const trip_count = std.math.cast(u32, feed.ids.getPtrConst(.trip).names.items.len) orelse return error.TooManyTransitIds;
        const next_trip_base = std.math.add(u32, trip_base, trip_count) catch return error.TooManyTransitIds;
        const trips = try work.alloc(bool, trip_count);
        @memset(trips, false);
        for (feed.trips) |trip| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (trip.trip_id.value >= trips.len) return error.InvalidTransitTrip;
            trips[trip.trip_id.value] = true;
        }
        for (feed.transfers) |row| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (row.transfer_type == .minimum_time and row.min_transfer_time == null) return error.InvalidTransitTransferTime;
            const linked = row.transfer_type == .in_seat or row.transfer_type == .forced_alight;
            if (linked and (row.from_trip_id == null or row.to_trip_id == null)) return error.InvalidTransitTransferTrip;
            var one_origin: [1]u32 = undefined;
            var one_dest: [1]u32 = undefined;
            const origins = try endpoints(row.from_stop_id, map.locations, children, linked, &one_origin);
            const destinations = try endpoints(row.to_stop_id, map.locations, children, linked, &one_dest);
            if (origins.stops.len == 0 or destinations.stops.len == 0) {
                missing += 1;
                continue;
            }
            const kind: transit.TransferType = @fromBackingInt(@intCast(@backingInt(row.transfer_type)));
            var key: Key = .{
                .origin = undefined,
                .destination = undefined,
                .origin_route = try routeId(row.from_route_id, map.timetable_ids.routes),
                .destination_route = try routeId(row.to_route_id, map.timetable_ids.routes),
                .origin_trip = try tripId(row.from_trip_id, trips, trip_base),
                .destination_trip = try tripId(row.to_trip_id, trips, trip_base),
            };
            const rank = @as(u2, @intFromBool(origins.platform)) + @intFromBool(destinations.platform);
            for (origins.stops) |origin| {
                key.origin = origin;
                for (destinations.stops) |destination| {
                    if (deadline.expired()) return error.DeadlineExceeded;
                    key.destination = destination;
                    const record = key.record(kind, row.min_transfer_time orelse 0);
                    const present = try explicit.getOrPut(work, key);
                    if (present.found_existing) {
                        if (present.value_ptr.specific_platforms == rank) return error.DuplicateTransitTransfer;
                        if (present.value_ptr.specific_platforms < rank) {
                            records.items[present.value_ptr.index] = record;
                            present.value_ptr.specific_platforms = rank;
                        }
                    } else {
                        present.value_ptr.* = .{ .index = records.items.len, .specific_platforms = rank };
                        try records.append(a, record);
                    }
                }
            }
        }
        trip_base = next_trip_base;
        work.free(trips);
    }

    const graph = try links.Adjacency.init(work, paths, locations.nodes.len, false, deadline);
    const reachable = try work.alloc(u32, locations.nodes.len);
    @memset(reachable, 0);
    const timed = try work.alloc(bool, locations.stations.len);
    @memset(timed, true);
    for (paths) |path| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (path.seconds == null) timed[locations.stationOf(locations.nodes[path.from])] = false;
    }
    const times = try work.alloc(u64, locations.nodes.len);
    var time_queue: links.Adjacency.TimeQueue = .initContext({});
    var queue: std.ArrayList(u32) = .empty;
    for (children, timed) |group, has_times| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (group.items.len < 2) continue;
        for (group.items) |origin| {
            const stamp = origin + 1;
            const first = locations.stops[origin].place.graph_node;
            if (has_times) {
                try graph.shortestTimes(work, first, reachable, stamp, times, &time_queue, deadline);
            } else {
                try graph.mark(work, &.{first}, reachable, stamp, &queue, deadline);
            }
            for (group.items) |destination| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const end = locations.stops[destination].place.graph_node;
                if (destination == origin or reachable[end] != stamp) continue;
                const key: Key = .{ .origin = origin, .destination = destination };
                if (explicit.contains(key)) continue;
                const minimum = if (has_times) std.math.cast(u32, times[end]) orelse return error.TransitTimeOverflow else 0;
                try records.append(a, key.record(if (has_times) .minimum_time else .recommended, minimum));
            }
        }
    }
    return .{ .records = try records.toOwnedSlice(a), .missing_endpoints = missing };
}

const Endpoints = struct { stops: []const u32, platform: bool = false };

fn endpoints(id: ?gtfs.Id(.stop), locations: []const ?places.Location, children: []const Stops, linked: bool, one: *[1]u32) !Endpoints {
    const stop_id = id orelse {
        if (!linked) return error.MissingTransitTransferStop;
        return .{ .stops = &.{transit.no_id} };
    };
    if (stop_id.value >= locations.len) return error.InvalidTransitTransferStop;
    const location = locations[stop_id.value] orelse return .{ .stops = &.{} };
    return switch (location) {
        .stop => |stop| blk: {
            one[0] = stop;
            break :blk .{ .stops = one, .platform = true };
        },
        .station => |station| if (linked) error.InvalidTransitTransferStop else .{ .stops = children[station].items },
        else => error.InvalidTransitTransferStop,
    };
}

fn routeId(id: ?gtfs.Id(.route), ids: []const u32) !u32 {
    const local = id orelse return transit.no_id;
    if (local.value >= ids.len or ids[local.value] == transit.no_id) return error.InvalidTransitTransferRoute;
    return ids[local.value];
}

fn tripId(id: ?gtfs.Id(.trip), present: []const bool, base: u32) !u32 {
    const local = id orelse return transit.no_id;
    if (local.value >= present.len or !present[local.value]) return error.InvalidTransitTransferTrip;
    return base + local.value;
}
