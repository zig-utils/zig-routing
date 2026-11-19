// Ported from src/mjolnir/graphbuilder.cc, src/mjolnir/util.cc and src/mjolnir/graphvalidator.cc
// (Valhalla 3.9.3). Assemble the native dense CSR topology.
const std = @import("std");
const geo = @import("../geo/point.zig");
const io = @import("../infra/io.zig");
const graph = @import("../graph/root.zig");
const format = graph.format;
const classes = graph.class_table;
const edges = @import("edges.zig");
const tags = @import("tags/root.zig");
const pbf = @import("pbf/root.zig");
const edge_class = @import("edge_class.zig");
const turns = @import("turns.zig");
const ColdBuilder = @import("cold_builder.zig").Builder;
const elevation = @import("elevation.zig");
const dem = @import("../elevation/root.zig");
const enhance = @import("enhance.zig");
const components = @import("components.zig");
const checkpoint = @import("checkpoint.zig");
const node_order = @import("order.zig");

const Allocator = std.mem.Allocator;
const max_degree = turns.max_degree;
const max_workers = 16;

pub const Options = struct {
    scratch_dir: []const u8,
    drive_side: edge_class.DriveSide = .right,
    workers: usize = 0,
    include_construction: bool = false,
    include_platforms: bool = false,
    dem_source: ?elevation.Source = null,
    admin_drive_side: ?enhance.AdminDriveSide = null,
    ordering: node_order.Ordering = .{},
    deadline: io.Deadline = .none,
};

pub const Stats = struct {
    source: edges.Stats,
    nodes: u32,
    directed_edges: u32,
    split_nodes: u32,
    connectors: u32,
    distinct_classes: usize,
    turn_pool_bytes: usize,
    distinct_turn_matrices: usize,
    cold_records: u32,
    cold_payload_bytes: u64,
    elevation: elevation.Coverage,
    spatial: graph.spatial.Stats,
    assembly_ns: u64,
};

/// Build the topology, validate it, and write it to the caller's staging
/// bundle. The caller commits the writer after all build stages succeed.
/// Parallel builds require an allocator and admin resolver that support concurrent use.
pub fn build(gpa: Allocator, source: pbf.file.Stream, writer: *format.BundleWriter, options: Options) !Stats {
    const edge_file = try io.File.temporary(options.scratch_dir);
    defer edge_file.close();
    const shape_file = try io.File.temporary(options.scratch_dir);
    defer shape_file.close();

    var metadata = Metadata.init(gpa, options);
    defer metadata.deinit();
    const source_stats = try edges.buildWithGeometry(gpa, source, .{ .edges = edge_file, .shapes = shape_file }, .{
        .scratch_dir = options.scratch_dir,
        .workers = options.workers,
        .include_construction = options.include_construction,
        .include_platforms = options.include_platforms,
        .deadline = options.deadline,
    }, &metadata, Metadata.way, Metadata.node, Metadata.culdesac);

    const timer = io.Timer.start();
    if (source_stats.edges > std.math.maxInt(u32) / 2) return error.TooManyDirectedEdges;
    const edge_map = try io.Mapping.mapFd(edge_file, .read_only);
    defer edge_map.unmap();
    const shape_map = try io.Mapping.mapFd(shape_file, .read_only);
    defer shape_map.unmap();
    const segments = try edge_map.slice(edges.Edge, 0, @intCast(source_stats.edges));
    const shape_points = try shape_map.slice(geo.FixedLL, 0, @intCast(source_stats.shape_points));

    var plan = try Layout.plan(gpa, segments, shape_points, &metadata, options);
    defer plan.deinit(gpa);
    if (plan.nodes.items.len != source_stats.nodes) return error.NodeCountMismatch;

    var topology = try Topology.init(gpa, &plan, segments, options);
    defer topology.deinit(gpa);
    const shared: Shared = .{
        .topology = &topology,
        .segments = segments,
        .shape_points = shape_points,
        .ways = &metadata.ways,
        .deadline = options.deadline,
    };
    var table = blk: {
        var base = try populate(gpa, &shared, options.workers);
        defer base.deinit();
        try validate(topology.first_edge, topology.output.data, topology.coordinates, base.classes, options.deadline);
        break :blk try enhanceGraph(gpa, &shared, &plan, base.classes, options);
    };
    defer table.deinit();
    var terrain = if (options.dem_source) |source_dem|
        try stampElevation(gpa, &shared, options.scratch_dir, options.workers, source_dem)
    else
        null;
    defer if (terrain) |*present| present.deinit();
    var turn_pool = turns.Pool.init(gpa);
    defer turn_pool.deinit();
    try buildTurns(&shared, table.classes, metadata.name_ids.items, &turn_pool);

    try writeTopology(writer, options.scratch_dir, topology, table.classes, turn_pool.bytes.items, if (terrain) |present| present.slopes.data else null);
    const topology_ns = timer.read();
    const means: []const i16 = if (terrain) |*present| present.means.data else &.{};
    const cold_bytes = try buildCold(gpa, &shared, &metadata, writer, options.scratch_dir, means);
    const spatial = try buildSpatial(gpa, &shared, writer, options.scratch_dir, options.workers);
    const bundle_metadata = [_]format.Metadata{.{
        .ordering_kind = @backingInt(options.ordering.kind),
        .order_hash = plan.order_hash,
    }};
    try writer.write(.metadata, &bundle_metadata);
    return .{
        .source = source_stats,
        .nodes = @intCast(topology.nodes.len),
        .directed_edges = @intCast(topology.output.data.len),
        .split_nodes = plan.split_nodes,
        .connectors = plan.connectors,
        .distinct_classes = table.classes.len,
        .turn_pool_bytes = turn_pool.bytes.items.len,
        .distinct_turn_matrices = turn_pool.indices.count(),
        .cold_records = @intCast(topology.output.data.len / 2),
        .cold_payload_bytes = cold_bytes,
        .elevation = if (terrain) |present| present.coverage else .{ .total_edges = segments.len },
        .spatial = spatial,
        .assembly_ns = topology_ns,
    };
}

