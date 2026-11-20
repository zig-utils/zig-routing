// Ported from src/loki/polygon_search.cc and src/mjolnir/adminbuilder.cc for
// ring queries and assembly. Clipping and repair use the planar coordinates
// directly. Callers must unwrap geometries that cross the antimeridian.

const std = @import("std");
const PointLL = @import("point.zig").PointLL;
const AABB = @import("aabb.zig").AABB;
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;

/// Closure is implicit. Readers also accept one repeated closing vertex.
pub const Ring = []const PointLL;
pub const Location = enum { outside, boundary, inside };
pub const Winding = enum { clockwise, counterclockwise, degenerate };
pub const Role = enum { outer, inner };
pub const Fragment = struct { points: []const PointLL, role: Role = .outer };

pub const Polygon = struct {
    outer: Ring,
    holes: []const Ring = &.{},

    /// Prefer an interior representative. A shell vertex is still part of
    /// the polygon when both interior candidates fall in a hole.
    pub fn representative(self: Polygon, deadline: Deadline) !?PointLL {
        const bounds = try ringBounds(self.outer, deadline) orelse return null;
        const center = bounds.center();
        if (try self.locate(center, deadline) == .inside) return center;
        if (try interiorPoint(self.outer, deadline)) |inside| {
            if (try self.locate(inside, deadline) == .inside) return inside;
        }
        return self.outer[0];
    }

    pub fn locate(self: Polygon, point: PointLL, deadline: Deadline) error{DeadlineExceeded}!Location {
        const shell = try locateInRing(self.outer, point, deadline);
        if (shell != .inside) return shell;
        for (self.holes, 0..) |hole, i| {
            try checkAt(deadline, i);
            switch (try locateInRing(hole, point, deadline)) {
                .inside => return .outside,
                .boundary => return .boundary,
                .outside => {},
            }
        }
        return .inside;
    }

    /// Closed-set intersection. Touching the shell or a hole boundary counts.
    pub fn intersectsLine(self: Polygon, line: []const PointLL, deadline: Deadline) error{DeadlineExceeded}!bool {
        if (line.len == 0) return false;
        if (try self.locate(line[0], deadline) != .outside) return true;
        for (line[0 .. line.len - 1], line[1..], 0..) |a, b, i| {
            try checkAt(deadline, i);
            for (self.holes, 0..) |hole, j| {
                try checkAt(deadline, j);
                if (try ringIntersectsSegment(hole, a, b, deadline)) return true;
            }
            if (try ringIntersectsSegment(self.outer, a, b, deadline)) return true;
        }
        return false;
    }

    pub fn intersectsBox(self: Polygon, box: AABB, deadline: Deadline) error{DeadlineExceeded}!bool {
        if (!validBox(box)) return false;
        const shell = vertices(self.outer);
        if (shell.len < 3) return false;
        if (box.covers(shell[0])) return true;
        const lo = box.minpt();
        const hi = box.maxpt();
        return self.intersectsLine(&.{ lo, .init(hi.lng, lo.lat), hi, .init(lo.lng, hi.lat), lo }, deadline);
    }

    /// Closed-set coverage for simple shells and their holes. A covered
    /// boundary cannot enter the complement. The only bounded components
    /// of that complement are the holes, so test an interior point of each.
    pub fn coversPolygon(self: Polygon, other: Polygon, gpa: Allocator, deadline: Deadline) !bool {
        const parent = try ringBounds(self.outer, deadline) orelse return false;
        const child = try ringBounds(other.outer, deadline) orelse return false;
        if (!parent.covers(child.minpt()) or !parent.covers(child.maxpt())) return false;
        var cuts: std.ArrayList(f64) = .empty;
        defer cuts.deinit(gpa);
        if (!try self.coversRing(other.outer, gpa, &cuts, deadline)) return false;
        for (other.holes, 0..) |hole, i| {
            try checkAt(deadline, i);
            if (!try self.coversRing(hole, gpa, &cuts, deadline)) return false;
        }
        for (self.holes, 0..) |hole, i| {
            try checkAt(deadline, i);
            if (try interiorPoint(hole, deadline)) |sample| {
                if (try other.locate(sample, deadline) == .inside) return false;
            }
        }
        return true;
    }

    fn coversRing(self: Polygon, input: Ring, gpa: Allocator, cuts: *std.ArrayList(f64), deadline: Deadline) !bool {
        const ring = vertices(input);
        if (ring.len < 3) return false;
        var a = ring[ring.len - 1];
        for (ring, 0..) |b, i| {
            try checkAt(deadline, i);
            if (!a.eql(b) and !try self.coversSegment(a, b, gpa, cuts, deadline)) return false;
            a = b;
        }
        return true;
    }

    noinline fn coversSegment(self: Polygon, a: PointLL, b: PointLL, gpa: Allocator, cuts: *std.ArrayList(f64), deadline: Deadline) !bool {
        cuts.clearRetainingCapacity();
        const segment: CoverageSegment = .{ .a = a, .b = b, .bounds = segmentBounds(a, b) };
        switch (try cutAtBorder(self.outer, segment, gpa, cuts, deadline)) {
            .on_border => return true,
            .crosses => return false,
            .touches => {},
        }
        for (self.holes, 0..) |hole, i| {
            try checkAt(deadline, i);
            switch (try cutAtBorder(hole, segment, gpa, cuts, deadline)) {
                .on_border => return true,
                .crosses => return false,
                .touches => {},
            }
        }
        try cuts.append(gpa, 1);
        std.sort.heap(f64, cuts.items, {}, std.sort.asc(f64));
        var previous: f64 = 0;
        for (cuts.items, 0..) |t, i| {
            try checkAt(deadline, i);
            if (t <= previous) continue;
            const halfway = previous + (t - previous) * 0.5;
            const sample = PointLL.init(a.lng + (b.lng - a.lng) * halfway, a.lat + (b.lat - a.lat) * halfway);
            if (try self.locate(sample, deadline) == .outside) return false;
            previous = t;
        }
        return true;
    }
};

