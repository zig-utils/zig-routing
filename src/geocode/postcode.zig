//! Postcode keys and centroids from OSM addresses and postal areas.
const std = @import("std");
const geo = @import("../geo/point.zig");
const polygon = @import("../geo/polygon.zig");
const io = @import("../infra/io.zig");

pub const Code = struct {
    storage: [32]u8 = undefined,
    len: u8 = 0,

    pub fn bytes(self: *const Code) []const u8 {
        return self.storage[0..self.len];
    }

    /// Store one postal code. Separators between several codes belong to
    /// the OSM tag reader. Interior hyphens distinguish values such as ZIP+4.
    pub fn normalize(raw: []const u8, iso: []const u8) ?Code {
        if (raw.len > 128) return null;
        var value = std.mem.trim(u8, raw, " \t\r\n");
        if (value.len >= 3 and value[2] == '-' and std.ascii.eqlIgnoreCase(value[0..2], iso)) {
            value = value[3..];
        } else if (value.len >= 2 and value[1] == '-' and std.ascii.toUpper(value[0]) == 'L' and
            std.ascii.eqlIgnoreCase(iso, "LU"))
        {
            value = value[2..];
        }
        var code: Code = .{};
        var final_letter_or_number = false;
        for (value) |byte| {
            if (std.ascii.isWhitespace(byte)) continue;
            if (code.len == code.storage.len) return null;
            if (byte == '-' and final_letter_or_number or std.ascii.isAlphanumeric(byte)) {
                code.storage[code.len] = std.ascii.toUpper(byte);
                code.len += 1;
                final_letter_or_number = byte != '-';
            } else return null;
        }
        return if (final_letter_or_number) code else null;
    }
};

pub const Extent = struct {
    min: geo.FixedLL,
    max: geo.FixedLL,
    /// A western longitude numerically greater than the east crosses the seam.
    pub fn wraps(self: Extent) bool {
        return self.min.lng > self.max.lng;
    }
};

pub const Summary = struct {
    center: geo.FixedLL,
    extent: Extent,
    address_count: u32,
    from_boundary: bool,
};

const Box = struct {
    west: f64 = std.math.inf(f64),
    south: f64 = std.math.inf(f64),
    east: f64 = -std.math.inf(f64),
    north: f64 = -std.math.inf(f64),

    fn add(self: *Box, x: f64, y: f64) void {
        self.west = @min(self.west, x);
        self.south = @min(self.south, y);
        self.east = @max(self.east, x);
        self.north = @max(self.north, y);
    }

    fn fixed(self: Box, longitude: f64) Extent {
        if (self.east - self.west >= 360) return .{
            .min = geo.PointLL.init(-180, self.south).toFixed(),
            .max = geo.PointLL.init(180, self.north).toFixed(),
        };
        return .{
            .min = geo.PointLL.init(wrap(longitude + self.west), self.south).toFixed(),
            .max = geo.PointLL.init(wrap(longitude + self.east), self.north).toFixed(),
        };
    }
};

pub const Accumulator = struct {
    longitude: ?f64 = null,
    point_count: u32 = 0,
    point_x: f64 = 0,
    point_y: f64 = 0,
    point_extent: Box = .{},
    area: f64 = 0,
    area_x: f64 = 0,
    area_y: f64 = 0,
    area_extent: Box = .{},

    fn origin(self: *Accumulator, value: f64) f64 {
        if (self.longitude == null) self.longitude = value;
        return self.longitude.?;
    }

    pub fn addPoint(self: *Accumulator, coordinate: geo.FixedLL) !void {
        if (!coordinate.inRange()) return error.InvalidGeocodeCoordinate;
        const count = try std.math.add(u32, self.point_count, 1);
        const point = coordinate.toPoint();
        const x = geo.wrappedLongitudeDelta(point.lng, self.origin(point.lng));
        self.point_count = count;
        self.point_x += x;
        self.point_y += point.lat;
        self.point_extent.add(x, point.lat);
    }

    pub fn addPolygon(self: *Accumulator, shape: polygon.Polygon, deadline: io.Deadline) !void {
        if (shape.outer.len < 3) return;
        const longitude = self.origin(shape.outer[0].lng);
        const shell = try moments(shape.outer, longitude, deadline);
        var projection = shell;
        for (shape.holes) |hole| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const part = try moments(hole, longitude, deadline);
            projection.area -= part.area;
            projection.x_weight -= part.x_weight;
            projection.y_weight -= part.y_weight;
        }
        if (projection.area <= 0) return;
        const x = projection.x_weight / projection.area;
        const y = projection.y_weight / projection.area;
        // Reject invalid rings whose signed moments do not describe a
        // finite center within the shell's bounds.
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or
            x < shell.bounds.west or x > shell.bounds.east or y < shell.bounds.south or y > shell.bounds.north)
            return;
        self.area += projection.area;
        self.area_x += projection.x_weight;
        self.area_y += projection.y_weight;
        self.area_extent.add(shell.bounds.west, shell.bounds.south);
        self.area_extent.add(shell.bounds.east, shell.bounds.north);
    }

    pub fn summary(self: Accumulator) ?Summary {
        const longitude = self.longitude orelse return null;
        const boundary = self.area > 0;
        if (!boundary and self.point_count == 0) return null;
        const weight: f64 = if (boundary) self.area else @floatFromInt(self.point_count);
        const box = if (boundary) self.area_extent else self.point_extent;
        const x = std.math.clamp((if (boundary) self.area_x else self.point_x) / weight, box.west, box.east);
        const y = std.math.clamp((if (boundary) self.area_y else self.point_y) / weight, box.south, box.north);
        return .{
            .center = geo.PointLL.init(wrap(longitude + x), y).toFixed(),
            .extent = box.fixed(longitude),
            .address_count = self.point_count,
            .from_boundary = boundary,
        };
    }
};