/// Run the graph stages against the segment files. The same algorithms and
/// section writers are used by build() for ephemeral callers.
pub fn buildStaged(
    session: *checkpoint.Session,
    metadata: *const Metadata,
    source_stats: edges.Stats,
    edge_file: io.File,
    shape_file: io.File,
    options: Options,
) !void {
    const gpa = session.gpa;
    const edge_map = try io.Mapping.mapFd(edge_file, .read_only);
    defer edge_map.unmap();
    const shape_map = try io.Mapping.mapFd(shape_file, .read_only);
    defer shape_map.unmap();
    const segments = try checkpoint.array(edges.Edge, edge_map);
    const points = try checkpoint.array(geo.FixedLL, shape_map);
    if (segments.len != source_stats.edges or points.len != source_stats.shape_points or segments.len > std.math.maxInt(u32) / 2)
        return error.InvalidSegmentCheckpoint;

    var plan = blk: {
        if (session.runs(.order)) {
            const start = io.Timer.start();
            var tx = try session.begin(.order);
            defer tx.deinit();
            var layout = try Layout.plan(gpa, segments, points, metadata, options);
            errdefer layout.deinit(gpa);
            if (layout.nodes.items.len != source_stats.nodes) return error.NodeCountMismatch;
            try layout.save(gpa, &tx);
            try session.commit(&tx, layout.nodes.items.len, start);
            break :blk layout;
        }
        const saved = try session.open(.order);
        defer saved.close();
        break :blk try Layout.load(gpa, saved, options.deadline);
    };
    defer plan.deinit(gpa);
    if (session.endsAt(.order)) return;

    const assembly_start = io.Timer.start();
    if (session.runs(.assemble)) session.current.* = .assemble;
    var topology = if (session.runs(.assemble))
        try Topology.init(gpa, &plan, segments, options)
    else
        try Topology.load(gpa, session, options);
    defer topology.deinit(gpa);
    if (topology.placements.data.len != 2 * segments.len) return error.InvalidCheckpoint;
    const shared: Shared = .{
        .topology = &topology,
        .segments = segments,
        .shape_points = points,
        .ways = &metadata.ways,
        .deadline = options.deadline,
    };
    var edge_classes: ?[]const classes.EdgeClass = null;
    defer if (edge_classes) |owned| gpa.free(owned);
    if (session.runs(.assemble)) {
        var tx = try session.begin(.assemble);
        defer tx.deinit();
        const table = try populate(gpa, &shared, options.workers);
        gpa.free(table.remap);
        edge_classes = table.classes;
        try validate(topology.first_edge, topology.output.data, topology.coordinates, table.classes, options.deadline);
        try topology.savePlacement(&tx);
        try saveAttributes(topology, table.classes, &tx);
        try session.commit(&tx, topology.output.data.len, assembly_start);
    }
    if (session.endsAt(.assemble)) return;

    if (edge_classes == null) {
        const source: checkpoint.Stage = if (session.runs(.enhance)) .assemble else .enhance;
        const saved = try session.open(source);
        defer saved.close();
        edge_classes = try loadArray(classes.EdgeClass, gpa, saved, .classes, options.deadline);
        try validate(topology.first_edge, topology.output.data, topology.coordinates, edge_classes.?, options.deadline);
    }
    if (session.runs(.enhance)) {
        const start = io.Timer.start();
        var tx = try session.begin(.enhance);
        defer tx.deinit();
        const enhanced = try enhanceGraph(gpa, &shared, &plan, edge_classes.?, options);
        gpa.free(enhanced.remap);
        gpa.free(edge_classes.?);
        edge_classes = enhanced.classes;
        try saveAttributes(topology, enhanced.classes, &tx);
        try session.commit(&tx, topology.output.data.len, start);
    }
    if (session.endsAt(.enhance)) return;

    var terrain: ?Terrain = null;
    defer if (terrain) |*present| present.deinit();
    if (session.runs(.elevation)) {
        const start = io.Timer.start();
        var tx = try session.begin(.elevation);
        defer tx.deinit();
        if (options.dem_source) |source_dem| {
            terrain = try stampElevation(gpa, &shared, options.scratch_dir, options.workers, source_dem);
            try tx.writeArray(terrain.?.means.data, .means);
            try tx.writeArray(terrain.?.slopes.data, .slopes);
        }
        const coverage: elevation.Coverage = if (terrain) |present| present.coverage else .{ .total_edges = segments.len };
        try tx.writeArray(topology.output.data, .directed_edges);
        try tx.writeJson(gpa, coverage, .terrain_stats);
        try session.commit(&tx, if (terrain != null) segments.len else 0, start);
    }
    if (session.endsAt(.elevation)) return;

    var turn_pool = turns.Pool.init(gpa);
    defer turn_pool.deinit();
    if (session.runs(.turns)) {
        const start = io.Timer.start();
        var tx = try session.begin(.turns);
        defer tx.deinit();
        try buildTurns(&shared, edge_classes.?, metadata.name_ids.items, &turn_pool);
        try tx.writeArray(topology.nodes, .nodes);
        try tx.writeArray(turn_pool.bytes.items, .turn_pool);
        try tx.writeJson(gpa, turn_pool.indices.count(), .turn_stats);
        try session.commit(&tx, topology.nodes.len, start);
    }
    if (session.endsAt(.turns)) return;

    if (session.runs(.cold)) {
        const start = io.Timer.start();
        var tx = try session.begin(.cold);
        defer tx.deinit();
        var writer = try stageWriter(session.*, tx);
        defer writer.deinit();
        const saved_turns = try session.open(.turns);
        defer saved_turns.close();
        const turn_data = try saved_turns.map(.turn_pool, options.deadline);
        defer turn_data.unmap();
        const saved_terrain = try session.open(.elevation);
        defer saved_terrain.close();
        const coverage = try saved_terrain.readJson(elevation.Coverage, gpa, .terrain_stats, options.deadline);
        defer coverage.deinit();
        const means_map = if (coverage.value.dem_configured) try saved_terrain.map(.means, options.deadline) else null;
        defer if (means_map) |mapped| mapped.unmap();
        const slopes_map = if (coverage.value.dem_configured) try saved_terrain.map(.slopes, options.deadline) else null;
        defer if (slopes_map) |mapped| mapped.unmap();
        const means = if (means_map) |mapped| try checkpoint.array(i16, mapped) else &.{};
        if (means.len != 0 and means.len != segments.len) return error.InvalidCheckpoint;
        try writeTopology(&writer, options.scratch_dir, topology, edge_classes.?, turn_data.bytes, if (slopes_map) |mapped| try checkpoint.array(u16, mapped) else null);
        const cold_bytes = try buildCold(gpa, &shared, metadata, &writer, options.scratch_dir, means);
        try tx.writeJson(gpa, cold_bytes, .source_stats);
        try writer.write(.metadata, &.{.{
            .ordering_kind = @backingInt(options.ordering.kind),
            .order_hash = plan.order_hash,
        }});
        try tx.saveSections(&writer);
        try session.commit(&tx, topology.output.data.len / 2, start);
    }
    if (session.endsAt(.cold)) return;

    if (session.runs(.spatial)) {
        const start = io.Timer.start();
        var tx = try session.begin(.spatial);
        defer tx.deinit();
        var writer = try stageWriter(session.*, tx);
        defer writer.deinit();
        const spatial = try buildSpatial(gpa, &shared, &writer, options.scratch_dir, options.workers);
        try tx.writeJson(gpa, spatial, .spatial_stats);
        try tx.saveSections(&writer);
        try session.commit(&tx, spatial.cells, start);
    }
}

fn saveAttributes(topology: Topology, edge_classes: []const classes.EdgeClass, tx: *checkpoint.Transaction) !void {
    try tx.writeArray(topology.nodes, .nodes);
    try tx.writeArray(topology.output.data, .directed_edges);
    try tx.writeArray(edge_classes, .classes);
}

fn writeTopology(writer: *format.BundleWriter, scratch_dir: []const u8, topology: Topology, edge_classes: []const classes.EdgeClass, turn_data: []const u8, slopes: ?[]const u16) !void {
    try writer.write(.nodes, topology.nodes);
    try writer.write(.edges, topology.output.data);
    try writer.write(.first_edge, topology.first_edge);
    try writer.write(.classes, edge_classes);
    try writer.write(.coordinates, topology.coordinates);
    try writer.write(.turns, turn_data);
    if (slopes) |data| try writer.write(.slopes, data);
    const labels = try Scratch(u32).init(topology.nodes.len, scratch_dir);
    defer labels.deinit();
    try components.label(labels.data, topology.first_edge, topology.output.data, writer.deadline);
    try writer.write(.components, labels.data);
}

pub fn stageWriter(session: checkpoint.Session, tx: checkpoint.Transaction) !format.BundleWriter {
    const path = try std.fs.path.join(session.gpa, &.{ session.path, &tx.name, "bundle" });
    defer session.gpa.free(path);
    return format.BundleWriter.init(path, session.identity, session.deadline);
}

const neutral_node: format.NodeHot = .{
    .turn_off = 0,
    .attr = .{ .access = @bitCast(graph.constants.AccessMask.all_tag_modes), .type = 0, .density = 0, .signal = 0 },
};

const Way = extern struct {
    by_direction: [2]classes.EdgeClass,
    speeds: packed struct(u32) {
        forward: u8,
        backward: u8,
        truck: u8,
        limit: u8,
    },
    attr: packed struct(u32) {
        oneway: bool,
        importance: u3,
        has_names: bool,
        layer: i8,
        reserved: u19 = 0,
    },
    level_start: u32,
    level_count: u32,
    name_start: u32,
    ref_start: u32,
    ref_end: u32,
    name_end: u32,
};

const WayEntry = extern struct {
    id: i64,
    way: Way,
};

const NodeEntry = extern struct {
    id: i64,
    hot: format.NodeHot,
};

comptime {
    std.debug.assert(@sizeOf(Way) == 72);
    std.debug.assert(@offsetOf(Way, "by_direction") == 0 and @offsetOf(Way, "speeds") == 40 and @offsetOf(Way, "attr") == 44);
    std.debug.assert(@offsetOf(Way, "level_start") == 48 and @offsetOf(Way, "name_end") == 68);
    std.debug.assert(@sizeOf(WayEntry) == 80 and @offsetOf(WayEntry, "way") == 8);
    std.debug.assert(@sizeOf(NodeEntry) == 16 and @offsetOf(NodeEntry, "hot") == 8);
}

