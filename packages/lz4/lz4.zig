//! LZ4 block and frame codec, in pure Zig.
//!
//! - Block format: https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
//! - Frame format: https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md
//!
//! Decompression is bounds-checked against both input and output and never
//! reads or writes outside them, so it is safe on untrusted data. Compression
//! is the greedy "fast" algorithm; its output is valid for any LZ4 decoder.
//! Checksums use `std.hash.XxHash32`.

const std = @import("std");
const XxHash32 = std.hash.XxHash32;

pub const Error = error{
    /// The input ended before the data it describes.
    Truncated,
    /// A match points before the start of the output.
    BadOffset,
    /// The output buffer is smaller than the data.
    OutputTooSmall,
    /// Not an LZ4 frame, or an unsupported frame option.
    BadFrame,
    /// A header, block or content checksum did not match.
    ChecksumMismatch,
};

// ---------------------------------------------------------------------------
// Block decompression
// ---------------------------------------------------------------------------

/// Decompresses one block into `dst[dst_start..]`. Matches may reach back
/// into `dst[0..dst_start]` (linked blocks use the previous output as the
/// dictionary). Returns the number of bytes written.
///
/// While there is slack in both buffers, copies run in whole 8 or 16 byte
/// chunks and may write a few bytes past the current sequence (never past
/// `dst.len`); those bytes are overwritten by later sequences, and bytes
/// beyond the returned length are unspecified.
pub fn decompressBlockInto(src: []const u8, dst: []u8, dst_start: usize) Error!usize {
    var ip: usize = 0;
    var op: usize = dst_start;
    while (true) {
        if (ip >= src.len) return error.Truncated;
        const token = src[ip];
        ip += 1;

        // Literals.
        var lit_len: usize = token >> 4;
        if (lit_len == 15) lit_len += try readLength(src, &ip);
        if (lit_len > src.len - ip) return error.Truncated;
        if (lit_len > dst.len - op) return error.OutputTooSmall;
        if (lit_len <= 16 and src.len - ip >= 16 and dst.len - op >= 16) {
            dst[op..][0..16].* = src[ip..][0..16].*;
        } else if (src.len - ip >= lit_len + 16 and dst.len - op >= lit_len + 16) {
            var i: usize = 0;
            while (i < lit_len) : (i += 16) dst[op + i ..][0..16].* = src[ip + i ..][0..16].*;
        } else {
            @memcpy(dst[op..][0..lit_len], src[ip..][0..lit_len]);
        }
        ip += lit_len;
        op += lit_len;

        // The last sequence has literals only.
        if (ip == src.len) return op - dst_start;

        // Match.
        if (src.len - ip < 2) return error.Truncated;
        const offset: usize = @as(usize, src[ip]) | (@as(usize, src[ip + 1]) << 8);
        ip += 2;
        if (offset == 0 or offset > op) return error.BadOffset;
        var match_len: usize = (token & 0x0f) + 4;
        if (match_len == 19) match_len += try readLength(src, &ip);
        if (match_len > dst.len - op) return error.OutputTooSmall;
        if (dst.len - op >= match_len + 16) {
            wildCopyMatch(dst, op, offset, match_len);
        } else {
            copyMatch(dst, op, offset, match_len);
        }
        op += match_len;
    }
}

const inc32 = [8]usize{ 0, 1, 2, 1, 0, 4, 4, 4 };
const dec64 = [8]isize{ 0, 0, 0, -1, -4, 1, 2, 3 };

/// Match copy in 8-byte chunks, overrunning by up to 15 bytes. Offsets
/// below 8 first expand the repeating pattern so later chunks never read
/// bytes not yet written (the reference decoder's inc32/dec64 trick).
inline fn wildCopyMatch(dst: []u8, op: usize, offset: usize, len: usize) void {
    var s = op - offset;
    var d = op;
    if (offset < 8) {
        dst[d] = dst[s];
        dst[d + 1] = dst[s + 1];
        dst[d + 2] = dst[s + 2];
        dst[d + 3] = dst[s + 3];
        s += inc32[offset];
        dst[d + 4 ..][0..4].* = dst[s..][0..4].*;
        s = @intCast(@as(isize, @intCast(s)) - dec64[offset]);
        d += 8;
    }
    const end = op + len;
    while (d < end) {
        dst[d..][0..8].* = dst[s..][0..8].*;
        d += 8;
        s += 8;
    }
}