fn wrap(longitude: f64) f64 {
    return if (longitude < -180) longitude + 360 else if (longitude > 180) longitude - 360 else longitude;
}

const Moments = struct {
    area: f64 = 0,
    x_weight: f64 = 0,
    y_weight: f64 = 0,
    bounds: Box = .{},
};

fn moments(ring: polygon.Ring, longitude: f64, deadline: io.Deadline) !Moments {
    if (ring.len < 3) return .{};
    const base_x = geo.wrappedLongitudeDelta(ring[0].lng, longitude);
    const base_y = ring[0].lat;
    var area: f64 = 0;
    var x_weight: f64 = 0;
    var y_weight: f64 = 0;
    var box: Box = .{};
    var a_x: f64 = 0;
    var a_y: f64 = 0;
    box.add(base_x, base_y);
    for (ring[1..], 0..) |point, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const x = geo.wrappedLongitudeDelta(point.lng, longitude);
        const y = point.lat;
        const b_x = x - base_x;
        const b_y = y - base_y;
        const twice = a_x * b_y - a_y * b_x;
        area += twice;
        x_weight += (a_x + b_x) * twice;
        y_weight += (a_y + b_y) * twice;
        box.add(x, y);
        a_x = b_x;
        a_y = b_y;
    }
    const sign: f64 = if (area < 0) -1 else 1;
    return .{
        .area = @abs(area),
        .x_weight = base_x * @abs(area) + sign * x_weight / 3,
        .y_weight = base_y * @abs(area) + sign * y_weight / 3,
        .bounds = box,
    };
}

test "postal codes normalize country prefixes and meaningful separators" {
    const t = std.testing;
    const lu = Code.normalize("L- 1240", "LU").?;
    const uk = Code.normalize(" sw1a 1aa ", "GB").?;
    const us = Code.normalize("US-12345-1234", "US").?;
    try t.expectEqualStrings("1240", lu.bytes());
    try t.expectEqualStrings("SW1A1AA", uk.bytes());
    try t.expectEqualStrings("12345-1234", us.bytes());
    try t.expectEqual(null, Code.normalize("1234;1235", "LU"));
    try t.expectEqual(null, Code.normalize("1--3", "US"));
}

test "postcode areas weight polygon shells and holes while point means cross the antimeridian" {
    const t = std.testing;
    const p = geo.PointLL.init;
    var points: Accumulator = .{};
    try points.addPoint(p(179, 1).toFixed());
    try points.addPoint(p(-179, 3).toFixed());
    const addresses = points.summary().?;
    try t.expectEqual(p(180, 2).toFixed(), addresses.center);
    try t.expect(addresses.extent.wraps());
    try t.expectEqual(2, addresses.address_count);
    try t.expect(!addresses.from_boundary);

    var polygonal: Accumulator = .{};
    try polygonal.addPoint(p(0, 0).toFixed());
    const shell = [_]geo.PointLL{ p(0, 0), p(6, 0), p(6, 6), p(0, 6) };
    const hole = [_]geo.PointLL{ p(4, 2), p(5, 2), p(5, 4), p(4, 4) };
    try polygonal.addPolygon(.{ .outer = &shell, .holes = &.{&hole} }, .none);
    const area = polygonal.summary().?;
    try t.expect(area.from_boundary);
    try t.expectEqual(p(99.0 / 34.0, 3).toFixed(), area.center);
    try t.expectEqual(p(0, 0).toFixed(), area.extent.min);
    try t.expectEqual(p(6, 6).toFixed(), area.extent.max);
}