const BorderCut = enum { on_border, crosses, touches };
const CoverageSegment = struct { a: PointLL, b: PointLL, bounds: AABB };

fn cutAtBorder(input: Ring, segment: CoverageSegment, gpa: Allocator, cuts: *std.ArrayList(f64), deadline: Deadline) !BorderCut {
    const ring = vertices(input);
    if (ring.len < 3) return .touches;
    const a = segment.a;
    const b = segment.b;
    const use_longitude = @abs(b.lng - a.lng) >= @abs(b.lat - a.lat);
    var previous = ring[ring.len - 1];
    for (ring, 0..) |q, i| {
        try checkAt(deadline, i);
        defer previous = q;
        const bounds = segmentBounds(previous, q);
        if (!segment.bounds.intersects(bounds)) continue;
        const side_p = orient(a, b, previous);
        const side_q = orient(a, b, q);
        if (side_p == 0 and side_q == 0 and bounds.covers(a) and bounds.covers(b)) return .on_border;
        if (side_p != 0 and side_q == -side_p) {
            const side_a = orient(previous, q, a);
            if (side_a != 0 and orient(previous, q, b) == -side_a) return .crosses;
        }
        // A shell vertex can touch or pass through the candidate line.
        // Split there and test the open intervals separately.
        if (side_q == 0 and segment.bounds.covers(q)) {
            const t = if (use_longitude) (q.lng - a.lng) / (b.lng - a.lng) else (q.lat - a.lat) / (b.lat - a.lat);
            if (t > 0 and t < 1) try cuts.append(gpa, t);
        }
    }
    return .touches;
}

fn interiorPoint(input: Ring, deadline: Deadline) !?PointLL {
    const ring = vertices(input);
    if (ring.len < 3) return null;
    var first = std.math.inf(f64);
    var second = first;
    for (ring, 0..) |point, i| {
        try checkAt(deadline, i);
        if (point.lat < first) {
            second = first;
            first = point.lat;
        } else if (point.lat > first and point.lat < second) {
            second = point.lat;
        }
    }
    if (!std.math.isFinite(second)) return null;
    const y = first + (second - first) * 0.5;
    var left = std.math.inf(f64);
    var right = left;
    var a = ring[ring.len - 1];
    for (ring, 0..) |b, i| {
        try checkAt(deadline, i);
        defer a = b;
        if ((a.lat > y) == (b.lat > y)) continue;
        const x = a.lng + (b.lng - a.lng) * ((y - a.lat) / (b.lat - a.lat));
        if (x < left) {
            right = left;
            left = x;
        } else if (x > left and x < right) {
            right = x;
        }
    }
    if (!std.math.isFinite(right)) return null;
    return .init(left + (right - left) * 0.5, y);
}

pub const MultiPolygon = struct {
    polygons: []const Polygon = &.{},
    storage: std.heap.ArenaAllocator,

    pub fn deinit(self: *MultiPolygon) void {
        self.storage.deinit();
        self.polygons = &.{};
    }
};

