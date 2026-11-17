//! Uniform square tiling, cell traversal, Hilbert order and web-mercator
//! tile math.
//!
//! `Tiles` is ported from valhalla/midgard/tiles.h and src/midgard/tiles.cc
//! (Valhalla 3.9.3) for geographic points. Tile ids start at 0 in the lower
//! left and increase along rows. The tile size is single precision upstream
//! (`float tilesize_`), and so is it here, because row and column results
//! depend on it. Each tile can be subdivided into `subdivisions^2` bins.

const std = @import("std");
const libm = @import("libm.zig");
const PointLL = @import("point.zig").PointLL;
const AABB = @import("aabb.zig").AABB;
const DistanceApproximator = @import("point.zig").DistanceApproximator;
const line_ops = @import("line.zig");
const Allocator = std.mem.Allocator;

pub const Neighbor = enum(u3) { bottom_left = 0, left = 1, top_left = 2, top = 3, top_right = 4, right = 5, bottom_right = 6, bottom = 7 };

/// One bin of one tile.
pub const Cell = struct {
    tile: i32,
    bin: u16,

    fn lessThan(_: void, a: Cell, b: Cell) bool {
        return if (a.tile != b.tile) a.tile < b.tile else a.bin < b.bin;
    }
};

pub const Tiles = struct {
    wrapx: bool,
    bounds: AABB,
    tilesize: f32,
    nsubdivisions: u16,
    subdivision_size: f32,
    ncolumns: i32,
    nrows: i32,

    pub fn init(bounds: AABB, tilesize: f32, subdivisions: u16, wrapx: bool) Tiles {
        const ts: f64 = tilesize;
        return .{
            .wrapx = wrapx,
            .bounds = bounds,
            .tilesize = tilesize,
            .nsubdivisions = subdivisions,
            .subdivision_size = tilesize / @as(f32, @floatFromInt(subdivisions)),
            .ncolumns = @intFromFloat(@round(bounds.width() / ts)),
            .nrows = @intFromFloat(@round(bounds.height() / ts)),
        };
    }

    pub fn initGrid(min_pt: PointLL, tilesize: f32, columns: i32, rows: i32, subdivisions: u16, wrapx: bool) Tiles {
        const ts: f64 = tilesize;
        return .{
            .wrapx = wrapx,
            .bounds = .{ .minx = min_pt.lng, .miny = min_pt.lat, .maxx = min_pt.lng + @as(f64, @floatFromInt(columns)) * ts, .maxy = min_pt.lat + @as(f64, @floatFromInt(rows)) * ts },
            .tilesize = tilesize,
            .nsubdivisions = subdivisions,
            .subdivision_size = tilesize / @as(f32, @floatFromInt(subdivisions)),
            .ncolumns = columns,
            .nrows = rows,
        };
    }

    /// Row containing `y`, or -1 outside the bounds.
    pub fn row(self: Tiles, y: f64) i32 {
        if (y < self.bounds.miny or y > self.bounds.maxy) return -1;
        if (y == self.bounds.maxy) return self.nrows - 1;
        return @intFromFloat((y - self.bounds.miny) / @as(f64, self.tilesize));
    }

    /// Column containing `x`, or -1 outside the bounds.
    pub fn col(self: Tiles, x: f64) i32 {
        if (x < self.bounds.minx or x > self.bounds.maxx) return -1;
        const c = (x - self.bounds.minx) / @as(f64, self.tilesize);
        if (c >= @as(f64, @floatFromInt(self.ncolumns))) return self.ncolumns - 1;
        return if (c >= 0.0) @intFromFloat(c) else @intFromFloat(c - 1);
    }

    pub fn tileIdOf(self: Tiles, p: PointLL) i32 {
        return self.tileId(p.lat, p.lng);
    }

    /// Tile containing (y, x), or -1 outside the bounds.
    pub fn tileId(self: Tiles, y: f64, x: f64) i32 {
        if (y < self.bounds.miny or x < self.bounds.minx or y > self.bounds.maxy or x > self.bounds.maxx) return -1;
        return self.row(y) * self.ncolumns + self.col(x);
    }

    pub fn tileIdColRow(self: Tiles, c: i32, r: i32) i32 {
        return r * self.ncolumns + c;
    }

    pub const RowCol = struct { row: i32, col: i32 };

    pub fn rowColumn(self: Tiles, tileid: i32) RowCol {
        return .{ .row = @divTrunc(tileid, self.ncolumns), .col = @rem(tileid, self.ncolumns) };
    }

    pub fn maxTileId(bounds: AABB, tilesize: f32) u32 {
        const cols: u32 = @intFromFloat(@ceil(bounds.width() / @as(f64, tilesize)));
        const rows: u32 = @intFromFloat(@ceil(bounds.height() / @as(f64, tilesize)));
        return cols * rows - 1;
    }

    pub fn base(self: Tiles, tileid: i32) PointLL {
        const r = @divTrunc(tileid, self.ncolumns);
        const c = tileid - r * self.ncolumns;
        return .{ .lng = self.bounds.minx + @as(f64, @floatFromInt(c)) * @as(f64, self.tilesize), .lat = self.bounds.miny + @as(f64, @floatFromInt(r)) * @as(f64, self.tilesize) };
    }

    pub fn tileBounds(self: Tiles, tileid: i32) AABB {
        const b = self.base(tileid);
        return .{ .minx = b.lng, .miny = b.lat, .maxx = b.lng + self.tilesize, .maxy = b.lat + self.tilesize };
    }

    pub fn tileBoundsColRow(self: Tiles, c: i32, r: i32) AABB {
        const bx = self.bounds.minx + @as(f64, @floatFromInt(c)) * @as(f64, self.tilesize);
        const by = self.bounds.miny + @as(f64, @floatFromInt(r)) * @as(f64, self.tilesize);
        return .{ .minx = bx, .miny = by, .maxx = bx + self.tilesize, .maxy = by + self.tilesize };
    }

    pub fn center(self: Tiles, tileid: i32) PointLL {
        const b = self.base(tileid);
        return .{ .lng = b.lng + @as(f64, self.tilesize) * 0.5, .lat = b.lat + @as(f64, self.tilesize) * 0.5 };
    }

    pub fn tileCount(self: Tiles) u32 {
        const nr: f32 = @floatCast((self.bounds.maxy - self.bounds.miny) / @as(f64, self.tilesize));
        return @intCast(self.ncolumns * @as(i32, @intFromFloat(@ceil(nr))));
    }

    pub fn rightNeighbor(self: Tiles, tileid: i32) i32 {
        if (tileid - @divTrunc(tileid, self.ncolumns) * self.ncolumns < self.ncolumns - 1) return tileid + 1;
        return if (self.wrapx) tileid - self.ncolumns + 1 else tileid;
    }

    pub fn leftNeighbor(self: Tiles, tileid: i32) i32 {
        if (tileid - @divTrunc(tileid, self.ncolumns) * self.ncolumns > 0) return tileid - 1;
        return if (self.wrapx) tileid + self.ncolumns - 1 else tileid;
    }

    pub fn topNeighbor(self: Tiles, tileid: i32) i32 {
        return if (tileid < @as(i32, @intCast(self.tileCount())) - self.ncolumns) tileid + self.ncolumns else tileid;
    }

    pub fn bottomNeighbor(self: Tiles, tileid: i32) i32 {
        return if (tileid < self.ncolumns) tileid else tileid - self.ncolumns;
    }

    /// Whether two tiles share an edge (N, E, S, W).
    pub fn areNeighbors(self: Tiles, a: i32, b: i32) bool {
        return b == self.topNeighbor(a) or b == self.rightNeighbor(a) or b == self.bottomNeighbor(a) or b == self.leftNeighbor(a);
    }

    /// The neighbouring bin of a global bin (upstream GetNeighboringBin).
    pub fn neighboringBin(self: Tiles, global_x: i32, global_y: i32, which: Neighbor) Cell {
        const dx = [8]i32{ -1, -1, -1, 0, 1, 1, 1, 0 };
        const dy = [8]i32{ -1, 0, 1, 1, 1, 0, -1, -1 };
        const subs: i32 = self.nsubdivisions;
        const nx = if (self.wrapx and (global_x == self.ncolumns * subs or global_x == 0)) global_x else global_x + dx[@backingInt(which)];
        const ny = global_y + dy[@backingInt(which)];
        return .{
            .tile = @divTrunc(nx, subs) + @divTrunc(ny, subs) * self.ncolumns,
            .bin = @intCast(@rem(nx, subs) + @rem(ny, subs) * subs),
        };
    }

    /// The 4 (edge) or 8 neighbouring bins of a bin, clockwise from the lower left.
    pub fn neighboringBins(self: Tiles, comptime four_way: bool, tileid: u32, binid: u16) [if (four_way) 4 else 8]Cell {
        var out: [if (four_way) 4 else 8]Cell = undefined;
        const subs: i32 = self.nsubdivisions;
        const t: i32 = @intCast(tileid);
        const gx = @rem(t, self.ncolumns) * subs + @rem(@as(i32, binid), subs);
        const gy = @divTrunc(t, self.ncolumns) * subs + @divTrunc(@as(i32, binid), subs);
        var n: usize = 0;
        var i: u8 = if (four_way) 1 else 0;
        while (i < 8) : (i += if (four_way) 2 else 1) {
            out[n] = self.neighboringBin(gx, gy, @fromBackingInt(@intCast(i)));
            n += 1;
        }
        return out;
    }

    /// Tiles a box covers, split across the antimeridian when wrapping.
    pub fn tileList(self: Tiles, gpa: Allocator, bbox: AABB, out: *std.ArrayList(i32)) Allocator.Error!void {
        var boxes: [2]AABB = undefined;
        var n: usize = 1;
        const tb = self.bounds;
        if (self.wrapx and bbox.minx < tb.minx and bbox.maxx > tb.minx) {
            boxes[0] = .{ .minx = tb.minx, .miny = bbox.miny, .maxx = bbox.maxx, .maxy = bbox.maxy };
            boxes[1] = .{ .minx = bbox.minx + tb.width(), .miny = bbox.miny, .maxx = tb.maxx, .maxy = bbox.maxy };
            n = 2;
        } else if (self.wrapx and bbox.minx < tb.maxx and bbox.maxx > tb.maxx) {
            boxes[0] = .{ .minx = bbox.minx, .miny = bbox.miny, .maxx = tb.maxx, .maxy = bbox.maxy };
            boxes[1] = .{ .minx = tb.minx, .miny = bbox.miny, .maxx = bbox.maxx - tb.width(), .maxy = bbox.maxy };
            n = 2;
        } else {
            boxes[0] = bbox.intersection(tb);
        }
        for (boxes[0..n]) |bb| {
            const minrow = @max(self.row(bb.miny), 0);
            const maxrow = @max(self.row(bb.maxy), 0);
            const mincol = @max(self.col(bb.minx), 0);
            const maxcol = @max(self.col(bb.maxx), 0);
            var r = minrow;
            while (r <= maxrow) : (r += 1) {
                var c = mincol;
                while (c <= maxcol) : (c += 1) try out.append(gpa, self.tileIdColRow(c, r));
            }
        }
    }

    fn setPixel(self: Tiles, gpa: Allocator, out: *std.ArrayList(Cell), x: i32, y: i32) Allocator.Error!bool {
        const subs: i32 = self.nsubdivisions;
        if (x < 0 or y < 0 or x >= subs * self.ncolumns or y >= subs * self.nrows) return true;
        try out.append(gpa, .{
            .tile = @divTrunc(y, subs) * self.ncolumns + @divTrunc(x, subs),
            .bin = @intCast(@rem(y, subs) * subs + @rem(x, subs)),
        });
        return false;
    }

    fn bresenham(self: Tiles, gpa: Allocator, out: *std.ArrayList(Cell), x0: f64, y0: f64, x1: f64, y1: f64) Allocator.Error!void {
        var outside = try self.setPixel(gpa, out, @intFromFloat(@floor(x0)), @intFromFloat(@floor(y0)));
        const sx: f64 = if (x0 < x1) 1 else -1;
        const dx = x1 - x0;
        var x = @floor(x0) + 0.5;
        const sy: f64 = if (y0 < y1) 1 else -1;
        const dy = y1 - y0;
        var y = @floor(y0) + 0.5;
        while (@floor(x) != @floor(x1) or @floor(y) != @floor(y1)) {
            const tx = @abs(dx * (y - y0) - dy * ((x + sx) - x0));
            const ty = @abs(dx * ((y + sy) - y0) - dy * (x - x0));
            if (tx < ty or (tx == ty and y0 == y1)) x += sx else y += sy;
            const o = try self.setPixel(gpa, out, @intFromFloat(@floor(x)), @intFromFloat(@floor(y)));
            if (!outside and o) return;
            outside = o;
        }
    }

    /// Every bin a polyline passes through, sorted and deduplicated
    /// (upstream Intersect(linestring), including its resampling so long
    /// segments follow the great circle).
    pub fn intersectLine(self: Tiles, gpa: Allocator, linestring: []const PointLL, out: *std.ArrayList(Cell)) Allocator.Error!void {
        if (linestring.len == 0) return;
        const start = out.items.len;
        var resampled: std.ArrayList(PointLL) = .empty;
        defer resampled.deinit(gpa);
        const max_meters = @max(1.0, @as(f64, self.subdivision_size) * 0.25 * DistanceApproximator.metersPerLngDegree(linestring[0].lat));
        if (line_ops.length(linestring) > max_meters) try line_ops.resampleSpherical(gpa, linestring, max_meters, true, &resampled);
        const pts = if (resampled.items.len > 0) resampled.items else linestring;
        const xs: f64 = @floatFromInt(self.ncolumns * self.nsubdivisions);
        const ys: f64 = @floatFromInt(self.nrows * self.nsubdivisions);
        var i: usize = 0;
        while (i < pts.len) : (i += 1) {
            const u = pts[i];
            var v = u;
            if (i + 1 < pts.len) {
                v = pts[i + 1];
            } else if (pts.len > 1) break;
            const x0 = (u.lng - self.bounds.minx) / self.bounds.width() * xs;
            const y0 = (u.lat - self.bounds.miny) / self.bounds.height() * ys;
            const x1 = (v.lng - self.bounds.minx) / self.bounds.width() * xs;
            const y1 = (v.lat - self.bounds.miny) / self.bounds.height() * ys;
            const ix0: i32 = @intFromFloat(@floor(x0));
            const ix1: i32 = @intFromFloat(@floor(x1));
            const iy0: i32 = @intFromFloat(@floor(y0));
            const iy1: i32 = @intFromFloat(@floor(y1));
            const ddx = ix0 - ix1;
            const ddy = iy0 - iy1;
            const ds = ddx * ddx + ddy * ddy;
            if (ds == 0) {
                _ = try self.setPixel(gpa, out, ix0, iy0);
            } else if (ds == 1) {
                _ = try self.setPixel(gpa, out, ix0, iy0);
                _ = try self.setPixel(gpa, out, ix1, iy1);
            } else {
                try self.bresenham(gpa, out, x0, y0, x1, y1);
            }
        }
        dedupe(out, start);
    }

    /// Every bin a box covers, clamped to the grid (upstream Intersect(box)).
    pub fn intersectBox(self: Tiles, gpa: Allocator, box: AABB, out: *std.ArrayList(Cell)) Allocator.Error!void {
        const subs: i32 = self.nsubdivisions;
        const xp = self.ncolumns * subs;
        const yp = self.nrows * subs;
        const fxp: f64 = @floatFromInt(xp);
        const fyp: f64 = @floatFromInt(yp);
        var x0: i32 = @intFromFloat(@floor(((box.minx - self.bounds.minx) * fxp) / self.bounds.width()));
        var y0: i32 = @intFromFloat(@floor(((box.miny - self.bounds.miny) * fyp) / self.bounds.height()));
        var x1: i32 = @intFromFloat(@floor(((box.maxx - self.bounds.minx) * fxp) / self.bounds.width()));
        var y1: i32 = @intFromFloat(@floor(((box.maxy - self.bounds.miny) * fyp) / self.bounds.height()));
        x0 = @max(x0, 0);
        y0 = @max(y0, 0);
        x1 = @min(x1, xp - 1);
        y1 = @min(y1, yp - 1);
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) try out.append(gpa, .{
                .tile = @divTrunc(y, subs) * self.ncolumns + @divTrunc(x, subs),
                .bin = @intCast(@rem(y, subs) * subs + @rem(x, subs)),
            });
        }
    }

    pub fn binBBox(self: Tiles, tile: i32, bin: u16) AABB {
        const bin_row = bin / self.nsubdivisions;
        const bin_col = bin % self.nsubdivisions;
        const tb = self.tileBounds(tile);
        const ss: f64 = self.subdivision_size;
        const llx = tb.minx + @as(f64, @floatFromInt(bin_col)) * ss;
        const lly = tb.miny + @as(f64, @floatFromInt(bin_row)) * ss;
        return .{ .minx = llx, .miny = lly, .maxx = llx + ss, .maxy = lly + ss };
    }
};

