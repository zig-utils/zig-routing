// Ported from src/mjolnir/admin.cc and src/mjolnir/graphbuilder.cc
// (Valhalla 3.9.3). The native builder reads GeoJSON boundary data directly.
const std = @import("std");
const io = @import("../infra/io.zig");
const graph = @import("../graph/root.zig");
const timezone = graph.timezone;
const grid = @import("../graph/polygon_grid.zig");
const polygon_grid = @import("polygon_grid.zig");
const enhance = @import("enhance.zig");
const Polygon = @import("../geo/polygon.zig").Polygon;
const Ring = @import("../geo/polygon.zig").Ring;
const PointLL = @import("../geo/point.zig").PointLL;
const AABB = @import("../geo/aabb.zig").AABB;
const Allocator = std.mem.Allocator;

pub const Source = struct {
    boundaries: []const u8,
    rules: []const u8,
};

pub const Index = struct {
    storage: std.heap.ArenaAllocator,
    view: grid.View,

    pub fn deinit(self: *Index) void {
        self.storage.deinit();
    }
};

/// Only clip to cells intersecting the routing graph's buffered local tiles.
pub fn build(a: Allocator, bytes: []const u8, rules: timezone.Rules, points: []const graph.format.Coordinate, deadline: io.Deadline) !Index {
    var coverage: polygon_grid.Coverage = .empty;
    var previous: ?u32 = null;
    for (points, 0..) |point, i| {
        try checkAt(deadline, i);
        const tile = enhance.tileId(point);
        if (tile == previous) continue;
        previous = tile;
        var cells = Cells.init(tileBounds(tile));
        while (cells.next()) |cell| coverage.set(cell);
    }

    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();
    var builder = try polygon_grid.Builder.init(temp, &coverage, deadline);
    var json = Json.init(temp, bytes, deadline);
    defer json.scanner.deinit();
    try json.document(&builder, rules);

    var storage: std.heap.ArenaAllocator = .init(a);
    errdefer storage.deinit();
    const view = try builder.encode(storage.allocator());
    return .{ .storage = storage, .view = view };
}

/// Valhalla assigns a tile's sole zone to all local nodes. Where the
/// buffered tile intersects several zones it takes the lowest covering ID.
pub fn assign(index: grid.View, points: []const graph.format.Coordinate, output: []timezone.Id, deadline: io.Deadline) !void {
    if (points.len != output.len) return error.InvalidTimezoneOutputLength;
    var previous: ?u32 = null;
    var sole: timezone.Id = timezone.unknown;
    for (points, output, 0..) |point, *id, i| {
        try checkAt(deadline, i);
        const tile = enhance.tileId(point);
        if (tile != previous) {
            sole = try singleZone(index, tileBounds(tile), deadline);
            previous = tile;
        }
        id.* = if (sole != timezone.unknown) sole else try zoneAt(index, point.toPoint(), deadline);
    }
}

fn tileBounds(tile: u32) AABB {
    const box = enhance.tileBounds(tile);
    const buffer = 1e-3;
    return .init(@max(-180, box.minx - buffer), @max(-90, box.miny - buffer), @min(180, box.maxx + buffer), @min(90, box.maxy + buffer));
}

fn singleZone(index: grid.View, bounds: AABB, deadline: io.Deadline) !timezone.Id {
    var found: timezone.Id = timezone.unknown;
    var cells = Cells.init(bounds);
    while (cells.next()) |cell| {
        for (try index.cellPieces(cell), 0..) |piece, i| {
            try checkAt(deadline, i);
            if (piece.attr.region == found) continue;
            if (!try index.intersectsBox(piece, bounds, deadline)) continue;
            if (found != timezone.unknown) return timezone.unknown;
            found = piece.attr.region;
        }
    }
    return found;
}

fn zoneAt(index: grid.View, point: PointLL, deadline: io.Deadline) !timezone.Id {
    const box = grid.cellBox(grid.cellId(point));
    // Look into both cells when a clipped piece touches the point.
    const west = if (point.lng == box.minx and point.lng > -180) point.lng - 1 else point.lng;
    const south = if (point.lat == box.miny and point.lat > -90) point.lat - 1 else point.lat;
    var cells = Cells.init(.init(west, south, point.lng, point.lat));
    var found: timezone.Id = timezone.unknown;
    while (cells.next()) |cell| {
        for (try index.cellPieces(cell), 0..) |piece, i| {
            try checkAt(deadline, i);
            const id = piece.attr.region;
            if ((found == timezone.unknown or id < found) and try index.locate(piece, point, deadline) != .outside)
                found = id;
        }
    }
    return found;
}