/// Decompresses one standalone block. Returns the decompressed slice of `dst`.
pub fn decompressBlock(src: []const u8, dst: []u8) Error![]u8 {
    const n = try decompressBlockInto(src, dst, 0);
    return dst[0..n];
}

inline fn readLength(src: []const u8, ip: *usize) Error!usize {
    var total: usize = 0;
    while (true) {
        if (ip.* >= src.len) return error.Truncated;
        const b = src[ip.*];
        ip.* += 1;
        total += b;
        if (b != 255) return total;
    }
}

inline fn copyMatch(dst: []u8, op: usize, offset: usize, len: usize) void {
    const from = op - offset;
    if (offset >= len) {
        @memcpy(dst[op..][0..len], dst[from..][0..len]);
        return;
    }
    if (offset >= 8) {
        // Overlapping but at least 8 apart: copy in 8-byte steps from the
        // already-written region.
        var i: usize = 0;
        while (i + 8 <= len) : (i += 8) {
            const chunk: [8]u8 = dst[from + i ..][0..8].*;
            dst[op + i ..][0..8].* = chunk;
        }
        while (i < len) : (i += 1) dst[op + i] = dst[from + i];
        return;
    }
    // Short repeating pattern (run-length style).
    for (0..len) |i| dst[op + i] = dst[from + i];
}

// ---------------------------------------------------------------------------
// Block compression (greedy fast mode)
// ---------------------------------------------------------------------------

const min_match = 4;
const last_literals = 5;
const mf_limit = 12;
const hash_log = 16;

/// Worst-case compressed size of `n` bytes (LZ4_compressBound).
pub fn compressBound(n: usize) usize {
    return n + n / 255 + 16;
}

/// Reusable compressor state (the match-finder hash table, 256 KiB).
pub const Compressor = struct {
    table: [1 << hash_log]u32 = undefined,

    inline fn hash(v: u32) u32 {
        return (v *% 2654435761) >> (32 - hash_log);
    }

    inline fn read32(b: []const u8, i: usize) u32 {
        return std.mem.readInt(u32, b[i..][0..4], .little);
    }

    /// Compresses `src` into `dst` as one block. `dst` must hold
    /// `compressBound(src.len)` bytes. Returns the compressed length.
    pub fn compressBlock(self: *Compressor, src: []const u8, dst: []u8) Error!usize {
        if (dst.len < compressBound(src.len)) return error.OutputTooSmall;
        var op: usize = 0;
        var anchor: usize = 0;
        if (src.len >= mf_limit + 1) {
            @memset(&self.table, 0);
            const mflimit = src.len - mf_limit;
            const matchlimit = src.len - last_literals;
            var ip: usize = 1;
            self.table[hash(read32(src, 0))] = 0;
            var search: u32 = (1 << 6);
            while (ip < mflimit) {
                const h = hash(read32(src, ip));
                var ref: usize = self.table[h];
                self.table[h] = @intCast(ip);
                if (ref >= ip or ip - ref > 65535 or read32(src, ref) != read32(src, ip)) {
                    ip += search >> 6;
                    search += 1;
                    continue;
                }
                search = 1 << 6;
                var start = ip;
                while (start > anchor and ref > 0 and src[start - 1] == src[ref - 1]) {
                    start -= 1;
                    ref -= 1;
                }
                var len: usize = min_match;
                while (start + len < matchlimit and src[start + len] == src[ref + len]) len += 1;
                op = emitSequence(dst, op, src[anchor..start], start - ref, len);
                ip = start + len;
                anchor = ip;
                if (ip < mflimit) self.table[hash(read32(src, ip - 2))] = @intCast(ip - 2);
            }
        }
        op = emitLastLiterals(dst, op, src[anchor..]);
        return op;
    }
};

