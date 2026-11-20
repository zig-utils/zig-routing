// Ported from src/baldr/graphtile.cc and graphreader.cc (Valhalla 3.9.3).
// Offline only. The graph reader and routing service consume native bundles.

const std = @import("std");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const graph = @import("../graph/root.zig");
const geo = @import("../geo/root.zig");
const components = @import("../build/components.zig");
const turns = @import("../build/turns.zig");
const cold_builder = @import("../build/cold_builder.zig");
const ColdBuilder = cold_builder.Builder;
const StringTable = @import("../build/tags/names.zig").StringTable;
pub const tile_format = @import("valhalla_tile.zig");
const format = graph.format;
const Allocator = std.mem.Allocator;
const no_edge = std.math.maxInt(u32);

pub const Stats = struct {
    tiles: usize = 0,
    nodes: u32 = 0,
    edges: u32 = 0,
    source_edges: u32 = 0,
    skipped_shortcuts: u32 = 0,
    version_mismatches: usize = 0,
};

const SourceTile = struct {
    tile: tile_format.Tile,
    node_base: u32 = 0,
    edge_ids: []u32 = &.{},

    fn key(_: void, source: SourceTile) u64 {
        return source.tile.header.tile.id.tileKey();
    }
};

const Sources = struct {
    allocator: Allocator,
    deadline: io.Deadline,
    tiles: std.ArrayList(SourceTile) = .empty,
    mappings: std.ArrayList(io.Mapping) = .empty,
    walk_error: ?anyerror = null,

    fn deinit(self: *Sources) void {
        for (self.mappings.items) |mapping| mapping.unmap();
    }

    fn add(self: *Sources, path: []const u8) !void {
        if (self.deadline.expired()) return error.DeadlineExceeded;
        if (std.mem.endsWith(u8, path, ".gph")) return self.addFile(path);
        if (std.mem.endsWith(u8, path, ".tar")) {
            const bytes = try self.map(path);
            for (try tile_format.archiveIndex(bytes, self.deadline)) |entry| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                if (entry.tile_id & 7 == tile_format.local_level) {
                    try self.tiles.append(self.allocator, .{ .tile = try tile_format.archiveTile(bytes, entry) });
                }
            }
            return;
        }
        const dir = try io.Directory.open(path);
        dir.close();
        io.walkFiles(path, self, visitFile);
        if (self.walk_error) |err| return err;
    }

    fn visitFile(self: *Sources, path: []const u8) void {
        if (self.walk_error != null or !std.mem.endsWith(u8, path, ".gph")) return;
        self.addFile(path) catch |err| {
            self.walk_error = err;
        };
    }

    fn addFile(self: *Sources, path: []const u8) !void {
        if (self.deadline.expired()) return error.DeadlineExceeded;
        const tile = try tile_format.Tile.parse(try self.map(path));
        if (tile.header.tile.id.level == tile_format.local_level) try self.tiles.append(self.allocator, .{ .tile = tile });
    }

    fn map(self: *Sources, path: []const u8) ![]const u8 {
        try self.mappings.ensureUnusedCapacity(self.allocator, 1);
        const mapping = try io.Mapping.mapFile(path, .read_only);
        self.mappings.appendAssumeCapacity(mapping);
        return mapping.bytes;
    }
};

const EdgeSource = struct {
    tile: u32,
    index: u21,
    opposite: u32 = undefined,
};

