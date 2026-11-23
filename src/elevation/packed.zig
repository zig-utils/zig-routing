//! Packed elevation: our own lossless, block-compressed, memory-mappable
//! storage for SRTM posts (P2.04). The format is specified in
//! docs/formats/dem.md; the summary:
//!
//!   Header (64 B) | payload: encoded blocks, tile after tile | directory:
//!   tile slots (u32 per 1x1 degree tile), TileEntry per tile, BlockEntry per
//!   64x64 block of each tile
//!
//! A block stores its posts predicted from their west, north and north-west
//! neighbours (the LOCO-I median predictor, as in lossless JPEG-LS), the
//! prediction errors zigzag-coded and bit-packed in groups of 16 with one
//! width nibble per group. Constant blocks and tiles (sea, voids) carry no
//! payload. Every post decodes to exactly the source value, so sampling
//! through a pack is bit-identical to sampling the .hgt it came from.
//!
//! Reading a post costs one lookup in a small per-thread cache of decoded
//! blocks; a miss decodes one block (4096 posts) from the mapped file.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../infra/io.zig");
const hgt = @import("hgt.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const Allocator = std.mem.Allocator;

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("the packed DEM format is little-endian");
}

pub const magic = "ZRDEM\x00\x00\x01".*;
pub const version: u32 = 1;
pub const tile_dim = hgt.hgt_dim; // 3601
pub const block_dim = 64;
pub const blocks_per_side = (tile_dim + block_dim - 1) / block_dim; // 57
pub const blocks_per_tile = blocks_per_side * blocks_per_side; // 3249
/// Posts per group sharing one bit width.
pub const group = 16;

pub const Header = extern struct {
    magic: [8]u8,
    version: u32,
    tile_dim: u16,
    block_dim: u16,
    tile_count: u32,
    _reserved: u32 = 0,
    /// u32[hgt.tile_count]: 0 when the tile is absent, else 1 + its TileEntry index.
    slots_offset: u64,
    entries_offset: u64,
    blocks_offset: u64,
    /// End of the directory, which is the end of the file.
    end_offset: u64,
    /// XxHash3 of the directory: bytes [slots_offset, end_offset).
    directory_hash: u64,
};

pub const TileKind = enum(u8) { constant = 0, blocks = 1, _ };

pub const TileEntry = extern struct {
    tile: u32,
    kind: TileKind,
    _reserved: u8 = 0,
    /// The value of every post of a constant tile.
    constant: i16,
    /// Index of the tile's first BlockEntry (blocks_per_tile of them, row-major).
    first_block: u32,
    _reserved2: u32 = 0,
};

/// How a block is stored: one value, or prediction errors under one of two
/// predictors (the encoder keeps whichever is smaller for the block).
pub const BlockKind = enum(u8) { constant = 0, med = 1, plane = 2, _ };
pub const Predictor = enum { med, plane };

pub const BlockEntry = extern struct {
    /// Absolute file offset of the block's payload.
    offset: u64,
    len: u32,
    /// CRC-32 of the payload bytes.
    crc: u32,
    kind: BlockKind,
    _reserved: u8 = 0,
    constant: i16,
    _reserved2: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
    std.debug.assert(@sizeOf(TileEntry) == 16);
    std.debug.assert(@sizeOf(BlockEntry) == 24);
    std.debug.assert(@offsetOf(Header, "slots_offset") == 24);
    std.debug.assert(@offsetOf(BlockEntry, "kind") == 16);
}

/// Width and height in posts of block (br, bc): 64, or 17 on the east and
/// south edges (3601 = 56 * 64 + 17).
pub fn blockSize(b: usize) usize {
    return if (b == blocks_per_side - 1) tile_dim - (blocks_per_side - 1) * block_dim else block_dim;
}

// ---------------------------------------------------------------------------
// Block coding
// ---------------------------------------------------------------------------

inline fn zigzag(v: i16) u16 {
    return @bitCast((v << 1) ^ (v >> 15));
}

inline fn unzigzag(u: u16) i16 {
    return @as(i16, @bitCast(u >> 1)) ^ -@as(i16, @bitCast(u & 1));
}

/// LOCO-I median edge detector: min(a, b) above an edge, max below, else
/// the plane a + b - c (which then lies between a and b, so cannot overflow).
inline fn medPredict(a: i16, b: i16, c: i16) i16 {
    const mx = @max(a, b);
    const mn = @min(a, b);
    if (c >= mx) return mn;
    if (c <= mn) return mx;
    return a +% b -% c;
}

/// The prediction of post (r, col) from the posts before it: the west
/// neighbour on the first row, the north one in the first column, and inside
/// the block either the median edge detector or the plane a + b - c (which
/// is exact on a uniform slope, where the median predictor is off by one
/// step). Wrapping arithmetic keeps both lossless for any input.
inline fn predict(comptime p: Predictor, posts: []const i16, w: usize, r: usize, col: usize) i16 {
    const i = r * w + col;
    if (r == 0) return if (col == 0) 0 else posts[i - 1];
    if (col == 0) return posts[i - w];
    return switch (p) {
        .med => medPredict(posts[i - 1], posts[i - w], posts[i - w - 1]),
        .plane => posts[i - 1] +% posts[i - w] -% posts[i - w - 1],
    };
}

/// Worst-case payload of one block: every group at 16 bits plus widths.
pub const max_block_payload = (block_dim * block_dim / group + 1) / 2 + block_dim * block_dim * 2 + 8;

/// Encodes `posts` (w x h, row-major) into `out`; returns the payload length.
pub fn encodeBlock(comptime p: Predictor, posts: []const i16, w: usize, h: usize, out: []u8) usize {
    const n = w * h;
    std.debug.assert(posts.len == n and out.len >= max_block_payload);
    var codes: [block_dim * block_dim]u16 = undefined;
    for (0..h) |r| for (0..w) |col| {
        const i = r * w + col;
        codes[i] = zigzag(posts[i] -% predict(p, posts, w, r, col));
    };
    const groups = (n + group - 1) / group;
    const widths_len = (groups + 1) / 2;
    @memset(out[0..widths_len], 0);
    var acc: u64 = 0;
    var bits: u6 = 0;
    var pos = widths_len;
    for (0..groups) |g| {
        const lo = g * group;
        const hi = @min(n, lo + group);
        var max: u16 = 0;
        for (codes[lo..hi]) |c| max |= c;
        const need: u5 = if (max == 0) 0 else @intCast(16 - @clz(max));
        // Nibble codes 0..14 are widths; 15 means 16 bits.
        const nibble: u4 = if (need >= 15) 15 else @intCast(need);
        const width: u5 = if (nibble == 15) 16 else nibble;
        out[g / 2] |= @as(u8, nibble) << @intCast((g % 2) * 4);
        if (width == 0) continue;
        for (codes[lo..hi]) |c| {
            acc |= @as(u64, c) << bits;
            bits += @as(u6, width);
            while (bits >= 8) {
                out[pos] = @truncate(acc);
                pos += 1;
                acc >>= 8;
                bits -= 8;
            }
        }
    }
    if (bits > 0) {
        out[pos] = @truncate(acc);
        pos += 1;
    }
    return pos;
}

pub const DecodeError = error{CorruptBlock};

/// Decodes a payload written by `encodeBlock(p, ...)` into `posts` (w x h):
/// first the residuals (`unpackResiduals`), then the posts in wavefronts of
/// eight rows (`rebuildRows`). Exactly the posts and errors of
/// `decodeBlockScalar`, in less time (measurements on issue #42).
pub fn decodeBlockWith(comptime p: Predictor, payload: []const u8, w: usize, h: usize, posts: []i16) DecodeError!void {
    std.debug.assert(posts.len >= w * h);
    var residuals: [block_dim * block_dim]i16 = undefined;
    try unpackResiduals(payload, w * h, &residuals);
    rebuildRows(p, &residuals, w, h, posts);
}

/// Whether a payload holds every bit its widths call for: exactly when
/// `decodeBlockScalar` succeeds (it fails only by running out of bits), so a
/// lazy decode can check once and then never fail part way. Also writes each
/// group's first byte to `offsets` when given (meaningful only while every
/// earlier group is full, which holds in blocks a whole number of groups wide).
pub fn payloadFits(payload: []const u8, n: usize, offsets: ?*[block_dim * block_dim / group]u16) bool {
    const groups = (n + group - 1) / group;
    const widths_len = (groups + 1) / 2;
    if (payload.len < widths_len) return false;
    var bits: usize = 0;
    for (0..groups) |g| {
        if (offsets) |o| o[g] = @truncate(widths_len + bits / 8);
        const nibble: u4 = @truncate(payload[g / 2] >> @intCast((g % 2) * 4));
        const width: usize = if (nibble == 15) 16 else nibble;
        bits += width * (@min(n, (g + 1) * group) - g * group);
    }
    return bits <= 8 * (payload.len - widths_len);
}

/// Bytes the vector path may read from the start of a group: the last code
/// of a 16-bit group starts at byte 30 and is read as a u32 (up to byte 33).
const group_slack = 36;

/// The 16 zigzag codes of one full group at a comptime width, unzigzagged.
/// A full group is 16 * width bits = exactly 2 * width bytes, so it starts on
/// a byte boundary; one shuffle gathers each code's bytes into its own lane,
/// then a per-lane shift and mask isolate it. Reads `group_slack` bytes.
inline fn unpackGroup(comptime width: u5, src: *const [group_slack]u8, dst: *[group]i16) void {
    // A lane holds (bit % 8) + width <= 7 + width bits.
    const Lane = if (width <= 9) u16 else u32;
    const lane_bytes = @sizeOf(Lane);
    const gather = comptime blk: {
        @setEvalBranchQuota(10_000);
        var m: [group * lane_bytes]i32 = undefined;
        for (0..group) |j| for (0..lane_bytes) |k| {
            m[j * lane_bytes + k] = (j * width) / 8 + k;
        };
        break :blk m;
    };
    const shifts = comptime blk: {
        var v: [group]std.math.Log2Int(Lane) = undefined;
        for (0..group) |j| v[j] = (j * width) % 8;
        break :blk v;
    };
    const in: @Vector(group_slack, u8) = src.*;
    const bytes: @Vector(group * lane_bytes, u8) = @shuffle(u8, in, undefined, gather);
    const lanes: @Vector(group, Lane) = @bitCast(bytes);
    const mask: @Vector(group, Lane) = @splat((1 << width) - 1);
    const codes: @Vector(group, u16) = @truncate((lanes >> shifts) & mask);
    const one: @Vector(group, u16) = @splat(1);
    dst.* = @as(@Vector(group, i16), @bitCast(codes >> one)) ^ -@as(@Vector(group, i16), @bitCast(codes & one));
}

