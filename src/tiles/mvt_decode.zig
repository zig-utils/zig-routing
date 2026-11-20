//! Checked Mapbox Vector Tile 2.1 decoding with borrowed dictionary strings.
const std = @import("std");
const wire = @import("protobuf").wire;
const mvt = @import("mvt.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;

pub const Error = mvt.Error || wire.Error || error{ InvalidValue, InvalidTags };

pub const Part = struct {
    points: []const mvt.Point,
    winding: ?mvt.Winding = null,
};

pub const Feature = struct {
    id: ?u64,
    kind: ?mvt.Kind,
    tags: []const u32,
    parts: []const Part,
};

pub const Layer = struct {
    name: []const u8,
    version: u32,
    extent: u32,
    keys: []const []const u8,
    values: []const mvt.Value,
    features: []const Feature,
};

pub const Tile = struct {
    arena: std.heap.ArenaAllocator,
    layers: []const Layer,

    pub fn deinit(self: *Tile) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Decode supported layers and keep text fields borrowed from bytes.
pub fn parse(gpa: Allocator, bytes: []const u8, deadline: Deadline) Error!Tile {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var layers: std.ArrayList(Layer) = .empty;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var input = wire.Reader.init(bytes);
    while (try input.next(deadline)) |field| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (field.number != 3) continue;
        const layer = (try parseLayer(a, try blob(field.value), deadline)) orelse continue;
        if ((try names.getOrPut(a, layer.name)).found_existing) return error.DuplicateLayer;
        try layers.append(a, layer);
    }
    return .{ .arena = arena, .layers = layers.items };
}

fn parseLayer(a: Allocator, bytes: []const u8, deadline: Deadline) Error!?Layer {
    var reader = wire.Reader.init(bytes);
    var version: ?u32 = null;
    var extent: ?u32 = null;
    var name: ?[]const u8 = null;
    while (try reader.next(deadline)) |field| {
        if (deadline.expired()) return error.DeadlineExceeded;
        switch (field.number) {
            1 => name = try text(field.value),
            5 => extent = try number(u32, field.value),
            15 => version = try number(u32, field.value),
            else => {},
        }
    }
    if ((version orelse return error.InvalidTile) != 2) return null;
    const grid = extent orelse return error.InvalidExtent;
    if (grid == 0) return error.InvalidExtent;
    const layer_name = name orelse return error.InvalidTile;

    var keys: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(mvt.Value) = .empty;
    var features: std.ArrayList(Feature) = .empty;
    reader = wire.Reader.init(bytes);
    while (try reader.next(deadline)) |field| {
        if (deadline.expired()) return error.DeadlineExceeded;
        switch (field.number) {
            2 => try features.append(a, try parseFeature(a, try blob(field.value), deadline)),
            3 => try keys.append(a, try text(field.value)),
            4 => try values.append(a, try parseValue(try blob(field.value), deadline)),
            else => {},
        }
    }
    for (features.items) |feature| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (feature.tags.len % 2 != 0) return error.InvalidTags;
        var i: usize = 0;
        while (i < feature.tags.len) : (i += 2) {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (feature.tags[i] >= keys.items.len or feature.tags[i + 1] >= values.items.len) return error.InvalidTags;
        }
    }
    return .{ .name = layer_name, .version = 2, .extent = grid, .keys = keys.items, .values = values.items, .features = features.items };
}

fn parseValue(bytes: []const u8, deadline: Deadline) Error!mvt.Value {
    var reader = wire.Reader.init(bytes);
    var value: ?mvt.Value = null;
    while (try reader.next(deadline)) |field| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const next: mvt.Value = switch (field.number) {
            1 => .{ .string = try text(field.value) },
            2 => .{ .float = @bitCast(if (field.value == .fixed32) field.value.fixed32 else return error.InvalidValue) },
            3 => .{ .double = @bitCast(if (field.value == .fixed64) field.value.fixed64 else return error.InvalidValue) },
            4 => .{ .signed = @bitCast(try number(u64, field.value)) },
            5 => .{ .unsigned = try number(u64, field.value) },
            6 => .{ .zigzag = wire.zigzagDecode(i64, try number(u64, field.value)) },
            7 => .{ .boolean = (try number(u64, field.value)) != 0 },
            else => continue,
        };
        if (value != null) return error.InvalidValue;
        value = next;
    }
    return value orelse error.InvalidValue;
}

