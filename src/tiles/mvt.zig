//! Mapbox Vector Tile 2.1 wire encoding.
const std = @import("std");
const wire = @import("protobuf").wire;
const io = @import("../infra/io.zig");
const Deadline = io.Deadline;
const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error || error{ DeadlineExceeded, InvalidGeometry, InvalidExtent, InvalidTile, DuplicateLayer };

pub const extent = 4096;
pub const mime_type = "application/vnd.mapbox-vector-tile";
pub const gzip = io.deflateGzip;
pub const Point = struct { x: i32, y: i32 };
pub const Kind = enum(u2) { point = 1, linestring = 2, polygon = 3 };
pub const Winding = enum { exterior, interior };
pub const Ring = struct { points: []const Point, winding: Winding };
pub const Value = union(enum) {
    string: []const u8,
    float: f32,
    double: f64,
    signed: i64,
    unsigned: u64,
    zigzag: i64,
    boolean: bool,
};
pub const Property = struct { key: []const u8, value: Value };

const max_commands = (1 << 29) - 1;

pub fn quantize(x: f64, y: f64, tile_extent: u32) Error!Point {
    if (tile_extent == 0) return error.InvalidExtent;
    const scale: f64 = @floatFromInt(tile_extent);
    return roundPoint(x * scale, y * scale);
}

pub fn roundPoint(x: f64, y: f64) Error!Point {
    return .{ .x = try roundCoordinate(x), .y = try roundCoordinate(y) };
}

fn roundCoordinate(value: f64) Error!i32 {
    const rounded = @round(value);
    if (!std.math.isFinite(rounded) or rounded < std.math.minInt(i32) or rounded > std.math.maxInt(i32))
        return error.InvalidGeometry;
    return @intFromFloat(rounded);
}

pub fn signedArea(points: []const Point, deadline: Deadline) Error!i128 {
    if (points.len < 3) return error.InvalidGeometry;
    var area: i128 = 0;
    var previous = points[points.len - 1];
    for (points, 0..) |point, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        area += @as(i128, previous.x) * point.y - @as(i128, previous.y) * point.x;
        previous = point;
    }
    return area;
}

const Bytes = struct {
    a: Allocator,
    data: std.ArrayList(u8) = .empty,

    pub fn writeAll(self: *Bytes, value: []const u8) Allocator.Error!void {
        try self.data.appendSlice(self.a, value);
    }

    fn number(self: *Bytes, field: wire.FieldNumber, value: u64) Allocator.Error!void {
        try wire.writeVarint(self, wire.tagValue(field, .varint));
        try wire.writeVarint(self, value);
    }

    fn fixed(self: *Bytes, comptime T: type, field: wire.FieldNumber, value: T) Allocator.Error!void {
        try wire.writeVarint(self, wire.tagValue(field, if (@sizeOf(T) == 4) .fixed32 else .fixed64));
        try wire.writeFixed(T, self, value);
    }

    fn blob(self: *Bytes, field: wire.FieldNumber, data: []const u8) Allocator.Error!void {
        try wire.writeVarint(self, wire.tagValue(field, .length_delimited));
        try wire.writeVarint(self, data.len);
        try self.writeAll(data);
    }

    fn reset(self: *Bytes) void {
        self.data.clearRetainingCapacity();
    }

    fn deinit(self: *Bytes) void {
        self.data.deinit(self.a);
    }
};

const ValueContext = struct {
    pub fn hash(_: ValueContext, value: Value) u32 {
        var h = std.hash.Wyhash.init(@backingInt(std.meta.activeTag(value)));
        switch (value) {
            .string => |s| h.update(s),
            inline else => |payload| h.update(std.mem.asBytes(&payload)),
        }
        return @truncate(h.final());
    }

    pub fn eql(_: ValueContext, a: Value, b: Value, _: usize) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .float => |f| @as(u32, @bitCast(f)) == @as(u32, @bitCast(b.float)),
            .double => |d| @as(u64, @bitCast(d)) == @as(u64, @bitCast(b.double)),
            inline else => |payload, tag| payload == @field(b, @tagName(tag)),
        };
    }
};