/// Stage 1 of a decode: the n residuals of a payload. Groups take the vector
/// path while `group_slack` bytes remain, so no read leaves the payload; the
/// last few go through the serial bit reader, which starts byte-aligned and
/// fails exactly where `decodeBlockScalar` does. A partial last group on the
/// vector path writes up to 15 residuals past n; they are never read.
fn unpackResiduals(payload: []const u8, n: usize, residuals: *[block_dim * block_dim]i16) DecodeError!void {
    const groups = (n + group - 1) / group;
    const widths_len = (groups + 1) / 2;
    if (payload.len < widths_len) return error.CorruptBlock;
    _ = try unpackGroups(payload, n, residuals, 0, groups, widths_len);
}

/// Groups [g_from, g_to) of a payload whose widths are already in bounds,
/// starting at byte `pos` (group g_from's first byte). Returns the first byte
/// of group g_to, so a later call can resume there: every group but the last
/// is a whole number of bytes.
fn unpackGroups(payload: []const u8, n: usize, residuals: *[block_dim * block_dim]i16, g_from: usize, g_to: usize, pos_from: usize) DecodeError!usize {
    var pos = pos_from;
    var g = g_from;
    while (g < g_to and pos + group_slack <= payload.len) : (g += 1) {
        const nibble: u4 = @truncate(payload[g / 2] >> @intCast((g % 2) * 4));
        const dst = residuals[g * group ..][0..group];
        const src = payload[pos..][0..group_slack];
        switch (nibble) {
            0 => dst.* = @splat(0),
            inline 1...14 => |width| unpackGroup(width, src, dst),
            15 => unpackGroup(16, src, dst),
        }
        pos += 2 * @as(usize, if (nibble == 15) 16 else nibble);
    }

    var acc: u64 = 0;
    var bits: u7 = 0;
    var i = g * group;
    while (g < g_to) : (g += 1) {
        const nibble: u4 = @truncate(payload[g / 2] >> @intCast((g % 2) * 4));
        const width: u5 = if (nibble == 15) 16 else nibble;
        const hi = @min(n, (g + 1) * group);
        if (width == 0) {
            @memset(residuals[i..hi], 0);
            i = hi;
            continue;
        }
        const mask: u64 = (@as(u64, 1) << width) - 1;
        while (i < hi) : (i += 1) {
            if (bits < width) {
                while (bits <= 56 and pos < payload.len) {
                    acc |= @as(u64, payload[pos]) << @as(u6, @intCast(bits));
                    pos += 1;
                    bits += 8;
                }
                if (bits < width) return error.CorruptBlock;
            }
            residuals[i] = unzigzag(@intCast(acc & mask));
            acc >>= @as(u6, width);
            bits -= width;
        }
    }
    // Whole bytes still in the accumulator belong to group g_to.
    return pos - bits / 8;
}

/// Rows rebuilt together by `rebuildStrip`: i16 x 8 fills one 128-bit
/// register (4 and 16 measured slower). `rebuildStripPair` runs two such
/// strips side by side.
const wave_rows = 8;

/// `medPredict` without selects: clamping c to [min(a, b), max(a, b)] is
/// the median of a, b and c, and a + b minus that median is min(a, b) when c
/// is above both, max(a, b) when below and else the plane, all in range, so
/// the wrapping sum is exact. The median is taken as max(min(a, c),
/// min(max(a, c), b)) so that only the last two steps wait on the north b.
inline fn medPredictVec(comptime V: type, west: V, north: V, north_west: V) V {
    const median = @max(@min(west, north_west), @min(@max(west, north_west), north));
    return west +% north -% median;
}

/// Stage 2 of a decode: the posts from their residuals, row 0 and then the
/// strips of `wave_rows` rows, two at a time under the median predictor.
fn rebuildRows(comptime p: Predictor, residuals: *const [block_dim * block_dim]i16, w: usize, h: usize, posts: []i16) void {
    rebuildFirstRow(residuals, 0, w, posts);
    var r0: usize = 1;
    while (r0 < h) : (r0 += wave_rows) switch (p) {
        .med => if (h - r0 > wave_rows and pairs(0, w)) {
            rebuildStripPair(residuals, w, r0, @min(wave_rows, h - r0 - wave_rows), 0, w, posts);
            r0 += wave_rows;
        } else rebuildStrip(residuals, w, r0, @min(wave_rows, h - r0), 0, w, posts),
        .plane => rebuildStripPlane(residuals, w, r0, @min(wave_rows, h - r0), 0, w, posts),
    };
}

/// Columns [c_from, c_to) of row 0, given columns [0, c_from) done: a
/// running sum of the residuals, eight at a time by `prefixSum`.
fn rebuildFirstRow(residuals: *const [block_dim * block_dim]i16, c_from: usize, c_to: usize, posts: []i16) void {
    var carry: i16 = if (c_from == 0) 0 else posts[c_from - 1];
    var col = c_from;
    while (col + wave_rows <= c_to) : (col += wave_rows) {
        const sum = prefixSum(residuals[col..][0..wave_rows].*) +% @as(@Vector(wave_rows, i16), @splat(carry));
        posts[col..][0..wave_rows].* = sum;
        carry = sum[wave_rows - 1];
    }
    while (col < c_to) : (col += 1) {
        carry +%= residuals[col];
        posts[col] = carry;
    }
}

/// The running (inclusive prefix) sums of a vector, in wrapping arithmetic.
inline fn prefixSum(v: @Vector(wave_rows, i16)) @Vector(wave_rows, i16) {
    var s = v;
    comptime var d = 1;
    inline while (d < wave_rows) : (d *= 2) s +%= std.simd.shiftElementsRight(s, d, 0);
    return s;
}

/// The plane predictor needs no wavefront. post = r + west + north -
/// north-west in every interior post, row 0 sums from the west and column 0
/// from the north, so in wrapping arithmetic the posts are the 2D running sum
/// of the residuals: each row is the row above plus the running sum of its
/// own residuals. Exactly the posts of the scalar recurrence, eight columns
/// at a time with no lane dependency but the carried sum.
///
/// Same contract as `rebuildStrip`: columns [c_from, c_to) of rows
/// [r0, r0 + rows), r0 >= 1, given the finished posts to the west and above;
/// the carried sum of a row starts as its difference from the row above in
/// column c_from - 1. `residuals` may be `posts` itself.
fn rebuildStripPlane(residuals: *const [block_dim * block_dim]i16, w: usize, r0: usize, rows: usize, c_from: usize, c_to: usize, posts: []i16) void {
    const K = wave_rows;
    const V = @Vector(K, i16);
    for (r0..r0 + rows) |r| {
        const row = r * w;
        const above = row - w;
        var carry: i16 = if (c_from == 0) 0 else posts[row + c_from - 1] -% posts[above + c_from - 1];
        var col = c_from;
        while (col + K <= c_to) : (col += K) {
            const sum = prefixSum(residuals[row + col ..][0..K].*) +% @as(V, @splat(carry));
            const north: V = posts[above + col ..][0..K].*;
            posts[row + col ..][0..K].* = north +% sum;
            carry = sum[K - 1];
        }
        while (col < c_to) : (col += 1) {
            carry +%= residuals[row + col];
            posts[row + col] = posts[above + col] +% carry;
        }
    }
}

/// The transpose of an 8 x 8 matrix of i16 rows: three rounds of
/// interleaving pairs of 16-, 32- and 64-bit units (lane pairs taken as
/// little-endian units by the bitcasts).
inline fn transpose8(m: [8]@Vector(8, i16)) [8]@Vector(8, i16) {
    comptime std.debug.assert(builtin.cpu.arch.endian() == .little and wave_rows == 8);
    const V = @Vector(8, i16);
    const W = @Vector(4, u32);
    const Q = @Vector(2, u64);
    var a: [8]V = undefined;
    inline for (0..4) |i| {
        a[2 * i] = @shuffle(i16, m[2 * i], m[2 * i + 1], [8]i32{ 0, -1, 2, -3, 4, -5, 6, -7 });
        a[2 * i + 1] = @shuffle(i16, m[2 * i], m[2 * i + 1], [8]i32{ 1, -2, 3, -4, 5, -6, 7, -8 });
    }
    var b: [8]W = undefined;
    inline for (0..2) |h| inline for (0..2) |j| {
        const x: W = @bitCast(a[4 * h + j]);
        const y: W = @bitCast(a[4 * h + j + 2]);
        b[4 * h + j] = @shuffle(u32, x, y, [4]i32{ 0, -1, 2, -3 });
        b[4 * h + j + 2] = @shuffle(u32, x, y, [4]i32{ 1, -2, 3, -4 });
    };
    // b[0..4] hold columns {0, 4}, {1, 5}, {2, 6}, {3, 7} of rows 0..3,
    // b[4..8] the same of rows 4..7.
    var out: [8]V = undefined;
    inline for (0..4) |j| {
        const x: Q = @bitCast(b[j]);
        const y: Q = @bitCast(b[j + 4]);
        out[j] = @bitCast(@shuffle(u64, x, y, [2]i32{ 0, -1 }));
        out[j + 4] = @bitCast(@shuffle(u64, x, y, [2]i32{ 1, -2 }));
    }
    return out;
}

