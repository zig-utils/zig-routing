// Ported from valhalla/baldr/transitstop.h, transitroute.h,
// transitdeparture.h, transitschedule.h, transittransfer.h and
// proto/descriptors/transit.proto (Valhalla 3.9.3).
const std = @import("std");
const builtin = @import("builtin");
const geo = @import("../geo/point.zig");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const cold = @import("cold.zig");
const Allocator = std.mem.Allocator;
const Deadline = io.Deadline;

pub const section_version: u32 = 1;
pub const no_id = std.math.maxInt(u32);
pub const Text = enum(u32) { none = no_id, _ };
pub const Traversability = enum(u2) { none, forward, backward, both };
pub const Vehicle = enum(u8) { tram, metro, rail, bus, ferry, cable_car, gondola, funicular, trolleybus = 11, monorail = 12, _ };
pub const TransferType = enum(u4) { recommended, timed, minimum_time, forbidden, in_seat, forced_alight, _ };
pub const DepartureType = enum(u2) { fixed, frequency, _ };
pub const Weekday = enum(u3) { sunday, monday, tuesday, wednesday, thursday, friday, saturday };

pub const Metadata = extern struct {
    version: u32 = section_version,
    /// Civil days since 1970-01-01. Service bitsets start here.
    start_day: i32,
    reserved: u32 = 0,
};

pub const Span = extern struct {
    first: u32 = 0,
    count: u32 = 0,

    pub fn items(self: Span, comptime T: type, records: []const T) error{InvalidTransitSpan}![]const T {
        if (self.first > records.len or self.count > records.len - self.first) return error.InvalidTransitSpan;
        return records[self.first..][0..self.count];
    }
};

pub const Place = extern struct {
    coordinate: geo.FixedLL,
    name: Text,
    one_stop_id: Text,
    timezone: Text = .none,
    graph_node: u32 = no_id,
    flags: packed struct(u32) {
        traversability: Traversability = .both,
        generated: bool = false,
        wheelchair_boarding: bool = false,
        reserved: u28 = 0,
    } = .{},
};

pub const Stop = extern struct {
    place: Place,
    station: u32 = no_id,
};

pub const Station = extern struct {
    place: Place,
};

pub const Egress = extern struct {
    place: Place,
    station: u32,
    connecting_way: u64 = 0,
    connecting_point: geo.FixedLL = .{ .lng = 0, .lat = 0 },
    flags: packed struct(u32) {
        has_connecting_way: bool = false,
        has_connecting_point: bool = false,
        reserved: u30 = 0,
    } = .{},
    reserved: u32 = 0,
};

pub const Route = extern struct {
    one_stop_id: Text,
    operator_one_stop_id: Text = .none,
    operator_name: Text = .none,
    operator_website: Text = .none,
    short_name: Text = .none,
    long_name: Text = .none,
    description: Text = .none,
    color: Text = .none,
    text_color: Text = .none,
    flags: packed struct(u32) { vehicle: Vehicle, reserved: u24 = 0 },
};

pub const Line = extern struct {
    origin: u32,
    destination: u32,
    route: u32,
    shape: u32 = no_id,
    departures: Span,
    occurrences: Span = .{},
};

pub const Departure = extern struct {
    line: u32,
    route: u32,
    trip: u32,
    block: u32,
    schedule: u32,
    headsign: Text = .none,
    start_time: u32,
    end_time: u32 = 0,
    headway: u32 = 0,
    elapsed_time: u32,
    flags: packed struct(u32) {
        kind: DepartureType = .fixed,
        wheelchair: bool = false,
        bicycle: bool = false,
        reserved: u28 = 0,
    } = .{},

    pub fn atOrAfter(self: Departure, time: u32) ?u32 {
        if (self.flags.kind == .fixed) return if (time <= self.start_time) self.start_time else null;
        if (self.flags.kind != .frequency or self.headway == 0 or self.start_time >= self.end_time) return null;
        const wait: u64 = time -| self.start_time;
        const intervals = (wait + self.headway - 1) / self.headway;
        const occurrence = self.start_time + intervals * self.headway;
        return if (occurrence < self.end_time) @intCast(occurrence) else null;
    }

    fn count(self: Departure) !u32 {
        if (self.flags.reserved != 0) return error.InvalidTransitDeparture;
        if (self.flags.kind == .fixed) {
            if (self.end_time != 0 or self.headway != 0) return error.InvalidTransitDeparture;
            return 1;
        }
        if (self.flags.kind != .frequency or self.end_time <= self.start_time or self.headway == 0)
            return error.InvalidTransitDeparture;
        return (self.end_time - self.start_time - 1) / self.headway + 1;
    }
};

