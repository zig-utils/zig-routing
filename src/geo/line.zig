//! Operations on polylines: length, trimming, resampling, simplification
//! and segment distance.
//!
//! Ported from src/midgard/util.cc, valhalla/midgard/util.h,
//! src/midgard/polyline2.cc and src/midgard/linesegment2.cc (Valhalla 3.9.3).
//! Upstream mixes float and double deliberately (for example
//! `resample_polyline` runs in float); the ports keep each choice.

const std = @import("std");
const libm = @import("libm.zig");
const k = @import("constants.zig");
const point = @import("point.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const PointLL = point.PointLL;
const Allocator = std.mem.Allocator;

const rad_per_meter: f64 = 1.0 / 6378160.187;

/// Total length in metres (sum of haversine segment lengths).
pub fn length(pts: []const PointLL) f64 {
    if (pts.len < 2) return 0.0;
    var total: f64 = 0.0;
    for (pts[1..], pts[0 .. pts.len - 1]) |p, prev| total += p.distance(prev);
    return total;
}

/// util.h `normalize`: num / den clamped to [0, 1], 0 when den is 0.
pub fn normalize(num: f32, den: f32) f32 {
    return if (den == 0) 0 else @min(@max(num / den, 0.0), 1.0);
}

/// util.h `trim_polyline`: the part of the line between `source` and
/// `target`, given as fractions of its length. Empty for an inverted or
/// out-of-range request; two copies of the last vertex when nothing is
/// inside. Output is appended to `out`.
pub fn trimPolyline(gpa: Allocator, pts: []const PointLL, source_in: f64, target_in: f64, out: *std.ArrayList(PointLL)) Allocator.Error!void {
    if (target_in < source_in or target_in < 0 or 1 < source_in or pts.len == 0) return;
    const source = std.math.clamp(source_in, 0, 1);
    const target = std.math.clamp(target_in, 0, 1);
    const total_length = length(pts);
    const source_length = total_length * source;
    const target_length = total_length * target;
    var prev_vertex_length: f64 = 0;
    var open = false;
    const start_len = out.items.len;
    var prev: usize = 0;
    for (1..pts.len) |i| {
        const segment_length = pts[prev].distance(pts[i]);
        const vertex_length = prev_vertex_length + segment_length;
        if (!open and source_length < vertex_length) {
            const offset = normalize(@floatCast(source_length - prev_vertex_length), @floatCast(segment_length));
            try out.append(gpa, pts[prev].pointAlongSegment(pts[i], offset));
            open = true;
        }
        if (open and target_length < vertex_length) {
            const offset = normalize(@floatCast(target_length - prev_vertex_length), @floatCast(segment_length));
            try out.append(gpa, pts[prev].pointAlongSegment(pts[i], offset));
            open = false;
            break;
        }
        if (open) try out.append(gpa, pts[i]);
        prev = i;
        prev_vertex_length = vertex_length;
    }
    if (out.items.len == start_len) {
        try out.append(gpa, pts[prev]);
        try out.append(gpa, pts[prev]);
    }
}

/// util.cc `trim_front`: removes the first `dist` metres from `pts` (in
/// place) and appends the removed piece to `out`. Mirrors upstream, which
/// keeps the segment the cut lands in (`erase(begin, p1)` then overwrites
/// its first vertex with the cut point).
pub fn trimFront(gpa: Allocator, pts: *std.ArrayList(PointLL), dist: f32, out: *std.ArrayList(PointLL)) Allocator.Error!void {
    if (pts.items.len < 2) return;
    try out.append(gpa, pts.items[0]);
    var d: f64 = 0.0;
    for (0..pts.items.len - 1) |i| {
        const p1 = pts.items[i];
        const p2 = pts.items[i + 1];
        const segdist = p1.distance(p2);
        if (d + segdist > dist) {
            const frac = (@as(f64, dist) - d) / segdist;
            const mid = p1.pointAlongSegment(p2, frac);
            try out.append(gpa, mid);
            std.mem.copyForwards(PointLL, pts.items[0 .. pts.items.len - i], pts.items[i..]);
            pts.shrinkRetainingCapacity(pts.items.len - i);
            pts.items[0] = mid;
            return;
        }
        d += segdist;
        try out.append(gpa, p2);
    }
    pts.clearRetainingCapacity();
}

/// util.cc `trim_shape(start, start_vertex, end, end_vertex, shape)`: cuts
/// the shape in place at distances along it, replacing the boundary
/// vertices with the given points (skipped when a point is invalid).
pub fn trimShape(start: f32, start_vertex: PointLL, end: f32, end_vertex: PointLL, shape: *std.ArrayList(PointLL)) void {
    trimShapeWithDeadline(start, start_vertex, end, end_vertex, shape, .none) catch unreachable;
}

pub fn trimShapeWithDeadline(start: f32, start_vertex: PointLL, end: f32, end_vertex: PointLL, shape: *std.ArrayList(PointLL), deadline: Deadline) error{DeadlineExceeded}!void {
    var along: f32 = 0;
    if (start_vertex.isValid() and shape.items.len >= 2) {
        var current: usize = 0;
        while (current != shape.items.len - 1 and along <= start) : (current += 1) {
            if (current % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            along += @floatCast(shape.items[current + 1].distance(shape.items[current]));
        }
        current -|= 1;
        shape.items[current] = start_vertex;
        std.mem.copyForwards(PointLL, shape.items[0 .. shape.items.len - current], shape.items[current..]);
        shape.shrinkRetainingCapacity(shape.items.len - current);
        along = start;
    }
    if (end_vertex.isValid() and shape.items.len > 0) {
        var current: usize = 0;
        while (current != shape.items.len - 1 and along <= end) : (current += 1) {
            if (current % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            along += @floatCast(shape.items[current + 1].distance(shape.items[current]));
        }
        shape.items[current] = end_vertex;
        shape.shrinkRetainingCapacity(current + 1);
    }
}

/// util.cc `trim_shape(start_pct, end_pct, shape)`.
pub fn trimShapePct(start_pct: f32, end_pct: f32, shape: *std.ArrayList(PointLL)) void {
    if (shape.items.len < 2 or (start_pct == 0 and end_pct == 1)) return;
    const total: f32 = @floatCast(length(shape.items));
    const start_dist = start_pct * total;
    const end_dist = end_pct * total;
    var start_vertex: PointLL = .invalid;
    var end_vertex: PointLL = .invalid;
    var accumulated: f32 = 0;
    for (1..shape.items.len) |i| {
        const seg_len: f32 = @floatCast(shape.items[i - 1].distance(shape.items[i]));
        if (!start_vertex.isValid() and accumulated + seg_len >= start_dist) {
            const pct: f32 = if (seg_len > 0) (start_dist - accumulated) / seg_len else 0;
            start_vertex = shape.items[i - 1].pointAlongSegment(shape.items[i], pct);
        }
        if (accumulated + seg_len >= end_dist) {
            const pct: f32 = if (seg_len > 0) (end_dist - accumulated) / seg_len else 0;
            end_vertex = shape.items[i - 1].pointAlongSegment(shape.items[i], pct);
            break;
        }
        accumulated += seg_len;
    }
    trimShape(start_dist, start_vertex, end_dist, end_vertex, shape);
}

/// Great-circle angle between two points in radians, as upstream computes it
/// inside the resamplers (law of cosines; 0 for equal points).
fn arc(last: PointLL, p: PointLL, comptime math: type) f64 {
    if (last.eql(p)) return 0.0;
    const lon2 = p.lng * -k.rad_per_deg_d;
    const lat2 = p.lat * k.rad_per_deg_d;
    return math.acosF(math.sinF(last.lat * k.rad_per_deg_d) * math.sinF(lat2) +
        math.cosF(last.lat * k.rad_per_deg_d) * math.cosF(lat2) * math.cosF(last.lng * -k.rad_per_deg_d - lon2));
}

/// The point `remaining` radians from `last` toward `p` (which is `d`
/// radians away), as upstream interpolates.
fn interpolate(last: PointLL, p: PointLL, d: f64, remaining: f64, comptime math: type) PointLL {
    const lon2 = p.lng * -k.rad_per_deg_d;
    const lat2 = p.lat * k.rad_per_deg_d;
    const lon1 = last.lng * -k.rad_per_deg_d;
    const lat1 = last.lat * k.rad_per_deg_d;
    const sd = math.sinF(d);
    const a = math.sinF(d - remaining) / sd;
    const acs1 = a * math.cosF(lat1);
    const b = math.sinF(remaining) / sd;
    const bcs2 = b * math.cosF(lat2);
    const x = acs1 * math.cosF(lon1) + bcs2 * math.cosF(lon2);
    const y = acs1 * math.sinF(lon1) + bcs2 * math.sinF(lon2);
    const z = a * math.sinF(lat1) + b * math.sinF(lat2);
    return .{ .lng = math.atan2F(y, x) * -k.deg_per_rad_d, .lat = math.atan2F(z, @sqrt(x * x + y * y)) * k.deg_per_rad_d };
}

/// util.cc `resample_spherical_polyline`: a point every `resolution`
/// metres along the great circles of the line, starting with the first
/// vertex. With `preserve`, original vertices are kept as well. As
/// upstream, the final vertex is only included when `preserve` is set.
pub fn resampleSpherical(gpa: Allocator, polyline: []const PointLL, resolution_m: f64, preserve: bool, out: *std.ArrayList(PointLL)) Allocator.Error!void {
    const Output = struct {
        gpa: Allocator,
        out: *std.ArrayList(PointLL),

        pub fn emit(self: *const @This(), p: PointLL) Allocator.Error!void {
            try self.out.append(self.gpa, p);
        }
    };
    const output: Output = .{ .gpa = gpa, .out = out };
    try visitResampledSpherical(polyline, resolution_m, preserve, &output);
}

/// Emits each point to a caller-selected sink while walking the same
/// great-circle segments as resampleSpherical.
pub fn visitResampledSpherical(polyline: []const PointLL, resolution_m: f64, preserve: bool, sink: anytype) !void {
    try visitResampledSphericalWith(polyline, resolution_m, preserve, sink, libm);
}

pub fn visitResampledSphericalWith(polyline: []const PointLL, resolution_m: f64, preserve: bool, sink: anytype, comptime math: type) !void {
    if (polyline.len == 0) return;
    const checks = @hasDecl(@TypeOf(sink.*), "check");
    const resolution = resolution_m * rad_per_meter;
    if (checks and resolution <= 0) return error.InvalidResolution;
    try sink.emit(polyline[0]);
    var remaining = resolution;
    var last = polyline[0];
    for (polyline[1..], 0..) |p, segment| {
        if (checks and segment & 1023 == 0) try sink.check();
        var d = arc(last, p, math);
        if (std.math.isNan(d)) d = 0.0;
        while (d > remaining) {
            const rest = d - remaining;
            if (checks and rest == d and remaining == resolution) return error.InvalidResolution;
            last = interpolate(last, p, d, remaining, math);
            try sink.emit(last);
            d = rest;
            remaining = resolution;
        }
        remaining -= d;
        last = p;
        if (preserve) try sink.emit(last);
    }
}

/// util.cc `uniform_resample_spherical_polyline`: exactly `n` points spread
/// evenly over a line of the given length, ending at the last vertex.
pub fn uniformResampleSpherical(gpa: Allocator, polyline: []const PointLL, length_m: f64, n: u32, out: *std.ArrayList(PointLL)) Allocator.Error!void {
    if (polyline.len == 0) return;
    if (n == 2) {
        try out.appendSlice(gpa, &.{ polyline[0], polyline[polyline.len - 1] });
        return;
    }
    const base = out.items.len;
    const sample_distance = length_m / @as(f64, @floatFromInt(n - 1)) * rad_per_meter;
    try out.append(gpa, polyline[0]);
    var remaining = sample_distance;
    var last = polyline[0];
    for (polyline[1..]) |p| {
        var d = arc(last, p, libm);
        if (std.math.isNan(d)) continue;
        while (remaining < d) {
            last = interpolate(last, p, d, remaining, libm);
            try out.append(gpa, last);
            d -= remaining;
            remaining = sample_distance;
        }
        remaining -= d;
        last = p;
    }
    const got = out.items.len - base;
    if (got < n) {
        try out.append(gpa, polyline[polyline.len - 1]);
    } else {
        out.shrinkRetainingCapacity(base + n);
        out.items[out.items.len - 1] = polyline[polyline.len - 1];
    }
}

/// util.cc `resample_polyline` (used by isochrones): planar interpolation
/// in single precision, about `resolution` metres apart, ending at the last
/// vertex.
pub fn resamplePolyline(gpa: Allocator, polyline: []const PointLL, length_m: f32, resolution: f32, out: *std.ArrayList(PointLL)) Allocator.Error!void {
    resamplePolylineWithDeadline(gpa, polyline, length_m, resolution, out, .none) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => unreachable,
    };
}

pub fn resamplePolylineWithDeadline(gpa: Allocator, polyline: []const PointLL, length_m: f32, resolution: f32, out: *std.ArrayList(PointLL), deadline: Deadline) (Allocator.Error || error{DeadlineExceeded})!void {
    if (polyline.len == 0) return;
    const base = out.items.len;
    try out.append(gpa, polyline[0]);
    const n: usize = @intFromFloat(@round(length_m / resolution));
    const sample_distance: f32 = length_m / @as(f32, @floatFromInt(n));
    var accumulated_d: f32 = 0;
    var endpoint: ?point.DistanceEndpoint = null;
    for (polyline[0 .. polyline.len - 1], polyline[1..], 0..) |p0, p1, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (out.items.len - base == n) break;
        if (p0.eql(p1)) continue;
        const a = endpoint orelse point.DistanceEndpoint.init(p0, libm);
        const b = point.DistanceEndpoint.init(p1, libm);
        const d: f32 = @floatCast(a.distance(b, libm));
        endpoint = b;
        if (d + accumulated_d > sample_distance) {
            const dlon: f32 = @floatCast(p1.lng - p0.lng);
            const dlat: f32 = @floatCast(p1.lat - p0.lat);
            var p = (sample_distance - accumulated_d) / d;
            try out.append(gpa, .{ .lng = p0.lng + p * dlon, .lat = p0.lat + p * dlat });
            const dp = sample_distance / d;
            while (p + dp < 1.0 and out.items.len - base < n) {
                if ((out.items.len - base) % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                p += dp;
                try out.append(gpa, .{ .lng = p0.lng + p * dlon, .lat = p0.lat + p * dlat });
            }
            accumulated_d = d * (1.0 - p);
        } else {
            accumulated_d += d;
        }
    }
    try out.append(gpa, polyline[polyline.len - 1]);
}

pub const SegmentClosest = struct { point: PointLL, distance_sq: f64 };

/// linesegment2.cc `DistanceSquared` for geographic points: projection in
/// degree space, distance in approximate metres squared from the
/// projected point.
pub fn segmentDistanceSquared(a: PointLL, b: PointLL, p: PointLL) SegmentClosest {
    const vx = b.lng - a.lng;
    const vy = b.lat - a.lat;
    const wx = p.lng - a.lng;
    const wy = p.lat - a.lat;
    const n = wx * vx + wy * vy;
    var closest: PointLL = undefined;
    if (n <= 0.0) {
        closest = a;
    } else {
        const d = vx * vx + vy * vy;
        closest = if (d <= n) b else .{ .lng = a.lng + vx * (n / d), .lat = a.lat + vy * (n / d) };
    }
    return .{ .point = closest, .distance_sq = closest.distanceSquared(p) };
}

/// polyline2.cc `DouglasPeucker` (Generalize without self-intersection
/// avoidance): removes vertices closer than `epsilon_m` to the simplified
/// line, in place. Vertices whose index is set in `excluded` are always
/// kept. Iterative (no recursion), same choices as upstream: the scan runs
/// from the end, ties keep the later vertex, an excluded vertex splits
/// immediately.
pub fn douglasPeucker(gpa: Allocator, polyline: *std.ArrayList(PointLL), epsilon_m: f64, excluded: ?[]const bool) Allocator.Error!void {
    return simplify(gpa, polyline, epsilon_m, excluded, false, .none) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DeadlineExceeded => unreachable,
    };
}

/// The same vertex retention rule in planar coordinates, where both axes
/// and the tolerance use the projection's units.
pub fn douglasPeuckerPlanar(gpa: Allocator, polyline: *std.ArrayList(PointLL), epsilon: f64, deadline: Deadline) !void {
    try simplify(gpa, polyline, epsilon, null, true, deadline);
}

fn simplify(gpa: Allocator, polyline: *std.ArrayList(PointLL), epsilon_m: f64, excluded: ?[]const bool, comptime planar: bool, deadline: Deadline) (Allocator.Error || error{DeadlineExceeded})!void {
    const pts = polyline.items;
    if (epsilon_m <= 0 or pts.len < 3) return;
    const epsilon = epsilon_m * epsilon_m;
    const keep = try gpa.alloc(bool, pts.len);
    defer gpa.free(keep);
    @memset(keep, true);

    const Range = struct { s: usize, e: usize };
    var stack: std.ArrayList(Range) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .s = 0, .e = pts.len - 1 });
    while (stack.pop()) |r| {
        if (comptime planar) if (deadline.expired()) return error.DeadlineExceeded;
        var dmax = -std.math.floatMax(f64);
        var split: usize = 0;
        var j = r.e - 1;
        while (j > r.s) : (j -= 1) {
            if (comptime planar) if (j % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (excluded) |mask| if (mask[j]) {
                dmax = epsilon;
                split = j;
                break;
            };
            const d = if (planar)
                planarDistanceSquared(pts[r.s], pts[r.e], pts[j])
            else
                segmentDistanceSquared(pts[r.s], pts[r.e], pts[j]).distance_sq;
            if (d > dmax) {
                dmax = d;
                split = j;
            }
        }
        if (dmax >= epsilon) {
            if (r.e - split > 1) try stack.append(gpa, .{ .s = split, .e = r.e });
            if (split - r.s > 1) try stack.append(gpa, .{ .s = r.s, .e = split });
        } else {
            @memset(keep[r.s + 1 .. r.e], false);
        }
    }
    var w: usize = 0;
    for (pts, keep, 0..) |p, kept, i| {
        if (comptime planar) if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!kept) continue;
        pts[w] = p;
        w += 1;
    }
    polyline.shrinkRetainingCapacity(w);
}

