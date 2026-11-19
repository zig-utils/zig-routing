// Ported from test/gurka/gurka.h and test/gurka/gurka.cc (Valhalla 3.9.3).

const std = @import("std");
const routing = @import("routing");
const coordinates = routing.geo.constants;
const pbf = @import("pbf.zig");
const Allocator = std.mem.Allocator;
const Point = routing.geo.PointLL;
const Api = routing.api.proto.Api;

pub const NodeLayout = struct {
    points: [128]?Point = @splat(null),

    pub fn get(self: *const NodeLayout, label: []const u8) ?Point {
        if (label.len != 1 or !std.ascii.isAlphanumeric(label[0])) return null;
        return self.points[label[0]];
    }
};

pub fn mapToCoordinates(ascii: []const u8, grid_size_m: f64) !NodeLayout {
    return mapToCoordinatesAt(ascii, grid_size_m, .{ .lng = 0, .lat = 0 });
}

pub fn mapToCoordinatesAt(ascii: []const u8, grid_size_m: f64, top_left: Point) !NodeLayout {
    if (!std.math.isFinite(grid_size_m)) return error.InvalidGridSize;
    var layout: NodeLayout = .{};
    var lines = std.mem.splitScalar(u8, ascii, '\n');
    var indent: usize = std.math.maxInt(usize);
    var content_start: usize = ascii.len;
    var start: usize = 0;
    while (lines.next()) |line| {
        const content = std.mem.trimStart(u8, line, &std.ascii.whitespace);
        if (content.len != 0) {
            content_start = @min(content_start, start);
            indent = @min(indent, line.len - content.len);
        }
        start += line.len + 1;
    }
    if (indent == std.math.maxInt(usize)) return layout;
    lines = std.mem.splitScalar(u8, ascii[content_start..], '\n');
    // Gurka uses the float radius from constants.h in both projections.
    const radius: f64 = coordinates.rad_earth_meters;
    var row: usize = 0;
    while (lines.next()) |line| : (row += 1) {
        if (line.len < indent) continue;
        const y = @as(f64, @floatFromInt(row)) * grid_size_m;
        const south = (2 * std.math.atan(@exp(y / radius)) - coordinates.pi_over_2_d) * coordinates.deg_per_rad_d;
        for (line[indent..], 0..) |label, col| {
            if (!std.ascii.isAlphanumeric(label)) continue;
            if (layout.points[label] != null) return error.DuplicateNodeLabel;
            const x = @as(f64, @floatFromInt(col)) * grid_size_m;
            layout.points[label] = .{ .lng = top_left.lng + (x / radius) * coordinates.deg_per_rad_d, .lat = top_left.lat - south };
        }
    }
    return layout;
}

pub const Tag = struct { key: []const u8, value: []const u8 };
pub const Tags = []const Tag;

pub fn tagValue(tags: Tags, key: []const u8) ?[]const u8 {
    for (tags) |tag| {
        if (std.mem.eql(u8, tag.key, key)) return tag.value;
    }
    return null;
}

/// Way labels list their nodes in order, e.g. "ABCD". A node label is one character.
pub const Way = struct { label: []const u8, tags: Tags = &.{} };
pub const Node = struct { label: []const u8, tags: Tags = &.{} };
pub const MemberKind = enum(i32) { node, way };
pub const Member = struct { kind: MemberKind, ref: []const u8, role: []const u8 };
pub const Relation = struct { members: []const Member, tags: Tags = &.{} };

pub const OsmNode = struct { id: i64, label: []const u8, location: Point, tags: Tags };
pub const OsmWay = struct { id: i64, label: []const u8, refs: []const i64, tags: Tags };
pub const OsmMember = struct { kind: MemberKind, id: i64, role: []const u8 };
pub const OsmRelation = struct { id: i64, members: []const OsmMember, tags: Tags };
pub const Dataset = struct {
    nodes: []const OsmNode,
    ways: []const OsmWay,
    relations: []const OsmRelation,

    pub fn writePbf(self: Dataset, gpa: Allocator, path: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const bytes = try pbf.encode(arena.allocator(), self);
        try routing.infra.io.writeFile(path, bytes);
    }
};

