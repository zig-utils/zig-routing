//! Immutable mmap reader for the four v1 topology sections.

const std = @import("std");
const live = @import("../traffic/live.zig");
const io = @import("../infra/io.zig");
const format = @import("format.zig");
const class_table = @import("class_table.zig");
const admin = @import("admin.zig");
const timezone = @import("timezone.zig");
const cold = @import("cold.zig");
const spatial = @import("spatial.zig");
const turn_sides = @import("turn_sides.zig");
const restrictions = @import("turn_restrictions.zig");
const automaton = @import("restriction_automaton.zig");
const transit = @import("transit.zig");
const Kind = format.SectionKind;
const Header = format.SectionHeader;
const kinds = std.enums.values(Kind);

pub const Files = std.EnumArray(Kind, ?[]const u8);
const Headers = std.EnumArray(Kind, ?Header);
const Mappings = std.EnumArray(Kind, io.Mapping);

pub const Diagnostic = struct {
    section: ?Kind = null,
};

pub const Bundle = struct {
    mappings: Mappings,
    view: View,
    live_overlay: ?live.Reader = null,

    pub fn open(path: []const u8) !Bundle {
        return openDescribed(path, null);
    }

    /// Check payload integrity before giving the caller a view of the bundle.
    pub fn openVerified(path: []const u8, deadline: io.Deadline, diagnostic: ?*Diagnostic) !Bundle {
        var bundle = try openPath(path, deadline, diagnostic);
        errdefer bundle.close();
        try bundle.view.verify(deadline, diagnostic);
        return bundle;
    }

    pub fn openDescribed(path: []const u8, diagnostic: ?*Diagnostic) !Bundle {
        return openPath(path, .none, diagnostic);
    }

    fn openPath(path: []const u8, deadline: io.Deadline, diagnostic: ?*Diagnostic) !Bundle {
        note(diagnostic, null);
        const dir = try io.Directory.open(path);
        defer dir.close();
        return openDir(dir, deadline, diagnostic);
    }

    pub fn openInDir(dir: io.Directory, diagnostic: ?*Diagnostic) !Bundle {
        return openDir(dir, .none, diagnostic);
    }

    noinline fn openDir(dir: io.Directory, deadline: io.Deadline, diagnostic: ?*Diagnostic) !Bundle {
        var result: Bundle = .{ .mappings = .initFill(.{ .bytes = &.{} }), .view = undefined };
        errdefer result.close();
        var files: Files = .initFill(null);
        for (kinds) |kind| {
            if (deadline.expired()) return error.DeadlineExceeded;
            note(diagnostic, kind);
            const file = dir.readFile(kind.filename()) catch |err| {
                if (err == error.FileNotFound and !format.required_sections.contains(kind)) continue;
                return err;
            };
            defer file.close();
            const mapping = try io.Mapping.mapFd(file, .read_only);
            result.mappings.set(kind, mapping);
            files.set(kind, mapping.bytes);
        }
        result.view = try View.parseWithDeadline(files, diagnostic, deadline);
        if (try live.Reader.open(dir, result.view.dataset_uuid, result.view.edges.len, deadline)) |overlay| {
            result.live_overlay = overlay;
            result.view.live_traffic = overlay.view;
        }
        return result;
    }

    pub noinline fn close(self: *Bundle) void {
        if (self.live_overlay) |overlay| overlay.close();
        for (kinds) |kind| self.mappings.get(kind).unmap();
        self.* = undefined;
    }

    /// Call in the startup worker while the bundle remains mapped.
    pub fn warm(self: *const Bundle, lock_hot: bool, stopping: *const std.atomic.Value(bool)) void {
        for (kinds) |kind| {
            if (stopping.load(.acquire)) return;
            const mapping = self.mappings.get(kind);
            placeMapping(mapping, kind.placement(), lock_hot);
        }
    }

    pub fn residentBytes(self: *const Bundle, kind: Kind, deadline: io.Deadline) !?usize {
        if (self.view.header(kind) == null) return null;
        return try self.mappings.get(kind).residentBytes(deadline);
    }
};

