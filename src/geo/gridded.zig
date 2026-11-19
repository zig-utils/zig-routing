// Ported from valhalla/midgard/gridded_data.h (Valhalla 3.9.3).
const std = @import("std");
const Allocator = std.mem.Allocator;
const PointLL = @import("point.zig").PointLL;
const AABB = @import("aabb.zig").AABB;
const Tiles = @import("grid.zig").Tiles;
const Deadline = @import("../infra/io.zig").Deadline;
const polygon = @import("polygon.zig");
const line = @import("line.zig");
const constants = @import("constants.zig");

pub const optimal_generalization = std.math.floatMax(f32);

pub const Interval = struct {
    metric: usize,
    value: f32,
    name: []const u8 = "",
    color: []const u8 = "",

    fn descending(_: void, a: Interval, b: Interval) bool {
        if (a.metric != b.metric) return a.metric > b.metric;
        if (a.value != b.value) return a.value > b.value;
        if (!std.mem.eql(u8, a.name, b.name)) return std.mem.order(u8, a.name, b.name) == .gt;
        return std.mem.order(u8, a.color, b.color) == .gt;
    }
};

pub const Geometry = union(enum) {
    lines: []const []const PointLL,
    polygons: []const polygon.Polygon,
};

pub const Contour = struct { interval: Interval, geometry: Geometry };
pub const ContourOptions = struct {
    rings_only: bool = false,
    denoise: f32 = 1,
    generalize_m: f32 = 200,
};

pub const Contours = struct {
    items: []const Contour,
    storage: std.heap.ArenaAllocator,

    pub fn deinit(self: *Contours) void {
        self.storage.deinit();
        self.items = &.{};
    }
};

