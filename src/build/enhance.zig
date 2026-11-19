// Ported from src/mjolnir/graphenhancer.cc, src/mjolnir/graphbuilder.cc
// and src/mjolnir/graphvalidator.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const geo = @import("../geo/point.zig");
const geo_constants = @import("../geo/constants.zig");
const math = @import("../geo/build_math.zig");
const format = @import("../graph/format.zig");
const graph = @import("../graph/constants.zig");
const EdgeClass = @import("../graph/class_table.zig").EdgeClass;
const DriveSide = @import("edge_class.zig").DriveSide;
const Allocator = std.mem.Allocator;

const max_expansions = 256;
const grid_level = 14;
const density_cell_deg: f32 = @as(f32, 1 << grid_level) / 1e7;
const radius_lat: f32 = @floatCast(2000 / geo_constants.meters_per_degree_lat);
const tile_width = 2_500_000;
const cols = 1440;
const rows = 720;
pub const tile_count = rows * cols;

pub const AdminDriveSide = struct {
    context: *const anyopaque,
    resolve: *const fn (*const anyopaque, geo.FixedLL) ?DriveSide,
};

pub const Network = struct {
    nodes: []const format.NodeHot,
    coordinates: []const geo.FixedLL,
    first_edge: []const u32,
    edges: []const format.EdgeHot,
    classes: []const EdgeClass,
    walk_order: []const u32,
    /// Empty for graphs without aliases. Otherwise indexed by physical node ID.
    aliases: []const u32 = &.{},

    fn canonical(self: Network, node: u32) u32 {
        return if (self.aliases.len == 0) node else self.aliases[node];
    }

    fn endAlias(self: Network, first: u32, deadline: io.Deadline) !u32 {
        var end = first + 1;
        if (self.aliases.len == 0) return end;
        while (end < self.aliases.len and self.aliases[end] == first) : (end += 1) {
            try check(deadline, end - first - 1);
        }
        return end;
    }

    fn class(self: Network, edge: format.EdgeHot) EdgeClass {
        return self.classes[edge.cls.class_id];
    }
};

pub fn intersection(network: Network, node: u32, deadline: io.Deadline) !graph.IntersectionType {
    const first = network.canonical(node);
    const end = try network.endAlias(first, deadline);
    const kind = network.nodes[first].attr.type;
    var degree: usize = 0;
    var drivable: usize = 0;
    var driveforward: usize = 0;
    var links: usize = 0;
    for (network.edges[network.first_edge[first]..network.first_edge[end]], 0..) |edge, i| {
        try check(deadline, i);
        const class = network.class(edge);
        if (class.flags.node_connector) continue;
        degree += 1;
        const fwd = class.forwardAccess().auto;
        drivable += @intFromBool(fwd or class.reverseAccess().auto);
        driveforward += @intFromBool(fwd);
        links += @intFromBool(class.flags.link);
    }
    const protected = kind == @backingInt(graph.NodeType.gate) or kind == @backingInt(graph.NodeType.toll_booth) or
        kind == @backingInt(graph.NodeType.toll_gantry) or kind == @backingInt(graph.NodeType.sump_buster);
    if (!protected) {
        if (drivable == 1) return .dead_end;
        if (degree == 2) return .false_intersection;
    }
    const motorway = kind == @backingInt(graph.NodeType.motorway_junction);
    if (degree > 2 and driveforward > 1 and (links == degree or
        (motorway and (links == 0 or (links == driveforward and degree == links + 1))))) return .fork;
    return .regular;
}

