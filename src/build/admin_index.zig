// Ported from src/mjolnir/adminbuilder.cc and src/mjolnir/admin.cc
// (Valhalla 3.9.3). Build a directly mappable grid instead of a database.
const std = @import("std");
const admin = @import("../graph/admin.zig");
const geometry = @import("../geo/polygon.zig");
const polygon_grid = @import("polygon_grid.zig");
const io = @import("../infra/io.zig");
const boundary = @import("admin_boundaries.zig");
const checkpoint = @import("checkpoint.zig");
const turns = @import("turn_restrictions.zig");
const lanes = @import("lanes.zig");
const Allocator = std.mem.Allocator;

pub const Index = struct {
    storage: std.heap.ArenaAllocator,
    view: admin.View,

    pub fn deinit(self: *Index) void {
        self.storage.deinit();
    }
};

const Piece = polygon_grid.Piece;
const Grid = []std.ArrayList(Piece);

pub fn build(gpa: Allocator, source: anytype, deadline: io.Deadline, boundaries: bool, restrictions: *turns.Catalog, connections: *lanes.Catalog, max_changeset: *u64) !?Index {
    var catalog = try boundary.collectRelations(gpa, source, deadline, boundaries, restrictions, connections);
    defer catalog.deinit();
    max_changeset.* = @max(max_changeset.*, catalog.max_relation_changeset);
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
    var grid = try polygon_grid.Builder.init(temp, null, deadline);
    for (regions, 1..) |region, i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        for (region.geometry.polygons) |polygon| {
            try grid.add(@intCast(i), polygon);
        }
    }
    const parents = try findParents(temp, gpa, grid.cells, regions, deadline);

    var storage: std.heap.ArenaAllocator = .init(gpa);
    errdefer storage.deinit();
    var encoded: Encoder = .{ .a = storage.allocator() };
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
    const packed_grid = grid.encode(encoded.a) catch |err| switch (err) {
        error.PolygonIndexTooLarge => return error.AdminIndexTooLarge,
        else => return err,
    };
    return .{
        .storage = storage,
        .view = .{
            .regions = encoded.regions.items,
            .cells = packed_grid.cells,
            .pieces = packed_grid.pieces,
            .rings = packed_grid.rings,
            .vertices = packed_grid.vertices,
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

const Encoder = struct {
    a: Allocator,
    regions: std.ArrayList(admin.Region) = .empty,
    strings: std.ArrayList(u8) = .empty,

    fn string(self: *Encoder, word: []const u8) !admin.Span {
        const result = admin.Span.init(self.strings.items.len, word.len) catch return error.AdminIndexTooLarge;
        try self.strings.appendSlice(self.a, word);
        return result;
    }
};

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}
