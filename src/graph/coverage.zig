//! Regional coverage in the same E7 coordinates as the graph.
const std = @import("std");
const point = @import("../geo/point.zig");
const Deadline = @import("../infra/io.zig").Deadline;

const half_turn: i32 = 1_800_000_000;
const turn: u32 = 3_600_000_000;
const pole: i32 = 900_000_000;

/// West greater than east denotes an interval crossing the antimeridian.
pub const Bounds = extern struct {
    west: i32,
    south: i32,
    east: i32,
    north: i32,

    pub fn valid(self: Bounds) bool {
        return @abs(self.west) <= half_turn and @abs(self.east) <= half_turn and
            self.south >= -pole and self.north <= pole and self.south <= self.north;
    }

    pub fn contains(self: Bounds, p: point.FixedLL) bool {
        if (@abs(p.lng) > half_turn or p.lat < self.south or p.lat > self.north) return false;
        return self.containsLongitude(p.lng) or (@abs(p.lng) == half_turn and self.containsLongitude(-p.lng));
    }

    fn containsLongitude(self: Bounds, lon: i32) bool {
        return if (self.west <= self.east)
            self.west <= lon and lon <= self.east
        else
            lon >= self.west or lon <= self.east;
    }
};

comptime {
    std.debug.assert(@sizeOf(Bounds) == 16);
    std.debug.assert(@offsetOf(Bounds, "west") == 0 and @offsetOf(Bounds, "south") == 4);
    std.debug.assert(@offsetOf(Bounds, "east") == 8 and @offsetOf(Bounds, "north") == 12);
}

pub const Builder = struct {
    bounds: Bounds = .{ .west = half_turn, .south = pole, .east = -half_turn, .north = -pole },
    shifted_west: u32 = turn,
    shifted_east: u32 = 0,

    pub fn add(self: *Builder, points: []const point.FixedLL, deadline: Deadline) !void {
        return self.include(points, false, deadline);
    }

    pub fn addShape(self: *Builder, points: []const point.FixedLL, deadline: Deadline) !void {
        return self.include(points, true, deadline);
    }

    fn include(self: *Builder, points: []const point.FixedLL, comptime shape: bool, deadline: Deadline) !void {
        for (points, 0..) |p, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (!p.inRange()) return error.InvalidCoordinate;
            self.bounds.south = @min(self.bounds.south, p.lat);
            self.bounds.north = @max(self.bounds.north, p.lat);
            self.bounds.west = @min(self.bounds.west, p.lng);
            self.bounds.east = @max(self.bounds.east, p.lng);
            const shifted = shift(p.lng);
            self.shifted_west = @min(self.shifted_west, shifted);
            self.shifted_east = @max(self.shifted_east, shifted);
            if (shape and i != 0) {
                // An edge follows the short arc. An interval in a coordinate
                // chart must span that chart if the edge crosses its seam.
                const last = points[i - 1].lng;
                if (@abs(@as(i64, p.lng) - last) > half_turn) {
                    self.bounds.west = -half_turn;
                    self.bounds.east = half_turn;
                }
                if (@abs(@as(i64, shifted) - shift(last)) > half_turn) {
                    self.shifted_west = 0;
                    self.shifted_east = turn;
                }
            }
        }
    }

    pub fn finish(self: Builder) ?Bounds {
        if (self.bounds.south > self.bounds.north) return null;
        var result = self.bounds;
        const width: u32 = @intCast(@as(i64, result.east) - result.west);
        if (self.shifted_east - self.shifted_west < width) {
            result.west = signed(self.shifted_west);
            result.east = signed(self.shifted_east);
        }
        return result;
    }

    fn signed(lon: u32) i32 {
        return @intCast(if (lon > half_turn) @as(i64, lon) - turn else lon);
    }

    fn shift(lon: i32) u32 {
        return @intCast(if (lon < 0) @as(i64, lon) + turn else lon);
    }
};

test "coverage uses the shorter antimeridian interval and includes its endpoints" {
    var builder: Builder = .{};
    try std.testing.expectEqual(@as(?Bounds, null), builder.finish());
    try builder.addShape(&.{ .{ .lng = 1_790_000_000, .lat = -1 }, .{ .lng = -1_780_000_000, .lat = 1 } }, .none);
    const box = builder.finish().?;
    try std.testing.expect(box.valid());
    try std.testing.expectEqual(@as(i32, 1_790_000_000), box.west);
    try std.testing.expect(box.contains(.{ .lng = -half_turn, .lat = 0 }));
    try std.testing.expect(box.contains(.{ .lng = half_turn, .lat = 0 }));
    try std.testing.expect(box.contains(.{ .lng = -1_780_000_000, .lat = 1 }));
    try std.testing.expect(!box.contains(.{ .lng = 0, .lat = 0 }));
    try std.testing.expect(!box.contains(.{ .lng = -half_turn, .lat = 2 }));
}
