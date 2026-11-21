//! Snap-grid entries for geocoded points and street and interpolation shapes.
const std = @import("std");
const io = @import("../infra/io.zig");
const spatial = @import("../graph/spatial.zig");
const grid = @import("../geo/grid.zig");
const bundle = @import("bundle.zig");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const Item = union(enum) {
    address: u32,
    place: u32,
    poi: u32,
    street_anchor: u32,
    street_piece: struct { street: u32, shape: model.Span },
    interpolation: u32,
};

pub const Index = struct {
    a: Allocator,
    items: []const Item,
    cells: spatial.Owned,
    wide_ranges: []const u32,
    range_streets: []const ?u32,

    pub fn init(a: Allocator, data: bundle.Data, deadline: io.Deadline) !Index {
        var build: Builder = .{ .a = a, .deadline = deadline };
        defer build.items.deinit(a);
        defer build.pairs.deinit(a);
        defer build.wide_ranges.deinit(a);
        for (data.addresses, 0..) |address, i| try build.addPoint(.{ .address = try row(i) }, address.record.coordinate);
        for (data.pois, 0..) |poi, i| try build.addPoint(.{ .poi = try row(i) }, poi.record.coordinate);
        for (data.places, 0..) |place, i| try build.addPoint(.{ .place = try row(i) }, place.record.coordinate);
        const extended = data.address_data;
        const range_streets = try a.alloc(?u32, if (extended) |addresses| addresses.interpolations.len else 0);
        errdefer a.free(range_streets);
        @memset(range_streets, null);
        if (extended) |addresses| {
            for (addresses.interpolations, 0..) |range, i| {
                try build.addRange(try row(i), try range.shape.get(addresses.address_coordinates));
            }
        }
        for (data.streets, 0..) |street, i| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const street_id = try row(i);
            if (extended) |addresses| {
                const shapes = try street.ways.get(addresses.street_shapes);
                for (shapes) |shape| try build.addStreet(street_id, shape, addresses.address_coordinates);
                const links = try addresses.street_houses[i].get(addresses.house_links);
                for (links, 0..) |link, j| {
                    if (j % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                    if (link.attr.kind == .interpolation and range_streets[link.object_id] == null)
                        range_streets[link.object_id] = street_id;
                }
            } else try build.addPoint(.{ .street_anchor = street_id }, street.record.coordinate);
        }
        const scratch = try a.alloc(spatial.Pair, build.pairs.items.len);
        defer a.free(scratch);
        var cells = try spatial.encode(a, build.pairs.items, scratch, try row(build.items.items.len), deadline);
        errdefer cells.deinit();
        const items = try build.items.toOwnedSlice(a);
        errdefer a.free(items);
        return .{
            .a = a,
            .items = items,
            .cells = cells,
            .wide_ranges = try build.wide_ranges.toOwnedSlice(a),
            .range_streets = range_streets,
        };
    }

    pub fn close(self: *Index) void {
        self.cells.deinit();
        self.a.free(self.items);
        self.a.free(self.wide_ranges);
        self.a.free(self.range_streets);
        self.* = undefined;
    }
};

const Builder = struct {
    a: Allocator,
    deadline: io.Deadline,
    items: std.ArrayList(Item) = .empty,
    pairs: std.ArrayList(spatial.Pair) = .empty,
    wide_ranges: std.ArrayList(u32) = .empty,

    fn add(self: *Builder, item: Item) !u32 {
        if (self.deadline.expired()) return error.DeadlineExceeded;
        const id = try row(self.items.items.len);
        try self.items.append(self.a, item);
        return id;
    }

    fn addPoint(self: *Builder, item: Item, coordinate: model.Coordinate) !void {
        const id = try self.add(item);
        const cell = grid.snapCell(coordinate.toPoint());
        try self.pairs.append(self.a, (@as(u64, cell) << 32) | id);
    }

    fn addStreet(self: *Builder, street: u32, shape: model.Span, coordinates: []const model.Coordinate) !void {
        const points = try shape.get(coordinates);
        if (points.len == 1) {
            return self.addPoint(.{ .street_piece = .{ .street = street, .shape = shape } }, points[0]);
        }
        for (0..points.len - 1) |i| {
            const span = try model.Span.init(@as(usize, shape.first) + i, 2);
            const id = try self.add(.{ .street_piece = .{ .street = street, .shape = span } });
            try spatial.addShape(self.a, &self.pairs, id, points[i..][0..2], self.deadline);
        }
    }

    fn addRange(self: *Builder, range: u32, points: []const model.Coordinate) !void {
        const id = try self.add(.{ .interpolation = range });
        for (points[0 .. points.len - 1], points[1..]) |first, last| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const distance = first.toPoint().distance(last.toPoint());
            if (distance > 5000 or @abs(first.toPoint().lat) > 89.9) {
                // Avoid duplicating long arcs into thousands of cells.
                try self.wide_ranges.append(self.a, id);
                return;
            }
            try spatial.addCircleCover(self.a, &self.pairs, id, first.toPoint(), distance + 0.03, self.deadline);
        }
    }
};

fn row(i: usize) !u32 {
    return std.math.cast(u32, i) orelse error.GeocodeSectionTooLarge;
}
