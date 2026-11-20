// Ported from src/loki/transit_available_action.cc and src/midgard/tiles.cc
// (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/root.zig");
const transit = @import("transit.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;

const rows = 720;
const columns = 1440;
const words_per_row = (columns + 63) / 64;

/// The availability action tests the quarter-degree transit tiles that
/// intersect the requested bounding box.
pub const Index = struct {
    words: [rows][words_per_row]u64,

    pub fn init(a: Allocator, table: ?transit.View, deadline: Deadline) !?*Index {
        const present = table orelse return null;
        if (deadline.expired()) return error.DeadlineExceeded;
        const index = try a.create(Index);
        errdefer a.destroy(index);
        @memset(std.mem.asBytes(index), 0);
        var marked = false;
        for (present.lines, 0..) |line, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if ((try line.departures.items(transit.Departure, present.departures)).len == 0) continue;
            for ([_]u32{ line.origin, line.destination }) |id| {
                if (id >= present.stops.len) return error.InvalidTransitStop;
                const place = present.stops[id].place;
                if (place.graph_node == transit.no_id) continue;
                if (!place.coordinate.inRange()) return error.InvalidTransitCoordinate;
                index.mark(place.coordinate.toPoint());
                marked = true;
            }
        }
        if (marked) return index;
        a.destroy(index);
        return null;
    }

    fn mark(self: *Index, point: geo.PointLL) void {
        const row = cell(point.lat, 90, rows - 1);
        const col = cell(point.lng, 180, columns - 1);
        self.words[row][col / 64] |= @as(u64, 1) << @as(u6, @truncate(col));
    }

    pub fn available(self: *const Index, point: geo.PointLL, radius: u32, deadline: Deadline) error{DeadlineExceeded}!bool {
        if (deadline.expired()) return error.DeadlineExceeded;
        const metres: f64 = @floatFromInt(radius);
        const latitude = metres / geo.constants.meters_per_degree_lat;
        const longitude = metres / geo.DistanceApproximator.metersPerLngDegree(point.lat);
        const south = point.lat - latitude;
        const north = point.lat + latitude;
        const west = point.lng - longitude;
        const east = point.lng + longitude;
        if (west < -180 and east > -180) {
            return try self.intersects(south, north, -180, east, deadline) or
                try self.intersects(south, north, west + 360, 180, deadline);
        }
        if (west < 180 and east > 180) {
            return try self.intersects(south, north, west, 180, deadline) or
                try self.intersects(south, north, -180, east - 360, deadline);
        }
        if (north < -90 or south > 90 or east < -180 or west > 180)
            return self.intersects(0, 0, 0, 0, deadline);
        return self.intersects(@max(-90, south), @min(90, north), @max(-180, west), @min(180, east), deadline);
    }

    fn intersects(self: *const Index, south: f64, north: f64, west: f64, east: f64, deadline: Deadline) error{DeadlineExceeded}!bool {
        const bottom = cell(south, 90, rows - 1);
        const top = cell(north, 90, rows - 1);
        const left = cell(west, 180, columns - 1);
        const right = cell(east, 180, columns - 1);
        if (bottom > top or left > right) return false;
        const first = left / 64;
        const last = right / 64;
        const ones: u64 = std.math.maxInt(u64);
        const low = ones << @as(u6, @truncate(left));
        const high = ones >> (63 - @as(u6, @truncate(right)));
        for (self.words[bottom .. top + 1], 0..) |*row, i| {
            if (i % 32 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (first == last) {
                if (row[first] & low & high != 0) return true;
            } else {
                if (row[first] & low != 0 or row[last] & high != 0) return true;
                for (row[first + 1 .. last]) |bits| if (bits != 0) return true;
            }
        }
        return false;
    }
};

fn cell(value: f64, half_range: f64, last: usize) usize {
    // TileList maps an invalid row or column to zero before traversing it.
    if (!std.math.isFinite(value) or value < -half_range or value > half_range) return 0;
    return @min(last, @as(usize, @intFromFloat((value + half_range) * 4)));
}

test "transit availability follows tile boundaries and wraps longitude" {
    const testing = std.testing;
    var index: Index = .{ .words = @splat(@splat(0)) };
    index.mark(.{ .lat = 42.08, .lng = -71.04 });
    index.mark(.{ .lat = 0.1, .lng = -179.98 });
    try testing.expect(try index.available(.{ .lat = 42.24, .lng = -71.249999 }, 0, .none));
    try testing.expect(!try index.available(.{ .lat = 42.24, .lng = -71.250001 }, 0, .none));
    try testing.expect(try index.available(.{ .lat = 42.24, .lng = -71.250001 }, 1, .none));
    try testing.expect(try index.available(.{ .lat = 0.1, .lng = 179.99 }, 2000, .none));
    try testing.expect(!try index.available(.{ .lat = 0, .lng = 0 }, std.math.maxInt(u32), .none));
    try testing.expectError(error.DeadlineExceeded, index.available(.{ .lat = 0, .lng = 0 }, 1, .{ .at_ns = 0 }));
    try testing.expectEqual(null, try Index.init(testing.allocator, null, .none));
}

test "transit coverage requires a scheduled line in the tile" {
    const testing = std.testing;
    const table: transit.View = .{
        .metadata = .{ .start_day = 0 },
        .stops = &.{
            .{ .place = .{ .coordinate = .{ .lat = 10000000, .lng = 10000000 }, .name = .none, .one_stop_id = .none, .graph_node = 0 } },
            .{ .place = .{ .coordinate = .{ .lat = 20000000, .lng = 20000000 }, .name = .none, .one_stop_id = .none, .graph_node = 1 } },
            .{ .place = .{ .coordinate = .{ .lat = 30000000, .lng = 30000000 }, .name = .none, .one_stop_id = .none, .graph_node = 2 } },
        },
        .stations = &.{},
        .egresses = &.{},
        .routes = &.{},
        .lines = &.{.{ .origin = 0, .destination = 1, .route = 0, .departures = .{ .count = 1 } }},
        .departures = &.{.{ .line = 0, .route = 0, .trip = 0, .block = transit.no_id, .schedule = 0, .start_time = 0, .elapsed_time = 60 }},
        .occurrences = &.{},
        .schedules = &.{},
        .days = &.{},
        .exceptions = &.{},
        .transfers = &.{},
        .strings = undefined,
    };
    const index = (try Index.init(testing.allocator, table, .none)).?;
    defer testing.allocator.destroy(index);
    try testing.expect(try index.available(.{ .lat = 1, .lng = 1 }, 0, .none));
    try testing.expect(try index.available(.{ .lat = 2, .lng = 2 }, 0, .none));
    try testing.expect(!try index.available(.{ .lat = 3, .lng = 3 }, 0, .none));
}