fn writeLength(dst: []u8, op_in: usize, len_in: usize) usize {
    var op = op_in;
    var len = len_in;
    while (len >= 255) : (len -= 255) {
        dst[op] = 255;
        op += 1;
    }
    dst[op] = @intCast(len);
    return op + 1;
}

fn emitSequence(dst: []u8, op_in: usize, literals: []const u8, offset: usize, match_len: usize) usize {
    var op = op_in;
    const lit = literals.len;
    const ml = match_len - min_match;
    const token_pos = op;
    op += 1;
    var token: u8 = 0;
    if (lit >= 15) {
        token = 15 << 4;
        op = writeLength(dst, op, lit - 15);
    } else token = @as(u8, @intCast(lit)) << 4;
    @memcpy(dst[op..][0..lit], literals);
    op += lit;
    dst[op] = @intCast(offset & 0xff);
    dst[op + 1] = @intCast(offset >> 8);
    op += 2;
    if (ml >= 15) {
        token |= 15;
        op = writeLength(dst, op, ml - 15);
    } else token |= @intCast(ml);
    dst[token_pos] = token;
    return op;
}

fn emitLastLiterals(dst: []u8, op_in: usize, literals: []const u8) usize {
    var op = op_in;
    const lit = literals.len;
    if (lit >= 15) {
        dst[op] = 15 << 4;
        op = writeLength(dst, op + 1, lit - 15);
    } else {
        dst[op] = @as(u8, @intCast(lit)) << 4;
        op += 1;
    }
    @memcpy(dst[op..][0..lit], literals);
    return op + lit;
}

// ---------------------------------------------------------------------------
// Frame format
// ---------------------------------------------------------------------------

const frame_magic: u32 = 0x184D2204;
const skippable_magic_mask: u32 = 0xFFFFFFF0;
const skippable_magic: u32 = 0x184D2A50;

pub const FrameInfo = struct {
    block_independent: bool,
    block_checksum: bool,
    content_checksum: bool,
    content_size: ?u64,
    block_max_size: usize,
    /// Bytes of the header, from the magic number through the header checksum.
    header_len: usize,
};

fn blockMaxSize(code: u8) Error!usize {
    return switch (code) {
        4 => 64 * 1024,
        5 => 256 * 1024,
        6 => 1024 * 1024,
        7 => 4 * 1024 * 1024,
        else => error.BadFrame,
    };
}

/// Parses an LZ4 frame header at the start of `src`.
pub fn readFrameHeader(src: []const u8) Error!FrameInfo {
    if (src.len < 7) return error.Truncated;
    if (std.mem.readInt(u32, src[0..4], .little) != frame_magic) return error.BadFrame;
    const flg = src[4];
    const bd = src[5];
    if (flg >> 6 != 1) return error.BadFrame; // version 01
    if (flg & 0x02 != 0 or bd & 0x8f != 0) return error.BadFrame; // reserved bits
    if (flg & 0x01 != 0) return error.BadFrame; // dictionary ids are not supported
    var pos: usize = 6;
    var content_size: ?u64 = null;
    if (flg & 0x08 != 0) {
        if (src.len < pos + 8) return error.Truncated;
        content_size = std.mem.readInt(u64, src[pos..][0..8], .little);
        pos += 8;
    }
    if (src.len < pos + 1) return error.Truncated;
    const hc: u8 = @truncate(XxHash32.hash(0, src[4..pos]) >> 8);
    if (hc != src[pos]) return error.ChecksumMismatch;
    return .{
        .block_independent = flg & 0x20 != 0,
        .block_checksum = flg & 0x10 != 0,
        .content_checksum = flg & 0x04 != 0,
        .content_size = content_size,
        .block_max_size = try blockMaxSize((bd >> 4) & 0x07),
        .header_len = pos + 1,
    };
}

