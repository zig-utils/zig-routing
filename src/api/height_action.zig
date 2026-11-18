//! The /height action.
//!
//! Ported from src/loki/height_action.cc and src/tyr/height_serializer.cc
//! (Valhalla 3.9.3): validate and optionally resample the shape, sample
//! the DEM at every point, optionally accumulate distances for
//! `range_height`, and serialize exactly as upstream does (including the
//! decimal truncation of `height_precision` and the odd 313 message).

const std = @import("std");
const http = @import("../server/http.zig");
const service = @import("service.zig");
const request = @import("request.zig");
const errors = @import("errors.zig");
const json_writer = @import("json_writer.zig");
const dem = @import("../elevation/root.zig");
const elevation = dem.hgt;
const geo = @import("../geo/root.zig");
const PointLL = geo.PointLL;
const Allocator = std.mem.Allocator;

/// tyr::kCoordinatePrecision.
const coordinate_precision = 6;
/// Longest `{"lat":x,"lon":y}`: two 40-byte numbers at most, plus 15 bytes of keys and braces.
const max_point_json = 15 + 2 * 40;

/// A coordinate as the writer prints it at `coordinate_precision`; NaN and
/// infinities as null, as the writer does.
fn coordinate(v: f64, buf: *[40]u8) []const u8 {
    if (!std.math.isFinite(v)) return "null";
    // Not a shortcut on m / 1e6 == v: rapidjson's Grisu2 is not always
    // shortest, and near the midpoint between doubles it emits extra digits
    // that the six-decimal truncation turns into a different last digit.
    // dtoa's fixed path already excludes that zone.
    return json_writer.dtoa(v, buf, coordinate_precision);
}

pub fn handle(svc: *service.Service, ctx: *http.Ctx, options: *request.Options, res: *http.Response) Allocator.Error!?errors.Failure {
    _ = ctx;
    const a = res.gpa;
    const source: *const dem.Source = @ptrCast(@alignCast(svc.state orelse return .{ .code = 107, .extra = "no elevation data configured" }));

    if (options.shape.len < 1) return .{ .code = 312 };
    var shape = try a.alloc(PointLL, options.shape.len);
    for (options.shape, shape) |l, *p| p.* = .{ .lng = l.lng, .lat = l.lat };

    var resampled = false;
    var encoded = options.encoded_polyline;
    if (options.resample_distance) |rd| {
        if (rd < svc.limits.skadi_min_resample) {
            // Upstream appends " " + std::to_string(min_resample) + " meters".
            return .{ .code = 313, .extra = try std.fmt.allocPrint(a, " {d:.6} meters", .{svc.limits.skadi_min_resample}) };
        }
        if (shape.len > 1) {
            const last = shape[shape.len - 1];
            var out: std.ArrayList(PointLL) = .empty;
            try geo.line.resampleSpherical(a, shape, rd, false, &out);
            try out.append(a, last);
            shape = out.items;
            if (options.encoded_polyline != null) {
                const buf = try a.alloc(u8, geo.polyline.maxEncodedLen(.polyline, shape.len));
                const n = (if (options.shape_format == .polyline5)
                    geo.polyline.encode(.polyline, 5, shape, buf)
                else
                    geo.polyline.encode(.polyline, 6, shape, buf)) catch return .{ .code = 599 };
                encoded = buf[0..n];
            }
            resampled = true;
        }
    }
    if (shape.len > svc.limits.skadi_max_shape) {
        return .{ .code = 314, .extra = try std.fmt.allocPrint(a, " ({d}{s}). The limit is {d}", .{ shape.len, if (resampled) " after resampling" else "", svc.limits.skadi_max_shape }) };
    }

    const heights = try a.alloc(f64, shape.len);
    try source.getAllBatched(a, shape, heights);

    var ranges: []f64 = &.{};
    if (options.range) {
        ranges = try a.alloc(f64, shape.len);
        ranges[0] = 0;
        for (1..shape.len) |i| ranges[i] = ranges[i - 1] + shape[i].distance(shape[i - 1]);
    }

    try serialize(a, &res.body, options, shape, encoded, heights, ranges);
    return null;
}

fn writeWithPrecision(w: *json_writer.Writer, value: f64, precision: u32) Allocator.Error!void {
    if (precision == 0) return w.int(@intFromFloat(@round(value)));
    return w.float(value);
}

