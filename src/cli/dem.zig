//! `zr dem`: build, check and describe packed elevation (P2.04).
//!
//!   zr dem pack HGT_DIR OUT.zdem [--threads N]
//!   zr dem verify PACK HGT_DIR [--samples N] [--threads N]
//!   zr dem info PACK
//!
//! `pack` converts every .hgt, .hgt.gz and .hgt.lz4 tile under HGT_DIR,
//! tiles in parallel, written in tile order so the output is reproducible.
//! `verify` decodes every block (checking its CRC), compares every post with
//! the source tiles, checks that the pack holds exactly the source's tiles,
//! and compares N random samples per tile through both readers bit for bit.

const std = @import("std");
const io = @import("../infra/io.zig");
const hgt = @import("../elevation/hgt.zig");
const pk = @import("../elevation/packed.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const Allocator = std.mem.Allocator;

/// Runs `work(ctx, slot, index)` for every tile index, `threads` at a time,
/// then `done(ctx, slot, index)` for each in ascending order before the next
/// batch starts. `slot` is the worker's number (0..threads), for buffers.
fn forTiles(threads: usize, indices: []const u32, ctx: anytype, comptime work: fn (@TypeOf(ctx), usize, u32) void, comptime done: fn (@TypeOf(ctx), usize, u32) anyerror!void) !void {
    var start: usize = 0;
    var handles: [256]std.Thread = undefined;
    const n = @max(1, @min(threads, handles.len));
    while (start < indices.len) : (start += n) {
        const batch = indices[start..@min(indices.len, start + n)];
        for (batch, 0..) |index, slot| handles[slot] = try std.Thread.spawn(.{}, work, .{ ctx, slot, index });
        for (handles[0..batch.len]) |h| h.join();
        for (batch, 0..) |index, slot| try done(ctx, slot, index);
    }
}

pub fn threadCount(requested: ?usize) usize {
    if (requested) |count| if (count != 0) return count;
    return std.Thread.getCpuCount() catch 4;
}

// ---------------------------------------------------------------------------
// pack

const PackCtx = struct {
    gpa: Allocator,
    tiles: *const hgt.Tiles,
    buffers: [][]u8,
    results: []?pk.EncodedTile,
    failures: []?anyerror,
    writer: *pk.Writer,
    raw_bytes: u64 = 0,
    constant_tiles: usize = 0,

    fn work(self: *PackCtx, slot: usize, index: u32) void {
        self.results[slot] = null;
        self.failures[slot] = null;
        if (!self.tiles.readTile(index, self.buffers[slot])) {
            self.failures[slot] = error.TileDoesNotDecode;
            return;
        }
        self.results[slot] = pk.encodeTile(self.gpa, index, self.buffers[slot]) catch |e| {
            self.failures[slot] = e;
            return;
        };
    }

    fn done(self: *PackCtx, slot: usize, index: u32) !void {
        var name_buf: [32]u8 = undefined;
        if (self.failures[slot]) |e| {
            std.debug.print("{s}: {t}\n", .{ hgt.tileName(index, &name_buf), e });
            return e;
        }
        var t = self.results[slot].?;
        defer t.deinit(self.gpa);
        try self.writer.add(&t);
        self.raw_bytes += hgt.hgt_bytes;
        if (t.entry.kind == .constant) self.constant_tiles += 1;
    }
};

pub fn pack(gpa: Allocator, dir: []const u8, out: []const u8, threads: usize) !void {
    var tiles = try hgt.Tiles.init(gpa, dir);
    defer tiles.deinit();
    const indices = try tiles.indices(gpa);
    defer gpa.free(indices);
    if (indices.len == 0) {
        std.debug.print("no .hgt tiles under {s}\n", .{dir});
        return error.InvalidArgument;
    }
    const n = @min(threads, indices.len);
    const buffers = try gpa.alloc([]u8, n);
    defer gpa.free(buffers);
    var allocated: usize = 0;
    defer for (buffers[0..allocated]) |b| gpa.free(b);
    for (buffers) |*b| {
        b.* = try gpa.alloc(u8, hgt.hgt_bytes);
        allocated += 1;
    }
    const results = try gpa.alloc(?pk.EncodedTile, n);
    defer gpa.free(results);
    const failures = try gpa.alloc(?anyerror, n);
    defer gpa.free(failures);

    const timer = io.Timer.start();
    var writer = try pk.Writer.begin(gpa, out);
    defer writer.deinit();
    var ctx: PackCtx = .{ .gpa = gpa, .tiles = &tiles, .buffers = buffers, .results = results, .failures = failures, .writer = &writer };
    try forTiles(n, indices, &ctx, PackCtx.work, PackCtx.done);
    const header = try writer.finish();
    const secs = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
    const size = header.end_offset;
    std.debug.print("{d} tiles ({d} constant) packed into {s}: {d:.1} MB of {d:.1} MB raw ({d:.1}%, {d:.2} bits a post) in {d:.1}s on {d} threads\n", .{
        indices.len,
        ctx.constant_tiles,
        out,
        @as(f64, @floatFromInt(size)) / 1e6,
        @as(f64, @floatFromInt(ctx.raw_bytes)) / 1e6,
        100 * @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(ctx.raw_bytes)),
        8 * @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(indices.len * hgt.hgt_pixels)),
        secs,
        n,
    });
}