const Cells = struct {
    first_col: u32,
    last_col: u32,
    last_row: u32,
    cell: u32,

    fn init(bounds: AABB) Cells {
        const low = grid.cellId(bounds.minpt());
        const high = grid.cellId(bounds.maxpt());
        return .{
            .first_col = low % grid.columns,
            .last_col = high % grid.columns,
            .last_row = high / grid.columns,
            .cell = low,
        };
    }

    fn next(self: *Cells) ?u32 {
        const cell = self.cell;
        if (cell / grid.columns > self.last_row) return null;
        self.cell = if (cell % grid.columns == self.last_col)
            (cell / grid.columns + 1) * grid.columns + self.first_col
        else
            cell + 1;
        return cell;
    }
};

const Json = struct {
    a: Allocator,
    bytes: []const u8,
    scanner: std.json.Scanner,
    deadline: io.Deadline,
    tokens: usize = 0,

    fn init(a: Allocator, bytes: []const u8, deadline: io.Deadline) Json {
        return .{ .a = a, .bytes = bytes, .scanner = .initCompleteInput(a, bytes), .deadline = deadline };
    }

    fn next(self: *Json) !std.json.Token {
        try checkAt(self.deadline, self.tokens);
        self.tokens += 1;
        return self.scanner.nextAllocMax(self.a, .alloc_if_needed, 1024);
    }

    fn expect(self: *Json, kind: std.meta.Tag(std.json.Token)) !void {
        if (try self.next() != kind) return error.InvalidTimezoneGeoJson;
    }

    fn field(self: *Json) !?[]const u8 {
        return switch (try self.next()) {
            .object_end => null,
            .string, .allocated_string => |value| value,
            else => error.InvalidTimezoneGeoJson,
        };
    }

    fn string(self: *Json) ![]const u8 {
        return switch (try self.next()) {
            .string, .allocated_string => |value| value,
            else => error.InvalidTimezoneGeoJson,
        };
    }

    fn skip(self: *Json, token: std.json.Token) !void {
        var depth: usize = switch (token) {
            .array_begin, .object_begin => 1,
            .string, .allocated_string, .number, .allocated_number, .null, .true, .false => 0,
            else => return error.InvalidTimezoneGeoJson,
        };
        while (depth != 0) {
            switch (try self.next()) {
                .array_begin, .object_begin => depth += 1,
                .array_end, .object_end => depth -= 1,
                .end_of_document => return error.InvalidTimezoneGeoJson,
                else => {},
            }
            if (depth > 64) return error.InvalidTimezoneGeoJson;
        }
    }

    fn document(self: *Json, builder: *polygon_grid.Builder, rules: timezone.Rules) !void {
        try self.expect(.object_begin);
        var collection = false;
        var features = false;
        while (try self.field()) |key| {
            if (std.mem.eql(u8, key, "type")) {
                if (collection or !std.mem.eql(u8, try self.string(), "FeatureCollection"))
                    return error.InvalidTimezoneGeoJson;
                collection = true;
            } else if (std.mem.eql(u8, key, "features")) {
                if (features) return error.InvalidTimezoneGeoJson;
                features = true;
                try self.expect(.array_begin);
                while (true) {
                    const token = try self.next();
                    if (token == .array_end) break;
                    if (token != .object_begin) return error.InvalidTimezoneGeoJson;
                    try self.feature(builder, rules);
                }
            } else try self.skip(try self.next());
        }
        if (!collection or !features) return error.InvalidTimezoneGeoJson;
        try self.expect(.end_of_document);
    }

    fn feature(self: *Json, builder: *polygon_grid.Builder, rules: timezone.Rules) !void {
        var id: timezone.Id = timezone.unknown;
        var shape: ?Shape = null;
        var feature_type = false;
        while (try self.field()) |key| {
            if (std.mem.eql(u8, key, "type")) {
                if (feature_type or !std.mem.eql(u8, try self.string(), "Feature")) return error.InvalidTimezoneGeoJson;
                feature_type = true;
            } else if (std.mem.eql(u8, key, "properties")) {
                if (id != timezone.unknown) return error.InvalidTimezoneGeoJson;
                try self.expect(.object_begin);
                while (try self.field()) |item| {
                    if (std.mem.eql(u8, item, "tzid")) {
                        if (id != timezone.unknown) return error.InvalidTimezoneGeoJson;
                        id = try rules.id(try self.string());
                        if (id == timezone.unknown) return error.UnknownTimezone;
                    } else try self.skip(try self.next());
                }
            } else if (std.mem.eql(u8, key, "geometry")) {
                if (shape != null) return error.InvalidTimezoneGeoJson;
                shape = try self.geometry();
            } else try self.skip(try self.next());
        }
        const present = shape orelse return error.InvalidTimezoneGeoJson;
        if (!feature_type or id == timezone.unknown) return error.InvalidTimezoneGeoJson;
        var coordinates = Json.init(self.a, present.coordinates, self.deadline);
        defer coordinates.scanner.deinit();
        try coordinates.expect(.array_begin);
        if (present.multi) {
            while (true) {
                const token = try coordinates.next();
                if (token == .array_end) break;
                if (token != .array_begin) return error.InvalidTimezoneGeoJson;
                try builder.add(id, try coordinates.polygon());
            }
        } else try builder.add(id, try coordinates.polygon());
        try coordinates.expect(.end_of_document);
    }

    const Shape = struct { multi: bool, coordinates: []const u8 };

    fn geometry(self: *Json) !Shape {
        try self.expect(.object_begin);
        var multi: ?bool = null;
        var coordinates: ?[]const u8 = null;
        while (try self.field()) |key| {
            if (std.mem.eql(u8, key, "type")) {
                if (multi != null) return error.InvalidTimezoneGeoJson;
                const kind = try self.string();
                multi = if (std.mem.eql(u8, kind, "MultiPolygon")) true else if (std.mem.eql(u8, kind, "Polygon")) false else return error.InvalidTimezoneGeoJson;
            } else if (std.mem.eql(u8, key, "coordinates")) {
                if (coordinates != null) return error.InvalidTimezoneGeoJson;
                try self.expect(.array_begin);
                const begin = self.scanner.cursor - 1;
                try self.skip(.array_begin);
                coordinates = self.bytes[begin..self.scanner.cursor];
            } else try self.skip(try self.next());
        }
        return .{ .multi = multi orelse return error.InvalidTimezoneGeoJson, .coordinates = coordinates orelse return error.InvalidTimezoneGeoJson };
    }

    fn polygon(self: *Json) !Polygon {
        try self.expect(.array_begin);
        const outer = try self.ring();
        var holes: std.ArrayList(Ring) = .empty;
        while (true) {
            const token = try self.next();
            if (token == .array_end) break;
            if (token != .array_begin) return error.InvalidTimezoneGeoJson;
            try holes.append(self.a, try self.ring());
        }
        return .{ .outer = outer, .holes = holes.items };
    }

    fn ring(self: *Json) !Ring {
        var points: std.ArrayList(PointLL) = .empty;
        while (true) {
            const token = try self.next();
            if (token == .array_end) break;
            if (token != .array_begin) return error.InvalidTimezoneGeoJson;
            const lon = try number(try self.next());
            const lat = try number(try self.next());
            const point: PointLL = .init(lon, lat);
            if (!point.inRange()) return error.InvalidTimezoneGeoJson;
            const tail = try self.next();
            if (tail != .array_end) {
                _ = try number(tail);
                try self.expect(.array_end);
            }
            try points.append(self.a, point);
        }
        if (points.items.len < 4 or !std.meta.eql(points.items[0], points.items[points.items.len - 1]))
            return error.InvalidTimezoneGeoJson;
        return points.items[0 .. points.items.len - 1];
    }
};

fn number(token: std.json.Token) !f64 {
    const text = switch (token) {
        .number, .allocated_number => |value| value,
        else => return error.InvalidTimezoneGeoJson,
    };
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidTimezoneGeoJson;
    if (!std.math.isFinite(value)) return error.InvalidTimezoneGeoJson;
    return value;
}

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}