/// A fixed departure or a materialized instant from a frequency record.
/// Only lines with frequencies need these rows. Fixed-only lines search the
/// canonical departure slice directly.
pub const Occurrence = extern struct {
    time: u32,
    departure: u32,
};

pub const Schedule = extern struct {
    days: Span,
    /// Number of days covered by the dense bitset. Outside that range,
    /// the weekly mask applies unless an exception exists.
    day_count: u32,
    exceptions: Span = .{},
    flags: packed struct(u32) {
        weekdays: u7 = 0,
        reserved: u25 = 0,
    } = .{},
};

pub const DayWord = extern struct { bits: u32 };

pub const Exception = extern struct {
    /// Civil day relative to the transit section's start day.
    day: i32,
    flags: packed struct(u32) { active: bool, reserved: u31 = 0 },
};

pub const Transfer = extern struct {
    origin: u32 = no_id,
    destination: u32 = no_id,
    origin_route: u32 = no_id,
    destination_route: u32 = no_id,
    origin_trip: u32 = no_id,
    destination_trip: u32 = no_id,
    minimum_time: u32 = 0,
    flags: packed struct(u32) { kind: TransferType, reserved: u28 = 0 },
};

comptime {
    std.debug.assert(builtin.target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Metadata) == 12 and @offsetOf(Metadata, "start_day") == 4);
    std.debug.assert(@sizeOf(Span) == 8 and @offsetOf(Span, "count") == 4);
    std.debug.assert(@sizeOf(Place) == 28 and @offsetOf(Place, "flags") == 24);
    std.debug.assert(@sizeOf(Stop) == 32 and @offsetOf(Stop, "station") == 28);
    std.debug.assert(@sizeOf(Station) == 28 and @offsetOf(Station, "place") == 0);
    std.debug.assert(@sizeOf(Egress) == 56 and @offsetOf(Egress, "connecting_way") == 32 and @offsetOf(Egress, "flags") == 48);
    std.debug.assert(@sizeOf(Route) == 40 and @offsetOf(Route, "flags") == 36);
    std.debug.assert(@sizeOf(Line) == 32 and @offsetOf(Line, "departures") == 16 and @offsetOf(Line, "occurrences") == 24);
    std.debug.assert(@sizeOf(Departure) == 44 and @offsetOf(Departure, "start_time") == 24 and @offsetOf(Departure, "flags") == 40);
    std.debug.assert(@sizeOf(Occurrence) == 8 and @offsetOf(Occurrence, "departure") == 4);
    std.debug.assert(@sizeOf(Schedule) == 24 and @offsetOf(Schedule, "exceptions") == 12 and @offsetOf(Schedule, "flags") == 20);
    std.debug.assert(@sizeOf(DayWord) == 4 and @offsetOf(DayWord, "bits") == 0);
    std.debug.assert(@sizeOf(Exception) == 8 and @offsetOf(Exception, "flags") == 4);
    std.debug.assert(@sizeOf(Transfer) == 32 and @offsetOf(Transfer, "flags") == 28);
}

pub const Indexed = struct {
    lines: []Line,
    occurrences: []Occurrence,

    pub fn deinit(self: Indexed, a: Allocator) void {
        a.free(self.lines);
        a.free(self.occurrences);
    }
};