fn checkAt(deadline: Deadline, i: usize) error{DeadlineExceeded}!void {
    if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

fn finite(point: PointLL) bool {
    return std.math.isFinite(point.lng) and std.math.isFinite(point.lat);
}

fn validBox(box: AABB) bool {
    return finite(box.minpt()) and finite(box.maxpt()) and box.minx <= box.maxx and box.miny <= box.maxy;
}

fn vertices(ring: Ring) Ring {
    if (ring.len > 1 and ring[0].eql(ring[ring.len - 1])) return ring[0 .. ring.len - 1];
    return ring;
}

pub fn ringBounds(ring: Ring, deadline: Deadline) !?AABB {
    if (ring.len < 3) return null;
    var box = AABB.fromPoints(ring[0], ring[0]);
    for (ring, 0..) |point, i| {
        try checkAt(deadline, i);
        if (!finite(point)) return error.InvalidGeometry;
        _ = box.expandPoint(point);
    }
    return box;
}

/// Test the boundary of a closed ring against a box.
pub fn ringIntersectsBox(input: Ring, box: AABB, deadline: Deadline) error{DeadlineExceeded}!bool {
    const ring = vertices(input);
    if (ring.len < 3) return false;
    var a = ring[ring.len - 1];
    for (ring, 0..) |b, i| {
        try checkAt(deadline, i);
        if (box.intersectsSegment(a, b)) return true;
        a = b;
    }
    return false;
}

/// Planar signed area in squared coordinate units. Positive is CCW.
pub fn signedArea(input: Ring, deadline: Deadline) error{DeadlineExceeded}!f64 {
    const ring = vertices(input);
    if (ring.len < 3) return 0;
    const origin = ring[0];
    var sum: f64 = 0;
    var correction: f64 = 0;
    for (ring[1 .. ring.len - 1], ring[2..], 0..) |a, b, i| {
        try checkAt(deadline, i);
        const adjusted = origin.isLeft(a, b) - correction;
        const next = sum + adjusted;
        correction = (next - sum) - adjusted;
        sum = next;
    }
    return sum * 0.5;
}

pub fn winding(ring: Ring, deadline: Deadline) error{DeadlineExceeded}!Winding {
    const area = try signedArea(ring, deadline);
    if (area > 0) return .counterclockwise;
    if (area < 0) return .clockwise;
    return .degenerate;
}

/// Use a wider determinant near collinearity. This keeps boundary and
/// segment tests consistent for close geographic coordinates.
fn orient(a: PointLL, b: PointLL, point: PointLL) i2 {
    const left = (b.lng - a.lng) * (point.lat - a.lat);
    const right = (b.lat - a.lat) * (point.lng - a.lng);
    const det = left - right;
    if (@abs(det) > (@abs(left) + @abs(right)) * (4 * std.math.floatEps(f64)))
        return if (det > 0) 1 else -1;
    const x0: f128 = a.lng;
    const y0: f128 = a.lat;
    const wide = (@as(f128, b.lng) - x0) * (@as(f128, point.lat) - y0) -
        (@as(f128, b.lat) - y0) * (@as(f128, point.lng) - x0);
    return if (wide > 0) 1 else if (wide < 0) -1 else 0;
}

fn segmentBounds(a: PointLL, b: PointLL) AABB {
    return .init(@min(a.lng, b.lng), @min(a.lat, b.lat), @max(a.lng, b.lng), @max(a.lat, b.lat));
}

pub fn locateInRing(input: Ring, point: PointLL, deadline: Deadline) error{DeadlineExceeded}!Location {
    const ring = vertices(input);
    if (ring.len < 3 or !finite(point)) return .outside;
    var inside = false;
    var a = ring[ring.len - 1];
    for (ring, 0..) |b, i| {
        try checkAt(deadline, i);
        if (!a.eql(b) and point.lat >= @min(a.lat, b.lat) and point.lat <= @max(a.lat, b.lat)) {
            const side = orient(a, b, point);
            if (side == 0 and segmentBounds(a, b).covers(point)) return .boundary;
            // Half-open ray crossings avoid counting a shared vertex twice.
            if ((a.lat > point.lat) != (b.lat > point.lat) and (side > 0) == (b.lat > a.lat))
                inside = !inside;
        }
        a = b;
    }
    return if (inside) .inside else .outside;
}

pub fn segmentsIntersect(a: PointLL, b: PointLL, c: PointLL, d: PointLL) bool {
    const ab = segmentBounds(a, b);
    const cd = segmentBounds(c, d);
    if (!ab.intersects(cd)) return false;
    const ac = orient(a, b, c);
    const ad = orient(a, b, d);
    const ca = orient(c, d, a);
    const cb = orient(c, d, b);
    if (ac == 0 and ab.covers(c) or ad == 0 and ab.covers(d) or
        ca == 0 and cd.covers(a) or cb == 0 and cd.covers(b)) return true;
    return ac * ad < 0 and ca * cb < 0;
}

fn ringIntersectsSegment(input: Ring, a: PointLL, b: PointLL, deadline: Deadline) error{DeadlineExceeded}!bool {
    const ring = vertices(input);
    if (ring.len < 3) return false;
    var prev = ring[ring.len - 1];
    for (ring, 0..) |next, i| {
        try checkAt(deadline, i);
        if (segmentsIntersect(a, b, prev, next)) return true;
        prev = next;
    }
    return false;
}

/// Liang-Barsky clipping of the finite segment against a closed box.
pub fn clipSegment(a: PointLL, b: PointLL, box: AABB) ?[2]PointLL {
    if (!validBox(box) or !finite(a) or !finite(b)) return null;
    const dx = b.lng - a.lng;
    const dy = b.lat - a.lat;
    const slope = [4]f64{ -dx, dx, -dy, dy };
    const gap = [4]f64{ a.lng - box.minx, box.maxx - a.lng, a.lat - box.miny, box.maxy - a.lat };
    var start: f64 = 0;
    var end: f64 = 1;
    var entry: u4 = 0;
    var exit: u4 = 0;
    for (slope, gap, 0..) |coefficient, distance, i| {
        if (coefficient == 0) {
            if (distance < 0) return null;
            continue;
        }
        const t = distance / coefficient;
        const side: u4 = @as(u4, 1) << @as(u2, @intCast(i));
        if (coefficient < 0 and t >= start) {
            entry = (if (t == start) entry else 0) | side;
            start = t;
        } else if (coefficient > 0 and t <= end) {
            exit = (if (t == end) exit else 0) | side;
            end = t;
        }
        if (start > end) return null;
    }
    if (start == end) {
        const contact = segmentPoint(a, b, start, box, entry | exit);
        return .{ contact, contact };
    }
    return .{ segmentPoint(a, b, start, box, entry), segmentPoint(a, b, end, box, exit) };
}

fn segmentPoint(a: PointLL, b: PointLL, t: f64, box: AABB, sides: u4) PointLL {
    if (t == 0) return a;
    if (t == 1) return b;
    return .{
        .lng = if (sides & 1 != 0) box.minx else if (sides & 2 != 0) box.maxx else std.math.clamp(a.lng + t * (b.lng - a.lng), box.minx, box.maxx),
        .lat = if (sides & 4 != 0) box.miny else if (sides & 8 != 0) box.maxy else std.math.clamp(a.lat + t * (b.lat - a.lat), box.miny, box.maxy),
    };
}

/// Appends clipped paths to the caller's lists. Each range is one connected
/// run of the input path. Isolated point contacts add no line.
pub const LineRange = struct { start: usize, end: usize };

pub fn clipPolyline(
    gpa: Allocator,
    line: []const PointLL,
    box: AABB,
    points: *std.ArrayList(PointLL),
    parts: *std.ArrayList(LineRange),
    deadline: Deadline,
) !void {
    if (line.len < 2) return;
    const first_point = points.items.len;
    const first_part = parts.items.len;
    errdefer points.shrinkRetainingCapacity(first_point);
    errdefer parts.shrinkRetainingCapacity(first_part);
    var joins_previous = false;
    for (line[0 .. line.len - 1], line[1..], 0..) |a, b, i| {
        try checkAt(deadline, i);
        const cut = clipSegment(a, b, box) orelse {
            joins_previous = false;
            continue;
        };
        if (cut[0].eql(cut[1])) {
            if (!box.covers(a) or !box.covers(b)) joins_previous = false;
            continue;
        }
        if (!joins_previous) {
            try parts.append(gpa, .{ .start = points.items.len, .end = 0 });
            try points.append(gpa, cut[0]);
        }
        try points.append(gpa, cut[1]);
        parts.items[parts.items.len - 1].end = points.items.len;
        joins_previous = box.covers(b);
    }
}

const BuiltRing = struct { points: []PointLL, area: f64, role: Role };

/// Adjacency lists for a planar boundary. Assembly inputs are undirected.
/// Clipping emits directed boundary fragments with the filled side on the left.
const Boundary = struct {
    const Vertex = struct {
        point: PointLL,
        head: ?usize = null,
        degree: usize = 0,
        seen: bool = false,
        trail_index: ?usize = null,
    };
    const Arc = struct { to: usize, next: ?usize, reverse: ?usize, used: bool = false };

    gpa: Allocator,
    by_point: std.AutoHashMapUnmanaged([2]u64, usize) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    arcs: std.ArrayList(Arc) = .empty,
    trail: std.ArrayList(usize) = .empty,
    points: std.ArrayList(PointLL) = .empty,

    fn vertex(self: *Boundary, point: PointLL) !usize {
        if (!finite(point)) return error.InvalidGeometry;
        const entry = try self.by_point.getOrPut(self.gpa, point.exactKey());
        if (!entry.found_existing) {
            entry.value_ptr.* = self.vertices.items.len;
            try self.vertices.append(self.gpa, .{ .point = point });
        }
        return entry.value_ptr.*;
    }

    fn appendArc(self: *Boundary, from: usize, to: usize, reverse: ?usize) !void {
        const v = &self.vertices.items[from];
        const index = self.arcs.items.len;
        try self.arcs.append(self.gpa, .{ .to = to, .next = v.head, .reverse = reverse });
        v.head = index;
        v.degree += 1;
    }

    fn add(self: *Boundary, a: PointLL, b: PointLL, comptime directed: bool) !void {
        const from = try self.vertex(a);
        const to = try self.vertex(b);
        if (from == to) return;
        const index = self.arcs.items.len;
        try self.appendArc(from, to, if (directed) null else index + 1);
        if (!directed) try self.appendArc(to, from, index);
    }

    fn follow(self: *Boundary, from: usize, deadline: Deadline) !?usize {
        const v = &self.vertices.items[from];
        var steps: usize = 0;
        while (v.head) |index| : (steps += 1) {
            try checkAt(deadline, steps);
            const arc = self.arcs.items[index];
            v.head = arc.next;
            if (arc.used) continue;
            if (arc.reverse) |reverse| self.arcs.items[reverse].used = true;
            return arc.to;
        }
        return null;
    }

    fn emit(
        self: *Boundary,
        ids: []const usize,
        output: Allocator,
        rings: *std.ArrayList(BuiltRing),
        role: ?Role,
        deadline: Deadline,
    ) !void {
        if (ids.len < 3) return;
        self.points.clearRetainingCapacity();
        try self.points.ensureTotalCapacity(self.gpa, ids.len);
        for (ids, 0..) |id, i| {
            try checkAt(deadline, i);
            self.points.appendAssumeCapacity(self.vertices.items[id].point);
        }
        const area = try signedArea(self.points.items, deadline);
        if (area == 0) return;
        try rings.append(self.gpa, .{
            .points = try output.dupe(PointLL, self.points.items),
            .area = area,
            .role = role orelse if (area > 0) .outer else .inner,
        });
    }

    /// Cut closed sub-trails as soon as a vertex repeats. This separates
    /// touching lobes without guessing which branch comes next at the touch.
    fn walk(
        self: *Boundary,
        start: usize,
        output: Allocator,
        rings: *std.ArrayList(BuiltRing),
        role: ?Role,
        repair_gap: bool,
        deadline: Deadline,
    ) !void {
        var current = start;
        var steps: usize = 0;
        while (true) : (steps += 1) {
            try checkAt(deadline, steps);
            const v = &self.vertices.items[current];
            if (v.trail_index) |first| {
                try self.emit(self.trail.items[first..], output, rings, role, deadline);
                try self.clearTrailAfter(first + 1, deadline);
            } else {
                v.trail_index = self.trail.items.len;
                try self.trail.append(self.gpa, current);
            }
            current = try self.follow(current, deadline) orelse break;
        }
        if (self.trail.items.len > 1) {
            if (role == null) return error.InvalidGeometry;
            if (repair_gap and try self.canCloseGap(deadline))
                try self.emit(self.trail.items, output, rings, role, deadline);
        }
        try self.clearTrailAfter(0, deadline);
    }

    fn clearTrailAfter(self: *Boundary, keep: usize, deadline: Deadline) !void {
        for (self.trail.items[keep..], 0..) |id, i| {
            try checkAt(deadline, i);
            self.vertices.items[id].trail_index = null;
        }
        self.trail.shrinkRetainingCapacity(keep);
    }

    fn canCloseGap(self: *const Boundary, deadline: Deadline) !bool {
        const ids = self.trail.items;
        if (ids.len < 3) return false;
        const a = self.vertices.items[ids[0]].point;
        const b = self.vertices.items[ids[ids.len - 1]].point;
        const next = self.vertices.items[ids[1]].point;
        const prev = self.vertices.items[ids[ids.len - 2]].point;
        if (orient(a, b, next) == 0 and segmentBounds(a, b).covers(next) or
            orient(a, b, prev) == 0 and segmentBounds(a, b).covers(prev)) return false;
        for (ids[1 .. ids.len - 2], ids[2 .. ids.len - 1], 0..) |from, to, i| {
            try checkAt(deadline, i);
            if (segmentsIntersect(a, b, self.vertices.items[from].point, self.vertices.items[to].point))
                return false;
        }
        return true;
    }

    fn assemble(
        self: *Boundary,
        output: Allocator,
        rings: *std.ArrayList(BuiltRing),
        role: Role,
        deadline: Deadline,
    ) !void {
        var component: std.ArrayList(usize) = .empty;
        for (self.vertices.items, 0..) |*root, start| {
            try checkAt(deadline, start);
            if (root.seen) continue;
            component.clearRetainingCapacity();
            root.seen = true;
            try component.append(self.gpa, start);
            var scan: usize = 0;
            var first_odd: usize = undefined;
            var odd_count: usize = 0;
            while (scan < component.items.len) : (scan += 1) {
                try checkAt(deadline, scan);
                const v = self.vertices.items[component.items[scan]];
                if (v.degree % 2 != 0) {
                    if (odd_count == 0) first_odd = component.items[scan];
                    odd_count += 1;
                }
                var arc_index = v.head;
                var steps: usize = 0;
                while (arc_index) |index| : (steps += 1) {
                    try checkAt(deadline, steps);
                    const arc = self.arcs.items[index];
                    arc_index = arc.next;
                    const neighbor = &self.vertices.items[arc.to];
                    if (neighbor.seen) continue;
                    neighbor.seen = true;
                    try component.append(self.gpa, arc.to);
                }
            }
            // Close a single unambiguous gap. At a fork, only keep actual
            // cycles and never connect unrelated dangling branches.
            if (odd_count == 2) try self.walk(first_odd, output, rings, role, true, deadline);
            if (odd_count > 2) {
                for (component.items, 0..) |id, i| {
                    try checkAt(deadline, i);
                    if (self.vertices.items[id].degree % 2 != 0 and self.vertices.items[id].head != null)
                        try self.walk(id, output, rings, role, false, deadline);
                }
            }
            for (component.items, 0..) |id, i| {
                try checkAt(deadline, i);
                if (self.vertices.items[id].head != null) try self.walk(id, output, rings, role, false, deadline);
            }
        }
    }

    fn extractDirected(
        self: *Boundary,
        output: Allocator,
        rings: *std.ArrayList(BuiltRing),
        deadline: Deadline,
    ) !void {
        for (self.vertices.items, 0..) |v, id| {
            try checkAt(deadline, id);
            if (v.head != null) try self.walk(id, output, rings, null, false, deadline);
        }
    }
};

/// Join unordered, arbitrarily oriented fragments. Equal coordinates form
/// a junction. Give touching fragments an explicit vertex at the junction.
/// Duplicate consecutive vertices and zero-area trails disappear.
/// Holes belong to the smallest shell containing them. Uncontained inner
/// rings are discarded. Output shells are CCW and holes are CW.
pub fn assemble(gpa: Allocator, fragments: []const Fragment, deadline: Deadline) !MultiPolygon {
    var output: MultiPolygon = .{ .storage = .init(gpa) };
    errdefer output.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const owned = output.storage.allocator();
    var rings: std.ArrayList(BuiltRing) = .empty;
    for ([_]Role{ .outer, .inner }) |role| {
        var boundary: Boundary = .{ .gpa = temp };
        for (fragments, 0..) |fragment, i| {
            try checkAt(deadline, i);
            const pts = fragment.points;
            if (fragment.role != role or pts.len < 2) continue;
            for (pts[0 .. pts.len - 1], pts[1..], 0..) |a, b, j| {
                try checkAt(deadline, j);
                try boundary.add(a, b, false);
            }
        }
        try boundary.assemble(owned, &rings, role, deadline);
    }
    output.polygons = try groupRings(temp, owned, rings.items, .counterclockwise, deadline);
    return output;
}

/// Nest preassembled CCW shells and CW holes, splitting rings that touch at
/// repeated vertices. Temporary storage uses the scratch arena and the
/// returned rings and polygons use the result arena.
pub fn nestOrientedRings(temp: Allocator, owned: Allocator, input: []const Ring, deadline: Deadline) ![]const Polygon {
    var boundary: Boundary = .{ .gpa = temp };
    for (input, 0..) |line, i| {
        try checkAt(deadline, i);
        const ring = vertices(line);
        if (ring.len < 3) continue;
        var prev = ring[ring.len - 1];
        for (ring, 0..) |next, j| {
            try checkAt(deadline, j);
            try boundary.add(prev, next, true);
            prev = next;
        }
    }
    var rings: std.ArrayList(BuiltRing) = .empty;
    try boundary.extractDirected(owned, &rings, deadline);
    return groupRings(temp, owned, rings.items, .counterclockwise, deadline);
}

fn groupRings(
    temp: Allocator,
    owned: Allocator,
    rings: []BuiltRing,
    shell_winding: Winding,
    deadline: Deadline,
) ![]const Polygon {
    const Shell = struct { ring: BuiltRing, bounds: AABB, holes: std.ArrayList(Ring) = .empty };
    var shells: std.ArrayList(Shell) = .empty;
    for (rings, 0..) |ring, i| {
        try checkAt(deadline, i);
        if (ring.role == .outer) try shells.append(temp, .{ .ring = ring, .bounds = (try ringBounds(ring.points, deadline)).? });
    }
    for (rings, 0..) |ring, i| {
        try checkAt(deadline, i);
        if (ring.role != .inner) continue;
        const bounds = (try ringBounds(ring.points, deadline)).?;
        var best: ?usize = null;
        var best_area = std.math.inf(f64);
        for (shells.items, 0..) |shell, j| {
            try checkAt(deadline, j);
            const area = @abs(shell.ring.area);
            if (area >= best_area or area <= @abs(ring.area) or
                !shell.bounds.covers(bounds.minpt()) or !shell.bounds.covers(bounds.maxpt())) continue;
            if (!try containsRing(shell.ring.points, ring.points, deadline)) continue;
            best = j;
            best_area = area;
        }
        if (best) |index| {
            if ((ring.area > 0) == (shell_winding == .counterclockwise)) std.mem.reverse(PointLL, ring.points);
            try shells.items[index].holes.append(owned, ring.points);
        }
    }
    const polygons = try owned.alloc(Polygon, shells.items.len);
    for (shells.items, polygons, 0..) |shell, *poly, i| {
        try checkAt(deadline, i);
        if ((shell.ring.area > 0) != (shell_winding == .counterclockwise)) std.mem.reverse(PointLL, shell.ring.points);
        poly.* = .{ .outer = shell.ring.points, .holes = shell.holes.items };
    }
    return polygons;
}

fn containsRing(shell: Ring, inner: Ring, deadline: Deadline) !bool {
    var has_interior = false;
    for (inner, 0..) |point, i| {
        try checkAt(deadline, i);
        switch (try locateInRing(shell, point, deadline)) {
            .outside => return false,
            .inside => has_interior = true,
            .boundary => {},
        }
    }
    if (has_interior) return true;
    // A hole can touch the shell at every vertex while its edges run
    // through the interior (for example, a diamond inscribed in a box).
    var prev = inner[inner.len - 1];
    for (inner, 0..) |next, i| {
        try checkAt(deadline, i);
        const half = PointLL.init((prev.lng + next.lng) * 0.5, (prev.lat + next.lat) * 0.5);
        switch (try locateInRing(shell, half, deadline)) {
            .outside => return false,
            .inside => has_interior = true,
            .boundary => {},
        }
        prev = next;
    }
    return has_interior;
}

const Side = enum { left, right, bottom, top };
const SideEvent = struct { at: f64, delta: isize };

fn boxSide(box: AABB, a: PointLL, b: PointLL) ?Side {
    if (a.lng == b.lng) {
        if (a.lng == box.minx) return .left;
        if (a.lng == box.maxx) return .right;
    }
    if (a.lat == b.lat) {
        if (a.lat == box.miny) return .bottom;
        if (a.lat == box.maxy) return .top;
    }
    return null;
}

fn sideCoord(side: Side, point: PointLL) f64 {
    return switch (side) {
        .left, .right => point.lat,
        .bottom, .top => point.lng,
    };
}

fn sidePoint(box: AABB, side: Side, value: f64) PointLL {
    return switch (side) {
        .left => .init(box.minx, value),
        .right => .init(box.maxx, value),
        .bottom => .init(value, box.miny),
        .top => .init(value, box.maxy),
    };
}

fn clampToBox(box: AABB, point: PointLL) PointLL {
    return .init(std.math.clamp(point.lng, box.minx, box.maxx), std.math.clamp(point.lat, box.miny, box.maxy));
}

fn clipRingEdges(
    boundary: *Boundary,
    points: *std.ArrayList(PointLL),
    side_events: *[4]std.ArrayList(SideEvent),
    input: Ring,
    role: Role,
    box: AABB,
    deadline: Deadline,
) !void {
    const ring = vertices(input);
    const order = try winding(ring, deadline);
    if (order == .degenerate) return;
    const reverse = (order == .counterclockwise) != (role == .outer);
    const gpa = boundary.gpa;
    points.clearRetainingCapacity();
    try points.ensureTotalCapacity(gpa, ring.len);
    for (ring, 0..) |point, i| {
        try checkAt(deadline, i);
        if (!finite(point)) return error.InvalidGeometry;
        points.appendAssumeCapacity(point);
    }
    // Sutherland-Hodgman can leave opposing connectors along the clip box
    // when it cuts a concave shell into multiple pieces or cuts into a hole.
    if (try box.clipWithDeadline(gpa, points, true, deadline) < 2) return;
    var prev = clampToBox(box, points.items[points.items.len - 1]);
    for (points.items, 0..) |point, i| {
        try checkAt(deadline, i);
        const next = clampToBox(box, point);
        defer prev = next;
        if (prev.eql(next)) continue;
        const a, const b = if (reverse) .{ next, prev } else .{ prev, next };
        if (boxSide(box, a, b)) |side| {
            const from = sideCoord(side, a);
            const to = sideCoord(side, b);
            const delta: isize = if (from < to) 1 else -1;
            const events = &side_events[@backingInt(side)];
            try events.append(gpa, .{ .at = @min(from, to), .delta = delta });
            try events.append(gpa, .{ .at = @max(from, to), .delta = -delta });
        } else {
            try boundary.add(a, b, true);
        }
    }
}

fn sideEventLess(_: void, a: SideEvent, b: SideEvent) bool {
    return a.at < b.at;
}

fn addBoxEdges(boundary: *Boundary, box: AABB, side: Side, events: []SideEvent, deadline: Deadline) !void {
    if (events.len == 0) return;
    if (deadline.expired()) return error.DeadlineExceeded;
    std.mem.sortUnstable(SideEvent, events, {}, sideEventLess);
    var coverage: isize = 0;
    var previous = events[0].at;
    for (events, 0..) |event, i| {
        try checkAt(deadline, i);
        if (event.at != previous and coverage != 0) {
            const a = sidePoint(box, side, previous);
            const b = sidePoint(box, side, event.at);
            if (coverage > 0) try boundary.add(a, b, true) else try boundary.add(b, a, true);
        }
        coverage += event.delta;
        previous = event.at;
    }
}

/// Clip a polygon to a closed rectangle. Area-zero contacts are omitted.
/// Disconnected pieces are separate polygons. Shell winding is preserved
/// and holes have the opposite winding.
pub fn clipPolygon(gpa: Allocator, poly: Polygon, box: AABB, deadline: Deadline) !MultiPolygon {
    if (!validBox(box)) return error.InvalidGeometry;
    var output: MultiPolygon = .{ .storage = .init(gpa) };
    errdefer output.deinit();
    if (box.width() == 0 or box.height() == 0) return output;
    const shell_winding = try winding(poly.outer, deadline);
    if (shell_winding == .degenerate) return output;

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const owned = output.storage.allocator();
    var boundary: Boundary = .{ .gpa = temp };
    var points: std.ArrayList(PointLL) = .empty;
    var events: [4]std.ArrayList(SideEvent) = @splat(.empty);
    try clipRingEdges(&boundary, &points, &events, poly.outer, .outer, box, deadline);
    for (poly.holes, 0..) |hole, i| {
        try checkAt(deadline, i);
        try clipRingEdges(&boundary, &points, &events, hole, .inner, box, deadline);
    }
    for (events, 0..) |side_events, i|
        try addBoxEdges(&boundary, box, @fromBackingInt(@intCast(i)), side_events.items, deadline);
    var rings: std.ArrayList(BuiltRing) = .empty;
    try boundary.extractDirected(owned, &rings, deadline);
    output.polygons = try groupRings(temp, owned, rings.items, shell_winding, deadline);
    return output;
}

const testing = std.testing;
const p = PointLL.init;

test "polygon coverage includes shared edges and excludes interior holes" {
    const shell = &.{ p(0, 0), p(6, 0), p(6, 6), p(0, 6) };
    const hole = &.{ p(2, 2), p(2, 4), p(4, 4), p(4, 2) };
    const parent: Polygon = .{ .outer = shell, .holes = &.{hole} };
    try testing.expect(try parent.coversPolygon(parent, testing.allocator, .none));
    try testing.expect(!try parent.coversPolygon(.{ .outer = shell }, testing.allocator, .none));
    const attached: Polygon = .{ .outer = &.{ p(0, 0), p(2, 0), p(2, 5), p(0, 5) } };
    try testing.expect(try parent.coversPolygon(attached, testing.allocator, .none));
    // The diagonal enters the hole at two vertices, with covered endpoints.
    const crosses_vertex: Polygon = .{ .outer = &.{ p(1, 1), p(5, 5), p(1, 5) } };
    try testing.expect(!try parent.coversPolygon(crosses_vertex, testing.allocator, .none));
}

// Ported from test/util_midgard.cc, PolygonArea.
test "area and orientation match Midgard for both orders" {
    var triangle = [_]PointLL{ p(1, 1), p(2, 2), p(3, 1) };
    try testing.expectEqual(-1, try signedArea(&triangle, .none));
    try testing.expectEqual(.clockwise, try winding(&triangle, .none));
    std.mem.reverse(PointLL, &triangle);
    try testing.expectEqual(1, try signedArea(&triangle, .none));
    try testing.expectEqual(.counterclockwise, try winding(&triangle, .none));
}

test "unordered and reversed fragments form shells and holes with boundary classification" {
    const fragments = [_]Fragment{
        .{ .points = &.{ p(6, 0), p(0, 0), p(0, 6) } },
        .{ .points = &.{ p(6, 0), p(6, 6) } },
        .{ .points = &.{ p(0, 6), p(6, 6) } },
        .{ .points = &.{ p(2, 2), p(2, 4), p(4, 4) }, .role = .inner },
        .{ .points = &.{ p(2, 2), p(4, 2), p(4, 4) }, .role = .inner },
    };
    var multi = try assemble(testing.allocator, &fragments, .none);
    defer multi.deinit();
    try testing.expectEqual(1, multi.polygons.len);
    const poly = multi.polygons[0];
    try testing.expectEqual(1, poly.holes.len);
    try testing.expectEqual(36, try signedArea(poly.outer, .none));
    try testing.expectEqual(-4, try signedArea(poly.holes[0], .none));
    try testing.expectEqual(.inside, try poly.locate(p(1, 3), .none));
    try testing.expectEqual(.outside, try poly.locate(p(3, 3), .none));
    try testing.expectEqual(.boundary, try poly.locate(p(2, 3), .none));
    try testing.expectEqual(.boundary, try poly.locate(p(6, 3), .none));
    try testing.expectEqual(.outside, try poly.locate(p(7, 3), .none));
}

test "self-touch yields two rings and a single gap is repaired" {
    var multi = try assemble(testing.allocator, &.{
        .{ .points = &.{ p(0, 0), p(1, 0), p(0, 1), p(0, 0), p(-1, 0), p(0, -1), p(0, 0) } },
        .{ .points = &.{ p(9, 8), p(9, 9), p(9, 9) } },
        .{ .points = &.{ p(8, 8), p(9, 8) } },
        .{ .points = &.{ p(9, 9), p(8, 9) } },
        .{ .points = &.{ p(3, 0), p(4, 0), p(5, 0) } },
        .{ .points = &.{ p(14, 0), p(14, 0) } },
        .{ .points = &.{ p(11, 0), p(12, 0), p(12, 1) } },
        .{ .points = &.{ p(12, 0), p(12, -1) } },
    }, .none);
    defer multi.deinit();
    try testing.expectEqual(3, multi.polygons.len);
    var total: f64 = 0;
    for (multi.polygons) |poly| total += try signedArea(poly.outer, .none);
    try testing.expectEqual(2, total);
}

// Ported from test/linesegment2.cc, TestIntersect.
test "proper segment crossings, parallel lines, and endpoint contact" {
    const a = p(-2, -2);
    const b = p(4, 4);
    try testing.expect(!segmentsIntersect(a, b, p(8, 10), p(4, 2)));
    try testing.expect(!segmentsIntersect(a, b, p(-10, 5), p(-14, -5)));
    try testing.expect(!segmentsIntersect(a, b, p(0, -5), p(-1, -2)));
    try testing.expect(!segmentsIntersect(a, b, p(0, 5), p(1, 3)));
    try testing.expect(segmentsIntersect(a, b, p(-2, 2), p(2, -2)));
    try testing.expect(!segmentsIntersect(a, b, p(-3, -2), p(3, 4)));
    try testing.expect(segmentsIntersect(a, b, b, p(8, 8)));
    try testing.expect(segmentsIntersect(a, b, p(1, 1), p(1, 1)));
    try testing.expect(!segmentsIntersect(a, b, p(2, 1), p(2, 1)));
}

test "polygon intersection excludes hole interiors and counts contact" {
    const poly: Polygon = .{
        .outer = &.{ p(0, 0), p(6, 0), p(6, 6), p(0, 6) },
        .holes = &.{&.{ p(2, 2), p(2, 4), p(4, 4), p(4, 2) }},
    };
    try testing.expect(!try poly.intersectsBox(.init(2.1, 2.1, 3.9, 3.9), .none));
    try testing.expect(try poly.intersectsBox(.init(4, 2.1, 4.1, 3.9), .none));
    try testing.expect(try poly.intersectsBox(.init(-1, -1, 7, 7), .none));
    try testing.expect(!try poly.intersectsLine(&.{ p(2.5, 3), p(3.5, 3) }, .none));
    try testing.expect(try poly.intersectsLine(&.{ p(2.5, 3), p(4.5, 3) }, .none));
    try testing.expect(try poly.intersectsLine(&.{ p(1, 1), p(1.1, 1.1) }, .none));
}

test "polyline clipping avoids joining separate runs along the box border" {
    const line = [_]PointLL{ p(1, 1), p(0, 1), p(-1, 1), p(-1, 3), p(0, 3), p(1, 3) };
    const box = AABB.init(0, 0, 4, 4);
    var points: std.ArrayList(PointLL) = .empty;
    defer points.deinit(testing.allocator);
    var parts: std.ArrayList(LineRange) = .empty;
    defer parts.deinit(testing.allocator);
    try clipPolyline(testing.allocator, &line, box, &points, &parts, .none);
    try testing.expectEqualSlices(LineRange, &.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 4 } }, parts.items);
    try testing.expectEqualSlices(PointLL, &.{ p(1, 1), p(0, 1), p(0, 3), p(1, 3) }, points.items);
    try testing.expectEqual([2]PointLL{ p(0, 0), p(4, 4) }, clipSegment(p(-1, -1), p(5, 5), box).?);
    try testing.expectEqual([2]PointLL{ p(0, 0), p(0, 0) }, clipSegment(p(-1, 1), p(1, -1), box).?);
    try testing.expect(clipSegment(p(-1, 0), p(-1, 4), box) == null);
}

