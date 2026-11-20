// Ported from valhalla/baldr/graphtile.h and valhalla/baldr/traffictile.h (Valhalla 3.9.3).
const std = @import("std");
const format = @import("format.zig");
const Deadline = @import("../infra/io.zig").Deadline;

pub const max_traffic_kph: u8 = 252;
pub const unknown_traffic_speed: u7 = 127;
pub const seconds_per_day = 24 * 60 * 60;
pub const seconds_per_week = 7 * seconds_per_day;
pub const seconds_per_bucket = 5 * 60;
pub const Bucket = u11;

pub const Flow = packed struct(u8) {
    freeflow: bool = false,
    constrained: bool = false,
    predicted: bool = false,
    current: bool = false,
    reserved: u4 = 0,

    pub const all: Flow = .{ .freeflow = true, .constrained = true, .predicted = true, .current = true };
};

pub const Time = struct {
    seconds_of_week: u64,
    seconds_from_now: u64 = 0,

    pub fn fromTimeInfo(info: @import("time_info.zig").TimeInfo) ?Time {
        if (!info.valid) return null;
        return .{ .seconds_of_week = info.second_of_week, .seconds_from_now = @abs(info.seconds_from_now) };
    }
};

pub const Query = struct {
    flow: Flow = .all,
    time: ?Time = null,
    truck: bool = false,
};

/// Decoded fields needed to blend the live speed with the next source.
/// Traffic readers supply these observations in Phase 10.
pub const Live = struct {
    overall: u7,
    segments: [3]u7,
    breakpoints: [2]u8,

    pub fn closed(self: Live) bool {
        return self.breakpoints[0] != 0 and self.overall == 0;
    }

    fn coverage(self: Live) ?f32 {
        const first, const second = self.breakpoints;
        if (self.overall == 0 or self.overall == unknown_traffic_speed or first == 0) return null;
        if (first == 255) return 1;
        if (second < first) return null;
        const known = self.segments;
        const covered = (if (known[0] != unknown_traffic_speed) first else 0) +
            (if (known[1] != unknown_traffic_speed) second - first else 0) +
            (if (known[2] != unknown_traffic_speed) 255 - second else 0);
        return @floatCast(@as(f64, @floatFromInt(covered)) / 255);
    }
};

/// Default provider. An overlay implements these methods with the same signatures.
pub const NoOverlays = struct {
    pub fn live(_: NoOverlays, _: format.EdgeId) ?Live {
        return null;
    }

    pub fn predicted(_: NoOverlays, _: format.EdgeId, _: Bucket) ?f32 {
        return null;
    }
};

pub const Result = struct {
    kph: u8,
    sources: Flow = .{},
    closed: bool = false,
};

fn blend(current: u8, fraction: f32, fallback: f32) u8 {
    const live_kph: f32 = @floatFromInt(current);
    return @intFromFloat(live_kph * fraction + (1 - fraction) * fallback);
}

inline fn staticSpeed(edge: format.EdgeHot, flow: Flow, time: ?Time) Result {
    const daytime = if (time) |present| blk: {
        const seconds = present.seconds_of_week % seconds_per_day;
        break :blk 7 * 3600 < seconds and seconds < 19 * 3600;
    } else false;
    if ((time == null or daytime) and flow.constrained and edge.speed[2] != 0)
        return .{ .kph = edge.speed[2], .sources = .{ .constrained = true } };
    if (!daytime and flow.freeflow and edge.speed[1] != 0)
        return .{ .kph = edge.speed[1], .sources = .{ .freeflow = true } };
    return .{ .kph = edge.speed[0] };
}

fn capBaseTruck(result: *Result, truck_kph: u8) void {
    if (truck_kph != 0 and !result.sources.constrained and !result.sources.freeflow)
        result.kph = @min(result.kph, truck_kph);
}

pub inline fn untimed(edge: format.EdgeHot, flow: Flow, truck: bool) Result {
    var result = staticSpeed(edge, flow, null);
    if (truck) capBaseTruck(&result, edge.speed[3]);
    return result;
}