fn placeMapping(mapping: anytype, placement: format.Placement, lock_hot: bool) void {
    switch (placement) {
        .hot => {
            mapping.adviseAll(.huge_page) catch {};
            mapping.adviseAll(.will_need) catch {};
            if (lock_hot) mapping.lock() catch {};
        },
        .cold => mapping.adviseAll(.random) catch {},
        .warm => {},
    }
}

test "placement continues when the IO shim rejects advice and page locks" {
    const Failure = struct {
        advice: std.EnumSet(io.Advice) = .{},
        lock_attempts: u8 = 0,

        fn adviseAll(self: *@This(), advice: io.Advice) error{InvalidArgument}!void {
            self.advice.insert(advice);
            return error.InvalidArgument;
        }

        fn lock(self: *@This()) error{AccessDenied}!void {
            self.lock_attempts += 1;
            return error.AccessDenied;
        }
    };
    var mapping: Failure = .{};
    placeMapping(&mapping, .warm, true);
    try std.testing.expect(mapping.advice.count() == 0 and mapping.lock_attempts == 0);
    placeMapping(&mapping, .cold, true);
    try std.testing.expectEqual(std.EnumSet(io.Advice).initOne(.random), mapping.advice);
    try std.testing.expectEqual(@as(u8, 0), mapping.lock_attempts);
    placeMapping(&mapping, .hot, false);
    try std.testing.expect(mapping.advice.contains(.huge_page) and mapping.advice.contains(.will_need));
    try std.testing.expectEqual(@as(u8, 0), mapping.lock_attempts);
    placeMapping(&mapping, .hot, true);
    try std.testing.expectEqual(@as(u8, 1), mapping.lock_attempts);
}

