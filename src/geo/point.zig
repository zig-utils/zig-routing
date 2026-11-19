//! Geographic points and distances.
//!
//! Ported from valhalla/midgard/pointll.h, src/midgard/pointll.cc and
//! valhalla/midgard/distanceapproximator.h (Valhalla 3.9.3). Upstream's
//! `PointLL` is `GeoPoint<double>`; this is that type. Arithmetic follows
//! upstream statement by statement, including the single-precision cosine in
//! the longitude scale, so results match to the last bit where upstream's do.

const std = @import("std");
const libm = @import("libm.zig");
const k = @import("constants.zig");

/// upstream INVALID_LL: (double)0xBADBADBAD.
pub const invalid_ll: f64 = @floatFromInt(0xBADBADBAD);

/// Short signed longitude displacement from origin to longitude.
pub fn wrappedLongitudeDelta(longitude: f64, origin: f64) f64 {
    const delta = longitude - origin;
    return if (delta > 180) delta - 360 else if (delta < -180) delta + 360 else delta;
}

/// Longitude, latitude in degrees (longitude first, as upstream).
pub const PointLL = struct {
    lng: f64,
    lat: f64,

    pub const invalid: PointLL = .{ .lng = invalid_ll, .lat = invalid_ll };

    pub fn init(lng: f64, lat: f64) PointLL {
        return .{ .lng = lng, .lat = lat };
    }

    pub fn isValid(self: PointLL) bool {
        return self.lng != invalid_ll and self.lat != invalid_ll;
    }

    pub fn inRange(self: PointLL) bool {
        return -180 <= self.lng and self.lng <= 180 and -90 <= self.lat and self.lat <= 90;
    }

    pub fn eql(self: PointLL, other: PointLL) bool {
        return self.lng == other.lng and self.lat == other.lat;
    }

    /// Exact key for finite points. Equal signed zeros use the same key.
    pub fn exactKey(self: PointLL) [2]u64 {
        return .{
            if (self.lng == 0) 0 else @bitCast(self.lng),
            if (self.lat == 0) 0 else @bitCast(self.lat),
        };
    }

    /// point2.h ApproximatelyEqual with the default LL_EPSILON.
    pub fn approxEql(self: PointLL, other: PointLL) bool {
        return self.approxEqlWithin(other, k.ll_epsilon);
    }

    pub fn approxEqlWithin(self: PointLL, other: PointLL, eps: f64) bool {
        return k.approxEqual(f64, self.lng, other.lng, eps) and k.approxEqual(f64, self.lat, other.lat, eps);
    }

    /// Fixed-point form at 1e-7 degrees (the precision of OSM and of graph
    /// shapes). Rounds to nearest.
    pub fn toFixed(self: PointLL) FixedLL {
        return .{ .lng = @intFromFloat(@round(self.lng * 1e7)), .lat = @intFromFloat(@round(self.lat * 1e7)) };
    }

    /// upstream `explicit operator uint64_t`: lat in the low 31 bits, lon in
    /// the next 32, both offset to be non-negative, at 7 decimal places
    /// (truncating, as upstream's `uint64_t(x * 1e7)` does).
    pub fn encode64(self: PointLL) u64 {
        const lon: u64 = @bitCast((@as(i64, @intFromFloat(self.lng * 1e7)) +% @as(i64, 180 * 10_000_000)));
        const lat: u64 = @bitCast((@as(i64, @intFromFloat(self.lat * 1e7)) +% @as(i64, 90 * 10_000_000)));
        return ((lon & ((1 << 32) - 1)) << 31) | (lat & ((1 << 31) - 1));
    }

    /// upstream `explicit GeoPoint(uint64_t encoded)`.
    pub fn decode64(encoded: u64) PointLL {
        const lon: i64 = @intCast((encoded >> 31) & ((1 << 32) - 1));
        const lat: i64 = @intCast(encoded & ((1 << 31) - 1));
        return .{
            .lng = (@as(f64, @floatFromInt(lon)) - 180 * 1e7) * 1e-7,
            .lat = (@as(f64, @floatFromInt(lat)) - 90 * 1e7) * 1e-7,
        };
    }

    /// Point a fraction of the way along the great circle to `p` (0.5 = midpoint).
    pub fn pointAlongSegment(self: PointLL, p: PointLL, fraction: f64) PointLL {
        if (fraction == 0) return self;
        if (fraction == 1) return p;
        const lon1 = self.lng * -k.rad_per_deg_d;
        const lat1 = self.lat * k.rad_per_deg_d;
        const lon2 = p.lng * -k.rad_per_deg_d;
        const lat2 = p.lat * k.rad_per_deg_d;
        const sl1 = libm.sinF(lat1);
        const sl2 = libm.sinF(lat2);
        const cl1 = libm.cosF(lat1);
        const cl2 = libm.cosF(lat2);
        const d = libm.acosF(sl1 * sl2 + cl1 * cl2 * libm.cosF(lon1 - lon2));
        const sd = libm.sinF(d);
        const a = libm.sinF(d * (1 - fraction)) / sd;
        const b = libm.sinF(d * fraction) / sd;
        const acs1 = a * cl1;
        const bcs2 = b * cl2;
        const x = acs1 * libm.cosF(lon1) + bcs2 * libm.cosF(lon2);
        const y = acs1 * libm.sinF(lon1) + bcs2 * libm.sinF(lon2);
        const z = a * sl1 + b * sl2;
        return .{
            .lng = libm.atan2F(y, x) * -k.deg_per_rad_d,
            .lat = libm.atan2F(z, @sqrt(x * x + y * y)) * k.deg_per_rad_d,
        };
    }

    pub fn midpoint(self: PointLL, p: PointLL) PointLL {
        return self.pointAlongSegment(p, 0.5);
    }

    /// Great-circle distance in metres (haversine, clamped for stability).
    pub fn distance(self: PointLL, other: PointLL) f64 {
        if (self.eql(other)) return 0;
        const phi1 = self.lat * k.rad_per_deg_d;
        const phi2 = other.lat * k.rad_per_deg_d;
        const dphi = phi2 - phi1;
        const lambda1 = self.lng * k.rad_per_deg_d;
        const lambda2 = other.lng * k.rad_per_deg_d;
        const dlambda = lambda2 - lambda1;
        const c1 = libm.cosF(phi1);
        const c2 = libm.cosF(phi2);
        const sdphi2 = libm.sinF(dphi / 2.0);
        const sdlmb2 = libm.sinF(dlambda / 2.0);
        var h = sdphi2 * sdphi2 + c1 * c2 * sdlmb2 * sdlmb2;
        h = @min(1.0, @max(0.0, h));
        const d = 2.0 * libm.asinF(@sqrt(h));
        return k.rad_earth_meters_d * d;
    }

    /// Approximate squared distance in metres squared (DistanceApproximator
    /// centred on this point).
    pub fn distanceSquared(self: PointLL, other: PointLL) f64 {
        return DistanceApproximator.init(self).distanceSquared(other);
    }

    /// Radius in metres of the circle through this point and two others;
    /// max f64 when collinear.
    pub fn curvature(self: PointLL, ll1: PointLL, ll2: PointLL) f64 {
        const a = self.distance(ll1);
        const b = ll1.distance(ll2);
        const c = self.distance(ll2);
        const s = (a + b + c) * 0.5;
        const kk = @sqrt(s * (s - a) * (s - b) * (s - c));
        return if (std.math.isNan(kk) or kk == 0.0) std.math.floatMax(f64) else (a * b * c) / (4.0 * kk);
    }

    /// Initial bearing to `ll2` in degrees [0, 360): 0 north, 90 east.
    pub fn heading(self: PointLL, ll2: PointLL) f64 {
        if (self.eql(ll2)) return 0.0;
        const lat1 = self.lat * k.rad_per_deg_d;
        const lat2 = ll2.lat * k.rad_per_deg_d;
        const dlng = (ll2.lng - self.lng) * k.rad_per_deg_d;
        const y = libm.sinF(dlng) * libm.cosF(lat2);
        const x = libm.cosF(lat1) * libm.sinF(lat2) - libm.sinF(lat1) * libm.cosF(lat2) * libm.cosF(dlng);
        const bearing = libm.atan2F(y, x) * k.deg_per_rad_d;
        return if (bearing < 0.0) bearing + 360.0 else bearing;
    }

    pub const Closest = struct {
        point: PointLL,
        /// Metres (approximate, from the distance approximator).
        distance: f64,
        /// Segment index, or -1 when the input was empty or the pivot invalid.
        index: i32,
    };

    /// Closest point on a polyline, searching outward from `pivot_index`.
    /// Ties at a shape point go to the index furthest along the search
    /// direction. The cutoffs bound how far (in metres along the line) each
    /// direction is searched. Mirrors upstream ClosestPoint exactly.
    pub fn closestPoint(self: PointLL, pts: []const PointLL, pivot_index: i32, forward_dist_cutoff: f64, reverse_dist_cutoff: f64) Closest {
        const n: i32 = @intCast(pts.len);
        if (pts.len == 0 or pivot_index < 0 or pivot_index > n - 1)
            return .{ .point = .invalid, .distance = std.math.floatMax(f64), .index = -1 };
        var closest_segment: i32 = pivot_index;
        var closest = pts[@intCast(pivot_index)];
        const approx = DistanceApproximator.init(self);
        var mindistsqr = approx.distanceSquared(closest);

        for ([_]bool{ true, false }) |reverse| {
            var dist_cutoff = if (reverse) reverse_dist_cutoff else forward_dist_cutoff;
            const increment: i32 = if (reverse) -1 else 1;
            var indices: i32 = if (reverse) pivot_index else (n - 1) - pivot_index;
            var index: i32 = pivot_index - @intFromBool(reverse);
            while (indices > 0 and dist_cutoff > 0.0) : ({
                index += increment;
                indices -= 1;
            }) {
                const u = pts[@intCast(index)];
                const v = pts[@intCast(index + 1)];
                const bx = v.lng - u.lng;
                const by = v.lat - u.lat;
                const bx2 = bx * approx.lng_scale;
                const sq = bx2 * bx2 + by * by;
                const scale = if (sq > 0) ((self.lng - u.lng) * approx.lng_scale * bx2 + (self.lat - u.lat) * by) / sq else 0.0;
                var right_most = false;
                var point: PointLL = undefined;
                if (scale <= 0.0) {
                    point = u;
                } else if (scale >= 1.0) {
                    point = v;
                    right_most = true;
                } else {
                    point = .{ .lng = u.lng + bx * scale, .lat = u.lat + by * scale };
                }
                const sq_distance = approx.distanceSquared(point);
                if (sq_distance < mindistsqr) {
                    closest_segment = index + @intFromBool(right_most);
                    mindistsqr = sq_distance;
                    closest = point;
                }
                if (dist_cutoff != std.math.inf(f64)) dist_cutoff -= u.distance(v);
            }
        }
        return .{ .point = closest, .distance = @sqrt(mindistsqr), .index = closest_segment };
    }

    /// closestPoint over the whole line from the start.
    pub fn closestPointAll(self: PointLL, pts: []const PointLL) Closest {
        return self.closestPoint(pts, 0, std.math.inf(f64), 0);
    }

    /// Projects onto segment u-v in a plane scaled by `lon_scale` (the cosine
    /// of latitude, computed once per search by callers in tight loops).
    pub fn projectScaled(self: PointLL, u: PointLL, v: PointLL, lon_scale: f64) PointLL {
        if (u.eql(v)) return u;
        const bx = v.lng - u.lng;
        const by = v.lat - u.lat;
        const bx2 = bx * lon_scale;
        const sq = bx2 * bx2 + by * by;
        var scale = (self.lng - u.lng) * lon_scale * bx2 + (self.lat - u.lat) * by;
        if (scale <= 0.0) return u;
        if (scale >= sq) return v;
        scale /= sq;
        return .{ .lng = u.lng + bx * scale, .lat = u.lat + by * scale };
    }

    /// upstream Project(u, v) with its default lon_scale: cos(lat) of this point.
    pub fn project(self: PointLL, u: PointLL, v: PointLL) PointLL {
        return self.projectScaled(u, v, libm.cosF(self.lat * k.rad_per_deg_d));
    }

    /// Point-in-polygon by winding number. Only the first and last vertices
    /// may be duplicated (closed or open rings both work).
    pub fn withinPolygon(self: PointLL, poly: []const PointLL) bool {
        if (poly.len == 0) return false;
        const closed = poly[0].eql(poly[poly.len - 1]);
        var p1: usize = if (closed) 0 else poly.len - 1;
        var p2: usize = if (closed) 1 else 0;
        var winding: isize = 0;
        while (p2 < poly.len) : ({
            p1 = p2;
            p2 += 1;
        }) {
            const a = poly[p1];
            const b = poly[p2];
            if (a.lat <= self.lat) {
                if (b.lat > self.lat and self.isLeft(a, b) > 0) winding += 1;
            } else {
                if (b.lat <= self.lat and self.isLeft(a, b) < 0) winding -= 1;
            }
        }
        return winding != 0;
    }

    /// > 0 when this point is left of the line a->b, < 0 right, 0 on it.
    pub fn isLeft(self: PointLL, a: PointLL, b: PointLL) f64 {
        return (b.lng - a.lng) * (self.lat - a.lat) - (self.lng - a.lng) * (b.lat - a.lat);
    }
};