/// Builds the time index for canonical records sorted by line then start
/// time. The caller owns the returned line metadata and index rows.
pub fn indexDepartures(a: Allocator, lines: []const Line, departures: []const Departure, deadline: Deadline) !Indexed {
    const indexed = try a.dupe(Line, lines);
    errdefer a.free(indexed);
    var total: u32 = 0;
    var covered: u32 = 0;
    for (indexed, 0..) |*line, id| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (line.departures.first != covered) return error.InvalidTransitDepartureOrder;
        const records = try line.departures.items(Departure, departures);
        covered = std.math.add(u32, covered, line.departures.count) catch return error.TooManyTransitDepartures;
        const count = try lineOccurrences(records, id, line.route, deadline);
        line.occurrences = .{ .first = total, .count = count };
        total = std.math.add(u32, total, count) catch return error.TooManyTransitOccurrences;
    }
    if (covered != departures.len) return error.InvalidTransitDepartureOrder;
    const occurrences = try a.alloc(Occurrence, total);
    errdefer a.free(occurrences);
    for (indexed) |line| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (line.occurrences.count == 0) continue;
        const records = try line.departures.items(Departure, departures);
        var position = line.occurrences.first;
        for (records, line.departures.first..) |record, id| {
            if (deadline.expired()) return error.DeadlineExceeded;
            for (0..try record.count()) |i| {
                if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                occurrences[position] = .{ .time = record.start_time + @as(u32, @intCast(i)) * record.headway, .departure = @intCast(id) };
                position += 1;
            }
        }
    }
    if (occurrences.len > 1) {
        const scratch = try a.alloc(Occurrence, occurrences.len);
        defer a.free(scratch);
        try radix.sortByU64(Occurrence, a, occurrences, scratch, departures, occurrenceKey, deadline);
    }
    return .{ .lines = indexed, .occurrences = occurrences };
}

fn occurrenceKey(departures: []const Departure, slot: Occurrence) u64 {
    return @as(u64, departures[slot.departure].line) << 32 | slot.time;
}

fn lineOccurrences(records: []const Departure, line_id: usize, route_id: u32, deadline: Deadline) !u32 {
    var previous: u32 = 0;
    var count: u64 = 0;
    var has_frequency = false;
    for (records, 0..) |record, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (record.line != line_id or record.route != route_id or record.start_time < previous)
            return error.InvalidTransitDepartureOrder;
        previous = record.start_time;
        count += try record.count();
        has_frequency = has_frequency or record.flags.kind == .frequency;
    }
    if (!has_frequency) return 0;
    return std.math.cast(u32, count) orelse error.TooManyTransitOccurrences;
}

pub const NextDeparture = struct {
    departure: *const Departure,
    time: u32,
};

pub const DepartureIterator = struct {
    line_id: u32,
    records: []const Departure,
    first_record: u32,
    occurrences: ?[]const Occurrence,

    pub fn next(self: *DepartureIterator) !?NextDeparture {
        if (self.occurrences) |slots| {
            if (slots.len == 0) return null;
            const slot = slots[0];
            if (slot.departure < self.first_record or slot.departure - self.first_record >= self.records.len)
                return error.InvalidTransitOccurrence;
            const record = &self.records[slot.departure - self.first_record];
            if (record.line != self.line_id or record.atOrAfter(slot.time) != slot.time)
                return error.InvalidTransitOccurrence;
            self.occurrences = slots[1..];
            return .{ .departure = record, .time = slot.time };
        }
        if (self.records.len == 0) return null;
        const record = &self.records[0];
        if (record.line != self.line_id or record.flags.kind != .fixed) return error.InvalidTransitDepartureOrder;
        self.records = self.records[1..];
        return .{ .departure = record, .time = record.start_time };
    }
};