// ---------------------------------------------------------------------------
// verify

const VerifyCtx = struct {
    tiles: *const hgt.Tiles,
    pack: *const pk.Pack,
    buffers: [][]u8,
    failures: []?[]const u8,
    samples: usize,
    gpa: Allocator,
    posts_checked: u64 = 0,
    samples_checked: u64 = 0,
    failed: usize = 0,

    fn work(self: *VerifyCtx, slot: usize, index: u32) void {
        self.failures[slot] = self.check(slot, index) catch |e| @errorName(e);
    }

    fn check(self: *VerifyCtx, slot: usize, index: u32) !?[]const u8 {
        const buf = self.buffers[slot];
        if (!self.tiles.readTile(index, buf)) return "source tile does not decode";
        const e = self.pack.entry(index) orelse return "missing from the pack";
        const src = hgt.BigEndianPosts{ .data = buf };
        var posts: [pk.block_dim * pk.block_dim]i16 = undefined;
        for (0..pk.blocks_per_side) |br| for (0..pk.blocks_per_side) |bc| {
            self.pack.decodeChecked(e, br, bc, &posts) catch return "block CRC or payload is corrupt";
            const w = pk.blockSize(bc);
            for (0..pk.blockSize(br)) |r| for (0..w) |col| {
                if (src.sample((br * pk.block_dim + r) * pk.tile_dim + bc * pk.block_dim + col) != posts[r * w + col]) return "a post differs";
            };
        };
        // Samples through both readers, bit for bit.
        var prng = std.Random.DefaultPrng.init(index);
        const random = prng.random();
        const x: f64 = @floatFromInt(@as(i32, @intCast(index % 360)) - 180);
        const y: f64 = @floatFromInt(@as(i32, @intCast(index / 360)) - 90);
        for (0..self.samples) |_| {
            const p: PointLL = .{ .lng = x + random.float(f64), .lat = y + random.float(f64) };
            const u = (p.lng - x) * (hgt.hgt_dim - 1);
            const v = (1.0 - (p.lat - y)) * (hgt.hgt_dim - 1);
            const want = hgt.interpolate(buf, u, v);
            const got = self.pack.get(p);
            if (@as(u64, @bitCast(want)) != @as(u64, @bitCast(got))) return "a sample differs";
        }
        return null;
    }

    fn done(self: *VerifyCtx, slot: usize, index: u32) !void {
        if (self.failures[slot]) |why| {
            var name_buf: [32]u8 = undefined;
            std.debug.print("{s}: {s}\n", .{ hgt.tileName(index, &name_buf), why });
            self.failed += 1;
            return;
        }
        self.posts_checked += hgt.hgt_pixels;
        self.samples_checked += self.samples;
    }
};

pub fn verify(gpa: Allocator, pack_path: []const u8, dir: []const u8, samples: usize, threads: usize) !void {
    var p = try pk.Pack.open(pack_path);
    defer p.close();
    var tiles = try hgt.Tiles.init(gpa, dir);
    defer tiles.deinit();
    const indices = try tiles.indices(gpa);
    defer gpa.free(indices);

    var extra: usize = 0;
    for (p.entries) |e| {
        if (std.mem.indexOfScalar(u32, indices, e.tile) == null) {
            var name_buf: [32]u8 = undefined;
            std.debug.print("{s}: in the pack but not under {s}\n", .{ hgt.tileName(e.tile, &name_buf), dir });
            extra += 1;
        }
    }
    const n = @max(1, @min(threads, indices.len));
    const buffers = try gpa.alloc([]u8, n);
    defer gpa.free(buffers);
    var allocated: usize = 0;
    defer for (buffers[0..allocated]) |b| gpa.free(b);
    for (buffers) |*b| {
        b.* = try gpa.alloc(u8, hgt.hgt_bytes);
        allocated += 1;
    }
    const failures = try gpa.alloc(?[]const u8, n);
    defer gpa.free(failures);
    const timer = io.Timer.start();
    var ctx: VerifyCtx = .{ .tiles = &tiles, .pack = &p, .buffers = buffers, .failures = failures, .samples = samples, .gpa = gpa };
    try forTiles(n, indices, &ctx, VerifyCtx.work, VerifyCtx.done);
    const secs = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
    if (ctx.failed + extra > 0) {
        std.debug.print("FAIL: {d} of {d} tiles differ, {d} extra tiles in the pack\n", .{ ctx.failed, indices.len, extra });
        return error.VerifyFailed;
    }
    std.debug.print("ok: {d} tiles, {d} posts identical, {d} samples bit-identical ({d:.1}s)\n", .{ indices.len, ctx.posts_checked, ctx.samples_checked, secs });
}