/// 1e-7 degree fixed point (OSM precision). Exact and compact for storage.
pub const FixedLL = extern struct {
    lng: i32,
    lat: i32,

    pub fn inRange(self: FixedLL) bool {
        return @abs(self.lng) <= 1_800_000_000 and @abs(self.lat) <= 900_000_000;
    }

    /// Coordinates after the unsigned upstream OSMNode conversion.
    pub fn toOsmPoint(fixed: FixedLL) PointLL {
        const lon: f64 = @floatFromInt(@as(i64, fixed.lng) + 1_800_000_000);
        const lat: f64 = @floatFromInt(@as(i64, fixed.lat) + 900_000_000);
        return .{ .lng = lon * 1e-7 - 180, .lat = lat * 1e-7 - 90 };
    }

    /// Valhalla E6 EdgeInfo point after shape encoding and decoding.
    pub fn toTilePoint(fixed: FixedLL) PointLL {
        const p = fixed.toOsmPoint();
        return .{ .lng = @round(p.lng * 1e6) * 1e-6, .lat = @round(p.lat * 1e6) * 1e-6 };
    }

    pub fn toPoint(self: FixedLL) PointLL {
        return .{ .lng = @as(f64, @floatFromInt(self.lng)) * 1e-7, .lat = @as(f64, @floatFromInt(self.lat)) * 1e-7 };
    }
};