fn checkAt(deadline: Deadline, i: usize) error{DeadlineExceeded}!void {
    if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

pub fn Grid(comptime dimensions: usize) type {
    if (dimensions == 0) @compileError("a contour grid needs at least one metric");
    return struct {
        const Self = @This();
        pub const Value = [dimensions]f32;

        tiles: Tiles,
        max_value: Value,
        data: []Value,
        allocator: Allocator,

        pub fn init(gpa: Allocator, bounds: AABB, cell_size: f32, initial: Value, deadline: Deadline) !Self {
            if (!std.math.isFinite(cell_size) or cell_size <= 0 or
                !std.math.isFinite(bounds.minx) or !std.math.isFinite(bounds.miny) or
                !std.math.isFinite(bounds.maxx) or !std.math.isFinite(bounds.maxy)) return error.InvalidGrid;
            const cols = @round(bounds.width() / @as(f64, cell_size));
            const rows = @round(bounds.height() / @as(f64, cell_size));
            if (rows < 1 or cols < 1 or rows * cols > std.math.maxInt(i32)) return error.InvalidGrid;
            for (initial) |value| {
                if (!std.math.isFinite(value)) return error.InvalidGrid;
            }
            const tiles = Tiles.init(bounds, cell_size, 1, false);
            const data = try gpa.alloc(Value, @intFromFloat(rows * cols));
            errdefer gpa.free(data);
            for (data, 0..) |*value, i| {
                try checkAt(deadline, i);
                value.* = initial;
            }
            return .{ .tiles = tiles, .max_value = initial, .data = data, .allocator = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
            self.data = &.{};
        }

        pub fn dataAt(self: Self, tile_id: i32, metric: usize) ?f32 {
            if (tile_id < 0 or tile_id >= self.data.len or metric >= dimensions) return null;
            return self.data[@intCast(tile_id)][metric];
        }

        /// Match Midgard's independent per-metric minima and ignore invalid IDs.
        pub fn setIfLess(self: *Self, tile_id: i32, value: Value) void {
            if (tile_id < 0 or tile_id >= self.data.len) return;
            const current = &self.data[@intCast(tile_id)];
            current.* = observedMin(dimensions, current.*, value);
        }

        /// Apply minima to one contiguous run of cells, discarding the suffix
        /// past the end of the grid. Nonfinite observations leave existing values.
        pub fn setManyIfLess(self: *Self, tile_id: i32, values: []const Value, deadline: Deadline) !void {
            if (tile_id < 0 or tile_id >= self.data.len) return;
            const start: usize = @intCast(tile_id);
            const count = @min(values.len, self.data.len - start);
            const dest = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(self.data[start..][0..count]));
            const src = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(values[0..count]));
            const width = 8;
            var i: usize = 0;
            while (i + width <= dest.len) : (i += width) {
                try checkAt(deadline, i);
                const target = dest[i..][0..width];
                target.* = observedMin(width, target.*, src[i..][0..width].*);
            }
            while (i < dest.len) : (i += 1) {
                try checkAt(deadline, i);
                if (std.math.isFinite(src[i])) dest[i] = @min(dest[i], src[i]);
            }
        }

        /// CONREC contours. Intervals are returned in descending metric and
        /// threshold order. Closed paths can be returned as nested polygons.
        pub fn generateContours(
            self: Self,
            gpa: Allocator,
            intervals: []const Interval,
            options: ContourOptions,
            deadline: Deadline,
        ) !Contours {
            if (!std.math.isFinite(options.denoise) or options.denoise < 0 or options.denoise > 1 or
                !std.math.isFinite(options.generalize_m) or options.generalize_m < 0)
                return error.InvalidContourOptions;
            var output: Contours = .{ .items = &.{}, .storage = .init(gpa) };
            errdefer output.deinit();
            const owned = output.storage.allocator();
            const ordered = try gpa.dupe(Interval, intervals);
            defer gpa.free(ordered);
            for (ordered, 0..) |interval, i| {
                try checkAt(deadline, i);
                if (interval.metric >= dimensions or !std.math.isFinite(interval.value))
                    return error.InvalidInterval;
            }
            std.mem.sort(Interval, ordered, {}, Interval.descending);
            const contours = try owned.alloc(Contour, ordered.len);
            for (ordered, contours, 0..) |interval, *contour, i| {
                try checkAt(deadline, i);
                var scratch: std.heap.ArenaAllocator = .init(gpa);
                defer scratch.deinit();
                var stitch: Stitcher = .{ .gpa = scratch.allocator() };
                try self.trace(interval, &stitch, deadline);
                contour.* = .{
                    .interval = .{
                        .metric = interval.metric,
                        .value = interval.value,
                        .name = try owned.dupe(u8, interval.name),
                        .color = try owned.dupe(u8, interval.color),
                    },
                    .geometry = try stitch.geometry(owned, self.tiles.tilesize, options, deadline),
                };
            }
            output.items = contours;
            return output;
        }

        fn trace(self: Self, interval: Interval, stitch: *Stitcher, deadline: Deadline) !void {
            const cols = self.tiles.ncolumns;
            const rows = self.tiles.nrows;
            if (cols < 3 or rows < 3) return;
            const offsets = [4]i32{ 0, 1, cols + 1, cols };
            const max = self.max_value[interval.metric];
            var row: i32 = 1;
            while (row < rows - 1) : (row += 1) {
                if (deadline.expired()) return error.DeadlineExceeded;
                var col: i32 = 1;
                while (col < cols - 1) : (col += 1) {
                    try checkAt(deadline, @intCast(col - 1));
                    const id = self.tiles.tileIdColRow(col, row);
                    var corner_values: [4]f32 = undefined;
                    for (offsets, &corner_values) |offset, *sample| {
                        sample.* = self.data[@intCast(id + offset)][interval.metric];
                    }
                    const vector: @Vector(4, f32) = corner_values;
                    if (interval.value < @reduce(.Min, vector) or interval.value > @reduce(.Max, vector))
                        continue;
                    var heights: [5]f64 = undefined;
                    var coords: [5]PointLL = undefined;
                    coords[0] = self.tiles.center(id);
                    for (offsets, corner_values, 1..) |offset, sample, i| {
                        coords[i] = self.tiles.base(id + offset);
                        // Match Valhalla's finite distance above the contour
                        // at unreached corners, independently of the sentinel.
                        heights[i] = if (sample < max) relativeHeight(sample, interval.value) else 1;
                    }
                    heights[0] = 0.25 * (heights[1] + heights[2] + heights[3] + heights[4]);
                    for (1..5) |corner| {
                        const next = if (corner == 4) 1 else corner + 1;
                        const cut = triangleCut(corner, 0, next, &heights, &coords) orelse continue;
                        if (!cut[0].eql(cut[1])) try stitch.add(cut[0], cut[1]);
                    }
                }
            }
        }
    };
}

