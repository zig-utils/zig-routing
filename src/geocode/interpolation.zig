//! Position estimates for OSM address interpolation ways.
const std = @import("std");
const geo = @import("../geo/point.zig");
const io = @import("../infra/io.zig");
const house = @import("house_number.zig");

pub const Mode = enum(u2) {
    all,
    even,
    odd,
    alphabetic,

    pub fn fromTag(value: []const u8) ?Mode {
        return modes.get(value);
    }

    pub fn endpointRank(self: Mode, label: house.Label) ?u32 {
        if (label.last != null or label.unit.len != 0) return null;
        return self.rank(label.first);
    }

    fn rank(self: Mode, key: house.Key) ?u32 {
        if (key.fraction.numerator != 0) return null;
        return switch (self) {
            .all => if (key.letters.len == 0) key.number else null,
            .even => if (key.letters.len == 0 and key.number % 2 == 0) key.number / 2 else null,
            .odd => if (key.letters.len == 0 and key.number % 2 != 0) key.number / 2 else null,
            .alphabetic => switch (key.letters.len) {
                0 => 0,
                1 => if (std.ascii.isAlphabetic(key.letters[0])) std.ascii.toLower(key.letters[0]) - 'a' + 1 else null,
                else => null,
            },
        };
    }
};

const modes = std.StaticStringMap(Mode).initComptime(.{
    .{ "all", .all },
    .{ "even", .even },
    .{ "odd", .odd },
    .{ "alphabetic", .alphabetic },
});

pub const Range = struct {
    mode: Mode,
    first: u32,
    last: u32,
    alphabetic_base: u32 = 0,

    pub fn init(mode: Mode, first: house.Label, last: house.Label) ?Range {
        const start = mode.endpointRank(first) orelse return null;
        const end = mode.endpointRank(last) orelse return null;
        if (start == end or (mode == .alphabetic and first.first.number != last.first.number)) return null;
        return .{
            .mode = mode,
            .first = start,
            .last = end,
            .alphabetic_base = if (mode == .alphabetic) first.first.number else 0,
        };
    }

    pub fn fraction(self: Range, requested: house.Label) ?f64 {
        if (self.mode == .alphabetic and requested.first.number != self.alphabetic_base) return null;
        const rank = self.mode.endpointRank(requested) orelse return null;
        // Endpoint nodes already supply exact addresses.
        if (rank <= @min(self.first, self.last) or rank >= @max(self.first, self.last)) return null;
        const offset: f64 = @floatFromInt(@as(i64, rank) - self.first);
        const width: f64 = @floatFromInt(@as(i64, self.last) - self.first);
        return offset / width;
    }

    pub fn locate(self: Range, label: house.Label, shape: []const geo.FixedLL, deadline: io.Deadline) !?Estimate {
        const t = self.fraction(label) orelse return null;
        const coordinate = try pointAt(shape, t, deadline) orelse return null;
        return .{ .coordinate = coordinate };
    }
};

pub const Estimate = struct {
    coordinate: geo.FixedLL,
    approximate: bool = true,
};

pub fn pointAt(shape: []const geo.FixedLL, fraction: f64, deadline: io.Deadline) !?geo.FixedLL {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (shape.len < 2 or !std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return null;
    if (!shape[0].inRange()) return error.InvalidGeocodeCoordinate;
    var total: f64 = 0;
    var a = shape[0].toPoint();
    for (shape[1..], 0..) |end, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!end.inRange()) return error.InvalidGeocodeCoordinate;
        const b = end.toPoint();
        total += a.distance(b);
        a = b;
    }
    if (total == 0) return null;

    var remaining = fraction * total;
    a = shape[0].toPoint();
    for (shape[1..], 0..) |end, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const b = end.toPoint();
        const length = a.distance(b);
        if (length > 0 and remaining <= length) {
            const t = remaining / length;
            return along(a, b, length, t);
        }
        remaining -= length;
        a = b;
    }
    return shape[shape.len - 1];
}

pub fn along(a: geo.PointLL, b: geo.PointLL, length: f64, fraction: f64) geo.FixedLL {
    // Very short segments can round to a zero central angle.
    if (length >= 1 and length < 20_000_000) return a.pointAlongSegment(b, fraction).toFixed();
    const lng = a.lng + geo.wrappedLongitudeDelta(b.lng, a.lng) * fraction;
    const wrapped = if (lng > 180) lng - 360 else if (lng < -180) lng + 360 else lng;
    return geo.PointLL.init(wrapped, a.lat + (b.lat - a.lat) * fraction).toFixed();
}

test "all OSM interpolation modes locate addresses along the entire way" {
    const t = std.testing;
    const coordinates = [_]geo.FixedLL{
        geo.PointLL.init(0, 0).toFixed(),
        geo.PointLL.init(0.001, 0).toFixed(),
        geo.PointLL.init(0.001, 0.001).toFixed(),
    };
    const cases = [_]struct { mode: Mode, first: []const u8, last: []const u8, query: []const u8 }{
        .{ .mode = .all, .first = "1", .last = "5", .query = "4" },
        .{ .mode = .even, .first = "2", .last = "10", .query = "8" },
        .{ .mode = .odd, .first = "17", .last = "9", .query = "11" },
        .{ .mode = .alphabetic, .first = "25", .last = "25D", .query = "25c" },
    };
    const expected = geo.PointLL.init(0.001, 0.0005);
    for (cases) |sample| {
        const range = Range.init(sample.mode, try house.parse(sample.first, ""), try house.parse(sample.last, "")).?;
        const located = (try range.locate(try house.parse(sample.query, ""), &coordinates, .none)).?;
        try t.expect(located.approximate);
        try t.expect(located.coordinate.toPoint().distance(expected) < 10);
        try t.expectEqual(null, try range.locate(try house.parse(sample.first, ""), &coordinates, .none));
        try t.expectError(error.DeadlineExceeded, range.locate(try house.parse(sample.query, ""), &coordinates, .fromNow(0)));
    }
    try t.expectEqual(null, Range.init(.even, try house.parse("3", ""), try house.parse("10", "")));
    try t.expectEqual(null, Range.init(.alphabetic, try house.parse("25a", ""), try house.parse("26d", "")));
}
