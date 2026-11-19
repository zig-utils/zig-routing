//! Immutable mmap reader for the four v1 topology sections.

const std = @import("std");
const io = @import("../infra/io.zig");
const format = @import("format.zig");
const class_table = @import("class_table.zig");
const cold = @import("cold.zig");
const spatial = @import("spatial.zig");
const turn_sides = @import("turn_sides.zig");
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

    pub fn open(path: []const u8) !Bundle {
        return openDescribed(path, null);
    }

    /// Check payload integrity before giving the caller a view of the bundle.
    pub fn openVerified(path: []const u8, deadline: io.Deadline, diagnostic: ?*Diagnostic) !Bundle {
        var bundle = try openDescribed(path, diagnostic);
        errdefer bundle.close();
        try bundle.view.verify(deadline, diagnostic);
        return bundle;
    }

    pub fn openDescribed(path: []const u8, diagnostic: ?*Diagnostic) !Bundle {
        note(diagnostic, null);
        const dir = try io.Directory.open(path);
        defer dir.close();
        var result: Bundle = .{ .mappings = .initFill(.{ .bytes = &.{} }), .view = undefined };
        errdefer result.close();
        var files: Files = .initFill(null);
        for (kinds) |kind| {
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
        result.view = try View.parse(files, diagnostic);
        return result;
    }

    pub fn close(self: *Bundle) void {
        for (kinds) |kind| self.mappings.get(kind).unmap();
        self.* = undefined;
    }
};

/// Typed slices borrow the section files. Retrieval checks any payload
/// values used as indices, since opening a bundle reads only the headers.
pub const View = struct {
    headers: Headers,
    dataset_uuid: format.DatasetUuid,
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

    pub fn parse(files: Files, diagnostic: ?*Diagnostic) !View {
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
                const count: usize = @intCast(present.count);
                @field(graph, @tagName(kind)) = try io.typedSlice(kind.Record(), files.get(kind).?, format.payload_offset, count);
            }
        }
        if (graph.first_edge[0] != 0 or graph.first_edge[graph.first_edge.len - 1] != edge_count) {
            note(diagnostic, .first_edge);
            return error.InvalidCsrEndpoints;
        }
        if (graph.cold) |bytes| {
            note(diagnostic, .cold);
            graph.cold_data = try cold.View.parse(bytes);
            if (graph.cold_data.?.header.record_count != edge_count / 2) return error.InvalidColdRecordCount;
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
        note(diagnostic, null);
        return graph;
    }

    pub fn header(self: *const View, kind: Kind) ?Header {
        return self.headers.get(kind);
    }

    pub fn node(self: *const View, id: format.NodeId) error{InvalidNodeId}!*const format.NodeHot {
        const index = @backingInt(id);
        if (index >= self.nodes.len) return error.InvalidNodeId;
        return &self.nodes[index];
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

    pub fn coldRecord(self: *const View, id: format.EdgeId) !cold.Record {
        _ = try self.edge(id);
        const table = self.cold_data orelse return error.MissingColdData;
        return table.record(self.cold_idx.?[@backingInt(id)]);
    }

    pub fn edgeSlopes(self: *const View, id: format.EdgeId) !format.Slopes {
        _ = try self.edge(id);
        const slopes = self.slopes orelse return format.Slopes.flat;
        const value = slopes[@backingInt(id)];
        if (value >> 10 != 0) return error.InvalidSlopes;
        return .{ .code = value };
    }

    pub fn wayId(self: *const View, id: format.EdgeId) !u64 {
        return (try self.coldRecord(id)).wayId();
    }

    pub fn names(self: *const View, id: format.EdgeId) !cold.Names {
        return (try self.coldRecord(id)).names(self.cold_data.?);
    }

    pub fn shape(self: *const View, id: format.EdgeId, arena: std.mem.Allocator) ![]format.Coordinate {
        return self.shapeWithDeadline(id, arena, .none);
    }

    pub fn shapeWithDeadline(self: *const View, id: format.EdgeId, arena: std.mem.Allocator, deadline: io.Deadline) ![]format.Coordinate {
        return (try self.coldRecord(id)).shape(arena, deadline);
    }

    pub fn verify(self: *const View, deadline: io.Deadline, diagnostic: ?*Diagnostic) !void {
        for (kinds) |kind| {
            const entry = self.header(kind) orelse continue;
            note(diagnostic, kind);
            if (deadline.expired()) return error.DeadlineExceeded;
            const bytes: []const u8 = switch (kind) {
                inline .classes, .coordinates, .cold_idx, .cold, .slopes, .spatial, .metadata, .components, .turn_sides => |section| std.mem.sliceAsBytes(@field(self, @tagName(section)).?),
                inline else => |section| std.mem.sliceAsBytes(@field(self, @tagName(section))),
            };
            var hash = std.hash.XxHash3.init(0);
            var rest = bytes;
            while (rest.len != 0) {
                if (deadline.expired()) return error.DeadlineExceeded;
                const chunk = rest[0..@min(rest.len, 1024 * 1024)];
                hash.update(chunk);
                rest = rest[chunk.len..];
            }
            if (hash.final() != entry.payload_hash) return error.PayloadHashMismatch;
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
