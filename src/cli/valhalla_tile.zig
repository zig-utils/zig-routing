// Ported from valhalla/baldr/graphtileheader.h, nodeinfo.h, directededge.h,
// edgeinfo.h and src/baldr/graphtile.cc, graphreader.cc (Valhalla 3.9.3).

const std = @import("std");
const io = @import("../infra/io.zig");
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");

pub const local_level = 2;
pub const version_major = '3';

pub const GraphId = packed struct(u46) {
    level: u3 = local_level,
    tile: u22,
    index: u21 = 0,

    pub fn tileKey(self: GraphId) u32 {
        return @as(u32, self.tile) << 3 | self.level;
    }
};

pub const Header = extern struct {
    tile: packed struct(u64) {
        id: GraphId,
        density: u4,
        name_quality: u4,
        speed_quality: u4,
        exit_quality: u4,
        elevation: bool,
        extended_edges: bool,
    },
    base_ll: [2]f32,
    version: [16]u8,
    dataset_id: u64,
    counts: packed struct(u64) {
        nodes: u21,
        edges: u21,
        predicted_speeds: u21,
        spare: u1,
    },
    transitions: packed struct(u32) { count: u22, spare: u10 },
    turn_lanes: packed struct(u32) { count: u21, spare: u11 },
    // The 7-bit spare after transfercount lands in the same word as the
    // departure and stop counts under the upstream GCC/Clang bitfield ABI.
    transit: packed struct(u64) {
        transfers: u16,
        spare1: u7,
        departures: u24,
        stops: u16,
        spare2: u1,
    },
    signs: packed struct(u64) {
        routes: u12,
        schedules: u12,
        count: u24,
        spare: u16,
    },
    access: packed struct(u64) {
        restrictions: u24,
        admins: u16,
        spare: u24,
    },
    spare: u64,
    checksum: u64,
    forward_restriction_offset: u32,
    reverse_restriction_offset: u32,
    edge_info_offset: u32,
    text_offset: u32,
    date_created: u32,
    bins: [25]u32,
    lane_connectivity_offset: u32,
    predicted_speed_offset: u32,
    tile_size: u32,
    bounding_circles_offset: u32,
    unused: [10]u32,
};

pub const Node = extern struct {
    position: packed struct(u64) {
        lat: u22,
        lat_digit: u4,
        lng: u22,
        lng_digit: u4,
        access: u12,
    },
    edges: packed struct(u64) {
        first: u21,
        count: u7,
        admin: u12,
        timezone: u9,
        intersection: u4,
        kind: u4,
        density: u4,
        signal: bool,
        mode_change: bool,
        named: bool,
    },
    flags: packed struct(u64) {
        transition_index: u21,
        transition_count: u3,
        local_driveability: u16,
        local_edge_count: u3,
        drive_on_right: bool,
        tagged_access: bool,
        private_access: bool,
        cash_only_toll: bool,
        elevation: u15,
        timezone_ext: bool,
        spare: u1,
    },
    headings: u64,

    pub fn coordinate(self: Node, base: [2]f32) !geo.FixedLL {
        if (self.position.lng_digit > 9 or self.position.lat_digit > 9) return error.InvalidTileCoordinate;
        const lng = @as(f64, base[0]) * 1e7 + @as(f64, @floatFromInt(@as(u32, self.position.lng) * 10 + self.position.lng_digit));
        const lat = @as(f64, base[1]) * 1e7 + @as(f64, @floatFromInt(@as(u32, self.position.lat) * 10 + self.position.lat_digit));
        if (!(lng >= -1.8e9 and lng <= 1.8e9 and lat >= -9e8 and lat <= 9e8)) return error.InvalidTileCoordinate;
        return .{ .lng = @intFromFloat(@round(lng)), .lat = @intFromFloat(@round(lat)) };
    }
};

