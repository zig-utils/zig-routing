// Native shared snapping grid. Replaces the per-tile bins from
// src/mjolnir/graphvalidator.cc (Valhalla 3.9.3).
const std = @import("std");
const wire = @import("protobuf").wire;
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const geo = @import("../geo/point.zig");
const grid = @import("../geo/grid.zig");
const constants = @import("../geo/constants.zig");
const math = @import("../geo/libm.zig");
const format = @import("format.zig");
const Allocator = std.mem.Allocator;

pub const Header = extern struct {
    cell_count: u32,
    reserved: u32 = 0,
};

pub const Entry = extern struct {
    id: u32,
    offset: u32,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 8 and @offsetOf(Header, "cell_count") == 0 and @offsetOf(Header, "reserved") == 4);
    std.debug.assert(@sizeOf(Entry) == 8 and @offsetOf(Entry, "id") == 0 and @offsetOf(Entry, "offset") == 4);
}

pub const cell_count = grid.snap_columns * grid.snap_rows;
const cell_width: f64 = 1.0 / @as(f64, grid.snap_cells_per_degree);

pub const Cell = struct {
    id: u32,
    encoded: []const u8,
    edge_count: u32,

    /// IDs are the lower CSR arc index in each opposing pair.
    pub fn edges(self: Cell) Edges {
        return .{ .reader = .init(self.encoded), .limit = self.edge_count };
    }
};

pub const Edges = struct {
    reader: wire.Reader,
    previous: ?u32 = null,
    limit: u32,

    pub fn next(self: *Edges) !?format.EdgeId {
        if (self.reader.remaining.len == 0) return null;
        const value = try self.reader.readVarint();
        if (self.previous != null and value == 0) return error.UnsortedSpatialEdges;
        const id = std.math.add(u64, self.previous orelse 0, value) catch return error.InvalidSpatialEdge;
        if (id >= self.limit) return error.InvalidSpatialEdge;
        self.previous = @intCast(id);
        return @fromBackingInt(@as(u32, @intCast(id)));
    }
};