/// The median predictor, row by row, makes each post wait on its west
/// neighbour. Instead a strip of `wave_rows` rows runs as a wavefront: at
/// step t, lane k rebuilds post (r0 + k, c_from + t - k), so its west is its
/// own lane at step t - 1, its north is lane k - 1 at step t - 1 (the row
/// above for lane 0) and its north-west is lane k - 1 at step t - 2. Same
/// predictions in the same wrapping arithmetic, so the same posts.
///
/// Rebuilds columns [c_from, c_to) of rows [r0, r0 + rows), given columns
/// [0, c_from) of those rows and [0, c_to) of row r0 - 1 done, so a block can
/// be rebuilt in pieces. At column c_from a lane takes its west and
/// north-west from the finished columns, or in column 0 predicts from its
/// north neighbour alone. `residuals` may be `posts` itself: each post is
/// read as a residual before it is written, and only finished posts are read
/// as neighbours.
fn rebuildStrip(residuals: *const [block_dim * block_dim]i16, w: usize, r0: usize, rows: usize, c_from: usize, c_to: usize, posts: []i16) void {
    if (c_to - c_from < wave_rows) return rebuildStripNarrow(residuals, w, r0, rows, c_from, c_to, posts);
    if (rows == wave_rows) return rebuildWave(wave_rows, residuals, w, r0, rows, c_from, c_to, posts);
    rebuildWave(null, residuals, w, r0, rows, c_from, c_to, posts);
}

/// How a tile of `wave_rows` steps meets its strip: the ramp up (steps
/// 0..K-1, lane k live from step k), every lane live, or the ramp down
/// (steps width..width+K-2, lane k >= 1 live through step k - 1 of them).
const Tile = enum { up, mid, down };

/// One strip's wavefront, `wave_rows` steps at a time: lane k's residuals
/// for steps t..t+K-1 are K consecutive ones of its row, so K row loads and
/// a transpose replace K lane-by-lane gathers, and the posts go back the
/// same way. In a ramp the lanes outside the strip compute values no live
/// lane reads, and their posts are blended out before the store. Lanes past
/// `rows` load zeros and store nothing. The methods are inline so that a
/// comptime `rows` folds the lane checks.
const Wave = struct {
    const K = wave_rows;
    const V = @Vector(K, i16);
    const M = @Vector(K, bool);
    const lane = std.simd.iota(u8, K);

    /// The posts of the last step, and its north: the next step's north-west.
    prev: V = @splat(0),
    north: V = @splat(0),
    /// West and north-west of each lane's first post, when not in column 0.
    west_in: V = @splat(0),
    north_west_in: V = @splat(0),
    /// The tile's residuals by step (after `load`), then its posts by step.
    in: [K]V = @splat(@splat(0)),
    cur: [K]V = @splat(@splat(0)),

    inline fn init(posts: []const i16, w: usize, r0: usize, rows: usize, c_from: usize) Wave {
        var self: Wave = .{};
        if (c_from > 0) inline for (0..K) |k| if (k < rows) {
            self.west_in[k] = posts[(r0 + k) * w + c_from - 1];
            self.north_west_in[k] = posts[(r0 + k - 1) * w + c_from - 1];
        };
        return self;
    }

    /// The residuals of a tile. `c` is c_from for the ramp up, the column
    /// of lane 0's first step otherwise, and c_to for the ramp down. Each
    /// row loads K columns inside the strip, moved so that lane j is step j.
    inline fn load(self: *Wave, comptime tile: Tile, residuals: *const [block_dim * block_dim]i16, w: usize, r0: usize, rows: usize, c: usize) void {
        inline for (0..K) |k| if (k < rows) switch (tile) {
            .up => self.in[k] = std.simd.shiftElementsRight(@as(V, residuals[(r0 + k) * w + c ..][0..K].*), k, 0),
            .mid => self.in[k] = residuals[(r0 + k) * w + c - k ..][0..K].*,
            .down => if (k > 0) {
                self.in[k] = std.simd.shiftElementsLeft(@as(V, residuals[(r0 + k) * w + c - K ..][0..K].*), K - k, 0);
            },
        };
        self.in = transpose8(self.in);
    }

    /// Step i of a tile, `top` the north of lane 0 (the row above).
    inline fn step(self: *Wave, comptime tile: Tile, comptime i: usize, column0: bool, top: i16) void {
        const north = std.simd.shiftElementsRight(self.prev, 1, top);
        const pred = if (tile == .up) blk: {
            const first: M = lane == @as(@Vector(K, u8), @splat(i));
            break :blk if (column0)
                @select(i16, first, north, medPredictVec(V, self.prev, north, self.north))
            else
                medPredictVec(V, @select(i16, first, self.west_in, self.prev), north, @select(i16, first, self.north_west_in, self.north));
        } else medPredictVec(V, self.prev, north, self.north);
        self.cur[i] = self.in[i] +% pred;
        self.north = north;
        self.prev = self.cur[i];
    }

    /// The posts of a tile, at the columns `load` read.
    inline fn store(self: *Wave, comptime tile: Tile, posts: []i16, w: usize, r0: usize, rows: usize, c: usize) void {
        const out = transpose8(self.cur);
        inline for (0..K) |k| if (k < rows) switch (tile) {
            .up => {
                // Lane j of row k is column c + j - k: live for j >= k.
                const dst = posts[(r0 + k) * w + c ..][0..K];
                const live: M = lane < @as(@Vector(K, u8), @splat(K - k));
                dst.* = @select(i16, live, std.simd.shiftElementsLeft(out[k], k, 0), dst.*);
            },
            .mid => posts[(r0 + k) * w + c - k ..][0..K].* = out[k],
            .down => if (k > 0) {
                // Lane j of row k is column c - K + j: live for j >= K - k.
                const dst = posts[(r0 + k) * w + c - K ..][0..K];
                const live: M = lane >= @as(@Vector(K, u8), @splat(K - k));
                dst.* = @select(i16, live, std.simd.shiftElementsRight(out[k], K - k, 0), dst.*);
            },
        };
    }

    /// One step with every lane live, lane by lane: lane 0 at column c.
    inline fn single(self: *Wave, residuals: *const [block_dim * block_dim]i16, posts: []i16, w: usize, r0: usize, rows: usize, c: usize, top: i16) void {
        const north = std.simd.shiftElementsRight(self.prev, 1, top);
        var r: V = @splat(0);
        inline for (0..K) |k| if (k < rows) {
            r[k] = residuals[(r0 + k) * w + (c - k)];
        };
        const cur = r +% medPredictVec(V, self.prev, north, self.north);
        inline for (0..K) |k| if (k < rows) {
            posts[(r0 + k) * w + (c - k)] = cur[k];
        };
        self.north = north;
        self.prev = cur;
    }
};

/// `rebuildStrip` at least `wave_rows` wide, `rows` comptime when `full`
/// is given: the ramp up, every-lane tiles, single steps for the columns
/// left over, and the ramp down.
fn rebuildWave(comptime full: ?usize, residuals: *const [block_dim * block_dim]i16, w: usize, r0: usize, rows_in: usize, c_from: usize, c_to: usize, posts: []i16) void {
    @setEvalBranchQuota(10_000);
    const K = wave_rows;
    const rows = full orelse rows_in;
    const width = c_to - c_from;
    const above = (r0 - 1) * w;
    var a = Wave.init(posts, w, r0, rows, c_from);
    a.load(.up, residuals, w, r0, rows, c_from);
    inline for (0..K) |i| a.step(.up, i, c_from == 0, posts[above + c_from + i]);
    a.store(.up, posts, w, r0, rows, c_from);
    var t: usize = K;
    while (t + K <= width) : (t += K) {
        const c = c_from + t;
        a.load(.mid, residuals, w, r0, rows, c);
        inline for (0..K) |i| a.step(.mid, i, false, posts[above + c + i]);
        a.store(.mid, posts, w, r0, rows, c);
    }
    while (t < width) : (t += 1) a.single(residuals, posts, w, r0, rows, c_from + t, posts[above + c_from + t]);
    a.load(.down, residuals, w, r0, rows, c_to);
    inline for (0..K - 1) |i| a.step(.down, i, false, 0);
    a.store(.down, posts, w, r0, rows, c_to);
}

/// Whether `rebuildStripPair` takes a strip of `wave_rows` rows and the
/// strip below it over these columns.
inline fn pairs(c_from: usize, c_to: usize) bool {
    return c_to - c_from >= wave_rows and (c_to - c_from) % wave_rows == 0;
}

/// Two strips at once over the same columns: `rebuildStrip` of rows
/// [r0, r0 + K) and then of [r0 + K, r0 + K + rows_below), as one wavefront
/// of 2K lanes. The lower strip runs one tile behind, its lane 0 taking the
/// north from the upper strip's lane K - 1 one step before, still in a
/// register. The two strips' steps do not wait on each other within a step,
/// so their latencies overlap. The width is a whole number of tiles (see
/// `pairs`), so the tiles of both line up.
fn rebuildStripPair(residuals: *const [block_dim * block_dim]i16, w: usize, r0: usize, rows_below: usize, c_from: usize, c_to: usize, posts: []i16) void {
    if (rows_below == wave_rows) return rebuildPair(wave_rows, residuals, w, r0, rows_below, c_from, c_to, posts);
    rebuildPair(null, residuals, w, r0, rows_below, c_from, c_to, posts);
}

