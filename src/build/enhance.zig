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
const turns = @import("turns.zig");
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

const internal_length = 32;
const stored_headings = 8;

pub fn intersectionInternal(network: Network, source: u32, slot: u32, headings: anytype, deadline: io.Deadline) !bool {
    const edge = network.edges[slot];
    const class = network.class(edge);
    if (edge.geom.len_m > internal_length or class.flags.roundabout or class.category.use > @backingInt(graph.Use.cycleway))
        return false;

    const incoming = try orderedEdges(network, source, deadline);
    var bearing: u16 = 0;
    for (incoming, 0..) |other, i| {
        try check(deadline, i);
        if (other != slot) {
            if (incoming.len == 2 and network.canonical(network.edges[other].head) == network.canonical(edge.head))
                return false;
        } else if (i < stored_headings) {
            bearing = turns.storedHeading(try headings.rawHeading(slot));
        }
    }
    const before = (try internalTurns(network, incoming, slot, bearing, true, headings, deadline)) orelse return false;
    if (!before.oneway) return false;

    const opposite = network.first_edge[edge.head] + edge.cls.opp_local;
    const arrival = (try headings.rawHeading(opposite) + 180) % 360;
    const outgoing = try orderedEdges(network, edge.head, deadline);
    const after = (try internalTurns(network, outgoing, opposite, arrival, false, headings, deadline)) orelse return false;
    return after.oneway and !(before.left and after.right) and !(before.right and after.left) and !(after.left and after.right);
}

fn orderedEdges(network: Network, node: u32, deadline: io.Deadline) ![]const u32 {
    const first = network.canonical(node);
    const end = try network.endAlias(first, deadline);
    return network.walk_order[network.first_edge[first]..network.first_edge[end]];
}

pub const NodeControls = packed struct(u32) {
    stop: bool = false,
    yield: bool = false,
    minor: bool = false,
    reserved: u29 = 0,
};

pub const Signs = struct {
    stop: bool = false,
    yield: bool = false,
    signal: bool = false,
};

fn isRoad(class: EdgeClass) bool {
    const use = class.category.use;
    return !class.flags.node_connector and (use == @backingInt(graph.Use.road) or use == @backingInt(graph.Use.service_road));
}

fn isRampOrChannel(class: EdgeClass) bool {
    const use = class.category.use;
    return use == @backingInt(graph.Use.ramp) or use == @backingInt(graph.Use.turn_channel);
}

pub fn signs(network: Network, source: u32, edge: format.EdgeHot, start: NodeControls, end: NodeControls, deadline: io.Deadline) !Signs {
    const class = network.class(edge);
    if (!class.forwardAccess().auto) return .{};
    var result: Signs = .{ .stop = class.flags.stop_sign, .yield = class.flags.yield_sign, .signal = class.flags.traffic_signal };
    const rc = class.category.road_class;
    if (start.minor and (result.stop or result.yield)) {
        const approaches = try orderedEdges(network, source, deadline);
        for (approaches[0..@min(approaches.len, stored_headings)]) |slot| {
            const approach = network.class(network.edges[slot]);
            if (approach.flags.node_connector) continue;
            const other_rc = approach.category.road_class;
            if (other_rc > rc or (other_rc == rc and isRampOrChannel(approach)))
                return .{ .signal = result.signal };
        }
    }
    if (!end.stop and !end.yield) return result;
    if (end.minor) {
        const approaches = try orderedEdges(network, edge.head, deadline);
        var best = rc;
        for (approaches, 0..) |slot, i| {
            try check(deadline, i);
            const approach = network.class(network.edges[slot]);
            if (isRoad(approach) and approach.reverseAccess().auto) best = @min(best, approach.category.road_class);
        }
        if (rc == best and !isRampOrChannel(class)) return result;
    }
    result.stop = end.stop;
    result.yield = end.yield;
    return result;
}