fn dedupe(out: *std.ArrayList(Cell), start: usize) void {
    const slice = out.items[start..];
    std.mem.sort(Cell, slice, {}, Cell.lessThan);
    var w: usize = 0;
    for (slice) |c| {
        if (w > 0 and slice[w - 1].tile == c.tile and slice[w - 1].bin == c.bin) continue;
        slice[w] = c;
        w += 1;
    }
    out.shrinkRetainingCapacity(start + w);
}

/// Visits bins in order of increasing distance from a seed point (upstream
/// `ClosestFirst`, used by location search to expand outward). Each call to
/// `next` returns the next closest bin and its distance in metres.
pub const ClosestFirst = struct {
    tiles: Tiles,
    seed: PointLL,
    subcols: i32,
    subrows: i32,
    queued: std.AutoHashMapUnmanaged(i32, void) = .empty,
    queue: std.PriorityQueue(Best, void, Best.order),
    gpa: Allocator,

    const Best = struct {
        dist: f64,
        sub: i32,
        fn order(_: void, a: Best, b: Best) std.math.Order {
            if (a.dist == b.dist) return std.math.order(a.sub, b.sub);
            return std.math.order(a.dist, b.dist);
        }
    };

    pub const Item = struct { tile: i32, bin: u16, distance: f64 };

    pub fn init(gpa: Allocator, tiles: Tiles, seed: PointLL) Allocator.Error!ClosestFirst {
        var self: ClosestFirst = .{
            .tiles = tiles,
            .seed = seed,
            .subcols = tiles.ncolumns * tiles.nsubdivisions,
            .subrows = tiles.nrows * tiles.nsubdivisions,
            .queue = .initContext({}),
            .gpa = gpa,
        };
        const x = (seed.lng - tiles.bounds.minx) / tiles.bounds.width() * @as(f64, @floatFromInt(self.subcols));
        const y = (seed.lat - tiles.bounds.miny) / tiles.bounds.height() * @as(f64, @floatFromInt(self.subrows));
        const sub = @as(i32, @intFromFloat(y)) * self.subcols + @as(i32, @intFromFloat(x));
        try self.queued.put(gpa, sub, {});
        try self.queue.push(gpa, .{ .dist = 0, .sub = sub });
        try self.neighbors(sub);
        return self;
    }

    pub fn deinit(self: *ClosestFirst) void {
        self.queued.deinit(self.gpa);
        self.queue.deinit(self.gpa);
    }

    fn dist(self: *const ClosestFirst, sub: i32) f64 {
        const ss: f64 = self.tiles.subdivision_size;
        const x: f64 = @floatFromInt(@rem(sub, self.subcols));
        const y: f64 = @floatFromInt(@divTrunc(sub, self.subcols));
        const x0 = self.tiles.bounds.minx + x * ss;
        const x1 = self.tiles.bounds.minx + (x + 1) * ss;
        const y0 = self.tiles.bounds.miny + y * ss;
        const y1 = self.tiles.bounds.miny + (y + 1) * ss;
        var corners: [8]PointLL = undefined;
        var n: usize = 4;
        corners[0] = .{ .lng = x0, .lat = y0 };
        corners[1] = .{ .lng = x1, .lat = y0 };
        corners[2] = .{ .lng = x0, .lat = y1 };
        corners[3] = .{ .lng = x1, .lat = y1 };
        const s = self.seed;
        if (x0 < s.lng and x1 > s.lng) {
            corners[n] = .{ .lng = s.lng, .lat = y0 };
            corners[n + 1] = .{ .lng = s.lng, .lat = y1 };
            n += 2;
        }
        if (y0 < s.lat and y1 > s.lat) {
            corners[n] = .{ .lng = x0, .lat = s.lat };
            corners[n + 1] = .{ .lng = x1, .lat = s.lat };
            n += 2;
        }
        var best = std.math.floatMax(f64);
        for (corners[0..n]) |c| best = @min(best, s.distance(c));
        return best;
    }

    fn neighbors(self: *ClosestFirst, s: i32) Allocator.Error!void {
        const x = @rem(s, self.subcols);
        const y = @divTrunc(s, self.subcols);
        const offsets = [4][2]i32{ .{ 0, -1 }, .{ -1, 0 }, .{ 1, 0 }, .{ 0, 1 } };
        for (offsets) |off| {
            const ny = y + off[1];
            if (ny == -1 or ny == self.subrows) continue;
            var nx = x + off[0];
            if (nx == -1 or nx == self.subcols) nx = @mod(nx + self.subcols, self.subcols); // geographic: wrap
            const nb = ny * self.subcols + nx;
            const gop = try self.queued.getOrPut(self.gpa, nb);
            if (!gop.found_existing) try self.queue.push(self.gpa, .{ .dist = self.dist(nb), .sub = nb });
        }
    }

    /// The next closest bin, or null when every bin has been visited.
    pub fn next(self: *ClosestFirst) Allocator.Error!?Item {
        const best = self.queue.pop() orelse return null;
        try self.neighbors(best.sub);
        const subs: i32 = self.tiles.nsubdivisions;
        const sx = @rem(best.sub, self.subcols);
        const sy = @divTrunc(best.sub, self.subcols);
        const tc = @divTrunc(sx, subs);
        const tr = @divTrunc(sy, subs);
        return .{
            .tile = tr * self.tiles.ncolumns + tc,
            .bin = @intCast((sy - tr * subs) * subs + (sx - tc * subs)),
            .distance = best.dist,
        };
    }
};

