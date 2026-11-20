// Ported from src/baldr/nodeinfo.cc and src/mjolnir/util.cc (Valhalla 3.9.3).
const point = @import("../geo/point.zig");
const math = @import("../geo/build_math.zig");
const io = @import("../infra/io.zig");
const constants = @import("constants.zig");
const EdgeClass = @import("class_table.zig").EdgeClass;

pub fn encode(degrees: u16) u8 {
    const shrink: f32 = 255.0 / 359.0;
    return @intFromFloat(@round(@as(f32, @floatFromInt(degrees % 360)) * shrink));
}

pub fn decode(encoded: u8) u16 {
    const expand: f32 = 359.0 / 255.0;
    return @intFromFloat(@round(@as(f32, @floatFromInt(encoded)) * expand));
}

pub fn sample(points: []const point.FixedLL, forward: bool, class: *const EdgeClass, deadline: io.Deadline) !u16 {
    if (points.len < 2) return error.InvalidSegmentShape;
    const distance = constants.headingOffset(class.category.road_class, class.category.use);
    // GraphEnhancer reads the shape after the E6 tile encoding.
    const start = points[if (forward) 0 else points.len - 1].toTilePoint();
    var target = points[if (forward) points.len - 1 else 0].toTilePoint();
    var previous = start;
    var travelled: f64 = 0;
    for (1..points.len) |i| {
        if (points.len == 2 or travelled >= distance) break;
        if ((i - 1) % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const next = points[if (forward) i else points.len - 1 - i].toTilePoint();
        const length = previous.distanceWith(next, math);
        if (travelled + length > distance) {
            const fraction = (distance - travelled) / length;
            target = .{
                .lng = previous.lng + (next.lng - previous.lng) * fraction,
                .lat = previous.lat + (next.lat - previous.lat) * fraction,
            };
            break;
        }
        travelled += length;
        previous = next;
    }
    return @as(u16, @intFromFloat(@round(start.headingWith(target, math)))) % 360;
}