test "Valhalla minor stop signs apply to lower-priority incoming roads" {
    const testing = std.testing;
    const access: u16 = @bitCast(graph.AccessMask{ .auto = true });
    const classes = [_]EdgeClass{
        .{ .category = .{ .road_class = @backingInt(graph.RoadClass.residential) }, .access = .{ .forward = access } },
        .{ .category = .{ .road_class = @backingInt(graph.RoadClass.primary) }, .access = .{ .forward = access, .reverse = access } },
        .{ .flags = .{ .stop_sign = true, .traffic_signal = true } },
    };
    const local: format.EdgeHot = .{
        .head = 1,
        .geom = .{ .len_m = 50, .grade = 6, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = @splat(0),
    };
    var main = local;
    main.head = 0;
    main.cls.class_id = 1;
    const network: Network = .{
        .nodes = &.{},
        .coordinates = &.{},
        .first_edge = &.{ 0, 1, 2 },
        .edges = &.{ local, main },
        .classes = &classes,
        .walk_order = &.{ 0, 1 },
    };
    const minor: NodeControls = .{ .stop = true, .minor = true };
    try testing.expect((try signs(network, 0, local, .{}, minor, .none)).stop);
    var primary = local;
    primary.cls.class_id = 1;
    try testing.expect(!(try signs(network, 0, primary, .{}, minor, .none)).stop);
    var footway = local;
    footway.cls.class_id = 2;
    try testing.expectEqual(Signs{}, try signs(network, 0, footway, .{}, minor, .none));
}

const InternalTurns = struct {
    left: bool = false,
    right: bool = false,
    oneway: bool = false,
};

fn internalTurns(network: Network, approaches: []const u32, selected: u32, bearing: u16, comptime incoming: bool, headings: anytype, deadline: io.Deadline) !?InternalTurns {
    var result: InternalTurns = .{};
    for (approaches, 0..) |slot, i| {
        try check(deadline, i);
        if (slot == selected) continue;
        const class = network.class(network.edges[slot]);
        if (!isRoad(class)) continue;
        const forward = class.forwardAccess().auto;
        const reverse = class.reverseAccess().auto;
        if (!(if (incoming) reverse else forward)) continue;
        if (class.flags.roundabout) return null;
        const heading = if (incoming)
            if (i < stored_headings) turns.storedHeading(try headings.rawHeading(slot)) else 0
        else
            try headings.rawHeading(slot);
        const degrees = if (incoming) (bearing + 540 - heading) % 360 else (heading + 360 - bearing) % 360;
        const kind = turns.turnType(degrees);
        result.left = result.left or kind == .left or kind == .sharp_left;
        result.right = result.right or kind == .right or kind == .sharp_right;
        result.oneway = result.oneway or
            (!(if (incoming) forward else reverse) and !class.flags.link and degrees >= 30 and degrees <= 330);
    }
    return result;
}

test "Valhalla internal intersections require compatible one-way approaches" {
    const Headings = struct {
        values: [6]u16,

        pub fn rawHeading(self: @This(), slot: u32) !u16 {
            return self.values[slot];
        }
    };
    const auto: u16 = @bitCast(graph.AccessMask{ .auto = true });
    const classes = [_]EdgeClass{
        .{ .access = .{ .forward = auto } },
        .{ .access = .{ .reverse = auto } },
        .{ .access = .{ .forward = auto, .reverse = auto } },
    };
    var edges: [6]format.EdgeHot = @splat(.{
        .head = 0,
        .geom = .{ .len_m = 12, .grade = 6, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = @splat(0),
    });
    for (&edges, [_]u32{ 1, 0, 2, 1, 3, 2 }, [_]u2{ 0, 1, 2, 2, 0, 1 }) |*edge, head, class| {
        edge.head = head;
        edge.cls.class_id = class;
    }
    const network: Network = .{
        .nodes = &.{},
        .coordinates = &.{},
        .first_edge = &.{ 0, 1, 3, 5, 6 },
        .edges = &edges,
        .classes = &classes,
        .walk_order = &.{ 0, 1, 2, 3, 4, 5 },
    };
    const left: Headings = .{ .values = .{ 180, 0, 90, 270, 0, 180 } };
    var opposed = left;
    opposed.values[4] = 180;
    try std.testing.expect(try intersectionInternal(network, 1, 2, left, .none));
    try std.testing.expect(!try intersectionInternal(network, 1, 2, opposed, .none));
    edges[2].geom.len_m = 33;
    try std.testing.expect(!try intersectionInternal(network, 1, 2, left, .none));
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