pub fn resolve(edge: format.EdgeHot, id: format.EdgeId, query: Query, overlays: anytype) Result {
    const observation = if (query.flow.current) overlays.live(id) else null;
    const closed = if (observation) |live| live.closed() else false;
    var sources: Flow = .{};
    var current: u8 = 0;
    var fraction: f32 = 0;
    if (query.time) |time| {
        if (observation) |live| {
            if (time.seconds_from_now < 3600) {
                if (live.coverage()) |coverage| {
                    const age: f64 = @floatFromInt(time.seconds_from_now);
                    const fade: f32 = @floatCast(1 - age * (@as(f64, 1) / 3600));
                    fraction = coverage * fade;
                    current = @as(u8, live.overall) << 1;
                    sources.current = true;
                    if (fraction == 1) return .{ .kph = current, .sources = sources, .closed = closed };
                }
            }
        }
        if (query.flow.predicted and edge.cls.pred_speed != 0) {
            const bucket: Bucket = @intCast((time.seconds_of_week % seconds_per_week) / seconds_per_bucket);
            if (overlays.predicted(id, bucket)) |predicted| {
                // Keep overlay data inside the speed range used by the metric.
                if (std.math.isFinite(predicted) and predicted <= max_traffic_kph) {
                    const rounded = @max(predicted, 0.5) + 0.5;
                    sources.predicted = true;
                    return .{ .kph = blend(current, fraction, rounded), .sources = sources, .closed = closed };
                }
            }
        }
    }
    var result = staticSpeed(edge, query.flow, query.time);
    if (fraction != 0) result.kph = blend(current, fraction, @floatFromInt(result.kph));
    if (query.truck) capBaseTruck(&result, edge.speed[3]);
    result.sources.current = sources.current;
    result.closed = closed;
    return result;
}

/// Overlay samples can be replaced independently of the bundle. Their
/// maximum is part of the bound even when no overlay is currently present.
pub fn upperBound(edge: format.EdgeHot) u8 {
    return @max(max_traffic_kph, edge.speed[0], edge.speed[1], edge.speed[2]);
}

pub noinline fn writeBounds(writer: *format.BundleWriter, edges: []const format.EdgeHot) !void {
    try writer.stream(.lb_speeds, edges, streamBounds);
}

pub noinline fn verifyBounds(edges: []const format.EdgeHot, bounds: []const u8, deadline: Deadline) !void {
    if (bounds.len != edges.len) return error.InvalidSpeedBoundCount;
    for (bounds, edges, 0..) |bound, hot, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (bound != upperBound(hot)) return error.InvalidSpeedBound;
    }
}

fn streamBounds(edges: []const format.EdgeHot, writer: *format.SectionWriter(.lb_speeds)) !void {
    var values: [16 * 1024]u8 = undefined;
    var remaining = edges;
    while (remaining.len != 0) {
        if (writer.deadline().expired()) return error.DeadlineExceeded;
        const count = @min(remaining.len, values.len);
        for (remaining[0..count], values[0..count]) |edge, *bound| bound.* = upperBound(edge);
        try writer.append(values[0..count]);
        remaining = remaining[count..];
    }
}

const test_edge: format.EdgeHot = .{
    .head = 0,
    .geom = .{ .len_m = 100, .grade = 6, .curvature = 0 },
    .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 1 },
    .speed = .{ 40, 60, 30, 20 },
};
const test_id: format.EdgeId = @fromBackingInt(17);

const TestOverlay = struct {
    traffic: ?Live = null,
    forecast: ?f32 = null,
    now_bucket: ?Bucket = null,

    pub fn live(self: TestOverlay, id: format.EdgeId) ?Live {
        std.debug.assert(id == test_id);
        return self.traffic;
    }

    pub fn predicted(self: TestOverlay, id: format.EdgeId, bucket: Bucket) ?f32 {
        std.debug.assert(id == test_id);
        if (self.now_bucket) |wanted| if (wanted != bucket) return null;
        return self.forecast;
    }
};