fn planarDistanceSquared(a: PointLL, b: PointLL, p: PointLL) f64 {
    const dx = b.lng - a.lng;
    const dy = b.lat - a.lat;
    const x = p.lng - a.lng;
    const y = p.lat - a.lat;
    const len = dx * dx + dy * dy;
    const t = if (len == 0) 0 else std.math.clamp((x * dx + y * dy) / len, 0, 1);
    const px = x - t * dx;
    const py = y - t * dy;
    return px * px + py * py;
}

/// Topology-aware Douglas-Peucker for contours, from
/// src/midgard/polyline2.cc's avoid-self-intersections variant. Search the
/// retained vertices inside each swept triangle before replacing an arc.
pub fn generalizeContour(
    gpa: Allocator,
    polyline: *std.ArrayList(PointLL),
    epsilon_m: f64,
    deadline: Deadline,
) !void {
    const pts = polyline.items;
    if (epsilon_m <= 0 or pts.len < 3) return;
    const epsilon_sq = epsilon_m * epsilon_m;
    const keep = try gpa.alloc(bool, pts.len);
    defer gpa.free(keep);
    @memset(keep, true);

    const Range = struct { start: usize, end: usize };
    const vertex_order = try gpa.alloc(usize, pts.len);
    defer gpa.free(vertex_order);
    for (vertex_order, 0..) |*index, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        index.* = i;
    }
    std.mem.sortUnstable(usize, vertex_order, @as([]const PointLL, pts), vertexLongitudeLess);
    var stack: std.ArrayList(Range) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .start = 0, .end = pts.len - 1 });
    while (stack.pop()) |range| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const a = pts[range.start];
        const b = pts[range.end];
        var distance_sq: f64 = -1;
        var split = range.start + 1;
        for (range.start + 1..range.end) |mid| {
            if (mid % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const d = segmentDistanceSquared(a, b, pts[mid]).distance_sq;
            if (d > distance_sq) {
                distance_sq = d;
                split = mid;
            }
        }
        if (distance_sq < epsilon_sq and
            !try sweepsVertex(pts, keep, vertex_order, range.start, range.end, deadline))
        {
            @memset(keep[range.start + 1 .. range.end], false);
            continue;
        }
        // Visit right first, like Valhalla's topology-preserving generalizer.
        if (split - range.start > 1) try stack.append(gpa, .{ .start = range.start, .end = split });
        if (range.end - split > 1) try stack.append(gpa, .{ .start = split, .end = range.end });
    }
    var count: usize = 0;
    for (pts, keep, 0..) |coordinate, retained, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!retained) continue;
        pts[count] = coordinate;
        count += 1;
    }
    polyline.shrinkRetainingCapacity(count);
}