/// tyr::serializeHeight.
pub fn serialize(a: Allocator, out: *std.ArrayList(u8), options: *const request.Options, shape: []const PointLL, encoded: ?[]const u8, heights: []const f64, ranges: []const f64) Allocator.Error!void {
    var w = json_writer.Writer.init(a, out);
    const precision = options.height_precision;
    try w.beginObject();
    if (encoded) |e| {
        try w.field("encoded_polyline", e);
    } else {
        try w.key("shape");
        // The points written in one loop into reserved space: the same bytes
        // the writer's beginObject/field/endObject calls produce.
        const buf = try w.rawValue();
        try buf.ensureUnusedCapacity(a, 2 + shape.len * (max_point_json + 1));
        buf.appendAssumeCapacity('[');
        var num: [40]u8 = undefined;
        for (shape, 0..) |p, i| {
            if (i > 0) buf.appendAssumeCapacity(',');
            buf.appendSliceAssumeCapacity("{\"lat\":");
            buf.appendSliceAssumeCapacity(coordinate(p.lat, &num));
            buf.appendSliceAssumeCapacity(",\"lon\":");
            buf.appendSliceAssumeCapacity(coordinate(p.lng, &num));
            buf.appendAssumeCapacity('}');
        }
        buf.appendAssumeCapacity(']');
    }
    if (ranges.len > 0) {
        try w.beginArrayField("range_height");
        w.setPrecision(@intCast(@max(precision, 1)));
        for (heights, ranges) |h, r| {
            try w.beginArray();
            try writeWithPrecision(&w, r, precision);
            if (h == elevation.no_data_value) try w.null_() else try writeWithPrecision(&w, h, precision);
            try w.endArray();
        }
        try w.endArray();
    } else if (precision == 0) {
        // Whole metres (the default): one loop into reserved space.
        try w.key("height");
        const buf = try w.rawValue();
        try buf.ensureUnusedCapacity(a, 2 + heights.len * 25);
        buf.appendAssumeCapacity('[');
        var num: [24]u8 = undefined;
        for (heights, 0..) |h, i| {
            if (i > 0) buf.appendAssumeCapacity(',');
            if (h == elevation.no_data_value) {
                buf.appendSliceAssumeCapacity("null");
            } else {
                buf.appendSliceAssumeCapacity(json_writer.formatInt(@intFromFloat(@round(h)), &num));
            }
        }
        buf.appendAssumeCapacity(']');
    } else {
        try w.beginArrayField("height");
        w.setPrecision(@intCast(precision));
        for (heights) |h| {
            if (h == elevation.no_data_value) try w.null_() else try writeWithPrecision(&w, h, precision);
        }
        try w.endArray();
    }
    if (options.id) |id| try w.field("id", id);
    if (options.warnings.items.len > 0) {
        try w.beginArrayField("warnings");
        for (options.warnings.items) |code| {
            try w.beginObject();
            try w.field("code", @as(u64, code));
            try w.field("text", errors.warningText(code) orelse "");
            try w.endObject();
        }
        try w.endArray();
    }
    try w.endObject();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "serializer output matches upstream's shape for each precision" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var o: request.Options = .{ .action = .height };
    const shape = [_]PointLL{ .{ .lng = -76.504913, .lat = 40.712433 }, .{ .lng = -76.605263, .lat = 40.712276 } };
    var out: std.ArrayList(u8) = .empty;
    try serialize(a, &out, &o, &shape, null, &.{ 303.4, elevation.no_data_value }, &.{});
    try testing.expectEqualStrings("{\"shape\":[{\"lat\":40.712433,\"lon\":-76.504913},{\"lat\":40.712276,\"lon\":-76.605263}],\"height\":[303,null]}", out.items);

    out.clearRetainingCapacity();
    o.height_precision = 2;
    o.id = "x";
    try serialize(a, &out, &o, &shape, "_ixfE", &.{ 303.456, 275.0 }, &.{ 0, 8467.4321 });
    try testing.expectEqualStrings("{\"encoded_polyline\":\"_ixfE\",\"range_height\":[[0.0,303.45],[8467.43,275.0]],\"id\":\"x\"}", out.items);

    out.clearRetainingCapacity();
    o.height_precision = 0;
    o.id = null;
    try o.warnings.append(a, 104);
    try serialize(a, &out, &o, &shape, "_ixfE", &.{ 303.5, 275.49 }, &.{ 0, 8467.5 });
    try testing.expectEqualStrings("{\"encoded_polyline\":\"_ixfE\",\"range_height\":[[0,304],[8468,275]],\"warnings\":[{\"code\":104,\"text\":\"jsonp has been deprecated, use CORS instead\"}]}", out.items);
}

/// The serializer as written with one writer call per value: the reference
/// the loops in `serialize` must match byte for byte.
fn serializeReference(a: Allocator, out: *std.ArrayList(u8), options: *const request.Options, shape: []const PointLL, heights: []const f64) Allocator.Error!void {
    var w = json_writer.Writer.init(a, out);
    const precision = options.height_precision;
    try w.beginObject();
    try w.beginArrayField("shape");
    w.setPrecision(coordinate_precision);
    for (shape) |p| {
        try w.beginObject();
        try w.field("lat", p.lat);
        try w.field("lon", p.lng);
        try w.endObject();
    }
    try w.endArray();
    try w.beginArrayField("height");
    w.setPrecision(@intCast(@max(precision, 1)));
    for (heights) |h| {
        if (h == elevation.no_data_value) try w.null_() else try writeWithPrecision(&w, h, precision);
    }
    try w.endArray();
    if (options.id) |id| try w.field("id", id);
    try w.endObject();
}

