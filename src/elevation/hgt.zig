//! SRTM elevation tiles and sampling.
//!
//! Ported from src/skadi/sample.cc (Valhalla 3.9.3). Tiles are 1x1 degree
//! `.hgt` files of 3601x3601 big-endian int16 samples, optionally `.gz` or
//! `.lz4` compressed, named `[NS]dd[WE]ddd` after their south-west corner
//! and found anywhere under the data directory. Raw tiles are memory
//! mapped; compressed tiles are decompressed on first use into a bounded
//! cache (upstream keeps up to 50 unpacked tiles). Sampling is bilinear
//! with upstream's exact no-data handling: samples outside [-16384, 16384]
//! drop out of the weighting, and a point with no valid neighbours is
//! `no_data_value` (-32768).

const std = @import("std");
const io = @import("../infra/io.zig");
const lz4 = @import("lz4");
const PointLL = @import("../geo/point.zig").PointLL;
const Allocator = std.mem.Allocator;

pub const hgt_dim = 3601;
pub const hgt_pixels = hgt_dim * hgt_dim;
pub const hgt_bytes = 2 * hgt_pixels;
pub const no_data_value: f64 = -32768;
const no_data_high: i16 = 16384;
const no_data_low: i16 = -16384;
pub const tile_count = 180 * 360;
pub const unpacked_tiles_max = 50;

pub const Format = enum(u8) { unknown, raw, gzip, lz4 };

/// Tile index of the tile containing a coordinate, computed as upstream
/// does (including its uint16 casts: longitude 180 lands in the next row).
pub fn tileIndex(p: PointLL) u32 {
    return tileIndexAt(@floor(p.lng), @floor(p.lat));
}

inline fn tileIndexAt(lon: f64, lat: f64) u32 {
    const ilat: u16 = @intFromFloat(@max(0, lat + 90));
    const ilon: u16 = @intFromFloat(@max(0, lon + 180));
    return @as(u32, ilat) * 360 + ilon;
}

pub const GridPosition = struct {
    tile: u32,
    u: f64,
    v: f64,

    pub inline fn at(p: PointLL) GridPosition {
        const lon = @floor(p.lng);
        const lat = @floor(p.lat);
        return .{
            .tile = tileIndexAt(lon, lat),
            .u = (p.lng - lon) * (hgt_dim - 1),
            .v = (1.0 - (p.lat - lat)) * (hgt_dim - 1),
        };
    }
};

/// "N47E008.hgt"-style name (without directory) for a tile index.
pub fn tileName(index: u32, buf: []u8) []const u8 {
    const x: i32 = @as(i32, @intCast(index % 360)) - 180;
    const y: i32 = @as(i32, @intCast(index / 360)) - 90;
    return std.fmt.bufPrint(buf, "{s}{d:0>2}{s}{d:0>3}.hgt", .{ if (y < 0) "S" else "N", @abs(y), if (x < 0) "W" else "E", @abs(x) }) catch unreachable;
}

pub const ParsedName = struct { index: u32, format: Format };

/// Parses a tile file name like upstream's regex
/// `.*[/\\]([NS])([0-9]{2})([WE])([0-9]{3})\.hgt(\.(gz|lz4))?$`.
pub fn parseName(path: []const u8) ?ParsedName {
    const sep = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return null;
    const name = path[sep + 1 ..];
    if (name.len < 11 or !std.mem.eql(u8, name[7..11], ".hgt")) return null;
    const ext = name[11..];
    const format: Format = if (ext.len == 0) .raw else if (std.mem.eql(u8, ext, ".gz")) .gzip else if (std.mem.eql(u8, ext, ".lz4")) .lz4 else return null;
    if (name[0] != 'N' and name[0] != 'S') return null;
    if (name[3] != 'W' and name[3] != 'E') return null;
    for (name[1..3]) |ch| if (!std.ascii.isDigit(ch)) return null;
    for (name[4..7]) |ch| if (!std.ascii.isDigit(ch)) return null;
    const lat_abs = std.fmt.parseInt(i32, name[1..3], 10) catch return null;
    const lon_abs = std.fmt.parseInt(i32, name[4..7], 10) catch return null;
    const lat = (if (name[0] == 'N') lat_abs else -lat_abs) + 90;
    const lon = (if (name[3] == 'E') lon_abs else -lon_abs) + 180;
    if (lon < 0 or lon >= 360 or lat < 0 or lat >= 180) return null;
    return .{ .index = @intCast(lat * 360 + lon), .format = format };
}