pub const View = struct {
    directory: []const Entry,
    lists: []const u8,
    edge_count: u32,

    pub fn parse(bytes: []const u8, edges: u32) !View {
        if (bytes.len < @sizeOf(Header)) return error.TruncatedSpatialHeader;
        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (header.reserved != 0 or header.cell_count > cell_count) return error.InvalidSpatialHeader;
        if (header.cell_count > (bytes.len - @sizeOf(Header)) / @sizeOf(Entry)) return error.TruncatedSpatialDirectory;
        const size = @sizeOf(Header) + @as(usize, header.cell_count) * @sizeOf(Entry);
        const directory = try io.typedSlice(Entry, bytes, @sizeOf(Header), header.cell_count);
        const lists = bytes[size..];
        if (lists.len > std.math.maxInt(u32)) return error.SpatialListsTooLarge;
        if (directory.len != 0) {
            if (directory[0].offset != 0 or directory[directory.len - 1].id >= cell_count or
                directory[directory.len - 1].offset >= lists.len) return error.InvalidSpatialDirectory;
        } else if (lists.len != 0) return error.InvalidSpatialDirectory;
        return .{ .directory = directory, .lists = lists, .edge_count = edges };
    }

    fn lowerBound(self: View, id: u32) usize {
        var left: usize = 0;
        var right = self.directory.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.directory[mid].id < id) left = mid + 1 else right = mid;
        }
        return left;
    }

    pub fn lookup(self: View, id: u32) !?Cell {
        if (id >= cell_count) return error.InvalidSpatialCell;
        const i = self.lowerBound(id);
        if (i == self.directory.len or self.directory[i].id != id) return null;
        return try self.at(i);
    }

    pub fn at(self: View, i: usize) !Cell {
        if (i >= self.directory.len) return error.InvalidSpatialCell;
        const entry = self.directory[i];
        const end = if (i + 1 == self.directory.len) self.lists.len else self.directory[i + 1].offset;
        if (entry.id >= cell_count or entry.offset >= end or end > self.lists.len) return error.InvalidSpatialDirectory;
        return .{ .id = entry.id, .encoded = self.lists[entry.offset..end], .edge_count = self.edge_count };
    }

    pub fn rings(self: View, arena: Allocator, point: geo.PointLL, radius_m: f64, deadline: io.Deadline) !Rings {
        return self.scan(arena, point, radius_m, null, deadline);
    }

    /// Range traversal in the same metric as Loki's projection ranking.
    pub fn projectionRings(self: View, arena: Allocator, approx: geo.DistanceApproximator, radius_m: f64, deadline: io.Deadline) !Rings {
        return self.scan(arena, .{ .lng = approx.center_lng, .lat = approx.center_lat }, radius_m, approx, deadline);
    }

    fn scan(self: View, arena: Allocator, point: geo.PointLL, radius_m: f64, approx: ?geo.DistanceApproximator, deadline: io.Deadline) !Rings {
        if (!point.inRange()) return error.InvalidCoordinate;
        if (!std.math.isFinite(radius_m) or radius_m < 0) return error.InvalidRadius;
        if (deadline.expired()) return error.DeadlineExceeded;
        var result: Rings = .{ .arena = arena, .queue = .initContext({}) };
        errdefer result.deinit();
        const bounds = if (approx) |plane|
            ScanBounds.fromSpans(point, radius_m / constants.meters_per_degree_lat, @min(180, radius_m / @abs(plane.m_per_lng_degree)))
        else
            ScanBounds.spherical(point, radius_m);
        for (bounds.south..bounds.north + 1) |row| {
            if (deadline.expired()) return error.DeadlineExceeded;
            for (bounds.longitude[0..bounds.range_count]) |range| {
                const start: u32 = @intCast(row * grid.snap_columns + range.first);
                const end: u32 = @intCast(row * grid.snap_columns + range.end);
                var i = self.lowerBound(start);
                while (i < self.directory.len and self.directory[i].id < end) : (i += 1) {
                    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                    const id = self.directory[i].id;
                    const d = if (approx) |plane| planeDistanceToCell(plane, id) else distanceToCell(point, id);
                    if (d <= radius_m) try result.queue.push(arena, .{ .distance = d, .cell = try self.at(i) });
                }
            }
        }
        return result;
    }

    pub fn cellsAlong(self: View, arena: Allocator, a: geo.PointLL, b: geo.PointLL, deadline: io.Deadline) ![]Cell {
        const Sink = struct {
            view: View,
            arena: Allocator,
            seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
            cells: std.ArrayList(Cell) = .empty,

            pub fn emit(self_sink: *@This(), id: u32) !void {
                const cell = (try self_sink.view.lookup(id)) orelse return;
                const seen = try self_sink.seen.getOrPut(self_sink.arena, id);
                if (!seen.found_existing) try self_sink.cells.append(self_sink.arena, cell);
            }
        };
        var sink: Sink = .{ .view = self, .arena = arena };
        defer sink.seen.deinit(arena);
        errdefer sink.cells.deinit(arena);
        try grid.visitSnapSegment(a, b, &sink, deadline);
        return sink.cells.toOwnedSlice(arena);
    }

    /// Visit only populated cells that can touch a non-wrapping rectangle.
    pub fn cellsInBox(self: View, west: geo.PointLL, east: geo.PointLL) BoxCells {
        const first = grid.snapCell(west);
        const last = grid.snapCell(east);
        const first_column = (first % grid.snap_columns) -| 1;
        const end_column = @min(last % grid.snap_columns + 2, grid.snap_columns);
        const row = (first / grid.snap_columns) -| 1;
        return .{
            .view = self,
            .first_column = first_column,
            .end_column = end_column,
            .row = row,
            .last_row = @min(last / grid.snap_columns + 1, grid.snap_rows - 1),
            .index = self.lowerBound(row * grid.snap_columns + first_column),
        };
    }
};