/// Heading from `pts[idx0]` to the point `dist` metres along the line.
pub fn headingAlongPolyline(pts: []const PointLL, dist: f64, idx0: u32, idx1: u32) f64 {
    const n = @as(i64, idx1) - @as(i64, idx0);
    if (n < 1) return 0.0;
    if (n > 1) {
        var d: f64 = 0.0;
        var i: usize = idx0;
        while (d < dist and i + 1 <= idx1) {
            const pt0 = pts[i];
            const pt1 = pts[i + 1];
            const seglength = pt0.distance(pt1);
            if (d + seglength > dist) {
                const pct = (dist - d) / seglength;
                const ll: PointLL = .{ .lng = pt0.lng + ((pt1.lng - pt0.lng) * pct), .lat = pt0.lat + ((pt1.lat - pt0.lat) * pct) };
                return pts[idx0].heading(ll);
            }
            d += seglength;
            i += 1;
        }
    }
    return pts[idx0].heading(pts[idx1]);
}

pub fn headingAlongPolylineAll(pts: []const PointLL, dist: f64) f64 {
    if (pts.len < 2) return 0.0;
    return headingAlongPolyline(pts, dist, 0, @intCast(pts.len - 1));
}

/// Heading from the point `dist` metres before the end to `pts[idx1]`.
pub fn headingAtEndOfPolyline(pts: []const PointLL, dist: f64, idx0: u32, idx1: u32) f64 {
    const n = @as(i64, idx1) - @as(i64, idx0);
    if (n < 1) return 0.0;
    if (n > 1) {
        var d: f64 = 0.0;
        var end_i: usize = idx1;
        while (d < dist and end_i >= idx0 + 1) {
            const pt1 = pts[end_i];
            const pt0 = pts[end_i - 1];
            const seglength = pt0.distance(pt1);
            if (d + seglength > dist) {
                const pct = (dist - d) / seglength;
                const ll: PointLL = .{ .lng = pt1.lng + ((pt0.lng - pt1.lng) * pct), .lat = pt1.lat + ((pt0.lat - pt1.lat) * pct) };
                return ll.heading(pts[idx1]);
            }
            if (end_i - 1 == 0) break;
            d += seglength;
            end_i -= 1;
        }
    }
    return pts[idx0].heading(pts[idx1]);
}