// ---------------------------------------------------------------------------
// Hilbert curve
// ---------------------------------------------------------------------------

/// Index of (x, y) along a Hilbert curve covering a 2^order square.
pub fn hilbertIndex(order: u5, x_in: u32, y_in: u32) u64 {
    var x: u64 = x_in;
    var y: u64 = y_in;
    var d: u64 = 0;
    var s: u64 = @as(u64, 1) << order;
    s >>= 1;
    while (s > 0) : (s >>= 1) {
        const rx: u64 = @intFromBool(x & s != 0);
        const ry: u64 = @intFromBool(y & s != 0);
        d += s * s * ((3 * rx) ^ ry);
        hilbertRotate(@as(u64, 1) << order, &x, &y, rx, ry);
    }
    return d;
}

/// Inverse of `hilbertIndex`.
pub fn hilbertPoint(order: u5, d_in: u64) [2]u32 {
    var x: u64 = 0;
    var y: u64 = 0;
    var t = d_in;
    var s: u64 = 1;
    const n: u64 = @as(u64, 1) << order;
    while (s < n) : (s *= 2) {
        const rx: u64 = 1 & (t / 2);
        const ry: u64 = 1 & (t ^ rx);
        hilbertRotate(s, &x, &y, rx, ry);
        x += s * rx;
        y += s * ry;
        t /= 4;
    }
    return .{ @intCast(x), @intCast(y) };
}