pub const Map = struct {
    layout: NodeLayout,
    osm: Dataset,

    /// The fixture arena owns the entities and synthesized names. Input labels
    /// and tag strings must outlive the fixture.
    pub fn init(arena: Allocator, layout: NodeLayout, ways: []const Way, nodes: []const Node, relations: []const Relation) !Map {
        return .{ .layout = layout, .osm = try makeDataset(arena, &layout, ways, nodes, relations) };
    }

    pub fn build(_: *Map) error{NotImplemented}!void {
        return error.NotImplemented;
    }

    pub fn doAction(_: *const Map, _: routing.api.request.Action, _: []const []const u8, _: routing.api.request.Costing) error{NotImplemented}!Api.View {
        return error.NotImplemented;
    }

    pub fn findWay(self: *const Map, label: []const u8) ?*const OsmWay {
        for (self.osm.ways) |*way| {
            if (std.mem.eql(u8, way.label, label)) return way;
        }
        return null;
    }

    pub fn findNode(self: *const Map, label: []const u8) ?*const OsmNode {
        for (self.osm.nodes) |*node| {
            if (std.mem.eql(u8, node.label, label)) return node;
        }
        return null;
    }
};

pub fn expectPath(_: Api.View, _: []const []const u8) error{NotImplemented}!void {
    return error.NotImplemented;
}

pub fn expectManeuvers(_: Api.View, _: []const routing.api.proto.directions.DirectionsLeg_Maneuver_Type) error{NotImplemented}!void {
    return error.NotImplemented;
}

pub fn expectSteps(_: Api.View, _: []const []const u8, _: bool) error{NotImplemented}!void {
    return error.NotImplemented;
}

fn namedTags(arena: Allocator, label: []const u8, tags: Tags) !Tags {
    if (tagValue(tags, "name") != null) return tags;
    const named = try arena.alloc(Tag, tags.len + 1);
    named[0] = .{ .key = "name", .value = label };
    @memcpy(named[1..], tags);
    return named;
}

const IdSet = std.AutoHashMapUnmanaged(i64, void);

fn explicitId(tags: Tags) !?i64 {
    const value = tagValue(tags, "osm_id") orelse return null;
    const id = std.fmt.parseInt(i64, value, 10) catch return error.InvalidOsmId;
    if (id <= 0) return error.InvalidOsmId;
    return id;
}

fn reserveId(arena: Allocator, reserved: *IdSet, tags: Tags) !void {
    if (try explicitId(tags)) |id| {
        const entry = try reserved.getOrPut(arena, id);
        if (entry.found_existing) return error.DuplicateOsmId;
    }
}

fn assignId(counter: *i64, reserved: *const IdSet, tags: Tags) !i64 {
    if (try explicitId(tags)) |id| return id;
    while (true) {
        counter.* += 1;
        if (!reserved.contains(counter.*)) return counter.*;
    }
}

fn wayOrder(_: void, a: Way, b: Way) bool {
    return std.mem.order(u8, a.label, b.label) == .lt;
}

fn nodeOrder(_: void, a: OsmNode, b: OsmNode) bool {
    return a.id < b.id;
}

fn osmWayOrder(_: void, a: OsmWay, b: OsmWay) bool {
    return a.id < b.id;
}

