// Ported from src/mjolnir/graphbuilder.cc, src/mjolnir/util.cc and src/mjolnir/graphvalidator.cc
// (Valhalla 3.9.3). Assemble the native dense CSR topology.
const std = @import("std");
const geo = @import("../geo/point.zig");
const math = @import("../geo/build_math.zig");
const io = @import("../infra/io.zig");
const graph = @import("../graph/root.zig");
const format = graph.format;
const classes = graph.class_table;
const edges = @import("edges.zig");
const tags = @import("tags/root.zig");
const pbf = @import("pbf/root.zig");
const edge_class = @import("edge_class.zig");
const turns = @import("turns.zig");
const cold_builder = @import("cold_builder.zig");
const ColdBuilder = cold_builder.Builder;
const elevation = @import("elevation.zig");
const dem = @import("../elevation/root.zig");
const enhance = @import("enhance.zig");
const speeds = @import("speeds.zig");
const components = @import("components.zig");
const checkpoint = @import("checkpoint.zig");
const node_order = @import("order.zig");
const admin_index = @import("admin_index.zig");
const country_access = @import("country_access.zig");
const timezones = @import("timezones.zig");
const turn_restrictions = @import("turn_restrictions.zig");
const mode_turns = @import("../graph/turn_restrictions.zig");
const automaton = @import("../graph/restriction_automaton.zig");
const automaton_builder = @import("restriction_automaton.zig");
const conditional_access = @import("conditional_access.zig");
const sign_build = @import("signs.zig");
const lane_build = @import("lanes.zig");
const name_details = @import("name_details.zig");
const link_classification = @import("link_classification.zig");
const grid = @import("../geo/grid.zig");

const Allocator = std.mem.Allocator;
const max_degree = turns.max_degree;
const max_workers = 16;

pub const Options = struct {
    scratch_dir: []const u8,
    drive_side: ?edge_class.DriveSide = null,
    workers: usize = 0,
    include_construction: bool = false,
    include_platforms: bool = false,
    dem_source: ?elevation.Source = null,
    admin_drive_side: ?enhance.AdminDriveSide = null,
    admin_index: ?graph.admin.View = null,
    use_admin_db: bool = true,
    allow_alt_name: bool = false,
    use_direction_on_ways: bool = false,
    apply_country_overrides: bool = true,
    timezone_source: ?timezones.Source = null,
    speed_rules: ?*const speeds.Config = null,
    reclassify_links: bool = true,
    infer_turn_channels: bool = true,
    infer_internal_intersections: bool = true,
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
    simple_turns: turn_restrictions.Stats,
};

/// Build the topology, validate it, and write it to the caller's staging
/// bundle. The caller commits the writer after all build stages succeed.
/// Parallel builds require an allocator and admin resolver that support concurrent use.
pub fn build(gpa: Allocator, source: pbf.file.Stream, writer: *format.BundleWriter, supplied: Options) !Stats {
    var options = supplied;
    if (!options.use_admin_db) options.admin_index = null;
    var restrictions: turn_restrictions.Catalog = .{ .a = gpa, .deadline = options.deadline };
    defer restrictions.deinit();
    var metadata = Metadata.init(gpa, options);
    defer metadata.deinit();
    var compiled_admins = try admin_index.build(gpa, source, options.deadline, options.use_admin_db and options.admin_index == null, &restrictions, &metadata.lanes);
    defer if (compiled_admins) |*index| index.deinit();
    if (compiled_admins) |index| options.admin_index = index.view;
    try metadata.lanes.prepare();
    const edge_file = try io.File.temporary(options.scratch_dir);
    defer edge_file.close();
    const shape_file = try io.File.temporary(options.scratch_dir);
    defer shape_file.close();

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
    var admin_ids = try assignAdmins(topology.coordinates, options);
    defer if (admin_ids) |*ids| ids.deinit();
    const country_table = try country_access.compile(gpa, options.admin_index, options.deadline);
    defer gpa.free(country_table);
    const shared: Shared = .{
        .topology = &topology,
        .segments = segments,
        .shape_points = shape_points,
        .ways = &metadata.ways,
        .metadata = &metadata,
        .admin_ids = if (admin_ids) |ids| ids.data else null,
        .admin_index = options.admin_index,
        .countries = country_table,
        .apply_country_overrides = options.apply_country_overrides,
        .deadline = options.deadline,
    };
    var restriction_program: automaton_builder.Program = .{};
    defer restriction_program.deinit(gpa);
    var lane_output: lane_build.Output = .{ .a = gpa };
    defer lane_output.deinit();
    var table = blk: {
        var base = try populate(gpa, &shared, &plan, options);
        defer base.deinit();
        try validate(topology.first_edge, topology.output.data, topology.coordinates, base.classes, options.deadline);
        break :blk try enhanceGraph(gpa, &shared, &plan, base.classes, options, restrictions.source(), &restriction_program, &lane_output);
    };
    defer table.deinit();
    var terrain = if (options.dem_source) |source_dem|
        try stampElevation(gpa, &shared, options.scratch_dir, options.workers, source_dem)
    else
        null;
    defer if (terrain) |*present| present.deinit();
    var turn_pool = turns.Pool.init(gpa);
    defer turn_pool.deinit();
    var resolved = try resolveTurns(gpa, &shared, &plan, table.classes, restrictions.source(), null);
    defer resolved.deinit(gpa);
    const headings = try Scratch(u8).init(topology.output.data.len, options.scratch_dir);
    defer headings.deinit();
    const turn_sides = try buildTurns(&shared, table.classes, &metadata, resolved.hard.items, &turn_pool, headings.data, gpa);
    defer gpa.free(turn_sides);

    try writeTopology(writer, options.scratch_dir, &topology, table.classes, turn_pool.bytes.items, if (terrain) |present| present.slopes.data else null);
    try writer.write(.turn_sides, turn_sides);
    try writer.write(.headings, headings.data);
    try lane_output.write(writer);
    if (resolved.modes.items.len != 0) try writer.write(.turn_restrictions, resolved.modes.items);
    if (restriction_program.states.len != 0) try writer.write(.restriction_automaton, restriction_program.states);
    if (restriction_program.conditions.len != 0) try writer.write(.restriction_conditions, restriction_program.conditions);
    try writeAdmins(writer, options.admin_index, shared.admin_ids);
    if (options.timezone_source) |source_tz| try writeTimezones(gpa, writer, source_tz, topology.coordinates, options.scratch_dir);
    const topology_ns = timer.read();
    const means: []const i16 = if (terrain) |*present| present.means.data else &.{};
    const cold_bytes = try buildCold(gpa, &shared, &metadata, &plan, table.classes, writer, options.scratch_dir, means);
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
        .simple_turns = resolved.stats,
    };
}

/// Run the graph stages against the segment files. The same algorithms and
/// section writers are used by build() for ephemeral callers.
pub fn buildStaged(
    session: *checkpoint.Session,
    metadata: *Metadata,
    source_stats: edges.Stats,
    edge_file: io.File,
    shape_file: io.File,
    options: Options,
    restrictions: turn_restrictions.Source,
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
        break :blk try Layout.load(gpa, &saved, options.deadline);
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
    var admin_ids = if (session.runs(.assemble) or session.runs(.enhance) or session.runs(.turns) or session.runs(.cold))
        try assignAdmins(topology.coordinates, options)
    else
        null;
    defer if (admin_ids) |*ids| ids.deinit();
    const country_table = if (session.runs(.assemble) or session.runs(.turns)) try country_access.compile(gpa, options.admin_index, options.deadline) else &.{};
    defer gpa.free(country_table);
    const shared: Shared = .{
        .topology = &topology,
        .segments = segments,
        .shape_points = points,
        .ways = &metadata.ways,
        .metadata = metadata,
        .admin_ids = if (admin_ids) |ids| ids.data else null,
        .admin_index = options.admin_index,
        .countries = country_table,
        .apply_country_overrides = options.apply_country_overrides,
        .deadline = options.deadline,
    };
    var edge_classes: ?[]const classes.EdgeClass = null;
    defer if (edge_classes) |owned| gpa.free(owned);
    if (session.runs(.assemble)) {
        var tx = try session.begin(.assemble);
        defer tx.deinit();
        const table = try populate(gpa, &shared, &plan, options);
        gpa.free(table.remap);
        edge_classes = table.classes;
        try validate(topology.first_edge, topology.output.data, topology.coordinates, table.classes, options.deadline);
        try topology.savePlacement(&tx);
        try saveAttributes(&topology, table.classes, &tx);
        try session.commit(&tx, topology.output.data.len, assembly_start);
    }
    if (session.endsAt(.assemble)) return;

    if (edge_classes == null) {
        const source: checkpoint.Stage = if (session.runs(.enhance)) .assemble else .enhance;
        const saved = try session.open(source);
        defer saved.close();
        edge_classes = try loadArray(classes.EdgeClass, gpa, &saved, .classes, options.deadline);
        try validate(topology.first_edge, topology.output.data, topology.coordinates, edge_classes.?, options.deadline);
    }
    if (session.runs(.enhance)) {
        const start = io.Timer.start();
        var tx = try session.begin(.enhance);
        defer tx.deinit();
        var restriction_program: automaton_builder.Program = .{};
        defer restriction_program.deinit(gpa);
        var lane_output: lane_build.Output = .{ .a = gpa };
        defer lane_output.deinit();
        const enhanced = try enhanceGraph(gpa, &shared, &plan, edge_classes.?, options, restrictions, &restriction_program, &lane_output);
        gpa.free(enhanced.remap);
        gpa.free(edge_classes.?);
        edge_classes = enhanced.classes;
        try saveAttributes(&topology, enhanced.classes, &tx);
        if (restriction_program.states.len != 0) try tx.writeArray(restriction_program.states, .restriction_states);
        if (restriction_program.conditions.len != 0) try tx.writeArray(restriction_program.conditions, .restriction_conditions);
        if (lane_output.entries.items.len != 0 or lane_output.connections.items.len != 0) {
            var writer = try stageWriter(session, &tx);
            defer writer.deinit();
            try lane_output.write(&writer);
            try tx.saveSections(&writer);
        }
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
        var resolved = try resolveTurns(gpa, &shared, &plan, edge_classes.?, restrictions, null);
        defer resolved.deinit(gpa);
        const headings = try Scratch(u8).init(topology.output.data.len, options.scratch_dir);
        defer headings.deinit();
        const turn_sides = try buildTurns(&shared, edge_classes.?, metadata, resolved.hard.items, &turn_pool, headings.data, gpa);
        defer gpa.free(turn_sides);
        try tx.writeArray(topology.nodes, .nodes);
        try tx.writeArray(turn_pool.bytes.items, .turn_pool);
        try tx.writeArray(turn_sides, .turn_sides);
        try tx.writeArray(headings.data, .headings);
        if (resolved.modes.items.len != 0) try tx.writeArray(resolved.modes.items, .mode_turns);
        if (resolved.stats.parsed != 0) try tx.writeJson(gpa, resolved.stats, .simple_turn_stats);
        try tx.writeJson(gpa, turn_pool.indices.count(), .turn_stats);
        try session.commit(&tx, topology.nodes.len, start);
    }
    if (session.endsAt(.turns)) return;

    if (session.runs(.cold)) try saveColdStage(session, &shared, metadata, &plan, edge_classes.?, &options);
    if (session.endsAt(.cold)) return;

    if (session.runs(.spatial)) {
        const start = io.Timer.start();
        var tx = try session.begin(.spatial);
        defer tx.deinit();
        var writer = try stageWriter(session, &tx);
        defer writer.deinit();
        const spatial = try buildSpatial(gpa, &shared, &writer, options.scratch_dir, options.workers);
        try tx.writeJson(gpa, spatial, .spatial_stats);
        try tx.saveSections(&writer);
        try session.commit(&tx, spatial.cells, start);
    }
}