/// Typed slices borrow the section files. Retrieval checks any payload
/// values used as indices, since opening a bundle reads only the headers.
pub const View = struct {
    headers: Headers,
    dataset_uuid: format.DatasetUuid,
    live_traffic: ?live.View = null,
    nodes: []const format.NodeHot,
    edges: []const format.EdgeHot,
    first_edge: []const format.FirstEdge,
    turns: []const format.TurnEntry,
    classes: ?[]const class_table.EdgeClass,
    coordinates: ?[]const format.Coordinate,
    cold_idx: ?[]const u32,
    cold: ?[]const u8,
    cold_data: ?cold.View,
    slopes: ?[]const u16,
    spatial: ?[]const u8,
    spatial_index: ?spatial.View,
    metadata: ?[]const format.Metadata,
    components: ?[]const u32,
    turn_sides: ?[]const u32,
    turn_side_index: ?turn_sides.View,
    coverage: ?[]const format.Bounds = null,
    admins: ?[]const u8 = null,
    node_admins: ?[]const admin.Id = null,
    admin_index: ?admin.View = null,
    node_timezones: ?[]const timezone.Id = null,
    timezone_rules: ?[]const u8 = null,
    tz_rules: ?timezone.Rules = null,
    turn_restrictions: ?[]const restrictions.Entry = null,
    restriction_automaton: ?[]const automaton.State = null,
    restriction_conditions: ?[]const automaton.Condition = null,
    signs: ?[]const format.SectionKind.signs.Record() = null,
    headings: ?[]const u8 = null,
    lb_speeds: ?[]const u8 = null,
    turnlanes: ?[]const u16 = null,
    lane_connectivity: ?[]const format.SectionKind.lane_connectivity.Record() = null,
    turn_lane_index: ?@import("lanes.zig").Table = null,
    transit_metadata: ?[]const transit.Metadata = null,
    transit_stops: ?[]const transit.Stop = null,
    transit_stations: ?[]const transit.Station = null,
    transit_egresses: ?[]const transit.Egress = null,
    transit_routes: ?[]const transit.Route = null,
    transit_lines: ?[]const transit.Line = null,
    transit_departures: ?[]const transit.Departure = null,
    transit_occurrences: ?[]const transit.Occurrence = null,
    transit_schedules: ?[]const transit.Schedule = null,
    transit_days: ?[]const transit.DayWord = null,
    transit_exceptions: ?[]const transit.Exception = null,
    transit_transfers: ?[]const transit.Transfer = null,
    transit_index: ?transit.View = null,
    edge_keys: ?[]const @import("edge_keys.zig").Record = null,
    edge_key_inverse: ?[]const u32 = null,
    edge_key_hash_header: ?[]const @import("edge_keys.zig").HashHeader = null,
    edge_key_hash_buckets: ?[]const u64 = null,
    edge_key_hash_slots: ?[]const u32 = null,
    edge_key_index: ?@import("edge_keys.zig").View = null,

    pub fn parse(files: Files, diagnostic: ?*Diagnostic) !View {
        return parseWithDeadline(files, diagnostic, .none);
    }

    fn parseWithDeadline(files: Files, diagnostic: ?*Diagnostic, deadline: io.Deadline) !View {
        var headers: Headers = .initFill(null);
        for (kinds) |kind| {
            note(diagnostic, kind);
            const file = files.get(kind) orelse {
                if (format.required_sections.contains(kind)) return error.MissingSection;
                continue;
            };
            headers.set(kind, try readHeader(kind, file));
        }
        const uuid = headers.get(.nodes).?.dataset_uuid;
        for (kinds) |kind| {
            const here = headers.get(kind) orelse continue;
            note(diagnostic, kind);
            if (!std.mem.eql(u8, &here.dataset_uuid, &uuid)) return error.DatasetUuidMismatch;
        }
        const node_count = headers.get(.nodes).?.count;
        const edge_count = headers.get(.edges).?.count;
        if (node_count > std.math.maxInt(u32)) {
            note(diagnostic, .nodes);
            return error.TooManyRecords;
        }
        if (edge_count > std.math.maxInt(u32)) {
            note(diagnostic, .edges);
            return error.TooManyRecords;
        }
        if (headers.get(.first_edge).?.count != node_count + 1) {
            note(diagnostic, .first_edge);
            return error.InvalidCsrCount;
        }
        if (headers.get(.classes)) |classes| {
            if (classes.count > class_table.max_classes) {
                note(diagnostic, .classes);
                return error.TooManyClasses;
            }
        }
        if (headers.get(.coordinates)) |coords| {
            if (coords.count != node_count) {
                note(diagnostic, .coordinates);
                return error.InvalidCoordinateCount;
            }
        }
        const cold_header = headers.get(.cold);
        const cold_index = headers.get(.cold_idx);
        if ((cold_header == null) != (cold_index == null)) {
            note(diagnostic, if (cold_header == null) .cold else .cold_idx);
            return error.MissingSection;
        }
        if (cold_index) |index| {
            if (index.count != edge_count or edge_count % 2 != 0) {
                note(diagnostic, .cold_idx);
                return error.InvalidColdIndexCount;
            }
        }
        if (headers.get(.slopes)) |slopes| {
            if (slopes.count != edge_count) {
                note(diagnostic, .slopes);
                return error.InvalidSlopeCount;
            }
        }
        if (headers.get(.headings)) |headings| {
            if (headings.count != edge_count) {
                note(diagnostic, .headings);
                return error.InvalidHeadingCount;
            }
        }
        if (headers.get(.metadata)) |metadata| {
            if (metadata.count != 1) {
                note(diagnostic, .metadata);
                return error.InvalidMetadataCount;
            }
        }

        if (headers.get(.components)) |components| {
            if (components.count != node_count) {
                note(diagnostic, .components);
                return error.InvalidComponentCount;
            }
        }

        var graph: View = .{
            .headers = headers,
            .dataset_uuid = uuid,
            .nodes = undefined,
            .edges = undefined,
            .first_edge = undefined,
            .turns = undefined,
            .classes = null,
            .coordinates = null,
            .cold_idx = null,
            .cold = null,
            .cold_data = null,
            .slopes = null,
            .spatial = null,
            .spatial_index = null,
            .metadata = null,
            .components = null,
            .turn_sides = null,
            .turn_side_index = null,
        };
        inline for (kinds) |kind| {
            if (headers.get(kind)) |present| {
                note(diagnostic, kind);
                const T = kind.Record();
                const payload = files.get(kind).?[format.payload_offset..];
                // readHeader checked the exact byte count against the record
                // width. Only nonempty payloads require an aligned pointer.
                if (present.count == 0) {
                    @field(graph, @tagName(kind)) = &.{};
                } else {
                    if (!std.mem.isAligned(@intFromPtr(payload.ptr), @alignOf(T))) return error.Misaligned;
                    @field(graph, @tagName(kind)) = std.mem.bytesAsSlice(T, @as([]align(@alignOf(T)) const u8, @alignCast(payload)));
                }
            }
        }
        if (graph.first_edge[0] != 0 or graph.first_edge[graph.first_edge.len - 1] != edge_count) {
            note(diagnostic, .first_edge);
            return error.InvalidCsrEndpoints;
        }
        if (graph.lb_speeds) |bounds| {
            note(diagnostic, .lb_speeds);
            try @import("speed.zig").verifyBounds(graph.edges, bounds, deadline);
        }
        if (graph.cold) |bytes| {
            note(diagnostic, .cold);
            graph.cold_data = try cold.View.parse(bytes);
            if (graph.cold_data.?.header.record_count != edge_count / 2) return error.InvalidColdRecordCount;
        }
        if (graph.signs) |records| {
            note(diagnostic, .signs);
            if (records.len != 0 and (graph.cold_data == null or graph.coordinates == null or graph.classes == null))
                return error.MissingSection;
        }
        if (graph.turnlanes) |words| {
            note(diagnostic, .turnlanes);
            if (graph.classes == null) return error.MissingSection;
            graph.turn_lane_index = try @import("lanes.zig").Table.parse(words);
        }
        if (graph.lane_connectivity != null and graph.classes == null) {
            note(diagnostic, .lane_connectivity);
            return error.MissingSection;
        }
        if (graph.spatial) |bytes| {
            note(diagnostic, .spatial);
            graph.spatial_index = try spatial.View.parse(bytes, @intCast(edge_count));
        }
        if (graph.turn_sides) |words| {
            note(diagnostic, .turn_sides);
            graph.turn_side_index = try turn_sides.View.parse(words, @intCast(node_count));
        }
        if (graph.metadata) |records| {
            note(diagnostic, .metadata);
            if (records[0].reserved != 0 or records[0].ordering() == null) return error.InvalidBundleMetadata;
        }
        if (graph.coverage) |records| {
            note(diagnostic, .coverage);
            if (records.len != 1 or !records[0].valid()) return error.InvalidBundleCoverage;
        }
        if (graph.admins) |bytes| {
            note(diagnostic, .admins);
            graph.admin_index = try admin.View.parse(bytes);
        }
        if (graph.node_admins != null or graph.admin_index != null) {
            note(diagnostic, .node_admins);
            if (graph.admin_index == null or graph.node_admins == null or graph.node_admins.?.len != node_count)
                return error.InvalidNodeAdminCount;
        }
        if (graph.timezone_rules) |bytes| {
            note(diagnostic, .timezone_rules);
            graph.tz_rules = try timezone.Rules.parse(bytes);
        }
        if (graph.node_timezones != null or graph.tz_rules != null) {
            note(diagnostic, .node_timezones);
            if (graph.tz_rules == null or graph.node_timezones == null or graph.node_timezones.?.len != node_count)
                return error.InvalidNodeTimezoneCount;
        }
        if (graph.restriction_automaton) |states| {
            note(diagnostic, .restriction_automaton);
            try automaton.verify(states, graph.edges.len, deadline);
            note(diagnostic, .restriction_conditions);
            try automaton.verifyConditions(states, graph.restriction_conditions orelse &.{}, deadline);
        } else if (graph.restriction_conditions != null) {
            note(diagnostic, .restriction_automaton);
            return error.MissingSection;
        }
        try graph.openTransit(diagnostic);
        try graph.openEdgeKeys(diagnostic);
        note(diagnostic, null);
        return graph;
    }

    fn openEdgeKeys(self: *View, diagnostic: ?*Diagnostic) !void {
        const hash_present = self.edge_key_hash_header != null or self.edge_key_hash_buckets != null or self.edge_key_hash_slots != null;
        if (self.edge_keys == null and self.edge_key_inverse == null and !hash_present) return;
        note(diagnostic, .edge_keys);
        const records = self.edge_keys orelse return error.MissingSection;
        if (records.len != self.edges.len) return error.InvalidEdgeKeyIndex;
        note(diagnostic, .edge_key_inverse);
        const inverse = self.edge_key_inverse orelse return error.MissingSection;
        if (inverse.len != self.edges.len) return error.InvalidEdgeKeyIndex;
        var index: @import("edge_keys.zig").View = .{ .records = records, .inverse = inverse };
        if (hash_present) {
            note(diagnostic, .edge_key_hash_header);
            const hash_header = self.edge_key_hash_header orelse return error.MissingSection;
            if (hash_header.len != 1 or hash_header[0].version != 1 or hash_header[0].reserved != 0) return error.InvalidEdgeKeyHash;
            note(diagnostic, .edge_key_hash_buckets);
            const buckets = self.edge_key_hash_buckets orelse return error.MissingSection;
            if (buckets.len == 0 or buckets.len > records.len) return error.InvalidEdgeKeyHash;
            note(diagnostic, .edge_key_hash_slots);
            const slots = self.edge_key_hash_slots orelse return error.MissingSection;
            if (slots.len != records.len) return error.InvalidEdgeKeyHash;
            index.hash = .{ .seed = hash_header[0].seed, .buckets = buckets, .slots = slots };
        }
        self.edge_key_index = index;
    }

    fn openTransit(self: *View, diagnostic: ?*Diagnostic) !void {
        var present: usize = 0;
        for (format.transit_sections) |kind| {
            if (self.headers.get(kind)) |entry| {
                note(diagnostic, kind);
                if (entry.count > std.math.maxInt(u32)) return error.TooManyRecords;
                present += 1;
            }
        }
        if (present == 0) return;
        if (present != format.transit_sections.len) {
            for (format.transit_sections) |kind| {
                if (self.headers.get(kind) == null) {
                    note(diagnostic, kind);
                    return error.MissingSection;
                }
            }
        }
        note(diagnostic, .cold);
        const strings = self.cold_data orelse return error.MissingSection;
        note(diagnostic, .transit_metadata);
        const metadata = self.transit_metadata.?;
        if (metadata.len != 1 or metadata[0].reserved != 0) return error.InvalidTransitMetadata;
        if (metadata[0].version != transit.section_version) return error.UnsupportedTransitVersion;
        self.transit_index = .{
            .metadata = metadata[0],
            .stops = self.transit_stops.?,
            .stations = self.transit_stations.?,
            .egresses = self.transit_egresses.?,
            .routes = self.transit_routes.?,
            .lines = self.transit_lines.?,
            .departures = self.transit_departures.?,
            .occurrences = self.transit_occurrences.?,
            .schedules = self.transit_schedules.?,
            .days = self.transit_days.?,
            .exceptions = self.transit_exceptions.?,
            .transfers = self.transit_transfers.?,
            .strings = strings,
        };
    }

    pub fn header(self: *const View, kind: Kind) ?Header {
        return self.headers.get(kind);
    }

    pub fn liveTrafficGraph(self: *const View) !live.Graph {
        return .{
            .uuid = self.dataset_uuid,
            .edges = self.edges,
            .classes = self.classes orelse return error.MissingClassTable,
            .bounds = self.lb_speeds,
        };
    }

    pub fn speedOverlays(self: *const View, now: u64, max_age_seconds: u64) live.Overlays {
        return .init(self.live_traffic, now, max_age_seconds);
    }

    pub fn node(self: *const View, id: format.NodeId) error{InvalidNodeId}!*const format.NodeHot {
        const index = @backingInt(id);
        if (index >= self.nodes.len) return error.InvalidNodeId;
        return &self.nodes[index];
    }

    pub fn nodeAdmin(self: *const View, id: format.NodeId) !admin.Names {
        _ = try self.node(id);
        const index = self.admin_index orelse return .{};
        return index.names(self.node_admins.?[@backingInt(id)]);
    }

    pub fn nodeTimezone(self: *const View, id: format.NodeId) !timezone.Id {
        _ = try self.node(id);
        const ids = self.node_timezones orelse return timezone.unknown;
        return ids[@backingInt(id)];
    }

    pub fn adminAt(self: *const View, point: @import("../geo/point.zig").PointLL, deadline: io.Deadline) !admin.Names {
        const index = self.admin_index orelse return .{};
        return index.names(try index.lookup(point, deadline));
    }

    pub fn edge(self: *const View, id: format.EdgeId) error{InvalidEdgeId}!*const format.EdgeHot {
        const index = @backingInt(id);
        if (index >= self.edges.len) return error.InvalidEdgeId;
        return &self.edges[index];
    }

    pub fn class(self: *const View, id: class_table.ClassId) !*const class_table.EdgeClass {
        const classes = self.classes orelse return error.MissingClassSection;
        if (id >= classes.len) return error.InvalidClassId;
        const entry = &classes[id];
        if (!entry.valid()) return error.InvalidEdgeClass;
        return entry;
    }

    pub fn coordinate(self: *const View, id: format.NodeId) !format.Coordinate {
        const coords = self.coordinates orelse return error.MissingCoordinatesSection;
        const index = @backingInt(id);
        if (index >= coords.len) return error.InvalidNodeId;
        const point = coords[index];
        if (!point.inRange()) return error.InvalidCoordinate;
        return point;
    }

    pub const EdgeRange = struct {
        first: u32,
        end: u32,

        pub fn count(self: EdgeRange) u32 {
            return self.end - self.first;
        }
    };

    pub fn outEdgeRange(self: *const View, id: format.NodeId) error{ InvalidNodeId, InvalidCsrRange }!EdgeRange {
        const index: usize = @backingInt(id);
        if (index >= self.nodes.len) return error.InvalidNodeId;
        const range: EdgeRange = .{ .first = self.first_edge[index], .end = self.first_edge[index + 1] };
        if (range.first > range.end or range.end > self.edges.len) return error.InvalidCsrRange;
        if (range.count() > 32) return error.InvalidCsrRange;
        return range;
    }

    pub fn outEdges(self: *const View, id: format.NodeId) ![]const format.EdgeHot {
        const range = try self.outEdgeRange(id);
        return self.edges[range.first..range.end];
    }

    pub fn oppEdge(self: *const View, id: format.EdgeId) !format.EdgeId {
        const original = try self.edge(id);
        const range = try self.outEdgeRange(@fromBackingInt(@intCast(original.head)));
        if (original.cls.opp_local >= range.count()) return error.InvalidOpposingEdge;
        return @fromBackingInt(@intCast(range.first + original.cls.opp_local));
    }

    pub fn component(self: *const View, id: format.NodeId) !u32 {
        _ = try self.node(id);
        const labels = self.components orelse return error.MissingComponents;
        const value = labels[@backingInt(id)];
        if (value > @backingInt(id) or labels[value] != value) return error.InvalidComponentId;
        return value;
    }

    /// Connector arcs occupy the last slots and join adjacent aliases of the
    /// same logical intersection.
    pub fn aliasNeighbor(self: *const View, id: u32, forward: bool) !?u32 {
        const range = try self.outEdgeRange(@fromBackingInt(id));
        const target = if (forward) id +| 1 else id -| 1;
        if (target == id) return null;
        var i = range.end;
        while (i > range.first) {
            i -= 1;
            const arc = try self.edge(@fromBackingInt(i));
            if (!(try self.class(arc.cls.class_id)).flags.node_connector) return null;
            if (arc.head == target) return target;
        }
        return null;
    }

    pub fn turnRow(self: *const View, id: format.NodeId, in_local: u5) ![]const format.TurnEntry {
        const degree = (try self.outEdgeRange(id)).count();
        if (in_local >= degree) return error.InvalidLocalEdge;
        const turn_off: u64 = (try self.node(id)).turn_off;
        const start = turn_off + @as(u64, in_local) * degree;
        const end = start + degree;
        if (end > self.turns.len) return error.InvalidTurnOffset;
        return self.turns[@intCast(start)..@intCast(end)];
    }

    pub fn turnSides(self: *const View, id: format.NodeId, from: u5, to: u5) !turn_sides.Sides {
        const degree = (try self.outEdgeRange(id)).count();
        if (from >= degree or to >= degree) return error.InvalidLocalEdge;
        const index = self.turn_side_index orelse return .{};
        return index.at(@backingInt(id), degree, from, to);
    }

    pub fn turnRestrictionModes(self: *const View, incoming: format.EdgeId, outgoing: format.EdgeId) u16 {
        const entries = self.turn_restrictions orelse return 0;
        return restrictions.modes(entries, @backingInt(incoming), @backingInt(outgoing));
    }

    pub fn coldRecord(self: *const View, id: format.EdgeId) !cold.Record {
        return self.coldRecordWithDeadline(id, .none);
    }

    pub fn coldRecordWithDeadline(self: *const View, id: format.EdgeId, deadline: io.Deadline) !cold.Record {
        _ = try self.edge(id);
        const table = self.cold_data orelse return error.MissingColdData;
        return table.recordWithDeadline(self.cold_idx.?[@backingInt(id)], deadline);
    }

    pub fn edgeSlopes(self: *const View, id: format.EdgeId) !format.Slopes {
        _ = try self.edge(id);
        const slopes = self.slopes orelse return format.Slopes.flat;
        const value = slopes[@backingInt(id)];
        if (value >> 10 != 0) return error.InvalidSlopes;
        return .{ .code = value };
    }

    pub fn lbSpeed(self: *const View, id: format.EdgeId) !u8 {
        const hot = try self.edge(id);
        if (self.lb_speeds) |bounds| return bounds[@backingInt(id)];
        return @import("speed.zig").upperBound(hot.*);
    }

    pub fn wayId(self: *const View, id: format.EdgeId) !u64 {
        return (try self.coldRecord(id)).wayId();
    }

    pub fn names(self: *const View, id: format.EdgeId) !cold.Names {
        return self.namesWithOptions(id, .{});
    }

    pub fn namesWithOptions(self: *const View, id: format.EdgeId, options: cold.Names.Options) !cold.Names {
        return (try self.coldRecordWithDeadline(id, options.deadline)).names(self.cold_data.?, options);
    }

    pub fn shape(self: *const View, id: format.EdgeId, arena: std.mem.Allocator) ![]format.Coordinate {
        return self.shapeWithDeadline(id, arena, .none);
    }

    pub fn shapeWithDeadline(self: *const View, id: format.EdgeId, arena: std.mem.Allocator, deadline: io.Deadline) ![]format.Coordinate {
        return (try self.coldRecordWithDeadline(id, deadline)).shape(arena, deadline);
    }

    pub fn verify(self: *const View, deadline: io.Deadline, diagnostic: ?*Diagnostic) !void {
        for (kinds) |kind| {
            const entry = self.header(kind) orelse continue;
            note(diagnostic, kind);
            if (deadline.expired()) return error.DeadlineExceeded;
            const bytes: []const u8 = switch (kind) {
                inline else => |section| blk: {
                    const data = @field(self, @tagName(section));
                    break :blk std.mem.sliceAsBytes(if (@typeInfo(@TypeOf(data)) == .optional) data.? else data);
                },
            };
            var hash = std.hash.XxHash3.init(0);
            var rest = bytes;
            while (rest.len != 0) {
                if (deadline.expired()) return error.DeadlineExceeded;
                const chunk = rest[0..@min(rest.len, 1024 * 1024)];
                io.updateFileHash(&hash, chunk);
                rest = rest[chunk.len..];
            }
            if (hash.final() != entry.payload_hash) return error.PayloadHashMismatch;
        }
        note(diagnostic, .signs);
        try @import("signs.zig").verify(self, deadline);
        note(diagnostic, .turnlanes);
        try @import("lanes.zig").verifyTurns(self, deadline);
        note(diagnostic, .lane_connectivity);
        try @import("lanes.zig").verifyConnectivity(self, deadline);
        if (self.admin_index) |index| {
            note(diagnostic, .admins);
            try index.verify(deadline);
            note(diagnostic, .node_admins);
            for (self.node_admins.?, 0..) |id, i| {
                if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                _ = try index.names(id);
            }
        }
        if (self.tz_rules) |rules| {
            note(diagnostic, .timezone_rules);
            try rules.verify(deadline);
            note(diagnostic, .node_timezones);
            for (self.node_timezones.?, 0..) |id, i| {
                if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (id != timezone.unknown and try rules.name(id) == null) return error.InvalidNodeTimezone;
            }
        }
        if (self.turn_restrictions) |entries| {
            note(diagnostic, .turn_restrictions);
            var previous: ?u64 = null;
            for (entries, 0..) |entry, i| {
                if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const key = entry.key();
                if (entry.incoming >= self.edges.len or entry.outgoing >= self.edges.len or
                    entry.attr.modes == 0 or entry.attr.modes & 0xf800 != 0 or entry.attr.reserved != 0 or
                    (previous != null and key <= previous.?))
                    return error.InvalidTurnRestrictions;
                const via = try self.node(@fromBackingInt(self.edges[entry.incoming].head));
                if (!via.attr.has_turn_restrictions) return error.InvalidTurnRestrictions;
                previous = key;
            }
        }
        if (self.transit_index) |index| {
            note(diagnostic, .transit_metadata);
            try index.verify(self.nodes.len, deadline);
        }
        if (self.edge_key_index) |index| {
            note(diagnostic, .edge_keys);
            try index.verify(self.edges.len, deadline);
        }
        note(diagnostic, null);
    }
};

fn note(diagnostic: ?*Diagnostic, section: ?Kind) void {
    if (diagnostic) |out| out.section = section;
}

fn readHeader(kind: Kind, bytes: []const u8) !Header {
    if (bytes.len < @sizeOf(Header)) return error.TruncatedHeader;
    const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &header.magic_tag, &format.magic)) return error.InvalidMagic;
    if (header.format_version != format.version) return error.UnsupportedFormatVersion;
    if (header.kind != @backingInt(kind)) return error.InvalidSectionKind;
    if (header.record_size != kind.recordSize()) return error.InvalidRecordSize;
    if (header.reserved != 0 or !std.mem.allEqual(u8, &header.reserved_tail, 0)) return error.InvalidReservedBytes;

    const payload_size = std.math.mul(u64, header.count, header.record_size) catch return error.SectionSizeOverflow;
    const size = std.math.add(u64, format.payload_offset, payload_size) catch return error.SectionSizeOverflow;
    if (size > bytes.len) return error.TruncatedSection;
    if (size < bytes.len) return error.TrailingSectionData;
    return header;
}