fn makeDataset(arena: Allocator, layout: *const NodeLayout, ways: []const Way, nodes: []const Node, relations: []const Relation) !Dataset {
    var used: std.StaticBitSet(128) = .empty;
    var tags_by_node: [128]?Tags = @splat(null);
    var reserved_nodes: IdSet = .empty;
    var reserved_ways: IdSet = .empty;
    for (nodes) |node| {
        _ = layout.get(node.label) orelse return error.UnknownNode;
        const label = node.label[0];
        if (tags_by_node[label] != null) return error.DuplicateNodeLabel;
        tags_by_node[label] = node.tags;
        used.set(label);
        try reserveId(arena, &reserved_nodes, node.tags);
    }
    const sorted = try arena.dupe(Way, ways);
    std.mem.sort(Way, sorted, {}, wayOrder);
    for (sorted, 0..) |way, index| {
        if (way.label.len < 2) return error.InvalidWay;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].label, way.label)) return error.DuplicateWayLabel;
        for (way.label) |label| {
            _ = layout.get(&.{label}) orelse return error.UnknownNode;
            used.set(label);
        }
        try reserveId(arena, &reserved_ways, way.tags);
    }
    for (relations) |relation| {
        for (relation.members) |member| {
            if (member.kind != .node) continue;
            _ = layout.get(member.ref) orelse return error.UnknownNode;
            used.set(member.ref[0]);
        }
    }

    var next_id: i64 = 0;
    const osm_nodes = try arena.alloc(OsmNode, used.count());
    var node_ids: [128]i64 = undefined;
    var used_it = used.iterator(.{});
    for (osm_nodes) |*node| {
        const label = used_it.next().?;
        node.label = try arena.dupe(u8, &.{@intCast(label)});
        node.location = layout.points[label].?;
        const tags = tags_by_node[label] orelse &.{};
        node.tags = try namedTags(arena, node.label, tags);
        node.id = try assignId(&next_id, &reserved_nodes, tags);
        node_ids[label] = node.id;
    }
    std.mem.sort(OsmNode, osm_nodes, {}, nodeOrder);

    const osm_ways = try arena.alloc(OsmWay, sorted.len);
    var way_ids: std.StringHashMapUnmanaged(i64) = .empty;
    for (osm_ways, sorted) |*way, spec| {
        const refs = try arena.alloc(i64, spec.label.len);
        for (refs, spec.label) |*id, label| id.* = node_ids[label];
        way.* = .{
            .id = try assignId(&next_id, &reserved_ways, spec.tags),
            .label = spec.label,
            .refs = refs,
            .tags = try namedTags(arena, spec.label, spec.tags),
        };
        try way_ids.put(arena, way.label, way.id);
    }
    std.mem.sort(OsmWay, osm_ways, {}, osmWayOrder);

    const osm_relations = try arena.alloc(OsmRelation, relations.len);
    for (osm_relations, relations) |*rel, spec| {
        const members = try arena.alloc(OsmMember, spec.members.len);
        for (members, spec.members) |*osm_member, member| {
            osm_member.* = .{
                .kind = member.kind,
                .role = member.role,
                .id = switch (member.kind) {
                    .node => node_ids[member.ref[0]],
                    .way => way_ids.get(member.ref) orelse return error.UnknownWay,
                },
            };
        }
        rel.* = .{ .id = @max(1, next_id), .members = members, .tags = spec.tags };
        next_id = rel.id + 1;
    }
    return .{ .nodes = osm_nodes, .ways = osm_ways, .relations = osm_relations };
}

test "ASCII coordinates captured from the Valhalla 3.9.3 Gurka function" {
    // Preserve the blank row between the roads in the reference grid.
    const layout = try mapToCoordinatesAt(
        \\
        \\        A---B\
        \\
        \\        C---D/ E
        \\            1
    , 17.25, .{ .lng = 5.1079374, .lat = 52.0887174 });
    const expected = [_]struct { label: []const u8, lon: f64, lat: f64 }{
        .{ .label = "1", .lon = 5.1085572353108741, .lat = 52.08825252351685 },
        .{ .label = "A", .lon = 5.1079374, .lat = 52.0887174 },
        .{ .label = "B", .lon = 5.1085572353108741, .lat = 52.0887174 },
        .{ .label = "C", .lon = 5.1079374, .lat = 52.088407482344572 },
        .{ .label = "D", .lon = 5.1085572353108741, .lat = 52.088407482344572 },
        .{ .label = "E", .lon = 5.1090221117940287, .lat = 52.088407482344572 },
    };
    for (expected) |entry| {
        const point = layout.get(entry.label).?;
        try std.testing.expectEqual(entry.lon, point.lng);
        try std.testing.expectEqual(entry.lat, point.lat);
    }
    try std.testing.expectEqual(null, (try mapToCoordinates(" \n\t", 10)).get("A"));
    try std.testing.expectError(error.DuplicateNodeLabel, mapToCoordinates("A-A", 10));
}
