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

const Allocator = std.mem.Allocator;
const max_degree = 32;
const max_workers = 16;

pub const Options = struct {
    scratch_dir: []const u8,
    drive_side: edge_class.DriveSide = .right,
    workers: usize = 0,
    include_construction: bool = false,
    include_platforms: bool = false,
    deadline: io.Deadline = .none,
};

pub const Stats = struct {
    source: edges.Stats,
    nodes: u32,
    directed_edges: u32,
    split_nodes: u32,
    connectors: u32,
    distinct_classes: usize,
    assembly_ns: u64,
};

/// Build the topology, validate it, and write it to the caller's staging
/// bundle. The caller commits the writer after all build stages succeed.
/// Parallel builds require an allocator that supports concurrent use.
pub fn build(gpa: Allocator, source: pbf.file.Stream, writer: *format.BundleWriter, options: Options) !Stats {
    const edge_file = try io.File.temporary(options.scratch_dir);
    defer edge_file.close();
    const shape_file = try io.File.temporary(options.scratch_dir);
    defer shape_file.close();

    var metadata: Metadata = .{ .gpa = gpa, .drive_side = options.drive_side };
    defer metadata.deinit();
    const source_stats = try edges.buildObserved(gpa, source, .{ .edges = edge_file, .shapes = shape_file }, .{
        .scratch_dir = options.scratch_dir,
        .workers = options.workers,
        .include_construction = options.include_construction,
        .include_platforms = options.include_platforms,
        .deadline = options.deadline,
    }, &metadata, Metadata.way, Metadata.node);

    const timer = io.Timer.start();
    if (source_stats.edges > std.math.maxInt(u32) / 2) return error.TooManyDirectedEdges;
    const edge_map = try io.Mapping.mapFd(edge_file, .read_only);
    defer edge_map.unmap();
    const shape_map = try io.Mapping.mapFd(shape_file, .read_only);
    defer shape_map.unmap();
    const segments = try edge_map.slice(edges.Edge, 0, @intCast(source_stats.edges));
    const shape_points = try shape_map.slice(geo.FixedLL, 0, @intCast(source_stats.shape_points));

    var plan = try Layout.plan(gpa, segments, shape_points, &metadata, options.deadline);
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
    var table = try populate(gpa, &shared, options.workers);
    defer table.deinit();
    try validate(topology.first_edge, topology.output.data, topology.coordinates, table.classes, options.deadline);

    try writer.write(.nodes, topology.nodes);
    try writer.write(.edges, topology.output.data);
    try writer.write(.first_edge, topology.first_edge);
    try writer.write(.classes, table.classes);
    try writer.write(.coordinates, topology.coordinates);
    try writer.write(.turns, &.{});
    return .{
        .source = source_stats,
        .nodes = @intCast(topology.nodes.len),
        .directed_edges = @intCast(topology.output.data.len),
        .split_nodes = plan.split_nodes,
        .connectors = plan.connectors,
        .distinct_classes = table.classes.len,
        .assembly_ns = timer.read(),
    };
}

const neutral_node: format.NodeHot = .{
    .turn_off = 0,
    .attr = .{ .access = @bitCast(graph.constants.AccessMask.all_tag_modes), .type = 0, .density = 0, .signal = 0 },
};

const Way = struct {
    by_direction: [2]classes.EdgeClass,
    speeds: [2]u8,
    truck_speed: u8,
    oneway: bool,
};

const Ways = std.AutoHashMapUnmanaged(i64, Way);
const Metadata = struct {
    gpa: Allocator,
    drive_side: edge_class.DriveSide,
    nodes: std.AutoHashMapUnmanaged(i64, format.NodeHot) = .empty,
    ways: Ways = .empty,

    fn deinit(self: *Metadata) void {
        self.nodes.deinit(self.gpa);
        self.ways.deinit(self.gpa);
    }

    fn node(self: *Metadata, id: i64, attrs: tags.NodeAttrs) !void {
        const hot: format.NodeHot = .{
            .turn_off = 0,
            .attr = .{
                .access = @bitCast(attrs.access),
                .type = @backingInt(attrs.type),
                .density = 0,
                .signal = @intFromBool(attrs.flags.traffic_signal),
            },
        };
        if (!std.meta.eql(hot, neutral_node)) try self.nodes.put(self.gpa, id, hot);
    }

    fn way(self: *Metadata, id: i64, attrs: tags.WayAttrs, _: pbf.block.TagIterator) !void {
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
        entry.value_ptr.* = .{
            .by_direction = pair,
            .speeds = .{
                if (attrs.flags.forward_tagged_speed) attrs.forward_speed else attrs.speed,
                if (attrs.flags.backward_tagged_speed) attrs.backward_speed else attrs.speed,
            },
            .truck_speed = attrs.truck_speed,
            .oneway = attrs.flags.oneway,
        };
    }
};

const Node = struct {
    point: geo.FixedLL,
    hot: format.NodeHot,
    degree: u32 = 0,
    first_alias: u32 = 0,
    placed: u32 = 0,
};

const Layout = struct {
    nodes: std.ArrayList(Node) = .empty,
    by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    node_count: u32 = 0,
    split_nodes: u32 = 0,
    connectors: u32 = 0,

    fn plan(gpa: Allocator, segments: []const edges.Edge, points: []const geo.FixedLL, metadata: *const Metadata, deadline: io.Deadline) !Layout {
        var self: Layout = .{};
        errdefer self.deinit(gpa);
        for (segments, 0..) |segment, i| {
            try checkDeadline(deadline, i);
            if (segment.from == segment.to) return error.SelfEdge;
            const shape = try segmentShape(points, segment);
            try self.countNode(gpa, metadata, segment.from, shape[0]);
            try self.countNode(gpa, metadata, segment.to, shape[shape.len - 1]);
        }
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

    fn countNode(self: *Layout, gpa: Allocator, metadata: *const Metadata, id: i64, point: geo.FixedLL) !void {
        const entry = try self.by_id.getOrPut(gpa, id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.math.cast(u32, self.nodes.items.len) orelse return error.TooManyNodes;
            try self.nodes.append(gpa, .{ .point = point, .hot = metadata.nodes.get(id) orelse neutral_node });
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
                edge_class.applySegmentControls(&class, segment.flags, direction == 0, way.oneway);
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
                    .speed = .{ way.speeds[direction], 0, 0, way.truck_speed },
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

    var threads: [max_workers - 1]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (active[0 .. count - 1]) |*job| {
        threads[started] = try std.Thread.spawn(.{}, Job.run, .{job});
        started += 1;
    }
    active[count - 1].run();
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    for (active) |job| try job.result;

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

fn remapEdges(rows: []format.EdgeHot, ids: []const classes.ClassId, deadline: io.Deadline) !void {
    for (rows, 0..) |*row, i| {
        try checkDeadline(deadline, i);
        row.cls.class_id = ids[row.cls.class_id];
    }
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