pub const Search = struct {
    visited: std.AutoHashMapUnmanaged(u32, void) = .empty,
    queue: [max_expansions]u32 = undefined,

    pub fn init(gpa: Allocator) !Search {
        var result: Search = .{};
        try result.visited.ensureTotalCapacity(gpa, max_expansions);
        return result;
    }

    pub fn deinit(self: *Search, gpa: Allocator) void {
        self.visited.deinit(gpa);
    }

    pub fn notThru(self: *Search, network: Network, start_node: u32, edge: format.EdgeHot, deadline: io.Deadline) !bool {
        const class = network.class(edge);
        if (class.flags.node_connector or class.category.road_class <= @backingInt(graph.RoadClass.tertiary)) return false;
        self.visited.clearRetainingCapacity();
        const start = network.canonical(start_node);
        const head = network.canonical(edge.head);
        const opposite = network.first_edge[edge.head] + edge.cls.opp_local;
        // Upstream compares edge-info offsets only within a tile. Here the CSR
        // supplies the exact opposing arc index for that comparison.
        const skip_opposite = tileId(network.coordinates[start]) == tileId(network.coordinates[head]);
        self.queue[0] = head;
        var queued: usize = 1;
        for (0..max_expansions) |expanded| {
            if (expanded == queued) return true;
            if (expanded % 16 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const node = self.queue[expanded];
            self.visited.putAssumeCapacity(node, {});
            const end = try network.endAlias(node, deadline);
            const first_edge = network.first_edge[node];
            const end_edge = network.first_edge[end];
            for (network.walk_order[first_edge..end_edge], 0..) |id, i| {
                try check(deadline, i);
                const next = network.edges[id];
                if (expanded == 0 and skip_opposite and id == opposite) continue;
                const next_class = network.class(next);
                if (next_class.flags.node_connector) continue;
                const target = network.canonical(next.head);
                if (target == start or next_class.category.road_class < @backingInt(graph.RoadClass.tertiary)) return false;
                // Queuing stops at the number of entries upstream can expand.
                // Visited nodes are marked when popped, including duplicates
                // that upstream can queue before the first visit.
                if (queued < self.queue.len and !self.visited.contains(target)) {
                    self.queue[queued] = target;
                    queued += 1;
                }
            }
        }
        return false;
    }
};

pub fn tileId(point: geo.FixedLL) u32 {
    const lon: u32 = @intCast(@as(i64, point.lng) + 1_800_000_000);
    const lat: u32 = @intCast(@as(i64, point.lat) + 900_000_000);
    const row: u32 = @min(rows - 1, lat / tile_width);
    const col: u32 = @min(cols - 1, lon / tile_width);
    return row * cols + col;
}

fn check(deadline: io.Deadline, i: usize) !void {
    if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

pub const TileIndex = struct {
    offsets: []u32,
    order: []const u32,
    active: std.ArrayList(u32) = .empty,

    pub fn init(gpa: Allocator, coordinates: []const geo.FixedLL, order: []u32, deadline: io.Deadline) !TileIndex {
        const offsets = try gpa.alloc(u32, tile_count + 1);
        var result: TileIndex = .{ .offsets = offsets, .order = order };
        errdefer result.deinit(gpa);
        @memset(offsets, 0);
        for (coordinates, 0..) |point, id| {
            try check(deadline, id);
            offsets[tileId(point) + 1] += 1;
        }
        for (1..offsets.len) |i| {
            try check(deadline, i);
            if (offsets[i] != 0) try result.active.append(gpa, @intCast(i - 1));
            offsets[i] += offsets[i - 1];
        }
        for (coordinates, 0..) |point, id| {
            try check(deadline, id);
            const tile = tileId(point);
            order[offsets[tile]] = @intCast(id);
            offsets[tile] += 1;
        }
        var i: usize = tile_count;
        while (i > 0) : (i -= 1) {
            try check(deadline, i);
            offsets[i] = offsets[i - 1];
        }
        offsets[0] = 0;
        return result;
    }

    pub fn deinit(self: *TileIndex, gpa: Allocator) void {
        self.active.deinit(gpa);
        gpa.free(self.offsets);
    }

    pub fn nodes(self: TileIndex, tile: u32) []const u32 {
        return self.order[self.offsets[tile]..self.offsets[tile + 1]];
    }
};

const Bounds = struct {
    west: f64,
    south: f64,
    east: f64,
    north: f64,

    fn contains(self: Bounds, point: geo.PointLL) bool {
        return point.lng >= self.west and point.lng <= self.east and point.lat >= self.south and point.lat <= self.north;
    }
};

const Frame = struct {
    expanded: Bounds,
    cell_area: f32,
    rx: i32,
    ry: i32,

    fn init(tile: u32) Frame {
        const corner = tileCorner(tile);
        const radians = @as(f64, geo_constants.rad_per_deg) * (corner.lat + 0.125);
        const angle: f32 = @floatCast(radians);
        const cos_lat: f32 = @floatCast(math.cosF(angle));
        const radius_lon = radius_lat / cos_lat;
        const pad_lon = radius_lon + density_cell_deg;
        const pad_lat = radius_lat + density_cell_deg;
        const cell_km: f32 = @floatCast(@as(f64, density_cell_deg) * geo_constants.meters_per_degree_lat / geo_constants.meters_per_km);
        return .{
            .expanded = .{
                .west = corner.lng - pad_lon,
                .south = corner.lat - pad_lat,
                .east = corner.lng + 0.25 + pad_lon,
                .north = corner.lat + 0.25 + pad_lat,
            },
            .cell_area = cell_km * cell_km * cos_lat,
            .rx = @intFromFloat(@ceil(radius_lon / density_cell_deg)),
            .ry = @intFromFloat(@ceil(radius_lat / density_cell_deg)),
        };
    }
};

fn tileCorner(tile: u32) geo.PointLL {
    return .{
        .lng = @as(f64, @floatFromInt(tile % cols)) * 0.25 - 180,
        .lat = @as(f64, @floatFromInt(tile / cols)) * 0.25 - 90,
    };
}

fn tileColumn(lng: f64) u32 {
    return @intFromFloat(std.math.clamp(@floor((lng + 180) * 4), 0, cols - 1));
}

fn tileRow(lat: f64) u32 {
    return @intFromFloat(std.math.clamp(@floor((lat + 90) * 4), 0, rows - 1));
}

// NodeInfo stores tile-relative E6 offsets plus the seventh digit.
fn nodePoint(fixed: geo.FixedLL, tile: u32) geo.PointLL {
    const corner = tileCorner(tile);
    const lng = @as(i64, fixed.lng) + 1_800_000_000 - @as(i64, tile % cols) * tile_width;
    const lat = @as(i64, fixed.lat) + 900_000_000 - @as(i64, tile / cols) * tile_width;
    return .{
        .lng = corner.lng + offset(lng),
        .lat = corner.lat + offset(lat),
    };
}

fn offset(value: i64) f64 {
    return @as(f64, @floatFromInt(@divTrunc(value, 10))) * 1e-6 + @as(f64, @floatFromInt(@rem(value, 10))) * 1e-7;
}

const CellId = struct {
    x: i32,
    y: i32,

    fn init(point: geo.PointLL) CellId {
        const x: u32 = @intFromFloat((point.lng + 180) * 1e7);
        const y: u32 = @intFromFloat((point.lat + 90) * 1e7);
        return .{ .x = @intCast(x >> grid_level), .y = @intCast(y >> grid_level) };
    }

    fn key(self: CellId) u64 {
        return @as(u32, @bitCast(self.x)) | (@as(u64, @as(u32, @bitCast(self.y))) << 32);
    }
};

const Cell = struct {
    meters: f32 = 0,
    relative: ?u4 = null,
};

pub const Density = struct {
    cells: std.AutoHashMapUnmanaged(u64, Cell) = .empty,

    pub fn deinit(self: *Density, gpa: Allocator) void {
        self.cells.deinit(gpa);
    }

    pub fn apply(self: *Density, gpa: Allocator, network: Network, tiles: TileIndex, tile: u32, nodes: []format.NodeHot, deadline: io.Deadline) !void {
        self.cells.clearRetainingCapacity();
        const frame = Frame.init(tile);
        try self.collect(gpa, network, tiles.nodes(tile), tile, null, deadline);
        const top = tileRow(frame.expanded.north);
        const left = tileColumn(frame.expanded.west);
        const right = tileColumn(frame.expanded.east);
        for (tileRow(frame.expanded.south)..top + 1) |y| {
            for (left..right + 1) |x| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const neighbor: u32 = @intCast(y * cols + x);
                if (neighbor == tile) continue;
                try self.collect(gpa, network, tiles.nodes(neighbor), neighbor, frame.expanded, deadline);
            }
        }

        for (tiles.nodes(tile), 0..) |id, i| {
            try check(deadline, i);
            const cell = CellId.init(nodePoint(network.coordinates[id], tile));
            const entry = self.cells.getPtr(cell.key()).?;
            const relative = entry.relative orelse try self.relativeDensity(cell, frame, deadline);
            entry.relative = relative;
            nodes[id].attr.density = relative;
        }
    }

    fn collect(self: *Density, gpa: Allocator, network: Network, ids: []const u32, tile: u32, bounds: ?Bounds, deadline: io.Deadline) !void {
        for (ids, 0..) |id, i| {
            try check(deadline, i);
            const point = nodePoint(network.coordinates[id], tile);
            if (bounds) |box| if (!box.contains(point)) continue;
            const cell = try self.cells.getOrPut(gpa, CellId.init(point).key());
            if (!cell.found_existing) cell.value_ptr.* = .{};
            var meters: f32 = 0;
            for (network.edges[network.first_edge[id]..network.first_edge[id + 1]]) |edge| {
                const use = std.enums.fromInt(graph.Use, network.class(edge).category.use) orelse continue;
                switch (use) {
                    .road, .service_road, .ramp, .turn_channel, .alley, .emergency_access => meters += @floatFromInt(edge.geom.len_m),
                    else => {},
                }
            }
            cell.value_ptr.meters += meters;
        }
    }

    fn relativeDensity(self: *const Density, cell: CellId, frame: Frame, deadline: io.Deadline) !u4 {
        const radius_sq = frame.rx * frame.ry;
        const max_dx = @min(frame.rx, squareRoot(radius_sq));
        var meters: f32 = 0;
        var neighbors: u32 = 0;
        var dx = -max_dx;
        while (dx <= max_dx) : (dx += 1) {
            if (@rem(dx, 16) == 0 and deadline.expired()) return error.DeadlineExceeded;
            const max_dy = @min(frame.ry, squareRoot(radius_sq - dx * dx));
            var dy = -max_dy;
            while (dy <= max_dy) : (dy += 1) {
                const neighbor: CellId = .{ .x = cell.x + dx, .y = cell.y + dy };
                if (self.cells.get(neighbor.key())) |hit| meters += hit.meters;
            }
            neighbors += @intCast(2 * max_dy + 1);
        }
        const density = (meters * 0.0005) / (frame.cell_area * @as(f32, @floatFromInt(neighbors)));
        return @intFromFloat(@min(15, @round(density * 0.7)));
    }
};

fn squareRoot(n: i32) i32 {
    return @intFromFloat(@sqrt(@as(f64, @floatFromInt(n))));
}