pub const BoxCells = struct {
    view: View,
    first_column: u32,
    end_column: u32,
    row: u32,
    last_row: u32,
    index: usize,

    pub fn next(self: *BoxCells, deadline: io.Deadline) !?Cell {
        while (self.index < self.view.directory.len and self.row <= self.last_row) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const id = self.view.directory[self.index].id;
            if (id < self.row * grid.snap_columns + self.end_column) {
                const index = self.index;
                self.index += 1;
                return try self.view.at(index);
            }
            self.row = @max(self.row + 1, id / grid.snap_columns);
            self.index = self.view.lowerBound(self.row * grid.snap_columns + self.first_column);
        }
        return null;
    }
};

pub const Hit = struct {
    distance: f64,
    cell: Cell,

    fn order(_: void, a: Hit, b: Hit) std.math.Order {
        if (a.distance == b.distance) return std.math.order(a.cell.id, b.cell.id);
        return std.math.order(a.distance, b.distance);
    }
};

pub const Rings = struct {
    arena: Allocator,
    queue: std.PriorityQueue(Hit, void, Hit.order),

    pub fn deinit(self: *Rings) void {
        self.queue.deinit(self.arena);
    }

    pub fn next(self: *Rings) ?Hit {
        return self.queue.pop();
    }
};

const ScanBounds = struct {
    south: u32,
    north: u32,
    longitude: [2]struct { first: u32, end: u32 },
    range_count: usize,

    fn spherical(point: geo.PointLL, radius_m: f64) ScanBounds {
        const span = sphereSpans(point, radius_m);
        return fromSpans(point, span.lat, span.lng);
    }

    fn fromSpans(point: geo.PointLL, lat_span: f64, lon_span: f64) ScanBounds {
        const south = (point.lat - lat_span + 90) * grid.snap_cells_per_degree;
        const north = (point.lat + lat_span + 90) * grid.snap_cells_per_degree;
        var bounds: ScanBounds = .{
            .south = @intFromFloat(std.math.clamp(@floor(south) - 1, 0, grid.snap_rows - 1)),
            .north = @intFromFloat(std.math.clamp(@floor(north) + 1, 0, grid.snap_rows - 1)),
            .longitude = .{ .{ .first = 0, .end = grid.snap_columns }, undefined },
            .range_count = 1,
        };
        if (lon_span >= 180) return bounds;
        const x = (point.lng + 180) * grid.snap_cells_per_degree;
        const extent = lon_span * grid.snap_cells_per_degree;
        const lo: i32 = @intFromFloat(@floor(x - extent) - 1);
        const hi: i32 = @intFromFloat(@floor(x + extent) + 2);
        if (hi - lo >= grid.snap_columns) return bounds;
        const west: u32 = @intCast(@mod(lo, grid.snap_columns));
        const count: u32 = @intCast(hi - lo);
        const end = west + count;
        bounds.longitude[0] = .{ .first = west, .end = @min(end, grid.snap_columns) };
        if (end > grid.snap_columns) {
            bounds.longitude[1] = .{ .first = 0, .end = end - grid.snap_columns };
            bounds.range_count = 2;
        }
        return bounds;
    }
};

fn sphereSpans(point: geo.PointLL, radius_m: f64) geo.PointLL {
    const angle = @min(std.math.pi, radius_m / constants.rad_earth_meters_d);
    const latitude = point.lat * constants.rad_per_deg_d;
    return .{
        .lat = angle * constants.deg_per_rad_d,
        .lng = if (angle >= std.math.pi / 2.0 - @abs(latitude)) 180 else math.asinF(@min(1, math.sinF(angle) / math.cosF(latitude))) * constants.deg_per_rad_d,
    };
}

