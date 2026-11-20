// Ported from src/mjolnir/adminbuilder.cc and src/mjolnir/admin.cc
// (Valhalla 3.9.3). Build a directly mappable grid instead of a database.
const std = @import("std");
const admin = @import("../graph/admin.zig");
const geometry = @import("../geo/polygon.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const io = @import("../infra/io.zig");
const boundary = @import("admin_boundaries.zig");
const checkpoint = @import("checkpoint.zig");
const Allocator = std.mem.Allocator;

pub const Index = struct {
    storage: std.heap.ArenaAllocator,
    view: admin.View,

    pub fn deinit(self: *Index) void {
        self.storage.deinit();
    }
};

const Piece = struct { id: admin.Id, polygon: geometry.Polygon };
const Grid = []std.ArrayList(Piece);

pub fn build(gpa: Allocator, source: anytype, deadline: io.Deadline) !?Index {
    var catalog = try boundary.collect(gpa, source, deadline);
    defer catalog.deinit();
    if (catalog.regions.len == 0) return null;
    return try pack(gpa, catalog.regions, deadline);
}

pub fn save(view: admin.View, tx: *checkpoint.Transaction) !void {
    const file = try tx.create(.admin_index);
    defer file.close();
    var sink: Sink = .{ .file = file, .deadline = tx.deadline };
    try view.write(&sink);
    try file.sync();
}

const Sink = struct {
    file: io.File,
    deadline: io.Deadline,
    offset: u64 = 0,

    pub fn append(self: *Sink, bytes: []const u8) !void {
        var left = bytes;
        while (left.len != 0) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const chunk = left[0..@min(left.len, 1024 * 1024)];
            try self.file.pwriteAll(chunk, self.offset);
            self.offset += chunk.len;
            left = left[chunk.len..];
        }
    }
};

fn pack(gpa: Allocator, regions: []boundary.Boundary, deadline: io.Deadline) !Index {
    if (regions.len > std.math.maxInt(admin.Id)) return error.TooManyAdmins;
    if (deadline.expired()) return error.DeadlineExceeded;
    std.sort.heap(boundary.Boundary, regions, {}, regionBefore);

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const grid: Grid = try temp.alloc(std.ArrayList(Piece), admin.rows * admin.columns);
    @memset(grid, .empty);
    for (regions, 1..) |region, i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        for (region.geometry.polygons) |polygon| {
            try addPolygon(temp, grid, @intCast(i), polygon, deadline);
        }
    }
    const parents = try findParents(temp, gpa, grid, regions, deadline);

    var storage: std.heap.ArenaAllocator = .init(gpa);
    errdefer storage.deinit();
    var encoded: Encoder = .{ .a = storage.allocator(), .deadline = deadline };
    for (regions, parents, 0..) |region, parent, i| {
        try checkAt(deadline, i);
        var root = i;
        while (parents[root] != admin.unknown) root = parents[root] - 1;
        const defaults = regions[root].attrs;
        try encoded.regions.append(encoded.a, .{
            .osm_id = region.osm_id,
            .attr = .{
                .level = region.attrs.level,
                .parent = parent,
                .drive_on_right = defaults.drive_on_right,
                .allow_intersection_names = defaults.allow_intersection_names,
            },
            .name = try encoded.string(region.attrs.name),
            .english_name = try encoded.string(region.attrs.english_name),
            .iso_code = try encoded.string(bundleIso(region.attrs.level, region.attrs.iso_code)),
            .default_language = try encoded.string(region.attrs.default_language),
        });
    }
    for (grid, 0..) |cell, i| {
        try checkAt(deadline, i);
        if (cell.items.len == 0) continue;
        const first = encoded.pieces.items.len;
        for (cell.items, 0..) |piece, j| {
            try checkAt(deadline, j);
            try encoded.piece(piece);
        }
        try encoded.cells.append(encoded.a, .{ .id = @intCast(i), .pieces = try span(first, cell.items.len) });
    }
    return .{
        .storage = storage,
        .view = .{
            .regions = encoded.regions.items,
            .cells = encoded.cells.items,
            .pieces = encoded.pieces.items,
            .rings = encoded.rings.items,
            .vertices = encoded.vertices.items,
            .strings = encoded.strings.items,
        },
    };
}

fn regionBefore(_: void, a: boundary.Boundary, b: boundary.Boundary) bool {
    return switch (std.mem.order(u8, a.attrs.name, b.attrs.name)) {
        .lt => true,
        .gt => false,
        .eq => a.osm_id < b.osm_id,
    };
}

// The Lua transform can retain a raw iso_code. Admin's tile record
// accepts a two-byte country code and two- or three-byte state codes.
fn bundleIso(level: u8, iso: []const u8) []const u8 {
    if (iso.len < 2 or iso[0] == 0) return "";
    if (level == 2) return if (iso.len == 2) iso else "";
    if (level == 4 and iso.len <= 3) return std.mem.sliceTo(iso, 0);
    return "";
}