const Ways = std.AutoHashMapUnmanaged(i64, Way);
pub const Metadata = struct {
    gpa: Allocator,
    drive_side: edge_class.DriveSide,
    deadline: io.Deadline,
    strings: tags.names.StringTable,
    name_ids: std.ArrayList(tags.names.Id) = .empty,
    levels: std.ArrayList(graph.cold.LevelRange) = .empty,
    nodes: std.AutoHashMapUnmanaged(i64, format.NodeHot) = .empty,
    ways: Ways = .empty,

    pub fn init(gpa: Allocator, options: Options) Metadata {
        return .{ .gpa = gpa, .drive_side = options.drive_side, .deadline = options.deadline, .strings = .init(gpa) };
    }

    pub fn saveNodes(self: *const Metadata, tx: *checkpoint.Transaction) !void {
        const file = try tx.create(.node_attributes);
        defer file.close();
        var rows: [2048]NodeEntry = undefined;
        var count: usize = 0;
        var offset: u64 = 0;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            rows[count] = .{ .id = entry.key_ptr.*, .hot = entry.value_ptr.* };
            count += 1;
            if (count == rows.len) {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                try file.pwriteAll(std.mem.asBytes(&rows), offset);
                offset += @sizeOf(@TypeOf(rows));
                count = 0;
            }
        }
        try file.pwriteAll(std.mem.sliceAsBytes(rows[0..count]), offset);
        try file.sync();
    }

    pub fn loadNodes(self: *Metadata, saved: checkpoint.Existing) !void {
        const mapped = try saved.map(.node_attributes, self.deadline);
        defer mapped.unmap();
        for (try checkpoint.array(NodeEntry, mapped), 0..) |entry, i| {
            try checkDeadline(self.deadline, i);
            try self.nodes.put(self.gpa, entry.id, entry.hot);
        }
    }

    pub fn saveWays(self: *const Metadata, tx: *checkpoint.Transaction) !void {
        const file = try tx.create(.way_attributes);
        defer file.close();
        var rows: [512]WayEntry = undefined;
        var count: usize = 0;
        var offset: u64 = 0;
        var iter = self.ways.iterator();
        while (iter.next()) |entry| {
            rows[count] = .{ .id = entry.key_ptr.*, .way = entry.value_ptr.* };
            count += 1;
            if (count == rows.len) {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                try file.pwriteAll(std.mem.asBytes(&rows), offset);
                offset += @sizeOf(@TypeOf(rows));
                count = 0;
            }
        }
        try file.pwriteAll(std.mem.sliceAsBytes(rows[0..count]), offset);
        try file.sync();
        const names = try tx.create(.names);
        defer names.close();
        offset = 0;
        for (self.strings.strings.items, 0..) |text, i| {
            try checkDeadline(self.deadline, i);
            const size = std.math.cast(u32, text.len) orelse return error.NameTooLarge;
            try names.pwriteAll(std.mem.asBytes(&size), offset);
            offset += @sizeOf(u32);
            try names.pwriteAll(text, offset);
            offset += size;
        }
        try names.sync();
        try tx.writeArray(self.name_ids.items, .name_refs);
        try tx.writeArray(self.levels.items, .levels);
    }

    pub fn loadWays(self: *Metadata, saved: checkpoint.Existing) !void {
        const names = try saved.map(.names, self.deadline);
        defer names.unmap();
        var remaining: []const u8 = names.bytes;
        while (remaining.len != 0) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (remaining.len < @sizeOf(u32)) return error.InvalidCheckpoint;
            const len = std.mem.readInt(u32, remaining[0..@sizeOf(u32)], .little);
            remaining = remaining[@sizeOf(u32)..];
            if (len == 0 or len > remaining.len) return error.InvalidCheckpoint;
            _ = try self.strings.intern(remaining[0..len]);
            remaining = remaining[len..];
        }
        const refs = try saved.map(.name_refs, self.deadline);
        defer refs.unmap();
        for (try checkpoint.array(tags.names.Id, refs), 0..) |id, i| {
            try checkDeadline(self.deadline, i);
            if (self.strings.get(id) == null) return error.InvalidCheckpoint;
            try self.name_ids.append(self.gpa, id);
        }
        const levels = try saved.map(.levels, self.deadline);
        defer levels.unmap();
        try self.levels.appendSlice(self.gpa, try checkpoint.array(graph.cold.LevelRange, levels));

        const ways = try saved.map(.way_attributes, self.deadline);
        defer ways.unmap();
        for (try checkpoint.array(WayEntry, ways), 0..) |entry, i| {
            try checkDeadline(self.deadline, i);
            const attrs = entry.way;
            if (attrs.name_start > attrs.ref_start or attrs.ref_start > attrs.ref_end or attrs.name_start > attrs.name_end or
                attrs.name_end - attrs.name_start > graph.cold.max_names or attrs.name_end > self.name_ids.items.len or
                attrs.level_start > self.levels.items.len or attrs.level_count > self.levels.items.len - attrs.level_start)
                return error.InvalidCheckpoint;
            try self.ways.put(self.gpa, entry.id, attrs);
        }
    }

    pub fn deinit(self: *Metadata) void {
        self.nodes.deinit(self.gpa);
        self.ways.deinit(self.gpa);
        self.name_ids.deinit(self.gpa);
        self.levels.deinit(self.gpa);
        self.strings.deinit();
    }

    pub fn node(self: *Metadata, id: i64, attrs: tags.NodeAttrs) !void {
        const hot: format.NodeHot = .{
            .turn_off = 0,
            .attr = .{
                .access = @bitCast(attrs.access),
                .type = @backingInt(attrs.type),
                .density = 0,
                .signal = @intFromBool(attrs.flags.traffic_signal),
                .tagged_access = attrs.flags.tagged_access,
                .private_access = attrs.flags.private_access,
                .cash_only_toll = attrs.flags.cash_only_toll,
            },
        };
        if (!std.meta.eql(hot, neutral_node)) try self.nodes.put(self.gpa, id, hot);
    }

    pub fn way(self: *Metadata, id: i64, attrs: tags.WayAttrs, raw_tags: pbf.block.TagIterator) !void {
        const use = attrs.edgeUse();
        const directed_use = if (attrs.flags.turn_channel and attrs.use != .construction)
            .turn_channel
        else if (attrs.flags.link and attrs.use != .service_area and attrs.use != .rest_area and attrs.use != .construction)
            .ramp
        else
            use;

        var pair = [2]classes.EdgeClass{
            try edge_class.fromWay(attrs, true, self.drive_side),
            try edge_class.fromWay(attrs, false, self.drive_side),
        };
        for (&pair) |*class| {
            class.category.use = @intCast(@backingInt(directed_use));
            if (directed_use == .ramp or directed_use == .turn_channel) class.flags.internal = false;
        }
        const entry = try self.ways.getOrPut(self.gpa, id);
        if (entry.found_existing) return error.DuplicateWay;
        const indexed = try self.strings.indexWay(attrs, raw_tags, .{}, self.deadline);
        const name_start = try self.nameOffset();
        const ref_first = attrs.road_class == .motorway or attrs.road_class == .trunk;
        if (!ref_first) try self.appendNames(indexed.name.text);
        const ref_start = try self.nameOffset();
        try self.appendNames(indexed.ref.text);
        const ref_end = try self.nameOffset();
        if (ref_first) try self.appendNames(indexed.name.text);
        if (indexed.alt_name.text != indexed.name.text) try self.appendNames(indexed.alt_name.text);
        if (indexed.official_name.text != indexed.name.text and indexed.official_name.text != indexed.alt_name.text)
            try self.appendNames(indexed.official_name.text);
        const name_end = try self.nameOffset();
        const level_start = std.math.cast(u32, self.levels.items.len) orelse return error.TooManyLevels;
        if (attrs.level) |level| try appendLevels(&self.levels, self.gpa, level, self.deadline);
        entry.value_ptr.* = .{
            .by_direction = pair,
            .speeds = .{
                .forward = if (attrs.flags.forward_tagged_speed) attrs.forward_speed else attrs.speed,
                .backward = if (attrs.flags.backward_tagged_speed) attrs.backward_speed else attrs.speed,
                .truck = attrs.truck_speed,
                .limit = attrs.speed_limit,
            },
            .attr = .{
                .oneway = attrs.flags.oneway,
                .importance = @intCast(@backingInt(attrs.road_class)),
                .has_names = name_start != name_end,
                .layer = attrs.layer,
            },
            .level_start = level_start,
            .level_count = std.math.cast(u32, self.levels.items.len - level_start) orelse return error.TooManyLevels,
            .name_start = name_start,
            .ref_start = ref_start,
            .ref_end = ref_end,
            .name_end = @min(name_end, name_start +| graph.cold.max_names),
        };
    }

    fn nameOffset(self: *const Metadata) !u32 {
        return std.math.cast(u32, self.name_ids.items.len) orelse error.TooManyNames;
    }

    fn appendNames(self: *Metadata, id: tags.names.Id) !void {
        var tokens = std.mem.tokenizeScalar(u8, self.strings.get(id).?, ';');
        while (tokens.next()) |token| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            try self.name_ids.append(self.gpa, try self.strings.intern(token));
        }
    }

    pub fn culdesac(self: *Metadata, id: i64) !void {
        const way_attrs = self.ways.getPtr(id) orelse return;
        for (&way_attrs.by_direction) |*class| {
            if (class.category.use == @backingInt(graph.constants.Use.road))
                class.category.use = @backingInt(graph.constants.Use.culdesac);
        }
    }
};