/// Upper bound in the ranking metric for any point within a great-circle cutoff.
pub fn projectionLimit(point: geo.PointLL, approx: geo.DistanceApproximator, cutoff: f64) f64 {
    const span = sphereSpans(point, cutoff);
    const lat_m = span.lat * constants.meters_per_degree_lat;
    const lon_m = span.lng * approx.m_per_lng_degree;
    return @sqrt(lat_m * lat_m + lon_m * lon_m);
}

fn planeDistanceToCell(approx: geo.DistanceApproximator, id: u32) f64 {
    const west = @as(f64, @floatFromInt(id % grid.snap_columns)) * cell_width - 180;
    const south = @as(f64, @floatFromInt(id / grid.snap_columns)) * cell_width - 90;
    const center = west + cell_width * 0.5;
    const longitude = approx.center_lng + geo.wrappedLongitudeDelta(center, approx.center_lng);
    return @sqrt(approx.distanceSquared(.{
        .lng = std.math.clamp(approx.center_lng, longitude - cell_width * 0.5, longitude + cell_width * 0.5),
        .lat = std.math.clamp(approx.center_lat, south, south + cell_width),
    }));
}

/// Distance to the closed spherical rectangle, in metres.
fn distanceToCell(point: geo.PointLL, id: u32) f64 {
    const col = id % grid.snap_columns;
    const row = id / grid.snap_columns;
    const west = @as(f64, @floatFromInt(col)) * cell_width - 180;
    const south = @as(f64, @floatFromInt(row)) * cell_width - 90;
    const east = west + cell_width;
    const north = south + cell_width;
    if ((point.lat == -90 and south == -90) or (point.lat == 90 and north == 90)) return 0;
    const center = west + cell_width * 0.5;
    const longitude = center + @mod(point.lng - center + 180, 360) - 180;
    const lng = std.math.clamp(longitude, west, east);
    if (lng == longitude and point.lat >= south and point.lat <= north) return 0;
    const origin: geo.PointLL = .{ .lng = longitude, .lat = point.lat };
    const latitude = point.lat * constants.rad_per_deg_d;
    const delta = (longitude - lng) * constants.rad_per_deg_d;
    // Maximize the dot product on the closest meridian. When the stationary
    // latitude is outside the cell, compare the endpoints on that meridian.
    const opt = math.atan2F(math.sinF(latitude), math.cosF(latitude) * math.cosF(delta)) * constants.deg_per_rad_d;
    if (opt >= south and opt <= north) return origin.distance(.{ .lng = lng, .lat = opt });
    return @min(origin.distance(.{ .lng = lng, .lat = south }), origin.distance(.{ .lng = lng, .lat = north }));
}

/// Sort order is cell ID, then the representative directed edge ID.
pub const Pair = u64;

pub fn addShape(gpa: Allocator, output: *std.ArrayList(Pair), representative: u32, points: []const geo.FixedLL, deadline: io.Deadline) !void {
    if (points.len < 2) return error.InvalidSegmentShape;
    const Sink = struct {
        gpa: Allocator,
        output: *std.ArrayList(Pair),
        edge: u32,
        last: ?u32 = null,

        pub fn emit(self: *@This(), id: u32) !void {
            if (self.last == id) return;
            self.last = id;
            try self.output.append(self.gpa, (@as(u64, id) << 32) | self.edge);
        }
    };
    var sink: Sink = .{ .gpa = gpa, .output = output, .edge = representative };
    var a = points[0].toPoint();
    for (points[1..]) |point| {
        const b = point.toPoint();
        try grid.visitSnapSegment(a, b, &sink, deadline);
        a = b;
    }
}

pub const Stats = struct {
    cells: u32,
    payload_bytes: u64,
};

