//! Nearest points and discrete interpolation numbers on street geometry.
const std = @import("std");
const io = @import("../infra/io.zig");
const geo = @import("../geo/point.zig");
const constants = @import("../geo/constants.zig");
const math = @import("../geo/libm.zig");
const interpolation = @import("interpolation.zig");

pub fn distance(a: geo.PointLL, b: geo.PointLL) f64 {
    if (a.lat == b.lat and (@abs(a.lat) == 90 or geo.wrappedLongitudeDelta(a.lng, b.lng) == 0)) return 0;
    return a.distance(b);
}

const Projection = struct { fraction: f64, point: geo.PointLL };

pub fn project(origin: geo.PointLL, a: geo.PointLL, b: geo.PointLL, lon_scale: f64) Projection {
    const dx = geo.wrappedLongitudeDelta(b.lng, a.lng);
    const dy = b.lat - a.lat;
    const mid = a.lng + dx * 0.5;
    const position = mid + geo.wrappedLongitudeDelta(origin.lng, mid);
    const scaled_x = dx * lon_scale;
    const square = scaled_x * scaled_x + dy * dy;
    if (square == 0) return .{ .fraction = 0, .point = a };
    const along = (position - a.lng) * lon_scale * scaled_x + (origin.lat - a.lat) * dy;
    if (along <= 0) return .{ .fraction = 0, .point = a };
    if (along >= square) return .{ .fraction = 1, .point = b };
    const fraction = along / square;
    const lon = a.lng + dx * fraction;
    const wrapped = if (lon > 180) lon - 360 else if (lon < -180) lon + 360 else lon;
    return .{ .fraction = fraction, .point = .init(wrapped, a.lat + dy * fraction) };
}

const Vec = @Vector(3, f64);

fn vector(point: geo.PointLL) Vec {
    const lat = point.lat * constants.rad_per_deg_d;
    const lon = point.lng * constants.rad_per_deg_d;
    const scale = math.cosF(lat);
    return .{ scale * math.cosF(lon), scale * math.sinF(lon), math.sinF(lat) };
}

fn arcFraction(query: geo.PointLL, a: geo.PointLL, b: geo.PointLL, length: f64, scale: f64) f64 {
    if (length < 1 or length >= 20_000_000) return project(query, a, b, scale).fraction;
    const angle = length / constants.rad_earth_meters_d;
    const start = vector(a);
    const end = vector(b);
    const point = vector(query);
    const along_start = @reduce(.Add, start * point);
    const along_end = @reduce(.Add, end * point);
    const tangent = (along_end - along_start * math.cosF(angle)) / math.sinF(angle);
    const angle_on_arc = math.atan2F(tangent, along_start);
    if (angle_on_arc < 0 or angle_on_arc > angle) return if (along_start >= along_end) 0 else 1;
    return angle_on_arc / angle;
}

pub const Number = struct {
    number: u32,
    suffix: u8 = 0,

    pub fn text(self: Number, buffer: []u8) ![]const u8 {
        if (self.suffix == 0) return std.fmt.bufPrint(buffer, "{d}", .{self.number});
        return std.fmt.bufPrint(buffer, "{d}{c}", .{ self.number, self.suffix });
    }
};

pub const Match = struct { number: Number, coordinate: geo.PointLL, distance: f64 };

pub fn nearestRange(
    range: interpolation.Range,
    shape: []const geo.FixedLL,
    point: geo.PointLL,
    lon_scale: f64,
    deadline: io.Deadline,
) !?Match {
    const steps = @max(range.first, range.last) - @min(range.first, range.last);
    if (steps <= 1 or shape.len < 2) return null;
    const widths: f64 = @floatFromInt(steps);
    var total: f64 = 0;
    for (shape[0 .. shape.len - 1], shape[1..], 0..) |start, end, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        total += start.toPoint().distance(end.toPoint());
    }
    if (total == 0) return null;
    var before: f64 = 0;
    var best: ?Match = null;
    for (shape[0 .. shape.len - 1], shape[1..], 0..) |start, finish, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const a = start.toPoint();
        const b = finish.toPoint();
        const length = a.distance(b);
        if (length == 0) continue;
        const low = @max(1, @ceil(before / total * widths - 1e-6));
        const high = @min(widths - 1, @floor((before + length) / total * widths + 1e-6));
        if (low <= high) {
            const nearest = (before + length * arcFraction(point, a, b, length, lon_scale)) / total * widths;
            for ([_]f64{ @floor(nearest), @ceil(nearest) }) |candidate| {
                const offset: u32 = @intFromFloat(std.math.clamp(candidate, low, high));
                const position = (@as(f64, @floatFromInt(offset)) / widths * total - before) / length;
                const coordinate = interpolation.along(a, b, length, std.math.clamp(position, 0, 1)).toPoint();
                const gap = distance(point, coordinate);
                const rank = if (range.first < range.last) range.first + offset else range.first - offset;
                const number: Number = switch (range.mode) {
                    .all => .{ .number = rank },
                    .even => .{ .number = rank * 2 },
                    .odd => .{ .number = rank * 2 + 1 },
                    .alphabetic => .{ .number = range.alphabetic_base, .suffix = 'a' + @as(u8, @intCast(rank - 1)) },
                };
                if (best == null or gap < best.?.distance or
                    (gap == best.?.distance and (number.number < best.?.number.number or
                        (number.number == best.?.number.number and number.suffix < best.?.number.suffix))))
                    best = .{ .number = number, .coordinate = coordinate, .distance = gap };
            }
        }
        before += length;
    }
    return best;
}