test "clipping a concave shell yields disconnected shells and preserves winding" {
    // A U shape whose bridge lies below the box.
    const shape = [_]PointLL{ p(0, 0), p(0, 6), p(2, 6), p(2, 2), p(4, 2), p(4, 6), p(6, 6), p(6, 0) };
    const box = AABB.init(-1, 3, 7, 5);
    var clipped = try clipPolygon(testing.allocator, .{ .outer = &shape }, box, .none);
    defer clipped.deinit();
    try testing.expectEqual(2, clipped.polygons.len);
    for (clipped.polygons) |poly| {
        try testing.expectEqual(-4, try signedArea(poly.outer, .none));
        for (poly.outer) |point| try testing.expect(box.covers(point));
        try testing.expectEqual(.outside, try poly.locate(p(3, 3), .none));
    }
}

test "polygon clipping opens a clipped hole at the box edge and retains a full hole" {
    const poly: Polygon = .{
        .outer = &.{ p(0, 0), p(10, 0), p(10, 10), p(0, 10) },
        .holes = &.{
            &.{ p(1, 1), p(1, 5), p(4, 5), p(4, 1) },
            &.{ p(6, 6), p(6, 7), p(7, 7), p(7, 6) },
        },
    };
    const box = AABB.init(0, 2, 10, 10);
    var clipped = try clipPolygon(testing.allocator, poly, box, .none);
    defer clipped.deinit();
    try testing.expectEqual(1, clipped.polygons.len);
    const result = clipped.polygons[0];
    try testing.expectEqual(1, result.holes.len);
    try testing.expectEqual(71, try signedArea(result.outer, .none));
    try testing.expectEqual(-1, try signedArea(result.holes[0], .none));
    try testing.expectEqual(.outside, try result.locate(p(3, 2), .none));
    try testing.expectEqual(.outside, try result.locate(p(6.5, 6.5), .none));
    try testing.expectEqual(.boundary, try result.locate(p(4, 4), .none));
    for (result.outer) |point| try testing.expect(box.covers(point));

    var in_hole = try clipPolygon(testing.allocator, poly, .init(2, 2, 3, 4), .none);
    defer in_hole.deinit();
    try testing.expectEqual(0, in_hole.polygons.len);
}