const Slot = struct {
    format: Format = .unknown,
    map: ?io.Mapping = null,
    /// Decompressed samples for gzip/lz4 tiles (owned).
    unpacked: ?[]align(2) u8 = null,
    /// LRU stamp for unpacked tiles.
    used_at: u64 = 0,
    failed: bool = false,
};

/// Index of the tiles under a data directory, with lazy decompression.
/// Thread-safe: lookups of raw tiles take no lock; decompression of a
/// compressed tile is serialized by a mutex.
pub const Tiles = struct {
    gpa: Allocator,
    slots: []Slot,
    mutex: std.atomic.Mutex = .unlocked,
    clock: u64 = 0,
    unpacked_count: usize = 0,
    count: usize = 0,
    owns_mappings: bool = true,

    pub fn init(gpa: Allocator, data_dir: []const u8) Allocator.Error!Tiles {
        var self = try empty(gpa);
        const trimmed = trimPath(data_dir);
        if (trimmed.len > 0) io.walkFiles(trimmed, &self, addFile);
        return self;
    }

    /// Build inputs choose duplicates by encoding, then by bytes. Neither
    /// filesystem iteration order nor the tile's storage path decides.
    pub fn initBuild(gpa: Allocator, data_dir: []const u8, deadline: io.Deadline) !Tiles {
        var self = try empty(gpa);
        errdefer self.deinit();
        const path = trimPath(data_dir);
        const dir = try io.Directory.open(path);
        defer dir.close();
        const Scan = struct {
            tiles: *Tiles,
            deadline: io.Deadline,

            fn visit(scan: @This(), file: []const u8) !void {
                const parsed = parseName(file) orelse return;
                const slot = &scan.tiles.slots[parsed.index];
                if (slot.map != null and @backingInt(parsed.format) > @backingInt(slot.format)) return;
                const map = mapTile(file, parsed.format) orelse return;
                errdefer map.unmap();
                if (slot.map) |previous| {
                    if (parsed.format == slot.format and !try bytesLess(map.bytes, previous.bytes, scan.deadline)) {
                        map.unmap();
                        return;
                    }
                    previous.unmap();
                } else {
                    scan.tiles.count += 1;
                }
                slot.* = .{ .format = parsed.format, .map = map };
            }
        };
        try io.walkFilesUntil(path, deadline, Scan{ .tiles = &self, .deadline = deadline }, Scan.visit);
        return self;
    }

    /// Each worker owns its decompression cache and borrows the same
    /// immutable source mappings. The catalog outlives all worker copies.
    pub fn borrowMappings(self: *const Tiles, gpa: Allocator, deadline: io.Deadline) !Tiles {
        const slots = try gpa.alloc(Slot, self.slots.len);
        errdefer gpa.free(slots);
        for (slots, self.slots, 0..) |*out, slot, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            out.* = .{ .format = slot.format, .map = slot.map };
        }
        return .{ .gpa = gpa, .slots = slots, .count = self.count, .owns_mappings = false };
    }

    pub fn fingerprint(self: *const Tiles, deadline: io.Deadline) ![32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("zr-hgt-v1");
        for (self.slots, 0..) |slot, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const map = slot.map orelse continue;
            var header: [13]u8 = undefined;
            std.mem.writeInt(u32, header[0..4], @intCast(i), .little);
            header[4] = @backingInt(slot.format);
            std.mem.writeInt(u64, header[5..13], map.bytes.len, .little);
            hash.update(&header);
            var rest: []const u8 = map.bytes;
            while (rest.len != 0) {
                if (deadline.expired()) return error.DeadlineExceeded;
                const count = @min(rest.len, 1024 * 1024);
                hash.update(rest[0..count]);
                rest = rest[count..];
            }
        }
        return hash.finalResult();
    }

    fn empty(gpa: Allocator) Allocator.Error!Tiles {
        const slots = try gpa.alloc(Slot, tile_count);
        @memset(slots, .{});
        return .{ .gpa = gpa, .slots = slots };
    }

    fn trimPath(data_dir: []const u8) []const u8 {
        var trimmed = data_dir;
        while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
        return trimmed;
    }

    pub fn deinit(self: *Tiles) void {
        for (self.slots) |*s| {
            if (self.owns_mappings) if (s.map) |m| m.unmap();
            if (s.unpacked) |u| self.gpa.free(u);
        }
        self.gpa.free(self.slots);
    }

    fn addFile(self: *Tiles, path: []const u8) void {
        const parsed = parseName(path) orelse return;
        const slot = &self.slots[parsed.index];
        if (slot.map != null) return; // first one found wins
        const map = mapTile(path, parsed.format) orelse return;
        slot.* = .{ .format = parsed.format, .map = map };
        self.count += 1;
    }

    fn mapTile(path: []const u8, format: Format) ?io.Mapping {
        const map = io.Mapping.mapFile(path, .read_only) catch return null;
        if (format == .raw and map.bytes.len != hgt_bytes) {
            map.unmap();
            return null;
        }
        map.adviseAll(.random) catch {};
        return map;
    }

    fn bytesLess(a: []const u8, b: []const u8, deadline: io.Deadline) !bool {
        const common = @min(a.len, b.len);
        var offset: usize = 0;
        while (offset < common) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const len = @min(common - offset, 1024 * 1024);
            const order = std.mem.order(u8, a[offset..][0..len], b[offset..][0..len]);
            if (order != .eq) return order == .lt;
            offset += len;
        }
        return a.len < b.len;
    }

    /// Decodes a tile into `out` (big-endian int16 bytes, `hgt_bytes` long)
    /// without touching the shared cache, so callers can decode tiles in
    /// parallel. False when the tile is absent or does not decode.
    pub fn readTile(self: *const Tiles, index: u32, out: []u8) bool {
        if (index >= tile_count or out.len != hgt_bytes) return false;
        const slot = &self.slots[index];
        return switch (slot.format) {
            .unknown => false,
            .raw => blk: {
                @memcpy(out, slot.map.?.bytes);
                break :blk true;
            },
            .gzip => inflateGzip(slot.map.?.bytes, out),
            .lz4 => blk: {
                const r = lz4.decompressFrames(slot.map.?.bytes, out) catch break :blk false;
                break :blk r.written == hgt_bytes;
            },
        };
    }

    /// Indices of the tiles found, ascending.
    pub fn indices(self: *const Tiles, gpa: Allocator) Allocator.Error![]u32 {
        var list: std.ArrayList(u32) = .empty;
        for (self.slots, 0..) |s, i| if (s.format != .unknown) try list.append(gpa, @intCast(i));
        return list.toOwnedSlice(gpa);
    }

    /// Samples of a tile as big-endian int16 bytes, or null without data.
    pub fn samples(self: *Tiles, index: u32) ?[]const u8 {
        if (index >= tile_count) return null;
        const slot = &self.slots[index];
        switch (slot.format) {
            .unknown => return null,
            .raw => return slot.map.?.bytes,
            .gzip, .lz4 => {},
        }
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.clock += 1;
        if (slot.unpacked) |u| {
            slot.used_at = self.clock;
            return u;
        }
        if (slot.failed) return null;
        const buf = self.takeBuffer() orelse return null;
        const ok = switch (slot.format) {
            .gzip => inflateGzip(slot.map.?.bytes, buf),
            .lz4 => blk: {
                const r = lz4.decompressFrames(slot.map.?.bytes, buf) catch break :blk false;
                break :blk r.written == hgt_bytes;
            },
            else => unreachable,
        };
        if (!ok) {
            self.gpa.free(buf);
            self.unpacked_count -= 1;
            slot.failed = true;
            return null;
        }
        slot.unpacked = buf;
        slot.used_at = self.clock;
        return buf;
    }

    /// A buffer for one unpacked tile: a new one under the limit, otherwise
    /// the least recently used tile's.
    fn takeBuffer(self: *Tiles) ?[]align(2) u8 {
        if (self.unpacked_count < unpacked_tiles_max) {
            const buf = self.gpa.alignedAlloc(u8, .@"2", hgt_bytes) catch return null;
            self.unpacked_count += 1;
            return buf;
        }
        var oldest: ?*Slot = null;
        for (self.slots) |*s| if (s.unpacked != null and (oldest == null or s.used_at < oldest.?.used_at)) {
            oldest = s;
        };
        const victim = oldest orelse return null;
        const buf = victim.unpacked.?;
        victim.unpacked = null;
        return buf;
    }
};