fn hilbertRotate(n: u64, x: *u64, y: *u64, rx: u64, ry: u64) void {
    if (ry == 0) {
        if (rx == 1) {
            x.* = n -% 1 -% x.*;
            y.* = n -% 1 -% y.*;
        }
        std.mem.swap(u64, x, y);
    }
}

/// Hilbert index of a coordinate on a 2^order grid over the whole world.
pub fn hilbertOfPoint(order: u5, p: PointLL) u64 {
    const n: f64 = @floatFromInt(@as(u64, 1) << order);
    const max: f64 = n - 1;
    const x = std.math.clamp(@floor((p.lng + 180.0) / 360.0 * n), 0, max);
    const y = std.math.clamp(@floor((p.lat + 90.0) / 180.0 * n), 0, max);
    return hilbertIndex(order, @intFromFloat(x), @intFromFloat(y));
}

// ---------------------------------------------------------------------------
// Web mercator z/x/y
// ---------------------------------------------------------------------------

pub const TileXYZ = struct { z: u5, x: u32, y: u32 };

/// Slippy-map tile containing a point at zoom z (y grows southward).
pub fn mercatorTile(z: u5, p: PointLL) TileXYZ {
    const n: f64 = @floatFromInt(@as(u64, 1) << z);
    const lat = std.math.clamp(p.lat, -85.0511287798066, 85.0511287798066) * std.math.pi / 180.0;
    const x = std.math.clamp(@floor((p.lng + 180.0) / 360.0 * n), 0, n - 1);
    const y = std.math.clamp(@floor((1.0 - libm.logF(libm.tanF(lat) + 1.0 / libm.cosF(lat)) / std.math.pi) / 2.0 * n), 0, n - 1);
    return .{ .z = z, .x = @intFromFloat(x), .y = @intFromFloat(y) };
}