fn observedMin(comptime width: usize, current: @Vector(width, f32), observation: @Vector(width, f32)) @Vector(width, f32) {
    const maximum: @Vector(width, f32) = @splat(std.math.floatMax(f32));
    return @select(f32, @abs(observation) <= maximum, @min(current, observation), current);
}

fn relativeHeight(sample: f32, threshold: f32) f64 {
    const relative = sample - threshold;
    return if (std.math.isFinite(relative)) relative else @as(f64, sample) - @as(f64, threshold);
}

// The four triangles around the tile center use Valhalla's CONREC case
// table. Emitted segments keep lower grid values on the left.
const cases = [3][3][3]u4{
    .{ .{ 0, 0, 8 }, .{ 0, 2, 5 }, .{ 7, 6, 9 } },
    .{ .{ 0, 3, 4 }, .{ 1, 0, 1 }, .{ 4, 3, 0 } },
    .{ .{ 9, 6, 7 }, .{ 5, 2, 0 }, .{ 8, 0, 0 } },
};
const swaps = [3][3][3]bool{
    .{ .{ false, false, true }, .{ false, true, true }, .{ true, false, false } },
    .{ .{ false, true, false }, .{ true, false, false }, .{ true, false, false } },
    .{ .{ true, true, false }, .{ false, false, false }, .{ false, false, false } },
};

fn signIndex(value: f64) usize {
    if (value < 0) return 0;
    return if (value == 0) 1 else 2;
}

fn intersection(a: usize, b: usize, heights: *const [5]f64, points: *const [5]PointLL) PointLL {
    const ha = heights[a];
    const hb = heights[b];
    const dx = hb - ha;
    return .init(
        @round(((hb * points[a].lng - ha * points[b].lng) / dx) * 1e7) / 1e7,
        @round(((hb * points[a].lat - ha * points[b].lat) / dx) * 1e7) / 1e7,
    );
}

fn triangleCut(a: usize, b: usize, c: usize, heights: *const [5]f64, pts: *const [5]PointLL) ?[2]PointLL {
    const sa = signIndex(heights[a]);
    const sb = signIndex(heights[b]);
    const sc = signIndex(heights[c]);
    const cut: [2]PointLL = switch (cases[sa][sb][sc]) {
        0 => return null,
        1 => .{ pts[a], pts[b] },
        2 => .{ pts[b], pts[c] },
        3 => .{ pts[c], pts[a] },
        4 => .{ pts[a], intersection(b, c, heights, pts) },
        5 => .{ pts[b], intersection(c, a, heights, pts) },
        6 => .{ pts[c], intersection(a, b, heights, pts) },
        7 => .{ intersection(a, b, heights, pts), intersection(b, c, heights, pts) },
        8 => .{ intersection(b, c, heights, pts), intersection(c, a, heights, pts) },
        9 => .{ intersection(c, a, heights, pts), intersection(a, b, heights, pts) },
        else => unreachable,
    };
    return if (swaps[sa][sb][sc]) .{ cut[1], cut[0] } else cut;
}

