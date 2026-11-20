// Ported from src/worker.cc and src/loki/polygon_search.cc (Valhalla 3.9.3).
const std = @import("std");
const json = @import("json.zig");
const errors = @import("errors.zig");
const io = @import("../infra/io.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_exclude_locations: usize = 50,
    max_exclude_polygons_length: f32 = 10_000,
    max_exclude_polygons_vertices: usize = 100,
};

pub const Ring = struct {
    points: []const PointLL,
    levels: []const f32 = &.{},

    pub fn segmentCount(self: Ring) usize {
        if (self.points.len < 2) return 0;
        return self.points.len - @intFromBool(self.points[0].eql(self.points[self.points.len - 1]));
    }
};

pub const Parsed = union(enum) {
    rings: []const Ring,
    warning,
    failure: errors.Failure,
};

const Error = Allocator.Error || error{DeadlineExceeded};

pub noinline fn parse(arena: Allocator, root: json.Value, comptime clamp: fn (f64, f64, f64) f64, deadline: io.Deadline) Error!Parsed {
    if (root != .object) return .{ .rings = &.{} };
    const raw = root.object.get("avoid_polygons") orelse root.object.get("exclude_polygons") orelse return .{ .rings = &.{} };
    const features = switch (raw) {
        .array => raw.array.items,
        .object => blk: {
            const kind = json.getOptional([]const u8, raw, "/type") orelse return .warning;
            if (!std.mem.eql(u8, kind, "FeatureCollection")) return .warning;
            break :blk json.array(raw, "/features") orelse return .warning;
        },
        else => return .warning,
    };
    var rings: std.ArrayList(Ring) = .empty;
    for (features) |feature| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const coords = switch (feature) {
            .array => feature.array.items,
            .object => blk: {
                if (feature.object.count() == 0) continue;
                const kind = json.getOptional([]const u8, feature, "/geometry/type") orelse return missingCoordinates();
                if (!std.mem.eql(u8, kind, "Polygon")) return missingCoordinates();
                break :blk json.array(feature, "/geometry/coordinates/0") orelse return missingCoordinates();
            },
            else => continue,
        };
        if (coords.len == 0) continue;
        const points = try arena.alloc(PointLL, coords.len);
        for (coords, points, 0..) |pair, *point, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (pair != .array or pair.array.items.len < 2) return invalidCoordinates();
            const lng = number(pair.array.items[0]) orelse return invalidCoordinates();
            const lat = number(pair.array.items[1]) orelse return invalidCoordinates();
            if (lat < -90 or lat > 90) return .{ .failure = .{ .code = 137, .extra = "Latitude must be in the range [-90, 90] degrees" } };
            point.* = .init(clamp(lng, -180, 180), lat);
            if (!point.inRange()) return invalidCoordinates();
        }
        var levels: std.ArrayList(f32) = .empty;
        for (json.array(feature, "/properties/levels") orelse &.{}, 0..) |level, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (level == .float and @abs(level.float) <= std.math.floatMax(f32)) {
                try levels.append(arena, @floatCast(level.float));
            }
        }
        try rings.append(arena, .{ .points = points, .levels = levels.items });
    }
    return .{ .rings = rings.items };
}

fn number(value: json.Value) ?f64 {
    const result = switch (value) {
        .integer, .float, .number_string => json.convert(f64, value) orelse return null,
        else => return null,
    };
    return if (std.math.isFinite(result)) result else null;
}

fn missingCoordinates() Parsed {
    return .{ .failure = .{ .code = 137, .extra = "Expected object to have coordinates member" } };
}

fn invalidCoordinates() Parsed {
    return .{ .failure = .{ .code = 137, .extra = "Polygon coordinates must consist of [Lon, Lat] arrays." } };
}

pub noinline fn validate(arena: Allocator, limits: Limits, rings: []const Ring, locations: usize, deadline: io.Deadline) Error!?errors.Failure {
    var circumference: f64 = 0;
    var vertices: usize = 0;
    for (rings) |ring| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const segments = ring.segmentCount();
        for (0..segments) |i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const a = ring.points[i];
            const b = ring.points[if (i + 1 == ring.points.len) 0 else i + 1];
            if (@abs(a.lng - b.lng) > 180) return .{ .code = 177 };
            circumference += a.distance(b);
        }
        vertices +|= if (segments == 0) ring.points.len else segments + 1;
    }
    if (circumference > limits.max_exclude_polygons_length) {
        const meters: f64 = @trunc(limits.max_exclude_polygons_length);
        return .{ .code = 167, .extra = try std.fmt.allocPrint(arena, "{d:.0} meters", .{meters}) };
    }
    if (vertices > limits.max_exclude_polygons_vertices) {
        return .{ .code = 176, .extra = try std.fmt.allocPrint(arena, "{d}", .{limits.max_exclude_polygons_vertices}) };
    }
    if (locations > limits.max_exclude_locations) {
        return .{ .code = 157, .extra = try std.fmt.allocPrint(arena, "{d}", .{limits.max_exclude_locations}) };
    }
    return null;
}