fn addPolygon(a: Allocator, grid: Grid, id: admin.Id, polygon: geometry.Polygon, deadline: io.Deadline) !void {
    const bounds = try geometry.ringBounds(polygon.outer, deadline) orelse return;
    const lo = admin.cellId(bounds.minpt());
    const hi = admin.cellId(bounds.maxpt());
    if (lo == hi) {
        try grid[lo].append(a, .{ .id = id, .polygon = polygon });
        return;
    }
    for (lo / admin.columns..hi / admin.columns + 1) |row| {
        for (lo % admin.columns..hi % admin.columns + 1) |col| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const cell: u32 = @intCast(row * admin.columns + col);
            // The piece geometry is kept by the scratch arena until packing
            // and the parent coverage checks both finish.
            const clipped = try geometry.clipPolygon(a, polygon, admin.cellBox(cell), deadline);
            for (clipped.polygons, 0..) |part, i| {
                try checkAt(deadline, i);
                try grid[cell].append(a, .{ .id = id, .polygon = part });
            }
        }
    }
}

fn findParents(temp: Allocator, gpa: Allocator, grid: Grid, regions: []const boundary.Boundary, deadline: io.Deadline) ![]const admin.Id {
    const candidates = try temp.alloc(?std.ArrayList(admin.Id), regions.len);
    @memset(candidates, null);
    for (grid, 0..) |bucket, i| {
        try checkAt(deadline, i);
        const pieces = bucket.items;
        for (pieces, 0..) |child, j| {
            try checkAt(deadline, j);
            const level = regions[child.id - 1].attrs.level;
            if (level <= 2) continue;
            const retained = &candidates[child.id - 1];
            if (retained.*) |*list| {
                var len: usize = 0;
                for (list.items, 0..) |id, k| {
                    try checkAt(deadline, k);
                    if (try covers(id, pieces, child.polygon, gpa, deadline)) {
                        list.items[len] = id;
                        len += 1;
                    }
                }
                list.shrinkRetainingCapacity(len);
            } else {
                var list: std.ArrayList(admin.Id) = .empty;
                var preceding: admin.Id = admin.unknown;
                for (pieces, 0..) |parent, k| {
                    try checkAt(deadline, k);
                    if (parent.id == preceding) continue;
                    preceding = parent.id;
                    if (regions[parent.id - 1].attrs.level >= level) continue;
                    if (try covers(parent.id, pieces[k..], child.polygon, gpa, deadline))
                        try list.append(temp, parent.id);
                }
                retained.* = list;
            }
        }
    }
    const parents = try temp.alloc(admin.Id, regions.len);
    for (candidates, parents, 0..) |options, *parent, i| {
        try checkAt(deadline, i);
        parent.* = admin.unknown;
        const list = options orelse continue;
        for (list.items, 0..) |id, j| {
            try checkAt(deadline, j);
            const next = regions[id - 1];
            if (parent.* != admin.unknown) {
                const best = regions[parent.* - 1];
                if (next.attrs.level < best.attrs.level or
                    (next.attrs.level == best.attrs.level and next.osm_id >= best.osm_id)) continue;
            }
            parent.* = id;
        }
    }
    return parents;
}

noinline fn covers(parent: admin.Id, pieces: []const Piece, child: geometry.Polygon, gpa: Allocator, deadline: io.Deadline) !bool {
    for (pieces, 0..) |piece, i| {
        try checkAt(deadline, i);
        if (piece.id < parent) continue;
        if (piece.id > parent) break;
        if (try piece.polygon.coversPolygon(child, gpa, deadline)) return true;
    }
    return false;
}

fn span(first: usize, count: usize) !admin.Span {
    if (first > std.math.maxInt(u32) or count > std.math.maxInt(u32) - first)
        return error.AdminIndexTooLarge;
    return .{ .first = @intCast(first), .count = @intCast(count) };
}

const Encoder = struct {
    a: Allocator,
    deadline: io.Deadline,
    regions: std.ArrayList(admin.Region) = .empty,
    cells: std.ArrayList(admin.Cell) = .empty,
    pieces: std.ArrayList(admin.Piece) = .empty,
    rings: std.ArrayList(admin.Span) = .empty,
    vertices: std.ArrayList(PointLL) = .empty,
    strings: std.ArrayList(u8) = .empty,

    fn string(self: *Encoder, word: []const u8) !admin.Span {
        const result = try span(self.strings.items.len, word.len);
        try self.strings.appendSlice(self.a, word);
        return result;
    }

    fn piece(self: *Encoder, part: Piece) !void {
        const rings = try span(self.rings.items.len, 1 + part.polygon.holes.len);
        try self.ring(part.polygon.outer);
        for (part.polygon.holes, 0..) |hole, i| {
            try checkAt(self.deadline, i);
            try self.ring(hole);
        }
        try self.pieces.append(self.a, .{ .attr = .{ .region = part.id }, .rings = rings });
    }

    fn ring(self: *Encoder, points: geometry.Ring) !void {
        const locations = try span(self.vertices.items.len, points.len);
        try self.vertices.appendSlice(self.a, points);
        try self.rings.append(self.a, locations);
    }
};

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}