pub const DecodeResult = struct {
    /// Bytes written to the output.
    written: usize,
    /// Bytes consumed from the input.
    consumed: usize,
};

/// Decompresses every frame in `src` (concatenated frames and skippable
/// frames are supported) into `dst`. Verifies block and content checksums
/// when present.
pub fn decompressFrames(src: []const u8, dst: []u8) Error!DecodeResult {
    var ip: usize = 0;
    var op: usize = 0;
    while (ip < src.len) {
        if (src.len - ip < 4) return error.Truncated;
        const magic = std.mem.readInt(u32, src[ip..][0..4], .little);
        if (magic & skippable_magic_mask == skippable_magic) {
            if (src.len - ip < 8) return error.Truncated;
            const len = std.mem.readInt(u32, src[ip + 4 ..][0..4], .little);
            if (src.len - ip - 8 < len) return error.Truncated;
            ip += 8 + len;
            continue;
        }
        const r = try decompressFrame(src[ip..], dst[op..]);
        ip += r.consumed;
        op += r.written;
    }
    return .{ .written = op, .consumed = ip };
}

/// Decompresses the single frame at the start of `src` into `dst`.
pub fn decompressFrame(src: []const u8, dst: []u8) Error!DecodeResult {
    const info = try readFrameHeader(src);
    var ip = info.header_len;
    var op: usize = 0;
    while (true) {
        if (src.len - ip < 4) return error.Truncated;
        const word = std.mem.readInt(u32, src[ip..][0..4], .little);
        ip += 4;
        if (word == 0) break; // end mark
        const raw = word & 0x80000000 != 0;
        const size: usize = word & 0x7fffffff;
        if (size > info.block_max_size) return error.BadFrame;
        if (src.len - ip < size) return error.Truncated;
        const block = src[ip..][0..size];
        ip += size;
        if (info.block_checksum) {
            if (src.len - ip < 4) return error.Truncated;
            if (std.mem.readInt(u32, src[ip..][0..4], .little) != XxHash32.hash(0, block)) return error.ChecksumMismatch;
            ip += 4;
        }
        if (raw) {
            if (dst.len - op < size) return error.OutputTooSmall;
            @memcpy(dst[op..][0..size], block);
            op += size;
        } else if (info.block_independent) {
            // Each block decodes on its own: give it a window that starts at its own output.
            const n = try decompressBlockInto(block, dst[op..], 0);
            op += n;
        } else {
            op += try decompressBlockInto(block, dst, op);
        }
    }
    if (info.content_checksum) {
        if (src.len - ip < 4) return error.Truncated;
        if (std.mem.readInt(u32, src[ip..][0..4], .little) != XxHash32.hash(0, dst[0..op])) return error.ChecksumMismatch;
        ip += 4;
    }
    if (info.content_size) |cs| if (cs != op) return error.BadFrame;
    return .{ .written = op, .consumed = ip };
}

/// Decompresses frames into newly allocated memory, sized from the content
/// size when the frame carries it and grown otherwise. `max_bytes` bounds
/// the output to defend against decompression bombs.
pub fn decompressAlloc(gpa: std.mem.Allocator, src: []const u8, max_bytes: usize) (Error || error{ OutOfMemory, TooLarge })![]u8 {
    var cap: usize = blk: {
        const info = readFrameHeader(src) catch break :blk @max(64 * 1024, src.len * 4);
        if (info.content_size) |cs| {
            if (cs > max_bytes) return error.TooLarge;
            break :blk @intCast(cs);
        }
        break :blk @max(64 * 1024, src.len * 4);
    };
    while (true) {
        cap = @min(cap, max_bytes);
        const buf = try gpa.alloc(u8, cap);
        const r = decompressFrames(src, buf) catch |e| {
            gpa.free(buf);
            if (e == error.OutputTooSmall and cap < max_bytes) {
                cap = cap * 2;
                continue;
            }
            if (e == error.OutputTooSmall) return error.TooLarge;
            return e;
        };
        return gpa.realloc(buf, r.written);
    }
}

