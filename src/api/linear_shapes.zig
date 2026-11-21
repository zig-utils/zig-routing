// Ported from parse_line_geojson and parse_line in src/worker.cc (Valhalla 3.9.3).
const std = @import("std");
const json = @import("json.zig");
const errors = @import("errors.zig");
const polyline = @import("../geo/polyline.zig");
const Point = @import("../geo/point.zig").PointLL;
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;

pub const Feature = struct {
    points: []const Point,
    factor: f32 = 1,
    allow: bool = false,
};

pub const Parsed = union(enum) {
    features: []const Feature,
    warning,
    failure: errors.Failure,
};

pub fn parse(a: Allocator, value: json.Value, deadline: Deadline) (Allocator.Error || error{DeadlineExceeded})!Parsed {
    if (value != .array) return .warning;
    const features = try a.alloc(Feature, value.array.items.len);
    for (value.array.items, features) |item, *feature| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (item != .object) return invalid("feature must be an object");
        var props = item;
        var points: std.ArrayList(Point) = .empty;
        if (item.object.contains("type")) {
            const coordinates = json.array(item, "/geometry/coordinates") orelse return invalid("feature coordinates must be an array");
            try points.ensureTotalCapacity(a, coordinates.len);
            for (coordinates, 0..) |coordinate, i| {
                if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (coordinate != .array or coordinate.array.items.len < 2) return invalid("feature coordinates must contain longitude and latitude");
                const lng = number(coordinate.array.items[0]) orelse return invalid("invalid feature longitude");
                const lat = number(coordinate.array.items[1]) orelse return invalid("invalid feature latitude");
                points.appendAssumeCapacity(.init(lng, lat));
            }
            props = item.object.get("properties") orelse .null;
        } else {
            const encoded = json.getOptional([]const u8, item, "/shape") orelse return invalid("feature shape must be an encoded polyline");
            var decoder = polyline.Decoder(.polyline).initPrecision(encoded, 1e-6);
            while (true) {
                if (points.items.len % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const point = (decoder.next() catch return invalid("invalid encoded feature shape")) orelse break;
                try points.append(a, point);
            }
        }
        if (points.items.len == 0) return invalid("feature coordinates are empty");
        feature.* = .{ .points = points.items };
        if (props == .object) if (props.object.get("factor")) |factor| {
            feature.factor = number(factor) orelse return invalid("invalid feature factor");
        };
        for (json.array(props, "/allow_types") orelse &.{}, 0..) |allow, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (allow == .string and std.mem.eql(u8, allow.string, "all")) {
                feature.allow = true;
                break;
            }
        }
    }
    return .{ .features = features };
}

fn invalid(message: []const u8) Parsed {
    return .{ .failure = .{ .code = 173, .extra = message } };
}

fn number(value: json.Value) ?f32 {
    return switch (value) {
        .float, .integer, .number_string => {
            const result = json.convert(f32, value) orelse return null;
            return if (std.math.isFinite(result)) result else null;
        },
        else => null,
    };
}