/// The dictionaries borrow their strings until the layer is written.
pub const Layer = struct {
    name: []const u8,
    tile_extent: u32 = extent,
    keys: std.StringArrayHashMapUnmanaged(void) = .empty,
    values: std.ArrayHashMapUnmanaged(Value, void, ValueContext, true) = .empty,
    contents: Bytes,
    feature: Bytes,
    tags: Bytes,
    geometry: Bytes,
    scratch: Bytes,

    pub fn init(a: Allocator, name: []const u8) Layer {
        return .{
            .name = name,
            .contents = .{ .a = a },
            .feature = .{ .a = a },
            .tags = .{ .a = a },
            .geometry = .{ .a = a },
            .scratch = .{ .a = a },
        };
    }

    pub fn initExtent(a: Allocator, name: []const u8, tile_extent: u32) Error!Layer {
        if (tile_extent == 0) return error.InvalidExtent;
        var layer = init(a, name);
        layer.tile_extent = tile_extent;
        return layer;
    }

    pub fn deinit(self: *Layer) void {
        self.keys.deinit(self.contents.a);
        self.values.deinit(self.contents.a);
        self.contents.deinit();
        self.feature.deinit();
        self.tags.deinit();
        self.geometry.deinit();
        self.scratch.deinit();
    }

    pub fn reset(self: *Layer) void {
        self.keys.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
        self.contents.reset();
        self.feature.reset();
        self.tags.reset();
        self.geometry.reset();
        self.scratch.reset();
    }

    pub fn addPoint(self: *Layer, id: u64, point: Point, properties: []const Property, deadline: Deadline) Error!void {
        return self.addPoints(id, &.{point}, properties, deadline);
    }

    pub fn addPoints(self: *Layer, id: u64, points: []const Point, properties: []const Property, deadline: Deadline) Error!void {
        if (points.len == 0 or points.len > max_commands) return error.InvalidGeometry;
        self.geometry.reset();
        try wire.writeVarint(&self.geometry, (points.len << 3) | 1);
        var cursor = Point{ .x = 0, .y = 0 };
        for (points, 0..) |point, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            try delta(&self.geometry, cursor, point);
            cursor = point;
        }
        return self.addFeature(id, .point, properties, deadline);
    }

    pub fn addLine(self: *Layer, id: u64, points: []const Point, properties: []const Property, deadline: Deadline) Error!void {
        return self.addLines(id, &.{points}, properties, deadline);
    }

    pub fn addLines(self: *Layer, id: u64, lines: []const []const Point, properties: []const Property, deadline: Deadline) Error!void {
        if (lines.len == 0) return error.InvalidGeometry;
        self.geometry.reset();
        var cursor = Point{ .x = 0, .y = 0 };
        for (lines) |line| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (line.len < 2 or line.len - 1 > max_commands) return error.InvalidGeometry;
            try self.path(line, false, false, &cursor, deadline);
        }
        return self.addFeature(id, .linestring, properties, deadline);
    }

    pub fn addPolygon(self: *Layer, id: u64, rings: []const Ring, properties: []const Property, deadline: Deadline) Error!void {
        if (rings.len == 0 or rings[0].winding != .exterior) return error.InvalidGeometry;
        self.geometry.reset();
        var cursor = Point{ .x = 0, .y = 0 };
        for (rings) |ring| {
            if (deadline.expired()) return error.DeadlineExceeded;
            var points = ring.points;
            if (points.len > 1 and equal(points[0], points[points.len - 1])) points = points[0 .. points.len - 1];
            if (points.len < 3 or points.len - 1 > max_commands or equal(points[0], points[points.len - 1]))
                return error.InvalidGeometry;
            const area = try signedArea(points, deadline);
            if (area == 0) return error.InvalidGeometry;
            const reverse = (area > 0) != (ring.winding == .exterior);
            try self.path(points, reverse, true, &cursor, deadline);
        }
        return self.addFeature(id, .polygon, properties, deadline);
    }

    fn path(self: *Layer, points: []const Point, reverse: bool, close: bool, cursor: *Point, deadline: Deadline) Error!void {
        try wire.writeVarint(&self.geometry, 9); // MoveTo(1)
        try delta(&self.geometry, cursor.*, points[0]);
        cursor.* = points[0];
        try wire.writeVarint(&self.geometry, ((points.len - 1) << 3) | 2); // LineTo
        for (1..points.len) |i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const point = points[if (reverse) points.len - i else i];
            if (equal(cursor.*, point)) return error.InvalidGeometry;
            try delta(&self.geometry, cursor.*, point);
            cursor.* = point;
        }
        if (close) try wire.writeVarint(&self.geometry, 15); // ClosePath(1)
    }

    fn addFeature(self: *Layer, id: u64, kind: Kind, properties: []const Property, deadline: Deadline) Error!void {
        self.tags.reset();
        for (properties, 0..) |prop, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const key = try self.keys.getOrPut(self.contents.a, prop.key);
            const value = try self.values.getOrPut(self.contents.a, prop.value);
            try wire.writeVarint(&self.tags, key.index);
            try wire.writeVarint(&self.tags, value.index);
        }
        self.feature.reset();
        try self.feature.number(1, id);
        if (self.tags.data.items.len != 0) try self.feature.blob(2, self.tags.data.items);
        try self.feature.number(3, @backingInt(kind));
        try self.feature.blob(4, self.geometry.data.items);
        const before = self.contents.data.items.len;
        errdefer self.contents.data.shrinkRetainingCapacity(before);
        try self.contents.blob(2, self.feature.data.items);
    }

    /// Appends the layer to a tile; empty layers are omitted.
    pub fn write(self: *Layer, tile: *std.ArrayList(u8), deadline: Deadline) Error!void {
        if (self.contents.data.items.len == 0) return;
        if (self.tile_extent == 0) return error.InvalidExtent;
        if (!std.unicode.utf8ValidateSlice(self.name)) return error.InvalidTile;
        try checkLayerName(tile.items, self.name, deadline);
        self.feature.reset();
        try self.feature.number(15, 2);
        try self.feature.blob(1, self.name);
        const geometry_len = self.contents.data.items.len;
        defer self.contents.data.shrinkRetainingCapacity(geometry_len);
        for (self.keys.keys(), 0..) |key, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidTile;
            try self.contents.blob(3, key);
        }
        for (self.values.keys(), 0..) |value, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            self.scratch.reset();
            switch (value) {
                .string => |s| {
                    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidTile;
                    try self.scratch.blob(1, s);
                },
                .float => |f| try self.scratch.fixed(u32, 2, @bitCast(f)),
                .double => |d| try self.scratch.fixed(u64, 3, @bitCast(d)),
                .signed => |n| try self.scratch.number(4, @bitCast(n)),
                .unsigned => |n| try self.scratch.number(5, n),
                .zigzag => |n| try self.scratch.number(6, wire.zigzagEncode(i64, n)),
                .boolean => |b| try self.scratch.number(7, @intFromBool(b)),
            }
            try self.contents.blob(4, self.scratch.data.items);
        }
        try self.contents.number(5, self.tile_extent);
        var output: Bytes = .{ .a = self.contents.a, .data = tile.* };
        defer tile.* = output.data;
        const before = output.data.items.len;
        errdefer output.data.shrinkRetainingCapacity(before);
        try wire.writeVarint(&output, wire.tagValue(3, .length_delimited));
        try wire.writeVarint(&output, self.feature.data.items.len + self.contents.data.items.len);
        try output.writeAll(self.feature.data.items);
        try output.writeAll(self.contents.data.items);
    }
};

