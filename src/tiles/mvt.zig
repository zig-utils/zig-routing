//! Mapbox Vector Tile 2.1 wire encoding.
const std = @import("std");
const wire = @import("protobuf").wire;
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;
const Error = Allocator.Error || error{ DeadlineExceeded, InvalidGeometry };

pub const extent = 4096;
pub const Point = struct { x: i32, y: i32 };
pub const Value = union(enum) {
    string: []const u8,
    float: f32,
    double: f64,
    signed: i64,
    unsigned: u64,
    boolean: bool,
};
pub const Property = struct { key: []const u8, value: Value };

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

    pub fn deinit(self: *Layer) void {
        self.keys.deinit(self.contents.a);
        self.values.deinit(self.contents.a);
        self.contents.deinit();
        self.feature.deinit();
        self.tags.deinit();
        self.geometry.deinit();
        self.scratch.deinit();
    }

    pub fn addPoint(self: *Layer, id: u64, point: Point, properties: []const Property, deadline: Deadline) Error!void {
        try self.add(id, .point, &.{point}, properties, deadline);
    }

    pub fn addLine(self: *Layer, id: u64, points: []const Point, properties: []const Property, deadline: Deadline) Error!void {
        if (points.len < 2 or points.len > (1 << 29)) return error.InvalidGeometry;
        try self.add(id, .linestring, points, properties, deadline);
    }

    const Kind = enum(u2) { point = 1, linestring = 2 };

    fn add(self: *Layer, id: u64, kind: Kind, points: []const Point, properties: []const Property, deadline: Deadline) Error!void {
        self.tags.reset();
        for (properties, 0..) |prop, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const key = try self.keys.getOrPut(self.contents.a, prop.key);
            const value = try self.values.getOrPut(self.contents.a, prop.value);
            try wire.writeVarint(&self.tags, key.index);
            try wire.writeVarint(&self.tags, value.index);
        }
        self.geometry.reset();
        try wire.writeVarint(&self.geometry, 9); // MoveTo(1)
        try delta(&self.geometry, .{ .x = 0, .y = 0 }, points[0]);
        if (kind == .linestring) {
            try wire.writeVarint(&self.geometry, ((points.len - 1) << 3) | 2); // LineTo
            for (points[0 .. points.len - 1], points[1..], 0..) |start, end, i| {
                if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (start.x == end.x and start.y == end.y) return error.InvalidGeometry;
                try delta(&self.geometry, start, end);
            }
        }
        self.feature.reset();
        try self.feature.number(1, id);
        if (self.tags.data.items.len != 0) try self.feature.blob(2, self.tags.data.items);
        try self.feature.number(3, @backingInt(kind));
        try self.feature.blob(4, self.geometry.data.items);
        try self.contents.blob(2, self.feature.data.items);
    }

    /// Appends the layer to a tile; empty layers are omitted.
    pub fn write(self: *Layer, tile: *std.ArrayList(u8), deadline: Deadline) Error!void {
        if (self.contents.data.items.len == 0) return;
        var header: Bytes = .{ .a = self.contents.a };
        defer header.deinit();
        try header.number(15, 2);
        try header.blob(1, self.name);
        const geometry_len = self.contents.data.items.len;
        defer self.contents.data.shrinkRetainingCapacity(geometry_len);
        for (self.keys.keys(), 0..) |key, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            try self.contents.blob(3, key);
        }
        for (self.values.keys(), 0..) |value, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            self.scratch.reset();
            switch (value) {
                .string => |s| try self.scratch.blob(1, s),
                .float => |f| try self.scratch.fixed(u32, 2, @bitCast(f)),
                .double => |d| try self.scratch.fixed(u64, 3, @bitCast(d)),
                .signed => |n| try self.scratch.number(4, @bitCast(n)),
                .unsigned => |n| try self.scratch.number(5, n),
                .boolean => |b| try self.scratch.number(7, @intFromBool(b)),
            }
            try self.contents.blob(4, self.scratch.data.items);
        }
        try self.contents.number(5, extent);
        var output: Bytes = .{ .a = self.contents.a, .data = tile.* };
        defer tile.* = output.data;
        try wire.writeVarint(&output, wire.tagValue(3, .length_delimited));
        try wire.writeVarint(&output, header.data.items.len + self.contents.data.items.len);
        try output.writeAll(header.data.items);
        try output.writeAll(self.contents.data.items);
    }
};

fn delta(bytes: *Bytes, from: Point, to: Point) Error!void {
    const x = std.math.sub(i32, to.x, from.x) catch return error.InvalidGeometry;
    const y = std.math.sub(i32, to.y, from.y) catch return error.InvalidGeometry;
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