pub fn headingAtEndOfPolylineAll(pts: []const PointLL, dist: f64) f64 {
    if (pts.len < 2) return 0.0;
    return headingAtEndOfPolyline(pts, dist, 0, @intCast(pts.len - 1));
}

/// Fast squared distances around a test point: exact metres of latitude and
/// metres of longitude at the test point's latitude. Under 1% error within a
/// few hundred metres; used by snapping, the A* heuristic and closest point.
pub const DistanceApproximator = struct {
    center_lat: f64,
    center_lng: f64,
    lng_scale: f64,
    m_per_lng_degree: f64,

    pub fn init(ll: PointLL) DistanceApproximator {
        const scale = lngScalePerLat(ll.lat);
        return .{ .center_lat = ll.lat, .center_lng = ll.lng, .lng_scale = scale, .m_per_lng_degree = scale * k.meters_per_degree_lat };
    }

    pub fn distanceSquared(self: DistanceApproximator, ll: PointLL) f64 {
        const dlat = (ll.lat - self.center_lat) * k.meters_per_degree_lat;
        const dlng = (ll.lng - self.center_lng) * self.m_per_lng_degree;
        return dlat * dlat + dlng * dlng;
    }

    /// Squared distances from the test point to many points at once.
    /// Same arithmetic as `distanceSquared`, lane by lane, so results are
    /// bit-identical to the scalar version.
    pub fn distanceSquaredBatch(self: DistanceApproximator, lngs: []const f64, lats: []const f64, out: []f64) void {
        std.debug.assert(lngs.len == lats.len and out.len >= lngs.len);
        const lanes = std.simd.suggestVectorLength(f64) orelse 4;
        const V = @Vector(lanes, f64);
        const clat: V = @splat(self.center_lat);
        const clng: V = @splat(self.center_lng);
        const mlat: V = @splat(k.meters_per_degree_lat);
        const mlng: V = @splat(self.m_per_lng_degree);
        var i: usize = 0;
        while (i + lanes <= lngs.len) : (i += lanes) {
            const la: V = lats[i..][0..lanes].*;
            const lo: V = lngs[i..][0..lanes].*;
            const dlat = (la - clat) * mlat;
            const dlng = (lo - clng) * mlng;
            out[i..][0..lanes].* = dlat * dlat + dlng * dlng;
        }
        while (i < lngs.len) : (i += 1) out[i] = self.distanceSquared(.{ .lng = lngs[i], .lat = lats[i] });
    }

    /// Squared distance between two points using their mid latitude.
    pub fn distanceSquaredBetween(ll1: PointLL, ll2: PointLL) f64 {
        const latm = (ll1.lat - ll2.lat) * k.meters_per_degree_lat;
        const lngm = (ll1.lng - ll2.lng) * metersPerLngDegree((ll1.lat + ll2.lat) * 0.5);
        return latm * latm + lngm * lngm;
    }

    pub fn metersPerLngDegree(lat: f64) f64 {
        return lngScalePerLat(lat) * k.meters_per_degree_lat;
    }

    /// cos(latitude). Upstream computes `cosf(lat * kRadPerDeg)`: the product
    /// in double, then the cosine in single precision.
    pub fn lngScalePerLat(lat: f64) f64 {
        const arg: f32 = @floatCast(lat * @as(f64, k.rad_per_deg));
        return @as(f64, libm.cosf32(arg));
    }
};