const Node = extern struct {
    osm_id: i64,
    point: geo.FixedLL,
    hot: format.NodeHot,
    degree: u32 = 0,
    first_alias: u32 = 0,
    placed: u32 = 0,
    reserved: u32 = 0,
};

const LayoutStats = struct { node_count: u32, split_nodes: u32, connectors: u32, order_hash: u64 };

const Layout = struct {
    nodes: std.ArrayList(Node) = .empty,
    by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    node_count: u32 = 0,
    split_nodes: u32 = 0,
    connectors: u32 = 0,
    order_hash: u64 = 0,

    fn plan(gpa: Allocator, segments: []const edges.Edge, points: []const geo.FixedLL, metadata: *const Metadata, options: Options) !Layout {
        const deadline = options.deadline;
        var self: Layout = .{};
        errdefer self.deinit(gpa);
        for (segments, 0..) |segment, i| {
            try checkDeadline(deadline, i);
            if (segment.from == segment.to) return error.SelfEdge;
            const shape = try segmentShape(points, segment);
            try self.countNode(gpa, metadata, segment.from, shape[0]);
            try self.countNode(gpa, metadata, segment.to, shape[shape.len - 1]);
        }
        try self.applyOrder(gpa, options);
        for (self.nodes.items, 0..) |*node, i| {
            try checkDeadline(deadline, i);
            const aliases = aliasCount(node.degree);
            node.first_alias = self.node_count;
            self.node_count = std.math.add(u32, self.node_count, aliases) catch return error.TooManyNodes;
            self.split_nodes += @intFromBool(aliases > 1);
            self.connectors += aliases - 1;
        }
        if (2 * (@as(u64, segments.len) + self.connectors) > std.math.maxInt(u32))
            return error.TooManyDirectedEdges;
        return self;
    }

    fn save(self: *const Layout, gpa: Allocator, tx: *checkpoint.Transaction) !void {
        try tx.writeArray(self.nodes.items, .logical_nodes);
        try tx.writeJson(gpa, LayoutStats{
            .node_count = self.node_count,
            .split_nodes = self.split_nodes,
            .connectors = self.connectors,
            .order_hash = self.order_hash,
        }, .layout_stats);
    }

    fn load(gpa: Allocator, saved: checkpoint.Existing, deadline: io.Deadline) !Layout {
        const stats = try saved.readJson(LayoutStats, gpa, .layout_stats, deadline);
        defer stats.deinit();
        const mapped = try saved.map(.logical_nodes, deadline);
        defer mapped.unmap();
        var self: Layout = .{
            .node_count = stats.value.node_count,
            .split_nodes = stats.value.split_nodes,
            .connectors = stats.value.connectors,
            .order_hash = stats.value.order_hash,
        };
        errdefer self.deinit(gpa);
        try self.nodes.appendSlice(gpa, try checkpoint.array(Node, mapped));
        var total: u32 = 0;
        for (self.nodes.items, 0..) |node, i| {
            try checkDeadline(deadline, i);
            if (node.reserved != 0 or node.placed != 0 or node.degree == 0 or node.first_alias != total) return error.InvalidCheckpoint;
            total = std.math.add(u32, total, aliasCount(node.degree)) catch return error.InvalidCheckpoint;
            try self.by_id.putNoClobber(gpa, node.osm_id, @intCast(i));
        }
        if (total != self.node_count) return error.InvalidCheckpoint;
        return self;
    }

    fn applyOrder(self: *Layout, gpa: Allocator, options: Options) !void {
        const coordinates = try Scratch(geo.FixedLL).init(self.nodes.items.len, options.scratch_dir);
        defer coordinates.deinit();
        for (self.nodes.items, coordinates.data, 0..) |node, *point, i| {
            try checkDeadline(options.deadline, i);
            point.* = node.point;
        }
        const permutation = try options.ordering.permutation(gpa, coordinates.data, options.deadline);
        defer gpa.free(permutation);
        self.order_hash = try node_order.hash(permutation, options.deadline);
        if (options.ordering.kind == .encounter) return;

        const previous_to_next = try Scratch(u32).init(permutation.len, options.scratch_dir);
        defer previous_to_next.deinit();
        const next_nodes = try gpa.alloc(Node, permutation.len);
        errdefer gpa.free(next_nodes);
        for (permutation, next_nodes, 0..) |previous, *node, next| {
            try checkDeadline(options.deadline, next);
            node.* = self.nodes.items[previous];
            previous_to_next.data[previous] = @intCast(next);
        }
        var references = self.by_id.valueIterator();
        var i: usize = 0;
        while (references.next()) |id| : (i += 1) {
            try checkDeadline(options.deadline, i);
            id.* = previous_to_next.data[id.*];
        }
        self.nodes.deinit(gpa);
        self.nodes = .fromOwnedSlice(next_nodes);
    }

    fn countNode(self: *Layout, gpa: Allocator, metadata: *const Metadata, id: i64, point: geo.FixedLL) !void {
        const entry = try self.by_id.getOrPut(gpa, id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.math.cast(u32, self.nodes.items.len) orelse return error.TooManyNodes;
            try self.nodes.append(gpa, .{ .osm_id = id, .point = point, .hot = metadata.nodes.get(id) orelse neutral_node });
        }
        const node = &self.nodes.items[entry.value_ptr.*];
        if (node.point.lat != point.lat or node.point.lng != point.lng) return error.InconsistentCoordinates;
        node.degree = std.math.add(u32, node.degree, 1) catch return error.TooManyDirectedEdges;
    }

    fn place(self: *Layout, id: i64, offsets: []const u32) Placement {
        const node = &self.nodes.items[self.by_id.get(id).?];
        const index = node.placed;
        node.placed += 1;
        const count = aliasCount(node.degree);
        const group = if (count == 1 or index < max_degree - 1)
            0
        else
            @min(1 + (index - (max_degree - 1)) / (max_degree - 2), count - 1);
        const consumed = if (group == 0) 0 else max_degree - 1 + (group - 1) * (max_degree - 2);
        const alias = node.first_alias + group;
        return .{ .node = alias, .slot = offsets[alias] + (index - consumed) };
    }

    fn deinit(self: *Layout, gpa: Allocator) void {
        self.by_id.deinit(gpa);
        self.nodes.deinit(gpa);
    }
};

fn aliasCount(degree: u32) u32 {
    if (degree <= max_degree) return 1;
    // End groups reserve one slot and internal groups reserve two.
    return 1 + (degree - 3) / (max_degree - 2);
}

const Group = packed struct(u8) {
    has_left: bool,
    has_right: bool,
    real_degree: u6,
};

const Placement = extern struct {
    node: u32,
    slot: u32,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Node) == 40 and @offsetOf(Node, "osm_id") == 0);
    std.debug.assert(@offsetOf(Node, "point") == 8 and @offsetOf(Node, "hot") == 16);
    std.debug.assert(@offsetOf(Node, "degree") == 24 and @offsetOf(Node, "reserved") == 36);
    std.debug.assert(@sizeOf(Placement) == 8 and @offsetOf(Placement, "node") == 0 and @offsetOf(Placement, "slot") == 4);
}

fn Scratch(comptime T: type) type {
    return struct {
        mapping: io.Mapping,
        data: []T,

        fn init(count: usize, dir: []const u8) !@This() {
            const file = try io.File.temporary(dir);
            defer file.close();
            const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.ScratchTooLarge;
            try file.truncate(bytes);
            const mapping = try io.Mapping.mapFd(file, .shared_writable);
            errdefer mapping.unmap();
            return .{ .mapping = mapping, .data = try mapping.sliceMut(T, 0, count) };
        }

        fn load(saved: checkpoint.Existing, key: checkpoint.Artifact, options: Options) !@This() {
            const file = try saved.read(key, options.deadline);
            defer file.close();
            const bytes = try file.size();
            if (bytes % @sizeOf(T) != 0) return error.InvalidCheckpoint;
            const self = try init(@intCast(bytes / @sizeOf(T)), options.scratch_dir);
            errdefer self.deinit();
            try file.preadAll(std.mem.sliceAsBytes(self.data), 0);
            return self;
        }

        fn deinit(self: @This()) void {
            self.mapping.unmap();
        }
    };
}

