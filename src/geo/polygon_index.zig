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

pub const Index = struct {
    polygons: []const polygon.Polygon,
    entries: []const Entry,
    nodes: []const Node,
    allocator: Allocator,

    /// Polygon coordinates and hole slices are borrowed and must stay immutable
    /// while the index exists. Empty shells do not get entries.
    pub fn init(gpa: Allocator, polygons: []const polygon.Polygon, deadline: Deadline) !Index {
        if (polygons.len > std.math.maxInt(u32)) return error.TooManyPolygons;
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        for (polygons, 0..) |poly, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const box = try polygon.ringBounds(poly.outer, deadline) orelse continue;
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
            .allocator = gpa,
        };
    }

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.nodes);
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
                if (entry.bounds.covers(point) and try self.polygons[entry.id].locate(point, deadline) != .outside)
                    try out.append(gpa, entry.id);
            }
        }
    }
};

const testing = std.testing;
const p = PointLL.init;

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