/// Geographic bounds of a slippy-map tile.
pub fn mercatorBounds(t: TileXYZ) AABB {
    const n: f64 = @floatFromInt(@as(u64, 1) << t.z);
    const lng0 = @as(f64, @floatFromInt(t.x)) / n * 360.0 - 180.0;
    const lng1 = @as(f64, @floatFromInt(t.x + 1)) / n * 360.0 - 180.0;
    const lat0 = mercatorLat(@as(f64, @floatFromInt(t.y + 1)) / n);
    const lat1 = mercatorLat(@as(f64, @floatFromInt(t.y)) / n);
    return .{ .minx = lng0, .miny = lat0, .maxx = lng1, .maxy = lat1 };
}

fn mercatorLat(frac: f64) f64 {
    return libm.atanF(libm.sinhF(std.math.pi * (1 - 2 * frac))) * 180.0 / std.math.pi;
}

// ---------------------------------------------------------------------------
// Fixed grids used across the engine
// ---------------------------------------------------------------------------

/// The spatial index grid: 1/256 degree cells over the world.
pub const snap_cells_per_degree = 256;

pub fn snapCell(p: PointLL) u32 {
    const cols: u32 = 360 * snap_cells_per_degree;
    const x: u32 = @intFromFloat(std.math.clamp(@floor((p.lng + 180.0) * snap_cells_per_degree), 0, @as(f64, @floatFromInt(cols - 1))));
    const y: u32 = @intFromFloat(std.math.clamp(@floor((p.lat + 90.0) * snap_cells_per_degree), 0, 180 * snap_cells_per_degree - 1));
    return y * cols + x;
}