pub const Edge = extern struct {
    endpoint: packed struct(u64) {
        node: GraphId,
        restrictions: u8,
        opposing: u7,
        forward: bool,
        leaves_tile: bool,
        country_crossing: bool,
    },
    attributes: packed struct(u64) {
        info_offset: u25,
        access_restriction: u12,
        start_restriction: u12,
        end_restriction: u12,
        complex_restriction: bool,
        destination_only: bool,
        not_thru: bool,
    },
    speed: packed struct(u64) {
        base: u8,
        free_flow: u8,
        constrained_flow: u8,
        truck: u8,
        name_consistency: u8,
        use: u6,
        lanes: u4,
        density: u4,
        road_class: u3,
        surface: u3,
        toll: bool,
        roundabout: bool,
        truck_route: bool,
        predicted: bool,
    },
    access: packed struct(u64) {
        forward: u12,
        reverse: u12,
        max_up_slope: u5,
        max_down_slope: u5,
        sac_scale: u3,
        cycle_lane: u2,
        bike_network: bool,
        use_sidepath: bool,
        dismount: bool,
        sidewalk_left: bool,
        sidewalk_right: bool,
        shoulder: bool,
        lane_connectivity: bool,
        turn_lanes: bool,
        signs: bool,
        internal: bool,
        tunnel: bool,
        bridge: bool,
        signal: bool,
        spare1: u1,
        dead_end: bool,
        bike_share_connection: bool,
        stop_sign: bool,
        yield_sign: bool,
        hov3: bool,
        indoor: bool,
        lit: bool,
        destination_only_hgv: bool,
        spare2: u3,
    },
    geometry: packed struct(u64) {
        turn_types: u24,
        edge_to_left: u8,
        length: u24,
        grade: u4,
        curvature: u4,
    },
    local: packed struct(u64) {
        stop_impacts: u24,
        edge_to_right: u8,
        index: u7,
        opposing: u7,
        shortcut: u7,
        superseded: u7,
        is_shortcut: bool,
        classified_speed: bool,
        named: bool,
        link: bool,
    },

    pub fn turn(self: Edge, incoming: Edge) struct { entry: graph.format.TurnEntry, sides: u2 } {
        const restricted = if (std.math.cast(u3, self.local.index)) |slot| bit(incoming.endpoint.restrictions, slot) else false;
        const restriction: u8 = if (restricted) 0x80 else 0;
        // Valhalla stores the first eight incoming slots on each directed edge.
        const index: u3 = std.math.cast(u3, incoming.local.opposing) orelse return .{ .entry = restriction, .sides = 0 };
        const shift: u5 = @as(u5, index) * 3;
        const kind: u3 = @truncate(self.geometry.turn_types >> shift);
        const stop: u3 = @truncate(self.local.stop_impacts >> shift);
        const name = bit(self.speed.name_consistency, index);
        const sides: graph.turn_sides.Sides = .{
            .left = bit(self.geometry.edge_to_left, index),
            .right = bit(self.local.edge_to_right, index),
        };
        return .{
            .entry = @as(u8, kind) | (@as(u8, stop) << 3) | (@as(u8, @intFromBool(name)) << 6) | restriction,
            .sides = @bitCast(sides),
        };
    }
};

fn bit(mask: u8, index: u3) bool {
    return (mask >> index) & 1 != 0;
}

const EdgeInfoHeader = extern struct {
    way_low: u32,
    attributes: packed struct(u32) { elevation: u12, bike_network: u4, speed_limit: u8, way_byte4: u8 },
    records: packed struct(u32) { names: u4, shape_bytes: u16, way_byte5: u8, extra_way_bytes: u2, elevation: bool, spare: u1 },
};

const NameInfo = extern struct {
    data: packed struct(u32) { offset: u24, additional: u4, route: bool, tagged: bool, spare: u2 },
};