fn inflateGzip(src: []const u8, dst: []u8) bool {
    var in: std.Io.Reader = .fixed(src);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d = std.compress.flate.Decompress.init(&in, .gzip, &window);
    d.reader.readSliceAll(dst) catch return false;
    return true;
}

/// Posts of an unpacked .hgt tile (big-endian int16, row-major from the
/// north-west corner), as `interpolateWith` reads them.
pub const BigEndianPosts = struct {
    data: []const u8,
    pub inline fn sample(self: BigEndianPosts, i: usize) i16 {
        return std.mem.readInt(i16, self.data[i * 2 ..][0..2], .big);
    }
};

inline fn outOfRange(v: i16) bool {
    return v > no_data_high or v < no_data_low;
}

/// skadi `tile_data::get(u, v)`: bilinear interpolation over the four
/// neighbouring samples, dropping no-data samples from the weights.
pub fn interpolate(data: []const u8, u: f64, v: f64) f64 {
    return interpolateWith(BigEndianPosts{ .data = data }, u, v);
}

/// `interpolate` over any post source with `sample(linear_index) i16`, so
/// the packed reader shares the exact arithmetic. Indices are linear in a
/// 3601-wide tile, as upstream reads them (x + 1 = 3601 is the next row).
pub fn interpolateWith(src: anytype, u: f64, v: f64) f64 {
    const x: usize = @intFromFloat(@floor(u));
    const y: usize = @intFromFloat(@floor(v));
    const u_ratio = u - @as(f64, @floatFromInt(x));
    const v_ratio = v - @as(f64, @floatFromInt(y));
    const u_inv = 1 - u_ratio;
    const v_inv = 1 - v_ratio;
    var a_coef = u_inv * v_inv;
    var b_coef = u_ratio * v_inv;
    var c_coef = u_inv * v_ratio;
    var d_coef = u_ratio * v_ratio;
    var adjust: f64 = 0;
    const a = src.sample(y * hgt_dim + x);
    const b = src.sample(y * hgt_dim + x + 1);
    if (outOfRange(a)) a_coef = 0;
    if (outOfRange(b)) b_coef = 0;
    var value = @as(f64, @floatFromInt(a)) * a_coef + @as(f64, @floatFromInt(b)) * b_coef;
    adjust += a_coef + b_coef;
    if (y < hgt_dim - 1) {
        const cc = src.sample((y + 1) * hgt_dim + x);
        const d = src.sample((y + 1) * hgt_dim + x + 1);
        if (outOfRange(cc)) c_coef = 0;
        if (outOfRange(d)) d_coef = 0;
        value += @as(f64, @floatFromInt(cc)) * c_coef + @as(f64, @floatFromInt(d)) * d_coef;
        adjust += c_coef + d_coef;
    }
    if (adjust == 0) return no_data_value;
    return value / adjust;
}