// Ported from test/predictive_traffic.cc.
test "speed resolution observes each source mask and the open daytime interval" {
    try std.testing.expectEqual(@as(?Time, null), Time.fromTimeInfo(.{}));
    try std.testing.expectEqual(@as(?Time, .{ .seconds_of_week = 25200, .seconds_from_now = 360 }), Time.fromTimeInfo(.{
        .valid = true,
        .second_of_week = 25200,
        .seconds_from_now = -360,
    }));
    const cases = [_]struct { query: Query, want: Result }{
        .{ .query = .{}, .want = .{ .kph = 30, .sources = .{ .constrained = true } } },
        .{ .query = .{ .flow = .{ .freeflow = true } }, .want = .{ .kph = 60, .sources = .{ .freeflow = true } } },
        .{ .query = .{ .flow = .{}, .truck = true }, .want = .{ .kph = 20 } },
        .{ .query = .{ .flow = .{} }, .want = .{ .kph = 40 } },
        .{ .query = .{ .time = .{ .seconds_of_week = 25200 } }, .want = .{ .kph = 60, .sources = .{ .freeflow = true } } },
        .{ .query = .{ .time = .{ .seconds_of_week = 25201 }, .truck = true }, .want = .{ .kph = 30, .sources = .{ .constrained = true } } },
        .{ .query = .{ .time = .{ .seconds_of_week = 68400 } }, .want = .{ .kph = 60, .sources = .{ .freeflow = true } } },
        .{ .query = .{ .time = .{ .seconds_of_week = 68400 + seconds_per_day }, .flow = .{ .constrained = true } }, .want = .{ .kph = 40 } },
        .{ .query = .{ .time = .{ .seconds_of_week = 25201 }, .flow = .{ .freeflow = true } }, .want = .{ .kph = 40 } },
    };
    for (cases) |case| try std.testing.expectEqual(case.want, resolve(test_edge, test_id, case.query, NoOverlays{}));
    var missing = test_edge;
    missing.speed = .{ 40, 60, 0, 0 };
    try std.testing.expectEqual(@as(u8, 60), untimed(missing, .all, true).kph);
    try std.testing.expectEqual(@as(u8, 40), resolve(missing, test_id, .{ .time = .{ .seconds_of_week = 30000 } }, NoOverlays{}).kph);
    missing.speed[1] = 0;
    try std.testing.expectEqual(Result{ .kph = 40 }, untimed(missing, .all, true));

    const forecast: TestOverlay = .{ .forecast = 49.5, .now_bucket = 84 };
    const day: Query = .{ .time = .{ .seconds_of_week = seconds_per_week + 25200 }, .truck = true };
    try std.testing.expectEqual(Result{ .kph = 50, .sources = .{ .predicted = true } }, resolve(test_edge, test_id, day, forecast));
    try std.testing.expectEqual(@as(u8, 30), resolve(test_edge, test_id, .{}, forecast).kph);
    missing = test_edge;
    missing.cls.pred_speed = 0;
    try std.testing.expectEqual(@as(u8, 60), resolve(missing, test_id, day, forecast).kph);
    try std.testing.expectEqual(@as(u8, 1), resolve(test_edge, test_id, day, TestOverlay{ .forecast = -2 }).kph);
    for ([_]f32{ 252.25, 253, std.math.inf(f32), std.math.nan(f32) }) |bad| {
        try std.testing.expectEqual(@as(u8, 60), resolve(test_edge, test_id, day, TestOverlay{ .forecast = bad }).kph);
    }
}