const Topology = struct {
    nodes: []format.NodeHot,
    coordinates: []format.Coordinate,
    groups: []Group,
    first_edge: []u32,
    slot_refs: Scratch(u32),
    placements: Scratch(Placement),
    output: Scratch(format.EdgeHot),

    fn init(gpa: Allocator, plan: *Layout, segments: []const edges.Edge, options: Options) !Topology {
        const deadline = options.deadline;
        const count = 2 * (segments.len + plan.connectors);
        const nodes = try gpa.alloc(format.NodeHot, plan.node_count);
        errdefer gpa.free(nodes);
        const coordinates = try gpa.alloc(format.Coordinate, plan.node_count);
        errdefer gpa.free(coordinates);
        const groups = try gpa.alloc(Group, plan.node_count);
        errdefer gpa.free(groups);
        const offsets = try gpa.alloc(u32, @as(usize, plan.node_count) + 1);
        errdefer gpa.free(offsets);

        var offset: u32 = 0;
        for (plan.nodes.items) |node| {
            const aliases = aliasCount(node.degree);
            var remaining = node.degree;
            for (0..aliases) |group| {
                const alias = node.first_alias + group;
                try checkDeadline(deadline, alias);
                const left = group != 0;
                const right = group + 1 != aliases;
                const connectors = @as(u32, @intFromBool(left)) + @intFromBool(right);
                const real = @min(remaining, max_degree - connectors);
                offsets[alias] = offset;
                offset += real + connectors;
                remaining -= real;
                groups[alias] = .{ .has_left = left, .has_right = right, .real_degree = @intCast(real) };
                nodes[alias] = node.hot;
                coordinates[alias] = node.point;
            }
        }
        offsets[nodes.len] = offset;
        if (offset != count) return error.InvalidDegreeLayout;

        const src = try Scratch(u32).init(count, options.scratch_dir);
        errdefer src.deinit();
        const placements = try Scratch(Placement).init(segments.len * 2, options.scratch_dir);
        errdefer placements.deinit();
        const output = try Scratch(format.EdgeHot).init(count, options.scratch_dir);
        errdefer output.deinit();

        for (segments, 0..) |segment, i| {
            try checkDeadline(deadline, i);
            const forward = plan.place(segment.from, offsets);
            const reverse = plan.place(segment.to, offsets);
            placements.data[2 * i] = forward;
            placements.data[2 * i + 1] = reverse;
            src.data[forward.slot] = @intCast(2 * i);
            src.data[reverse.slot] = @intCast(2 * i + 1);
        }
        return .{
            .nodes = nodes,
            .coordinates = coordinates,
            .groups = groups,
            .first_edge = offsets,
            .slot_refs = src,
            .placements = placements,
            .output = output,
        };
    }

    fn savePlacement(self: Topology, tx: *checkpoint.Transaction) !void {
        try tx.writeArray(self.coordinates, .coordinates);
        try tx.writeArray(self.groups, .groups);
        try tx.writeArray(self.first_edge, .first_edge);
        try tx.writeArray(self.slot_refs.data, .slot_refs);
        try tx.writeArray(self.placements.data, .placements);
    }

    fn load(gpa: Allocator, session: *checkpoint.Session, options: Options) !Topology {
        const base = try session.open(.assemble);
        defer base.close();
        const nodes_stage: checkpoint.Stage = if (@backingInt(session.from) > @backingInt(checkpoint.Stage.turns)) .turns else if (@backingInt(session.from) > @backingInt(checkpoint.Stage.enhance)) .enhance else .assemble;
        const edges_stage: checkpoint.Stage = if (@backingInt(session.from) > @backingInt(checkpoint.Stage.elevation)) .elevation else if (@backingInt(session.from) > @backingInt(checkpoint.Stage.enhance)) .enhance else .assemble;
        const nodes_source = try session.open(nodes_stage);
        defer nodes_source.close();
        const edges_source = try session.open(edges_stage);
        defer edges_source.close();

        const nodes = try loadArray(format.NodeHot, gpa, nodes_source, .nodes, options.deadline);
        errdefer gpa.free(nodes);
        const coordinates = try loadArray(format.Coordinate, gpa, base, .coordinates, options.deadline);
        errdefer gpa.free(coordinates);
        const groups = try loadArray(Group, gpa, base, .groups, options.deadline);
        errdefer gpa.free(groups);
        const first_edge = try loadArray(u32, gpa, base, .first_edge, options.deadline);
        errdefer gpa.free(first_edge);
        const slot_refs = try Scratch(u32).load(base, .slot_refs, options);
        errdefer slot_refs.deinit();
        const placements = try Scratch(Placement).load(base, .placements, options);
        errdefer placements.deinit();
        const output = try Scratch(format.EdgeHot).load(edges_source, .directed_edges, options);
        errdefer output.deinit();
        if (groups.len != nodes.len or coordinates.len != nodes.len or first_edge.len != nodes.len + 1 or
            first_edge[0] != 0 or first_edge[nodes.len] != output.data.len or slot_refs.data.len != output.data.len)
            return error.InvalidCheckpoint;
        return .{
            .nodes = nodes,
            .coordinates = coordinates,
            .groups = groups,
            .first_edge = first_edge,
            .slot_refs = slot_refs,
            .placements = placements,
            .output = output,
        };
    }

    fn deinit(self: Topology, gpa: Allocator) void {
        self.output.deinit();
        self.placements.deinit();
        self.slot_refs.deinit();
        gpa.free(self.first_edge);
        gpa.free(self.groups);
        gpa.free(self.coordinates);
        gpa.free(self.nodes);
    }
};

fn loadArray(comptime T: type, gpa: Allocator, saved: checkpoint.Existing, key: checkpoint.Artifact, deadline: io.Deadline) ![]T {
    const mapping = try saved.map(key, deadline);
    defer mapping.unmap();
    return gpa.dupe(T, try checkpoint.array(T, mapping));
}

const Shared = struct {
    topology: *Topology,
    segments: []const edges.Edge,
    shape_points: []const geo.FixedLL,
    ways: *const Ways,
    deadline: io.Deadline,
};

const Job = struct {
    shared: *const Shared,
    start: usize,
    end: usize,
    interner: classes.Interner,
    result: anyerror!void = {},

    fn run(self: *Job) void {
        self.result = self.emit();
    }

    fn emit(self: *Job) !void {
        const shared = self.shared;
        const topo = shared.topology;
        for (self.start..self.end) |node| {
            try checkDeadline(shared.deadline, node - self.start);
            const first = topo.first_edge[node];
            const group = topo.groups[node];
            for (0..group.real_degree) |local| {
                const slot = first + local;
                const ref = topo.slot_refs.data[slot];
                const segment = shared.segments[ref / 2];
                const opposite = topo.placements.data[ref ^ 1];
                const way = shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
                const direction = ref & 1;
                var class = way.by_direction[direction];
                edge_class.applySegmentControls(&class, segment.flags, direction == 0, way.attr.oneway);
                const encoded_len = try encodeLength(segment.length_m);
                const curvature = try computeCurvature(try segmentShape(shared.shape_points, segment), shared.deadline);
                topo.output.data[slot] = .{
                    .head = opposite.node,
                    .geom = .{ .len_m = encoded_len, .grade = 6, .curvature = curvature },
                    .cls = .{
                        .class_id = @intCast(@backingInt(try self.interner.intern(class))),
                        .local = @intCast(local),
                        .opp_local = @intCast(opposite.slot - topo.first_edge[opposite.node]),
                        .cold_checks = 0,
                        .pred_speed = 0,
                    },
                    .speed = .{ if (direction == 0) way.speeds.forward else way.speeds.backward, 0, 0, way.speeds.truck },
                };
            }
            if (!group.has_left and !group.has_right) continue;
            const access = topo.nodes[node].attr.access;
            const connector = try self.interner.intern(.{
                .access = .{ .forward = access, .reverse = access },
                .flags = .{ .node_connector = true },
            });
            var local: u32 = group.real_degree;
            if (group.has_left) {
                const other = topo.groups[node - 1];
                topo.output.data[first + local] = connectorEdge(node - 1, local, other.real_degree + @as(u32, @intFromBool(other.has_left)), connector);
                local += 1;
            }
            if (group.has_right) {
                const other = topo.groups[node + 1];
                topo.output.data[first + local] = connectorEdge(node + 1, local, other.real_degree, connector);
            }
        }
    }
};

fn connectorEdge(head: usize, local: u32, opp_local: u32, class: classes.Handle) format.EdgeHot {
    return .{
        .head = @intCast(head),
        .geom = .{ .len_m = 0, .grade = 6, .curvature = 0 },
        .cls = .{
            .class_id = @intCast(@backingInt(class)),
            .local = @intCast(local),
            .opp_local = @intCast(opp_local),
            .cold_checks = 0,
            .pred_speed = 0,
        },
        .speed = .{ 1, 0, 0, 0 },
    };
}