// ---------------------------------------------------------------------------
// Tests: ported from test/pointll.cc and test/distanceapproximator.cc
// ---------------------------------------------------------------------------

const testing = std.testing;

fn P(lng: f64, lat: f64) PointLL {
    return .{ .lng = lng, .lat = lat };
}

test "invalid and constructor" {
    var ll: PointLL = .invalid;
    try testing.expect(!ll.isValid());
    ll = P(0, 0);
    try testing.expect(ll.isValid());
    ll = .invalid;
    try testing.expect(!ll.isValid());
    const p = P(1, 2);
    try testing.expectEqual(@as(f64, 1), p.lng);
    try testing.expectEqual(@as(f64, 2), p.lat);
}

fn testAlong(l: []const PointLL, d: f64, a: f64) !void {
    try testing.expectApproxEqAbs(a, headingAlongPolylineAll(l, d), 1.0);
}

fn testEnd(l: []const PointLL, d: f64, a: f64) !void {
    try testing.expectApproxEqAbs(a, headingAtEndOfPolylineAll(l, d), 1.0);
}

const baltimore_bend = [_]PointLL{ P(-76.316360, 39.494102), P(-76.316360, 39.494129), P(-76.316376, 39.494152), P(-76.316391, 39.494175), P(-76.316422, 39.494194), P(-76.316444, 39.494209), P(-76.316483, 39.494221), P(-76.316521, 39.494228) };
const north = [_]PointLL{ P(-76.612682, 39.294540), P(-76.612681, 39.294897), P(-76.612708, 39.295208) };
const east = [_]PointLL{ P(-76.612682, 39.294540), P(-76.612508, 39.294535), P(-76.612359, 39.294541), P(-76.612151, 39.294545) };
const south = [_]PointLL{ P(-76.612682, 39.294540), P(-76.612670, 39.294447), P(-76.612666, 39.294378), P(-76.612659, 39.294280) };
const west = [_]PointLL{ P(-76.612682, 39.294540), P(-76.612789, 39.294527), P(-76.612898, 39.294525), P(-76.613033, 39.294523) };