fn rebuildPair(comptime full: ?usize, residuals: *const [block_dim * block_dim]i16, w: usize, r0: usize, rows_in: usize, c_from: usize, c_to: usize, posts: []i16) void {
    @setEvalBranchQuota(10_000);
    const K = wave_rows;
    const rows = full orelse rows_in;
    const width = c_to - c_from;
    std.debug.assert(pairs(c_from, c_to));
    const above = (r0 - 1) * w;
    const r1 = r0 + K;
    const column0 = c_from == 0;
    var a = Wave.init(posts, w, r0, K, c_from);
    var b = Wave.init(posts, w, r1, rows, c_from);
    // The upper ramp up alone.
    a.load(.up, residuals, w, r0, K, c_from);
    inline for (0..K) |i| a.step(.up, i, column0, posts[above + c_from + i]);
    a.store(.up, posts, w, r0, K, c_from);
    // The lower ramp up beside the upper's second tile (or ramp down).
    b.load(.up, residuals, w, r1, rows, c_from);
    if (width == K) {
        a.load(.down, residuals, w, r0, K, c_to);
        inline for (0..K) |i| {
            b.step(.up, i, column0, a.prev[K - 1]);
            if (i < K - 1) a.step(.down, i, false, 0);
        }
        a.store(.down, posts, w, r0, K, c_to);
        b.store(.up, posts, w, r1, rows, c_from);
    } else {
        a.load(.mid, residuals, w, r0, K, c_from + K);
        inline for (0..K) |i| {
            b.step(.up, i, column0, a.prev[K - 1]);
            a.step(.mid, i, false, posts[above + c_from + K + i]);
        }
        a.store(.mid, posts, w, r0, K, c_from + K);
        b.store(.up, posts, w, r1, rows, c_from);
        var t: usize = 2 * K;
        while (t < width) : (t += K) {
            const c = c_from + t;
            a.load(.mid, residuals, w, r0, K, c);
            b.load(.mid, residuals, w, r1, rows, c - K);
            inline for (0..K) |i| {
                b.step(.mid, i, false, a.prev[K - 1]);
                a.step(.mid, i, false, posts[above + c + i]);
            }
            a.store(.mid, posts, w, r0, K, c);
            b.store(.mid, posts, w, r1, rows, c - K);
        }
        // The upper ramp down beside the lower's last full tile.
        a.load(.down, residuals, w, r0, K, c_to);
        b.load(.mid, residuals, w, r1, rows, c_to - K);
        inline for (0..K) |i| {
            b.step(.mid, i, false, a.prev[K - 1]);
            if (i < K - 1) a.step(.down, i, false, 0);
        }
        a.store(.down, posts, w, r0, K, c_to);
        b.store(.mid, posts, w, r1, rows, c_to - K);
    }
    // The lower ramp down alone.
    b.load(.down, residuals, w, r1, rows, c_to);
    inline for (0..K - 1) |i| b.step(.down, i, false, 0);
    b.store(.down, posts, w, r1, rows, c_to);
}

/// `rebuildStrip` one step at a time, lane by lane: for strips narrower than
/// a wavefront, where the K-step tiles would reach outside the strip.
fn rebuildStripNarrow(residuals: *const [block_dim * block_dim]i16, w: usize, r0: usize, rows: usize, c_from: usize, c_to: usize, posts: []i16) void {
    const K = wave_rows;
    const V = @Vector(K, i16);
    const width = c_to - c_from;
    if (width == 0) return;
    const lane: @Vector(K, i32) = std.simd.iota(i32, K);
    const above = (r0 - 1) * w;
    var west_in: V = @splat(0);
    var north_west_in: V = @splat(0);
    if (c_from > 0) {
        inline for (0..K) |k| {
            if (k < rows) {
                west_in[k] = posts[(r0 + k) * w + c_from - 1];
                north_west_in[k] = posts[(r0 + k - 1) * w + c_from - 1];
            }
        }
    }
    var prev: V = @splat(0);
    var prev2: V = @splat(0);
    const steps = width + rows - 1;
    for (0..steps) |t| {
        // Lanes outside the range stay dead, and a lane at its first column
        // takes its west from the finished columns, or in column 0 predicts
        // from its north neighbour alone.
        const step: @Vector(K, i32) = @as(@Vector(K, i32), @splat(@intCast(t))) - lane;
        const first = step == @as(@Vector(K, i32), @splat(0));
        const c = c_from + t;
        const top: i16 = if (t < width) posts[above + c] else 0;
        const top_west: i16 = if (c >= 1 and t < width) posts[above + c - 1] else 0;
        const north = std.simd.shiftElementsRight(prev, 1, top);
        var north_west = std.simd.shiftElementsRight(prev2, 1, top_west);
        const pred = if (c_from == 0)
            @select(i16, first, north, medPredictVec(V, prev, north, north_west))
        else blk: {
            north_west = @select(i16, first, north_west_in, north_west);
            break :blk medPredictVec(V, @select(i16, first, west_in, prev), north, north_west);
        };
        var r: V = @splat(0);
        inline for (0..K) |k| {
            if (k < rows and t >= k and t - k < width) r[k] = residuals[(r0 + k) * w + (c - k)];
        }
        const cur = r +% pred;
        inline for (0..K) |k| {
            if (k < rows and t >= k and t - k < width) posts[(r0 + k) * w + (c - k)] = cur[k];
        }
        prev2 = prev;
        prev = cur;
    }
}

/// The reference decoder: a serial bit reader, then the posts row by row.
/// `decodeBlockWith` must match it exactly, posts and errors; the tests and
/// the `dem` fuzz target hold it to that.
pub fn decodeBlockScalar(comptime p: Predictor, payload: []const u8, w: usize, h: usize, posts: []i16) DecodeError!void {
    const n = w * h;
    std.debug.assert(posts.len >= n);
    const groups = (n + group - 1) / group;
    const widths_len = (groups + 1) / 2;
    if (payload.len < widths_len) return error.CorruptBlock;

    var codes: [block_dim * block_dim]u16 = undefined;
    var acc: u64 = 0;
    var bits: u7 = 0;
    var pos = widths_len;
    var i: usize = 0;
    for (0..groups) |g| {
        const nibble: u4 = @truncate(payload[g / 2] >> @intCast((g % 2) * 4));
        const width: u5 = if (nibble == 15) 16 else nibble;
        const hi = @min(n, (g + 1) * group);
        if (width == 0) {
            @memset(codes[i..hi], 0);
            i = hi;
            continue;
        }
        const mask: u64 = (@as(u64, 1) << width) - 1;
        while (i < hi) : (i += 1) {
            if (bits < width) {
                // Refill whole bytes while they fit in the accumulator.
                while (bits <= 56 and pos < payload.len) {
                    acc |= @as(u64, payload[pos]) << @as(u6, @intCast(bits));
                    pos += 1;
                    bits += 8;
                }
                if (bits < width) return error.CorruptBlock;
            }
            codes[i] = @intCast(acc & mask);
            acc >>= @as(u6, width);
            bits -= width;
        }
    }

    posts[0] = unzigzag(codes[0]);
    for (1..w) |col| posts[col] = unzigzag(codes[col]) +% posts[col - 1];
    for (1..h) |r| {
        const base = r * w;
        posts[base] = unzigzag(codes[base]) +% posts[base - w];
        for (base + 1..base + w) |j| {
            const pred = switch (p) {
                .med => medPredict(posts[j - 1], posts[j - w], posts[j - w - 1]),
                .plane => posts[j - 1] +% posts[j - w] -% posts[j - w - 1],
            };
            posts[j] = unzigzag(codes[j]) +% pred;
        }
    }
}