/// All slices and text references borrow the bundle's mmap.
pub const View = struct {
    metadata: Metadata,
    stops: []const Stop,
    stations: []const Station,
    egresses: []const Egress,
    routes: []const Route,
    lines: []const Line,
    departures: []const Departure,
    occurrences: []const Occurrence,
    schedules: []const Schedule,
    days: []const DayWord,
    exceptions: []const Exception,
    transfers: []const Transfer,
    strings: cold.View,

    pub fn text(self: View, id: Text) !?[]const u8 {
        if (id == .none) return null;
        const index = @backingInt(id);
        if (index > std.math.maxInt(u31)) return error.InvalidTransitText;
        return (try self.strings.name(index)).text;
    }

    pub fn departuresOn(self: View, line_id: u32) ![]const Departure {
        if (line_id >= self.lines.len) return error.InvalidTransitLine;
        return self.lines[line_id].departures.items(Departure, self.departures);
    }

    /// Finds the first offered time on a line. Calendar and accessibility
    /// checks use the returned record's schedule and flags.
    pub fn nextDeparture(self: View, line_id: u32, time: u32) !?NextDeparture {
        var iterator = try self.departureIterator(line_id, time);
        return iterator.next();
    }

    /// Seek once to the first offered time. Iteration includes every tied
    /// departure so the search can evaluate its service and trip state.
    pub fn departureIterator(self: View, line_id: u32, time: u32) !DepartureIterator {
        const records = try self.departuresOn(line_id);
        const line = self.lines[line_id];
        var iterator: DepartureIterator = .{
            .line_id = line_id,
            .records = records,
            .first_record = line.departures.first,
            .occurrences = null,
        };
        if (line.occurrences.count == 0) {
            iterator.records = records[lowerBound(Departure, records, "start_time", time)..];
        } else {
            const slots = try line.occurrences.items(Occurrence, self.occurrences);
            iterator.occurrences = slots[lowerBound(Occurrence, slots, "time", time)..];
        }
        return iterator;
    }

    pub fn lastDepartureTime(self: View, line_id: u32) !?u32 {
        const records = try self.departuresOn(line_id);
        const line = self.lines[line_id];
        if (line.occurrences.count != 0) {
            const slots = try line.occurrences.items(Occurrence, self.occurrences);
            return slots[slots.len - 1].time;
        }
        return if (records.len != 0) records[records.len - 1].start_time else null;
    }

    pub fn scheduleActive(self: View, schedule_id: u32, civil_day: i32, weekday: Weekday) !bool {
        if (schedule_id >= self.schedules.len) return error.InvalidTransitSchedule;
        const schedule = self.schedules[schedule_id];
        const day = @as(i64, civil_day) - self.metadata.start_day;
        const exceptions = try schedule.exceptions.items(Exception, self.exceptions);
        const pos = lowerBound(Exception, exceptions, "day", day);
        if (pos < exceptions.len and exceptions[pos].day == day) return exceptions[pos].flags.active;
        if (day >= 0 and day < schedule.day_count) {
            const words = try schedule.days.items(DayWord, self.days);
            const index: usize = @intCast(@divFloor(day, 32));
            if (index >= words.len) return error.InvalidTransitSchedule;
            return words[index].bits & (@as(u32, 1) << @as(u5, @intCast(@mod(day, 32)))) != 0;
        }
        return schedule.flags.weekdays & (@as(u7, 1) << @backingInt(weekday)) != 0;
    }

    pub fn verify(self: View, node_count: usize, deadline: Deadline) !void {
        for (self.stations) |entry| {
            if (deadline.expired()) return error.DeadlineExceeded;
            try self.verifyPlace(entry.place, node_count);
        }
        for (self.stops) |entry| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (entry.station != no_id and entry.station >= self.stations.len) return error.InvalidTransitStop;
            try self.verifyPlace(entry.place, node_count);
        }
        for (self.egresses) |entry| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (entry.station >= self.stations.len or entry.flags.reserved != 0 or entry.reserved != 0 or
                (entry.flags.has_connecting_point and !entry.connecting_point.inRange())) return error.InvalidTransitEgress;
            try self.verifyPlace(entry.place, node_count);
        }
        for (self.routes) |entry| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const kind = @backingInt(entry.flags.vehicle);
            if (entry.flags.reserved != 0 or (kind > 7 and kind != 11 and kind != 12)) return error.InvalidTransitRoute;
            inline for (@typeInfo(Route).@"struct".field_names, @typeInfo(Route).@"struct".field_types) |name, Field| {
                if (Field == Text) _ = try self.text(@field(entry, name));
            }
        }
        for (self.transfers) |entry| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (entry.flags.reserved != 0 or
                (entry.origin != no_id and entry.origin >= self.stops.len) or
                (entry.destination != no_id and entry.destination >= self.stops.len) or
                (entry.origin_route != no_id and entry.origin_route >= self.routes.len) or
                (entry.destination_route != no_id and entry.destination_route >= self.routes.len))
                return error.InvalidTransitTransfer;
            switch (entry.flags.kind) {
                .recommended, .timed, .minimum_time, .forbidden => {
                    if (entry.origin == no_id or entry.destination == no_id) return error.InvalidTransitTransfer;
                },
                .in_seat, .forced_alight => {
                    if (entry.origin_trip == no_id or entry.destination_trip == no_id) return error.InvalidTransitTransfer;
                },
                else => return error.InvalidTransitTransfer,
            }
        }
        for (self.schedules) |schedule| {
            if (deadline.expired()) return error.DeadlineExceeded;
            try self.verifySchedule(schedule, deadline);
        }
        try self.verifyLines(deadline);
    }

    fn verifyPlace(self: View, place: Place, node_count: usize) !void {
        if (!place.coordinate.inRange() or place.flags.reserved != 0 or
            (place.graph_node != no_id and place.graph_node >= node_count)) return error.InvalidTransitPlace;
        _ = try self.text(place.name);
        _ = try self.text(place.one_stop_id);
        _ = try self.text(place.timezone);
    }

    fn verifySchedule(self: View, schedule: Schedule, deadline: Deadline) !void {
        const words = try schedule.days.items(DayWord, self.days);
        const expected = (@as(u64, schedule.day_count) + 31) / 32;
        if (words.len != expected or schedule.flags.reserved != 0) return error.InvalidTransitSchedule;
        const tail: u5 = @truncate(schedule.day_count);
        if (tail != 0 and words[words.len - 1].bits >> tail != 0) return error.InvalidTransitSchedule;
        const exceptions = try schedule.exceptions.items(Exception, self.exceptions);
        var previous: ?i32 = null;
        for (exceptions, 0..) |entry, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (entry.flags.reserved != 0 or (previous != null and entry.day <= previous.?)) return error.InvalidTransitSchedule;
            previous = entry.day;
        }
    }

    fn verifyLines(self: View, deadline: Deadline) !void {
        var departure_count: usize = 0;
        var slot_count: usize = 0;
        for (self.lines, 0..) |line, id| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (line.origin >= self.stops.len or line.destination >= self.stops.len or line.route >= self.routes.len)
                return error.InvalidTransitLine;
            if (line.departures.first != departure_count or line.occurrences.first != slot_count)
                return error.InvalidTransitDepartureOrder;
            const records = try line.departures.items(Departure, self.departures);
            const slots = try line.occurrences.items(Occurrence, self.occurrences);
            if (slots.len != try lineOccurrences(records, id, line.route, deadline)) return error.InvalidTransitOccurrence;
            for (records, 0..) |record, i| {
                if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (record.schedule >= self.schedules.len) return error.InvalidTransitSchedule;
                _ = try self.text(record.headsign);
            }
            var previous: ?Occurrence = null;
            for (slots, 0..) |slot, i| {
                if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (slot.departure < departure_count or slot.departure - departure_count >= records.len)
                    return error.InvalidTransitOccurrence;
                if (previous) |prior| {
                    if (slot.time < prior.time or (slot.time == prior.time and slot.departure <= prior.departure))
                        return error.InvalidTransitOccurrence;
                }
                if (self.departures[slot.departure].atOrAfter(slot.time) != slot.time) return error.InvalidTransitOccurrence;
                previous = slot;
            }
            departure_count += records.len;
            slot_count += slots.len;
        }
        if (departure_count != self.departures.len or slot_count != self.occurrences.len)
            return error.InvalidTransitDepartureOrder;
    }
};

fn lowerBound(comptime T: type, records: []const T, comptime key: []const u8, target: anytype) usize {
    var left: usize = 0;
    var right = records.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (@field(records[mid], key) < target) left = mid + 1 else right = mid;
    }
    return left;
}
