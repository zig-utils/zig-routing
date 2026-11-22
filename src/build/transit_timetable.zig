// Ported from src/mjolnir/convert_transit.cc (Valhalla 3.9.3).
const std = @import("std");
const transit = @import("../graph/transit.zig");
const geo = @import("../geo/point.zig");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const gtfs = @import("gtfs/model.zig");
const calendar = @import("transit_calendar.zig");
const stop_times = @import("transit_stop_times.zig");
const names = @import("tags/names.zig");
const Allocator = std.mem.Allocator;

pub const FeedIds = struct {
    stops: []const u32,
    coordinates: []const ?geo.FixedLL,
    routes: []const u32,
};

pub const Timetable = struct {
    lines: []const transit.Line,
    departures: []const transit.Departure,
    occurrences: []const transit.Occurrence,
    missing_stop_legs: u64,
};

const Pattern = struct {
    route: u32,
    shape: u32,
    direction: ?gtfs.Direction,
    stops: []const u32,

    const Context = struct {
        pub fn hash(_: Context, key: Pattern) u64 {
            var digest = std.hash.XxHash3.init(0);
            digest.update(std.mem.asBytes(&key.route));
            digest.update(std.mem.asBytes(&key.shape));
            const direction: u8 = if (key.direction) |value| @backingInt(value) else 2;
            digest.update(std.mem.asBytes(&direction));
            digest.update(std.mem.sliceAsBytes(key.stops));
            return digest.final();
        }

        pub fn eql(_: Context, left: Pattern, right: Pattern) bool {
            return left.route == right.route and left.shape == right.shape and left.direction == right.direction and
                std.mem.eql(u32, left.stops, right.stops);
        }
    };
};