const Stitcher = struct {
    const Vertex = struct { point: PointLL, next: ?usize = null };
    const Chain = struct { first: usize, last: usize, active: bool = true };
    const Endpoints = std.AutoHashMapUnmanaged([2]u64, usize);
    const Path = struct {
        points: std.ArrayList(PointLL),
        area: f64,

        fn largestFirst(_: void, a: Path, b: Path) bool {
            return a.area > b.area;
        }
    };

    gpa: Allocator,
    vertices: std.ArrayList(Vertex) = .empty,
    chains: std.ArrayList(Chain) = .empty,
    begins: Endpoints = .empty,
    ends: Endpoints = .empty,

    fn vertex(self: *Stitcher, point: PointLL, next: ?usize) !usize {
        const index = self.vertices.items.len;
        try self.vertices.append(self.gpa, .{ .point = point, .next = next });
        return index;
    }

    fn remember(self: *Stitcher, map: *Endpoints, key: [2]u64, chain: usize) !void {
        const entry = try map.getOrPut(self.gpa, key);
        if (!entry.found_existing) entry.value_ptr.* = chain;
    }

    fn add(self: *Stitcher, a: PointLL, b: PointLL) !void {
        const from = a.exactKey();
        const to = b.exactKey();
        const before = self.ends.fetchRemove(from);
        const after = self.begins.fetchRemove(to);
        if (before) |prev| {
            const first = &self.chains.items[prev.value];
            if (after) |next| {
                if (prev.value == next.value) {
                    const last = try self.vertex(b, null);
                    self.vertices.items[first.last].next = last;
                    first.last = last;
                } else {
                    const second = &self.chains.items[next.value];
                    self.vertices.items[first.last].next = second.first;
                    first.last = second.last;
                    second.active = false;
                    try self.ends.put(self.gpa, self.vertices.items[first.last].point.exactKey(), prev.value);
                }
            } else {
                const last = try self.vertex(b, null);
                self.vertices.items[first.last].next = last;
                first.last = last;
                try self.remember(&self.ends, to, prev.value);
            }
        } else if (after) |next| {
            const second = &self.chains.items[next.value];
            second.first = try self.vertex(a, second.first);
            try self.remember(&self.begins, from, next.value);
        } else {
            const last = try self.vertex(b, null);
            const first = try self.vertex(a, last);
            const id = self.chains.items.len;
            try self.chains.append(self.gpa, .{ .first = first, .last = last });
            try self.remember(&self.begins, from, id);
            try self.remember(&self.ends, to, id);
        }
    }

    fn geometry(self: *Stitcher, owned: Allocator, cell_size: f32, options: ContourOptions, deadline: Deadline) !Geometry {
        var paths: std.ArrayList(Path) = .empty;
        var remaining = self.chains.items.len;
        while (remaining > 0) {
            remaining -= 1;
            try checkAt(deadline, remaining);
            const chain = self.chains.items[remaining];
            if (!chain.active) continue;
            if (options.rings_only and !self.vertices.items[chain.first].point.eql(self.vertices.items[chain.last].point)) continue;
            var points: std.ArrayList(PointLL) = .empty;
            var next: ?usize = chain.first;
            while (next) |index| {
                try checkAt(deadline, points.items.len);
                const vertex_data = self.vertices.items[index];
                try points.append(self.gpa, vertex_data.point);
                next = vertex_data.next;
            }
            try paths.append(self.gpa, .{ .points = points, .area = @abs(try polygon.signedArea(points.items, deadline)) });
        }
        std.mem.sort(Path, paths.items, {}, Path.largestFirst);
        const largest = if (paths.items.len > 0) paths.items[0].area else 0;
        const generalize_m: f32 = if (options.generalize_m == optimal_generalization)
            @floatCast(@as(f64, cell_size * 0.25) * constants.meters_per_degree_lat)
        else
            options.generalize_m;
        const half = @as(f64, cell_size) * 0.5;
        var lines: std.ArrayList(polygon.Ring) = .empty;
        for (paths.items, 0..) |*path, i| {
            try checkAt(deadline, i);
            if (largest > 0 and path.area / largest < options.denoise) break;
            if (generalize_m > 0)
                try line.generalizeContour(self.gpa, &path.points, generalize_m, deadline);
            if (path.points.items.len < 4) continue;
            for (path.points.items, 0..) |*point, j| {
                try checkAt(deadline, j);
                point.lng += half;
                point.lat += half;
            }
            try lines.append(self.gpa, path.points.items);
        }
        if (options.rings_only) {
            return .{ .polygons = try polygon.nestOrientedRings(self.gpa, owned, lines.items, deadline) };
        }
        const copied = try owned.alloc([]const PointLL, lines.items.len);
        for (lines.items, copied, 0..) |coordinates, *path, i| {
            try checkAt(deadline, i);
            path.* = try owned.dupe(PointLL, coordinates);
        }
        return .{ .lines = copied };
    }
};

const testing = std.testing;
const p = PointLL.init;
const nodata = std.math.floatMax(f32);
const polygon_opts: ContourOptions = .{ .rings_only = true, .denoise = 0, .generalize_m = 0 };