test "heading along polyline" {
    try testing.expectApproxEqAbs(@as(f64, 0), headingAlongPolylineAll(&.{}, 30.0), 1.0);
    try testing.expectApproxEqAbs(@as(f64, 0), headingAlongPolylineAll(&.{P(-70.0, 30.0)}, 30.0), 1.0);
    try testAlong(&.{ P(-73.986392, 40.755800), P(-73.986438, 40.755819) }, 30.0, 299);
    try testAlong(&.{ P(-73.986438, 40.755819), P(-73.986484, 40.755681) }, 30.0, 194);
    try testAlong(&.{ P(-73.985777, 40.755539), P(-73.986440, 40.755820), P(-73.986617, 40.755254) }, 30.0, 299);
    try testAlong(&baltimore_bend, 30.0, 315);
    try testAlong(&north, 30.0, 0);
    try testAlong(&east, 30.0, 90);
    try testAlong(&south, 30.0, 176);
    try testAlong(&west, 30.0, 266);
}

test "heading at end of polyline" {
    try testing.expectApproxEqAbs(@as(f64, 0), headingAtEndOfPolylineAll(&.{}, 30.0), 1.0);
    try testing.expectApproxEqAbs(@as(f64, 0), headingAtEndOfPolylineAll(&.{P(-70.0, 30.0)}, 30.0), 1.0);
    try testEnd(&.{ P(-73.986392, 40.755800), P(-73.986438, 40.755819) }, 30.0, 299);
    try testEnd(&.{ P(-73.986438, 40.755819), P(-73.986484, 40.755681) }, 30.0, 194);
    try testEnd(&.{ P(-73.985777, 40.755539), P(-73.986440, 40.755820), P(-73.986617, 40.755254) }, 30.0, 194);
    try testEnd(&baltimore_bend, 30.0, 315);
    try testEnd(&north, 30.0, 356);
    try testEnd(&east, 30.0, 88);
    try testEnd(&south, 30.0, 176);
    try testEnd(&west, 30.0, 266);
}

test "heading precision" {
    try testing.expectApproxEqAbs(@as(f64, 348.954542), P(11.6057196, 48.1032867).heading(P(11.6056538, 48.1035118)), 0.000001);
}