fn populate(gpa: Allocator, shared: *const Shared, requested: usize) !classes.Table {
    const workers = if (requested == 0) std.Thread.getCpuCount() catch 1 else requested;
    const nodes = shared.topology.nodes.len;
    const count = @max(1, @min(workers, max_workers, (nodes + 255) / 256));
    var jobs: [max_workers]Job = undefined;
    const active = jobs[0..count];
    for (active, 0..) |*job, i| {
        const start = (nodes * i) / count;
        const end = (nodes * (i + 1)) / count;
        job.* = .{ .shared = shared, .start = start, .end = end, .interner = .init(gpa) };
    }
    defer for (active) |*job| job.interner.deinit();

    try runJobs(active);

    if (count == 1) {
        var table = try active[0].interner.finish(shared.deadline);
        errdefer table.deinit();
        try remapEdges(shared.topology.output.data, table.remap, shared.deadline);
        return table;
    }

    var interned = classes.Interner.init(gpa);
    defer interned.deinit();
    var remaps: [max_workers][]classes.Handle = undefined;
    var allocated: usize = 0;
    defer for (remaps[0..allocated]) |remap| gpa.free(remap);
    for (active, remaps[0..count]) |*job, *remap| {
        const local = job.interner.rows.items;
        remap.* = try gpa.alloc(classes.Handle, local.len);
        allocated += 1;
        for (local, remap.*, 0..) |entry, *dst, i| {
            try checkDeadline(shared.deadline, i);
            dst.* = try interned.intern(entry);
        }
    }
    var table = try interned.finish(shared.deadline);
    errdefer table.deinit();
    const topo = shared.topology;
    for (active, remaps[0..count]) |job, remap| {
        const ids = try gpa.alloc(classes.ClassId, remap.len);
        defer gpa.free(ids);
        for (remap, ids, 0..) |handle, *id, i| {
            try checkDeadline(shared.deadline, i);
            id.* = try table.id(handle);
        }
        try remapEdges(topo.output.data[topo.first_edge[job.start]..topo.first_edge[job.end]], ids, shared.deadline);
    }
    return table;
}

fn runJobs(jobs: anytype) !void {
    var threads: [max_workers - 1]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (jobs[0 .. jobs.len - 1]) |*job| {
        threads[started] = try std.Thread.spawn(.{}, @TypeOf(job.*).run, .{job});
        started += 1;
    }
    jobs[jobs.len - 1].run();
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    for (jobs) |job| try job.result;
}

const NodeEnhanceJob = struct {
    gpa: Allocator,
    network: enhance.Network,
    tiles: enhance.TileIndex,
    active: []const u32,
    nodes: []format.NodeHot,
    options: Options,
    result: anyerror!void = {},

    fn run(self: *NodeEnhanceJob) void {
        self.result = self.emit();
    }

    fn emit(self: *NodeEnhanceJob) !void {
        var density: enhance.Density = .{};
        defer density.deinit(self.gpa);
        const deadline = self.options.deadline;
        for (self.active, 0..) |tile, i| {
            try checkDeadline(deadline, i);
            try density.apply(self.gpa, self.network, self.tiles, tile, self.nodes, deadline);
            for (self.tiles.nodes(tile), 0..) |id, j| {
                try checkDeadline(deadline, j);
                const node = &self.nodes[id];
                const override = if (self.options.admin_drive_side) |admin|
                    admin.resolve(admin.context, self.network.coordinates[id])
                else
                    null;
                node.attr.drive_on_left = (override orelse self.options.drive_side) == .left;
                node.attr.intersection = try enhance.intersection(self.network, id, deadline);
            }
        }
    }
};

const EdgeEnhanceJob = struct {
    gpa: Allocator,
    network: enhance.Network,
    flags: []u8,
    start: usize,
    end: usize,
    deadline: io.Deadline,
    result: anyerror!void = {},

    fn run(self: *EdgeEnhanceJob) void {
        self.result = self.emit();
    }

    fn emit(self: *EdgeEnhanceJob) !void {
        var search = try enhance.Search.init(self.gpa);
        defer search.deinit(self.gpa);
        for (self.start..self.end) |id| {
            try checkDeadline(self.deadline, id - self.start);
            const first = self.network.first_edge[id];
            const end = self.network.first_edge[id + 1];
            for (self.network.edges[first..end], self.flags[first..end]) |edge, *flag| {
                flag.* = @intFromBool(try search.notThru(self.network, @intCast(id), edge, self.deadline));
            }
        }
    }
};

fn enhanceGraph(gpa: Allocator, shared: *const Shared, plan: *const Layout, base: []const classes.EdgeClass, options: Options) !classes.Table {
    const topo = shared.topology;
    const deadline = options.deadline;
    const aliases = try Scratch(u32).init(if (plan.split_nodes == 0) 0 else topo.nodes.len, options.scratch_dir);
    defer aliases.deinit();
    if (aliases.data.len != 0) {
        for (plan.nodes.items, 0..) |node, i| {
            try checkDeadline(deadline, i);
            const count = aliasCount(node.degree);
            var remaining = aliases.data[node.first_alias..][0..count];
            while (remaining.len != 0) {
                if (deadline.expired()) return error.DeadlineExceeded;
                const n = @min(remaining.len, 1024);
                @memset(remaining[0..n], node.first_alias);
                remaining = remaining[n..];
            }
        }
    }
    const order = try Scratch(u32).init(topo.output.data.len, options.scratch_dir);
    defer order.deinit();
    const flags = try Scratch(u8).init(topo.output.data.len, options.scratch_dir);
    defer flags.deinit();
    try orderWalks(shared, plan, base, order.data, flags.data);
    const network: enhance.Network = .{
        .nodes = topo.nodes,
        .coordinates = topo.coordinates,
        .first_edge = topo.first_edge,
        .edges = topo.output.data,
        .classes = base,
        .walk_order = order.data,
        .aliases = aliases.data,
    };
    const workers = if (options.workers == 0) std.Thread.getCpuCount() catch 1 else options.workers;
    {
        const tile_order = try Scratch(u32).init(topo.nodes.len, options.scratch_dir);
        defer tile_order.deinit();
        var tiles = try enhance.TileIndex.init(gpa, topo.coordinates, tile_order.data, deadline);
        defer tiles.deinit(gpa);
        const active = tiles.active.items;
        const count = @max(1, @min(workers, max_workers, active.len));
        var jobs: [max_workers]NodeEnhanceJob = undefined;
        for (jobs[0..count], 0..) |*job, i| {
            job.* = .{
                .gpa = gpa,
                .network = network,
                .tiles = tiles,
                .active = active[active.len * i / count .. active.len * (i + 1) / count],
                .nodes = topo.nodes,
                .options = options,
            };
        }
        try runJobs(jobs[0..count]);
    }
    const count = @max(1, @min(workers, max_workers, (topo.nodes.len + 255) / 256));
    var jobs: [max_workers]EdgeEnhanceJob = undefined;
    for (jobs[0..count], 0..) |*job, i| {
        job.* = .{
            .gpa = gpa,
            .network = network,
            .flags = flags.data,
            .start = topo.nodes.len * i / count,
            .end = topo.nodes.len * (i + 1) / count,
            .deadline = deadline,
        };
    }
    try runJobs(jobs[0..count]);

    var interner = classes.Interner.init(gpa);
    defer interner.deinit();
    for (topo.nodes, 0..) |node, i| {
        try checkDeadline(deadline, i);
        const first = topo.first_edge[i];
        const end = topo.first_edge[i + 1];
        for (topo.output.data[first..end], flags.data[first..end]) |*edge, not_thru| {
            var class = base[edge.cls.class_id];
            const target = topo.nodes[edge.head];
            class.category.density = @intCast((@as(u8, node.attr.density) + target.attr.density) / 2);
            if (!class.flags.node_connector) {
                class.flags.not_thru = not_thru != 0;
                class.flags.dead_end = target.attr.intersection == .dead_end;
            }
            const interned = @backingInt(try interner.intern(class));
            edge.cls.class_id = std.math.cast(classes.ClassId, interned) orelse return error.TooManyClasses;
        }
    }
    var final = try interner.finish(deadline);
    errdefer final.deinit();
    try remapEdges(topo.output.data, final.remap, deadline);
    return final;
}