fn parseFeature(a: Allocator, bytes: []const u8, deadline: Deadline) Error!Feature {
    var id: ?u64 = null;
    var kind: ?mvt.Kind = null;
    var tags: std.ArrayList(u32) = .empty;
    var geometry: std.ArrayList(u32) = .empty;
    defer geometry.deinit(a);
    var reader = wire.Reader.init(bytes);
    while (try reader.next(deadline)) |field| {
        if (deadline.expired()) return error.DeadlineExceeded;
        switch (field.number) {
            1 => id = try number(u64, field.value),
            2 => try repeated(a, &tags, field.value, deadline),
            3 => kind = switch (try number(u32, field.value)) {
                1 => .point,
                2 => .linestring,
                3 => .polygon,
                else => null,
            },
            4 => try repeated(a, &geometry, field.value, deadline),
            else => {},
        }
    }
    return .{
        .id = id,
        .kind = kind,
        .tags = tags.items,
        .parts = if (kind) |feature_kind| try paths(a, feature_kind, geometry.items, deadline) else &.{},
    };
}

fn repeated(a: Allocator, out: *std.ArrayList(u32), value: wire.Value, deadline: Deadline) Error!void {
    switch (value) {
        .varint => try out.append(a, try number(u32, value)),
        .length_delimited => |bytes| {
            var reader = wire.Reader.init(bytes);
            while (reader.remaining.len != 0) {
                if (out.items.len % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const word = std.math.cast(u32, try reader.readVarint()) orelse return error.InvalidTile;
                try out.append(a, word);
            }
        },
        else => return error.InvalidTile,
    }
}

const Commands = struct {
    words: []const u32,
    index: usize = 0,
    cursor: mvt.Point = .{ .x = 0, .y = 0 },

    fn read(self: *Commands, command: u3, min: u29, max: u29) Error!u29 {
        if (self.index == self.words.len) return error.InvalidGeometry;
        const word = self.words[self.index];
        self.index += 1;
        const count: u29 = @truncate(word >> 3);
        if (word & 7 != command or count < min or count > max) return error.InvalidGeometry;
        return count;
    }

    fn vertices(self: *Commands, points: []mvt.Point, line: bool, deadline: Deadline) Error!void {
        if (points.len > (self.words.len - self.index) / 2) return error.InvalidGeometry;
        for (points, 0..) |*point, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const dx = wire.zigzagDecode(i32, self.words[self.index]);
            const dy = wire.zigzagDecode(i32, self.words[self.index + 1]);
            self.index += 2;
            if ((line and dx == 0 and dy == 0) or dx == std.math.minInt(i32) or dy == std.math.minInt(i32))
                return error.InvalidGeometry;
            self.cursor.x = std.math.add(i32, self.cursor.x, dx) catch return error.InvalidGeometry;
            self.cursor.y = std.math.add(i32, self.cursor.y, dy) catch return error.InvalidGeometry;
            point.* = self.cursor;
        }
    }
};

fn paths(a: Allocator, kind: mvt.Kind, geometry: []const u32, deadline: Deadline) Error![]const Part {
    var commands: Commands = .{ .words = geometry };
    const max = std.math.maxInt(u29);
    if (kind == .point) {
        const count = try commands.read(1, 1, max);
        if (count != (geometry.len - commands.index) / 2 or (geometry.len - commands.index) % 2 != 0)
            return error.InvalidGeometry;
        const points = try a.alloc(mvt.Point, count);
        try commands.vertices(points, false, deadline);
        const part = try a.alloc(Part, 1);
        part[0] = .{ .points = points };
        return part;
    }
    var parts: std.ArrayList(Part) = .empty;
    const polygon = kind == .polygon;
    while (commands.index < geometry.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        _ = try commands.read(1, 1, 1);
        var start: [1]mvt.Point = undefined;
        try commands.vertices(&start, false, deadline);
        const count = try commands.read(2, if (polygon) 2 else 1, max);
        if (count > (geometry.len - commands.index) / 2) return error.InvalidGeometry;
        const points = try a.alloc(mvt.Point, @as(usize, count) + 1);
        points[0] = start[0];
        try commands.vertices(points[1..], true, deadline);
        var winding: ?mvt.Winding = null;
        if (polygon) {
            _ = try commands.read(7, 1, 1);
            const last = points[points.len - 1];
            if (last.x == points[0].x and last.y == points[0].y) return error.InvalidGeometry;
            const area = try mvt.signedArea(points, deadline);
            if (area == 0 or (parts.items.len == 0 and area < 0)) return error.InvalidGeometry;
            winding = if (area > 0) .exterior else .interior;
        }
        try parts.append(a, .{ .points = points, .winding = winding });
    }
    if (parts.items.len == 0) return error.InvalidGeometry;
    return parts.items;
}

fn blob(value: wire.Value) Error![]const u8 {
    return if (value == .length_delimited) value.length_delimited else error.InvalidTile;
}

fn text(value: wire.Value) Error![]const u8 {
    const bytes = try blob(value);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return bytes;
}

fn number(comptime T: type, value: wire.Value) Error!T {
    if (value != .varint) return error.InvalidTile;
    return std.math.cast(T, value.varint) orelse error.InvalidTile;
}
