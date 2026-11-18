//! DEM sampling for /height and graph grades (port of Valhalla skadi).

const std = @import("std");
const PointLL = @import("../geo/point.zig").PointLL;
const Allocator = std.mem.Allocator;

pub const hgt = @import("hgt.zig");
pub const @"packed" = @import("packed.zig");

/// Where elevation comes from: loose .hgt tiles (upstream's layout) or a
/// pack built by `zr dem pack`. Both sample identically.
pub const Source = union(enum) {
    tiles: *hgt.Tiles,
    pack: *const @"packed".Pack,

    pub fn get(self: Source, p: PointLL) f64 {
        return switch (self) {
            .tiles => |t| hgt.get(t, p),
            .pack => |pk| pk.get(p),
        };
    }

    /// Samples in request order, one point after another.
    pub fn getAll(self: Source, pts: []const PointLL, out: []f64) void {
        switch (self) {
            .tiles => |t| hgt.getAll(t, pts, out),
            .pack => |pk| pk.getAll(pts, out),
        }
    }

    /// Samples many points so each block of a pack is decoded once: when
    /// the request jumps between 64x64-post blocks (scattered points rather
    /// than a path), the points are sorted by tile and block with a radix
    /// sort, sampled in that order, and the heights written back in request
    /// order. Paths are already local and skip the sort, and so do loose
    /// tiles: their posts are plain memory, and on an M3 Pro scattered points
    /// sample at about 20 ns each in request order against 35 ns sorted,
    /// while through a pack sorting takes them from about 13 us to 4 us.
    /// Every point goes through the same per-point code as `getAll`, so the
    /// results are identical. `scratch` is the request arena.
    pub fn getAllBatched(self: Source, scratch: Allocator, pts: []const PointLL, out: []f64) Allocator.Error!void {
        const n = pts.len;
        if (self == .tiles or n < 64 or n >= 1 << index_bits) return self.getAll(pts, out);
        var changes: usize = 0;
        var prev: u64 = std.math.maxInt(u64);
        for (pts) |p| {
            const k = blockKey(p);
            changes += @intFromBool(k != prev);
            prev = k;
        }
        // A path changes block every few dozen points; scattered points nearly every time.
        if (changes * 8 < n) return self.getAll(pts, out);

        const keys = try scratch.alloc(u64, n);
        const tmp = try scratch.alloc(u64, n);
        for (keys, pts, 0..) |*k, p, i| k.* = (blockKey(p) << index_bits) | i;
        radixSort(keys, tmp);
        const sorted = try scratch.alloc(PointLL, n);
        for (sorted, keys) |*s, k| s.* = pts[@intCast(k & index_mask)];
        const heights = try scratch.alloc(f64, n);
        self.getAll(sorted, heights);
        for (keys, heights) |k, h| out[@intCast(k & index_mask)] = h;
    }
};

const index_bits = 24;
const index_mask: u64 = (1 << index_bits) - 1;
/// Tile index (16 bits) and block within the tile (12 bits): the order the
/// samplers' memory is laid out in.
const key_bits = 28;

fn blockKey(p: PointLL) u64 {
    const tile = hgt.tileIndex(p);
    const lon = @floor(p.lng);
    const lat = @floor(p.lat);
    const u = (p.lng - lon) * (hgt.hgt_dim - 1);
    const v = (1.0 - (p.lat - lat)) * (hgt.hgt_dim - 1);
    // Out-of-range input (NaN, beyond the tile grid) keys to block 0; it is
    // only an ordering hint, the sampler handles such points itself.
    const bx: u64 = if (u >= 0 and u < hgt.hgt_dim) @as(u64, @intFromFloat(u)) / @"packed".block_dim else 0;
    const by: u64 = if (v >= 0 and v < hgt.hgt_dim) @as(u64, @intFromFloat(v)) / @"packed".block_dim else 0;
    return (@as(u64, @min(tile, 0xffff)) << 12) | (by * @"packed".blocks_per_side + bx);
}

