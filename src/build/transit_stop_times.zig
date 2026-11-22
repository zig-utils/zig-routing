// Ported from src/mjolnir/ingest_transit.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/point.zig");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const gtfs = @import("gtfs/model.zig");
const Allocator = std.mem.Allocator;
const StopId = gtfs.Id(.stop);
const Columns = std.MultiArrayList(gtfs.StopTime).Slice;

pub const Timing = struct {
    arrival: u32,
    departure: u32,
};

pub const Visit = struct {
    stop: StopId,
    timing: ?Timing,
};

const Keys = struct {
    trips: []const gtfs.Id(.trip),
    sequences: []const u32,

    fn key(self: Keys, row: u32) u64 {
        return @as(u64, self.trips[row].value) << 32 | self.sequences[row];
    }
};

/// Keep the parsed columns in place and sort a single row index by trip
/// then sequence. Feeds already in that order avoid radix scratch.
pub fn orderedRows(a: Allocator, table: Columns, deadline: io.Deadline) ![]u32 {
    if (table.len > std.math.maxInt(u32)) return error.TooManyTransitStopTimes;
    const index = try a.alloc(u32, table.len);
    errdefer a.free(index);
    const keys: Keys = .{ .trips = table.items(.trip_id), .sequences = table.items(.stop_sequence) };
    var sorted = true;
    var previous: u64 = 0;
    for (index, 0..) |*row, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        row.* = @intCast(i);
        const key = keys.key(row.*);
        sorted = sorted and previous <= key;
        previous = key;
    }
    if (!sorted) {
        const scratch = try a.alloc(u32, index.len);
        defer a.free(scratch);
        try radix.sortByU64(u32, a, index, scratch, keys, Keys.key, deadline);
    }
    if (index.len > 1) {
        for (index[0 .. index.len - 1], index[1..], 0..) |before, after, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (keys.key(before) == keys.key(after)) return error.DuplicateTransitStopSequence;
        }
    }
    return index;
}

/// Form the ordered visits for one trip. An untimed run uses the supplied
/// shape distances when available, stop-to-stop distances otherwise, and
/// uniform spacing when the run has no usable distance.
pub fn visits(
    a: Allocator,
    out: *std.ArrayList(Visit),
    table: Columns,
    rows: []const u32,
    positions: []const ?geo.FixedLL,
    deadline: io.Deadline,
) !void {
    try out.resize(a, rows.len);
    if (rows.len == 0) return;
    const stops = table.items(.stop_id);
    const arrivals = table.items(.arrival_time);
    const departures = table.items(.departure_time);
    for (rows, out.items, 0..) |row, *visit, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (row >= table.len) return error.InvalidTransitStopTimeRow;
        const id = stops[row] orelse return error.MissingTransitStopId;
        if (id.value >= positions.len) return error.InvalidTransitStopId;
        const arrival = arrivals[row] orelse departures[row];
        const departure = departures[row] orelse arrivals[row];
        visit.* = .{
            .stop = id,
            .timing = if (arrival) |time| .{ .arrival = time.seconds, .departure = departure.?.seconds } else null,
        };
    }
    if (out.items[0].timing == null or out.items[out.items.len - 1].timing == null) return error.UntimedTransitEndpoint;
    const distances = table.items(.shape_dist_traveled);
    var anchor: usize = 0;
    for (out.items, 0..) |visit, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const timing = visit.timing orelse continue;
        if (timing.arrival > timing.departure) return error.InvalidTransitStopTimeOrder;
        if (i == 0) continue;
        const start = out.items[anchor].timing.?.departure;
        if (timing.arrival < start) return error.InvalidTransitStopTimeOrder;
        if (i > anchor + 1)
            try interpolate(out.items[anchor .. i + 1], rows[anchor .. i + 1], distances, positions, start, timing.arrival, deadline);
        anchor = i;
    }
}

const Distance = enum { shape, coordinates, uniform };

fn interpolate(
    stops: []Visit,
    rows: []const u32,
    along_shape: []const ?f64,
    coordinates: []const ?geo.FixedLL,
    start: u32,
    finish: u32,
    deadline: io.Deadline,
) !void {
    var mode: Distance = .shape;
    var previous: f64 = -1;
    for (rows, 0..) |row, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const distance = along_shape[row] orelse {
            mode = .coordinates;
            break;
        };
        if (!std.math.isFinite(distance) or distance < 0 or distance < previous) {
            mode = .coordinates;
            break;
        }
        previous = distance;
    }
    var total = if (mode == .shape) previous - along_shape[rows[0]].? else 0;
    if (total == 0) {
        mode = .coordinates;
        for (stops[0 .. stops.len - 1], stops[1..], 0..) |left, right, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            total += coordinateDistance(left, right, coordinates) orelse {
                mode = .uniform;
                break;
            };
        }
        if (total == 0) mode = .uniform;
    }
    if (mode == .uniform) total = @floatFromInt(stops.len - 1);

    var traveled: f64 = 0;
    var i: usize = 1;
    while (i + 1 < stops.len) : (i += 1) {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        traveled += switch (mode) {
            .shape => along_shape[rows[i]].? - along_shape[rows[i - 1]].?,
            .coordinates => coordinateDistance(stops[i - 1], stops[i], coordinates).?,
            .uniform => 1,
        };
        const duration: f64 = @floatFromInt(finish - start);
        const elapsed: u32 = @intFromFloat(@round(@min(1, traveled / total) * duration));
        const time = start + elapsed;
        stops[i].timing = .{ .arrival = time, .departure = time };
    }
}

fn coordinateDistance(left: Visit, right: Visit, coordinates: []const ?geo.FixedLL) ?f64 {
    const a = coordinates[left.stop.value] orelse return null;
    const b = coordinates[right.stop.value] orelse return null;
    return a.toPoint().distance(b.toPoint());
}

test "transit visits sort by trip sequence and interpolate across midnight" {
    const testing = std.testing;
    const a = testing.allocator;
    const trip: gtfs.Id(.trip) = .{ .value = 0 };
    var table: std.MultiArrayList(gtfs.StopTime) = .empty;
    defer table.deinit(a);
    for ([_]gtfs.StopTime{
        .{ .trip_id = trip, .stop_sequence = 30, .stop_id = .{ .value = 2 }, .arrival_time = .{ .seconds = 86_520 }, .shape_dist_traveled = 800 },
        .{ .trip_id = trip, .stop_sequence = 10, .stop_id = .{ .value = 0 }, .departure_time = .{ .seconds = 86_280 }, .shape_dist_traveled = 400 },
        .{ .trip_id = trip, .stop_sequence = 20, .stop_id = .{ .value = 1 }, .shape_dist_traveled = 500 },
    }) |row| try table.append(a, row);
    const rows = try orderedRows(a, table.slice(), .none);
    defer a.free(rows);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, rows);
    var list: std.ArrayList(Visit) = .empty;
    defer list.deinit(a);
    try visits(a, &list, table.slice(), rows, &.{ null, null, null }, .none);
    try testing.expectEqualDeep(Timing{ .arrival = 86_340, .departure = 86_340 }, list.items[1].timing.?);
    try testing.expectEqual(86_520, list.items[2].timing.?.departure);
}