fn vertexLongitudeLess(points: []const PointLL, a: usize, b: usize) bool {
    return points[a].lng < points[b].lng;
}

fn sweepsVertex(
    points: []const PointLL,
    keep: []const bool,
    vertex_order: []const usize,
    start: usize,
    end: usize,
    deadline: Deadline,
) !bool {
    const a = points[start];
    const b = points[end];
    if (a.eql(b)) return false;
    for (points[start + 1 .. end], 0..) |c, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (a.isLeft(b, c) == 0) continue;
        const lo = PointLL.init(@min(a.lng, b.lng, c.lng), @min(a.lat, b.lat, c.lat));
        const hi = PointLL.init(@max(a.lng, b.lng, c.lng), @max(a.lat, b.lat, c.lat));
        var left: usize = 0;
        var right = vertex_order.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (points[vertex_order[mid]].lng < lo.lng) left = mid + 1 else right = mid;
        }
        for (vertex_order[left..], 0..) |index, j| {
            if (j % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const candidate = points[index];
            if (candidate.lng > hi.lng) break;
            if (!keep[index] or (index >= start and index <= end)) continue;
            if (candidate.lat < lo.lat or candidate.lat > hi.lat) continue;
            if (triangleContains(a, c, b, candidate)) return true;
        }
    }
    return false;
}

