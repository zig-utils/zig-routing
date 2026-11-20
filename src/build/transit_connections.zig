// Ported from src/mjolnir/transitbuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const geo = @import("../geo/point.zig");
const io = @import("../infra/io.zig");
const snap = @import("../snap/search.zig");
const Allocator = std.mem.Allocator;

pub const snap_cutoff_m: f64 = 500.0;

pub fn streetUse(use: graph.constants.Use) bool {
    return switch (use) {
        .road, .living_street, .cycleway, .sidewalk, .footway, .path, .pedestrian, .alley, .service_road => true,
        else => false,
    };
}

pub const Match = struct {
    id: u32,
    projection: snap.Projection,
};

pub const Search = struct {
    allocator: Allocator,
    coordinates: std.ArrayList(geo.PointLL) = .empty,
    seen: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn deinit(self: *Search) void {
        self.seen.deinit(self.allocator);
        self.coordinates.deinit(self.allocator);
    }

    /// Source.shape returns null for a segment that pedestrians cannot use.
    /// Index entries name the same segments as the source.
    pub fn nearest(self: *Search, index: graph.spatial.View, source: anytype, point: geo.FixedLL, deadline: io.Deadline) !?Match {
        self.seen.clearRetainingCapacity();
        const approx: geo.DistanceApproximator = .init(point.toPoint());
        var cells = try index.projectionRings(self.allocator, approx, snap_cutoff_m, deadline);
        defer cells.deinit();
        var best: ?Match = null;
        var best_squared = snap_cutoff_m * snap_cutoff_m;
        while (cells.next()) |hit| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (hit.distance * hit.distance > best_squared) break;
            var ids = hit.cell.edges();
            while (try ids.next()) |id| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const street = @backingInt(id);
                const seen = try self.seen.getOrPut(self.allocator, street);
                if (seen.found_existing) continue;
                const shape = (try source.shape(street)) orelse continue;
                if (shape.len < 2) return error.InvalidStreetShape;
                try self.coordinates.resize(self.allocator, shape.len);
                for (shape, self.coordinates.items, 0..) |fixed, *ll, i| {
                    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                    ll.* = fixed.toPoint();
                }
                const projected = try snap.project(approx, self.coordinates.items, deadline);
                if (projected.squared < best_squared or
                    (projected.squared == best_squared and best != null and street < best.?.id))
                {
                    best = .{ .id = street, .projection = projected };
                    best_squared = projected.squared;
                }
            }
        }
        return best;
    }
};

pub const Endpoint = enum { from, to };

/// Street endpoint, traversed part of the street, projection, and entrance.
/// Adjacent repeated points are elided except for a coincident two-point
/// connector, which still needs a start and an end.
pub fn approachShape(
    a: Allocator,
    out: *std.ArrayList(geo.FixedLL),
    shape: []const geo.FixedLL,
    projection: snap.Projection,
    entrance: geo.FixedLL,
    endpoint: Endpoint,
    deadline: io.Deadline,
) !f64 {
    if (shape.len < 2 or projection.segment >= shape.len - 1 or !projection.point.inRange() or !entrance.inRange())
        return error.InvalidStreetProjection;
    out.clearRetainingCapacity();
    const split = projection.segment + 1;
    switch (endpoint) {
        .from => for (shape[0..split], 0..) |point, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            try appendDistinct(a, out, point);
        },
        .to => {
            var i = shape.len;
            while (i > split) {
                i -= 1;
                if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                try appendDistinct(a, out, shape[i]);
            }
        },
    }
    try appendDistinct(a, out, projection.point.toFixed());
    try appendDistinct(a, out, entrance);
    if (out.items.len == 1) try out.append(a, entrance);
    var meters: f64 = 0;
    for (out.items[0 .. out.items.len - 1], out.items[1..], 0..) |left, right, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        meters += left.toPoint().distance(right.toPoint());
    }
    return @max(1, meters);
}

fn appendDistinct(a: Allocator, out: *std.ArrayList(geo.FixedLL), point: geo.FixedLL) !void {
    if (out.items.len == 0 or !std.meta.eql(out.items[out.items.len - 1], point)) try out.append(a, point);
}

test "street approach follows the nearest walkable shape from either endpoint" {
    const testing = std.testing;
    const a = testing.allocator;
    const entrance: geo.FixedLL = .{ .lng = 2000, .lat = 2000 };
    const Source = struct {
        const road = [_]geo.FixedLL{ .{ .lng = 1000, .lat = 1000 }, .{ .lng = 3000, .lat = 1000 } };

        fn shape(_: @This(), id: u32) !?[]const geo.FixedLL {
            return if (id == 1) &road else null;
        }
    };
    const cell = @import("../geo/grid.zig").snapCell(entrance.toPoint());
    const index: graph.spatial.View = .{
        .directory = &.{.{ .id = cell, .offset = 0 }},
        .lists = &.{ 0, 1 },
        .edge_count = 2,
    };
    var search: Search = .{ .allocator = a };
    defer search.deinit();
    const closest = (try search.nearest(index, Source{}, entrance, .none)).?;
    try testing.expectEqual(1, closest.id);
    const projection: geo.FixedLL = .{ .lng = 2000, .lat = 1000 };
    try testing.expectEqualDeep(projection, closest.projection.point.toFixed());

    var shape: std.ArrayList(geo.FixedLL) = .empty;
    defer shape.deinit(a);
    for ([_]Endpoint{ .from, .to }, Source.road) |endpoint, start| {
        const length = try approachShape(a, &shape, &Source.road, closest.projection, entrance, endpoint, .none);
        try testing.expect(length > 20 and length < 23);
        try testing.expectEqualSlices(geo.FixedLL, &.{ start, projection, entrance }, shape.items);
    }
}