const Builder = struct {
    a: Allocator,
    strings: *names.StringTable,
    calendars: calendar.Calendars,
    deadline: io.Deadline,
    patterns: std.HashMapUnmanaged(Pattern, u32, Pattern.Context, 80) = .empty,
    line_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    lines: std.ArrayList(transit.Line) = .empty,
    departures: std.ArrayList(transit.Departure) = .empty,
    visits: std.ArrayList(stop_times.Visit) = .empty,
    pattern_stops: std.ArrayList(u32) = .empty,
    trip_base: u32 = 0,
    shape_base: u32 = 0,
    next_block: u32 = 0,
    missing_stop_legs: u64 = 0,

    fn consumeFeed(self: *Builder, source: *const gtfs.Feed, ids: FeedIds, feed_id: usize, a: Allocator) !void {
        const visits = source.stop_times.slice();
        const rows = try stop_times.orderedRows(a, visits, self.deadline);
        const trips = try a.alloc(?*const gtfs.Trip, source.ids.getPtrConst(.trip).names.items.len);
        @memset(trips, null);
        for (source.trips) |*trip| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (trip.trip_id.value >= trips.len) return error.InvalidTransitTrip;
            const entry = &trips[trip.trip_id.value];
            if (entry.* != null) return error.DuplicateTransitTrip;
            entry.* = trip;
        }
        const frequencies = try a.dupe(gtfs.Frequency, source.frequencies);
        if (frequencies.len > 1) {
            const scratch = try a.alloc(gtfs.Frequency, frequencies.len);
            try radix.sortByU64(gtfs.Frequency, a, frequencies, scratch, {}, frequencyKey, self.deadline);
        }
        try verifyFrequencies(frequencies, trips, self.deadline);

        const trip_ids = visits.items(.trip_id);
        var block_ids: std.AutoHashMapUnmanaged(gtfs.Text, u32) = .empty;
        var first: usize = 0;
        while (first < rows.len) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const trip_id = trip_ids[rows[first]].value;
            var end = first + 1;
            while (end < rows.len and trip_ids[rows[end]].value == trip_id) : (end += 1) {
                if (end % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            }
            defer first = end;
            if (trip_id >= trips.len) return error.InvalidTransitTrip;
            const trip = trips[trip_id] orelse return error.InvalidTransitTrip;
            if (trip.route_id.value >= ids.routes.len or ids.routes[trip.route_id.value] == transit.no_id)
                return error.InvalidTransitRoute;
            const block = if (trip.block_id) |text| try self.blockId(a, &block_ids, text) else transit.no_id;
            try stop_times.visits(self.a, &self.visits, visits, rows[first..end], ids.coordinates, self.deadline);
            if (self.visits.items.len < 2) continue;
            const schedule_id = try self.calendars.scheduleId(feed_id, trip.service_id);
            const shape = if (trip.shape_id) |shape_id| try addId(self.shape_base, shape_id.value) else transit.no_id;
            try self.appendTrip(source, ids, trip, block, schedule_id, shape, frequenciesFor(frequencies, trip_id));
        }
        self.trip_base = try addCount(self.trip_base, trips.len);
        self.shape_base = try addCount(self.shape_base, source.ids.getPtrConst(.shape).names.items.len);
    }

    fn blockId(self: *Builder, a: Allocator, blocks: *std.AutoHashMapUnmanaged(gtfs.Text, u32), text: gtfs.Text) !u32 {
        const entry = try blocks.getOrPut(a, text);
        if (!entry.found_existing) {
            if (self.next_block == transit.no_id) return error.TooManyTransitIds;
            entry.value_ptr.* = self.next_block;
            self.next_block += 1;
        }
        return entry.value_ptr.*;
    }

    fn appendTrip(
        self: *Builder,
        source: *const gtfs.Feed,
        ids: FeedIds,
        trip: *const gtfs.Trip,
        block: u32,
        schedule: u32,
        shape: u32,
        frequencies: []const gtfs.Frequency,
    ) !void {
        const route = ids.routes[trip.route_id.value];
        const trip_id = try addId(self.trip_base, trip.trip_id.value);
        const visits = self.visits.items;
        try self.pattern_stops.resize(self.a, visits.len);
        for (visits, self.pattern_stops.items, 0..) |visit, *stop, i| {
            if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            stop.* = visit.stop.value;
        }
        const pattern = try self.patternId(.{ .route = route, .shape = shape, .direction = trip.direction_id, .stops = self.pattern_stops.items });
        const first_departure = visits[0].timing.?.departure;
        // Valhalla's stop pairs carry the trip's headsign.
        const headsign: transit.Text = if (trip.trip_headsign) |text|
            @fromBackingInt(@backingInt(try self.strings.intern(source.text(text))))
        else
            .none;
        for (visits[0 .. visits.len - 1], visits[1..], 0..) |origin, destination, leg| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const from = ids.stops[origin.stop.value];
            const to = ids.stops[destination.stop.value];
            if (from == transit.no_id or to == transit.no_id) {
                self.missing_stop_legs += 1;
                continue;
            }
            const line = try self.lineId(pattern, @intCast(leg), from, to, route, shape);
            const boarding = origin.timing.?.departure;
            const arrival = destination.timing.?.arrival;
            const scheduled: transit.Departure = .{
                .line = line,
                .route = route,
                .trip = trip_id,
                .block = block,
                .schedule = schedule,
                .headsign = headsign,
                .start_time = boarding,
                .elapsed_time = arrival - boarding,
                .flags = .{
                    .wheelchair = trip.wheelchair_accessible == .available,
                    .bicycle = trip.bikes_allowed == .available,
                },
            };
            if (frequencies.len == 0) {
                try self.departures.append(self.a, scheduled);
                continue;
            }
            const offset = boarding - first_departure;
            for (frequencies) |frequency| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                var repeat = scheduled;
                repeat.start_time = std.math.add(u32, frequency.start_time.seconds, offset) catch return error.TransitTimeOverflow;
                repeat.end_time = std.math.add(u32, frequency.end_time.seconds, offset) catch return error.TransitTimeOverflow;
                repeat.headway = frequency.headway_secs;
                repeat.flags.kind = .frequency;
                try self.departures.append(self.a, repeat);
            }
        }
    }

    fn patternId(self: *Builder, pattern: Pattern) !u32 {
        const entry = try self.patterns.getOrPut(self.a, pattern);
        if (!entry.found_existing) {
            entry.value_ptr.* = self.patterns.count() - 1;
            entry.key_ptr.stops = try self.a.dupe(u32, pattern.stops);
        }
        return entry.value_ptr.*;
    }

    fn lineId(self: *Builder, pattern: u32, leg: u32, from: u32, to: u32, route: u32, shape: u32) !u32 {
        const key = @as(u64, pattern) << 32 | leg;
        const entry = try self.line_ids.getOrPut(self.a, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = try addCount(0, self.lines.items.len);
            try self.lines.append(self.a, .{
                .origin = from,
                .destination = to,
                .route = route,
                .shape = shape,
                .departures = .{},
            });
        }
        return entry.value_ptr.*;
    }

    fn finish(self: *Builder, working: Allocator) !Timetable {
        const departures = self.departures.items;
        const lines = self.lines.items;
        if (departures.len > std.math.maxInt(u32)) return error.TooManyTransitDepartures;
        const scratch = try working.alloc(transit.Departure, departures.len);
        defer working.free(scratch);
        try radix.sortByU64(transit.Departure, working, departures, scratch, {}, departureKey, self.deadline);
        var next: usize = 0;
        for (lines, 0..) |*line, id| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const first = next;
            while (next < departures.len and departures[next].line == id) : (next += 1) {
                if (next % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            }
            line.departures = .{ .first = @intCast(first), .count = @intCast(next - first) };
        }
        const indexed = try transit.indexDepartures(self.a, lines, departures, self.deadline);
        return .{
            .lines = indexed.lines,
            .departures = departures,
            .occurrences = indexed.occurrences,
            .missing_stop_legs = self.missing_stop_legs,
        };
    }
};