// Ported from src/midgard/util.cc's triangle_contains. Endpoints and the
// opposite edge do not count as interior swept vertices.
fn triangleContains(a: PointLL, b: PointLL, c: PointLL, candidate: PointLL) bool {
    const x0 = c.lng - a.lng;
    const y0 = c.lat - a.lat;
    const x1 = b.lng - a.lng;
    const y1 = b.lat - a.lat;
    const x2 = candidate.lng - a.lng;
    const y2 = candidate.lat - a.lat;
    const d00 = x0 * x0 + y0 * y0;
    const d01 = x0 * x1 + y0 * y1;
    const d02 = x0 * x2 + y0 * y2;
    const d11 = x1 * x1 + y1 * y1;
    const d12 = x1 * x2 + y1 * y2;
    const denominator = d00 * d11 - d01 * d01;
    if (@abs(denominator) < 1e-20) return false;
    const u = (d11 * d02 - d01 * d12) / denominator;
    const v = (d00 * d12 - d01 * d02) / denominator;
    return u >= 1e-16 and v >= 1e-16 and u + v < 1;
}

/// Bearing over a sampled distance along a shape, starting behind the
/// projection and consuming any remaining distance ahead of it.
pub fn tangentAngle(shape: []const PointLL, index: usize, projected: PointLL, sample_distance: f32, forward: bool, deadline: Deadline) !f32 {
    std.debug.assert(index + 1 < shape.len);
    const last = shape.len - 1;
    var remaining = sample_distance;
    var start = projected;
    var i = if (forward) index else last - index - 1;
    var step: usize = 0;
    while (remaining > 0) : (step += 1) {
        if (step % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const next = shape[if (forward) i else last - i];
        const d = start.distance(next);
        if (remaining <= d) {
            start = start.pointAlongSegment(next, remaining / d);
            return @floatCast(start.heading(projected));
        }
        start = next;
        remaining = @floatCast(@as(f64, remaining) - d);
        if (i == 0) break;
        i -= 1;
    }
    i = if (forward) index + 1 else last - index;
    var end = projected;
    while (remaining > 0) : (step += 1) {
        if (step % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const next = shape[if (forward) i else last - i];
        const d = end.distance(next);
        if (remaining <= d) {
            end = end.pointAlongSegment(next, remaining / d);
            break;
        }
        end = next;
        remaining = @floatCast(@as(f64, remaining) - d);
        if (i == last) break;
        i += 1;
    }
    return @floatCast(start.heading(end));
}

/// Squared planar distances (degrees, longitude scaled by `lon_scale`) from
/// `p` to many segments a[i]-b[i] at once, for candidate filtering before
/// exact projection. Writes one value per segment.
pub fn projectBatchSquared(p: PointLL, lon_scale: f64, ax: []const f64, ay: []const f64, bx: []const f64, by: []const f64, out: []f64) void {
    std.debug.assert(ax.len == ay.len and ax.len == bx.len and ax.len == by.len and out.len >= ax.len);
    const lanes = std.simd.suggestVectorLength(f64) orelse 4;
    const V = @Vector(lanes, f64);
    const px: V = @splat(p.lng);
    const py: V = @splat(p.lat);
    const sc: V = @splat(lon_scale);
    const zero: V = @splat(0);
    const one: V = @splat(1);
    var i: usize = 0;
    while (i + lanes <= ax.len) : (i += lanes) {
        const x0: V = ax[i..][0..lanes].*;
        const y0: V = ay[i..][0..lanes].*;
        const dx = (@as(V, bx[i..][0..lanes].*) - x0) * sc;
        const dy = @as(V, by[i..][0..lanes].*) - y0;
        const wx = (px - x0) * sc;
        const wy = py - y0;
        const sq = dx * dx + dy * dy;
        const t = @select(f64, sq > zero, @min(one, @max(zero, (wx * dx + wy * dy) / sq)), zero);
        const ex = wx - dx * t;
        const ey = wy - dy * t;
        out[i..][0..lanes].* = ex * ex + ey * ey;
    }
    while (i < ax.len) : (i += 1) {
        const dx = (bx[i] - ax[i]) * lon_scale;
        const dy = by[i] - ay[i];
        const wx = (p.lng - ax[i]) * lon_scale;
        const wy = p.lat - ay[i];
        const sq = dx * dx + dy * dy;
        const t = if (sq > 0) @min(1.0, @max(0.0, (wx * dx + wy * dy) / sq)) else 0.0;
        const ex = wx - dx * t;
        const ey = wy - dy * t;
        out[i] = ex * ex + ey * ey;
    }
}

// ---------------------------------------------------------------------------
// Tests: ported from test/util_midgard.cc and test/polyline2.cc
// ---------------------------------------------------------------------------

const testing = std.testing;

fn P(lng: f64, lat: f64) PointLL {
    return .{ .lng = lng, .lat = lat };
}

test "length" {
    try testing.expectEqual(@as(f64, 0), length(&.{}));
    try testing.expectEqual(@as(f64, 0), length(&.{P(1, 1)}));
    const pts = [_]PointLL{ P(-76.3002, 40.0433), P(-76.3036, 40.043), P(-76.3036, 40.044) };
    try testing.expectApproxEqAbs(pts[0].distance(pts[1]) + pts[1].distance(pts[2]), length(&pts), 1e-9);
}

test "trim polyline (upstream TestTrimPolyline)" {
    const line = [_]PointLL{ P(0, 0), P(0, 1), P(0, 2), P(0, 3) };
    var out: std.ArrayList(PointLL) = .empty;
    defer out.deinit(testing.allocator);

    try trimPolyline(testing.allocator, &line, 0, 1, &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectApproxEqAbs(length(&line), length(out.items), 1e-6);

    out.clearRetainingCapacity();
    try trimPolyline(testing.allocator, &line, 0.5, 1, &out);
    try testing.expectApproxEqAbs(length(&line) / 2, length(out.items), 1.0);
    try testing.expectApproxEqAbs(@as(f64, 1.5), out.items[0].lat, 1e-6);

    out.clearRetainingCapacity();
    try trimPolyline(testing.allocator, &line, 0.6, 0.4, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    out.clearRetainingCapacity();
    try trimPolyline(testing.allocator, &line, 1, 1, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(out.items[0].eql(out.items[1]));
}

test "trim front" {
    var pts: std.ArrayList(PointLL) = .empty;
    defer pts.deinit(testing.allocator);
    try pts.appendSlice(testing.allocator, &.{ P(0, 0), P(0, 0.001), P(0, 0.002) });
    var cut: std.ArrayList(PointLL) = .empty;
    defer cut.deinit(testing.allocator);
    const seg: f32 = @floatCast(P(0, 0).distance(P(0, 0.001)));
    try trimFront(testing.allocator, &pts, seg * 1.5, &cut);
    try testing.expectEqual(@as(usize, 3), cut.items.len);
    try testing.expectApproxEqAbs(@as(f64, 0.0015), cut.items[2].lat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0015), pts.items[0].lat, 1e-9);
}

test "trim shape by percent" {
    var shape: std.ArrayList(PointLL) = .empty;
    defer shape.deinit(testing.allocator);
    try shape.appendSlice(testing.allocator, &.{ P(0, 0), P(0, 1), P(0, 2), P(0, 3), P(0, 4) });
    trimShapePct(0.25, 0.75, &shape);
    try testing.expectApproxEqAbs(@as(f64, 1), shape.items[0].lat, 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 3), shape.items[shape.items.len - 1].lat, 1e-4);
}

test "resample spherical polyline keeps spacing (upstream TestResample)" {
    const line = [_]PointLL{ P(-76.299171, 40.042519), P(-76.298851, 40.042549), P(-76.297806, 40.042671), P(-76.297691, 40.042015), P(-76.296837, 40.042099) };
    var out: std.ArrayList(PointLL) = .empty;
    defer out.deinit(testing.allocator);
    try resampleSpherical(testing.allocator, &line, 10, false, &out);
    // Upstream: no two consecutive samples are further apart than the resolution (+1 m).
    for (out.items[0 .. out.items.len - 1], out.items[1..]) |a, b| try testing.expect(a.distance(b) <= 10 + 1);
    // On the first (straight) segment the spacing is exact.
    try testing.expectApproxEqAbs(@as(f64, 10), out.items[0].distance(out.items[1]), 0.01);
    const total = length(&line);
    try testing.expectEqual(@as(usize, @intFromFloat(@floor(total / 10))) + 1, out.items.len);

    out.clearRetainingCapacity();
    try resampleSpherical(testing.allocator, &line, 10, true, &out);
    for (line) |v| {
        var found = false;
        for (out.items) |q| found = found or q.eql(v);
        try testing.expect(found);
    }
}

test "uniform resample gives exactly n points ending at the last vertex" {
    const line = [_]PointLL{ P(8.0, 47.0), P(8.01, 47.0), P(8.01, 47.02) };
    var out: std.ArrayList(PointLL) = .empty;
    defer out.deinit(testing.allocator);
    for ([_]u32{ 2, 3, 10, 51 }) |n| {
        out.clearRetainingCapacity();
        try uniformResampleSpherical(testing.allocator, &line, length(&line), n, &out);
        try testing.expectEqual(@as(usize, n), out.items.len);
        try testing.expect(out.items[out.items.len - 1].eql(line[2]));
    }
}

test "planar resample ends at the last vertex" {
    const line = [_]PointLL{ P(8.0, 47.0), P(8.001, 47.0001), P(8.002, 47.0) };
    var out: std.ArrayList(PointLL) = .empty;
    defer out.deinit(testing.allocator);
    const metres: f32 = @floatCast(length(&line));
    try resamplePolyline(testing.allocator, &line, metres, 20, &out);
    try testing.expect(out.items[out.items.len - 1].eql(line[2]));
    try testing.expect(out.items.len >= 7);
    var duplicates: std.ArrayList(PointLL) = .empty;
    defer duplicates.deinit(testing.allocator);
    try resamplePolyline(testing.allocator, &.{ line[0], line[0], line[1], line[1], line[2] }, metres, 20, &duplicates);
    try testing.expectEqualSlices(PointLL, out.items, duplicates.items);
}

test "douglas peucker (upstream polyline2 Generalize)" {
    var line: std.ArrayList(PointLL) = .empty;
    defer line.deinit(testing.allocator);
    // A nearly straight line with a 1 m wiggle and one real corner.
    try line.appendSlice(testing.allocator, &.{ P(8.0, 47.0), P(8.0005, 47.000005), P(8.001, 47.0), P(8.001, 47.001), P(8.0010001, 47.002) });
    try douglasPeucker(testing.allocator, &line, 5, null);
    try testing.expectEqual(@as(usize, 3), line.items.len);
    try testing.expect(line.items[1].eql(P(8.001, 47.0)));

    line.clearRetainingCapacity();
    try line.appendSlice(testing.allocator, &.{ P(8.0, 47.0), P(8.0005, 47.000005), P(8.001, 47.0) });
    const mask = [_]bool{ false, true, false };
    try douglasPeucker(testing.allocator, &line, 5, &mask);
    try testing.expectEqual(@as(usize, 3), line.items.len);

    try douglasPeucker(testing.allocator, &line, 0, null);
    try testing.expectEqual(@as(usize, 3), line.items.len);
}

test "segment distance" {
    const r = segmentDistanceSquared(P(0, 0), P(0, 1), P(0.001, 0.5));
    try testing.expect(r.point.eql(P(0, 0.5)));
    try testing.expectApproxEqRel(@as(f64, 111.3), @sqrt(r.distance_sq), 0.01);
    try testing.expect(segmentDistanceSquared(P(0, 0), P(0, 1), P(0, -1)).point.eql(P(0, 0)));
    try testing.expect(segmentDistanceSquared(P(0, 0), P(0, 1), P(0, 2)).point.eql(P(0, 1)));
}

test "batch projection matches scalar" {
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    var ax: [37]f64 = undefined;
    var ay: [37]f64 = undefined;
    var bx: [37]f64 = undefined;
    var by: [37]f64 = undefined;
    var out: [37]f64 = undefined;
    for (0..37) |i| {
        ax[i] = r.float(f64);
        ay[i] = r.float(f64);
        bx[i] = r.float(f64);
        by[i] = r.float(f64);
    }
    by[5] = ay[5];
    bx[5] = ax[5];
    const p = P(0.5, 0.5);
    const sc = 0.7;
    projectBatchSquared(p, sc, &ax, &ay, &bx, &by, &out);
    for (0..37) |i| {
        var one: [1]f64 = undefined;
        projectBatchSquared(p, sc, ax[i..][0..1], ay[i..][0..1], bx[i..][0..1], by[i..][0..1], &one);
        try testing.expectApproxEqRel(one[0], out[i], 1e-12);
    }
}