pub const ArchiveEntry = extern struct {
    offset: u64,
    tile_id: u32,
    size: u32,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@bitSizeOf(GraphId) == 46);
    std.debug.assert(@sizeOf(Header) == 272 and @offsetOf(Header, "base_ll") == 8 and @offsetOf(Header, "version") == 16);
    std.debug.assert(@offsetOf(Header, "dataset_id") == 32 and @offsetOf(Header, "counts") == 40);
    std.debug.assert(@offsetOf(Header, "transitions") == 48 and @offsetOf(Header, "turn_lanes") == 52);
    std.debug.assert(@offsetOf(Header, "transit") == 56 and @offsetOf(Header, "signs") == 64 and @offsetOf(Header, "access") == 72);
    std.debug.assert(@offsetOf(Header, "checksum") == 88 and @offsetOf(Header, "forward_restriction_offset") == 96);
    std.debug.assert(@offsetOf(Header, "edge_info_offset") == 104 and @offsetOf(Header, "text_offset") == 108 and @offsetOf(Header, "bins") == 116);
    std.debug.assert(@offsetOf(Header, "lane_connectivity_offset") == 216 and @offsetOf(Header, "tile_size") == 224);
    std.debug.assert(@sizeOf(Node) == 32 and @offsetOf(Node, "edges") == 8 and @offsetOf(Node, "flags") == 16 and @offsetOf(Node, "headings") == 24);
    std.debug.assert(@sizeOf(Edge) == 48 and @offsetOf(Edge, "attributes") == 8 and @offsetOf(Edge, "speed") == 16 and
        @offsetOf(Edge, "access") == 24 and @offsetOf(Edge, "geometry") == 32 and @offsetOf(Edge, "local") == 40);
    std.debug.assert(@sizeOf(EdgeInfoHeader) == 12 and @offsetOf(EdgeInfoHeader, "attributes") == 4 and @offsetOf(EdgeInfoHeader, "records") == 8);
    std.debug.assert(@sizeOf(NameInfo) == 4 and @offsetOf(NameInfo, "data") == 0);
    std.debug.assert(@sizeOf(ArchiveEntry) == 16 and @offsetOf(ArchiveEntry, "tile_id") == 8 and @offsetOf(ArchiveEntry, "size") == 12);
}

pub const Tile = struct {
    bytes: []const u8,
    header: Header,
    nodes: []align(1) const Node,
    edges: []align(1) const Edge,
    local_signs: []align(1) const Sign,
    edge_info: []const u8,
    text: []const u8,

    pub fn signText(self: *const Tile, offset: u32) ![]const u8 {
        if (offset >= self.text.len) return error.InvalidSignOffset;
        return terminatedText(self.text[offset..]) orelse error.UnterminatedSign;
    }

    pub fn parse(bytes: []const u8) !Tile {
        if (bytes.len < @sizeOf(Header)) return error.TruncatedTileHeader;
        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (header.tile_size != bytes.len or header.tile.id.index != 0) return error.InvalidTileHeader;
        const node_end = @sizeOf(Header) + @as(usize, header.counts.nodes) * @sizeOf(Node);
        const edge_start = node_end + @as(usize, header.transitions.count) * @sizeOf(u64);
        const edge_end = edge_start + @as(usize, header.counts.edges) * @sizeOf(Edge);
        const extended = if (header.tile.extended_edges) @as(usize, header.counts.edges) * @sizeOf(u64) else 0;
        const access_end = edge_end + extended + @as(usize, header.access.restrictions) * 16;
        const local_sign_count = if (header.tile.id.level == local_level) header.signs.count else 0;
        // Local road tiles have no transit tables between access restrictions and signs.
        if (local_sign_count != 0 and (header.transit.departures != 0 or header.transit.stops != 0 or
            header.signs.routes != 0 or header.signs.schedules != 0 or header.transit.transfers != 0))
            return error.InvalidTileOffsets;
        const sign_end = access_end + @as(usize, local_sign_count) * @sizeOf(Sign);
        if (sign_end > header.forward_restriction_offset or
            header.forward_restriction_offset > header.reverse_restriction_offset or
            header.reverse_restriction_offset > header.edge_info_offset or
            header.edge_info_offset > header.text_offset or header.text_offset > header.lane_connectivity_offset or
            header.lane_connectivity_offset > bytes.len) return error.InvalidTileOffsets;
        return .{
            .bytes = bytes,
            .header = header,
            .nodes = std.mem.bytesAsSlice(Node, bytes[@sizeOf(Header)..node_end]),
            .edges = std.mem.bytesAsSlice(Edge, bytes[edge_start..edge_end]),
            .local_signs = std.mem.bytesAsSlice(Sign, bytes[access_end..sign_end]),
            .edge_info = bytes[header.edge_info_offset..header.text_offset],
            .text = bytes[header.text_offset..header.lane_connectivity_offset],
        };
    }

    pub noinline fn info(self: *const Tile, offset: u25) !EdgeInfo {
        if (offset >= self.edge_info.len) return error.InvalidEdgeInfoOffset;
        const bytes = self.edge_info[offset..];
        if (bytes.len < @sizeOf(EdgeInfoHeader)) return error.TruncatedEdgeInfo;
        const header = std.mem.bytesToValue(EdgeInfoHeader, bytes[0..@sizeOf(EdgeInfoHeader)]);
        const names_end = @sizeOf(EdgeInfoHeader) + @as(usize, header.records.names) * @sizeOf(NameInfo);
        const shape_end = names_end + header.records.shape_bytes;
        const extra = header.records.extra_way_bytes;
        if (extra > 2 or shape_end + extra > bytes.len) return error.TruncatedEdgeInfo;
        var way: u64 = @as(u64, header.way_low) | (@as(u64, header.attributes.way_byte4) << 32) | (@as(u64, header.records.way_byte5) << 40);
        if (extra > 0) way |= @as(u64, bytes[shape_end]) << 48;
        if (extra > 1) way |= @as(u64, bytes[shape_end + 1]) << 56;
        return .{
            .way = way,
            .speed_limit = header.attributes.speed_limit,
            .mean_elevation = @as(i16, header.attributes.elevation) * 2 + graph.cold.no_elevation,
            .bike_network = header.attributes.bike_network,
            .shape = bytes[names_end..shape_end],
            .names = std.mem.bytesAsSlice(NameInfo, bytes[@sizeOf(EdgeInfoHeader)..names_end]),
            .text = self.text,
        };
    }
};

