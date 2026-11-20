//! Common storage and point queries for clipped polygons in a sparse grid.

const std = @import("std");
const io = @import("../infra/io.zig");
const polygon = @import("../geo/polygon.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const AABB = @import("../geo/aabb.zig").AABB;

pub const Id = u16;
pub const columns = 180;
pub const rows = 90;
const cell_width = 2;

pub const Span = extern struct {
    first: u32,
    count: u32,

    pub fn init(first: usize, count: usize) error{PolygonIndexTooLarge}!Span {
        if (first > std.math.maxInt(u32) or count > std.math.maxInt(u32) - first)
            return error.PolygonIndexTooLarge;
        return .{ .first = @intCast(first), .count = @intCast(count) };
    }

    pub fn get(self: Span, slice: anytype) error{InvalidPolygonIndex}!@TypeOf(slice) {
        if (self.first > slice.len or self.count > slice.len - self.first) return error.InvalidPolygonIndex;
        return slice[self.first..][0..self.count];
    }
};

pub const Cell = extern struct {
    id: u32,
    pieces: Span,
};

pub const Piece = extern struct {
    attr: packed struct(u32) { region: Id, reserved: u16 = 0 },
    rings: Span,
};

pub const View = struct {
    cells: []const Cell,
    pieces: []const Piece,
    rings: []const Span,
    vertices: []const PointLL,

    pub fn cellPieces(self: View, id: u32) error{InvalidPolygonIndex}![]const Piece {
        var low: usize = 0;
        var high = self.cells.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const cell = self.cells[mid];
            if (cell.id == id) return cell.pieces.get(self.pieces);
            if (cell.id < id) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return &.{};
    }

    pub fn locate(self: View, piece: Piece, point: PointLL, deadline: io.Deadline) !polygon.Location {
        const rings = try piece.rings.get(self.rings);
        if (rings.len == 0) return error.InvalidPolygonIndex;
        const shell = try polygon.locateInRing(try rings[0].get(self.vertices), point, deadline);
        if (shell != .inside) return shell;
        for (rings[1..], 0..) |ring, i| {
            try checkAt(deadline, i);
            switch (try polygon.locateInRing(try ring.get(self.vertices), point, deadline)) {
                .inside => return .outside,
                .boundary => return .boundary,
                .outside => {},
            }
        }
        return .inside;
    }

    pub fn intersectsBox(self: View, piece: Piece, box: AABB, deadline: io.Deadline) !bool {
        if (try self.locate(piece, box.minpt(), deadline) != .outside) return true;
        const rings = try piece.rings.get(self.rings);
        for (rings, 0..) |ring, i| {
            try checkAt(deadline, i);
            if (try polygon.ringIntersectsBox(try ring.get(self.vertices), box, deadline)) return true;
        }
        return false;
    }

    pub fn verify(self: View, max_id: Id, deadline: io.Deadline) !void {
        var previous: ?u32 = null;
        var piece_offset: usize = 0;
        for (self.cells, 0..) |cell, i| {
            try checkAt(deadline, i);
            if (cell.id >= rows * columns or (previous != null and cell.id <= previous.?) or
                cell.pieces.first != piece_offset or cell.pieces.count == 0)
                return error.InvalidPolygonIndex;
            const pieces = try cell.pieces.get(self.pieces);
            for (pieces, 0..) |piece, j| {
                try checkAt(deadline, j);
                if (piece.attr.region == 0 or piece.attr.region > max_id or
                    piece.attr.reserved != 0 or piece.rings.count == 0)
                    return error.InvalidPolygonIndex;
                _ = try piece.rings.get(self.rings);
            }
            piece_offset += pieces.len;
            previous = cell.id;
        }
        if (piece_offset != self.pieces.len) return error.InvalidPolygonIndex;
        for (self.rings, 0..) |ring, i| {
            try checkAt(deadline, i);
            if (ring.count < 3) return error.InvalidPolygonIndex;
            _ = try ring.get(self.vertices);
        }
        for (self.vertices, 0..) |vertex, i| {
            try checkAt(deadline, i);
            if (!vertex.inRange()) return error.InvalidPolygonIndex;
        }
    }
};

/// Both positive ends of the world belong to the final column or row.
pub fn cellId(point: PointLL) u32 {
    const x: u32 = @intFromFloat(@min(columns - 1, (point.lng + 180) / cell_width));
    const y: u32 = @intFromFloat(@min(rows - 1, (point.lat + 90) / cell_width));
    return y * columns + x;
}

pub fn cellBox(id: u32) AABB {
    const x: f64 = @floatFromInt(id % columns);
    const y: f64 = @floatFromInt(id / columns);
    const lo = PointLL.init(x * cell_width - 180, y * cell_width - 90);
    return AABB.fromPoints(lo, .init(lo.lng + cell_width, lo.lat + cell_width));
}

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Span) == 8 and @offsetOf(Span, "first") == 0 and @offsetOf(Span, "count") == 4);
    std.debug.assert(@sizeOf(Cell) == 12 and @offsetOf(Cell, "id") == 0 and @offsetOf(Cell, "pieces") == 4);
    std.debug.assert(@sizeOf(Piece) == 12 and @offsetOf(Piece, "attr") == 0 and @offsetOf(Piece, "rings") == 4);
    std.debug.assert(@sizeOf(PointLL) == 16 and @offsetOf(PointLL, "lng") == 0 and @offsetOf(PointLL, "lat") == 8);
}