// Each section is copied into the stage's own transaction before publishing it.
noinline fn saveColdStage(session: *checkpoint.Session, shared: *const Shared, metadata: *Metadata, plan: *const Layout, edge_classes: []const classes.EdgeClass, options: *const Options) !void {
    const gpa = session.gpa;
    const start = io.Timer.start();
    var tx = try session.begin(.cold);
    defer tx.deinit();
    var writer = try stageWriter(session, &tx);
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
    if (means.len != 0 and means.len != shared.segments.len) return error.InvalidCheckpoint;
    const slopes = if (slopes_map) |mapped| try checkpoint.array(u16, mapped) else null;
    try writeTopology(&writer, options.scratch_dir, shared.topology, edge_classes, turn_data.bytes, slopes);
    try writeAdmins(&writer, options.admin_index, shared.admin_ids);
    if (options.timezone_source) |source| try writeTimezones(gpa, &writer, source, shared.topology.coordinates, options.scratch_dir);
    if (saved_turns.manifest.files.get(.turn_sides) != null) {
        const side_data = try saved_turns.map(.turn_sides, options.deadline);
        defer side_data.unmap();
        try writer.write(.turn_sides, try checkpoint.array(u32, side_data));
    }
    if (saved_turns.manifest.files.get(.headings) != null) {
        const headings = try saved_turns.map(.headings, options.deadline);
        defer headings.unmap();
        if (headings.bytes.len != shared.topology.output.data.len) return error.InvalidCheckpoint;
        try writer.write(.headings, headings.bytes);
    }
    if (saved_turns.manifest.files.get(.mode_turns) != null) {
        const rows = try saved_turns.map(.mode_turns, options.deadline);
        defer rows.unmap();
        try writer.write(.turn_restrictions, try checkpoint.array(mode_turns.Entry, rows));
    }
    const enhancement = try session.open(.enhance);
    defer enhancement.close();
    if (enhancement.manifest.files.get(.restriction_states) != null) {
        const rows = try enhancement.map(.restriction_states, options.deadline);
        defer rows.unmap();
        try writer.write(.restriction_automaton, try checkpoint.array(automaton.State, rows));
    }
    if (enhancement.manifest.files.get(.restriction_conditions) != null) {
        const rows = try enhancement.map(.restriction_conditions, options.deadline);
        defer rows.unmap();
        try writer.write(.restriction_conditions, try checkpoint.array(automaton.Condition, rows));
    }
    const cold_bytes = try buildCold(gpa, shared, metadata, plan, edge_classes, &writer, options.scratch_dir, means);
    try tx.writeJson(gpa, cold_bytes, .source_stats);
    try writer.write(.metadata, &.{.{
        .ordering_kind = @backingInt(options.ordering.kind),
        .order_hash = plan.order_hash,
    }});
    try tx.saveSections(&writer);
    try session.commit(&tx, shared.topology.output.data.len / 2, start);
}

noinline fn saveAttributes(topology: *const Topology, edge_classes: []const classes.EdgeClass, tx: *checkpoint.Transaction) !void {
    try tx.writeArray(topology.nodes, .nodes);
    try tx.writeArray(topology.output.data, .directed_edges);
    try tx.writeArray(edge_classes, .classes);
}

fn writeTopology(writer: *format.BundleWriter, scratch_dir: []const u8, topology: *const Topology, edge_classes: []const classes.EdgeClass, turn_data: []const u8, slopes: ?[]const u16) !void {
    try writer.write(.nodes, topology.nodes);
    try writer.write(.edges, topology.output.data);
    try graph.speed.writeBounds(writer, topology.output.data);
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

pub noinline fn stageWriter(session: *const checkpoint.Session, tx: *const checkpoint.Transaction) !format.BundleWriter {
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
        ferry_duration: bool = false,
        access_tags: u11 = 0,
        motorroad: bool = false,
        access_tags_known: bool = false,
        primary_name: bool = false,
        drive_on_left: bool = false,
        reserved: u3 = 0,
    },
    level_start: u32,
    level_count: u32,
    name_start: u32,
    names: packed struct(u32) {
        count: u8,
        ref_start: u8,
        ref_count: u8,
        reserved: u8 = 0,
    },
    name_tags: name_details.Range,

    fn primaryNameOffset(self: Way) usize {
        return self.name_start + @as(usize, if (self.names.ref_start == 0) self.names.ref_count else 0);
    }

    fn nameRange(self: Way, ids: []const tags.names.Id) []const tags.names.Id {
        return ids[self.name_start..][0..self.names.count];
    }
};

const WayEntry = extern struct {
    id: i64,
    way: Way,
};

const NodeEntry = extern struct {
    id: i64,
    hot: format.NodeHot,
};

const access_restriction = graph.cold.access_restriction;
const LimitEntry = extern struct {
    way_id: i64,
    limit: access_restriction.Entry,
};

comptime {
    std.debug.assert(@sizeOf(Way) == 72);
    std.debug.assert(@offsetOf(Way, "by_direction") == 0 and @offsetOf(Way, "speeds") == 40 and @offsetOf(Way, "attr") == 44);
    std.debug.assert(@offsetOf(Way, "level_start") == 48 and @offsetOf(Way, "name_start") == 56 and
        @offsetOf(Way, "names") == 60 and @offsetOf(Way, "name_tags") == 64);
    std.debug.assert(@sizeOf(WayEntry) == 80 and @offsetOf(WayEntry, "way") == 8);
    std.debug.assert(@sizeOf(NodeEntry) == 16 and @offsetOf(NodeEntry, "hot") == 8);
    std.debug.assert(@sizeOf(LimitEntry) == 24 and @offsetOf(LimitEntry, "way_id") == 0 and @offsetOf(LimitEntry, "limit") == 8);
}