fn checkLayerName(tile: []const u8, name: []const u8, deadline: Deadline) Error!void {
    var layers = wire.Reader.init(tile);
    while (layers.next(deadline) catch |err| return wireError(err)) |entry| {
        if (entry.number != 3) continue;
        if (entry.value != .length_delimited) return error.InvalidTile;
        var fields = wire.Reader.init(entry.value.length_delimited);
        while (fields.next(deadline) catch |err| return wireError(err)) |field| {
            if (field.number != 1) continue;
            if (field.value != .length_delimited) return error.InvalidTile;
            if (std.mem.eql(u8, field.value.length_delimited, name)) return error.DuplicateLayer;
            break;
        }
    }
}

fn wireError(err: wire.Error) Error {
    return switch (err) {
        error.DeadlineExceeded => error.DeadlineExceeded,
        else => error.InvalidTile,
    };
}

fn equal(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn delta(bytes: *Bytes, from: Point, to: Point) Error!void {
    const x = std.math.sub(i32, to.x, from.x) catch return error.InvalidGeometry;
    const y = std.math.sub(i32, to.y, from.y) catch return error.InvalidGeometry;
    if (x == std.math.minInt(i32) or y == std.math.minInt(i32)) return error.InvalidGeometry;
    try wire.writeVarint(bytes, wire.zigzagEncode(i32, x));
    try wire.writeVarint(bytes, wire.zigzagEncode(i32, y));
}

test "MVT line commands use signed deltas and share attribute dictionary entries" {
    const a = std.testing.allocator;
    var layer: Layer = .init(a, "edges");
    defer layer.deinit();
    const props = &.{
        Property{ .key = "length", .value = .{ .unsigned = 10 } },
        Property{ .key = "name", .value = .{ .string = "Road" } },
    };
    const points = &.{ Point{ .x = -5, .y = 10 }, Point{ .x = 0, .y = 6 }, Point{ .x = 9, .y = 6 } };
    try layer.addLine(0, points, props, .none);
    try layer.addLine(1, points, props, .none);
    var tile: std.ArrayList(u8) = .empty;
    defer tile.deinit(a);
    try layer.write(&tile, .none);
    var layers = wire.Reader.init(tile.items);
    const entry = (try layers.next(Deadline.none)).?;
    try std.testing.expectEqual(3, entry.number);
    var fields = wire.Reader.init(entry.value.length_delimited);
    var feature_count: usize = 0;
    var key_count: usize = 0;
    var value_count: usize = 0;
    while (try fields.next(Deadline.none)) |f| switch (f.number) {
        2 => {
            feature_count += 1;
            var feature = wire.Reader.init(f.value.length_delimited);
            while (try feature.next(Deadline.none)) |item| switch (item.number) {
                2 => try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 1 }, item.value.length_delimited),
                4 => try std.testing.expectEqualSlices(u8, &.{ 9, 9, 20, 18, 10, 7, 18, 0 }, item.value.length_delimited),
                else => {},
            };
        },
        3 => key_count += 1,
        4 => value_count += 1,
        else => {},
    };
    try std.testing.expectEqual(2, feature_count);
    try std.testing.expectEqual(2, key_count);
    try std.testing.expectEqual(2, value_count);
}
