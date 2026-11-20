//! Static polygon R-tree with Hilbert-ordered leaves and contiguous branches.
const std = @import("std");
const Allocator = std.mem.Allocator;
const PointLL = @import("point.zig").PointLL;
const AABB = @import("aabb.zig").AABB;
const Deadline = @import("../infra/io.zig").Deadline;
const polygon = @import("polygon.zig");
const grid = @import("grid.zig");

const fanout = 8;
// One frame per level. There can be no more than 2^32 indexed polygons.
const max_depth = 1 + (32 + 2) / 3;

const Entry = struct {
    bounds: AABB,
    key: u64,
    id: u32,

    fn less(_: void, a: Entry, b: Entry) bool {
        return a.key < b.key or (a.key == b.key and a.id < b.id);
    }
};

const Node = struct {
    bounds: AABB,
    first: usize,
    len: u8,
    leaf: bool,
};

const LatitudeBands = struct {
    const max_bands = 256;
    const Span = struct { first: usize, len: usize };

    south: f64,
    scale: f64,
    bands: []Span,
    edges: []u32,

    fn init(a: Allocator, input: polygon.Ring, box: AABB, deadline: Deadline) !?LatitudeBands {
        const ring = if (input.len > 1 and input[0].eql(input[input.len - 1])) input[0 .. input.len - 1] else input;
        if (ring.len < 256 or ring.len > std.math.maxInt(u32) or box.height() <= 0) return null;
        const count = @min(max_bands, ring.len / 64);
        const scale = @as(f64, @floatFromInt(count)) / box.height();
        if (scale <= 0 or !std.math.isFinite(scale)) return null;
        var lengths: [max_bands]usize = @splat(0);
        var total: usize = 0;
        var prev = ring[ring.len - 1];
        for (ring, 0..) |next, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const low = bandAt(@min(prev.lat, next.lat), box.miny, scale, count);
            const high = bandAt(@max(prev.lat, next.lat), box.miny, scale, count);
            prev = next;
            total += high - low + 1;
            if (total > ring.len * 4) return null;
            for (lengths[low .. high + 1]) |*len| len.* += 1;
        }

        const bands = try a.alloc(Span, count);
        const edges = try a.alloc(u32, total);
        var offset: usize = 0;
        for (bands, lengths[0..count]) |*span, len| {
            span.* = .{ .first = offset, .len = 0 };
            offset += len;
        }
        prev = ring[ring.len - 1];
        for (ring, 0..) |next, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const low = bandAt(@min(prev.lat, next.lat), box.miny, scale, count);
            const high = bandAt(@max(prev.lat, next.lat), box.miny, scale, count);
            prev = next;
            for (bands[low .. high + 1]) |*span| {
                edges[span.first + span.len] = @intCast(i);
                span.len += 1;
            }
        }
        return .{ .south = box.miny, .scale = scale, .bands = bands, .edges = edges };
    }

    fn candidates(self: LatitudeBands, latitude: f64) []const u32 {
        const span = self.bands[bandAt(latitude, self.south, self.scale, self.bands.len)];
        return self.edges[span.first..][0..span.len];
    }

    fn bandAt(latitude: f64, south: f64, scale: f64, count: usize) usize {
        const last: f64 = @floatFromInt(count - 1);
        return @intFromFloat(std.math.clamp((latitude - south) * scale, 0, last));
    }
};

pub const Index = struct {
    polygons: []const polygon.Polygon,
    entries: []const Entry,
    nodes: []const Node,
    shells: []const ?LatitudeBands,
    bands_storage: std.heap.ArenaAllocator,
    allocator: Allocator,

    /// Polygon coordinates and hole slices are borrowed and must stay immutable
    /// while the index exists. Empty shells do not get entries.
    pub fn init(gpa: Allocator, polygons: []const polygon.Polygon, deadline: Deadline) !Index {
        if (polygons.len > std.math.maxInt(u32)) return error.TooManyPolygons;
        var bands_storage = std.heap.ArenaAllocator.init(gpa);
        errdefer bands_storage.deinit();
        const bands_allocator = bands_storage.allocator();
        const shells = try bands_allocator.alloc(?LatitudeBands, polygons.len);
        @memset(shells, null);
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        for (polygons, 0..) |poly, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const box = try polygon.ringBounds(poly.outer, deadline) orelse continue;
            shells[i] = try LatitudeBands.init(bands_allocator, poly.outer, box, deadline);
            try entries.append(gpa, .{ .bounds = box, .key = grid.hilbertOfPoint(16, box.center()), .id = @intCast(i) });
        }
        if (deadline.expired()) return error.DeadlineExceeded;
        std.mem.sortUnstable(Entry, entries.items, {}, Entry.less);

        var nodes: std.ArrayList(Node) = .empty;
        defer nodes.deinit(gpa);
        var first: usize = 0;
        var end = entries.items.len;
        var leaf = true;
        while (first < end) {
            var offset = first;
            const parent_start = nodes.items.len;
            while (offset < end) : (offset += fanout) {
                if (deadline.expired()) return error.DeadlineExceeded;
                const limit = @min(offset + fanout, end);
                var box = if (leaf) entries.items[offset].bounds else nodes.items[offset].bounds;
                for (offset + 1..limit) |child|
                    box.expand(if (leaf) entries.items[child].bounds else nodes.items[child].bounds);
                try nodes.append(gpa, .{ .bounds = box, .first = offset, .len = @intCast(limit - offset), .leaf = leaf });
            }
            if (nodes.items.len - parent_start == 1) break;
            first = parent_start;
            end = nodes.items.len;
            leaf = false;
        }
        const owned_entries = try entries.toOwnedSlice(gpa);
        errdefer gpa.free(owned_entries);
        return .{
            .polygons = polygons,
            .entries = owned_entries,
            .nodes = try nodes.toOwnedSlice(gpa),
            .shells = shells,
            .bands_storage = bands_storage,
            .allocator = gpa,
        };
    }

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.nodes);
        self.bands_storage.deinit();
        self.* = undefined;
    }

    /// Append the input indices whose polygons cover the point. Boundaries
    /// count, including hole boundaries. Result order is tree order.
    pub fn lookup(self: Index, gpa: Allocator, point: PointLL, out: *std.ArrayList(u32), deadline: Deadline) !void {
        if (self.nodes.len == 0) return;
        const before = out.items.len;
        errdefer out.shrinkRetainingCapacity(before);
        const Level = struct { next: usize, end: usize };
        var stack: [max_depth]Level = undefined;
        stack[0] = .{ .next = self.nodes.len - 1, .end = self.nodes.len };
        var depth: usize = 1;
        while (depth > 0) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const level = &stack[depth - 1];
            if (level.next == level.end) {
                depth -= 1;
                continue;
            }
            const node = self.nodes[level.next];
            level.next += 1;
            if (!node.bounds.covers(point)) continue;
            if (!node.leaf) {
                stack[depth] = .{ .next = node.first, .end = node.first + node.len };
                depth += 1;
                continue;
            }
            for (self.entries[node.first..][0..node.len]) |entry| {
                if (entry.bounds.covers(point) and try self.locate(entry.id, point, deadline) != .outside)
                    try out.append(gpa, entry.id);
            }
        }
    }

    fn locate(self: Index, id: u32, point: PointLL, deadline: Deadline) !polygon.Location {
        const shape = self.polygons[id];
        if (self.shells[id]) |shell| {
            const location = try polygon.locateInRingEdges(shape.outer, shell.candidates(point.lat), point, deadline);
            return shape.locateWithShell(point, location, deadline);
        }
        return shape.locate(point, deadline);
    }
};