/// Decodes a stored block of either predicted kind.
pub fn decodeBlock(kind: BlockKind, payload: []const u8, w: usize, h: usize, posts: []i16) DecodeError!void {
    return switch (kind) {
        .med => decodeBlockWith(.med, payload, w, h, posts),
        .plane => decodeBlockWith(.plane, payload, w, h, posts),
        else => error.CorruptBlock,
    };
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// One tile, encoded: its entry, its blocks (offsets relative to the start
/// of `payload`) and the payload bytes.
pub const EncodedTile = struct {
    entry: TileEntry,
    blocks: []BlockEntry,
    payload: std.ArrayList(u8),

    pub fn deinit(self: *EncodedTile, gpa: Allocator) void {
        gpa.free(self.blocks);
        self.payload.deinit(gpa);
    }
};

/// Encodes one unpacked .hgt tile (big-endian bytes).
pub fn encodeTile(gpa: Allocator, index: u32, hgt_bytes: []const u8) Allocator.Error!EncodedTile {
    std.debug.assert(hgt_bytes.len == hgt.hgt_bytes);
    const src = hgt.BigEndianPosts{ .data = hgt_bytes };
    const first = src.sample(0);
    var constant = true;
    for (0..hgt.hgt_pixels) |i| if (src.sample(i) != first) {
        constant = false;
        break;
    };
    if (constant) return .{
        .entry = .{ .tile = index, .kind = .constant, .constant = first, .first_block = 0 },
        .blocks = &.{},
        .payload = .empty,
    };

    const blocks = try gpa.alloc(BlockEntry, blocks_per_tile);
    errdefer gpa.free(blocks);
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(gpa);
    var posts: [block_dim * block_dim]i16 = undefined;
    var buf: [max_block_payload]u8 = undefined;
    var alt: [max_block_payload]u8 = undefined;
    for (0..blocks_per_side) |br| for (0..blocks_per_side) |bc| {
        const w = blockSize(bc);
        const h = blockSize(br);
        for (0..h) |r| for (0..w) |col| {
            posts[r * w + col] = src.sample((br * block_dim + r) * tile_dim + bc * block_dim + col);
        };
        const p = posts[0 .. w * h];
        const e = &blocks[br * blocks_per_side + bc];
        if (std.mem.allEqual(i16, p, p[0])) {
            e.* = .{ .offset = 0, .len = 0, .crc = 0, .kind = .constant, .constant = p[0] };
            continue;
        }
        const med_len = encodeBlock(.med, p, w, h, &buf);
        const plane_len = encodeBlock(.plane, p, w, h, &alt);
        const kind: BlockKind, const bytes = if (plane_len < med_len) .{ .plane, alt[0..plane_len] } else .{ .med, buf[0..med_len] };
        e.* = .{ .offset = payload.items.len, .len = @intCast(bytes.len), .crc = std.hash.Crc32.hash(bytes), .kind = kind, .constant = 0 };
        try payload.appendSlice(gpa, bytes);
    };
    return .{ .entry = .{ .tile = index, .kind = .blocks, .constant = 0, .first_block = 0 }, .blocks = blocks, .payload = payload };
}

/// Streams a pack to a file: `begin`, `add` each tile in ascending tile
/// order, then `finish`, which writes the directory and the header.
pub const Writer = struct {
    gpa: Allocator,
    file: io.File,
    offset: u64 = @sizeOf(Header),
    entries: std.ArrayList(TileEntry) = .empty,
    blocks: std.ArrayList(BlockEntry) = .empty,

    pub fn begin(gpa: Allocator, path: []const u8) !Writer {
        const file = try io.File.open(path, .create_truncate);
        errdefer file.close();
        try file.writeAll(&@as([@sizeOf(Header)]u8, @splat(0)));
        return .{ .gpa = gpa, .file = file };
    }

    pub fn deinit(self: *Writer) void {
        self.entries.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
        self.file.close();
    }

    pub fn add(self: *Writer, t: *const EncodedTile) !void {
        if (self.entries.items.len > 0) std.debug.assert(t.entry.tile > self.entries.items[self.entries.items.len - 1].tile);
        var entry = t.entry;
        entry.first_block = @intCast(self.blocks.items.len);
        try self.entries.append(self.gpa, entry);
        for (t.blocks) |b| {
            var abs = b;
            if (b.kind != .constant) abs.offset += self.offset;
            try self.blocks.append(self.gpa, abs);
        }
        try self.file.writeAll(t.payload.items);
        self.offset += t.payload.items.len;
    }

    pub fn finish(self: *Writer) !Header {
        // The directory starts 8-byte aligned.
        const pad = (8 - self.offset % 8) % 8;
        try self.file.writeAll((&@as([8]u8, @splat(0)))[0..pad]);
        self.offset += pad;

        const slots = try self.gpa.alloc(u32, hgt.tile_count);
        defer self.gpa.free(slots);
        @memset(slots, 0);
        for (self.entries.items, 0..) |e, i| slots[e.tile] = @intCast(i + 1);
        const slot_bytes = std.mem.sliceAsBytes(slots);
        const entry_bytes = std.mem.sliceAsBytes(self.entries.items);
        const block_bytes = std.mem.sliceAsBytes(self.blocks.items);
        var hasher = std.hash.XxHash3.init(0);
        hasher.update(slot_bytes);
        hasher.update(entry_bytes);
        hasher.update(block_bytes);

        const h: Header = .{
            .magic = magic,
            .version = version,
            .tile_dim = tile_dim,
            .block_dim = block_dim,
            .tile_count = @intCast(self.entries.items.len),
            .slots_offset = self.offset,
            .entries_offset = self.offset + slot_bytes.len,
            .blocks_offset = self.offset + slot_bytes.len + entry_bytes.len,
            .end_offset = self.offset + slot_bytes.len + entry_bytes.len + block_bytes.len,
            .directory_hash = hasher.final(),
        };
        try self.file.writeAll(slot_bytes);
        try self.file.writeAll(entry_bytes);
        try self.file.writeAll(block_bytes);
        try self.file.pwriteAll(std.mem.asBytes(&h), 0);
        return h;
    }
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

pub const OpenError = io.Error || error{ NotAPack, UnsupportedVersion, CorruptDirectory };

pub const Pack = struct {
    map: io.Mapping,
    header: Header,
    slots: []const u32,
    entries: []const TileEntry,
    blocks: []const BlockEntry,
    /// Distinguishes packs in the shared per-thread cache.
    id: u32,

    var next_id: std.atomic.Value(u32) = .init(1);

    pub fn open(path: []const u8) OpenError!Pack {
        const map = try io.Mapping.mapFile(path, .read_only);
        errdefer map.unmap();
        return fromMapping(map);
    }

    /// Validates the header and directory of a mapped pack.
    pub fn fromMapping(map: io.Mapping) OpenError!Pack {
        const bytes = map.bytes;
        if (bytes.len < @sizeOf(Header)) return error.NotAPack;
        var h: Header = undefined;
        @memcpy(std.mem.asBytes(&h), bytes[0..@sizeOf(Header)]);
        if (!std.mem.eql(u8, &h.magic, &magic)) return error.NotAPack;
        if (h.version != version) return error.UnsupportedVersion;
        if (h.tile_dim != tile_dim or h.block_dim != block_dim) return error.UnsupportedVersion;
        const slot_len = hgt.tile_count * @sizeOf(u32);
        const entry_len = @as(u64, h.tile_count) * @sizeOf(TileEntry);
        if (h.slots_offset % 8 != 0 or h.end_offset != bytes.len or
            h.entries_offset != h.slots_offset + slot_len or
            h.blocks_offset != h.entries_offset + entry_len or
            h.blocks_offset > h.end_offset or (h.end_offset - h.blocks_offset) % @sizeOf(BlockEntry) != 0)
            return error.CorruptDirectory;
        const dir = bytes[@intCast(h.slots_offset)..@intCast(h.end_offset)];
        if (std.hash.XxHash3.hash(0, dir) != h.directory_hash) return error.CorruptDirectory;

        const slots = try io.typedSlice(u32, bytes, @intCast(h.slots_offset), hgt.tile_count);
        const entries = try io.typedSlice(TileEntry, bytes, @intCast(h.entries_offset), h.tile_count);
        const blocks = try io.typedSlice(BlockEntry, bytes, @intCast(h.blocks_offset), @intCast((h.end_offset - h.blocks_offset) / @sizeOf(BlockEntry)));
        // Every reference stays inside the file, so readers never check again.
        for (slots) |s| if (s > entries.len) return error.CorruptDirectory;
        for (entries) |e| {
            if (e.tile >= hgt.tile_count or slots[e.tile] == 0 or entries[slots[e.tile] - 1].tile != e.tile) return error.CorruptDirectory;
            switch (e.kind) {
                .constant => {},
                .blocks => if (@as(u64, e.first_block) + blocks_per_tile > blocks.len) return error.CorruptDirectory,
                _ => return error.CorruptDirectory,
            }
        }
        for (blocks) |b| switch (b.kind) {
            .constant => {},
            .med, .plane => if (b.offset < @sizeOf(Header) or b.offset + b.len > h.slots_offset) return error.CorruptDirectory,
            _ => return error.CorruptDirectory,
        };
        map.adviseAll(.random) catch {};
        return .{ .map = map, .header = h, .slots = slots, .entries = entries, .blocks = blocks, .id = next_id.fetchAdd(1, .monotonic) };
    }

    pub fn close(self: *Pack) void {
        self.map.unmap();
    }

    pub fn entry(self: *const Pack, index: u32) ?*const TileEntry {
        if (index >= hgt.tile_count) return null;
        const s = self.slots[index];
        return if (s == 0) null else &self.entries[s - 1];
    }

    pub fn blockPayload(self: *const Pack, b: *const BlockEntry) []const u8 {
        return self.map.bytes[@intCast(b.offset)..][0..b.len];
    }

    /// Decodes block (br, bc) of a tile into `posts`, checking its CRC.
    pub fn decodeChecked(self: *const Pack, e: *const TileEntry, br: usize, bc: usize, posts: []i16) DecodeError!void {
        const w = blockSize(bc);
        const h = blockSize(br);
        if (e.kind == .constant) return @memset(posts[0 .. w * h], e.constant);
        const b = &self.blocks[e.first_block + br * blocks_per_side + bc];
        if (b.kind == .constant) return @memset(posts[0 .. w * h], b.constant);
        const payload = self.blockPayload(b);
        if (std.hash.Crc32.hash(payload) != b.crc) return error.CorruptBlock;
        try decodeBlock(b.kind, payload, w, h, posts);
    }

    /// Elevation at a point, exactly as `hgt.get` on the source tile.
    pub fn get(self: *const Pack, p: PointLL) f64 {
        const e = self.entry(hgt.tileIndex(p)) orelse return hgt.no_data_value;
        return sampleTile(self, e, p);
    }

    /// Elevations of many points, exactly as `hgt.getAll` on the source tiles.
    pub fn getAll(self: *const Pack, pts: []const PointLL, out: []f64) void {
        std.debug.assert(out.len >= pts.len);
        var sampler: Sampler = .{ .pack = self };
        for (pts, out[0..pts.len]) |p, *o| o.* = sampler.get(p);
    }

    pub fn prefetchBlock(self: *const Pack, tile: u32, block: usize) void {
        const e = self.entry(tile) orelse return;
        if (e.kind == .constant) return;
        const b = &self.blocks[e.first_block + block];
        if (b.kind != .constant) @prefetch(self.blockPayload(b).ptr, .{ .locality = 2 });
    }
};

pub const Sampler = struct {
    pack: *const Pack,
    index: u32 = std.math.maxInt(u32),
    posts: ?TilePosts = null,

    pub fn select(self: *Sampler, index: u32) bool {
        if (index != self.index) {
            self.index = index;
            self.posts = if (self.pack.entry(index)) |e| .{ .pack = self.pack, .entry = e } else null;
        }
        return self.posts != null;
    }

    pub fn sample(self: *Sampler, p: hgt.GridPosition) f64 {
        const posts = &self.posts.?;
        if (posts.entry.kind == .constant) return hgt.interpolateWith(ConstantPosts{ .value = posts.entry.constant }, p.u, p.v);
        posts.checkLastBlock();
        return hgt.interpolateWith(posts, p.u, p.v);
    }

    pub fn sampleBatch(self: *Sampler, points: *const [hgt.batch_width]hgt.GridPosition) [hgt.batch_width]f64 {
        const posts = &self.posts.?;
        if (posts.entry.kind == .constant) return hgt.interpolateBatch(ConstantPosts{ .value = posts.entry.constant }, points);
        posts.checkLastBlock();
        return hgt.interpolateBatch(posts, points);
    }

    pub fn get(self: *Sampler, point: PointLL) f64 {
        const p = hgt.GridPosition.at(point);
        return if (self.select(p.tile)) self.sample(p) else hgt.no_data_value;
    }
};

fn sampleTile(pack: *const Pack, e: *const TileEntry, p: PointLL) f64 {
    const lon = @floor(p.lng);
    const lat = @floor(p.lat);
    const u = (p.lng - lon) * (hgt.hgt_dim - 1);
    const v = (1.0 - (p.lat - lat)) * (hgt.hgt_dim - 1);
    if (e.kind == .constant) return hgt.interpolateWith(ConstantPosts{ .value = e.constant }, u, v);
    var posts: TilePosts = .{ .pack = pack, .entry = e };
    return hgt.interpolateWith(&posts, u, v);
}

const ConstantPosts = struct {
    value: i16,
    pub inline fn sample(self: ConstantPosts, _: usize) i16 {
        return self.value;
    }
};

/// Posts of one packed tile by linear index, through the block cache, with
/// the last block remembered (the four posts of a sample nearly always share
/// one block).
const TilePosts = struct {
    pack: *const Pack,
    entry: *const TileEntry,
    last_block: usize = std.math.maxInt(usize),
    last_posts: *[block_dim * block_dim]i16 = undefined,
    last_lazy: *LazyBlock = undefined,
    last_entry: *const BlockEntry = undefined,
    last_constant: ?i16 = null,
    last_slot_key: ?*const u64 = null,
    last_key: u64 = 0,

    fn checkLastBlock(self: *TilePosts) void {
        // Another sampler on this thread can replace the cached block between calls.
        if (self.last_slot_key) |key| {
            if (key.* != self.last_key) self.last_block = std.math.maxInt(usize);
        }
    }

    pub fn sample(self: *TilePosts, i: usize) i16 {
        const r = i / tile_dim;
        const col = i % tile_dim;
        const br = r / block_dim;
        const bc = col / block_dim;
        const block = br * blocks_per_side + bc;
        if (block != self.last_block) {
            const b = &self.pack.blocks[self.entry.first_block + block];
            self.last_block = block;
            self.last_constant = if (b.kind == .constant) b.constant else null;
            self.last_slot_key = null;
            if (b.kind != .constant) {
                const slot = cache.posts(self.pack, self.entry, br, bc, b);
                self.last_posts = slot.posts;
                self.last_lazy = slot.lazy;
                self.last_entry = b;
                self.last_slot_key = slot.key;
                self.last_key = slot.key.*;
            }
        }
        if (self.last_constant) |value| return value;
        const row = r % block_dim;
        const c = col % block_dim;
        const w = blockSize(bc);
        if (!self.last_lazy.done(row, c)) self.last_lazy.extend(self.last_entry.kind, self.pack.blockPayload(self.last_entry), w, blockSize(br), row, c, self.last_posts);
        return self.last_posts[row * w + c];
    }
};

/// How far a cached block is decoded. A trail through a block reads a few
/// of its posts, and a post needs only the posts above and to the left of it,
/// so a block is rebuilt in pieces, as far down and across as samples have
/// reached: on the us-dach /height corpus about half of its posts. Pieces
/// are strips of `wave_rows` rows (row 0 alone first) and, in a block a
/// whole number of groups wide, groups of 16 columns, whose residuals are
/// unpacked by group offset. Residuals are unpacked into the posts buffer,
/// just ahead of the posts rebuilt from them.
pub const LazyBlock = struct {
    const strips = 1 + (block_dim - 1 + wave_rows - 1) / wave_rows;
    const max_groups = block_dim * block_dim / group;

    /// Columns [0, cols[s]) of strip s are posts. Never fewer than the
    /// strip below, so each strip's north row is done wherever it is read.
    cols: [strips]u8 = @splat(0),
    /// Blocks not a whole number of groups wide unpack in order: the next
    /// group and its first byte.
    group: u16 = 0,
    pos: u16 = 0,
    /// First byte of each group, for blocks a whole number of groups wide.
    offsets: [max_groups]u16 = undefined,

    pub inline fn strip(row: usize) usize {
        return (row + wave_rows - 1) / wave_rows;
    }

    pub inline fn done(self: *const LazyBlock, row: usize, col: usize) bool {
        return col < self.cols[strip(row)];
    }

    /// Starts a block, checking its payload once as `decodeBlockScalar`
    /// would (it fails only by running out of bits), so the pieces never
    /// fail; a block that would fail reads as all no data.
    pub fn begin(self: *LazyBlock, kind: BlockKind, payload: []const u8, w: usize, h: usize, posts: *[block_dim * block_dim]i16) void {
        const n = w * h;
        self.cols = @splat(0);
        self.group = 0;
        self.pos = @intCast(((n + group - 1) / group + 1) / 2);
        const ok = (kind == .med or kind == .plane) and
            payloadFits(payload, n, if (w % group == 0) &self.offsets else null);
        if (!ok) self.fail(w, h, posts);
    }

    fn fail(self: *LazyBlock, w: usize, h: usize, posts: *[block_dim * block_dim]i16) void {
        @memset(posts[0 .. w * h], std.math.minInt(i16));
        self.cols = @splat(@intCast(w));
    }

    /// Decodes on until post (row, col) is done. `begin` already checked
    /// that every bit is present, so the pieces do not fail; the fallback to
    /// no data is only a guard.
    pub noinline fn extend(self: *LazyBlock, kind: BlockKind, payload: []const u8, w: usize, h: usize, row: usize, col: usize, posts: *[block_dim * block_dim]i16) void {
        switch (kind) {
            .plane => self.extendWith(.plane, payload, w, h, row, col, posts) catch self.fail(w, h, posts),
            else => self.extendWith(.med, payload, w, h, row, col, posts) catch self.fail(w, h, posts),
        }
    }

    fn extendWith(self: *LazyBlock, comptime p: Predictor, payload: []const u8, w: usize, h: usize, row: usize, col: usize, posts: *[block_dim * block_dim]i16) DecodeError!void {
        const n = w * h;
        const aligned = w % group == 0;
        const per_row = w / group;
        // Columns go 16 at a time once, then to the end: a trail crossing a
        // block would otherwise rebuild each strip in four short pieces, which
        // cost more than one whole strip (most of their steps are ramp).
        const to = if (aligned and self.cols[strip(row)] == 0) @min(w, (col / group + 1) * group) else w;
        const last = strip(row);
        var s: usize = 0;
        while (s <= last) : (s += 1) {
            const from: usize = self.cols[s];
            if (from >= to) continue;
            const r0 = if (s == 0) 0 else 1 + (s - 1) * wave_rows;
            // The median strip below over the same columns goes along in
            // one `rebuildStripPair`.
            const pair = p == .med and s > 0 and s < last and self.cols[s + 1] == from and pairs(from, to);
            const r1 = if (s == 0) 1 else @min(h, r0 + @as(usize, if (pair) 2 else 1) * wave_rows);
            if (aligned and from == 0 and to == w) {
                // Whole rows: one run of groups.
                _ = try unpackGroups(payload, n, posts, r0 * per_row, r1 * per_row, self.offsets[r0 * per_row]);
            } else if (aligned) {
                // Each row's groups for the new columns, by offset.
                for (r0..r1) |r| {
                    const g = r * per_row + from / group;
                    _ = try unpackGroups(payload, n, posts, g, r * per_row + to / group, self.offsets[g]);
                }
            } else {
                // In order, so a group across two rows is unpacked once.
                const g_to = (r1 * w + group - 1) / group;
                if (g_to > self.group) {
                    self.pos = @intCast(try unpackGroups(payload, n, posts, self.group, g_to, self.pos));
                    self.group = @intCast(g_to);
                }
            }
            if (s == 0) {
                rebuildFirstRow(posts, from, to, posts);
            } else if (pair) {
                rebuildStripPair(posts, w, r0, r1 - r0 - wave_rows, from, to, posts);
                self.cols[s] = @intCast(to);
                s += 1;
            } else switch (p) {
                .med => rebuildStrip(posts, w, r0, r1 - r0, from, to, posts),
                .plane => rebuildStripPlane(posts, w, r0, r1 - r0, from, to, posts),
            }
            self.cols[s] = @intCast(to);
        }
    }
};

/// Two-way cache of lazily decoded blocks, one per thread: 256 blocks, 2 MiB
/// of posts and about 130 KiB of `LazyBlock` state.
/// Replace the way least recently looked up in its set.
const Cache = struct {
    const sets = 128;
    const ways = 2;
    keys: [sets][ways]u64 = @splat(@splat(0)),
    replace: [sets]u1 = @splat(0),
    lazy: [sets][ways]LazyBlock = undefined,
    data: [sets][ways][block_dim * block_dim]i16 = undefined,

    const Slot = struct {
        key: *const u64,
        posts: *[block_dim * block_dim]i16,
        lazy: *LazyBlock,
    };

    fn blockKey(pack: *const Pack, tile: u32, block: usize) u64 {
        // Key: pack id, tile and block; never 0 because the id starts at 1.
        return (@as(u64, pack.id) << 44) | (@as(u64, tile) << 12) | block;
    }

    fn posts(self: *Cache, pack: *const Pack, e: *const TileEntry, br: usize, bc: usize, b: *const BlockEntry) Slot {
        const key = blockKey(pack, e.tile, br * blocks_per_side + bc);
        const set = std.hash.int(key) % sets;
        const keys = &self.keys[set];
        if (keys[0] == key) {
            self.replace[set] = 1;
            return .{ .key = &keys[0], .posts = &self.data[set][0], .lazy = &self.lazy[set][0] };
        }
        if (keys[1] == key) {
            self.replace[set] = 0;
            return .{ .key = &keys[1], .posts = &self.data[set][1], .lazy = &self.lazy[set][1] };
        }

        const way = self.replace[set];
        // The directory was validated at open; the payload was CRC-checked
        // by `zr dem verify`. A block that still fails to decode reads as no data.
        self.lazy[set][way].begin(b.kind, pack.blockPayload(b), blockSize(bc), blockSize(br), &self.data[set][way]);
        keys[way] = key;
        self.replace[set] = way ^ 1;
        return .{ .key = &keys[way], .posts = &self.data[set][way], .lazy = &self.lazy[set][way] };
    }
};

threadlocal var cache: Cache = .{};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "block coding round-trips edge sizes, voids and extremes" {
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    var posts: [block_dim * block_dim]i16 = undefined;
    var back: [block_dim * block_dim]i16 = undefined;
    var buf: [max_block_payload]u8 = undefined;
    for ([_][2]usize{ .{ 64, 64 }, .{ 17, 64 }, .{ 64, 17 }, .{ 17, 17 }, .{ 1, 1 }, .{ 3, 5 } }) |dims| {
        const w = dims[0];
        const h = dims[1];
        for (0..6) |kind| {
            for (posts[0 .. w * h], 0..) |*p, i| p.* = switch (kind) {
                0 => @intCast(@as(i32, @intCast(i % w)) * 3 + @as(i32, @intCast(i / w)) * 2 + 400), // a plane
                1 => random.int(i16), // noise, worst case
                2 => if (i % 7 == 0) -32768 else @intCast(1200 + random.intRangeAtMost(i32, -40, 40)), // voids in hills
                3 => if (i % 2 == 0) 32767 else -32768, // extremes alternating
                4 => 0,
                else => @intCast(random.intRangeAtMost(i32, -3, 3)),
            };
            inline for (.{ Predictor.med, Predictor.plane }) |pred| {
                const len = encodeBlock(pred, posts[0 .. w * h], w, h, &buf);
                try decodeBlockWith(pred, buf[0..len], w, h, &back);
                try testing.expectEqualSlices(i16, posts[0 .. w * h], back[0 .. w * h]);
                // A uniform slope is exact under the plane predictor inside the block;
                // only the widths and the first row and column cost: under 2 bits a post.
                if (kind == 0 and w == 64 and h == 64 and pred == .plane) try testing.expect(len < 64 * 64 * 2 / 8);
            }
        }
    }
    // Truncated payloads fail cleanly.
    for (posts[0..4096], 0..) |*p, i| p.* = @intCast(i);
    const len = encodeBlock(.med, &posts, 64, 64, &buf);
    try testing.expectError(error.CorruptBlock, decodeBlock(.med, buf[0 .. len - 1], 64, 64, &back));
    try testing.expectError(error.CorruptBlock, decodeBlock(.med, buf[0..10], 64, 64, &back));
    try testing.expectError(error.CorruptBlock, decodeBlock(.constant, buf[0..len], 64, 64, &back));
}

/// Decodes with both decoders and requires the same error or the same posts.
fn expectSameDecode(comptime p: Predictor, payload: []const u8, w: usize, h: usize) !void {
    var want: [block_dim * block_dim]i16 = undefined;
    var got: [block_dim * block_dim]i16 = undefined;
    const want_ok = if (decodeBlockScalar(p, payload, w, h, &want)) |_| true else |_| false;
    const got_ok = if (decodeBlockWith(p, payload, w, h, &got)) |_| true else |_| false;
    try testing.expectEqual(want_ok, got_ok);
    try testing.expectEqual(want_ok, payloadFits(payload, w * h, null));
    if (want_ok) try testing.expectEqualSlices(i16, want[0 .. w * h], got[0 .. w * h]);
    try expectSameLazyDecode(p, payload, w, h, if (want_ok) &want else null);
}

/// Decodes lazily, posts asked for in a scrambled (row, col) order, and
/// requires every decoded post to match `want` (null: the block must read as
/// no data). The whole block is checked each time a piece is decoded, so a
/// later piece that disturbs an earlier one is caught.
fn expectSameLazyDecode(comptime p: Predictor, payload: []const u8, w: usize, h: usize, want: ?*const [block_dim * block_dim]i16) !void {
    const kind: BlockKind = if (p == .med) .med else .plane;
    var posts: [block_dim * block_dim]i16 = undefined;
    var lazy: LazyBlock = .{};
    lazy.begin(kind, payload, w, h, &posts);
    try expectLazyPosts(&lazy, &posts, w, h, want);
    // A block that fails reads as no data from the start; nothing more to learn.
    if (want == null) return;
    var row: usize = (w * 7 + h * 3) % h;
    var col: usize = (w * 3 + h * 5) % w;
    for (0..h + w) |_| {
        if (!lazy.done(row, col)) {
            lazy.extend(kind, payload, w, h, row, col, &posts);
            try expectLazyPosts(&lazy, &posts, w, h, want);
        }
        try testing.expect(lazy.done(row, col));
        row = (row * 5 + 3) % h;
        col = (col * 7 + 5) % w;
    }
}

/// Every done post of a lazy block, and the staircase shape.
fn expectLazyPosts(lazy: *const LazyBlock, posts: *const [block_dim * block_dim]i16, w: usize, h: usize, want: ?*const [block_dim * block_dim]i16) !void {
    for (0..h) |r| {
        const cols = lazy.cols[LazyBlock.strip(r)];
        if (r > 0) try testing.expect(cols <= lazy.cols[LazyBlock.strip(r - 1)]);
        const got = posts[r * w ..][0..cols];
        if (want) |posts_want| {
            try testing.expectEqualSlices(i16, posts_want[r * w ..][0..cols], got);
        } else for (got) |v| try testing.expectEqual(std.math.minInt(i16), v);
    }
}

test "the vector decoder matches the scalar reference, posts and errors" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var posts: [block_dim * block_dim]i16 = undefined;
    var buf: [max_block_payload + 64]u8 = undefined;
    // Every block shape the wavefront treats differently: thinner and
    // narrower than a strip, one row past a strip, the 17-post edge blocks.
    const dims = [_]usize{ 64, 63, 17, 9, 8, 7, 5, 3, 2, 1 };
    for (0..3000) |iter| {
        const w = dims[random.uintLessThan(usize, dims.len)];
        const h = dims[random.uintLessThan(usize, dims.len)];
        const n = w * h;
        // Real encodings of terrain-like, noisy and extreme posts.
        for (posts[0..n], 0..) |*v, i| v.* = switch (iter % 4) {
            0 => @intCast(@as(i32, @intCast(i % w)) * 3 + @as(i32, @intCast(i / w)) * 2 + 400 + random.intRangeAtMost(i32, -3, 3)),
            1 => random.int(i16),
            2 => if (random.boolean()) 32767 else -32768,
            else => @intCast(1200 + random.intRangeAtMost(i32, -200, 200)),
        };
        inline for (.{ Predictor.med, Predictor.plane }) |p| {
            const len = encodeBlock(p, posts[0..n], w, h, buf[0..max_block_payload]);
            try expectSameDecode(p, buf[0..len], w, h);
            // Truncations reach every split between the vector and serial paths.
            var cut = len;
            while (cut > 0) : (cut -= 1 + cut / 64) try expectSameDecode(p, buf[0..cut], w, h);
        }
        // Arbitrary bytes: random widths, lengths from 40 bytes short to 40 long.
        random.bytes(&buf);
        const groups = (n + group - 1) / group;
        var need_bits: usize = 0;
        for (0..groups) |g| {
            const nibble: u4 = if (iter % 2 == 0) random.uintLessThan(u4, 7) else random.int(u4);
            const shift: u3 = @intCast((g % 2) * 4);
            buf[g / 2] = (buf[g / 2] & ~(@as(u8, 0xf) << shift)) | (@as(u8, nibble) << shift);
            need_bits += @as(usize, if (nibble == 15) 16 else nibble) * (@min(n, (g + 1) * group) - g * group);
        }
        const exact = (groups + 1) / 2 + (need_bits + 7) / 8;
        const len = @min(buf.len, (exact + 40) -| random.uintLessThan(usize, 80));
        try expectSameDecode(.med, buf[0..len], w, h);
        try expectSameDecode(.plane, buf[0..len], w, h);
    }
}

test "zigzag and the median predictor" {
    for ([_]i16{ 0, 1, -1, 2, -2, 32767, -32768 }) |v| try testing.expectEqual(v, unzigzag(zigzag(v)));
    try testing.expectEqual(@as(u16, 1), zigzag(-1));
    try testing.expectEqual(@as(i16, 3), medPredict(3, 9, 10)); // c above both: min
    try testing.expectEqual(@as(i16, 9), medPredict(3, 9, 1)); // c below both: max
    try testing.expectEqual(@as(i16, 7), medPredict(3, 9, 5)); // between: plane
}

/// A rugged synthetic tile: smooth hills, noise, a void patch and a flat sea.
fn ruggedTile(gpa: Allocator) ![]u8 {
    const raw = try gpa.alloc(u8, hgt.hgt_bytes);
    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    for (0..tile_dim) |r| for (0..tile_dim) |col| {
        const x: f64 = @floatFromInt(col);
        const y: f64 = @floatFromInt(r);
        var v: i32 = @intFromFloat(1500 + 900 * @sin(x / 300) * @cos(y / 410) + 40 * @sin(x / 13 + y / 17));
        v += random.intRangeAtMost(i32, -2, 2);
        if (r > 3000 and col < 900) v = 0; // sea
        if (r >= 500 and r < 540 and col >= 700 and col < 760) v = -32768; // void
        std.mem.writeInt(i16, raw[(r * tile_dim + col) * 2 ..][0..2], @intCast(v), .big);
    };
    return raw;
}

test "a pack samples bit-identically to its source tiles on 10^6 points" {
    const gpa = testing.allocator;
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/zig-routing-dem-{d}", .{std.c.getpid()});
    hgt.mkdir(dir);
    defer hgt.rmTree(dir);
    var sub_buf: [256]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/N47", .{dir});
    hgt.mkdir(sub);

    // A rugged tile (raw), the regular test tile (lz4), and an all-sea tile.
    const rugged = try ruggedTile(gpa);
    defer gpa.free(rugged);
    var path_buf: [512]u8 = undefined;
    try io.writeFile(try std.fmt.bufPrint(&path_buf, "{s}/N47E008.hgt", .{sub}), rugged);
    try hgt.writeTile(gpa, dir, "N46E008.hgt.lz4", .lz4);
    const sea = try gpa.alloc(u8, hgt.hgt_bytes);
    defer gpa.free(sea);
    @memset(sea, 0);
    try io.writeFile(try std.fmt.bufPrint(&path_buf, "{s}/N46E009.hgt", .{dir}), sea);

    var tiles = try hgt.Tiles.init(gpa, dir);
    defer tiles.deinit();
    const indices = try tiles.indices(gpa);
    defer gpa.free(indices);
    try testing.expectEqual(@as(usize, 3), indices.len);

    const pack_path = try std.fmt.bufPrint(&path_buf, "{s}/test.zdem", .{dir});
    var w = try Writer.begin(gpa, pack_path);
    const buf = try gpa.alloc(u8, hgt.hgt_bytes);
    defer gpa.free(buf);
    var raw_total: usize = 0;
    for (indices) |index| {
        try testing.expect(tiles.readTile(index, buf));
        var t = try encodeTile(gpa, index, buf);
        defer t.deinit(gpa);
        try w.add(&t);
        raw_total += hgt.hgt_bytes;
    }
    const header = try w.finish();
    w.deinit();
    try testing.expectEqual(@as(u32, 3), header.tile_count);

    var pack = try Pack.open(pack_path);
    defer pack.close();
    try testing.expectEqual(TileKind.constant, pack.entry(indices[1]).?.kind); // N46E009, the sea
    // Far smaller than raw: the sea is one value, the patterns predict well.
    try testing.expect(pack.map.bytes.len * 4 < raw_total);

    // Every post decodes to the source, block by block, with CRCs checked.
    var posts: [block_dim * block_dim]i16 = undefined;
    for (indices) |index| {
        try testing.expect(tiles.readTile(index, buf));
        const src = hgt.BigEndianPosts{ .data = buf };
        const e = pack.entry(index).?;
        for (0..blocks_per_side) |br| for (0..blocks_per_side) |bc| {
            try pack.decodeChecked(e, br, bc, &posts);
            const bw = blockSize(bc);
            for (0..blockSize(br)) |r| for (0..bw) |col| {
                try testing.expectEqual(src.sample((br * block_dim + r) * tile_dim + bc * block_dim + col), posts[r * bw + col]);
            };
        };
    }

    // Sampling: 10^6 random points across the three tiles and their edges.
    var prng = std.Random.DefaultPrng.init(99);
    const random = prng.random();
    var pts: [1000]PointLL = undefined;
    var a: [1000]f64 = undefined;
    var b: [1000]f64 = undefined;
    for (0..1000) |_| {
        for (&pts) |*p| p.* = .{ .lng = 8 + random.float(f64) * 2, .lat = 46 + random.float(f64) * 2 };
        // Exact posts and tile edges, where the neighbour logic matters.
        pts[0] = .{ .lng = 8.0, .lat = 48.0 - 1e-12 };
        pts[1] = .{ .lng = 8.0 + 3599.5 / 3600.0, .lat = 47.0 };
        pts[2] = .{ .lng = 8.0 + 700.5 / 3600.0, .lat = 48.0 - 520.5 / 3600.0 }; // inside the void
        hgt.getAll(&tiles, &pts, &a);
        pack.getAll(&pts, &b);
        for (a, b) |x, y| try testing.expect(@as(u64, @bitCast(x)) == @as(u64, @bitCast(y)));
    }
    try testing.expectEqual(hgt.get(&tiles, pts[5]), pack.get(pts[5]));
    try testing.expectEqual(hgt.no_data_value, pack.get(.{ .lng = 20.5, .lat = 10.5 }));

    // Two samplers on one thread share the cache. Evict the first sampler's
    // last block, then sample it again without changing its selected tile.
    const tile = indices[2];
    const entry = pack.entry(tile).?;
    const origin: hgt.GridPosition = .{ .tile = tile, .u = 12.25, .v = 12.25 };
    var first: Sampler = .{ .pack = &pack };
    var other: Sampler = .{ .pack = &pack };
    try testing.expect(first.select(tile));
    try testing.expect(other.select(tile));
    const expected = first.sample(origin);
    const set = std.hash.int(Cache.blockKey(&pack, tile, 0)) % Cache.sets;
    var replacements: usize = 0;
    for (1..blocks_per_tile) |block| {
        if (std.hash.int(Cache.blockKey(&pack, tile, block)) % Cache.sets != set or
            pack.blocks[entry.first_block + block].kind == .constant) continue;
        _ = other.sample(.{
            .tile = tile,
            .u = @floatFromInt((block % blocks_per_side) * block_dim + 12),
            .v = @floatFromInt((block / blocks_per_side) * block_dim + 12),
        });
        replacements += 1;
        if (replacements == Cache.ways) break;
    }
    try testing.expectEqual(Cache.ways, replacements);
    try testing.expect(first.posts.?.last_slot_key.?.* != first.posts.?.last_key);
    try testing.expectEqual(expected, first.sampleBatch(&@as([hgt.batch_width]hgt.GridPosition, @splat(origin)))[0]);
}

test "a damaged pack is rejected at open" {
    const gpa = testing.allocator;
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/zig-routing-dem-bad-{d}.zdem", .{std.c.getpid()}, 0);
    defer _ = std.c.unlink(path);
    var w = try Writer.begin(gpa, path);
    const raw = try ruggedTile(gpa);
    defer gpa.free(raw);
    var t = try encodeTile(gpa, 100, raw);
    defer t.deinit(gpa);
    try w.add(&t);
    _ = try w.finish();
    w.deinit();

    const good = try io.readFileAlloc(gpa, path, 1 << 30);
    defer gpa.free(good);
    // A flipped byte in the directory fails the hash.
    good[good.len - 3] ^= 1;
    try io.writeFile(path, good);
    try testing.expectError(error.CorruptDirectory, Pack.open(path));
    good[good.len - 3] ^= 1;
    // A wrong magic is not a pack.
    good[0] = 'X';
    try io.writeFile(path, good);
    try testing.expectError(error.NotAPack, Pack.open(path));
    good[0] = magic[0];
    // A flipped payload byte passes open but fails the block CRC.
    good[@sizeOf(Header) + 10] ^= 0x40;
    try io.writeFile(path, good);
    var pack = try Pack.open(path);
    defer pack.close();
    var posts: [block_dim * block_dim]i16 = undefined;
    const e = pack.entry(100).?;
    var failures: usize = 0;
    for (0..blocks_per_side) |br| for (0..blocks_per_side) |bc| {
        pack.decodeChecked(e, br, bc, &posts) catch {
            failures += 1;
        };
    };
    try testing.expectEqual(@as(usize, 1), failures);
}

test "the vector median predictor matches the scalar one" {
    const V = @Vector(wave_rows, i16);
    var prng = std.Random.DefaultPrng.init(5);
    const random = prng.random();
    const edges = [_]i16{ -32768, -32767, -1, 0, 1, 32766, 32767 };
    for (0..20000) |iter| {
        var a: V = undefined;
        var b: V = undefined;
        var c: V = undefined;
        inline for (0..wave_rows) |k| {
            a[k] = if (iter % 3 == 0) edges[random.uintLessThan(usize, edges.len)] else random.int(i16);
            b[k] = if (iter % 5 == 0) edges[random.uintLessThan(usize, edges.len)] else random.int(i16);
            c[k] = if (iter % 2 == 0) edges[random.uintLessThan(usize, edges.len)] else random.int(i16);
        }
        const got = medPredictVec(V, a, b, c);
        inline for (0..wave_rows) |k| try testing.expectEqual(medPredict(a[k], b[k], c[k]), got[k]);
    }
}

/// The posts of residuals by the scalar recurrence, as `decodeBlockScalar`
/// rebuilds them.
fn rebuildScalar(comptime p: Predictor, residuals: []const i16, w: usize, h: usize, posts: []i16) void {
    for (0..h) |r| for (0..w) |col| {
        const i = r * w + col;
        posts[i] = residuals[i] +% predict(p, posts, w, r, col);
    };
}

test "the strip kernels match the scalar recurrence in any pieces" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var residuals: [block_dim * block_dim]i16 = undefined;
    var want: [block_dim * block_dim]i16 = undefined;
    var got: [block_dim * block_dim]i16 = undefined;
    // Full and edge blocks, widths on and off the tile size, heights that
    // end a strip short, and strips paired or not.
    const shapes = [_][2]usize{ .{ 64, 64 }, .{ 17, 17 }, .{ 64, 17 }, .{ 17, 64 }, .{ 24, 12 }, .{ 9, 10 }, .{ 8, 9 }, .{ 16, 25 }, .{ 40, 33 }, .{ 7, 20 } };
    for (shapes) |shape| {
        const w = shape[0];
        const h = shape[1];
        const n = w * h;
        for (0..6) |iter| {
            for (residuals[0..n]) |*v| v.* = switch (iter % 3) {
                0 => random.int(i16),
                1 => random.intRangeAtMost(i16, -5, 5),
                else => if (random.boolean()) 32767 else -32768,
            };
            inline for (.{ Predictor.med, Predictor.plane }) |p| {
                rebuildScalar(p, residuals[0..n], w, h, &want);
                // Two pieces split at every column, in place or from a
                // separate residual buffer (the posts start as garbage).
                for (0..w) |split| for ([_]bool{ true, false }) |in_place| {
                    if (in_place) @memcpy(got[0..n], residuals[0..n]) else @memset(&got, 0x5555);
                    const src: *const [block_dim * block_dim]i16 = if (in_place) &got else &residuals;
                    for ([_][2]usize{ .{ 0, split }, .{ split, w } }) |piece| {
                        const c_from = piece[0];
                        const c_to = piece[1];
                        rebuildFirstRow(src, c_from, c_to, &got);
                        var r0: usize = 1;
                        while (r0 < h) : (r0 += wave_rows) {
                            if (p == .plane) {
                                rebuildStripPlane(src, w, r0, @min(wave_rows, h - r0), c_from, c_to, &got);
                            } else if (h - r0 > wave_rows and pairs(c_from, c_to) and (iter + r0 / wave_rows) % 2 == 0) {
                                rebuildStripPair(src, w, r0, @min(wave_rows, h - r0 - wave_rows), c_from, c_to, &got);
                                r0 += wave_rows;
                            } else rebuildStrip(src, w, r0, @min(wave_rows, h - r0), c_from, c_to, &got);
                        }
                    }
                    try testing.expectEqualSlices(i16, want[0..n], got[0..n]);
                };
            }
        }
    }
}