pub const batch_width = 4;

/// Vector interpolation of interior points. The scalar expression, including
/// the normalization by the sum of the four weights, fixes the rounding order.
pub fn interpolateBatch(src: anytype, points: *const [batch_width]GridPosition) [batch_width]f64 {
    const F64 = @Vector(batch_width, f64);
    const Index = @Vector(batch_width, usize);
    const Posts = @Vector(batch_width, i16);
    var us: [batch_width]f64 = undefined;
    var vs: [batch_width]f64 = undefined;
    inline for (0..batch_width) |i| {
        us[i] = points[i].u;
        vs[i] = points[i].v;
    }
    const u: F64 = us;
    const v: F64 = vs;
    const xl = @floor(u);
    const yl = @floor(v);
    if (@reduce(.Or, xl >= @as(F64, @splat(hgt_dim - 1))) or @reduce(.Or, yl >= @as(F64, @splat(hgt_dim - 1)))) {
        return scalarBatch(src, points);
    }
    const x: Index = @intFromFloat(xl);
    const y: Index = @intFromFloat(yl);
    const offset = y * @as(Index, @splat(hgt_dim)) + x;
    var a: Posts = undefined;
    var b: Posts = undefined;
    var c: Posts = undefined;
    var d: Posts = undefined;
    inline for (0..batch_width) |i| {
        a[i] = src.sample(offset[i]);
        b[i] = src.sample(offset[i] + 1);
        c[i] = src.sample(offset[i] + hgt_dim);
        d[i] = src.sample(offset[i] + hgt_dim + 1);
    }
    const low: Posts = @splat(no_data_low);
    const high: Posts = @splat(no_data_high);
    if (@reduce(.Or, (a < low) | (b < low) | (c < low) | (d < low) |
        (a > high) | (b > high) | (c > high) | (d > high)))
    {
        return scalarBatch(src, points);
    }

    const ur = u - xl;
    const vr = v - yl;
    const ui = @as(F64, @splat(1)) - ur;
    const vi = @as(F64, @splat(1)) - vr;
    const aw = ui * vi;
    const bw = ur * vi;
    const cw = ui * vr;
    const dw = ur * vr;
    const upper = @as(F64, @floatFromInt(a)) * aw + @as(F64, @floatFromInt(b)) * bw;
    const lower = @as(F64, @floatFromInt(c)) * cw + @as(F64, @floatFromInt(d)) * dw;
    return (upper + lower) / ((aw + bw) + (cw + dw));
}