pub const FrameOptions = struct {
    block_max_code: u8 = 7, // 4 MiB blocks
    content_checksum: bool = true,
    block_checksum: bool = false,
    content_size: bool = true,
};

/// Upper bound for `compressFrame` output.
pub fn compressFrameBound(n: usize, options: FrameOptions) usize {
    const block = blockMaxSize(options.block_max_code) catch unreachable;
    const blocks = n / block + 1;
    return 19 + blocks * (4 + 4) + compressBound(n) + blocks * 16 + 8;
}

/// Compresses `src` into one frame with independent blocks.
pub fn compressFrame(c: *Compressor, src: []const u8, dst: []u8, options: FrameOptions) Error!usize {
    if (dst.len < compressFrameBound(src.len, options)) return error.OutputTooSmall;
    const block_size = try blockMaxSize(options.block_max_code);
    var op: usize = 0;
    std.mem.writeInt(u32, dst[0..4], frame_magic, .little);
    var flg: u8 = (1 << 6) | 0x20;
    if (options.block_checksum) flg |= 0x10;
    if (options.content_size) flg |= 0x08;
    if (options.content_checksum) flg |= 0x04;
    dst[4] = flg;
    dst[5] = options.block_max_code << 4;
    op = 6;
    if (options.content_size) {
        std.mem.writeInt(u64, dst[op..][0..8], src.len, .little);
        op += 8;
    }
    dst[op] = @truncate(XxHash32.hash(0, dst[4..op]) >> 8);
    op += 1;
    var ip: usize = 0;
    while (ip < src.len) {
        const chunk = src[ip..@min(src.len, ip + block_size)];
        ip += chunk.len;
        const body = dst[op + 4 ..];
        const n = try c.compressBlock(chunk, body);
        var stored: []const u8 = body[0..n];
        if (n >= chunk.len) {
            // Incompressible: store raw.
            @memcpy(body[0..chunk.len], chunk);
            stored = body[0..chunk.len];
            std.mem.writeInt(u32, dst[op..][0..4], @as(u32, @intCast(chunk.len)) | 0x80000000, .little);
        } else {
            std.mem.writeInt(u32, dst[op..][0..4], @intCast(n), .little);
        }
        op += 4 + stored.len;
        if (options.block_checksum) {
            std.mem.writeInt(u32, dst[op..][0..4], XxHash32.hash(0, stored), .little);
            op += 4;
        }
    }
    std.mem.writeInt(u32, dst[op..][0..4], 0, .little);
    op += 4;
    if (options.content_checksum) {
        std.mem.writeInt(u32, dst[op..][0..4], XxHash32.hash(0, src), .little);
        op += 4;
    }
    return op;
}