const Ways = std.AutoHashMapUnmanaged(i64, Way);
pub const Metadata = struct {
    gpa: Allocator,
    drive_side: ?edge_class.DriveSide,
    use_admin_db: bool,
    deadline: io.Deadline,
    strings: tags.names.StringTable,
    name_ids: std.ArrayList(tags.names.Id) = .empty,
    levels: std.ArrayList(graph.cold.LevelRange) = .empty,
    nodes: std.AutoHashMapUnmanaged(i64, format.NodeHot) = .empty,
    controls: std.AutoHashMapUnmanaged(i64, enhance.NodeControls) = .empty,
    ways: Ways = .empty,
    access_limits: std.AutoHashMapUnmanaged(i64, std.ArrayList(access_restriction.Entry)) = .empty,
    access_scratch: std.ArrayList(access_restriction.Entry) = .empty,
    conditional: conditional_access.Parser,
    infer_turn_channels: bool,
    infer_internal_intersections: bool,
    signs: sign_build.Catalog,
    lanes: lane_build.Catalog,
    name_tags: name_details.Catalog,
    name_options: tags.names.Options,

    pub fn init(gpa: Allocator, options: Options) Metadata {
        return .{
            .gpa = gpa,
            .drive_side = options.drive_side,
            .use_admin_db = options.use_admin_db,
            .deadline = options.deadline,
            .strings = .init(gpa),
            .conditional = .init(gpa, options.deadline),
            .infer_turn_channels = options.infer_turn_channels,
            .infer_internal_intersections = options.infer_internal_intersections,
            .signs = .{ .arena = .init(gpa) },
            .lanes = .{ .a = gpa, .deadline = options.deadline },
            .name_tags = .{ .a = gpa, .deadline = options.deadline },
            .name_options = .{
                .use_admin_db = options.use_admin_db,
                .allow_alt_name = options.allow_alt_name,
                .use_direction_on_ways = options.use_direction_on_ways,
                .capture_details = true,
            },
        };
    }

    pub fn saveNodes(self: *const Metadata, tx: *checkpoint.Transaction) !void {
        try self.signs.saveNodes(tx);
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

    pub fn loadNodes(self: *Metadata, saved: *const checkpoint.Existing) !void {
        try self.loadNodeSigns(saved);
        const mapped = try saved.map(.node_attributes, self.deadline);
        defer mapped.unmap();
        for (try checkpoint.array(NodeEntry, mapped), 0..) |entry, i| {
            try checkDeadline(self.deadline, i);
            try self.nodes.put(self.gpa, entry.id, entry.hot);
        }
        if (saved.manifest.files.get(.controls) != null) {
            const controls = try saved.map(.controls, self.deadline);
            defer controls.unmap();
            for (try checkpoint.array(edges.ControlEntry, controls), 0..) |entry, i| {
                try checkDeadline(self.deadline, i);
                if (entry.reserved != 0 or entry.padding != 0) return error.InvalidCheckpoint;
                try self.storeControls(entry.id, @bitCast(entry.flags));
            }
        }
    }

    pub fn loadNodeSigns(self: *Metadata, saved: *const checkpoint.Existing) !void {
        try self.signs.loadNodes(self.gpa, saved, self.deadline);
    }

    pub fn saveWays(self: *const Metadata, tx: *checkpoint.Transaction) !void {
        try self.signs.saveWays(tx);
        try self.lanes.saveWays(tx);
        try self.name_tags.save(tx);
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
        if (self.access_limits.count() != 0) try self.saveAccessLimits(tx);
    }

    fn saveAccessLimits(self: *const Metadata, tx: *checkpoint.Transaction) !void {
        const file = try tx.create(.motor_limits);
        defer file.close();
        var rows: [256]LimitEntry = undefined;
        var count: usize = 0;
        var offset: u64 = 0;
        var iter = self.access_limits.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |limit| {
                rows[count] = .{ .way_id = entry.key_ptr.*, .limit = limit };
                count += 1;
                if (count != rows.len) continue;
                if (self.deadline.expired()) return error.DeadlineExceeded;
                try file.pwriteAll(std.mem.asBytes(&rows), offset);
                offset += @sizeOf(@TypeOf(rows));
                count = 0;
            }
        }
        try file.pwriteAll(std.mem.sliceAsBytes(rows[0..count]), offset);
        try file.sync();
    }

    pub fn loadWays(self: *Metadata, saved: *const checkpoint.Existing) !void {
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
        try self.signs.loadWays(self.gpa, saved, &self.strings, self.deadline);
        try self.lanes.loadWays(saved, &self.strings);
        try self.name_tags.load(saved, &self.strings);
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
            const end = @as(usize, attrs.name_start) + attrs.names.count;
            if (attrs.names.reserved != 0 or end > self.name_ids.items.len or
                @as(u16, attrs.names.ref_start) + attrs.names.ref_count > attrs.names.count or
                (attrs.attr.primary_name and attrs.primaryNameOffset() >= end) or
                attrs.name_tags.first > attrs.name_tags.end or attrs.name_tags.end > self.name_tags.rows.items.len or
                attrs.level_start > self.levels.items.len or attrs.level_count > self.levels.items.len - attrs.level_start)
                return error.InvalidCheckpoint;
            try self.ways.put(self.gpa, entry.id, attrs);
        }
        if (saved.manifest.files.get(.motor_limits) != null) {
            const limits = try saved.map(.motor_limits, self.deadline);
            defer limits.unmap();
            for (try checkpoint.array(LimitEntry, limits), 0..) |entry, i| {
                try checkDeadline(self.deadline, i);
                if (!entry.limit.valid() or !self.ways.contains(entry.way_id)) return error.InvalidCheckpoint;
                const set = try self.access_limits.getOrPutValue(self.gpa, entry.way_id, .empty);
                try set.value_ptr.append(self.gpa, entry.limit);
            }
        }
        var iter = self.ways.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            try checkDeadline(self.deadline, i);
            const limits = if (self.access_limits.get(entry.key_ptr.*)) |set| set.items else &.{};
            const masks = try accessMasks(limits, self.deadline);
            for (entry.value_ptr.by_direction, masks) |class, modes| {
                if (class.detail.access_restriction != modes) return error.InvalidCheckpoint;
            }
        }
    }

    pub fn deinit(self: *Metadata) void {
        self.nodes.deinit(self.gpa);
        self.controls.deinit(self.gpa);
        self.ways.deinit(self.gpa);
        var sets = self.access_limits.valueIterator();
        while (sets.next()) |set| set.deinit(self.gpa);
        self.access_limits.deinit(self.gpa);
        self.access_scratch.deinit(self.gpa);
        self.conditional.deinit();
        self.signs.deinit(self.gpa);
        self.lanes.deinit();
        self.name_tags.deinit();
        self.name_ids.deinit(self.gpa);
        self.levels.deinit(self.gpa);
        self.strings.deinit();
    }

    pub fn node(self: *Metadata, id: i64, attrs: tags.NodeAttrs) !void {
        try self.storeControls(id, attrs.flags);
        try self.signs.addNode(self.gpa, id, attrs);
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

    fn storeControls(self: *Metadata, id: i64, flags: tags.NodeAttrs.Flags) !void {
        const sign = flags.stop_sign != flags.yield_sign;
        if (sign or flags.minor) try self.controls.put(self.gpa, id, .{
            .stop = sign and flags.stop_sign,
            .yield = sign and flags.yield_sign,
            .minor = flags.minor,
        });
    }

    pub fn way(self: *Metadata, id: i64, attrs: tags.WayAttrs, raw_tags: pbf.block.TagIterator) !void {
        const use = attrs.edgeUse();
        const directed_use = if (!self.infer_turn_channels and attrs.flags.turn_channel and !attrs.flags.link and attrs.use != .construction)
            .turn_channel
        else if (attrs.flags.link and attrs.use != .service_area and attrs.use != .rest_area and attrs.use != .construction)
            .ramp
        else
            use;

        var pair = [2]classes.EdgeClass{
            try edge_class.fromWay(attrs, true, .right),
            try edge_class.fromWay(attrs, false, .right),
        };
        const raw_flags = try self.rawWayFlags(raw_tags);
        for (&pair) |*class| {
            class.category.use = @intCast(@backingInt(directed_use));
            class.flags.internal = directed_use != .ramp and directed_use != .turn_channel and
                (class.flags.internal or raw_flags.internal);
        }
        const entry = try self.ways.getOrPut(self.gpa, id);
        if (entry.found_existing) return error.DuplicateWay;
        const access_masks = try self.wayAccess(id, &attrs.motor_limits, raw_tags);
        for (&pair, access_masks) |*class, modes| class.detail.access_restriction = modes;
        const indexed = try self.strings.indexWay(attrs, raw_tags, self.name_options, self.deadline);
        try self.signs.addWay(self.gpa, id, indexed);
        try self.lanes.addWay(id, indexed.turn_lanes_forward, indexed.turn_lanes_backward);
        const name_tags = try self.name_tags.addWay(&self.strings, &indexed);
        const name_start = try self.nameOffset();
        const ref_first = attrs.road_class == .motorway or attrs.road_class == .trunk;
        if (!ref_first) try self.appendNames(indexed.name.text);
        const ref_start = try self.nameOffset();
        try self.appendNames(indexed.ref.text);
        const ref_end = try self.nameOffset();
        if (ref_first) try self.appendNames(indexed.name.text);
        const primary_name = self.name_ids.items.len - name_start > ref_end - ref_start;
        if (indexed.alt_name.text != indexed.name.text) try self.appendNames(indexed.alt_name.text);
        if (indexed.official_name.text != indexed.name.text and indexed.official_name.text != indexed.alt_name.text)
            try self.appendNames(indexed.official_name.text);
        const name_end = @min(try self.nameOffset(), name_start +| graph.cold.max_names);
        self.name_ids.shrinkRetainingCapacity(name_end);
        const name_count: u8 = @intCast(name_end - name_start);
        const ref_offset: u8 = @intCast(@min(name_end, ref_start) - name_start);
        const ref_count: u8 = @intCast(@min(name_end, ref_end) - @min(name_end, ref_start));
        const level_start = std.math.cast(u32, self.levels.items.len) orelse return error.TooManyLevels;
        if (attrs.level) |level| try appendLevels(&self.levels, self.gpa, level, self.deadline);
        entry.value_ptr.* = .{
            .by_direction = pair,
            .speeds = .{
                .forward = attrs.ferry_speed orelse if (attrs.flags.forward_tagged_speed) attrs.forward_speed else attrs.speed,
                .backward = attrs.ferry_speed orelse if (attrs.flags.backward_tagged_speed) attrs.backward_speed else attrs.speed,
                .truck = attrs.truck_speed,
                .limit = attrs.speed_limit,
            },
            .attr = .{
                .oneway = attrs.flags.oneway,
                .ferry_duration = attrs.ferry_speed != null,
                .access_tags = @truncate(@as(u16, @bitCast(attrs.access_tags))),
                .motorroad = attrs.flags.motorroad,
                .access_tags_known = true,
                .importance = @intCast(@backingInt(attrs.road_class)),
                .has_names = name_start != name_end,
                .primary_name = primary_name and (!ref_first or ref_count < name_count),
                .drive_on_left = raw_flags.drive_on_left,
                .layer = attrs.layer,
            },
            .level_start = level_start,
            .level_count = std.math.cast(u32, self.levels.items.len - level_start) orelse return error.TooManyLevels,
            .name_start = name_start,
            .names = .{ .count = name_count, .ref_start = ref_offset, .ref_count = ref_count },
            .name_tags = name_tags,
        };
    }

    const RawWayFlags = struct { drive_on_left: bool = false, internal: bool = false };

    // Ported from ParseWays' driving_side and internal_intersection handlers.
    noinline fn rawWayFlags(self: *const Metadata, raw_tags: pbf.block.TagIterator) !RawWayFlags {
        if (self.use_admin_db and self.infer_internal_intersections) return .{};
        var flags: RawWayFlags = .{
            .drive_on_left = !self.use_admin_db and self.drive_side == .left,
        };
        var tags_at_way = raw_tags;
        while (try tags_at_way.next()) |tag| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (!self.use_admin_db and std.mem.eql(u8, tag.key, "driving_side")) {
                flags.drive_on_left = !std.mem.eql(u8, tag.value, "right");
            } else if (!self.infer_internal_intersections and std.mem.eql(u8, tag.key, "internal_intersection")) {
                flags.internal = std.mem.eql(u8, tag.value, "true");
            }
        }
        return flags;
    }

    noinline fn wayAccess(self: *Metadata, id: i64, unconditional: *const access_restriction.Set, raw_tags: pbf.block.TagIterator) ![2]u16 {
        const scratch = &self.access_scratch;
        scratch.clearRetainingCapacity();
        try scratch.appendSlice(self.gpa, unconditional.entries());
        try self.conditional.append(raw_tags, scratch);
        if (scratch.items.len == 0) return .{ 0, 0 };
        const masks = try accessMasks(scratch.items, self.deadline);
        if (scratch.items.len > unconditional.len) std.sort.heap(access_restriction.Entry, scratch.items, {}, access_restriction.Entry.before);
        const owned = try self.gpa.dupe(access_restriction.Entry, scratch.items);
        errdefer self.gpa.free(owned);
        try self.access_limits.put(self.gpa, id, .fromOwnedSlice(owned));
        return masks;
    }

    fn accessMasks(limits: []const access_restriction.Entry, deadline: io.Deadline) ![2]u16 {
        var modes: [2]u16 = @splat(0);
        for (limits, 0..) |limit, i| {
            try checkDeadline(deadline, i);
            if (limit.applies(true)) modes[0] |= limit.modes();
            if (limit.applies(false)) modes[1] |= limit.modes();
        }
        return modes;
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
    controls: enhance.NodeControls = .{},
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

    fn load(gpa: Allocator, saved: *const checkpoint.Existing, deadline: io.Deadline) !Layout {
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
            if (node.controls.reserved != 0 or (node.controls.stop and node.controls.yield) or
                node.placed != 0 or node.degree == 0 or node.first_alias != total) return error.InvalidCheckpoint;
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
            try self.nodes.append(gpa, .{
                .osm_id = id,
                .point = point,
                .hot = metadata.nodes.get(id) orelse neutral_node,
                .controls = metadata.controls.get(id) orelse .{},
            });
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
    std.debug.assert(@offsetOf(Node, "degree") == 24 and @offsetOf(Node, "controls") == 36);
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

        fn load(saved: *const checkpoint.Existing, key: checkpoint.Artifact, options: Options) !@This() {
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

        const nodes = try loadArray(format.NodeHot, gpa, &nodes_source, .nodes, options.deadline);
        errdefer gpa.free(nodes);
        const coordinates = try loadArray(format.Coordinate, gpa, &base, .coordinates, options.deadline);
        errdefer gpa.free(coordinates);
        const groups = try loadArray(Group, gpa, &base, .groups, options.deadline);
        errdefer gpa.free(groups);
        const first_edge = try loadArray(u32, gpa, &base, .first_edge, options.deadline);
        errdefer gpa.free(first_edge);
        const slot_refs = try Scratch(u32).load(&base, .slot_refs, options);
        errdefer slot_refs.deinit();
        const placements = try Scratch(Placement).load(&base, .placements, options);
        errdefer placements.deinit();
        const output = try Scratch(format.EdgeHot).load(&edges_source, .directed_edges, options);
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

fn loadArray(comptime T: type, gpa: Allocator, saved: *const checkpoint.Existing, key: checkpoint.Artifact, deadline: io.Deadline) ![]T {
    const mapping = try saved.map(key, deadline);
    defer mapping.unmap();
    return gpa.dupe(T, try checkpoint.array(T, mapping));
}

const Shared = struct {
    topology: *Topology,
    segments: []const edges.Edge,
    shape_points: []const geo.FixedLL,
    ways: *const Ways,
    metadata: *const Metadata,
    admin_ids: ?[]const graph.admin.Id = null,
    admin_index: ?graph.admin.View = null,
    countries: []const country_access.Country = &.{},
    apply_country_overrides: bool = true,
    deadline: io.Deadline,

    fn country(self: *const Shared, node: u32) country_access.Country {
        return if (self.admin_ids) |ids| self.countries[ids[node]] else .{};
    }

    fn adminDriveOnLeft(self: *const Shared, node: u32, options: *const Options) !?bool {
        if (options.admin_drive_side) |hook| {
            if (hook.resolve(hook.context, self.topology.coordinates[node])) |side| return side == .left;
        }
        if (!options.use_admin_db) return null;
        if (self.admin_index) |index| {
            if (try index.region(self.admin_ids.?[node])) |area| return !area.attr.drive_on_right;
        }
        return (options.drive_side orelse .left) == .left;
    }
};

const AdminJob = struct {
    index: graph.admin.View,
    points: []const geo.FixedLL,
    ids: []graph.admin.Id,
    deadline: io.Deadline,
    result: anyerror!void = {},

    fn run(self: *AdminJob) void {
        self.result = self.assign();
    }

    fn assign(self: AdminJob) !void {
        var previous: ?u32 = null;
        var sole: graph.admin.Id = graph.admin.unknown;
        for (self.points, self.ids, 0..) |point, *id, i| {
            try checkDeadline(self.deadline, i);
            const tile = enhance.tileId(point);
            if (tile != previous) {
                sole = try self.index.singleArea(enhance.tileBounds(tile), self.deadline);
                previous = tile;
            }
            id.* = if (sole != graph.admin.unknown) sole else try self.index.lookup(point.toPoint(), self.deadline);
        }
    }
};

fn assignAdmins(points: []const geo.FixedLL, options: Options) !?Scratch(graph.admin.Id) {
    const index = options.admin_index orelse return null;
    var ids = try Scratch(graph.admin.Id).init(points.len, options.scratch_dir);
    errdefer ids.deinit();
    const cores = if (options.workers == 0) std.Thread.getCpuCount() catch 1 else options.workers;
    const count = @max(1, @min(cores, max_workers, (points.len + 255) / 256));
    var jobs: [max_workers]AdminJob = undefined;
    for (jobs[0..count], 0..) |*job, i| {
        const start = points.len * i / count;
        const end = points.len * (i + 1) / count;
        job.* = .{ .index = index, .points = points[start..end], .ids = ids.data[start..end], .deadline = options.deadline };
    }
    try runJobs(jobs[0..count]);
    return ids;
}

fn writeAdmins(writer: *format.BundleWriter, index: ?graph.admin.View, ids: ?[]const graph.admin.Id) !void {
    if (index) |present| {
        try writer.stream(.admins, present, emitAdmins);
        try writer.write(.node_admins, ids.?);
    }
}

fn emitAdmins(index: graph.admin.View, out: *format.SectionWriter(.admins)) !void {
    try index.write(out);
}

noinline fn writeTimezones(gpa: Allocator, writer: *format.BundleWriter, source: timezones.Source, points: []const format.Coordinate, scratch_dir: []const u8) !void {
    const rules = try graph.timezone.Rules.parse(source.rules);
    try rules.verify(writer.deadline);
    var index = try timezones.build(gpa, source.boundaries, rules, points, writer.deadline);
    defer index.deinit();
    var ids = try Scratch(graph.timezone.Id).init(points.len, scratch_dir);
    defer ids.deinit();
    try timezones.assign(index.view, points, ids.data, writer.deadline);
    try writer.write(.node_timezones, ids.data);
    try writer.write(.timezone_rules, source.rules);
}

const LinkSource = struct {
    shared: *const Shared,
    plan: *const Layout,

    pub fn nodeCount(self: LinkSource) usize {
        return self.plan.nodes.items.len;
    }

    pub fn nodeOrder(self: LinkSource, id: u32) struct { osm: u64, geography: u64 } {
        const node = self.plan.nodes.items[id];
        const tile = enhance.tileId(node.point);
        const bounds = enhance.tileBounds(tile);
        const point = node.point.toOsmPoint();
        const x: u32 = @intFromFloat(std.math.clamp((point.lng - bounds.minx) * 262144.0, 0, 65535));
        const y: u32 = @intFromFloat(std.math.clamp((point.lat - bounds.miny) * 262144.0, 0, 65535));
        return .{ .osm = @bitCast(node.osm_id), .geography = (@as(u64, tile) << 32) | grid.hilbertIndex(16, x, y) };
    }

    pub fn hasExit(self: LinkSource, id: u32) bool {
        const node = self.plan.nodes.items[id];
        const tags_at_node = self.shared.metadata.signs.nodes.get(node.osm_id) orelse return false;
        return tags_at_node.ref.len != 0 or tags_at_node.exit_to.len != 0;
    }

    pub fn appendArcs(self: LinkSource, id: u32, out: *std.ArrayList(link_classification.Arc), a: Allocator) !void {
        const topo = self.shared.topology;
        const node = self.plan.nodes.items[id];
        try out.ensureUnusedCapacity(a, node.degree);
        for (node.first_alias..node.first_alias + aliasCount(node.degree)) |alias| {
            try checkDeadline(self.shared.deadline, alias);
            const first_edge = topo.first_edge[alias];
            const degree = topo.groups[alias].real_degree;
            for (topo.slot_refs.data[first_edge..][0..degree]) |ref|
                out.appendAssumeCapacity(try self.arc(ref));
        }
    }

    pub fn arc(self: LinkSource, ref: u32) !link_classification.Arc {
        const segment = self.shared.segments[ref / 2];
        const way = self.shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
        const class = way.by_direction[ref & 1];
        const end = if (ref & 1 == 0) segment.to else segment.from;
        return .{
            .ref = ref,
            .head = self.plan.by_id.get(end) orelse return error.MissingLinkNode,
            .road_class = @fromBackingInt(way.attr.importance),
            .link = class.flags.link,
            .named = way.attr.has_names,
            .outbound = class.forwardAccess().auto,
            .inbound = class.reverseAccess().auto,
        };
    }

    pub fn road(self: LinkSource, ref: u32) !link_classification.Road {
        const id = self.shared.segments[ref / 2].way_id;
        const way = self.shared.ways.get(id) orelse return error.MissingWayAttributes;
        const metadata = self.shared.metadata;
        const destination = if (metadata.signs.ways.get(id)) |fields| fields.branch_ref else .empty;
        const main_name = if (way.attr.primary_name) metadata.name_ids.items[way.primaryNameOffset()] else .empty;
        const main_ref = if (way.names.ref_count != 0) way.nameRange(metadata.name_ids.items)[way.names.ref_start] else .empty;
        return .{
            .way = id,
            .name = metadata.strings.get(main_name).?,
            .ref = metadata.strings.get(main_ref).?,
            .destination_refs = metadata.strings.get(destination).?,
        };
    }

    pub fn length(self: LinkSource, ref: u32) f64 {
        return self.shared.segments[ref / 2].length_m;
    }

    pub fn heading(self: LinkSource, ref: u32) !f64 {
        const shape = try segmentShape(self.shared.shape_points, self.shared.segments[ref / 2]);
        const first = if (ref & 1 == 0) shape[0] else shape[shape.len - 1];
        const next = if (ref & 1 == 0) shape[1] else shape[shape.len - 2];
        return first.toOsmPoint().headingWith(next.toOsmPoint(), math);
    }
};

const Job = struct {
    shared: *const Shared,
    options: *const Options,
    start: usize,
    end: usize,
    interner: classes.Interner,
    link_results: []const link_classification.Result,
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
            const from_country = shared.country(@intCast(node));
            const admin_left = try shared.adminDriveOnLeft(@intCast(node), self.options);
            for (0..group.real_degree) |local| {
                const slot = first + local;
                const ref = topo.slot_refs.data[slot];
                const segment = shared.segments[ref / 2];
                const opposite = topo.placements.data[ref ^ 1];
                const way = shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
                const direction = ref & 1;
                var class = way.by_direction[direction];
                class.flags.named = way.attr.has_names;
                if (admin_left orelse way.attr.drive_on_left) {
                    const opposing = way.by_direction[direction ^ 1];
                    class.flags.shoulder = opposing.flags.shoulder;
                    // Explicit one-way bicycle access and contraflow lanes keep their direction.
                    if (!way.attr.oneway and class.forwardAccess().bicycle == class.reverseAccess().bicycle)
                        class.category.cycle_lane = opposing.category.cycle_lane;
                }
                if (self.link_results.len != 0) {
                    const link = self.link_results[ref / 2];
                    if (link.processed) {
                        class.category.road_class = link.road_class;
                        if (link.turn_channel and class.category.use != @backingInt(graph.constants.Use.construction)) {
                            class.category.use = @backingInt(graph.constants.Use.turn_channel);
                            class.flags.internal = false;
                        }
                    }
                }
                if (shared.metadata.signs.ways.count() != 0 or shared.metadata.signs.nodes.count() != 0)
                    class.flags.sign = (try selectEdgeSigns(shared, @intCast(node), segment, ref, class)) != null;
                edge_class.applySegmentControls(&class, segment.flags, direction == 0, way.attr.oneway);
                const to_country = shared.country(opposite.node);
                class.flags.country_crossing = from_country.iso != 0 and to_country.iso != 0 and from_country.iso != to_country.iso;
                if (shared.apply_country_overrides and way.attr.access_tags_known and from_country.iso == to_country.iso and
                    (from_country.rules != .none or way.attr.motorroad))
                {
                    const access_tags: graph.constants.AccessMask = @bitCast(@as(u16, way.attr.access_tags));
                    const is_ferry = class.category.use == @backingInt(graph.constants.Use.ferry);
                    const motorroad = way.attr.motorroad and (!is_ferry or way.attr.ferry_duration);
                    country_access.apply(&class, from_country.rules, access_tags, motorroad);
                }
                if (class.access.forward == 0) class.detail.access_restriction = 0;
                const encoded_len = try encodeLength(segment.length_m);
                const curvature = try computeCurvature(try segmentShape(shared.shape_points, segment), shared.deadline);
                topo.output.data[slot] = .{
                    .head = opposite.node,
                    .geom = .{ .len_m = encoded_len, .grade = 6, .curvature = curvature },
                    .cls = .{
                        .class_id = @intCast(@backingInt(try self.interner.intern(class))),
                        .local = @intCast(local),
                        .opp_local = @intCast(opposite.slot - topo.first_edge[opposite.node]),
                        .cold_checks = @intFromBool(class.detail.access_restriction != 0),
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

fn populate(gpa: Allocator, shared: *const Shared, plan: *const Layout, options: Options) !classes.Table {
    const run_links = options.reclassify_links or options.infer_turn_channels;
    const classified = try Scratch(link_classification.Result).init(if (run_links) shared.segments.len else 0, options.scratch_dir);
    defer classified.deinit();
    try link_classification.classify(gpa, LinkSource{ .shared = shared, .plan = plan }, classified.data, .{
        .reclassify = options.reclassify_links,
        .infer_turn_channels = options.infer_turn_channels,
        .deadline = options.deadline,
    });
    const requested = options.workers;
    const workers = if (requested == 0) std.Thread.getCpuCount() catch 1 else requested;
    const nodes = shared.topology.nodes.len;
    const count = @max(1, @min(workers, max_workers, (nodes + 255) / 256));
    var jobs: [max_workers]Job = undefined;
    const active = jobs[0..count];
    for (active, 0..) |*job, i| {
        const start = (nodes * i) / count;
        const end = (nodes * (i + 1)) / count;
        job.* = .{ .shared = shared, .options = &options, .start = start, .end = end, .interner = .init(gpa), .link_results = classified.data };
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
    shared: *const Shared,
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
                node.attr.drive_on_left = (try self.shared.adminDriveOnLeft(id, &self.options)) orelse
                    try self.wayDriveOnLeft(id);
                node.attr.intersection = try enhance.intersection(self.network, id, deadline);
            }
        }
    }

    fn wayDriveOnLeft(self: *const NodeEnhanceJob, node: u32) !bool {
        // With admin lookup disabled, Valhalla retains the driving side of
        // the last physical edge in incident order at the junction.
        const first = self.network.canonical(node);
        const end = try self.network.endAlias(first, self.options.deadline);
        const topo = self.shared.topology;
        const start = topo.first_edge[first];
        var i = topo.first_edge[end];
        while (i > start) {
            i -= 1;
            try checkDeadline(self.options.deadline, i);
            const slot = self.network.walk_order[i];
            if (self.network.classes[topo.output.data[slot].cls.class_id].flags.node_connector) continue;
            const segment = self.shared.segments[topo.slot_refs.data[slot] / 2];
            const way = self.shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
            return way.attr.drive_on_left;
        }
        return (self.options.drive_side orelse .right) == .left;
    }
};

const not_thru_flag = 1;
const configured_speed_flag = 2;
const internal_flag = 4;
const stop_flag = 8;
const yield_flag = 16;
const signal_flag = 32;

const EdgeEnhanceJob = struct {
    gpa: Allocator,
    shared: *const Shared,
    network: enhance.Network,
    controls: []const u8,
    derived: []u16,
    nodes: []const u32,
    options: Options,
    result: anyerror!void = {},

    fn run(self: *EdgeEnhanceJob) void {
        self.result = self.emit();
    }

    fn emit(self: *EdgeEnhanceJob) !void {
        var search = try enhance.Search.init(self.gpa);
        defer search.deinit(self.gpa);
        const deadline = self.options.deadline;
        for (self.nodes, 0..) |id, i| {
            try checkDeadline(deadline, i);
            const first = self.network.first_edge[id];
            const end = self.network.first_edge[id + 1];
            const density = self.network.nodes[id].attr.density;
            for (self.network.edges[first..end], self.derived[first..end], first..end) |edge, *derived, slot| {
                const class = self.network.classes[edge.cls.class_id];
                if (class.flags.node_connector) {
                    derived.* = 0;
                    continue;
                }
                const configured = if (self.options.speed_rules) |rules| configured: {
                    const region: speeds.Region = if (self.options.admin_index) |index| region: {
                        const names = try index.names(self.shared.admin_ids.?[edge.head]);
                        break :region .{ .country = names.country_iso, .state = names.state_iso };
                    } else .{};
                    break :configured rules.speed(region, class, density, class.flags.sign);
                } else null;
                const ferry_duration = if (class.category.use == @backingInt(graph.constants.Use.ferry)) ferry: {
                    const segment = self.shared.segments[self.shared.topology.slot_refs.data[slot] / 2];
                    const way = self.shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
                    break :ferry way.attr.ferry_duration;
                } else false;
                const speed = configured orelse speeds.defaultSpeed(class, edge.speed[0], edge.geom.len_m, density, .{
                    .infer_turn_channels = self.options.infer_turn_channels,
                    .ferry_duration = ferry_duration,
                });
                const not_thru = try search.notThru(self.network, id, edge, deadline);
                const internal = self.options.infer_internal_intersections and
                    try enhance.intersectionInternal(self.network, id, @intCast(slot), self, deadline);
                const signs = try enhance.signs(
                    self.network,
                    id,
                    edge,
                    @bitCast(@as(u32, self.controls[id])),
                    @bitCast(@as(u32, self.controls[edge.head])),
                    deadline,
                );
                derived.* = (@as(u16, speed) << 8) |
                    (if (not_thru) @as(u16, not_thru_flag) else 0) |
                    (if (configured != null) @as(u16, configured_speed_flag) else 0) |
                    (if (internal) @as(u16, internal_flag) else 0) |
                    (if (signs.stop) @as(u16, stop_flag) else 0) |
                    (if (signs.yield) @as(u16, yield_flag) else 0) |
                    (if (signs.signal) @as(u16, signal_flag) else 0);
            }
        }
    }

    pub fn rawHeading(self: *const EdgeEnhanceJob, slot: u32) !u16 {
        const ref = self.shared.topology.slot_refs.data[slot];
        const segment = self.shared.segments[ref / 2];
        const shape = try segmentShape(self.shared.shape_points, segment);
        const class = &self.network.classes[self.network.edges[slot].cls.class_id];
        return turns.rawHeading(shape, ref & 1 == 0, class, self.options.deadline);
    }
};

noinline fn enhanceGraph(gpa: Allocator, shared: *const Shared, plan: *const Layout, base: []const classes.EdgeClass, options: Options, restrictions: turn_restrictions.Source, program: *automaton_builder.Program, lane_output: *lane_build.Output) !classes.Table {
    const topo = shared.topology;
    const deadline = options.deadline;
    const aliases = try Scratch(u32).init(if (plan.split_nodes == 0) 0 else topo.nodes.len, options.scratch_dir);
    defer aliases.deinit();
    const controls = try Scratch(u8).init(topo.nodes.len, options.scratch_dir);
    defer controls.deinit();
    for (plan.nodes.items, 0..) |node, i| {
        try checkDeadline(deadline, i);
        const raw: u32 = @bitCast(node.controls);
        if (raw == 0 and aliases.data.len == 0) continue;
        const end = node.first_alias + aliasCount(node.degree);
        var start = node.first_alias;
        while (start < end) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const count = @min(end - start, 1024);
            if (raw != 0) @memset(controls.data[start..][0..count], @truncate(raw));
            if (aliases.data.len != 0) @memset(aliases.data[start..][0..count], node.first_alias);
            start += count;
        }
    }
    const order = try Scratch(u32).init(topo.output.data.len, options.scratch_dir);
    defer order.deinit();
    // Reuse the walk ranks after sorting for edge speed and not-thru results.
    const derived = try Scratch(u16).init(topo.output.data.len, options.scratch_dir);
    defer derived.deinit();
    try orderWalks(shared, plan, base, order.data, derived.data);
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
    const tile_order = try Scratch(u32).init(topo.nodes.len, options.scratch_dir);
    defer tile_order.deinit();
    {
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
                .shared = shared,
                .options = options,
            };
        }
        try runJobs(jobs[0..count]);
    }
    const count = @max(1, @min(workers, max_workers, (topo.nodes.len + 255) / 256));
    var jobs: [max_workers]EdgeEnhanceJob = undefined;
    // Keep geographic order and split large tiles across workers. Results
    // are still indexed by CSR slot and interned in one fixed order.
    for (jobs[0..count], 0..) |*job, i| {
        job.* = .{
            .gpa = gpa,
            .shared = shared,
            .network = network,
            .controls = controls.data,
            .derived = derived.data,
            .nodes = tile_order.data[topo.nodes.len * i / count .. topo.nodes.len * (i + 1) / count],
            .options = options,
        };
    }
    try runJobs(jobs[0..count]);

    var restriction_starts: RestrictionStarts = .empty;
    defer restriction_starts.deinit(gpa);
    program.* = try compileComplexTurns(gpa, shared, plan, base, order.data, restrictions, &restriction_starts);
    const catalog = &shared.metadata.lanes;
    if (catalog.ways.count() != 0 or catalog.links.items.len != 0) {
        var lane_turns: ResolvedTurns = .{ .stats = restrictions.stats };
        defer lane_turns.deinit(gpa);
        if (catalog.ways.count() != 0) lane_turns = try resolveTurns(gpa, shared, plan, base, restrictions, null);
        try assembleLanes(shared, plan, base, lane_turns.hard.items, &restriction_starts, lane_output);
    }
    var interner = classes.Interner.init(gpa);
    defer interner.deinit();
    var lane_index: usize = 0;
    var connection_index: usize = 0;
    for (topo.nodes, 0..) |node, i| {
        try checkDeadline(deadline, i);
        const first = topo.first_edge[i];
        const end = topo.first_edge[i + 1];
        for (topo.output.data[first..end], derived.data[first..end], first..) |*edge, result, slot| {
            var class = base[edge.cls.class_id];
            const target = topo.nodes[edge.head];
            class.category.density = @intCast((@as(u8, node.attr.density) + target.attr.density) / 2);
            if (!class.flags.node_connector) {
                class.flags.not_thru = result & not_thru_flag != 0;
                class.flags.internal = class.flags.internal or result & internal_flag != 0;
                class.flags.stop_sign = result & stop_flag != 0;
                class.flags.yield_sign = result & yield_flag != 0;
                class.flags.traffic_signal = result & signal_flag != 0;
                if (result & configured_speed_flag != 0) class.flags.tagged_speed = false;
                class.flags.dead_end = target.attr.intersection == .dead_end;
                edge.speed[0] = @truncate(result >> 8);
            }
            if (restriction_starts.get(@intCast(slot))) |masks| {
                class.restrictions = @bitCast(masks);
                class.flags.complex_restriction = true;
            }
            if (lane_index < lane_output.entries.items.len and lane_output.entries.items[lane_index].edge == slot) {
                class.flags.turnlanes = true;
                lane_index += 1;
            }
            while (connection_index < lane_output.connections.items.len and lane_output.connections.items[connection_index].edge == slot) : (connection_index += 1) {
                try checkDeadline(deadline, connection_index);
                class.flags.lane_conn = true;
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

noinline fn assembleLanes(shared: *const Shared, plan: *const Layout, base: []const classes.EdgeClass, hard: []const TurnMask, starts: *const RestrictionStarts, output: *lane_build.Output) !void {
    const topo = shared.topology;
    const catalog = &shared.metadata.lanes;
    for (topo.output.data, 0..) |edge, slot| {
        try checkDeadline(shared.deadline, slot);
        const class = &base[edge.cls.class_id];
        if (class.flags.node_connector) continue;
        const ref = topo.slot_refs.data[slot];
        const segment = shared.segments[ref / 2];
        try output.addConnections(@intCast(slot), catalog.linksTo(segment.way_id), shared.deadline);
        const tag_ids = catalog.ways.get(segment.way_id) orelse continue;
        const text = shared.metadata.strings.get(tag_ids[ref & 1]) orelse return error.InvalidStringId;
        if (text.len == 0) continue;
        try lane_build.parseTurnLanes(output.a, &output.parsed, text, shared.deadline);
        const exits = try laneExits(shared, plan, base, edge, segment, ref & 1 == 0, hard);
        const complex = (starts.get(@intCast(slot)) orelse 0) & 0xffff != 0;
        _ = try output.addTurns(@intCast(slot), exits, complex, shared.deadline);
    }
}

fn laneExits(shared: *const Shared, plan: *const Layout, base: []const classes.EdgeClass, edge: format.EdgeHot, segment: edges.Edge, forward: bool, hard: []const TurnMask) !lane_build.ExitTurns {
    const topo = shared.topology;
    const opposite = topo.first_edge[edge.head] + edge.cls.opp_local;
    const first = std.sort.lowerBound(TurnMask, hard, opposite, TurnMask.compare);
    var restricted: u32 = 0;
    for (hard[first..], 0..) |entry, i| {
        if (entry.slot != opposite) break;
        try checkDeadline(shared.deadline, i);
        restricted |= entry.exits;
    }
    const shape = try segmentShape(shared.shape_points, segment);
    const incoming = (try turns.rawHeading(shape, !forward, &base[edge.cls.class_id], shared.deadline) + 180) % 360;
    const node = plan.nodes.items[plan.by_id.get(if (forward) segment.to else segment.from).?];
    var exits: lane_build.ExitTurns = .empty;
    for (node.first_alias..node.first_alias + aliasCount(node.degree)) |alias| {
        try checkDeadline(shared.deadline, alias - node.first_alias);
        const offset = topo.first_edge[alias];
        for (offset..offset + topo.groups[alias].real_degree) |slot| {
            const outgoing = topo.output.data[slot];
            const class = &base[outgoing.cls.class_id];
            if (slot == opposite or !class.forwardAccess().auto or
                (alias == edge.head and (restricted & (@as(u32, 1) << outgoing.cls.local)) != 0)) continue;
            const ref = topo.slot_refs.data[slot];
            const points = try segmentShape(shared.shape_points, shared.segments[ref / 2]);
            const heading = try turns.rawHeading(points, ref & 1 == 0, class, shared.deadline);
            exits.insert(turns.turnType((@as(u32, heading) + 360 - incoming) % 360));
        }
    }
    return exits;
}

/// Valhalla visits outbound arcs by auto driveability, effective class, names
/// and then segment encounter order. The expansion cap depends on that order,
/// so keep a separate ordering for the walk and preserve CSR local indices.
fn orderWalks(shared: *const Shared, plan: *const Layout, base: []const classes.EdgeClass, order: []u32, ranks: []u16) !void {
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
                rank.* = graph.constants.incidentEdgeRank(class.forwardAccess().auto, class.category.road_class, way.attr.has_names);
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
        if (self.source == .pack) {
            var sampler: dem.@"packed".Sampler = .{ .pack = self.source.pack };
            return self.emit(&sampler);
        }
        // Each job owns the decompression cache because its sampler holds
        // the current tile between reads.
        var tiles = switch (self.source) {
            .tiles => |dir| try dem.hgt.Tiles.initBuild(self.gpa, dir, self.shared.deadline),
            .catalog => |catalog| try catalog.borrowMappings(self.gpa, self.shared.deadline),
            .pack => unreachable,
        };
        defer tiles.deinit();
        var sampler: dem.hgt.Sampler = .{ .tiles = &tiles };
        try self.emit(&sampler);
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

const TurnMask = struct {
    slot: u32,
    exits: u32,

    fn before(_: void, a: TurnMask, b: TurnMask) bool {
        return a.slot < b.slot;
    }

    fn compare(slot: u32, item: TurnMask) std.math.Order {
        return std.math.order(slot, item.slot);
    }
};

const ResolvedTurns = struct {
    hard: std.ArrayList(TurnMask) = .empty,
    modes: std.ArrayList(mode_turns.Entry) = .empty,
    stats: turn_restrictions.Stats,

    fn deinit(self: *ResolvedTurns, a: Allocator) void {
        self.hard.deinit(a);
        self.modes.deinit(a);
    }
};

const IncidentTurnEdge = struct {
    way: i64,
    node: u32,
    slot: u32,
    rank: u8,

    fn before(_: void, a: IncidentTurnEdge, b: IncidentTurnEdge) bool {
        return if (a.rank == b.rank) a.slot < b.slot else a.rank < b.rank;
    }
};

// Matches EdgeClass.restrictions, with the forward mask in the low half.
const RestrictionStarts = std.AutoHashMapUnmanaged(u32, u32);
const RestrictionSink = struct { builder: *automaton_builder.Builder, starts: *RestrictionStarts };

// Ported from src/mjolnir/restrictionbuilder.cc (Valhalla 3.9.3).
const ComplexWalk = struct {
    shared: *const Shared,
    layout: *const Layout,
    classes: []const classes.EdgeClass,
    order: []const u32,

    const Frame = struct {
        previous: i64,
        node: i64,
        next: u32,
        end: u32,
        way: usize,
        extend: bool = false,
    };

    fn frame(self: ComplexWalk, previous: i64, node: i64, way: usize) !Frame {
        const topo = self.shared.topology;
        const logical = self.layout.nodes.items[self.layout.by_id.get(node) orelse return error.MissingNode];
        const first = logical.first_alias;
        return .{
            .previous = previous,
            .node = node,
            .next = topo.first_edge[first],
            .end = topo.first_edge[first + aliasCount(logical.degree)],
            .way = way,
        };
    }

    fn classFor(self: ComplexWalk, slot: u32) classes.EdgeClass {
        return self.classes[self.shared.topology.output.data[slot].cls.class_id];
    }

    fn allowed(class: classes.EdgeClass, modes: u16) bool {
        if (class.flags.node_connector or class.access.forward & modes == 0) return false;
        return switch (std.enums.fromInt(graph.constants.Use, class.category.use) orelse return false) {
            .rail, .bus, .egress_connection, .platform_connection, .transit_connection => false,
            else => true,
        };
    }

    fn wayId(self: ComplexWalk, slot: u32) i64 {
        return self.shared.segments[self.shared.topology.slot_refs.data[slot] / 2].way_id;
    }

    fn nodeFor(self: ComplexWalk, slot: u32, destination: bool) i64 {
        const reference = self.shared.topology.slot_refs.data[slot];
        const segment = self.shared.segments[reference / 2];
        return if (destination != (reference & 1 != 0)) segment.to else segment.from;
    }

    /// Walk the via ways in relation order, trying the next member before
    /// following more segments of the current way. Alias connectors are
    /// internal to one OSM junction and do not consume a restriction edge.
    noinline fn find(self: ComplexWalk, origin: u32, ways: []const i64, modes: u16, path: *[automaton.max_edges]u32) ![]u32 {
        var stack: [automaton.max_edges - 1]Frame = undefined;
        var depth: usize = 1;
        path[0] = origin;
        stack[0] = try self.frame(self.nodeFor(origin, false), self.nodeFor(origin, true), 0);
        while (depth != 0) {
            if (self.shared.deadline.expired()) return error.DeadlineExceeded;
            const at = &stack[depth - 1];
            if (at.next == at.end) {
                depth -= 1;
                continue;
            }
            const slot = self.order[at.next];
            var next_way = at.way + 1;
            if (at.extend) {
                at.extend = false;
                at.next += 1;
                next_way = at.way;
                const head = self.nodeFor(slot, true);
                for (stack[0..depth]) |prior| {
                    if (prior.node == head) break;
                } else {
                    stack[depth] = try self.frame(at.node, head, next_way);
                    depth += 1;
                }
                continue;
            }
            if (!allowed(self.classFor(slot), modes) or self.wayId(slot) != ways[at.way] or
                self.nodeFor(slot, true) == at.previous)
            {
                at.next += 1;
                continue;
            }
            path[depth] = slot;
            if (next_way == ways.len) return path[0 .. depth + 1];
            if (depth == stack.len) {
                at.next += 1;
                continue;
            }
            at.extend = true;
            stack[depth] = try self.frame(at.node, self.nodeFor(slot, true), next_way);
            depth += 1;
        }
        return path[0..0];
    }

    noinline fn prohibit(self: ComplexWalk, sink: RestrictionSink, path: []u32, modes: u16, only: bool) !void {
        if (!only) return forbidSequence(sink, path, modes, 0);
        // Each wrong exit from a mandatory prefix is a forbidden sequence.
        // Reversing those sequences preserves legality in reverse search too.
        for (1..path.len) |index| {
            const prescribed = path[index];
            const head = self.nodeFor(path[index - 1], true);
            const at = try self.frame(0, head, 0);
            for (self.order[at.next..at.end], 0..) |exit, i| {
                try checkDeadline(self.shared.deadline, i);
                if (exit == prescribed or !allowed(self.classFor(exit), modes)) continue;
                path[index] = exit;
                try forbidSequence(sink, path[0 .. index + 1], modes, 0);
            }
            path[index] = prescribed;
        }
    }
};

fn forbidSequence(sink: RestrictionSink, path: []const u32, modes: u16, domain: u64) !void {
    try sink.builder.forbidWhen(path, modes, domain);
    const forward = try sink.starts.getOrPutValue(sink.builder.a, path[0], 0);
    forward.value_ptr.* |= modes;
    const reverse = try sink.starts.getOrPutValue(sink.builder.a, path[path.len - 1], 0);
    reverse.value_ptr.* |= @as(u32, modes) << 16;
}

noinline fn compileComplexTurns(gpa: Allocator, shared: *const Shared, layout: *const Layout, base: []const classes.EdgeClass, order: []const u32, source: turn_restrictions.Source, starts: *RestrictionStarts) !automaton_builder.Program {
    if (source.complex.len == 0 and source.simple_domains.len == 0) return .{};
    var builder: automaton_builder.Builder = .{ .a = gpa, .deadline = shared.deadline };
    defer builder.deinit();
    const sink: RestrictionSink = .{ .builder = &builder, .starts = starts };
    if (source.simple_domains.len != 0) {
        var timed = try resolveTurns(gpa, shared, layout, base, source, sink);
        timed.deinit(gpa);
    }
    if (source.complex.len != 0) try addComplexTurns(shared, layout, base, order, source, sink);
    return builder.finish(shared.topology.output.data.len);
}

noinline fn addComplexTurns(shared: *const Shared, layout: *const Layout, base: []const classes.EdgeClass, order: []const u32, source: turn_restrictions.Source, sink: RestrictionSink) !void {
    const gpa = sink.builder.a;
    const Origin = struct { segment: u32, next: u32 };
    var origins: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    defer origins.deinit(gpa);
    var from_segments: std.ArrayList(Origin) = .empty;
    defer from_segments.deinit(gpa);
    for (source.complex, 0..) |row, i| {
        try checkDeadline(shared.deadline, i);
        _ = try origins.getOrPutValue(gpa, row.from, 0);
    }
    var segment_index = shared.segments.len;
    while (segment_index != 0) {
        segment_index -= 1;
        try checkDeadline(shared.deadline, segment_index);
        if (origins.getPtr(shared.segments[segment_index].way_id)) |first| {
            try from_segments.append(gpa, .{ .segment = @intCast(segment_index), .next = first.* });
            first.* = @intCast(from_segments.items.len);
        }
    }
    const walk: ComplexWalk = .{ .shared = shared, .layout = layout, .classes = base, .order = order };
    const topo = shared.topology;
    for (source.complex, 0..) |row, i| {
        try checkDeadline(shared.deadline, i);
        const kind = try row.kind();
        const via = try row.vias(source.via_ways);
        if (row.attr.modes == 0) continue;
        var ways: [automaton.max_edges - 1]i64 = undefined;
        @memcpy(ways[0..via.len], via);
        ways[via.len] = row.to;
        var origin = origins.get(row.from).?;
        while (origin != 0) {
            if (shared.deadline.expired()) return error.DeadlineExceeded;
            const entry = from_segments.items[origin - 1];
            origin = entry.next;
            for (topo.placements.data[2 * entry.segment ..][0..2]) |placement| {
                if (!ComplexWalk.allowed(walk.classFor(placement.slot), row.attr.modes)) continue;
                var storage: [automaton.max_edges]u32 = undefined;
                const path = try walk.find(placement.slot, ways[0 .. via.len + 1], row.attr.modes, &storage);
                if (path.len != 0) try walk.prohibit(sink, path, row.attr.modes, kind.only());
            }
        }
    }
}

fn turnIncidents(a: Allocator, shared: *const Shared, edge_classes: []const classes.EdgeClass, node: Node, incident: *std.ArrayList(IncidentTurnEdge)) !void {
    incident.clearRetainingCapacity();
    try incident.ensureTotalCapacity(a, node.degree);
    const topo = shared.topology;
    for (node.first_alias..node.first_alias + aliasCount(node.degree)) |alias| {
        const first = topo.first_edge[alias];
        for (first..first + topo.groups[alias].real_degree) |slot| {
            try checkDeadline(shared.deadline, incident.items.len);
            const ref = topo.slot_refs.data[slot];
            const segment = shared.segments[ref / 2];
            const way = shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
            const access = way.by_direction[ref & 1].forwardAccess();
            const class = edge_classes[topo.output.data[slot].cls.class_id];
            incident.appendAssumeCapacity(.{
                .way = segment.way_id,
                .node = @intCast(alias),
                .slot = @intCast(slot),
                .rank = graph.constants.incidentEdgeRank(access.auto, class.category.road_class, way.attr.has_names),
            });
        }
    }
    std.sort.heap(IncidentTurnEdge, incident.items, {}, IncidentTurnEdge.before);
}

fn restrictionEntryBefore(_: void, a: mode_turns.Entry, b: mode_turns.Entry) bool {
    return a.key() < b.key();
}

// The pinned tile stores eight outgoing bits in Valhalla's incident-edge order.
// Find those arcs without changing native CSR indices.
noinline fn resolveTurns(a: Allocator, shared: *const Shared, plan: *const Layout, edge_classes: []const classes.EdgeClass, source: turn_restrictions.Source, sink: ?RestrictionSink) !ResolvedTurns {
    const topo = shared.topology;
    const valhalla_mask_width = 8;
    var result: ResolvedTurns = .{ .stats = source.stats };
    errdefer result.deinit(a);
    if (source.entries.len == 0) return result;
    if (source.simple_domains.len != 0 and source.simple_domains.len != source.entries.len) return error.InvalidCheckpoint;
    var incident: std.ArrayList(IncidentTurnEdge) = .empty;
    defer incident.deinit(a);
    var preceding_via: ?i64 = null;
    var resolved_relation: ?i64 = null;
    for (source.entries, 0..) |restriction, row| {
        try checkDeadline(shared.deadline, row);
        const kind = try restriction.kind();
        const domain = if (source.simple_domains.len == 0) 0 else source.simple_domains[row];
        if (sink != null and domain == 0) continue;
        if (domain != 0 and !restriction.attr.mode_specific) return error.InvalidCheckpoint;
        const logical = plan.by_id.get(restriction.via) orelse {
            result.stats.missing_via += 1;
            continue;
        };
        const via = plan.nodes.items[logical];
        if (preceding_via != restriction.via) {
            try turnIncidents(a, shared, edge_classes, via, &incident);
            preceding_via = restriction.via;
        }
        var has_from = false;
        var has_to = false;
        for (incident.items, 0..) |edge, i| {
            try checkDeadline(shared.deadline, i);
            has_from = has_from or edge.way == restriction.from;
            has_to = has_to or edge.way == restriction.to;
        }
        if (!has_from) {
            result.stats.missing_from += 1;
            continue;
        }
        if (!has_to and !kind.only()) {
            result.stats.missing_to += 1;
            continue;
        }
        const mode_start = result.modes.items.len;
        var truncated = false;
        const specific = restriction.attr.mode_specific;
        for (incident.items, 0..) |out, rank| {
            try checkDeadline(shared.deadline, rank);
            if ((out.way == restriction.to) == kind.only()) continue;
            if (!specific and rank >= valhalla_mask_width) {
                truncated = true;
            } else if (restriction.attr.modes != 0) {
                for (incident.items, 0..) |in, i| {
                    try checkDeadline(shared.deadline, i);
                    if (in.way != restriction.from) continue;
                    if (domain != 0) {
                        const active = sink orelse continue;
                        const opposing = topo.output.data[in.slot];
                        const incoming = topo.first_edge[opposing.head] + opposing.cls.opp_local;
                        try forbidSequence(active, &.{ incoming, out.slot }, restriction.attr.modes, domain);
                    } else if (!specific and in.node == out.node) {
                        const local = topo.output.data[out.slot].cls.local;
                        try result.hard.append(a, .{ .slot = in.slot, .exits = @as(u32, 1) << local });
                    } else {
                        const opposing = topo.output.data[in.slot];
                        const incoming = topo.first_edge[opposing.head] + opposing.cls.opp_local;
                        try result.modes.append(a, .{
                            .incoming = incoming,
                            .outgoing = out.slot,
                            .attr = .{ .modes = restriction.attr.modes },
                        });
                    }
                }
            }
            if (!kind.only() and !specific) break;
        }
        if (result.modes.items.len != mode_start) {
            for (via.first_alias..via.first_alias + aliasCount(via.degree)) |node| {
                try checkDeadline(shared.deadline, node - via.first_alias);
                topo.nodes[node].attr.has_turn_restrictions = true;
            }
        }
        result.stats.mask_truncated += @intFromBool(truncated);
        result.stats.resolved += @intFromBool(resolved_relation != restriction.relation);
        resolved_relation = restriction.relation;
    }
    std.sort.heap(TurnMask, result.hard.items, {}, TurnMask.before);
    std.sort.heap(mode_turns.Entry, result.modes.items, {}, restrictionEntryBefore);
    var count: usize = 0;
    for (result.modes.items, 0..) |entry, i| {
        try checkDeadline(shared.deadline, i);
        if (count != 0 and entry.key() == result.modes.items[count - 1].key()) {
            result.modes.items[count - 1].attr.modes |= entry.attr.modes;
        } else {
            result.modes.items[count] = entry;
            count += 1;
        }
    }
    result.modes.shrinkRetainingCapacity(count);
    return result;
}

fn buildTurns(shared: *const Shared, edge_classes: []const classes.EdgeClass, metadata: *Metadata, restrictions: []const TurnMask, pool: *turns.Pool, headings: []u8, gpa: Allocator) ![]u32 {
    const topo = shared.topology;
    var side_pool = try turns.SidePool.init(gpa, topo.nodes.len);
    defer side_pool.deinit();
    const name_ids = metadata.name_ids.items;
    var approaches: [max_degree]turns.Approach = undefined;
    var us_names: [max_degree][graph.cold.max_names]tags.names.Id = undefined;
    var entries: [turns.max_matrix_size]u8 = undefined;
    var sides: [turns.max_matrix_size]u2 = undefined;
    var restriction_index: usize = 0;
    for (topo.nodes, 0..) |*node, i| {
        try checkDeadline(shared.deadline, i);
        const first = topo.first_edge[i];
        const degree = topo.first_edge[i + 1] - first;
        const use_us_names = shared.country(@intCast(i)).iso == std.mem.readInt(u16, "US", .little);
        for (approaches[0..degree], topo.output.data[first..][0..degree], headings[first..][0..degree], 0..) |*approach, edge, *code, local| {
            const class = &edge_classes[edge.cls.class_id];
            approach.* = .{ .bearing = 0, .length = edge.geom.len_m, .class = class, .names = &.{} };
            code.* = 0;
            if (class.flags.node_connector) continue;
            const ref = topo.slot_refs.data[first + local];
            const segment = shared.segments[ref / 2];
            const way = shared.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
            code.* = graph.headings.encode(try turns.rawHeading(try segmentShape(shared.shape_points, segment), ref & 1 == 0, class, shared.deadline));
            approach.bearing = graph.headings.decode(code.*);
            const names = way.nameRange(name_ids);
            approach.names = names;
            if (use_us_names) {
                const canonical = us_names[local][0..names.len];
                for (names, canonical) |id, *out| {
                    const text = metadata.strings.get(id).?;
                    const base = tags.names.usBaseName(text);
                    out.* = if (base.len == text.len) id else try metadata.strings.intern(base);
                }
                approach.names = canonical;
            }
        }
        const matrix = entries[0 .. degree * degree];
        const side: edge_class.DriveSide = if (node.attr.drive_on_left) .left else .right;
        const turn_sides = sides[0..matrix.len];
        try turns.matrix(approaches[0..degree], node.attr.signal != 0, side, matrix, turn_sides, shared.deadline);
        while (restriction_index < restrictions.len and restrictions[restriction_index].slot < first + degree) : (restriction_index += 1) {
            try checkDeadline(shared.deadline, restriction_index);
            const restriction = restrictions[restriction_index];
            const start = (restriction.slot - first) * degree;
            var exits = restriction.exits;
            while (exits != 0) {
                matrix[start + @ctz(exits)] |= 0x80;
                exits &= exits - 1;
            }
        }
        node.turn_off = try pool.intern(matrix);
        try side_pool.append(i, turn_sides);
    }
    return side_pool.finish(shared.deadline);
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

noinline fn buildCold(gpa: Allocator, shared: *const Shared, metadata: *Metadata, plan: *const Layout, edge_classes: []const classes.EdgeClass, writer: *format.BundleWriter, scratch_dir: []const u8, means: []const i16) !u64 {
    const topo = shared.topology;
    var coverage: graph.coverage.Builder = .{};
    try coverage.add(topo.coordinates, writer.deadline);
    const index = try Scratch(u32).init(topo.output.data.len, scratch_dir);
    defer index.deinit();
    var builder = try ColdBuilder.init(gpa, &metadata.strings, scratch_dir, shared.deadline);
    defer builder.deinit();
    var name_writer: name_details.Builder = .{ .selector = .{ .a = gpa, .deadline = shared.deadline } };
    defer name_writer.deinit();
    var refs: [graph.cold.max_names]u32 = undefined;
    var access_scratch: std.ArrayList(access_restriction.Entry) = .empty;
    defer access_scratch.deinit(gpa);
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
                const active = refs[0..way.names.count];
                const ref_start = way.names.ref_start;
                const ref_end = @as(usize, ref_start) + way.names.ref_count;
                for (active, way.nameRange(metadata.name_ids.items), 0..) |*name, id, i| {
                    name.* = try builder.nameRef(id, i >= ref_start and i < ref_end);
                }
                reverse = ref & 1 != 0;
                const mean = if (means.len == 0) graph.cold.no_elevation else means[ref / 2];
                const indoor: graph.cold.Indoor = .{
                    .layer = way.attr.layer,
                    .levels = metadata.levels.items[way.level_start..][0..way.level_count],
                };
                const shape = try segmentShape(shared.shape_points, seg);
                try coverage.addShape(shape, writer.deadline);
                const limits = metadata.access_limits.get(seg.way_id);
                const access_limits = if (limits) |set| try accessForDirections(gpa, &access_scratch, set.items, .{
                    topo.output.data[if (reverse) opposite else slot].cls.cold_checks != 0,
                    topo.output.data[if (reverse) slot else opposite].cls.cold_checks != 0,
                }, shared.deadline) else &.{};
                const raw_names = metadata.name_tags.tags(way.name_tags);
                if (raw_names.len != 0 or indoor.layer != 0 or (shared.admin_index != null and active.len != 0)) {
                    const ref_first = way.attr.importance <= @backingInt(graph.constants.RoadClass.trunk);
                    for ([_]bool{ true, false }) |forward| {
                        try name_writer.resolve(&builder, &metadata.strings, if (shared.admin_index) |*admin| admin else null, &.{
                            .rows = raw_names,
                            .legacy = active,
                            .indoor = indoor,
                            .ref_first = ref_first,
                            .forward = forward,
                            .point = shape[if (forward) 0 else shape.len - 1].toPoint(),
                        });
                    }
                    const fore = name_writer.sides[0];
                    const aft = name_writer.sides[1];
                    break :blk try builder.appendFull(@bitCast(seg.way_id), way.speeds.limit, mean, shape, fore.refs.items, .{
                        .reverse_refs = if (std.mem.eql(u32, fore.refs.items, aft.refs.items)) null else aft.refs.items,
                        .name_details = fore.details(),
                        .reverse_name_details = if (fore.detailsEqual(aft)) null else aft.details(),
                        .indoor = indoor,
                        .access_limits = access_limits,
                    });
                }
                break :blk try builder.appendFull(@bitCast(seg.way_id), way.speeds.limit, mean, shape, active, .{
                    .indoor = indoor,
                    .access_limits = access_limits,
                });
            } else try builder.append(0, 0, graph.cold.no_elevation, &.{ topo.coordinates[node], topo.coordinates[edge.head] }, &.{}, .{});
            index.data[slot] = graph.cold.directedIndex(record, reverse);
            index.data[opposite] = graph.cold.directedIndex(record, !reverse);
        }
    }
    if (builder.record_count != topo.output.data.len / 2) return error.InvalidColdRecordCount;
    try writer.write(.cold_idx, index.data);
    if (coverage.finish()) |bounds| try writer.write(.coverage, &.{bounds});
    try writeSigns(shared, metadata, plan, edge_classes, &builder, writer);
    return builder.write(writer);
}

noinline fn selectEdgeSigns(shared: *const Shared, node: u32, segment: edges.Edge, ref: u32, raw_class: classes.EdgeClass) !?sign_build.Selection {
    if (!raw_class.forwardAccess().auto) return null;
    const catalog = &shared.metadata.signs;
    const forward = ref & 1 == 0;
    const tail = if (forward) segment.from else segment.to;
    const node_tags = catalog.nodes.get(tail) orelse sign_build.NodeTags{};
    const way_tags: sign_build.WayTags = catalog.ways.get(segment.way_id) orelse way: {
        if (node_tags.ref.len == 0 and node_tags.exit_to.len == 0 and (node_tags.named or node_tags.name.len == 0)) return null;
        break :way .{};
    };
    const junction = try signJunction(shared, node);
    const node_type = shared.topology.nodes[node].attr.type;
    const fork = junction.isFork(node_type == @backingInt(graph.constants.NodeType.motorway_junction));
    const use: graph.constants.Use = @fromBackingInt(raw_class.category.use);
    const selection: sign_build.Selection = .init(way_tags, node_tags, &shared.metadata.strings, forward, use, fork);
    return if (selection.present(junction, raw_class.flags.link, fork)) selection else null;
}

fn signJunction(shared: *const Shared, node: u32) !sign_build.Junction {
    const topo = shared.topology;
    var owner = node;
    while (topo.groups[owner].has_left) {
        if (shared.deadline.expired()) return error.DeadlineExceeded;
        owner -= 1;
    }
    var result: sign_build.Junction = .{ .degree = 0 };
    while (true) : (owner += 1) {
        if (shared.deadline.expired()) return error.DeadlineExceeded;
        const group = topo.groups[owner];
        result.degree += group.real_degree;
        const first = topo.first_edge[owner];
        for (topo.slot_refs.data[first..][0..group.real_degree]) |ref| {
            const seg = shared.segments[ref / 2];
            const way = shared.ways.get(seg.way_id) orelse return error.MissingWayAttributes;
            const class = way.by_direction[ref & 1];
            result.links += @intFromBool(class.flags.link);
            result.drivable += @intFromBool(class.forwardAccess().auto);
        }
        if (!group.has_right) return result;
    }
}

noinline fn writeSigns(shared: *const Shared, metadata: *Metadata, plan: *const Layout, edge_classes: []const classes.EdgeClass, builder: *ColdBuilder, writer: *format.BundleWriter) !void {
    if (metadata.signs.ways.count() == 0 and metadata.signs.nodes.count() == 0) return;
    const topo = shared.topology;
    var sink: cold_builder.SignSink = .{ .builder = builder, .strings = &metadata.strings };
    defer sink.deinit();
    // Edges are appended first so equal keys retain edge records before
    // node records in the stable geographic sort.
    for (topo.groups, 0..) |group, node| {
        try checkDeadline(shared.deadline, node);
        const first = topo.first_edge[node];
        for (topo.output.data[first..][0..group.real_degree], first..) |edge, slot| {
            if (!edge_classes[edge.cls.class_id].flags.sign) continue;
            const ref = topo.slot_refs.data[slot];
            const seg = shared.segments[ref / 2];
            const way = shared.ways.get(seg.way_id) orelse return error.MissingWayAttributes;
            var source_class = way.by_direction[ref & 1];
            source_class.category.use = edge_classes[edge.cls.class_id].category.use;
            const selection = (try selectEdgeSigns(shared, @intCast(node), seg, ref, source_class)) orelse return error.MissingSignTags;
            sink.cell = grid.snapCell(topo.coordinates[node].toPoint());
            sink.owner = @intCast(slot);
            try selection.write(&sink, shared.deadline);
        }
    }
    for (plan.nodes.items, 0..) |node, i| {
        try checkDeadline(shared.deadline, i);
        const source = metadata.signs.nodes.get(node.osm_id) orelse continue;
        if (!source.named) continue;
        const toll = node.hot.attr.type == @backingInt(graph.constants.NodeType.toll_booth) or
            node.hot.attr.type == @backingInt(graph.constants.NodeType.toll_gantry);
        if (!toll) {
            const admins = shared.admin_index orelse continue;
            const region = (try admins.region(shared.admin_ids.?[node.first_alias])) orelse continue;
            if (!region.attr.allow_intersection_names) continue;
        }
        sink.cell = grid.snapCell(node.point.toPoint());
        const alias_end = node.first_alias + aliasCount(node.degree);
        for (node.first_alias..alias_end) |id| {
            try checkDeadline(shared.deadline, id);
            sink.owner = @intCast(id);
            try sign_build.writeTokens(source.name, if (toll) .toll_name else .junction_name, false, &sink, shared.deadline);
        }
    }
    try sink.write(writer);
}

noinline fn accessForDirections(gpa: Allocator, scratch: *std.ArrayList(access_restriction.Entry), limits: []const access_restriction.Entry, enabled: [2]bool, deadline: io.Deadline) ![]const access_restriction.Entry {
    if (enabled[0] and enabled[1]) return limits;
    if (!enabled[0] and !enabled[1]) return &.{};
    scratch.clearRetainingCapacity();
    for (limits, 0..) |limit, i| {
        try checkDeadline(deadline, i);
        if (!limit.applies(enabled[0])) continue;
        var present = limit;
        present.attr.direction = if (enabled[0]) .forward else .backward;
        try scratch.append(gpa, present);
    }
    return scratch.items;
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
        const radius: f32 = @floatCast(points[i - 2].toPoint().curvatureWith(points[i - 1].toPoint(), points[i].toPoint(), math));
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