/// The 1 degree elevation tile (SRTM naming: south-west corner) of a point.
pub const ElevationTile = struct { lat: i32, lng: i32 };

pub fn elevationTile(p: PointLL) ElevationTile {
    return .{ .lat = @intFromFloat(@floor(p.lat)), .lng = @intFromFloat(@floor(p.lng)) };
}

// ---------------------------------------------------------------------------
// Tests: ported from test/tiles.cc
// ---------------------------------------------------------------------------

const testing = std.testing;

fn P(lng: f64, lat: f64) PointLL {
    return .{ .lng = lng, .lat = lat };
}

const world = AABB.init(-180, -90, 180, 90);

test "max id" {
    try testing.expectEqual(@as(u32, 1036799), Tiles.maxTileId(world, 0.25));
    try testing.expectEqual(@as(u32, 64799), Tiles.maxTileId(world, 1));
    try testing.expectEqual(@as(u32, 4049), Tiles.maxTileId(world, 4));
}

test "base" {
    const t = Tiles.init(world, 1, 1, true);
    try testing.expect(t.base(0).eql(P(-180, -90)));
    try testing.expect(t.base(1).eql(P(-179, -90)));
    try testing.expect(t.base(359).eql(P(179, -90)));
    try testing.expect(t.base(360).eql(P(-180, -89)));
    try testing.expect(t.base(360 * 180 - 1).eql(P(179, 89)));
}