fn scalarBatch(src: anytype, points: *const [batch_width]GridPosition) [batch_width]f64 {
    var values: [batch_width]f64 = undefined;
    for (points, &values) |p, *out| out.* = interpolateWith(src, p.u, p.v);
    return values;
}

/// Tile reuse for sequential points, including points emitted by a resampler.
pub const Sampler = struct {
    tiles: *Tiles,
    index: u32 = std.math.maxInt(u32),
    data: ?[]const u8 = null,

    pub fn select(self: *Sampler, index: u32) bool {
        if (index != self.index) {
            self.index = index;
            self.data = self.tiles.samples(index);
        }
        return self.data != null;
    }

    pub fn sample(self: *const Sampler, p: GridPosition) f64 {
        return interpolate(self.data.?, p.u, p.v);
    }

    pub fn sampleBatch(self: *const Sampler, points: *const [batch_width]GridPosition) [batch_width]f64 {
        return interpolateBatch(BigEndianPosts{ .data = self.data.? }, points);
    }

    pub fn get(self: *Sampler, point: PointLL) f64 {
        const p = GridPosition.at(point);
        return if (self.select(p.tile)) self.sample(p) else no_data_value;
    }
};

/// The cursor selects a tile once for a group of consecutive points in it.
pub fn sampleAll(sampler: anytype, pts: []const PointLL, out: []f64, deadline: io.Deadline) error{DeadlineExceeded}!void {
    var i: usize = 0;
    var next_check: usize = 0;
    while (i < pts.len) {
        if (i >= next_check) {
            if (deadline.expired()) return error.DeadlineExceeded;
            next_check = i + 1024;
        }
        const first = GridPosition.at(pts[i]);
        const available = sampler.select(first.tile);
        var positions: [batch_width]GridPosition = undefined;
        positions[0] = first;
        var n: usize = 1;
        while (n < batch_width and i + n < pts.len) : (n += 1) {
            const p = GridPosition.at(pts[i + n]);
            if (p.tile != first.tile) break;
            positions[n] = p;
        }
        if (!available) {
            @memset(out[i..][0..n], no_data_value);
        } else if (n == batch_width) {
            out[i..][0..batch_width].* = sampler.sampleBatch(&positions);
        } else {
            for (positions[0..n], out[i..][0..n]) |p, *value| value.* = sampler.sample(p);
        }
        i += n;
    }
}

