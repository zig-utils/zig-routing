//! Axis-aligned bounding boxes.
//!
//! Ported from valhalla/midgard/aabb2.h and src/midgard/aabb2.cc (Valhalla
//! 3.9.3), for geographic points. Contains is half-open (min edges inside,
//! max edges outside), exactly as upstream.

const std = @import("std");
const PointLL = @import("point.zig").PointLL;
const Deadline = @import("../infra/io.zig").Deadline;

pub const AABB = struct {
    minx: f64 = 0,
    miny: f64 = 0,
    maxx: f64 = 0,
    maxy: f64 = 0,

    pub fn init(minx: f64, miny: f64, maxx: f64, maxy: f64) AABB {
        return .{ .minx = minx, .miny = miny, .maxx = maxx, .maxy = maxy };
    }

    pub fn fromPoints(lo: PointLL, hi: PointLL) AABB {
        return .{ .minx = lo.lng, .miny = lo.lat, .maxx = hi.lng, .maxy = hi.lat };
    }

    /// Bounds of a non-empty point list (upstream Create).
    pub fn of(pts: []const PointLL) AABB {
        std.debug.assert(pts.len > 0);
        var b: AABB = .{ .minx = pts[0].lng, .maxx = pts[0].lng, .miny = pts[0].lat, .maxy = pts[0].lat };
        for (pts[1..]) |p| {
            if (p.lng < b.minx) b.minx = p.lng else if (p.lng > b.maxx) b.maxx = p.lng;
            if (p.lat < b.miny) b.miny = p.lat else if (p.lat > b.maxy) b.maxy = p.lat;
        }
        return b;
    }

    pub fn minpt(self: AABB) PointLL {
        return .{ .lng = self.minx, .lat = self.miny };
    }

    pub fn maxpt(self: AABB) PointLL {
        return .{ .lng = self.maxx, .lat = self.maxy };
    }

    pub fn width(self: AABB) f64 {
        return self.maxx - self.minx;
    }

    pub fn height(self: AABB) f64 {
        return self.maxy - self.miny;
    }

    pub fn center(self: AABB) PointLL {
        return .{ .lng = (self.minx + self.maxx) * 0.5, .lat = (self.miny + self.maxy) * 0.5 };
    }

    /// Half-open: points on the min edges are inside, on the max edges outside.
    pub fn contains(self: AABB, pt: PointLL) bool {
        return pt.lng >= self.minx and pt.lat >= self.miny and pt.lng < self.maxx and pt.lat < self.maxy;
    }

    pub fn covers(self: AABB, pt: PointLL) bool {
        return pt.lng >= self.minx and pt.lat >= self.miny and pt.lng <= self.maxx and pt.lat <= self.maxy;
    }

    pub fn containsBox(self: AABB, r2: AABB) bool {
        return self.contains(r2.minpt()) and self.contains(r2.maxpt());
    }

    pub fn intersects(self: AABB, r2: AABB) bool {
        return !((r2.minx < self.minx and r2.maxx < self.minx) or (r2.miny < self.miny and r2.maxy < self.miny) or
            (r2.minx > self.maxx and r2.maxx > self.maxx) or (r2.miny > self.maxy and r2.maxy > self.maxy));
    }

    /// Overlap of two boxes, or the all-zero box when they do not intersect.
    pub fn intersection(self: AABB, r2: AABB) AABB {
        if (!self.intersects(r2)) return .{};
        return .{ .minx = @max(self.minx, r2.minx), .miny = @max(self.miny, r2.miny), .maxx = @min(self.maxx, r2.maxx), .maxy = @min(self.maxy, r2.maxy) };
    }

    /// Whether segment a-b intersects (or lies inside) the box.
    pub fn intersectsSegment(self: AABB, a: PointLL, b: PointLL) bool {
        if (self.contains(a) or self.contains(b)) return true;
        if ((a.lng < self.minx and b.lng < self.minx) or (a.lat < self.miny and b.lat < self.miny) or
            (a.lng > self.maxx and b.lng > self.maxx) or (a.lat > self.maxy and b.lat > self.maxy)) return false;
        const s1 = PointLL.init(self.minx, self.miny).isLeft(a, b);
        return s1 * PointLL.init(self.minx, self.maxy).isLeft(a, b) <= 0.0 or
            s1 * PointLL.init(self.maxx, self.maxy).isLeft(a, b) <= 0.0 or
            s1 * PointLL.init(self.maxx, self.miny).isLeft(a, b) <= 0.0;
    }

    /// Whether a circle (radius in metres, approximate distance) intersects
    /// the box. Upstream takes the radius as `float`.
    pub fn intersectsCircle(self: AABB, c: PointLL, radius: f32) bool {
        if (self.contains(c)) return true;
        const r: f64 = radius;
        if (c.lng < self.minx - r or c.lat < self.miny - r or c.lng > self.maxx + r or c.lat > self.maxy + r) return false;
        const r2: f64 = @as(f32, radius * radius);
        const horizontal = std.math.clamp(c.lat, self.miny, self.maxy);
        const vertical = std.math.clamp(c.lng, self.minx, self.maxx);
        return c.distanceSquared(.{ .lng = self.minx, .lat = horizontal }) <= r2 or
            c.distanceSquared(.{ .lng = self.maxx, .lat = horizontal }) <= r2 or
            c.distanceSquared(.{ .lng = vertical, .lat = self.miny }) <= r2 or
            c.distanceSquared(.{ .lng = vertical, .lat = self.maxy }) <= r2;
    }

    pub fn expand(self: *AABB, r2: AABB) void {
        if (r2.minx < self.minx) self.minx = r2.minx;
        if (r2.miny < self.miny) self.miny = r2.miny;
        if (r2.maxx > self.maxx) self.maxx = r2.maxx;
        if (r2.maxy > self.maxy) self.maxy = r2.maxy;
    }

    /// Grows the box to include `pt`; returns whether it grew.
    pub fn expandPoint(self: *AABB, pt: PointLL) bool {
        var grew = false;
        if (pt.lng < self.minx) {
            self.minx = pt.lng;
            grew = true;
        }
        if (pt.lat < self.miny) {
            self.miny = pt.lat;
            grew = true;
        }
        if (pt.lng > self.maxx) {
            self.maxx = pt.lng;
            grew = true;
        }
        if (pt.lat > self.maxy) {
            self.maxy = pt.lat;
            grew = true;
        }
        return grew;
    }

    const Edge = enum { left, right, bottom, top };

    fn inside(self: AABB, edge: Edge, v: PointLL) bool {
        return switch (edge) {
            .left => v.lng > self.minx,
            .right => v.lng < self.maxx,
            .bottom => v.lat > self.miny,
            .top => v.lat < self.maxy,
        };
    }

    fn clipIntersection(self: AABB, edge: Edge, in: PointLL, out: PointLL) PointLL {
        const dx = out.lng - in.lng;
        const dy = out.lat - in.lat;
        const t: f64 = switch (edge) {
            .left => (self.minx - in.lng) / dx,
            .right => (self.maxx - in.lng) / dx,
            .bottom => (self.miny - in.lat) / dy,
            .top => (self.maxy - in.lat) / dy,
        };
        // Keep the clipped coordinate exactly on its boundary for adjoining
        // shapes, including when interpolation rounds outside the box.
        return switch (edge) {
            .left => .{ .lng = self.minx, .lat = in.lat + t * dy },
            .right => .{ .lng = self.maxx, .lat = in.lat + t * dy },
            .bottom => .{ .lng = in.lng + t * dx, .lat = self.miny },
            .top => .{ .lng = in.lng + t * dx, .lat = self.maxy },
        };
    }

    fn add(list: *std.ArrayList(PointLL), gpa: std.mem.Allocator, pt: PointLL) !void {
        if (list.items.len == 0 or !list.items[list.items.len - 1].eql(pt)) try list.append(gpa, pt);
    }

    fn clipEdge(self: AABB, gpa: std.mem.Allocator, edge: Edge, closed: bool, vin: []const PointLL, vout: *std.ArrayList(PointLL), deadline: Deadline) !usize {
        vout.clearRetainingCapacity();
        const n = vin.len;
        if (n == 0) return 0;
        var v1: usize = if (closed) n - 1 else 0;
        var v2: usize = 0;
        while (v2 < n) : ({
            v1 = v2;
            v2 += 1;
        }) {
            if (v2 % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const v1in = self.inside(edge, vin[v1]);
            const v2in = self.inside(edge, vin[v2]);
            if (v1in and v2in) {
                try add(vout, gpa, vin[v2]);
            } else if (!v1in and v2in) {
                try add(vout, gpa, self.clipIntersection(edge, vin[v2], vin[v1]));
                try add(vout, gpa, vin[v2]);
            } else if (v1in and !v2in) {
                try add(vout, gpa, self.clipIntersection(edge, vin[v1], vin[v2]));
            }
        }
        return vout.items.len;
    }

    /// Sutherland-Hodgman clip of a polyline or polygon to the box, in place.
    /// Returns the number of vertices left (0 when nothing is inside).
    pub fn clip(self: AABB, gpa: std.mem.Allocator, pts: *std.ArrayList(PointLL), closed: bool) !usize {
        return self.clipWithDeadline(gpa, pts, closed, .none);
    }

    pub fn clipWithDeadline(self: AABB, gpa: std.mem.Allocator, pts: *std.ArrayList(PointLL), closed: bool, deadline: Deadline) !usize {
        var tmp: std.ArrayList(PointLL) = .empty;
        defer tmp.deinit(gpa);
        if (try self.clipEdge(gpa, .left, closed, pts.items, &tmp, deadline) == 0) return clear(pts);
        if (try self.clipEdge(gpa, .right, closed, tmp.items, pts, deadline) == 0) return clear(pts);
        if (try self.clipEdge(gpa, .bottom, closed, pts.items, &tmp, deadline) == 0) return clear(pts);
        if (try self.clipEdge(gpa, .top, closed, tmp.items, pts, deadline) == 0) return clear(pts);
        return pts.items.len;
    }

    fn clear(pts: *std.ArrayList(PointLL)) usize {
        pts.clearRetainingCapacity();
        return 0;
    }
};

// ---------------------------------------------------------------------------
// Tests: ported from test/aabb2.cc where they apply to geographic boxes
// ---------------------------------------------------------------------------

const testing = std.testing;

fn P(lng: f64, lat: f64) PointLL {
    return .{ .lng = lng, .lat = lat };
}

test "construction, size and center" {
    const a = AABB.init(-1, -1, 1, 1);
    try testing.expectEqual(@as(f64, 2), a.width());
    try testing.expectEqual(@as(f64, 2), a.height());
    try testing.expect(a.center().eql(P(0, 0)));
    const b = AABB.of(&.{ P(1, 5), P(-3, 2), P(4, -1) });
    try testing.expectEqual(AABB.init(-3, -1, 4, 5), b);
}

test "contains is half-open" {
    const a = AABB.init(0, 0, 10, 10);
    try testing.expect(a.contains(P(0, 0)));
    try testing.expect(a.contains(P(5, 5)));
    try testing.expect(!a.contains(P(10, 5)));
    try testing.expect(!a.contains(P(5, 10)));
    try testing.expect(a.containsBox(AABB.init(1, 1, 9, 9)));
    try testing.expect(!a.containsBox(AABB.init(1, 1, 10, 9)));
}

test "intersects and intersection" {
    const a = AABB.init(0, 0, 10, 10);
    try testing.expect(a.intersects(AABB.init(5, 5, 15, 15)));
    try testing.expect(a.intersects(AABB.init(-5, -5, 0, 0)));
    try testing.expect(!a.intersects(AABB.init(11, 0, 12, 10)));
    try testing.expectEqual(AABB.init(5, 5, 10, 10), a.intersection(AABB.init(5, 5, 15, 15)));
    try testing.expectEqual(AABB{}, a.intersection(AABB.init(20, 20, 30, 30)));
}

test "segment intersection" {
    const a = AABB.init(0, 0, 10, 10);
    try testing.expect(a.intersectsSegment(P(-5, 5), P(15, 5)));
    try testing.expect(a.intersectsSegment(P(1, 1), P(2, 2)));
    try testing.expect(!a.intersectsSegment(P(-5, 15), P(15, 15)));
    try testing.expect(a.intersectsSegment(P(-1, 5), P(5, 11)));
    try testing.expect(!a.intersectsSegment(P(-2, 9), P(1, 13)));
}

test "circle intersection uses metres" {
    const box = AABB.init(8.0, 47.0, 8.1, 47.1);
    try testing.expect(box.intersectsCircle(P(8.05, 47.05), 1));
    // 0.01 degrees of latitude is about 1106 m.
    try testing.expect(box.intersectsCircle(P(8.05, 47.11), 1200));
    try testing.expect(!box.intersectsCircle(P(8.05, 47.11), 1000));
}

test "expand" {
    var a = AABB.init(0, 0, 1, 1);
    a.expand(AABB.init(-1, 0.5, 0.5, 3));
    try testing.expectEqual(AABB.init(-1, 0, 1, 3), a);
    try testing.expect(a.expandPoint(P(2, -2)));
    try testing.expect(!a.expandPoint(P(0, 0)));
    try testing.expectEqual(AABB.init(-1, -2, 2, 3), a);
}

test "clip polyline and polygon" {
    const box = AABB.init(0, 0, 10, 10);
    var line: std.ArrayList(PointLL) = .empty;
    defer line.deinit(testing.allocator);
    try line.appendSlice(testing.allocator, &.{ P(-5, 5), P(5, 5), P(15, 5) });
    try testing.expectEqual(@as(usize, 3), try box.clip(testing.allocator, &line, false));
    try testing.expect(line.items[0].eql(P(0, 5)));
    try testing.expect(line.items[2].eql(P(10, 5)));

    var poly: std.ArrayList(PointLL) = .empty;
    defer poly.deinit(testing.allocator);
    try poly.appendSlice(testing.allocator, &.{ P(-5, -5), P(15, -5), P(15, 15), P(-5, 15) });
    try testing.expectEqual(@as(usize, 4), try box.clip(testing.allocator, &poly, true));
    for (poly.items) |p| try testing.expect(p.lng >= 0 and p.lng <= 10 and p.lat >= 0 and p.lat <= 10);

    var outside: std.ArrayList(PointLL) = .empty;
    defer outside.deinit(testing.allocator);
    try outside.appendSlice(testing.allocator, &.{ P(20, 20), P(30, 30) });
    try testing.expectEqual(@as(usize, 0), try box.clip(testing.allocator, &outside, false));
}