const Layout = struct {
    by_key: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    nodes: []format.NodeHot,
    coords: []format.Coordinate,
    first: []u32,
    sources: []EdgeSource,
    edges: []format.EdgeHot,
    slopes: []u16,
    headings: []u8,

    fn init(a: Allocator, stats: Stats) !Layout {
        return .{
            .nodes = try a.alloc(format.NodeHot, stats.nodes),
            .coords = try a.alloc(format.Coordinate, stats.nodes),
            .first = try a.alloc(u32, @as(usize, stats.nodes) + 1),
            .sources = try a.alloc(EdgeSource, stats.edges),
            .edges = try a.alloc(format.EdgeHot, stats.edges),
            .slopes = try a.alloc(u16, stats.edges),
            .headings = try a.alloc(u8, stats.edges),
        };
    }

    fn catalog(self: *Layout, a: Allocator, tiles: []SourceTile, deadline: io.Deadline) !void {
        var node_index: u32 = 0;
        var edge_index: u32 = 0;
        for (tiles, 0..) |*source, tile_index| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const tile = source.tile;
            const entry = try self.by_key.getOrPut(a, tile.header.tile.id.tileKey());
            if (entry.found_existing) return error.DuplicateValhallaTile;
            entry.value_ptr.* = @intCast(tile_index);
            source.node_base = node_index;
            source.edge_ids = try a.alloc(u32, tile.edges.len);
            var raw_index: usize = 0;
            for (tile.nodes) |node| {
                if (node_index % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const raw_end = raw_index + node.edges.count;
                if (node.edges.first != raw_index or raw_end > tile.edges.len) return error.InvalidTileNodeEdges;
                self.coords[node_index] = try node.coordinate(tile.header.base_ll);
                self.nodes[node_index] = try nodeHot(node);
                self.first[node_index] = edge_index;
                for (tile.edges[raw_index..raw_end], source.edge_ids[raw_index..raw_end], raw_index..) |edge, *id, i| {
                    if (edge.local.is_shortcut) {
                        id.* = no_edge;
                    } else {
                        id.* = edge_index;
                        self.sources[edge_index] = .{ .tile = @intCast(tile_index), .index = @intCast(i) };
                        self.headings[edge_index] = if (std.math.cast(u3, edge.local.index)) |local|
                            @truncate(node.headings >> (@as(u6, local) * 8))
                        else
                            0;
                        edge_index += 1;
                    }
                }
                if (edge_index - self.first[node_index] > turns.max_degree) return error.ValhallaNodeDegreeTooLarge;
                raw_index = raw_end;
                node_index += 1;
            }
            if (raw_index != tile.edges.len) return error.InvalidTileNodeEdges;
        }
        self.first[node_index] = edge_index;
    }

    fn connect(self: *Layout, a: Allocator, tiles: []const SourceTile, deadline: io.Deadline) !graph.class_table.Table {
        var classes = graph.class_table.Interner.init(a);
        defer classes.deinit();
        const handles = try a.alloc(graph.class_table.Handle, self.edges.len);
        defer a.free(handles);
        for (self.sources, self.edges, self.slopes, handles, 0..) |*ref, *output, *slope, *handle, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const tile = &tiles[ref.tile].tile;
            const raw = tile.edges[ref.index];
            const head = raw.endpoint.node;
            const other = tiles[self.by_key.get(head.tileKey()) orelse return error.MissingValhallaEndTile];
            if (head.index >= other.tile.nodes.len) return error.InvalidValhallaEndNode;
            const node = other.tile.nodes[head.index].edges;
            if (raw.endpoint.opposing >= node.count) return error.InvalidValhallaOpposingEdge;
            const opposite = other.edge_ids[@as(usize, node.first) + raw.endpoint.opposing];
            if (opposite == no_edge or opposite == i) return error.InvalidValhallaOpposingEdge;
            const dense = other.node_base + head.index;
            ref.opposite = opposite;
            const info = try tile.info(raw.attributes.info_offset);
            handle.* = try classes.intern(edgeClass(raw, info.bike_network));
            output.* = .{
                .head = dense,
                .geom = .{ .len_m = raw.geometry.length, .grade = raw.geometry.grade, .curvature = raw.geometry.curvature },
                .cls = .{
                    .class_id = 0,
                    .local = 0,
                    .opp_local = @intCast(opposite - self.first[dense]),
                    .cold_checks = @intFromBool(raw.attributes.access_restriction != 0 or raw.attributes.complex_restriction or
                        raw.attributes.start_restriction != 0 or raw.attributes.end_restriction != 0),
                    .pred_speed = @intFromBool(raw.speed.predicted),
                },
                .speed = .{ raw.speed.base, raw.speed.free_flow, raw.speed.constrained_flow, raw.speed.truck },
            };
            slope.* = format.Slopes.init(raw.access.max_up_slope, raw.access.max_down_slope).code;
        }
        for (self.first[0..self.nodes.len], self.first[1..], 0..) |begin, end, node| {
            if (node % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            for (self.edges[begin..end], self.sources[begin..end], begin..end) |*edge, ref, i| {
                if (self.sources[ref.opposite].opposite != i or self.edges[ref.opposite].head != node) return error.InvalidValhallaOpposingEdge;
                edge.cls.local = @intCast(i - begin);
            }
        }
        var table = try classes.finish(deadline);
        errdefer table.deinit();
        for (self.edges, handles, 0..) |*edge, handle, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            edge.cls.class_id = try table.id(handle);
        }
        return table;
    }

    fn writeTurns(self: *Layout, a: Allocator, tiles: []const SourceTile, writer: *format.BundleWriter) !void {
        var pool = turns.Pool.init(a);
        defer pool.deinit();
        var sides = try turns.SidePool.init(a, self.nodes.len);
        defer sides.deinit();
        var entries: [turns.max_matrix_size]format.TurnEntry = undefined;
        var turn_sides: [turns.max_matrix_size]u2 = undefined;
        for (self.nodes, self.first[0..self.nodes.len], self.first[1..], 0..) |*node, start, end, index| {
            if (index % 256 == 0 and writer.deadline.expired()) return error.DeadlineExceeded;
            const degree = end - start;
            const refs = self.sources[start..end];
            for (refs, 0..) |from, row| {
                const opposite = self.sources[from.opposite];
                const incoming = tiles[opposite.tile].tile.edges[opposite.index];
                for (refs, 0..) |to, column| {
                    const outgoing = tiles[to.tile].tile.edges[to.index];
                    const turn = outgoing.turn(incoming);
                    entries[row * degree + column] = turn.entry;
                    turn_sides[row * degree + column] = turn.sides;
                }
            }
            node.turn_off = try pool.intern(entries[0 .. degree * degree]);
            try sides.append(index, turn_sides[0 .. degree * degree]);
        }
        try writer.write(.turns, pool.bytes.items);
        const side_data = try sides.finish(writer.deadline);
        defer a.free(side_data);
        try writer.write(.turn_sides, side_data);
    }

    fn writeCold(self: *const Layout, a: Allocator, tiles: []const SourceTile, writer: *format.BundleWriter, scratch_dir: []const u8) !void {
        var strings = StringTable.init(a);
        defer strings.deinit();
        var cold = try ColdBuilder.init(a, &strings, scratch_dir, writer.deadline);
        defer cold.deinit();
        var points: std.ArrayList(geo.FixedLL) = .empty;
        defer points.deinit(a);
        var levels: std.ArrayList(graph.cold.LevelRange) = .empty;
        defer levels.deinit(a);
        var pairs: std.ArrayList(graph.spatial.Pair) = .empty;
        defer pairs.deinit(a);
        const indices = try a.alloc(u32, self.edges.len);
        defer a.free(indices);
        var coverage: graph.coverage.Builder = .{};
        try coverage.add(self.coords, writer.deadline);
        for (self.sources, 0..) |ref, i| {
            if (i % 256 == 0 and writer.deadline.expired()) return error.DeadlineExceeded;
            if (i > ref.opposite) continue;
            const tile = tiles[ref.tile].tile;
            const edge = tile.edges[ref.index];
            const opposite_ref = self.sources[ref.opposite];
            const opposite_tile = tiles[opposite_ref.tile].tile;
            const opposite = opposite_tile.edges[opposite_ref.index];
            if (edge.endpoint.forward == opposite.endpoint.forward) return error.InvalidValhallaShapeDirection;
            const here_info = try tile.info(edge.attributes.info_offset);
            const other_info = try opposite_tile.info(opposite.attributes.info_offset);
            const info = if (edge.endpoint.forward) here_info else other_info;
            const reverse_info = if (edge.endpoint.forward) other_info else here_info;
            if (info.way != reverse_info.way or !std.mem.eql(u8, info.shape, reverse_info.shape)) return error.ValhallaOpposingShapeMismatch;
            try info.decodeShape(a, &points, writer.deadline);
            try coverage.addShape(points.items, writer.deadline);
            var forward_names: [15]u32 = undefined;
            var reverse_names: [15]u32 = undefined;
            const names = try nameRefs(info, &strings, &cold, &forward_names);
            const reverse = try nameRefs(reverse_info, &strings, &cold, &reverse_names);
            const indoor = try info.indoor(a, &levels, writer.deadline);
            const different_names = if (std.mem.eql(u32, names, reverse)) null else reverse;
            const record = try cold.appendDirectional(info.way, info.speed_limit, info.mean_elevation, points.items, names, different_names, indoor);
            indices[i] = graph.cold.directedIndex(record, !edge.endpoint.forward);
            indices[ref.opposite] = graph.cold.directedIndex(record, edge.endpoint.forward);
            try graph.spatial.addShape(a, &pairs, @intCast(i), points.items, writer.deadline);
        }
        try writer.write(.cold_idx, indices);
        try self.writeSigns(tiles, &strings, &cold, writer);
        _ = try cold.write(writer);
        if (coverage.finish()) |box| try writer.write(.coverage, &.{box});
        const scratch = try a.alloc(graph.spatial.Pair, pairs.items.len);
        defer a.free(scratch);
        _ = try graph.spatial.write(a, pairs.items, scratch, scratch_dir, writer, writer.deadline);
    }

    // Ported from GraphTile::GetSigns for the local road tile import.
    fn writeSigns(self: *const Layout, tiles: []const SourceTile, strings: *StringTable, cold: *ColdBuilder, writer: *format.BundleWriter) !void {
        var sink: cold_builder.SignSink = .{ .builder = cold, .strings = strings };
        defer sink.deinit();
        // The stable sort preserves edge signs before node signs when their keys coincide.
        try self.collectSigns(tiles, &sink, false, writer.deadline);
        try self.collectSigns(tiles, &sink, true, writer.deadline);
        try sink.write(writer);
    }

    noinline fn collectSigns(self: *const Layout, tiles: []const SourceTile, sink: *cold_builder.SignSink, on_node: bool, deadline: io.Deadline) !void {
        for (tiles) |*source| {
            if (deadline.expired()) return error.DeadlineExceeded;
            for (source.tile.local_signs, 0..) |sign, index| {
                if (index % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (sign.data.kind == 255 and sign.data.tagged) continue; // Linguistics are separate records.
                if (sign.data.kind > @backingInt(graph.signs.Type.toll_name)) return error.InvalidValhallaSignType;
                const kind: graph.signs.Type = @fromBackingInt(sign.data.kind);
                if ((kind == .junction_name or kind == .toll_name) != on_node) continue;
                const owner = if (on_node) node: {
                    if (sign.data.index >= source.tile.nodes.len or !source.tile.nodes[sign.data.index].edges.named) return error.InvalidValhallaSignOwner;
                    break :node source.node_base + sign.data.index;
                } else edge: {
                    if (sign.data.index >= source.edge_ids.len or !source.tile.edges[sign.data.index].access.signs) return error.InvalidValhallaSignOwner;
                    break :edge source.edge_ids[sign.data.index];
                };
                if (owner == no_edge) continue;
                const node = if (on_node) owner else self.edges[self.sources[owner].opposite].head;
                const text = try source.tile.signText(sign.text_offset);
                if (text.len == 0) return error.EmptySign;
                sink.cell = geo.grid.snapCell(self.coords[node].toPoint());
                sink.owner = owner;
                try sink.addTagged(kind, sign.data.route_number, sign.data.tagged, text);
            }
        }
    }
};

