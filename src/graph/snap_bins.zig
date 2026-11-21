//! Ordered correlation bins from a single-level Valhalla tile import.
const std = @import("std");
const geo = @import("../geo/root.zig");
const io = @import("../infra/io.zig");

pub const bins_per_tile = 25;
const tile_count = 1440 * 720;

pub const Tile = extern struct {
    id: u32,
    ends: [bins_per_tile]u32,
};

pub const words_per_tile = @sizeOf(Tile) / @sizeOf(u32);

pub const Entry = extern struct {
    edge: u32,
    circle: Circle,
};

/// Hash of the source GraphId in the pinned Meili candidate set.
/// Keep the native directory four-byte aligned.
pub const SourceHash = extern struct {
    low: u32,
    high: u32,

    pub fn fromGraphId(raw: u64) SourceHash {
        var mixed = (raw ^ (raw >> 33)) *% 0xff51afd7ed558ccd;
        mixed = (mixed ^ (mixed >> 33)) *% 0xc4ceb9fe1a85ec53;
        const hash = mixed ^ (mixed >> 33);
        return .{ .low = @truncate(hash), .high = @truncate(hash >> 32) };
    }

    pub fn value(self: SourceHash) u64 {
        return @as(u64, self.high) << 32 | self.low;
    }
};

// Ported from src/baldr/boundingcircle.cc (Valhalla 3.9.3).
pub const Circle = packed struct(u32) {
    y: u13,
    x: u13,
    radius_index: u6,

    pub const absent: Circle = .{ .x = 8191, .y = 8191, .radius_index = 0 };
    const radii = [64]u16{
        1,   2,   3,   4,   5,   6,   7,   8,   9,   10,  13,  15,  17,   18,   20,   23,
        25,  27,  30,  35,  40,  43,  45,  50,  55,  60,  65,  70,  75,   80,   85,   90,
        95,  100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200, 210,  220,  230,  240,
        250, 275, 300, 325, 350, 375, 400, 500, 550, 600, 700, 800, 1000, 1500, 2000, 2500,
    };
    const meters_per_degree = geo.constants.meters_per_degree_lat;
    const max_offset = 0.025 * meters_per_degree + 2500;

    fn offset(value: u13) f64 {
        return @as(f64, @floatFromInt(value)) / 8191.0 * (2 * max_offset) - max_offset;
    }

    pub fn valid(self: Circle) bool {
        return @as(u32, @bitCast(self)) != @as(u32, @bitCast(absent));
    }

    pub fn radius(self: Circle) f64 {
        return @floatFromInt(radii[self.radius_index]);
    }

    pub fn center(self: Circle, bin: geo.DistanceApproximator) geo.PointLL {
        return .init(bin.center_lng + offset(self.x) / bin.m_per_lng_degree, bin.center_lat + offset(self.y) / meters_per_degree);
    }

    pub const LatitudeBand = struct {
        const small_radius_index = 33;

        first: i32,
        last: i32,

        pub fn excludes(self: LatitudeBand, circle: Circle) bool {
            return circle.valid() and circle.radius_index <= small_radius_index and
                (circle.y < self.first or circle.y > self.last);
        }
    };

    /// A conservative latitude-only rejection before decoding small circles.
    pub fn latitudeBand(point: f64, origin: f64, reach: f64) LatitudeBand {
        const scale = 8191.0 / (2 * max_offset);
        const center_index = ((point - origin) * meters_per_degree + max_offset) * scale;
        // Round the limits out past a full quantization step.
        const margin = (reach + radii[LatitudeBand.small_radius_index]) * scale + 1;
        return .{
            .first = @intFromFloat(std.math.clamp(@floor(center_index - margin), -1, 8192)),
            .last = @intFromFloat(std.math.clamp(@ceil(center_index + margin), -1, 8192)),
        };
    }
};

test "latitude screening preserves nearby, absent and large circles" {
    const inside: Circle = .{ .x = 0, .y = 4096, .radius_index = 0 };
    const outside: Circle = .{ .x = 0, .y = 0, .radius_index = 0 };
    const large: Circle = .{ .x = 0, .y = 0, .radius_index = 63 };
    const band = Circle.latitudeBand(0, 0, 10);
    try std.testing.expect(!band.excludes(inside));
    try std.testing.expect(band.excludes(outside));
    try std.testing.expect(!band.excludes(large));
    try std.testing.expect(!band.excludes(.absent));
    const unbounded = Circle.latitudeBand(90, -90, std.math.maxInt(u32));
    try std.testing.expect(!unbounded.excludes(outside));
}