fn tryClosestPoint(pts_in: []const PointLL, pt: PointLL, expected_pt: PointLL, expected_dist: f64, expected_idx_in: i32, expected_inverse_idx: i32, begin_idx_in: i32) !void {
    var buf: [16]PointLL = undefined;
    const pts = buf[0..pts_in.len];
    @memcpy(pts, pts_in);
    var begin_idx = begin_idx_in;
    var expected_idx = expected_idx_in;
    for (0..2) |reverse| {
        var forward = std.math.inf(f64);
        var backward: f64 = 0;
        if (reverse == 1) {
            std.mem.reverse(PointLL, pts);
            if (pts.len > 1) begin_idx = @as(i32, @intCast(pts.len - 1)) - begin_idx;
            std.mem.swap(f64, &forward, &backward);
            expected_idx = expected_inverse_idx;
        }
        const r = pt.closestPoint(pts, begin_idx, forward, backward);
        if (expected_pt.isValid()) {
            try testing.expect(r.point.approxEql(expected_pt));
        } else {
            try testing.expect(!r.point.isValid());
        }
        try testing.expectApproxEqAbs(expected_dist, r.distance, 0.5);
        try testing.expectEqual(expected_idx, r.index);
    }
}

test "closest point" {
    const max = std.math.floatMax(f64);
    try tryClosestPoint(&.{}, P(-76.299179, 40.042572), .invalid, max, -1, -1, 0);
    try tryClosestPoint(&.{P(-76.299171, 40.042519)}, P(-76.299179, 40.042572), P(-76.299171, 40.042519), 5.933, 0, 0, 0);
    const pts = [_]PointLL{ P(-76.299171, 40.042519), P(-76.298851, 40.042549), P(-76.297806, 40.042671), P(-76.297691, 40.042015), P(-76.296837, 40.042099) };
    try tryClosestPoint(&pts, P(-76.299189, 40.042572), P(-76.299171, 40.042519), 5.933, 0, 4, 0);
    try tryClosestPoint(&pts, P(-76.298477, 40.042645), P(-76.298470, 40.042595), 5.592, 1, 2, 0);
    try tryClosestPoint(&pts, P(-76.297806, 40.042671), P(-76.297806, 40.042671), 0.0, 2, 2, 0);
    try tryClosestPoint(&pts, P(-76.297752, 40.042183), P(-76.297722, 40.042187), 2.592, 2, 1, 0);
    try tryClosestPoint(&pts, P(-76.297752, 40.042183), P(-76.297722, 40.042187), 2.592, 2, 1, 2);
    try tryClosestPoint(&pts, P(-76.297020, 40.042133), P(-76.297012, 40.042084), 5.491, 3, 0, 0);
    try tryClosestPoint(&pts, P(-76.296700, 40.042114), P(-76.296837, 40.042099), 11.78, 4, 0, 0);
    try tryClosestPoint(&pts, P(-76.296700, 40.042114), P(-76.296837, 40.042099), 11.78, 4, 0, 4);
    try tryClosestPoint(&pts, P(-76.299179, 40.042572), .invalid, max, -1, -1, 5);

    const shape = [_]PointLL{ P(-97.2987, 50.4072), P(-97.3208, 50.4265) };
    const r = P(-97.3014, 50.4212).closestPointAll(&shape);
    try testing.expect(r.point.approxEql(P(-97.310097, 50.417156)));
    try testing.expectEqual(@as(i32, 0), r.index);
}

test "within convex polygon" {
    const pts = [_]PointLL{ P(2.0, 2.0), P(0.0, 4.0), P(-10.0, 0.0), P(0.0, -4.0), P(2.0, -2.0) };
    try testing.expect(P(0.0, 0.0).withinPolygon(&pts));
    try testing.expect(P(0.0, -3.99).withinPolygon(&pts));
    try testing.expect(P(1.99, -2.0).withinPolygon(&pts));
    try testing.expect(!P(15.0, 4.0).withinPolygon(&pts));
    try testing.expect(!P(2.5, 0.0).withinPolygon(&pts));
    try testing.expect(!P(-3.0, 3.0).withinPolygon(&pts));
    try testing.expect(!P(1.0, -3.5).withinPolygon(&pts));
}

fn expectLL(a: PointLL, b: PointLL) !void {
    try testing.expectApproxEqAbs(b.lng, a.lng, 1e-7);
    try testing.expectApproxEqAbs(b.lat, a.lat, 1e-7);
}