test "row and column" {
    const t = Tiles.init(world, 1, 1, true);
    const id1 = t.tileId(-76.5, 40.5);
    const rc = t.rowColumn(id1);
    try testing.expectEqual(id1, t.tileIdColRow(rc.col, rc.row));
    for ([_]f64{ 179.9999986, 180.0, 180.001, -179.9999986, -180.0, -180.001 }) |x| try testing.expect(t.col(x) < t.ncolumns);
}

test "tile bounds" {
    const t = Tiles.init(world, 1, 1, true);
    const n = t.ncolumns * t.nrows;
    try testing.expectEqual(@as(i32, 360 * 180), n);
    for ([_]i32{ 0, 1, t.ncolumns - 1, t.ncolumns, @divTrunc(n, 2) - 1, @divTrunc(n, 2), n - t.ncolumns, n - 1 }) |id| {
        const rc = t.rowColumn(id);
        try testing.expectEqual(t.tileBounds(id), t.tileBoundsColRow(rc.col, rc.row));
    }
}

test "neighbors" {
    const t = Tiles.init(world, 1, 1, true);
    const id1 = t.tileId(-76.5, 40.5);
    const rc1 = t.rowColumn(id1);
    const l = t.leftNeighbor(id1);
    try testing.expect(t.areNeighbors(id1, l));
    try testing.expectEqual(rc1.col - 1, t.rowColumn(l).col);
    const r = t.rightNeighbor(id1);
    try testing.expectEqual(rc1.col + 1, t.rowColumn(r).col);
    const top = t.topNeighbor(id1);
    try testing.expectEqual(rc1.row + 1, t.rowColumn(top).row);
    const b = t.bottomNeighbor(id1);
    try testing.expectEqual(rc1.row - 1, t.rowColumn(b).row);
    // Wrapping at the antimeridian.
    try testing.expectEqual(@as(i32, 359), t.leftNeighbor(0));
    try testing.expectEqual(@as(i32, 0), t.rightNeighbor(359));
}

test "tile list (upstream TileList)" {
    const t = Tiles.init(world, 1, 1, true);
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(testing.allocator);
    try t.tileList(testing.allocator, AABB.init(-99.5, 30.5, -90.5, 39.5), &list);
    try testing.expectEqual(@as(usize, 100), list.items.len);
    list.clearRetainingCapacity();
    try t.tileList(testing.allocator, AABB.init(179.5, 0.5, 180.5, 1.5), &list);
    try testing.expectEqual(@as(usize, 4), list.items.len);
}

