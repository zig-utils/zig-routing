//! The geocoder's persisted administrative boundaries and point lookup.
const std = @import("std");
const io = @import("../infra/io.zig");
const geo = @import("../geo/point.zig");
const polygon = @import("../geo/polygon.zig");
const polygon_index = @import("../geo/polygon_index.zig");
const bundle = @import("bundle.zig");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const Choice = struct {
    ids: [5]model.AdminId = @splat(.unknown),
    areas: [5]f64 = @splat(std.math.inf(f64)),

    pub fn add(self: *Choice, division: model.Division, id: model.AdminId, area: f64) void {
        const slot = @backingInt(division);
        if (area > self.areas[slot] or (area == self.areas[slot] and @backingInt(id) >= @backingInt(self.ids[slot]))) return;
        self.areas[slot] = area;
        self.ids[slot] = id;
    }

    pub fn hierarchy(self: Choice) model.Hierarchy {
        var result: model.Hierarchy = .{};
        inline for (std.enums.values(model.Division)) |division|
            @field(result, @tagName(division)) = self.ids[@backingInt(division)];
        return result;
    }
};

pub fn encode(a: Allocator, shapes: []const polygon.Polygon, owners: []const usize, deadline: io.Deadline) !bundle.AdminGeometry {
    const records = try a.alloc(model.AdminPolygon, shapes.len);
    var rings: std.ArrayList(model.Span) = .empty;
    var points: std.ArrayList(model.Coordinate) = .empty;
    for (shapes, owners, records) |shape, owner, *record| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const id = std.math.cast(u32, owner + 1) orelse return error.GeocodeSectionTooLarge;
        record.* = .{
            .admin = @fromBackingInt(id),
            .outer = try appendRing(a, &points, shape.outer, deadline),
            .holes = try model.Span.init(rings.items.len, shape.holes.len),
        };
        for (shape.holes) |hole| try rings.append(a, try appendRing(a, &points, hole, deadline));
    }
    return .{ .admin_polygons = records, .admin_rings = rings.items, .admin_coordinates = points.items };
}

fn appendRing(a: Allocator, points: *std.ArrayList(model.Coordinate), ring: polygon.Ring, deadline: io.Deadline) !model.Span {
    const span = try model.Span.init(points.items.len, ring.len);
    const target = try points.addManyAsSlice(a, ring.len);
    for (ring, target, 0..) |point, *destination, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        destination.* = point.toFixed();
    }
    return span;
}

pub const View = struct {
    memory: std.heap.ArenaAllocator,
    tree: polygon_index.Index,
    polygons: []const model.AdminPolygon,
    admins: []const model.Admin,
    areas: []const f64,

    pub fn open(a: Allocator, data: bundle.Data, deadline: io.Deadline) !?View {
        const geometry = data.admin_geometry orelse return null;
        var memory: std.heap.ArenaAllocator = .init(a);
        errdefer memory.deinit();
        const owned = memory.allocator();
        const points = try owned.alloc(geo.PointLL, geometry.admin_coordinates.len);
        for (geometry.admin_coordinates, points, 0..) |coordinate, *point, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            point.* = coordinate.toPoint();
        }
        const holes = try owned.alloc(polygon.Ring, geometry.admin_rings.len);
        for (geometry.admin_rings, holes, 0..) |span, *hole, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            hole.* = try span.get(@as([]const geo.PointLL, points));
        }
        const areas = try owned.alloc(f64, data.admins.len);
        @memset(areas, 0);
        const polys = try owned.alloc(polygon.Polygon, geometry.admin_polygons.len);
        for (geometry.admin_polygons, polys) |entry, *poly| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (try data.admin(entry.admin) == null) return error.InvalidGeocodeAdminGeometry;
            poly.* = .{
                .outer = try entry.outer.get(@as([]const geo.PointLL, points)),
                .holes = try entry.holes.get(@as([]const polygon.Ring, holes)),
            };
            areas[@backingInt(entry.admin) - 1] += @abs(try polygon.signedArea(poly.outer, deadline));
        }
        return .{
            .tree = try polygon_index.Index.init(a, polys, deadline),
            .memory = memory,
            .polygons = geometry.admin_polygons,
            .admins = data.admins,
            .areas = areas,
        };
    }

    pub fn close(self: *View) void {
        self.tree.deinit();
        self.memory.deinit();
        self.* = undefined;
    }

    pub fn lookup(self: View, a: Allocator, point: geo.PointLL, deadline: io.Deadline) !model.Hierarchy {
        var hits: std.ArrayList(u32) = .empty;
        defer hits.deinit(a);
        try self.tree.lookup(a, point, &hits, deadline);
        var found: Choice = .{};
        for (hits.items) |hit| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const id = self.polygons[hit].admin;
            const index = @backingInt(id) - 1;
            found.add(self.admins[index].attr.division, id, self.areas[index]);
        }
        return found.hierarchy();
    }
};

test "persisted polygon holes exclude their interiors and retain boundary hits" {
    const t = std.testing;
    const a = t.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const memory = arena.allocator();
    const outer: []const geo.PointLL = &.{ .init(0, 0), .init(4, 0), .init(4, 4), .init(0, 4) };
    const hole: []const geo.PointLL = &.{ .init(1, 1), .init(2, 1), .init(2, 2), .init(1, 2) };
    const data: bundle.Data = .{
        .admins = &.{.{ .osm_id = 4, .names = .{}, .attr = .{ .division = .country, .level = 2 } }},
        .admin_geometry = try encode(memory, &.{.{ .outer = outer, .holes = &.{hole} }}, &.{0}, .none),
    };
    try data.validate(.none);
    var view = (try View.open(a, data, .none)).?;
    defer view.close();
    try t.expectEqual(.unknown, (try view.lookup(memory, .init(1.5, 1.5), .none)).country);
    try t.expectEqual(@as(model.AdminId, @fromBackingInt(1)), (try view.lookup(memory, .init(1, 1.5), .none)).country);
    try t.expectEqual(@as(model.AdminId, @fromBackingInt(1)), (try view.lookup(memory, .init(3, 3), .none)).country);
    try t.expectEqual(.unknown, (try view.lookup(memory, .init(20, 20), .none)).country);
}