/// Output records and provisional text IDs are owned by the build arena.
pub fn compile(a: Allocator, scratch: Allocator, feeds: []const gtfs.Feed, ids: []const FeedIds, calendars: calendar.Calendars, strings: *names.StringTable, deadline: io.Deadline) !Timetable {
    if (feeds.len != ids.len) return error.InvalidTransitFeed;
    var builder: Builder = .{ .a = a, .strings = strings, .calendars = calendars, .deadline = deadline };
    for (feeds, ids, 0..) |*feed, feed_ids, i| {
        if (feed_ids.stops.len != feed_ids.coordinates.len) return error.InvalidTransitStopId;
        var temp: std.heap.ArenaAllocator = .init(scratch);
        defer temp.deinit();
        try builder.consumeFeed(feed, feed_ids, i, temp.allocator());
    }
    return builder.finish(scratch);
}

fn verifyFrequencies(rows: []const gtfs.Frequency, trips: []const ?*const gtfs.Trip, deadline: io.Deadline) !void {
    var before: ?gtfs.Frequency = null;
    for (rows) |row| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (row.trip_id.value >= trips.len or trips[row.trip_id.value] == null) return error.InvalidTransitTrip;
        if (row.start_time.seconds >= row.end_time.seconds or row.headway_secs == 0) return error.InvalidTransitFrequency;
        if (before) |previous| {
            if (row.trip_id.value == previous.trip_id.value and row.start_time.seconds < previous.end_time.seconds)
                return error.OverlappingTransitFrequency;
        }
        before = row;
    }
}

fn frequenciesFor(rows: []const gtfs.Frequency, trip: u32) []const gtfs.Frequency {
    const first = frequencyBoundary(rows, trip);
    const end = frequencyBoundary(rows[first..], @as(u64, trip) + 1);
    return rows[first..][0..end];
}

fn frequencyBoundary(rows: []const gtfs.Frequency, trip: u64) usize {
    var left: usize = 0;
    var right = rows.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (rows[mid].trip_id.value < trip) left = mid + 1 else right = mid;
    }
    return left;
}

fn frequencyKey(_: void, row: gtfs.Frequency) u64 {
    return @as(u64, row.trip_id.value) << 32 | row.start_time.seconds;
}