/// Valhalla visits outbound arcs by auto driveability, raw way class, names
/// and then segment encounter order. The expansion cap depends on that order,
/// so keep a separate ordering for the walk and preserve CSR local indices.
fn orderWalks(shared: *const Shared, plan: *const Layout, base: []const classes.EdgeClass, order: []u32, ranks: []u8) !void {
    const topo = shared.topology;
    const connector_rank = 32;
    for (plan.nodes.items, 0..) |node, i| {
        try checkDeadline(shared.deadline, i);
        const first = topo.first_edge[node.first_alias];
        const end = topo.first_edge[node.first_alias + aliasCount(node.degree)];
        var positions: [connector_rank + 1]u32 = @splat(0);
        for (topo.output.data[first..end], ranks[first..end], first..end) |edge, *rank, slot| {
            try checkDeadline(shared.deadline, slot - first);
            const class = base[edge.cls.class_id];
            if (class.flags.node_connector) {
                rank.* = connector_rank;
            } else {
                const segment = shared.segments[topo.slot_refs.data[slot] / 2];
                const way = shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
                rank.* = graph.constants.incidentEdgeRank(class.forwardAccess().auto, way.attr.importance, way.attr.has_names);
            }
            positions[rank.*] += 1;
        }
        var offset = first;
        for (&positions) |*position| {
            const count = position.*;
            position.* = offset;
            offset += count;
        }
        for (ranks[first..end], first..end) |rank, slot| {
            try checkDeadline(shared.deadline, slot - first);
            order[positions[rank]] = @intCast(slot);
            positions[rank] += 1;
        }
    }
}

const Terrain = struct {
    means: Scratch(i16),
    slopes: Scratch(u16),
    coverage: elevation.Coverage = .{ .dem_configured = true },

    fn deinit(self: *Terrain) void {
        self.slopes.deinit();
        self.means.deinit();
    }
};

const ElevationJob = struct {
    gpa: Allocator,
    shared: *const Shared,
    means: []i16,
    slopes: []u16,
    order: []const u32,
    source: elevation.Source,
    coverage: elevation.Coverage = .{},
    result: anyerror!void = {},

    fn run(self: *ElevationJob) void {
        self.result = self.sample();
    }

    fn sample(self: *ElevationJob) !void {
        switch (self.source) {
            .tiles => |dir| {
                // The loose tile cache may evict decoded buffers. Each job
                // owns its cache and keeps its current tile local.
                var tiles = try dem.hgt.Tiles.init(self.gpa, dir);
                defer tiles.deinit();
                var sampler: dem.hgt.Sampler = .{ .tiles = &tiles };
                try self.emit(&sampler);
            },
            .pack => |pack| {
                var sampler: dem.@"packed".Sampler = .{ .pack = pack };
                try self.emit(&sampler);
            },
        }
    }

    fn emit(self: *ElevationJob, sampler: anytype) !void {
        const shared = self.shared;
        const topo = shared.topology;
        var work: elevation.Work = .{ .allocator = self.gpa, .deadline = shared.deadline };
        defer work.deinit();
        for (self.order, 0..) |id, i| {
            try checkDeadline(shared.deadline, i);
            const segment = shared.segments[id];
            const way = shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
            const class = way.by_direction[0];
            const interpolate = class.flags.bridge or class.flags.tunnel or
                class.category.use == @backingInt(graph.constants.Use.ferry) or
                class.category.use == @backingInt(graph.constants.Use.rail_ferry);
            const first = topo.placements.data[2 * @as(usize, id)].slot;
            const length = topo.output.data[first].geom.len_m;
            const stamp = try work.measure(try segmentShape(shared.shape_points, segment), length, interpolate, sampler);
            self.means[id] = stamp.mean;
            for (stamp.directed, 0..) |direction, d| {
                const slot = topo.placements.data[2 * @as(usize, id) + d].slot;
                topo.output.data[slot].geom.grade = direction.grade;
                self.slopes[slot] = direction.slopes.code;
            }
            self.coverage.add(stamp);
        }
    }
};

fn stampElevation(gpa: Allocator, shared: *const Shared, scratch_dir: []const u8, requested: usize, source: elevation.Source) !Terrain {
    const means = try Scratch(i16).init(shared.segments.len, scratch_dir);
    errdefer means.deinit();
    const slopes = try Scratch(u16).init(shared.topology.output.data.len, scratch_dir);
    errdefer slopes.deinit();
    // Connector slots stay zero in the new scratch file.
    var output: Terrain = .{ .means = means, .slopes = slopes };
    if (shared.segments.len == 0) return output;

    const order = try Scratch(u32).init(shared.segments.len, scratch_dir);
    defer order.deinit();
    try orderByTile(gpa, shared, order.data);
    const workers = if (requested == 0) std.Thread.getCpuCount() catch 1 else requested;
    const count = @max(1, @min(workers, max_workers, (order.data.len + 255) / 256));
    var jobs: [max_workers]ElevationJob = undefined;
    const active = jobs[0..count];
    for (active, 0..) |*job, i| {
        job.* = .{
            .gpa = gpa,
            .shared = shared,
            .means = means.data,
            .slopes = slopes.data,
            .order = order.data[(order.data.len * i) / count .. (order.data.len * (i + 1)) / count],
            .source = source,
        };
    }
    try runJobs(active);
    for (active) |job| output.coverage.merge(job.coverage);
    return output;
}

fn orderByTile(gpa: Allocator, shared: *const Shared, order: []u32) !void {
    // The extra bucket keeps points outside the DEM grid at the end.
    const buckets = try gpa.alloc(u32, dem.hgt.tile_count + 2);
    defer gpa.free(buckets);
    @memset(buckets, 0);
    for (shared.segments, 0..) |segment, i| {
        try checkDeadline(shared.deadline, i);
        const first = (try segmentShape(shared.shape_points, segment))[0];
        const tile = elevation.tileKey(first);
        buckets[tile + 1] += 1;
    }
    for (1..buckets.len) |i| {
        try checkDeadline(shared.deadline, i);
        buckets[i] += buckets[i - 1];
    }
    for (shared.segments, 0..) |segment, i| {
        try checkDeadline(shared.deadline, i);
        const tile = elevation.tileKey(shared.shape_points[@intCast(segment.shape_offset)]);
        order[buckets[tile]] = @intCast(i);
        buckets[tile] += 1;
    }
}

fn remapEdges(rows: []format.EdgeHot, ids: []const classes.ClassId, deadline: io.Deadline) !void {
    for (rows, 0..) |*row, i| {
        try checkDeadline(deadline, i);
        row.cls.class_id = ids[row.cls.class_id];
    }
}

fn buildTurns(shared: *const Shared, edge_classes: []const classes.EdgeClass, name_ids: []const tags.names.Id, pool: *turns.Pool) !void {
    const topo = shared.topology;
    var approaches: [max_degree]turns.Approach = undefined;
    var entries: [turns.max_matrix_size]u8 = undefined;
    for (topo.nodes, 0..) |*node, i| {
        try checkDeadline(shared.deadline, i);
        const first = topo.first_edge[i];
        const degree = topo.first_edge[i + 1] - first;
        for (approaches[0..degree], topo.output.data[first..][0..degree], 0..) |*approach, edge, local| {
            const class = &edge_classes[edge.cls.class_id];
            approach.* = .{ .bearing = 0, .class = class, .names = &.{} };
            if (class.flags.node_connector) continue;
            const ref = topo.slot_refs.data[first + local];
            const segment = shared.segments[ref / 2];
            const way = shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
            approach.bearing = try turns.heading(try segmentShape(shared.shape_points, segment), ref & 1 == 0, class, shared.deadline);
            approach.names = name_ids[way.name_start..way.name_end];
        }
        const matrix = entries[0 .. degree * degree];
        const side: edge_class.DriveSide = if (node.attr.drive_on_left) .left else .right;
        try turns.matrix(approaches[0..degree], node.attr.signal != 0, side, matrix, shared.deadline);
        node.turn_off = try pool.intern(matrix);
    }
}

// Ported from src/mjolnir/osmway.cc GetTaggedValues. Level tags hold
// individual floors or inclusive ranges separated by semicolons.
fn appendLevels(out: *std.ArrayList(graph.cold.LevelRange), gpa: Allocator, source: []const u8, deadline: io.Deadline) !void {
    var tokens = std.mem.tokenizeScalar(u8, source, ';');
    while (tokens.next()) |raw| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const token = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (token.len == 0) continue;
        const split = if (token[0] == '-') null else std.mem.indexOfScalar(u8, token, '-');
        const first = std.fmt.parseFloat(f32, token[0 .. split orelse token.len]) catch continue;
        const last = if (split) |sep|
            std.fmt.parseFloat(f32, token[sep + 1 ..]) catch continue
        else
            first;
        if (std.math.isFinite(first) and std.math.isFinite(last) and first <= last)
            try out.append(gpa, .init(first, last));
    }
}

