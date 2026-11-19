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
/// first the bit-packed codes, then the posts row by row (no per-post
/// division, predictions from the rows already rebuilt).
pub fn decodeBlockWith(comptime p: Predictor, payload: []const u8, w: usize, h: usize, posts: []i16) DecodeError!void {
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
        return hgt.interpolateWith(posts, p.u, p.v);
    }

    pub fn sampleBatch(self: *Sampler, points: *const [hgt.batch_width]hgt.GridPosition) [hgt.batch_width]f64 {
        const posts = &self.posts.?;
        if (posts.entry.kind == .constant) return hgt.interpolateBatch(ConstantPosts{ .value = posts.entry.constant }, points);
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
    last_posts: *const [block_dim * block_dim]i16 = undefined,
    last_constant: ?i16 = null,

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
            if (b.kind != .constant) self.last_posts = cache.posts(self.pack, self.entry, br, bc, b);
        }
        if (self.last_constant) |value| return value;
        return self.last_posts[(r % block_dim) * blockSize(bc) + col % block_dim];
    }
};

/// Direct-mapped cache of decoded blocks, one per thread: 256 blocks, 2 MiB.
const Cache = struct {
    const ways = 256;
    keys: [ways]u64 = @splat(0),
    data: [ways][block_dim * block_dim]i16 = undefined,

    fn posts(self: *Cache, pack: *const Pack, e: *const TileEntry, br: usize, bc: usize, b: *const BlockEntry) *const [block_dim * block_dim]i16 {
        // Key: pack id, tile and block; never 0 because the id starts at 1.
        const key = (@as(u64, pack.id) << 44) | (@as(u64, e.tile) << 12) | (br * blocks_per_side + bc);
        const slot = std.hash.int(key) % ways;
        if (self.keys[slot] != key) {
            // The directory was validated at open; the payload was CRC-checked
            // by `zr dem verify`. A block that still fails to decode reads as
            // no data rather than garbage.
            decodeBlock(b.kind, pack.blockPayload(b), blockSize(bc), blockSize(br), &self.data[slot]) catch
                @memset(&self.data[slot], std.math.minInt(i16));
            self.keys[slot] = key;
        }
        return &self.data[slot];
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