/// Elevation at a point (skadi `sample::get`), or `no_data_value`.
pub fn get(tiles: *Tiles, p: PointLL) f64 {
    const index = tileIndex(p);
    const data = tiles.samples(index) orelse return no_data_value;
    const lon = @floor(p.lng);
    const lat = @floor(p.lat);
    const u = (p.lng - lon) * (hgt_dim - 1);
    const v = (1.0 - (p.lat - lat)) * (hgt_dim - 1);
    return interpolate(data, u, v);
}

/// Elevations of many points (skadi `sample::get_all`), written to `out`.
/// Consecutive points in the same tile reuse its sample pointer.
pub fn getAll(tiles: *Tiles, pts: []const PointLL, out: []f64) void {
    std.debug.assert(out.len >= pts.len);
    var cur_index: u32 = std.math.maxInt(u32);
    var cur: ?[]const u8 = null;
    for (pts, out[0..pts.len]) |p, *o| {
        const index = tileIndex(p);
        if (index != cur_index) {
            cur_index = index;
            cur = tiles.samples(index);
        }
        const data = cur orelse {
            o.* = no_data_value;
            continue;
        };
        const lon = @floor(p.lng);
        const lat = @floor(p.lat);
        o.* = interpolate(data, (p.lng - lon) * (hgt_dim - 1), (1.0 - (p.lat - lat)) * (hgt_dim - 1));
    }
}

// ---------------------------------------------------------------------------
// Tests: ported from test/util_skadi.cc and test/sample.cc behaviour
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tile names and indices" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("N47E008.hgt", tileName(tileIndex(.{ .lng = 8.54, .lat = 47.37 }), &buf));
    try testing.expectEqualStrings("S34W059.hgt", tileName(tileIndex(.{ .lng = -58.38, .lat = -33.6 }), &buf));
    try testing.expectEqualStrings("N00E000.hgt", tileName(tileIndex(.{ .lng = 0.5, .lat = 0.5 }), &buf));
    try testing.expectEqualStrings("S01W001.hgt", tileName(tileIndex(.{ .lng = -0.5, .lat = -0.5 }), &buf));
    const p = parseName("/data/N47/N47E008.hgt.lz4").?;
    try testing.expectEqual(Format.lz4, p.format);
    try testing.expectEqual(tileIndex(.{ .lng = 8.54, .lat = 47.37 }), p.index);
    try testing.expectEqual(Format.gzip, parseName("x/S34W059.hgt.gz").?.format);
    try testing.expectEqual(@as(?ParsedName, null), parseName("N47E008.hgt")); // needs a directory separator
    try testing.expectEqual(@as(?ParsedName, null), parseName("/d/N47E008.hgt.zip"));
    try testing.expectEqual(@as(?ParsedName, null), parseName("/d/N47E200.hgt"));
}

