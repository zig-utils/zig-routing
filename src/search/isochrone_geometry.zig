//! Immutable samples derived from an existing graph bundle for raster replay.
const std = @import("std");
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");
const Deadline = @import("../infra/io.zig").Deadline;

const View = graph.reader.View;
const Point = geo.PointLL;
const Use = graph.constants.Use;
pub const cell_count = 5;
pub const cell_step: f32 = 0.001;

pub fn shapeInterval(cell: f32) f32 {
    return cell * @as(f32, geo.constants.meters_per_degree_lat) * 0.25;
}

pub fn cellIndex(cell: f32) usize {
    return @as(usize, @intFromFloat(@round(cell * 1000))) - 1;
}

pub fn paints(use: u8) bool {
    return use != @backingInt(Use.ferry) and use != @backingInt(Use.rail) and use != @backingInt(Use.bus);
}

const EdgeShape = packed struct(u32) {
    row_plus_one: u31 = 0,
    reverse: bool = false,
};

const Row = [cell_count + 1]u32;

pub const Shape = struct {
    points: []const Point,
    reverse: bool,
    distances: ?[]const f32 = null,
};

/// Each row holds the resampled points in storage order at every cell width
/// that uses the long-edge painter. Opposing directions can share a row when
/// their cold record and rounded length both match.
pub const Layout = struct {
    pub const Mode = enum { samples, distances };

    view: *const View,
    mode: Mode,
    edges: []const EdgeShape,
    rows: []const Row,
    points: []const Point,
    distances: []const f32,

    pub fn init(a: std.mem.Allocator, view: *const View, mode: Mode, deadline: Deadline) !Layout {
        if (deadline.expired()) return error.Cancelled;
        const refs = view.cold_idx orelse return error.MissingColdData;
        const edges = try a.alloc(EdgeShape, view.edges.len);
        errdefer a.free(edges);
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(a);
        var points: std.ArrayList(Point) = .empty;
        defer points.deinit(a);
        var distances: std.ArrayList(f32) = .empty;
        defer distances.deinit(a);
        var vertices: std.ArrayList(Point) = .empty;
        defer vertices.deinit(a);

        for (view.edges, refs, edges, 0..) |*edge, ref, *entry, i| {
            if (i % 256 == 0 and deadline.expired()) return error.Cancelled;
            entry.* = .{};
            const length: f32 = @floatFromInt(edge.geom.len_m);
            if (length < shapeInterval(cell_step) * 1.5) continue;
            if (!paints((try view.class(edge.cls.class_id)).category.use)) continue;
            const other = @backingInt(try view.opposingId(edge));
            if (other < i and edges[other].row_plus_one != 0 and
                @as(u31, @truncate(refs[other])) == @as(u31, @truncate(ref)) and
                view.edges[other].geom.len_m == edge.geom.len_m)
            {
                entry.* = .{ .row_plus_one = edges[other].row_plus_one, .reverse = ref >> 31 != 0 };
                continue;
            }

            const id: graph.format.EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
            var record = try view.coldRecordWithDeadline(id, deadline);
            entry.* = .{
                .row_plus_one = std.math.cast(u31, rows.items.len + 1) orelse return error.GeometryTooLarge,
                .reverse = record.reverse,
            };
            record.reverse = false;
            try vertices.resize(a, record.header.point_count);
            try record.decodeTilePoints(vertices.items, deadline);
            var offsets: Row = undefined;
            switch (mode) {
                .samples => {
                    for (0..cell_count) |index| {
                        offsets[index] = std.math.cast(u32, points.items.len) orelse return error.GeometryTooLarge;
                        const cell = @as(f32, @floatFromInt(index + 1)) * cell_step;
                        const interval = shapeInterval(cell);
                        if (length < interval * 1.5) continue;
                        try geo.line.resamplePolylineWithDeadline(a, vertices.items, length, interval, &points, deadline);
                    }
                    offsets[cell_count] = std.math.cast(u32, points.items.len) orelse return error.GeometryTooLarge;
                },
                .distances => {
                    const start = points.items.len;
                    const end = start + vertices.items.len;
                    offsets = @splat(std.math.cast(u32, end) orelse return error.GeometryTooLarge);
                    offsets[0] = @intCast(start);
                    try points.appendSlice(a, vertices.items);
                    try distances.resize(a, end);
                    try geo.line.prepareResamplingDistances(vertices.items, distances.items[start..], deadline);
                },
            }
            try rows.append(a, offsets);
        }
        const owned_rows = try rows.toOwnedSlice(a);
        errdefer a.free(owned_rows);
        const owned_points = try points.toOwnedSlice(a);
        errdefer a.free(owned_points);
        return .{
            .view = view,
            .mode = mode,
            .edges = edges,
            .rows = owned_rows,
            .points = owned_points,
            .distances = try distances.toOwnedSlice(a),
        };
    }

    pub fn deinit(self: Layout, a: std.mem.Allocator) void {
        a.free(self.distances);
        a.free(self.points);
        a.free(self.rows);
        a.free(self.edges);
    }

    pub fn residentBytes(self: Layout) usize {
        return self.edges.len * @sizeOf(EdgeShape) + self.rows.len * @sizeOf(Row) +
            self.points.len * @sizeOf(Point) + self.distances.len * @sizeOf(f32);
    }

    pub fn shape(self: *const Layout, edge: graph.format.EdgeId, cell: usize) ?Shape {
        const entry = self.edges[@backingInt(edge)];
        if (entry.row_plus_one == 0) return null;
        const row = &self.rows[entry.row_plus_one - 1];
        const index = if (self.mode == .samples) cell else 0;
        const start = row[index];
        const end = row[index + 1];
        if (start == end) return null;
        return .{
            .points = self.points[start..end],
            .reverse = entry.reverse,
            .distances = if (self.mode == .distances) self.distances[start..end] else null,
        };
    }
};