test "the shape and height loops write the same bytes as one writer call per value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(5);
    const random = prng.random();
    for (0..3000) |round| {
        _ = arena_state.reset(.retain_capacity);
        const n = random.uintLessThan(usize, 60);
        const shape = try a.alloc(PointLL, n);
        const heights = try a.alloc(f64, n);
        for (shape, heights) |*p, *h| {
            p.* = .{ .lat = random.float(f64) * 180 - 90, .lng = random.float(f64) * 360 - 180 };
            switch (random.uintLessThan(u8, 12)) {
                0 => p.lat = @round(p.lat * 1e6) / 1e6, // on the grid, the common case
                6 => p.lng = @round(p.lng * 1e3) / 1e3,
                7 => p.lat = @round(p.lat * 1e6) / 1e6 + 1e-12, // just off the grid
                8 => p.lng = 1e7 + @round(random.float(f64) * 1e6) / 1e6, // large, wrapped longitudes
                9 => p.lat = 0.00001,
                1 => p.lng = -0.0,
                2 => p.lat = 0,
                3 => p.lng = 1e-9,
                4 => p.lat = 89.9999999999,
                5 => p.lng = @round(p.lng),
                else => {},
            }
            h.* = switch (random.uintLessThan(u8, 6)) {
                0 => elevation.no_data_value,
                1 => -0.4,
                2 => 0.5,
                3 => -412.5,
                else => random.float(f64) * 9000 - 500,
            };
        }
        var o: request.Options = .{ .action = .height };
        o.height_precision = @intCast(round % 3);
        if (round % 4 == 0) o.id = "abc";
        var fast: std.ArrayList(u8) = .empty;
        try serialize(a, &fast, &o, shape, null, heights, &.{});
        var ref: std.ArrayList(u8) = .empty;
        try serializeReference(a, &ref, &o, shape, heights);
        try testing.expectEqualStrings(ref.items, fast.items);
    }
}

const arena_mod = @import("../infra/arena.zig");

const SteadyState = struct {
    svc: *service.Service,
    bodies: []const []const u8,

    fn run(arena: *arena_mod.Arena, self: SteadyState) anyerror!void {
        for (self.bodies) |body| {
            const a = arena.allocator();
            var options = switch (try request.parseHttp(a, "/height", &.{}, body)) {
                .ok => |o| o,
                .failure => return error.TestUnexpectedResult,
            };
            var res: http.Response = .{ .gpa = a };
            var ctx: http.Ctx = undefined;
            if (try handle(self.svc, &ctx, &options, &res)) |f| {
                std.debug.print("failure {d}\n", .{f.code});
                return error.TestUnexpectedResult;
            }
            try testing.expect(res.body.items.len > 0);
        }
    }
};

test "bulk /height reaches no allocator after warm-up" {
    const gpa = testing.allocator;
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/zig-routing-steady-{d}", .{std.c.getpid()});
    elevation.mkdir(dir);
    defer elevation.rmTree(dir);
    try elevation.writeTile(gpa, dir, "N47E008.hgt.lz4", .lz4);
    var tiles = try elevation.Tiles.init(gpa, dir);
    defer tiles.deinit();
    var source: dem.Source = .{ .tiles = &tiles };
    var svc: service.Service = .{ .state = &source };

    // A 5000-point shape (the fast parse path), scattered points, an encoded
    // polyline with range, and a resampled shape at height precision 2.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    var scattered: std.ArrayList(u8) = .empty;
    defer scattered.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(4);
    const random = prng.random();
    try big.appendSlice(gpa, "{\"shape\":[");
    try scattered.appendSlice(gpa, "{\"range\":true,\"shape\":[");
    for (0..5000) |i| {
        if (i > 0) {
            try big.append(gpa, ',');
            try scattered.append(gpa, ',');
        }
        const t = @as(f64, @floatFromInt(i)) / 5000.0;
        try big.print(gpa, "{{\"lat\":{d:.6},\"lon\":{d:.6}}}", .{ 47.1 + 0.5 * t, 8.2 + 0.3 * t });
        try scattered.print(gpa, "{{\"lon\":{d:.6},\"lat\":{d:.6}}}", .{ 8 + random.float(f64), 47 + random.float(f64) });
    }
    try big.appendSlice(gpa, "]}");
    try scattered.appendSlice(gpa, "]}");
    const bodies = [_][]const u8{
        big.items,
        scattered.items,
        "{\"encoded_polyline\":\"_lmhH_a~p@_ibE_ibE\",\"range\":true}",
        "{\"shape\":[{\"lat\":47.2,\"lon\":8.3},{\"lat\":47.25,\"lon\":8.35}],\"resample_distance\":40,\"height_precision\":2}",
    };
    try arena_mod.expectNoSteadyStateAlloc(SteadyState, .{ .svc = &svc, .bodies = &bodies }, SteadyState.run);
}