const testing = std.testing;
const p = PointLL.init;

test "latitude bands preserve exact shell, hole and boundary results" {
    var shell: [1025]PointLL = undefined;
    for (shell[0..1024], 0..) |*vertex, i| {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / 1024.0;
        const wave = 1 + 0.12 * @cos(angle * 13);
        vertex.* = p(wave * @cos(angle) * 2, wave * @sin(angle));
    }
    shell[1024] = shell[0];
    const hole = [_]PointLL{ p(-0.4, -0.3), p(0.4, -0.3), p(0.4, 0.3), p(-0.4, 0.3) };
    const shapes = [_]polygon.Polygon{.{ .outer = &shell, .holes = &.{&hole} }};
    const a = testing.allocator;
    var index = try Index.init(a, &shapes, .none);
    defer index.deinit();
    try testing.expect(index.shells[0] != null);
    for (shell) |vertex|
        try testing.expectEqual(.boundary, try index.locate(0, vertex, .none));
    for (hole) |vertex|
        try testing.expectEqual(.boundary, try index.locate(0, vertex, .none));
    var state = std.Random.DefaultPrng.init(219);
    const random = state.random();
    var hits: std.ArrayList(u32) = .empty;
    defer hits.deinit(a);
    for (0..2000) |_| {
        const location = p(random.float(f64) * 5 - 2.5, random.float(f64) * 3 - 1.5);
        hits.clearRetainingCapacity();
        try index.lookup(a, location, &hits, .none);
        const expected = try shapes[0].locate(location, .none);
        try testing.expectEqual(expected != .outside, hits.items.len == 1);
    }
}

test "packed polygon lookup matches brute force including boundaries and holes" {
    const gpa = testing.allocator;
    const count = 513;
    const shells = try gpa.alloc([4]PointLL, count);
    defer gpa.free(shells);
    const holes = try gpa.alloc([4]PointLL, count);
    defer gpa.free(holes);
    const views = try gpa.alloc([1]polygon.Ring, count);
    defer gpa.free(views);
    const polygons = try gpa.alloc(polygon.Polygon, count);
    defer gpa.free(polygons);
    for (0..count) |i| {
        const x: f64 = @floatFromInt(i % 23);
        const y: f64 = @floatFromInt(i / 23);
        shells[i] = .{ p(x, y), p(x + 2, y), p(x + 2, y + 2), p(x, y + 2) };
        holes[i] = .{ p(x + 0.5, y + 0.5), p(x + 0.5, y + 1.5), p(x + 1.5, y + 1.5), p(x + 1.5, y + 0.5) };
        views[i] = .{&holes[i]};
        polygons[i] = .{ .outer = &shells[i], .holes = &views[i] };
    }
    var index = try Index.init(gpa, polygons, .none);
    defer index.deinit();
    var hits: std.ArrayList(u32) = .empty;
    defer hits.deinit(gpa);
    var rng = std.Random.DefaultPrng.init(1234);
    for (0..450) |iteration| {
        const r = rng.random();
        const point = if (iteration == 0)
            p(24, 2) // The right edge of the rightmost polygon in row zero.
        else
            p(-1 + 26 * r.float(f64), -1 + 26 * r.float(f64));
        hits.clearRetainingCapacity();
        try index.lookup(gpa, point, &hits, .none);
        std.mem.sortUnstable(u32, hits.items, {}, std.sort.asc(u32));
        var expected: usize = 0;
        for (polygons, 0..) |poly, id| {
            if (try poly.locate(point, .none) == .outside) continue;
            try testing.expect(expected < hits.items.len);
            try testing.expectEqual(id, @as(usize, hits.items[expected]));
            expected += 1;
        }
        try testing.expectEqual(expected, hits.items.len);
    }
}