test "mid point" {
    try expectLL(P(0, 90).midpoint(P(0, 0)), P(0, 45));
    try expectLL(P(0, 90).midpoint(P(0, -66)), P(0, 12));
    try testing.expectEqual(@as(f64, 90), P(-23, 45).midpoint(P(157, 45)).lat);
    try testing.expect(P(-15, 45).midpoint(P(15, 45)).lat > 45.1);
    try testing.expect(P(-80, 1).midpoint(P(80, 1)).lat > 1.1);
    try testing.expect(P(-15, -45).midpoint(P(15, -45)).lat < -45.1);
    try testing.expect(P(-80, -1).midpoint(P(80, -1)).lat < -1.1);
    try expectLL(P(-15, 0).midpoint(P(15, 0)), P(0, 0));
    try expectLL(P(-170, 0).midpoint(P(160, 0)), P(175, 0));

    var mid = P(-12.5, 4).pointAlongSegment(P(7.123, -18.945), 0.33);
    try testing.expectApproxEqAbs(0.33 * P(-12.5, 4).distance(P(7.123, -18.945)), P(-12.5, 4).distance(mid), 1e-8);
    mid = P(81.2366, -34.54987).pointAlongSegment(P(-176.123, 81.945), 0.66);
    try testing.expectApproxEqAbs(0.66 * P(81.2366, -34.54987).distance(P(-176.123, 81.945)), P(81.2366, -34.54987).distance(mid), 1e-8);
}

test "distance" {
    try testing.expectEqual(k.pi_d * k.rad_earth_meters_d, P(-90.0, 0.0).distance(P(90.0, 0.0)));
    try testing.expectEqual(@as(f64, 0), P(-90.0, 0.0).distance(P(-90.0, 0.0)));
    try testing.expectApproxEqAbs(@as(f64, 556599.5), P(45.0, 45.0).distance(P(45.0, 40.0)), 1.0);
}

test "64-bit encoding round-trips at 7 digits" {
    const p = P(-76.299171, 40.042519);
    const back = PointLL.decode64(p.encode64());
    try testing.expectApproxEqAbs(p.lng, back.lng, 1.5e-7);
    try testing.expectApproxEqAbs(p.lat, back.lat, 1.5e-7);
    const f = p.toFixed();
    try testing.expectEqual(@as(i32, -762991710), f.lng);
    try testing.expectApproxEqAbs(p.lat, f.toPoint().lat, 1e-9);
}

test "distance approximator (test/distanceapproximator.cc)" {
    // Upstream checks the approximation against true distance within 1% for nearby points.
    const a = P(-76.299171, 40.042519);
    const approx = DistanceApproximator.init(a);
    for ([_]PointLL{ P(-76.298851, 40.042549), P(-76.297806, 40.042671), P(-76.296837, 40.042099) }) |b| {
        const exact = a.distance(b);
        const est = @sqrt(approx.distanceSquared(b));
        try testing.expect(@abs(est - exact) / exact < 0.01);
        try testing.expectApproxEqRel(est * est, DistanceApproximator.distanceSquaredBetween(a, b), 0.01);
    }
    try testing.expectEqual(@as(f64, 0), approx.distanceSquared(a));
    // The longitude scale is computed with a single-precision cosine, as upstream.
    try testing.expectEqual(@as(f64, libm.cosf32(@as(f32, @floatCast(40.0 * @as(f64, k.rad_per_deg))))), DistanceApproximator.lngScalePerLat(40.0));
}

test "batch squared distance is bit-identical to scalar" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const center = P(8.54, 47.37);
    const approx = DistanceApproximator.init(center);
    var lngs: [1003]f64 = undefined;
    var lats: [1003]f64 = undefined;
    var out: [1003]f64 = undefined;
    for (&lngs, &lats) |*lo, *la| {
        lo.* = center.lng + (r.float(f64) - 0.5) * 0.2;
        la.* = center.lat + (r.float(f64) - 0.5) * 0.2;
    }
    approx.distanceSquaredBatch(&lngs, &lats, &out);
    for (lngs, lats, out) |lo, la, o| try testing.expectEqual(approx.distanceSquared(P(lo, la)), o);
}

test "projection onto a segment" {
    const u = P(0, 0);
    const v = P(0, 1);
    try expectLL(P(0.5, 0.5).project(u, v), P(0, 0.5));
    try expectLL(P(0.5, -1).project(u, v), u);
    try expectLL(P(0.5, 2).project(u, v), v);
    try expectLL(P(3, 3).project(u, u), u);
}