fn nameRefs(info: tile_format.EdgeInfo, strings: *StringTable, cold: *ColdBuilder, out: *[15]u32) ![]const u32 {
    var count: usize = 0;
    for (0..info.names.len) |i| {
        if (try info.name(i)) |name| {
            out[count] = try cold.nameRef(try strings.intern(name.text), name.route);
            count += 1;
        }
    }
    return out[0..count];
}

fn nodeHot(node: tile_format.Node) !format.NodeHot {
    if (std.enums.fromInt(graph.constants.NodeType, node.edges.kind) == null) return error.InvalidValhallaNodeType;
    return .{
        .turn_off = 0,
        .attr = .{
            .access = node.position.access,
            .type = node.edges.kind,
            .density = node.edges.density,
            .signal = @intFromBool(node.edges.signal),
            .intersection = std.enums.fromInt(graph.constants.IntersectionType, node.edges.intersection) orelse return error.InvalidValhallaIntersectionType,
            .drive_on_left = !node.flags.drive_on_right,
            .tagged_access = node.flags.tagged_access,
            .private_access = node.flags.private_access,
            .cash_only_toll = node.flags.cash_only_toll,
        },
    };
}

fn edgeClass(edge: tile_format.Edge, bike_network: u4) graph.class_table.EdgeClass {
    return .{
        .category = .{
            .use = edge.speed.use,
            .road_class = edge.speed.road_class,
            .surface = edge.speed.surface,
            .sac_scale = edge.access.sac_scale,
            .cycle_lane = edge.access.cycle_lane,
            .bike_network = bike_network,
            .lanes = edge.speed.lanes,
            .density = edge.speed.density,
        },
        .access = .{ .forward = edge.access.forward, .reverse = edge.access.reverse },
        .flags = .{
            .toll = edge.speed.toll,
            .tunnel = edge.access.tunnel,
            .bridge = edge.access.bridge,
            .roundabout = edge.speed.roundabout,
            .link = edge.local.link,
            .internal = edge.access.internal,
            .destination_only = edge.attributes.destination_only,
            .lit = edge.access.lit,
            .sidewalk_left = edge.access.sidewalk_left,
            .sidewalk_right = edge.access.sidewalk_right,
            .dismount = edge.access.dismount,
            .use_sidepath = edge.access.use_sidepath,
            .hov3 = edge.access.hov3,
            .truck_route = edge.speed.truck_route,
            .shoulder = edge.access.shoulder,
            .destination_only_hgv = edge.access.destination_only_hgv,
            .not_thru = edge.attributes.not_thru,
            .dead_end = edge.access.dead_end,
            .named = edge.local.named,
            .sign = edge.access.signs,
            .indoor = edge.access.indoor,
            .complex_restriction = edge.attributes.complex_restriction,
            .bike_share_connection = edge.access.bike_share_connection,
            .traffic_signal = edge.access.signal,
            .stop_sign = edge.access.stop_sign,
            .yield_sign = edge.access.yield_sign,
            .country_crossing = edge.endpoint.country_crossing,
            .tagged_speed = !edge.local.classified_speed,
        },
        .restrictions = .{ .start = edge.attributes.start_restriction, .end = edge.attributes.end_restriction },
        .detail = .{
            .access_restriction = edge.attributes.access_restriction,
            .max_up_slope = edge.access.max_up_slope,
            .max_down_slope = edge.access.max_down_slope,
        },
    };
}