// ---------------------------------------------------------------------------
// info

pub const Info = struct {
    path: []const u8,
    version: u32,
    bytes: u64,
    tiles: u32,
    constant_tiles: usize,
    predicted_blocks: usize,
    constant_blocks: usize,
    block_dim: u32,
    payload_bytes: u64,
    directory_bytes: u64,
    percent_raw: f64,
    bits_per_post: f64,
};

pub fn loadInfo(pack_path: []const u8) !Info {
    var p = try pk.Pack.open(pack_path);
    defer p.close();
    var constant_tiles: usize = 0;
    var constant_blocks: usize = 0;
    var predicted_blocks: usize = 0;
    var payload: u64 = 0;
    for (p.entries) |e| {
        if (e.kind == .constant) {
            constant_tiles += 1;
            continue;
        }
        for (p.blocks[e.first_block..][0..pk.blocks_per_tile]) |b| switch (b.kind) {
            .constant => constant_blocks += 1,
            else => {
                predicted_blocks += 1;
                payload += b.len;
            },
        };
    }
    const size = p.header.end_offset;
    const raw = @as(u64, p.header.tile_count) * hgt.hgt_bytes;
    return .{
        .path = pack_path,
        .version = p.header.version,
        .bytes = size,
        .tiles = p.header.tile_count,
        .constant_tiles = constant_tiles,
        .predicted_blocks = predicted_blocks,
        .constant_blocks = constant_blocks,
        .block_dim = pk.block_dim,
        .payload_bytes = payload,
        .directory_bytes = size - p.header.slots_offset,
        .percent_raw = 100 * @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(@max(raw, 1))),
        .bits_per_post = 8 * @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(@max(raw / 2, 1))),
    };
}

pub fn printInfo(info: Info) void {
    std.debug.print(
        \\{s}: packed DEM v{d}, {d} bytes
        \\  tiles      {d} ({d} constant)
        \\  blocks     {d} predicted, {d} constant ({d}x{d} posts)
        \\  payload    {d} bytes, directory {d} bytes
        \\  size       {d:.1}% of raw .hgt, {d:.2} bits a post
        \\
    , .{
        info.path,            info.version,   info.bytes,     info.tiles,         info.constant_tiles,  info.predicted_blocks,
        info.constant_blocks, info.block_dim, info.block_dim, info.payload_bytes, info.directory_bytes, info.percent_raw,
        info.bits_per_post,
    });
}

test "pack, verify and info on synthetic tiles" {
    const gpa = std.testing.allocator;
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/zig-routing-demcli-{d}", .{std.c.getpid()});
    hgt.mkdir(dir);
    defer hgt.rmTree(dir);
    try hgt.writeTile(gpa, dir, "N46E008.hgt.lz4", .lz4);
    try hgt.writeTile(gpa, dir, "N47E008.hgt", .raw);
    var out_buf: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(&out_buf, "{s}/x.zdem", .{dir});
    try pack(gpa, dir, out, 2);
    try verify(gpa, out, dir, 2000, 2);
    const info = try loadInfo(out);
    try std.testing.expectEqual(2, info.tiles);
    printInfo(info);
    // Verify against a directory missing one tile reports the extra tile.
    var lone_buf: [256]u8 = undefined;
    const lone = try std.fmt.bufPrint(&lone_buf, "{s}/N47", .{dir});
    hgt.mkdir(lone);
    var p_buf: [256]u8 = undefined;
    try hgt.writeTile(gpa, lone, "N47E008.hgt", .raw);
    try std.testing.expectError(error.VerifyFailed, verify(gpa, out, lone, 10, 1));
    var z_buf: [256]u8 = undefined;
    _ = std.c.unlink(try std.fmt.bufPrintSentinel(&z_buf, "{s}", .{out}, 0));
    _ = std.c.unlink(try std.fmt.bufPrintSentinel(&p_buf, "{s}/N47E008.hgt", .{lone}, 0));
}