/// A synthetic tile: height = row + 2 * column, with a no-data hole.
pub fn writeTile(gpa: Allocator, dir: []const u8, name: []const u8, format: Format) !void {
    const raw = try gpa.alloc(u8, hgt_bytes);
    defer gpa.free(raw);
    for (0..hgt_dim) |r| for (0..hgt_dim) |col| {
        var v: i16 = @intCast((r + 2 * col) % 5000);
        if (r >= 100 and r < 102 and col >= 100 and col < 102) v = -32768;
        std.mem.writeInt(i16, raw[(r * hgt_dim + col) * 2 ..][0..2], v, .big);
    };
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    switch (format) {
        .raw => try io.writeFile(path, raw),
        .lz4 => {
            const z = try lz4.compressAlloc(gpa, raw, .{});
            defer gpa.free(z);
            try io.writeFile(path, z);
        },
        .gzip => {
            const z = try gpa.alloc(u8, hgt_bytes + (1 << 20));
            defer gpa.free(z);
            var out: std.Io.Writer = .fixed(z);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var raw_c = try std.compress.flate.Compress.Raw.init(&out, &window, .gzip);
            try raw_c.writer.writeAll(raw);
            try raw_c.finish();
            try io.writeFile(path, out.buffered());
        },
        else => unreachable,
    }
}

pub fn mkdir(path: []const u8) void {
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = std.c.mkdir(@ptrCast(&buf), 0o755);
}

pub fn rmTree(path: []const u8) void {
    const Del = struct {
        fn visit(_: void, file: []const u8) void {
            var b: [600]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&b, "{s}", .{file}, 0) catch return;
            _ = std.c.unlink(z);
        }
    };
    io.walkFiles(path, {}, Del.visit);
    var b: [600]u8 = undefined;
    _ = std.c.rmdir(std.fmt.bufPrintSentinel(&b, "{s}/N47", .{path}, 0) catch return);
    _ = std.c.rmdir(std.fmt.bufPrintSentinel(&b, "{s}", .{path}, 0) catch return);
}

test "sampling raw and lz4 tiles, no-data handling and edges" {
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/zig-routing-hgt-{d}", .{std.c.getpid()});
    mkdir(dir);
    defer rmTree(dir);
    var sub_buf: [256]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/N47", .{dir});
    mkdir(sub);
    try writeTile(testing.allocator, sub, "N47E008.hgt", .raw);
    try writeTile(testing.allocator, dir, "N46E008.hgt.lz4", .lz4);
    try writeTile(testing.allocator, dir, "N46E009.hgt.gz", .gzip);
    try io.writeFile(try std.fmt.bufPrint(&sub_buf, "{s}/N45E008.hgt", .{dir}), "too short");

    var tiles = try Tiles.init(testing.allocator, dir);
    defer tiles.deinit();
    try testing.expectEqual(@as(usize, 3), tiles.count);
    // The gzip tile decodes to the same pattern.
    try testing.expectApproxEqAbs(@as(f64, 3600), get(&tiles, .{ .lng = 9.0 + 900.0 / 3600.0, .lat = 47.0 - 1800.0 / 3600.0 }), 1e-6);

    // Exactly on a sample: row r counts from the north edge.
    // lat = 48 - r/3600, lng = 8 + col/3600 -> height r + 2*col.
    const r: f64 = 1800;
    const col: f64 = 900;
    try testing.expectApproxEqAbs(@as(f64, 1800 + 1800), get(&tiles, .{ .lng = 8.0 + col / 3600, .lat = 48.0 - r / 3600 }), 1e-6);
    // Half way between samples interpolates linearly.
    try testing.expectApproxEqAbs(@as(f64, 3601), get(&tiles, .{ .lng = 8.0 + (col + 0.5) / 3600, .lat = 48.0 - r / 3600 }), 1e-6);
    // The compressed tile gives the same pattern.
    try testing.expectApproxEqAbs(@as(f64, 3600), get(&tiles, .{ .lng = 8.0 + col / 3600, .lat = 47.0 - r / 3600 }), 1e-6);
    // Inside the no-data hole every neighbour is missing.
    try testing.expectEqual(no_data_value, get(&tiles, .{ .lng = 8.0 + 100.5 / 3600.0, .lat = 48.0 - 100.5 / 3600.0 }));
    // Next to the hole the missing samples drop out of the weights.
    const near = get(&tiles, .{ .lng = 8.0 + 99.5 / 3600.0, .lat = 48.0 - 99.5 / 3600.0 });
    try testing.expect(near != no_data_value);
    // The southern edge row (v = 3600) uses only the last row.
    try testing.expectApproxEqAbs(@as(f64, @mod(3600 + 2 * col, 5000)), get(&tiles, .{ .lng = 8.0 + col / 3600, .lat = 47.0 + 1e-12 }), 0.01);
    // Missing and corrupt tiles have no data.
    try testing.expectEqual(no_data_value, get(&tiles, .{ .lng = 9.5, .lat = 47.5 }));
    try testing.expectEqual(no_data_value, get(&tiles, .{ .lng = 8.5, .lat = 45.5 }));

    var out: [4]f64 = undefined;
    getAll(&tiles, &.{ .{ .lng = 8.0 + col / 3600, .lat = 48.0 - r / 3600 }, .{ .lng = 8.0 + col / 3600, .lat = 47.0 - r / 3600 }, .{ .lng = 9.5, .lat = 47.5 }, .{ .lng = 8.0 + col / 3600, .lat = 48.0 - r / 3600 } }, &out);
    try testing.expectApproxEqAbs(@as(f64, 3600), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 3600), out[1], 1e-6);
    try testing.expectEqual(no_data_value, out[2]);
}