fn departureKey(_: void, row: transit.Departure) u64 {
    return @as(u64, row.line) << 32 | row.start_time;
}

fn addCount(first: u32, length: usize) !u32 {
    const count = std.math.cast(u32, length) orelse return error.TooManyTransitIds;
    return std.math.add(u32, first, count) catch return error.TooManyTransitIds;
}

fn addId(first: u32, local: u32) !u32 {
    const id = try addCount(first, local);
    if (id == transit.no_id) return error.TooManyTransitIds;
    return id;
}

test "stop pairs from the same trip pattern share fixed and frequency departures" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var feed: gtfs.Feed = .init(a);
    const route = try feed.internId(.route, "route");
    const service = try feed.internId(.service, "service");
    const block = try feed.internText("block");
    const headsign = try feed.internText("Northbound");
    const fixed = try feed.internId(.trip, "fixed");
    const repeated = try feed.internId(.trip, "repeated");
    const branch = try feed.internId(.trip, "branch");
    const stops = [_]gtfs.Id(.stop){
        try feed.internId(.stop, "first"),
        try feed.internId(.stop, "second"),
        try feed.internId(.stop, "third"),
        try feed.internId(.stop, "branch-only"),
    };
    feed.trips = &.{
        .{ .trip_id = fixed, .route_id = route, .service_id = service, .trip_headsign = headsign, .block_id = block, .wheelchair_accessible = .available },
        .{ .trip_id = repeated, .route_id = route, .service_id = service, .trip_headsign = headsign, .block_id = block, .bikes_allowed = .available },
        .{ .trip_id = branch, .route_id = route, .service_id = service },
    };
    feed.frequencies = &.{.{
        .trip_id = repeated,
        .start_time = .{ .seconds = 32400 },
        .end_time = .{ .seconds = 36000 },
        .headway_secs = 1800,
    }};
    feed.calendar_dates = &.{.{ .service_id = service, .date = .{ .yyyymmdd = 20260101 }, .exception_type = .added }};
    for (feed.trips, 0..) |trip, i| {
        const trip_stops = [_]gtfs.Id(.stop){ stops[0], stops[1], stops[if (i == 2) 3 else 2] };
        for (trip_stops, 0..) |stop, seq| {
            try feed.stop_times.append(a, .{
                .trip_id = trip.trip_id,
                .stop_sequence = @intCast(seq + 1),
                .stop_id = stop,
                .arrival_time = .{ .seconds = 28800 + @as(u32, @intCast(seq)) * 300 },
            });
        }
    }
    const feeds = &.{feed};
    const calendars = try calendar.compile(a, feeds, .none);
    var strings: names.StringTable = .init(a);
    defer strings.deinit();
    const result = try compile(a, testing.allocator, feeds, &.{.{
        .stops = &.{ 0, 1, 2, 3 },
        .coordinates = &.{ null, null, null, null },
        .routes = &.{0},
    }}, calendars, &strings, .none);
    try testing.expectEqual(4, result.lines.len);
    try testing.expectEqual(6, result.departures.len);
    try testing.expectEqual(6, result.occurrences.len);
    try testing.expectEqual(0, result.missing_stop_legs);
    try testing.expectEqualDeep(transit.Span{ .count = 2 }, result.lines[0].departures);
    try testing.expectEqualDeep(transit.Span{ .first = 4, .count = 1 }, result.lines[2].departures);
    try testing.expectEqual(28800, result.departures[0].start_time);
    try testing.expectEqual(32400, result.departures[1].start_time);
    try testing.expectEqual(32700, result.departures[3].start_time);
    try testing.expectEqual(36300, result.departures[3].end_time);
    try testing.expectEqual(300, result.departures[3].elapsed_time);
    try testing.expectEqual(result.departures[0].block, result.departures[1].block);
    try testing.expect(result.departures[0].flags.wheelchair and result.departures[1].flags.bicycle);
    try testing.expectEqualStrings("Northbound", strings.get(@fromBackingInt(@backingInt(result.departures[1].headsign))).?);
}