fn buildCold(gpa: Allocator, shared: *const Shared, metadata: *const Metadata, writer: *format.BundleWriter, scratch_dir: []const u8, means: []const i16) !u64 {
    const topo = shared.topology;
    const index = try Scratch(u32).init(topo.output.data.len, scratch_dir);
    defer index.deinit();
    var builder = try ColdBuilder.init(gpa, &metadata.strings, scratch_dir, shared.deadline);
    defer builder.deinit();
    var refs: [graph.cold.max_names]u32 = undefined;
    for (topo.nodes, 0..) |_, node| {
        try checkDeadline(shared.deadline, node);
        const first = topo.first_edge[node];
        const end = topo.first_edge[node + 1];
        for (topo.output.data[first..end], first..end) |edge, slot| {
            const opposite = topo.first_edge[edge.head] + edge.cls.opp_local;
            if (slot > opposite) continue;
            var reverse = false;
            const record = if (edge.cls.local < topo.groups[node].real_degree) blk: {
                const ref = topo.slot_refs.data[slot];
                const seg = shared.segments[ref / 2];
                const way = shared.ways.get(seg.way_id) orelse return error.MissingWayAttributes;
                const active = refs[0 .. way.name_end - way.name_start];
                for (active, way.name_start..way.name_end) |*name, i| {
                    name.* = try builder.nameRef(metadata.name_ids.items[i], i >= way.ref_start and i < way.ref_end);
                }
                reverse = ref & 1 != 0;
                const mean = if (means.len == 0) graph.cold.no_elevation else means[ref / 2];
                const indoor: graph.cold.Indoor = .{
                    .layer = way.attr.layer,
                    .levels = metadata.levels.items[way.level_start..][0..way.level_count],
                };
                break :blk try builder.append(@bitCast(seg.way_id), way.speeds.limit, mean, try segmentShape(shared.shape_points, seg), active, indoor);
            } else try builder.append(0, 0, graph.cold.no_elevation, &.{ topo.coordinates[node], topo.coordinates[edge.head] }, &.{}, .{});
            index.data[slot] = graph.cold.directedIndex(record, reverse);
            index.data[opposite] = graph.cold.directedIndex(record, !reverse);
        }
    }
    if (builder.record_count != topo.output.data.len / 2) return error.InvalidColdRecordCount;
    try writer.write(.cold_idx, index.data);
    return builder.write(writer);
}

const SpatialJob = struct {
    gpa: Allocator,
    shared: *const Shared,
    start: usize,
    end: usize,
    pairs: std.ArrayList(graph.spatial.Pair) = .empty,
    result: anyerror!void = {},

    fn run(self: *SpatialJob) void {
        self.result = self.emit();
    }

    fn emit(self: *SpatialJob) !void {
        const shared = self.shared;
        for (self.start..self.end) |i| {
            try checkDeadline(shared.deadline, i - self.start);
            const slots = shared.topology.placements.data[2 * i ..][0..2];
            const representative = @min(slots[0].slot, slots[1].slot);
            const shape = try segmentShape(shared.shape_points, shared.segments[i]);
            try graph.spatial.addShape(self.gpa, &self.pairs, representative, shape, shared.deadline);
        }
    }
};

fn buildSpatial(gpa: Allocator, shared: *const Shared, writer: *format.BundleWriter, scratch_dir: []const u8, requested: usize) !graph.spatial.Stats {
    const topo = shared.topology;
    const workers = if (requested == 0) std.Thread.getCpuCount() catch 1 else requested;
    const segments = shared.segments.len;
    const count = @max(1, @min(workers, max_workers, (segments + 255) / 256));
    var jobs: [max_workers]SpatialJob = undefined;
    const active = jobs[0..count];
    for (active, 0..) |*job, i| {
        job.* = .{ .gpa = gpa, .shared = shared, .start = segments * i / count, .end = segments * (i + 1) / count };
    }
    defer for (active) |*job| job.pairs.deinit(gpa);
    try runJobs(active);

    // Synthetic alias arcs share their endpoint coordinates. They have a
    // representative as well, so every stored shape has a spatial entry.
    for (topo.groups, 0..) |group, i| {
        try checkDeadline(shared.deadline, i);
        if (!group.has_right) continue;
        const slot = topo.first_edge[i + 1] - 1;
        try graph.spatial.addShape(gpa, &active[0].pairs, slot, &.{ topo.coordinates[i], topo.coordinates[i + 1] }, shared.deadline);
    }

    var total: usize = 0;
    for (active) |job| total = std.math.add(usize, total, job.pairs.items.len) catch return error.SpatialIndexTooLarge;
    const pairs = try Scratch(graph.spatial.Pair).init(total, scratch_dir);
    defer pairs.deinit();
    const scratch = try Scratch(graph.spatial.Pair).init(total, scratch_dir);
    defer scratch.deinit();
    var written: usize = 0;
    for (active) |*job| {
        var remaining = job.pairs.items;
        while (remaining.len != 0) {
            if (shared.deadline.expired()) return error.DeadlineExceeded;
            const n = @min(remaining.len, 64 * 1024);
            @memcpy(pairs.data[written..][0..n], remaining[0..n]);
            written += n;
            remaining = remaining[n..];
        }
        job.pairs.deinit(gpa);
        job.pairs = .empty;
    }
    return graph.spatial.write(gpa, pairs.data, scratch.data, scratch_dir, writer, shared.deadline);
}

fn checkDeadline(deadline: io.Deadline, index: usize) !void {
    if (index % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

fn segmentShape(points: []const geo.FixedLL, segment: edges.Edge) ![]const geo.FixedLL {
    if (segment.shape_count < 2 or segment.shape_offset > points.len or
        segment.shape_count > points.len - segment.shape_offset)
        return error.InvalidSegmentShape;
    return points[@intCast(segment.shape_offset)..][0..segment.shape_count];
}

fn encodeLength(length: f64) !u24 {
    if (!std.math.isFinite(length) or length < 0 or length > std.math.maxInt(u24))
        return error.InvalidEdgeLength;
    return @max(1, @as(u24, @intFromFloat(@round(length))));
}

fn computeCurvature(points: []const geo.FixedLL, deadline: io.Deadline) !u4 {
    var total: f32 = 0;
    var count: usize = 0;
    for (2..points.len) |i| {
        try checkDeadline(deadline, i - 2);
        const radius: f32 = @floatCast(points[i - 2].toPoint().curvature(points[i - 1].toPoint(), points[i].toPoint()));
        if (std.math.isNan(radius)) continue;
        total += if (radius > 1000) 0 else @min(25, 1500 / radius);
        count += 1;
    }
    if (count == 0) return 0;
    return @intFromFloat(@min(15, total / @as(f32, @floatFromInt(count))));
}

/// Validate the CSR, class IDs, and the complete opposing-edge involution.
pub fn validate(
    first_edge: []const u32,
    directed: []const format.EdgeHot,
    coords: []const format.Coordinate,
    attributes: []const classes.EdgeClass,
    deadline: io.Deadline,
) !void {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (first_edge.len == 0 or first_edge.len - 1 != coords.len or
        first_edge[0] != 0 or first_edge[first_edge.len - 1] != directed.len)
        return error.InvalidCsrEndpoints;
    for (attributes, 0..) |class, i| {
        try checkDeadline(deadline, i);
        if (!class.valid()) return error.InvalidEdgeClass;
    }
    for (0..coords.len) |node| {
        try checkDeadline(deadline, node);
        const start = first_edge[node];
        const end = first_edge[node + 1];
        if (start >= end or end > directed.len or end - start > max_degree) return error.InvalidCsrRange;
        for (directed[start..end], 0..) |row, local| {
            if (row.head >= coords.len or row.head == node or row.cls.local != local)
                return error.InvalidDirectedEdge;
            if (row.cls.class_id >= attributes.len) return error.InvalidClassId;
            const connector = attributes[row.cls.class_id].flags.node_connector;
            if ((row.geom.len_m == 0) != connector) return error.InvalidEdgeLength;
            if (connector and !std.meta.eql(coords[node], coords[row.head])) return error.InvalidConnector;
            const opposite_start = first_edge[row.head];
            const opposite_end = first_edge[row.head + 1];
            if (opposite_start >= opposite_end or opposite_end > directed.len or
                row.cls.opp_local >= opposite_end - opposite_start)
                return error.InvalidOpposingEdge;
            const reverse = directed[opposite_start + row.cls.opp_local];
            if (reverse.head != node or reverse.cls.opp_local != local or reverse.cls.local != row.cls.opp_local or
                reverse.geom.len_m != row.geom.len_m)
                return error.InvalidOpposingEdge;
        }
    }
}

test "real edge lengths round to metres and reserve zero for connectors" {
    try std.testing.expectEqual(1, try encodeLength(0));
    try std.testing.expectEqual(1, try encodeLength(0.49));
    try std.testing.expectEqual(2, try encodeLength(1.5));
    try std.testing.expectError(error.InvalidEdgeLength, encodeLength(-1));
    try std.testing.expectError(error.InvalidEdgeLength, encodeLength(std.math.nan(f64)));
    try std.testing.expectError(error.InvalidEdgeLength, encodeLength(1 << 24));
}
