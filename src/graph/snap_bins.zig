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
};

pub const View = struct {
    tiles: []const Tile,
    entries: []const Entry,

    pub fn parse(words: []const u32) !View {
        if (words.len == 0 or words[0] == 0 or words[0] > (words.len - 1) / words_per_tile)
            return error.InvalidSnapBinDirectory;
        const limit = 1 + @as(usize, words[0]) * words_per_tile;
        const tiles = std.mem.bytesAsSlice(Tile, std.mem.sliceAsBytes(words[1..limit]));
        if ((words.len - limit) % 2 != 0) return error.InvalidSnapBinDirectory;
        const entries = std.mem.bytesAsSlice(Entry, std.mem.sliceAsBytes(words[limit..]));
        if (tiles[tiles.len - 1].ends[bins_per_tile - 1] != entries.len) return error.InvalidSnapBinDirectory;
        return .{ .tiles = tiles, .entries = entries };
    }

    pub fn edgesIn(self: View, tile: u32, bin: u16) ![]const Entry {
        if (bin >= bins_per_tile) return error.InvalidSnapBin;
        const index = std.sort.lowerBound(Tile, self.tiles, tile, struct {
            fn compare(id: u32, entry: Tile) std.math.Order {
                return std.math.order(id, entry.id);
            }
        }.compare);
        if (index == self.tiles.len or self.tiles[index].id != tile) return &.{};
        const record = &self.tiles[index];
        const begin = if (bin != 0) record.ends[bin - 1] else if (index != 0) self.tiles[index - 1].ends[bins_per_tile - 1] else 0;
        const end = record.ends[bin];
        if (begin > end or end > self.entries.len) return error.InvalidSnapBinOffsets;
        return self.entries[begin..end];
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
}