test "random cuts preserve occupancy, box bounds, and winding" {
    var star: [12]PointLL = undefined;
    for (&star, 0..) |*point, i| {
        const angle = @as(f64, @floatFromInt(i)) * std.math.tau / star.len;
        const radius: f64 = if (i % 2 == 0) 8 else 2;
        point.* = p(radius * @cos(angle), radius * @sin(angle));
    }
    const source: Polygon = .{ .outer = &star };
    var prng = std.Random.DefaultPrng.init(991);
    const rng = prng.random();
    for (0..128) |_| {
        const x = 24 * rng.float(f64) - 12;
        const y = 24 * rng.float(f64) - 12;
        const box = AABB.init(x, y, x + 0.1 + 10 * rng.float(f64), y + 0.1 + 10 * rng.float(f64));
        var cut = try clipPolygon(testing.allocator, source, box, .none);
        defer cut.deinit();
        for (cut.polygons) |poly| {
            try testing.expectEqual(.counterclockwise, try winding(poly.outer, .none));
            for (poly.outer) |point| try testing.expect(box.covers(point));
        }
        for (0..32) |_| {
            const point = p(x + box.width() * rng.float(f64), y + box.height() * rng.float(f64));
            const expected = try source.locate(point, .none);
            var inside = false;
            for (cut.polygons) |poly| inside = inside or try poly.locate(point, .none) != .outside;
            try testing.expectEqual(expected != .outside, inside);
        }
    }
}

test "ring assembly checks the operation deadline" {
    try testing.expectError(error.DeadlineExceeded, assemble(testing.allocator, &.{
        .{ .points = &.{ p(0, 0), p(1, 0), p(0, 1) } },
    }, .{ .at_ns = 0 }));
}