pub fn run(gpa: Allocator, inputs: []const []const u8, output: []const u8, deadline: io.Deadline) !Stats {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var input: Sources = .{ .allocator = a, .deadline = deadline };
    defer input.deinit();
    for (inputs) |path| try input.add(path);
    const tiles = input.tiles.items;
    if (tiles.len == 0) return error.NoLocalValhallaTiles;
    if (tiles.len > std.math.maxInt(u22)) return error.TooManyValhallaTiles;
    const sort_space = try a.alloc(SourceTile, tiles.len);
    try radix.sortByU64(SourceTile, gpa, tiles, sort_space, {}, SourceTile.key, deadline);
    a.free(sort_space);

    var stats: Stats = .{ .tiles = tiles.len };
    var hash = std.crypto.hash.Blake3.init(.{});
    for (tiles) |source| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const tile = source.tile;
        stats.nodes = try std.math.add(u32, stats.nodes, tile.header.counts.nodes);
        stats.source_edges = try std.math.add(u32, stats.source_edges, tile.header.counts.edges);
        stats.version_mismatches += @intFromBool(tile.header.version[0] != tile_format.version_major);
        for (tile.edges, 0..) |edge, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            stats.skipped_shortcuts += @intFromBool(edge.local.is_shortcut);
        }
        var remaining = tile.bytes;
        while (remaining.len != 0) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const chunk = remaining[0..@min(remaining.len, 1024 * 1024)];
            hash.update(chunk);
            remaining = remaining[chunk.len..];
        }
    }
    stats.edges = stats.source_edges - stats.skipped_shortcuts;
    var layout = try Layout.init(a, stats);
    try layout.catalog(a, tiles, deadline);
    var classes = try layout.connect(a, tiles, deadline);
    defer classes.deinit();

    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var writer = try format.BundleWriter.init(output, digest[0..16].*, deadline);
    defer writer.deinit();
    const scratch_dir = std.fs.path.dirname(output) orelse ".";
    try layout.writeTurns(a, tiles, &writer);
    try writer.write(.nodes, layout.nodes);
    try writer.write(.first_edge, layout.first);
    try writer.write(.edges, layout.edges);
    try graph.speed.writeBounds(&writer, layout.edges);
    try writer.write(.classes, classes.classes);
    try writer.write(.coordinates, layout.coords);
    try writer.write(.slopes, layout.slopes);
    try writer.write(.headings, layout.headings);
    const labels = try a.alloc(u32, stats.nodes);
    try components.label(labels, layout.first, layout.edges, deadline);
    try writer.write(.components, labels);
    try layout.writeCold(gpa, tiles, &writer, scratch_dir);
    try writer.commit();
    return stats;
}