pub fn write(gpa: Allocator, pairs: []Pair, scratch: []Pair, dir: []const u8, bundle: *format.BundleWriter, deadline: io.Deadline) !Stats {
    if (pairs.len != scratch.len) return error.InvalidSpatialScratch;
    try radix.sortByU64(Pair, gpa, pairs, scratch, {}, pairKey, deadline);
    const file = try io.File.temporary(dir);
    defer file.close();
    var directory: std.ArrayList(Entry) = .empty;
    defer directory.deinit(gpa);
    var buffer: [64 * 1024]u8 = undefined;
    var bytes: std.Io.Writer = .fixed(&buffer);
    var offset: u64 = 0;
    var previous: ?Pair = null;
    for (pairs, 0..) |pair, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (previous == pair) continue;
        if (bytes.end + 5 > buffer.len) {
            try file.pwriteAll(bytes.buffered(), offset);
            offset += bytes.end;
            bytes.end = 0;
        }
        const id: u32 = @intCast(pair >> 32);
        const edge: u32 = @truncate(pair);
        const same_cell = if (previous) |prev| (prev >> 32) == id else false;
        if (!same_cell) {
            if (id >= cell_count) return error.InvalidSpatialCell;
            const start = std.math.cast(u32, offset + bytes.end) orelse return error.SpatialListsTooLarge;
            try directory.append(gpa, .{ .id = id, .offset = start });
        }
        const delta = edge - if (same_cell) @as(u32, @truncate(previous.?)) else 0;
        try wire.writeVarint(&bytes, delta);
        previous = pair;
    }
    const length = offset + bytes.end;
    if (length > std.math.maxInt(u32)) return error.SpatialListsTooLarge;
    try file.pwriteAll(bytes.buffered(), offset);
    try bundle.stream(.spatial, Payload{ .file = file, .length = length, .directory = directory.items }, Payload.emit);
    return .{
        .cells = @intCast(directory.items.len),
        .payload_bytes = @sizeOf(Header) + directory.items.len * @sizeOf(Entry) + length,
    };
}

const Payload = struct {
    file: io.File,
    length: u64,
    directory: []const Entry,

    fn emit(self: Payload, out: *format.SectionWriter(.spatial)) !void {
        const header: Header = .{ .cell_count = @intCast(self.directory.len) };
        try out.append(std.mem.asBytes(&header));
        try out.append(std.mem.sliceAsBytes(self.directory));
        var buf: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < self.length) {
            if (out.deadline().expired()) return error.DeadlineExceeded;
            const bytes = buf[0..@min(buf.len, self.length - offset)];
            try self.file.preadAll(bytes, offset);
            try out.append(bytes);
            offset += bytes.len;
        }
    }
};

fn pairKey(_: void, pair: Pair) u64 {
    return pair;
}

test "zero-radius rings contain both sides of the seam and all occupied polar cells" {
    const testing = std.testing;
    const equator: u32 = (grid.snap_rows / 2) * grid.snap_columns;
    const polar: u32 = (grid.snap_rows - 1) * grid.snap_columns;
    const directory = [_]Entry{
        .{ .id = equator, .offset = 0 },
        .{ .id = equator + grid.snap_columns - 1, .offset = 1 },
        .{ .id = polar, .offset = 2 },
        .{ .id = polar + grid.snap_columns - 1, .offset = 3 },
    };
    const index: View = .{ .directory = &directory, .lists = &.{ 0, 0, 0, 0 }, .edge_count = 2 };
    for ([_]geo.PointLL{ .init(180, 0), .init(10, 90) }, [_]u32{ equator, polar }) |point, first| {
        var rings = try index.rings(testing.allocator, point, 0, .none);
        defer rings.deinit();
        const near = rings.next().?;
        const far = rings.next().?;
        try testing.expectEqual(0, near.distance);
        try testing.expectEqual(0, far.distance);
        try testing.expectEqual(first, near.cell.id);
        try testing.expectEqual(first + grid.snap_columns - 1, far.cell.id);
        try testing.expectEqual(null, rings.next());
    }
}