pub const View = struct {
    tiles: []const Tile,
    entries: []const Entry,
    source_hashes: ?[]const SourceHash = null,

    pub fn parse(words: []const u32) !View {
        if (words.len == 0 or words[0] == 0 or words[0] > (words.len - 1) / words_per_tile)
            return error.InvalidSnapBinDirectory;
        const limit = 1 + @as(usize, words[0]) * words_per_tile;
        const tiles = std.mem.bytesAsSlice(Tile, std.mem.sliceAsBytes(words[1..limit]));
        const count = tiles[tiles.len - 1].ends[bins_per_tile - 1];
        const words_per_entry = @sizeOf(Entry) / @sizeOf(u32);
        if (count > (words.len - limit) / words_per_entry) return error.InvalidSnapBinDirectory;
        const end = limit + @as(usize, count) * words_per_entry;
        const entries = std.mem.bytesAsSlice(Entry, std.mem.sliceAsBytes(words[limit..end]));
        const hashes = words[end..];
        if (hashes.len == 0) return .{ .tiles = tiles, .entries = entries };
        if (hashes.len != end - limit) return error.InvalidSnapBinDirectory;
        return .{
            .tiles = tiles,
            .entries = entries,
            .source_hashes = std.mem.bytesAsSlice(SourceHash, std.mem.sliceAsBytes(hashes)),
        };
    }

    const Range = struct { begin: usize = 0, end: usize = 0 };

    fn rangeIn(self: View, tile: u32, bin: u16) !Range {
        if (bin >= bins_per_tile) return error.InvalidSnapBin;
        const index = std.sort.lowerBound(Tile, self.tiles, tile, struct {
            fn compare(id: u32, entry: Tile) std.math.Order {
                return std.math.order(id, entry.id);
            }
        }.compare);
        if (index == self.tiles.len or self.tiles[index].id != tile) return .{};
        const record = &self.tiles[index];
        const begin = if (bin != 0) record.ends[bin - 1] else if (index != 0) self.tiles[index - 1].ends[bins_per_tile - 1] else 0;
        const end = record.ends[bin];
        if (begin > end or end > self.entries.len) return error.InvalidSnapBinOffsets;
        return .{ .begin = begin, .end = end };
    }

    pub fn edgesIn(self: View, tile: u32, bin: u16) ![]const Entry {
        const range = try self.rangeIn(tile, bin);
        return self.entries[range.begin..range.end];
    }

    pub const OrderedEntries = struct {
        edges: []const Entry,
        hashes: []const SourceHash,
    };

    pub fn orderedEdgesIn(self: View, tile: u32, bin: u16) !OrderedEntries {
        const range = try self.rangeIn(tile, bin);
        const hashes = self.source_hashes orelse return error.MissingSnapSourceHashes;
        return .{ .edges = self.entries[range.begin..range.end], .hashes = hashes[range.begin..range.end] };
    }

    pub fn verify(self: View, edge_count: usize, deadline: io.Deadline) !void {
        var previous: ?u32 = null;
        var offset: u32 = 0;
        for (self.tiles) |tile| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (tile.id >= tile_count or (previous != null and tile.id <= previous.?)) return error.InvalidSnapBinDirectory;
            for (tile.ends) |end| {
                if (end < offset or end > self.entries.len) return error.InvalidSnapBinOffsets;
                offset = end;
            }
            previous = tile.id;
        }
        for (self.entries, 0..) |entry, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (entry.edge >= edge_count) return error.InvalidSnapBinEdge;
        }
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Tile) == 104 and @offsetOf(Tile, "id") == 0 and @offsetOf(Tile, "ends") == 4);
    std.debug.assert(@sizeOf(Entry) == 8 and @offsetOf(Entry, "edge") == 0 and @offsetOf(Entry, "circle") == 4);
    std.debug.assert(@sizeOf(SourceHash) == 8 and @offsetOf(SourceHash, "low") == 0 and @offsetOf(SourceHash, "high") == 4);
}