// Ported from valhalla/baldr/sign.h.
pub const Sign = extern struct {
    data: packed struct(u32) {
        index: u22,
        kind: u8,
        route_number: bool,
        tagged: bool,
    },
    text_offset: u32,

    comptime {
        std.debug.assert(@sizeOf(Sign) == 8 and @offsetOf(Sign, "data") == 0 and @offsetOf(Sign, "text_offset") == 4);
    }
};

pub const EdgeInfo = struct {
    way: u64,
    speed_limit: u8,
    mean_elevation: i16,
    bike_network: u4,
    shape: []const u8,
    names: []align(1) const NameInfo,
    text: []const u8,

    pub fn name(self: EdgeInfo, index: usize) !?graph.cold.Name {
        if (index >= self.names.len) return error.InvalidNameIndex;
        const info = self.names[index].data;
        if (info.offset >= self.text.len) return error.InvalidNameOffset;
        if (info.tagged) return null;
        const text = terminatedText(self.text[info.offset..]) orelse return error.UnterminatedEdgeName;
        return .{ .text = text, .route = info.route };
    }

    pub fn decodeShape(self: EdgeInfo, a: std.mem.Allocator, points: *std.ArrayList(geo.FixedLL), deadline: io.Deadline) !void {
        points.clearRetainingCapacity();
        // Shape7 encodes 7 bits per group. Valhalla 3.9.3 defaults to E6.
        var decoder = geo.polyline.Decoder(.varint).init(self.shape, 6);
        while (try decoder.nextFixed()) |point| {
            if (points.items.len % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (point.lng < -180_000_000 or point.lng > 180_000_000 or
                point.lat < -90_000_000 or point.lat > 90_000_000) return error.InvalidTileShapePoint;
            try points.append(a, .{ .lng = point.lng * 10, .lat = point.lat * 10 });
        }
        if (points.items.len < 2) return error.IncompleteTileShape;
    }

    pub fn indoor(self: EdgeInfo, a: std.mem.Allocator, levels: *std.ArrayList(graph.cold.LevelRange), deadline: io.Deadline) !graph.cold.Indoor {
        levels.clearRetainingCapacity();
        var layer: i8 = 0;
        var seen_layer = false;
        var seen_levels = false;
        for (self.names) |record| {
            const name_info = record.data;
            if (!name_info.tagged) continue;
            if (name_info.offset >= self.text.len) return error.InvalidNameOffset;
            const tag = self.text[name_info.offset..];
            if (tag[0] == 1 and !seen_layer) {
                if (tag.len < 3 or tag[2] != 0) return error.InvalidTileLayer;
                layer = @bitCast(tag[1]);
                seen_layer = true;
            } else if (tag[0] == 8 and !seen_levels) {
                try decodeLevels(a, levels, tag[1..], deadline);
                seen_levels = true;
            }
        }
        return .{ .layer = layer, .levels = levels.items };
    }
};

noinline fn terminatedText(bytes: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return null;
    return bytes[0..end];
}

fn decodeLevels(a: std.mem.Allocator, levels: *std.ArrayList(graph.cold.LevelRange), bytes: []const u8, deadline: io.Deadline) !void {
    const Decoder = geo.polyline.IntDecoder(i32);
    var prefix = Decoder.init(bytes);
    const tagged_size = (try prefix.nextDelta()) orelse return error.InvalidTileLevels;
    const size = std.math.cast(usize, tagged_size) orelse return error.InvalidTileLevels;
    const rest = bytes[prefix.pos..];
    if (size >= rest.len or rest[size] != 0) return error.InvalidTileLevels;
    var values = Decoder.init(rest[0..size]);
    const precision = (try values.nextDelta()) orelse return error.InvalidTileLevels;
    // In 3.9.3 decode_levels uses a factor of ten for positive precision.
    const factor: f32 = if (precision > 0) 10 else 1;
    var in_range = false;
    var i: usize = 0;
    while (try values.nextDelta()) |value| : (i += 1) {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (value == 1_048_575) {
            in_range = false;
            continue;
        }
        const level = @as(f32, @floatFromInt(value)) / factor;
        if (in_range) {
            levels.items[levels.items.len - 1].bounds.last = level;
        } else {
            try levels.append(a, .init(level, level));
            in_range = true;
        }
    }
}

pub fn archiveIndex(bytes: []const u8, deadline: io.Deadline) ![]align(1) const ArchiveEntry {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (bytes.len - offset < 512) return error.TruncatedTileArchive;
        const header = bytes[offset..][0..512];
        if (header[0] == 0) break;
        const checksum = parseOctal(u32, header[148..156]) catch return error.InvalidTileArchiveChecksum;
        var sum: u32 = 8 * ' ';
        for (header[0..148]) |byte| sum += byte;
        for (header[156..]) |byte| sum += byte;
        if (sum != checksum) return error.InvalidTileArchiveChecksum;
        const size = parseOctal(usize, header[124..136]) catch return error.InvalidTileArchiveSize;
        offset += 512;
        if (size > bytes.len - offset) return error.TruncatedTileArchive;
        if (std.mem.eql(u8, std.mem.sliceTo(header[0..100], 0), "index.bin") and
            (header[156] == 0 or header[156] == '0') and header[345] == 0)
        {
            if (size == 0 or size % @sizeOf(ArchiveEntry) != 0) return error.InvalidTileArchiveIndex;
            return std.mem.bytesAsSlice(ArchiveEntry, bytes[offset..][0..size]);
        }
        const padded = std.math.add(usize, size, 511) catch return error.InvalidTileArchiveSize;
        if ((padded & ~@as(usize, 511)) > bytes.len - offset) return error.TruncatedTileArchive;
        offset += padded & ~@as(usize, 511);
    }
    return error.MissingTileArchiveIndex;
}

fn parseOctal(comptime T: type, bytes: []const u8) !T {
    return std.fmt.parseInt(T, std.mem.trim(u8, bytes, "\x00 "), 8);
}

pub fn archiveTile(bytes: []const u8, entry: ArchiveEntry) !Tile {
    if (entry.offset % 512 != 0 or entry.offset < 512 or entry.offset > bytes.len or entry.size > bytes.len - entry.offset) return error.InvalidTileArchiveIndex;
    const tile = try Tile.parse(bytes[@intCast(entry.offset)..][0..entry.size]);
    if (tile.header.tile.id.tileKey() != entry.tile_id) return error.TileArchiveIdMismatch;
    return tile;
}
