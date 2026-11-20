//! Clip polygons into the cells used by the packed graph index.

const std = @import("std");
const grid = @import("../graph/polygon_grid.zig");
const geometry = @import("../geo/polygon.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const io = @import("../infra/io.zig");
const Allocator = std.mem.Allocator;

pub const Coverage = std.StaticBitSet(grid.rows * grid.columns);
pub const Piece = struct { id: grid.Id, polygon: geometry.Polygon };

pub const Builder = struct {
    scratch: Allocator,
    cells: []std.ArrayList(Piece),
    coverage: ?*const Coverage,
    deadline: io.Deadline,

    pub fn init(scratch: Allocator, coverage: ?*const Coverage, deadline: io.Deadline) !Builder {
        const cells = try scratch.alloc(std.ArrayList(Piece), grid.rows * grid.columns);
        @memset(cells, .empty);
        return .{ .scratch = scratch, .cells = cells, .coverage = coverage, .deadline = deadline };
    }

    /// Input rings that stay within one cell are borrowed until encoding.
    pub fn add(self: *Builder, id: grid.Id, polygon: geometry.Polygon) !void {
        const bounds = try geometry.ringBounds(polygon.outer, self.deadline) orelse return;
        const lo = grid.cellId(bounds.minpt());
        const hi = grid.cellId(bounds.maxpt());
        if (lo == hi) {
            if (self.includes(lo)) try self.cells[lo].append(self.scratch, .{ .id = id, .polygon = polygon });
            return;
        }
        for (lo / grid.columns..hi / grid.columns + 1) |row| {
            for (lo % grid.columns..hi % grid.columns + 1) |col| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                const cell: u32 = @intCast(row * grid.columns + col);
                if (!self.includes(cell)) continue;
                const clipped = try geometry.clipPolygon(self.scratch, polygon, grid.cellBox(cell), self.deadline);
                for (clipped.polygons, 0..) |part, i| {
                    try checkAt(self.deadline, i);
                    try self.cells[cell].append(self.scratch, .{ .id = id, .polygon = part });
                }
            }
        }
    }

    fn includes(self: Builder, cell: u32) bool {
        return if (self.coverage) |coverage| coverage.isSet(cell) else true;
    }

    pub fn encode(self: *const Builder, output: Allocator) !grid.View {
        var encoded: Encoder = .{ .a = output, .deadline = self.deadline };
        for (self.cells, 0..) |cell, i| {
            try checkAt(self.deadline, i);
            if (cell.items.len == 0) continue;
            const first = encoded.pieces.items.len;
            for (cell.items, 0..) |piece, j| {
                try checkAt(self.deadline, j);
                try encoded.piece(piece);
            }
            try encoded.cells.append(output, .{ .id = @intCast(i), .pieces = try grid.Span.init(first, cell.items.len) });
        }
        return .{
            .cells = encoded.cells.items,
            .pieces = encoded.pieces.items,
            .rings = encoded.rings.items,
            .vertices = encoded.vertices.items,
        };
    }
};

const Encoder = struct {
    a: Allocator,
    deadline: io.Deadline,
    cells: std.ArrayList(grid.Cell) = .empty,
    pieces: std.ArrayList(grid.Piece) = .empty,
    rings: std.ArrayList(grid.Span) = .empty,
    vertices: std.ArrayList(PointLL) = .empty,

    fn piece(self: *Encoder, part: Piece) !void {
        const rings = try grid.Span.init(self.rings.items.len, 1 + part.polygon.holes.len);
        try self.ring(part.polygon.outer);
        for (part.polygon.holes, 0..) |hole, i| {
            try checkAt(self.deadline, i);
            try self.ring(hole);
        }
        try self.pieces.append(self.a, .{ .attr = .{ .region = part.id }, .rings = rings });
    }

    fn ring(self: *Encoder, points: geometry.Ring) !void {
        const locations = try grid.Span.init(self.vertices.items.len, points.len);
        try self.vertices.appendSlice(self.a, points);
        try self.rings.append(self.a, locations);
    }
};

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}