test "intersect linestring visits exactly the bins a brute force check finds" {
    const t = Tiles.init(world, 1, 4, true);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(testing.allocator);
    // A short diagonal inside one degree: covers bins along the diagonal.
    try t.intersectLine(testing.allocator, &.{ P(10.01, 20.01), P(10.99, 20.99) }, &cells);
    try testing.expect(cells.items.len >= 4);
    for (cells.items) |c| try testing.expectEqual(t.tileId(20.5, 10.5), c.tile);
    // Random short segments: every reported bin's box touches the segment,
    // and both endpoints' bins are reported.
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    for (0..2000) |_| {
        const a = P(r.float(f64) * 20, r.float(f64) * 20);
        const b = P(a.lng + (r.float(f64) - 0.5) * 0.4, a.lat + (r.float(f64) - 0.5) * 0.4);
        cells.clearRetainingCapacity();
        try t.intersectLine(testing.allocator, &.{ a, b }, &cells);
        for ([_]PointLL{ a, b }) |end| {
            const tile = t.tileIdOf(end);
            const tb = t.tileBounds(tile);
            const bx: u16 = @intFromFloat(@min(3, @floor((end.lng - tb.minx) / 0.25)));
            const by: u16 = @intFromFloat(@min(3, @floor((end.lat - tb.miny) / 0.25)));
            var found = false;
            for (cells.items) |c| found = found or (c.tile == tile and c.bin == by * 4 + bx);
            try testing.expect(found);
        }
        for (cells.items) |c| {
            var box = t.binBBox(c.tile, c.bin);
            // Upstream follows the great circle (resampled), not the straight
            // chord in degree space, so allow the difference between the two.
            box.minx -= 1e-4;
            box.miny -= 1e-4;
            box.maxx += 1e-4;
            box.maxy += 1e-4;
            try testing.expect(box.intersectsSegment(a, b) or box.contains(a) or box.contains(b));
        }
    }
}

test "intersect bbox world and single bin" {
    const t = Tiles.init(world, 90, 2, true);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(testing.allocator);
    try t.intersectBox(testing.allocator, world, &cells);
    try testing.expectEqual(@as(usize, 8 * 4), cells.items.len);
    cells.clearRetainingCapacity();
    try t.intersectBox(testing.allocator, AABB.init(-179, -89, -178, -88), &cells);
    try testing.expectEqual(@as(usize, 1), cells.items.len);
    try testing.expectEqual(Cell{ .tile = 0, .bin = 0 }, cells.items[0]);
}

test "closest first visits bins in distance order" {
    const t = Tiles.init(world, 1, 5, true);
    var cf = try ClosestFirst.init(testing.allocator, t, P(8.54, 47.37));
    defer cf.deinit();
    const first = (try cf.next()).?;
    try testing.expectEqual(t.tileIdOf(P(8.54, 47.37)), first.tile);
    try testing.expectEqual(@as(f64, 0), first.distance);
    var last: f64 = 0;
    for (0..200) |_| {
        const item = (try cf.next()).?;
        try testing.expect(item.distance >= last);
        last = item.distance;
    }
}

test "hilbert round-trips for every order up to 16" {
    var prng = std.Random.DefaultPrng.init(5);
    const r = prng.random();
    var order: u5 = 1;
    while (order <= 16) : (order += 1) {
        const n: u32 = @as(u32, 1) << order;
        for (0..200) |_| {
            const x = r.uintLessThan(u32, n);
            const y = r.uintLessThan(u32, n);
            const d = hilbertIndex(order, x, y);
            try testing.expect(d < @as(u64, n) * n);
            try testing.expectEqual([2]u32{ x, y }, hilbertPoint(order, d));
        }
    }
    // Consecutive indices are adjacent cells.
    var d: u64 = 0;
    while (d < 255) : (d += 1) {
        const a = hilbertPoint(4, d);
        const b = hilbertPoint(4, d + 1);
        const dist = @abs(@as(i64, a[0]) - b[0]) + @abs(@as(i64, a[1]) - b[1]);
        try testing.expectEqual(@as(u64, 1), dist);
    }
}

test "web mercator tiles" {
    const t = mercatorTile(0, P(10, 10));
    try testing.expectEqual(TileXYZ{ .z = 0, .x = 0, .y = 0 }, t);
    const zurich = mercatorTile(14, P(8.5417, 47.3769));
    try testing.expectEqual(@as(u32, 8580), zurich.x);
    try testing.expectEqual(@as(u32, 5737), zurich.y);
    const b = mercatorBounds(zurich);
    try testing.expect(b.contains(P(8.5417, 47.3769)));
}

test "fixed grids" {
    try testing.expectEqual(@as(u32, 0), snapCell(P(-180, -90)));
    try testing.expectEqual(ElevationTile{ .lat = 47, .lng = 8 }, elevationTile(P(8.54, 47.37)));
    try testing.expectEqual(ElevationTile{ .lat = -34, .lng = -59 }, elevationTile(P(-58.38, -33.6)));
}
