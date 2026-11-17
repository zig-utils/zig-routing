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
const elevation = @import("../elevation/hgt.zig");
const geo = @import("../geo/root.zig");
const PointLL = geo.PointLL;
const Allocator = std.mem.Allocator;

/// tyr::kCoordinatePrecision.
const coordinate_precision = 6;

pub fn handle(svc: *service.Service, ctx: *http.Ctx, options: *request.Options, res: *http.Response) Allocator.Error!?errors.Failure {
    _ = ctx;
    const a = res.gpa;
    const tiles: *elevation.Tiles = @ptrCast(@alignCast(svc.state orelse return .{ .code = 107, .extra = "no elevation data configured" }));

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
    elevation.getAll(tiles, shape, heights);

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
        try w.beginArrayField("shape");
        w.setPrecision(coordinate_precision);
        for (shape) |p| {
            try w.beginObject();
            try w.field("lat", p.lat);
            try w.field("lon", p.lng);
            try w.endObject();
        }
        try w.endArray();
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
    } else {
        try w.beginArrayField("height");
        w.setPrecision(@intCast(@max(precision, 1)));
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
