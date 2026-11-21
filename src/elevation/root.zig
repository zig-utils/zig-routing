//! DEM sampling for /height and graph grades (port of Valhalla skadi).

const std = @import("std");
const PointLL = @import("../geo/point.zig").PointLL;
const io = @import("../infra/io.zig");
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
    /// Contiguous groups use SIMD with the scalar rounding order. The request
    /// arena supplies the sort keys for scattered packed requests.
    pub fn getAllBatched(self: Source, scratch: Allocator, pts: []const PointLL, out: []f64) Allocator.Error!void {
        return self.getAllBatchedUntil(scratch, pts, out, .none) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.DeadlineExceeded => unreachable,
        };
    }

    pub fn getAllBatchedUntil(self: Source, scratch: Allocator, pts: []const PointLL, out: []f64, deadline: io.Deadline) (Allocator.Error || error{DeadlineExceeded})!void {
        const n = pts.len;
        if (self == .tiles) {
            if (n < 64) return hgt.getAllUntil(self.tiles, pts, out, deadline);
            var cursor: hgt.Sampler = .{ .tiles = self.tiles };
            defer cursor.deinit();
            return hgt.sampleAll(&cursor, pts, out, deadline);
        }
        const pack = self.pack;
        if (n < 64) {
            if (deadline.expired()) return error.DeadlineExceeded;
            return pack.getAll(pts, out);
        }
        var changes: usize = 0;
        var prev: u64 = std.math.maxInt(u64);
        for (pts, 0..) |p, i| {
            try checkDeadline(deadline, i);
            const k = blockKey(p);
            changes += @intFromBool(k != prev);
            if (changes * 8 >= n) break;
            prev = k;
        }
        // A path changes block every few dozen points; scattered points nearly every time.
        if (changes * 8 < n or n >= 1 << index_bits) {
            var cursor: @"packed".Sampler = .{ .pack = pack };
            return hgt.sampleAll(&cursor, pts, out, deadline);
        }

        const keys = try scratch.alloc(u64, n);
        const tmp = try scratch.alloc(u64, n);
        for (keys, pts, 0..) |*k, p, i| {
            try checkDeadline(deadline, i);
            k.* = (blockKey(p) << index_bits) | i;
        }
        try radixSort(keys, tmp, deadline);
        try sampleSorted(pack, pts, keys, out, deadline);
    }

    pub fn sampler(self: Source) Sampler {
        return switch (self) {
            .tiles => |tiles| .{ .tiles = .{ .tiles = tiles } },
            .pack => |pack| .{ .pack = .{ .pack = pack } },
        };
    }
};

pub const Sampler = union(enum) {
    tiles: hgt.Sampler,
    pack: @"packed".Sampler,

    pub fn deinit(self: *Sampler) void {
        if (self.* == .tiles) self.tiles.deinit();
    }

    pub fn get(self: *Sampler, point: PointLL) f64 {
        return self.getUntil(point, .none) catch unreachable;
    }

    pub fn getUntil(self: *Sampler, point: PointLL, deadline: io.Deadline) error{DeadlineExceeded}!f64 {
        return switch (self.*) {
            .tiles => |*tiles| tiles.getUntil(point, deadline),
            .pack => |*pack| pack.get(point),
        };
    }
};

const index_bits = 24;
const index_mask: u64 = (1 << index_bits) - 1;
/// Tile index (16 bits) and block within the tile (12 bits): the order the
/// samplers' memory is laid out in.
const key_bits = 28;

fn blockKey(p: PointLL) u64 {
    const pos = hgt.GridPosition.at(p);
    // Out-of-range input (NaN, beyond the tile grid) keys to block 0; it is
    // only an ordering hint, the sampler handles such points itself.
    const bx: u64 = if (pos.u >= 0 and pos.u < hgt.hgt_dim) @as(u64, @intFromFloat(pos.u)) / @"packed".block_dim else 0;
    const by: u64 = if (pos.v >= 0 and pos.v < hgt.hgt_dim) @as(u64, @intFromFloat(pos.v)) / @"packed".block_dim else 0;
    return (@as(u64, @min(pos.tile, 0xffff)) << 12) | (by * @"packed".blocks_per_side + bx);
}

inline fn checkDeadline(deadline: io.Deadline, i: usize) error{DeadlineExceeded}!void {
    if (i & 1023 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

fn sampleSorted(pack: *const @"packed".Pack, points: []const PointLL, keys: []const u64, out: []f64, deadline: io.Deadline) error{DeadlineExceeded}!void {
    var sampler: @"packed".Sampler = .{ .pack = pack };
    var start: usize = 0;
    var next_check: usize = 0;
    while (start < keys.len) {
        if (start >= next_check) {
            if (deadline.expired()) return error.DeadlineExceeded;
            next_check = start + 1024;
        }
        const block_key = keys[start] >> index_bits;
        var end = start + 1;
        while (end < @min(keys.len, next_check) and keys[end] >> index_bits == block_key) : (end += 1) {}
        if (end < keys.len) {
            const next = keys[end] >> index_bits;
            if (next != block_key) pack.prefetchBlock(@intCast(next >> 12), @intCast(next & 0xfff));
        }
        const available = sampler.select(@intCast(block_key >> 12));
        while (available and end - start >= hgt.batch_width) : (start += hgt.batch_width) {
            const group = keys[start..][0..hgt.batch_width];
            var positions: [hgt.batch_width]hgt.GridPosition = undefined;
            for (&positions, group) |*pos, key| pos.* = .at(points[@intCast(key & index_mask)]);
            const values = sampler.sampleBatch(&positions);
            for (group, values) |key, value| out[@intCast(key & index_mask)] = value;
        }
        for (keys[start..end]) |key| {
            const index: usize = @intCast(key & index_mask);
            out[index] = if (available) sampler.sample(.at(points[index])) else hgt.no_data_value;
        }
        start = end;
    }
}

/// LSD radix sort on the key bits above the index: two 14-bit passes.
fn radixSort(keys: []u64, tmp: []u64, deadline: io.Deadline) error{DeadlineExceeded}!void {
    const digit_bits = key_bits / 2;
    const buckets = 1 << digit_bits;
    var counts: [buckets]u32 = undefined;
    var src = keys;
    var dst = tmp;
    inline for (0..2) |pass| {
        const shift = index_bits + pass * digit_bits;
        @memset(&counts, 0);
        for (src, 0..) |k, i| {
            try checkDeadline(deadline, i);
            counts[@intCast((k >> shift) & (buckets - 1))] += 1;
        }
        var sum: u32 = 0;
        for (&counts, 0..) |*c, i| {
            try checkDeadline(deadline, i);
            const v = c.*;
            c.* = sum;
            sum += v;
        }
        for (src, 0..) |k, i| {
            try checkDeadline(deadline, i);
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