/// Compresses into newly allocated memory.
pub fn compressAlloc(gpa: std.mem.Allocator, src: []const u8, options: FrameOptions) (Error || error{OutOfMemory})![]u8 {
    const c = try gpa.create(Compressor);
    defer gpa.destroy(c);
    const buf = try gpa.alloc(u8, compressFrameBound(src.len, options));
    errdefer gpa.free(buf);
    const n = try compressFrame(c, src, buf, options);
    return gpa.realloc(buf, n);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const fixtures = struct {
    const text = @embedFile("fixtures/text.bin");
    const random = @embedFile("fixtures/random.bin");
    const hgt_rows = @embedFile("fixtures/hgt_rows.bin");
    const empty = "";
};

fn expectFrame(compressed: []const u8, expected: []const u8) !void {
    const out = try testing.allocator.alloc(u8, expected.len + 64);
    defer testing.allocator.free(out);
    const r = try decompressFrames(compressed, out);
    try testing.expectEqual(compressed.len, r.consumed);
    try testing.expectEqualSlices(u8, expected, out[0..r.written]);
}

test "decompresses frames made by the reference lz4 tool" {
    try expectFrame(@embedFile("fixtures/text.default.lz4"), fixtures.text);
    try expectFrame(@embedFile("fixtures/text.linked.lz4"), fixtures.text);
    try expectFrame(@embedFile("fixtures/text.b4_blockcrc_size.lz4"), fixtures.text);
    try expectFrame(@embedFile("fixtures/text.hc.lz4"), fixtures.text);
    try expectFrame(@embedFile("fixtures/random.default.lz4"), fixtures.random);
    try expectFrame(@embedFile("fixtures/hgt_rows.default.lz4"), fixtures.hgt_rows);
    try expectFrame(@embedFile("fixtures/hgt_rows.b5_nocrc.lz4"), fixtures.hgt_rows);
    try expectFrame(@embedFile("fixtures/empty.default.lz4"), fixtures.empty);
}

test "frame header is parsed and checked" {
    const f = @embedFile("fixtures/text.b4_blockcrc_size.lz4");
    const info = try readFrameHeader(f);
    try testing.expect(info.block_checksum);
    try testing.expectEqual(@as(?u64, fixtures.text.len), info.content_size);
    try testing.expectEqual(@as(usize, 64 * 1024), info.block_max_size);
    var bad = f[0..32].*;
    bad[6] ^= 0x01; // corrupt the content size: header checksum fails
    try testing.expectError(error.ChecksumMismatch, readFrameHeader(&bad));
}

test "corrupt content checksum is reported" {
    const f = @embedFile("fixtures/text.default.lz4");
    const copy = try testing.allocator.dupe(u8, f);
    defer testing.allocator.free(copy);
    copy[copy.len - 1] ^= 0xff;
    const out = try testing.allocator.alloc(u8, fixtures.text.len);
    defer testing.allocator.free(out);
    try testing.expectError(error.ChecksumMismatch, decompressFrames(copy, out));
}

test "round trip through our compressor" {
    inline for (.{ fixtures.text, fixtures.random, fixtures.hgt_rows, fixtures.empty, "a", "abcdabcdabcdabcdabcdabcd", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) |input| {
        const z = try compressAlloc(testing.allocator, input, .{});
        defer testing.allocator.free(z);
        const back = try decompressAlloc(testing.allocator, z, 1 << 24);
        defer testing.allocator.free(back);
        try testing.expectEqualSlices(u8, input, back);
    }
    const z = try compressAlloc(testing.allocator, fixtures.text, .{ .block_max_code = 4, .block_checksum = true });
    defer testing.allocator.free(z);
    try testing.expect(z.len < fixtures.text.len / 2);
}

test "block round trip on random structured data" {
    var prng = std.Random.DefaultPrng.init(99);
    const r = prng.random();
    const c = try testing.allocator.create(Compressor);
    defer testing.allocator.destroy(c);
    var src: [5000]u8 = undefined;
    var dst: [compressBound(5000)]u8 = undefined;
    var back: [5000]u8 = undefined;
    for (0..300) |_| {
        const len = r.uintLessThan(usize, src.len);
        const alphabet = r.intRangeAtMost(u8, 1, 255);
        for (src[0..len]) |*b| b.* = r.uintLessThan(u8, alphabet);
        const n = try c.compressBlock(src[0..len], &dst);
        const out = try decompressBlock(dst[0..n], &back);
        try testing.expectEqualSlices(u8, src[0..len], out);
    }
}

test "decompressor never reads or writes out of bounds on random input" {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    var src: [256]u8 = undefined;
    var dst: [1024]u8 = undefined;
    for (0..20000) |_| {
        const len = r.uintLessThan(usize, src.len);
        r.bytes(src[0..len]);
        _ = decompressBlock(src[0..len], &dst) catch {};
        _ = decompressFrames(src[0..len], &dst) catch {};
    }
}

test "decompressAlloc refuses outputs over the limit" {
    const z = try compressAlloc(testing.allocator, fixtures.text, .{});
    defer testing.allocator.free(z);
    try testing.expectError(error.TooLarge, decompressAlloc(testing.allocator, z, 1000));
}