test "gridded minima support multiple metrics and SIMD runs without changing adjacent cells" {
    var data = try Grid(2).init(testing.allocator, .init(0, 0, 4, 3), 1, .{ 100, 200 }, .none);
    defer data.deinit();
    data.setIfLess(3, .{ 25, 80 });
    data.setIfLess(3, .{ 50, 60 });
    data.setIfLess(-1, .{ 0, 0 });
    data.setIfLess(12, .{ 0, 0 });
    try data.setManyIfLess(3, &.{
        .{ std.math.nan(f32), 20 }, .{ 1, 10 }, .{ 2, 9 }, .{ 3, 8 }, .{ 4, 7 }, .{ 5, std.math.inf(f32) },
    }, .none);
    try testing.expectEqual([2]f32{ 25, 20 }, data.data[3]);
    try testing.expectEqual([2]f32{ 4, 7 }, data.data[7]);
    try testing.expectEqual([2]f32{ 5, 200 }, data.data[8]);
    try testing.expectEqual([2]f32{ 100, 200 }, data.data[2]);
    try testing.expectEqual([2]f32{ 100, 200 }, data.data[9]);
    try data.setManyIfLess(11, &.{ .{ 6, 7 }, .{ 1, 2 } }, .none);
    try testing.expectEqual(6, data.dataAt(11, 0).?);
    try testing.expectEqual(null, data.dataAt(12, 0));
}

// Ported from test/gridded_data.cc, GriddedData.Basic.
test "nested distance contours match Midgard's test" {
    var data = try Grid(1).init(testing.allocator, .init(-7, -7, 7, 7), 1, .{nodata}, .none);
    defer data.deinit();
    for (0..14) |col| {
        for (0..14) |row| {
            const id = data.tiles.tileIdColRow(@intCast(col), @intCast(row));
            const distance = p(0, 0).distance(data.tiles.base(id));
            data.setIfLess(id, .{@floatCast(distance)});
        }
    }
    const thresholds = [_]Interval{
        .{ .metric = 0, .value = 100_000, .name = "dist" }, .{ .metric = 0, .value = 200_000, .name = "dist" },
        .{ .metric = 0, .value = 300_000, .name = "dist" }, .{ .metric = 0, .value = 400_000, .name = "dist" },
        .{ .metric = 0, .value = 500_000, .name = "dist" }, .{ .metric = 0, .value = 600_000, .name = "dist" },
    };
    var contours = try data.generateContours(testing.allocator, &thresholds, .{ .rings_only = true }, .none);
    defer contours.deinit();
    try testing.expectEqual(thresholds.len, contours.items.len);
    for (contours.items, 0..) |feature, i| {
        const polygons = feature.geometry.polygons;
        try testing.expectEqual(thresholds[thresholds.len - 1 - i].value, feature.interval.value);
        try testing.expectEqual(1, polygons.len);
        if (i + 1 == contours.items.len) break;
        for (contours.items[i + 1].geometry.polygons[0].outer) |point| {
            try testing.expectEqual(.inside, try polygons[0].locate(point, .none));
        }
    }
}

test "cone produces a centered diamond at one unit" {
    var data = try Grid(1).init(testing.allocator, .init(0, 0, 7, 7), 1, .{nodata}, .none);
    defer data.deinit();
    for (0..7) |row| {
        for (0..7) |col| {
            const distance = @max(row, 3) - @min(row, 3) + @max(col, 3) - @min(col, 3);
            data.setIfLess(data.tiles.tileIdColRow(@intCast(col), @intCast(row)), .{@floatFromInt(distance)});
        }
    }
    var contours = try data.generateContours(testing.allocator, &.{.{ .metric = 0, .value = 1 }}, polygon_opts, .none);
    defer contours.deinit();
    const polygons = contours.items[0].geometry.polygons;
    try testing.expectEqual(1, polygons.len);
    try testing.expectEqual(2, try polygon.signedArea(polygons[0].outer, .none));
    try testing.expectEqual(AABB.init(2.5, 2.5, 4.5, 4.5), AABB.of(polygons[0].outer));
    try testing.expectEqual(.inside, try polygons[0].locate(p(3.5, 3.5), .none));
}