test "build catalog selects duplicate tiles deterministically and fingerprints contents" {
    const root = try io.Directory.open(".");
    defer root.close();
    const left = try root.temporaryChild();
    defer root.deleteDir(&left.name) catch {};
    defer left.dir.close();
    const right = try root.temporaryChild();
    defer root.deleteDir(&right.name) catch {};
    defer right.dir.close();
    const sub = try left.dir.createChild("nested");
    defer left.dir.deleteDir("nested") catch {};
    defer sub.close();

    const name = "N47E008.hgt";
    const Sparse = struct {
        fn write(dir: io.Directory, tile: [:0]const u8, first: u8) !void {
            const file = try dir.openOrCreateFile(tile);
            defer file.close();
            try file.truncate(hgt_bytes);
            try file.pwriteAll(&.{ 0, first }, 0);
        }
    };
    try Sparse.write(left.dir, name, 2);
    defer left.dir.deleteFile(name) catch {};
    try Sparse.write(sub, name, 1);
    defer sub.deleteFile(name) catch {};
    try Sparse.write(right.dir, name, 1);
    defer right.dir.deleteFile(name) catch {};

    const index = tileIndex(.{ .lng = 8.5, .lat = 47.5 });
    var first = try Tiles.initBuild(testing.allocator, &left.name, .none);
    defer first.deinit();
    try testing.expectEqual(@as(usize, 1), first.count);
    try testing.expectEqualSlices(u8, &.{ 0, 1 }, first.samples(index).?[0..2]);
    const digest = try first.fingerprint(.none);
    {
        var second = try Tiles.initBuild(testing.allocator, &right.name, .none);
        defer second.deinit();
        try testing.expectEqual(digest, try second.fingerprint(.none));
        var borrower = try second.borrowMappings(testing.allocator, .none);
        borrower.deinit();
        try testing.expectEqualSlices(u8, &.{ 0, 1 }, second.samples(index).?[0..2]);
    }
    try Sparse.write(right.dir, name, 3);
    var changed = try Tiles.initBuild(testing.allocator, &right.name, .none);
    defer changed.deinit();
    try testing.expect(!std.mem.eql(u8, &digest, &try changed.fingerprint(.none)));
}