/// LSD radix sort on the key bits above the index: two 14-bit passes.
fn radixSort(keys: []u64, tmp: []u64) void {
    const digit_bits = key_bits / 2;
    const buckets = 1 << digit_bits;
    var counts: [buckets]u32 = undefined;
    var src = keys;
    var dst = tmp;
    inline for (0..2) |pass| {
        const shift = index_bits + pass * digit_bits;
        @memset(&counts, 0);
        for (src) |k| counts[@intCast((k >> shift) & (buckets - 1))] += 1;
        var sum: u32 = 0;
        for (&counts) |*c| {
            const v = c.*;
            c.* = sum;
            sum += v;
        }
        for (src) |k| {
            const b: usize = @intCast((k >> shift) & (buckets - 1));
            dst[counts[b]] = k;
            counts[b] += 1;
        }
        const t = src;
        src = dst;
        dst = t;
    }
    // Two passes leave the result back in `keys`.
}

test "batched sampling equals point-by-point sampling on 10^6 points" {
    const gpa = std.testing.allocator;
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/zig-routing-batch-{d}", .{std.c.getpid()});
    hgt.mkdir(dir);
    defer hgt.rmTree(dir);
    try hgt.writeTile(gpa, dir, "N46E008.hgt.lz4", .lz4);
    try hgt.writeTile(gpa, dir, "N47E008.hgt", .raw);
    var tiles = try hgt.Tiles.init(gpa, dir);
    defer tiles.deinit();
    // Pack the two tiles: batching applies to packs.
    var path_buf: [300]u8 = undefined;
    const pack_path = try std.fmt.bufPrint(&path_buf, "{s}/t.zdem", .{dir});
    {
        var w = try @"packed".Writer.begin(gpa, pack_path);
        defer w.deinit();
        const indices = try tiles.indices(gpa);
        defer gpa.free(indices);
        const buf = try gpa.alloc(u8, hgt.hgt_bytes);
        defer gpa.free(buf);
        for (indices) |index| {
            try std.testing.expect(tiles.readTile(index, buf));
            var t = try @"packed".encodeTile(gpa, index, buf);
            defer t.deinit(gpa);
            try w.add(&t);
        }
        _ = try w.finish();
    }
    var pack = try @"packed".Pack.open(pack_path);
    defer pack.close();
    const source: Source = .{ .pack = &pack };
    const loose: Source = .{ .tiles = &tiles };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(21);
    const random = prng.random();
    var pts: [10_000]PointLL = undefined;
    var a: [10_000]f64 = undefined;
    var b: [10_000]f64 = undefined;
    var sorted_runs: usize = 0;
    // 100 rounds of 10^4 points, plus small requests below the batching floor.
    for (0..120) |round| {
        _ = arena_state.reset(.retain_capacity);
        const n = if (round >= 100) 1 + random.uintLessThan(usize, 100) else pts.len;
        for (pts[0..n], 0..) |*p, i| {
            if (round % 3 == 0) {
                // A path: consecutive points close together.
                const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                p.* = .{ .lng = 8.1 + 0.3 * t, .lat = 46.5 + 0.8 * t };
            } else {
                // Scattered, over both tiles, a missing one and the edges.
                p.* = .{ .lng = 7.9 + random.float(f64) * 1.3, .lat = 45.9 + random.float(f64) * 2.2 };
                if (i % 97 == 0) p.* = .{ .lng = 8.0, .lat = 48.0 };
                if (i % 89 == 0) p.* = .{ .lng = 8.5, .lat = 47.0 };
            }
        }
        source.getAll(pts[0..n], &a);
        try source.getAllBatched(arena_state.allocator(), pts[0..n], &b);
        for (a[0..n], b[0..n]) |x, y| try std.testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(y)));
        // And both equal the loose tiles (batched there is plain request order).
        try loose.getAllBatched(arena_state.allocator(), pts[0..n], &b);
        for (a[0..n], b[0..n]) |x, y| try std.testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(y)));
        if (round % 3 != 0 and round < 100) sorted_runs += 1;
    }
    try std.testing.expect(sorted_runs > 50);
}

test {
    std.testing.refAllDecls(@This());
}