test "saddle contours separate and merge at the cell center height" {
    var data = try Grid(1).init(testing.allocator, .init(0, 0, 7, 7), 1, .{nodata}, .none);
    defer data.deinit();
    for (0..data.data.len) |id| data.setIfLess(@intCast(id), .{2});
    data.setIfLess(data.tiles.tileIdColRow(2, 2), .{0});
    data.setIfLess(data.tiles.tileIdColRow(3, 3), .{0});
    var contours = try data.generateContours(testing.allocator, &.{
        .{ .metric = 0, .value = 0.75 },
        .{ .metric = 0, .value = 1 },
        .{ .metric = 0, .value = 1.25 },
    }, polygon_opts, .none);
    defer contours.deinit();
    try testing.expectEqual(1, contours.items[0].geometry.polygons.len);
    try testing.expectEqual(2, contours.items[1].geometry.polygons.len);
    for (contours.items[1].geometry.polygons) |poly|
        try testing.expectEqual(.boundary, try poly.locate(p(3, 3), .none));
    try testing.expectEqual(2, contours.items[2].geometry.polygons.len);
}

test "a threshold plateau emits its perimeter once" {
    var data = try Grid(1).init(testing.allocator, .init(0, 0, 7, 7), 1, .{nodata}, .none);
    defer data.deinit();
    for (0..data.data.len) |id| data.setIfLess(@intCast(id), .{4});
    for (2..4) |row| {
        for (2..4) |col| data.setIfLess(data.tiles.tileIdColRow(@intCast(col), @intCast(row)), .{1});
    }
    var contours = try data.generateContours(testing.allocator, &.{.{ .metric = 0, .value = 1 }}, polygon_opts, .none);
    defer contours.deinit();
    const polygons = contours.items[0].geometry.polygons;
    try testing.expectEqual(1, polygons.len);
    try testing.expectEqual(1, try polygon.signedArea(polygons[0].outer, .none));
    try testing.expectEqual(AABB.init(2.5, 2.5, 3.5, 3.5), AABB.of(polygons[0].outer));
}

test "contours nest holes and can denoise by relative area" {
    var data = try Grid(1).init(testing.allocator, .init(0, 0, 10, 10), 1, .{nodata}, .none);
    defer data.deinit();
    for (0..10) |row| {
        for (0..10) |col| {
            const low = row >= 2 and row <= 7 and col >= 2 and col <= 7 and !(row == 4 and col == 4);
            data.setIfLess(data.tiles.tileIdColRow(@intCast(col), @intCast(row)), .{if (low) 0 else 2});
        }
    }
    const intervals = [_]Interval{.{ .metric = 0, .value = 1 }};
    var all = try data.generateContours(testing.allocator, &intervals, polygon_opts, .none);
    defer all.deinit();
    const shell = all.items[0].geometry.polygons[0];
    try testing.expectEqual(1, shell.holes.len);
    try testing.expectEqual(.clockwise, try polygon.winding(shell.holes[0], .none));
    try testing.expectEqual(.outside, try shell.locate(p(4.5, 4.5), .none));
    var denoised = try data.generateContours(testing.allocator, &intervals, .{
        .rings_only = true,
        .denoise = 0.2,
        .generalize_m = optimal_generalization,
    }, .none);
    defer denoised.deinit();
    const kept = denoised.items[0].geometry.polygons[0];
    try testing.expectEqual(0, kept.holes.len);
    try testing.expectEqual(.inside, try kept.locate(p(4.5, 4.5), .none));
    try testing.expect(kept.outer.len < shell.outer.len);
}

test "line contours remain open and intervals are sorted by metric" {
    var data = try Grid(2).init(testing.allocator, .init(0, 0, 7, 7), 1, @splat(nodata), .none);
    defer data.deinit();
    for (0..7) |row| {
        for (0..7) |col| {
            data.setIfLess(data.tiles.tileIdColRow(@intCast(col), @intCast(row)), .{ @floatFromInt(col), @floatFromInt(row) });
        }
    }
    var contours = try data.generateContours(testing.allocator, &.{
        .{ .metric = 0, .value = 2.5, .name = "distance" },
        .{ .metric = 1, .value = 2.5, .name = "time" },
    }, .{ .denoise = 0, .generalize_m = 0 }, .none);
    defer contours.deinit();
    try testing.expectEqualStrings("time", contours.items[0].interval.name);
    try testing.expectEqualStrings("distance", contours.items[1].interval.name);
    for (contours.items) |contour| {
        const paths = contour.geometry.lines;
        try testing.expectEqual(1, paths.len);
        try testing.expect(!paths[0][0].eql(paths[0][paths[0].len - 1]));
    }
}