// Ported from test/gurka/test_traffic_smoothing.cc.
test "live interpolation keeps coverage, fade, closure and flow bits independent" {
    const unknown = unknown_traffic_speed;
    var overlay: TestOverlay = .{
        .traffic = .{ .overall = 60, .segments = .{ 60, unknown, unknown }, .breakpoints = .{ 255, 0 } },
        .forecast = 49.5,
    };
    var query: Query = .{ .time = .{ .seconds_of_week = 0 }, .truck = true };
    try std.testing.expectEqual(Result{ .kph = 120, .sources = .{ .current = true } }, resolve(test_edge, test_id, query, overlay));
    query.time.?.seconds_from_now = 360;
    try std.testing.expectEqual(Result{ .kph = 113, .sources = .{ .current = true, .predicted = true } }, resolve(test_edge, test_id, query, overlay));
    query.time.?.seconds_from_now = 3600;
    try std.testing.expectEqual(Result{ .kph = 50, .sources = .{ .predicted = true } }, resolve(test_edge, test_id, query, overlay));

    query.time.?.seconds_from_now = 0;
    overlay.traffic = .{ .overall = 60, .segments = .{ 60, unknown, 60 }, .breakpoints = .{ 85, 170 } };
    try std.testing.expectEqual(Result{ .kph = 96, .sources = .{ .current = true, .predicted = true } }, resolve(test_edge, test_id, query, overlay));
    query.flow = .{ .current = true, .freeflow = true };
    try std.testing.expectEqual(Result{ .kph = 100, .sources = .{ .current = true, .freeflow = true } }, resolve(test_edge, test_id, query, overlay));
    query.flow = .{ .current = true };
    try std.testing.expectEqual(Result{ .kph = 20, .sources = .{ .current = true } }, resolve(test_edge, test_id, query, overlay));

    query.flow = .all;
    overlay.traffic.?.segments = .{ unknown, 60, unknown };
    overlay.traffic.?.breakpoints = .{ 51, 204 };
    try std.testing.expectEqual(Result{ .kph = 92, .sources = .{ .current = true, .predicted = true } }, resolve(test_edge, test_id, query, overlay));
    overlay.traffic.?.segments = @splat(unknown);
    try std.testing.expectEqual(Result{ .kph = 50, .sources = .{ .current = true, .predicted = true } }, resolve(test_edge, test_id, query, overlay));
    overlay.traffic.?.overall = 0;
    try std.testing.expectEqual(Result{ .kph = 50, .sources = .{ .predicted = true }, .closed = true }, resolve(test_edge, test_id, query, overlay));
    query.time = null;
    try std.testing.expectEqual(Result{ .kph = 30, .sources = .{ .constrained = true }, .closed = true }, resolve(test_edge, test_id, query, overlay));
    query.flow.current = false;
    try std.testing.expect(!resolve(test_edge, test_id, query, overlay).closed);
    query.flow = .all;
    query.time = .{ .seconds_of_week = 0 };
    overlay.traffic.?.overall = unknown;
    try std.testing.expectEqual(Result{ .kph = 50, .sources = .{ .predicted = true } }, resolve(test_edge, test_id, query, overlay));
    overlay.traffic.?.overall = 60;
    overlay.traffic.?.breakpoints = .{ 170, 85 };
    try std.testing.expectEqual(Result{ .kph = 50, .sources = .{ .predicted = true } }, resolve(test_edge, test_id, query, overlay));
    overlay.traffic.?.breakpoints = .{ 0, 255 };
    try std.testing.expectEqual(Result{ .kph = 50, .sources = .{ .predicted = true } }, resolve(test_edge, test_id, query, overlay));
}

test "edge speed bound covers valid overlays for every flow mask and truck state" {
    var edge = test_edge;
    for ([_]u8{ 0, 1, 120, 252, 255 }) |base| {
        edge.speed[0] = base;
        for (0..16) |mask| {
            for ([_]u64{ 0, 359, 3599, 3600, 7200 }) |age| {
                for ([_]bool{ false, true }) |truck| {
                    const flow: Flow = @bitCast(@as(u8, @intCast(mask)));
                    const time: Time = .{ .seconds_of_week = 25201, .seconds_from_now = age };
                    const overlay: TestOverlay = .{
                        .traffic = .{ .overall = 126, .segments = .{ 126, 126, 126 }, .breakpoints = .{ 127, 191 } },
                        .forecast = 252,
                    };
                    const actual = resolve(edge, test_id, .{ .flow = flow, .time = time, .truck = truck }, overlay);
                    try std.testing.expect(actual.kph <= upperBound(edge));
                }
            }
        }
    }
}
