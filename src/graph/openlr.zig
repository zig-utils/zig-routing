// Ported from valhalla/baldr/openlr.h and src/tyr/locate_serializer.cc
// (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/root.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const EdgeClass = @import("class_table.zig").EdgeClass;
const constants = @import("constants.zig");

pub const max_encoded_bytes = 24;
const full_circle: f64 = 16777216;
const Encoder = std.base64.standard.Encoder;

/// Two location reference points for a position along a directed edge.
/// The caller supplies the shape in travel order.
pub fn pointAlongEdge(out: *[max_encoded_bytes]u8, shape: []const geo.PointLL, class: EdgeClass, length: u24, fraction: f32, deadline: Deadline) ![]const u8 {
    if (shape.len < 2) return error.IncompleteShape;
    const first = shape[0];
    const last = shape[shape.len - 1];
    const fow = formOfWay(class);
    const frc: u8 = class.category.road_class;
    const forward = try geo.line.tangentAngle(shape, 0, first, 20, true, deadline);
    const reverse = try geo.line.tangentAngle(shape, shape.len - 2, last, 20, false, deadline);
    var bytes: [17]u8 = undefined;
    bytes[0] = 0x2b;
    const lng = roundTripCoordinate(first.lng);
    const lat = roundTripCoordinate(first.lat);
    std.mem.writeInt(i24, bytes[1..4], @truncate(absoluteCoordinate(lng)), .big);
    std.mem.writeInt(i24, bytes[4..7], @truncate(absoluteCoordinate(lat)), .big);
    bytes[7] = 0x40 | (frc << 3) | fow;
    bytes[8] = (frc << 5) | bearing(forward);
    const dnp = @trunc(@as(f64, @floatFromInt(length)) / 58.6) * 58.6;
    bytes[9] = @truncate(@as(u32, @intFromFloat(dnp / 58.6)));
    std.mem.writeInt(i16, bytes[10..12], relativeCoordinate(lng, last.lng), .big);
    std.mem.writeInt(i16, bytes[12..14], relativeCoordinate(lat, last.lat), .big);
    bytes[14] = (frc << 3) | fow;
    const offset: u8 = @intFromFloat(@min(255, fraction * 255 + 0.5));
    bytes[15] = (if (offset != 0) @as(u8, 0x40) else 0) | bearing(reverse);
    bytes[16] = offset;
    return Encoder.encode(out, bytes[0 .. 16 + @as(usize, @intFromBool(offset != 0))]);
}

fn absoluteCoordinate(value: f64) i32 {
    return @intFromFloat(value * full_circle / 360 + sign(value) * 0.5);
}

fn roundTripCoordinate(value: f64) f64 {
    const quantized: f64 = @floatFromInt(absoluteCoordinate(value));
    return (quantized - sign(quantized) * 0.5) * 360 / full_circle;
}

fn relativeCoordinate(from: f64, to: f64) i16 {
    const normalized = from + @round((to - from) * 100_000) / 100_000;
    return @truncate(@as(i32, @intFromFloat(@round((normalized - from) * 100_000))));
}

fn sign(value: f64) f64 {
    return if (value > 0) 1 else if (value < 0) -1 else 0;
}

fn bearing(value: f32) u8 {
    return @as(u8, @truncate(@as(u32, @intFromFloat(@as(f64, value) / 11.25)))) & 0x1f;
}

fn formOfWay(class: EdgeClass) u8 {
    if (class.category.road_class == @backingInt(constants.RoadClass.motorway)) return 1;
    if (class.flags.roundabout) return 4;
    if (class.category.use == @backingInt(constants.Use.ramp) or class.category.use == @backingInt(constants.Use.turn_channel)) return 6;
    const vehicles: u16 = @bitCast(constants.AccessMask{ .auto = true, .truck = true, .moped = true, .motorcycle = true, .taxi = true, .bus = true, .hov = true });
    const forward = class.access.forward & vehicles != 0;
    const reverse = class.access.reverse & vehicles != 0;
    return if (forward and reverse) 2 else if (forward or reverse) 3 else 7;
}

test "Utrecht point-along-line matches the pinned locate reference" {
    const shape = [_]geo.PointLL{
        .init(5.113830, 52.080620),
        .init(5.113823, 52.080556),
        .init(5.115404, 52.078858),
    };
    const class: EdgeClass = .{
        .category = .{ .road_class = @backingInt(constants.RoadClass.residential) },
        .access = .{ .forward = 1 },
    };
    var encoded: [max_encoded_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "KwOi8iUI/XPOAwCe/1AzXfM=",
        try pointAlongEdge(&encoded, &shape, class, 225, 0.95318586, .none),
    );
}
