// Ported from src/mjolnir/pbfadminparser.cc and src/mjolnir/adminbuilder.cc
// (Valhalla 3.9.3). Boundary geometry comes from ordinary OSM relations.
const std = @import("std");
const pbf = @import("pbf/root.zig");
const io = @import("../infra/io.zig");
const polygon = @import("../geo/polygon.zig");
const point = @import("../geo/point.zig");
const tags = @import("admin_tags.zig");
const turns = @import("turn_restrictions.zig");
const lanes = @import("lanes.zig");
const Allocator = std.mem.Allocator;

pub const Boundary = struct {
    osm_id: i64,
    attrs: tags.Attributes,
    geometry: polygon.MultiPolygon,
};

pub const Catalog = struct {
    regions: []Boundary,
    storage: std.heap.ArenaAllocator,

    pub fn deinit(self: *Catalog) void {
        for (self.regions) |*region| region.geometry.deinit();
        self.storage.deinit();
    }
};

/// Read relations, resolve their way members, then acquire only the nodes
/// referenced by those ways. The stream can represent multiple extracts.
pub fn collect(gpa: Allocator, source: anytype, deadline: io.Deadline) !Catalog {
    return collectRelations(gpa, source, deadline, true, null, null);
}

pub fn collectRelations(gpa: Allocator, source: anytype, deadline: io.Deadline, boundaries: bool, restrictions: ?*turns.Catalog, connections: ?*lanes.Catalog) !Catalog {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var storage: std.heap.ArenaAllocator = .init(gpa);
    errdefer storage.deinit();
    const owned = storage.allocator();
    var collector: Collector = .{
        .a = scratch.allocator(),
        .owned = owned,
        .gpa = gpa,
        .deadline = deadline,
        .boundaries = boundaries,
        .restrictions = restrictions,
        .connections = connections,
    };
    defer collector.block.deinit(gpa);
    try source.forEach(gpa, deadline, &collector, Collector.visit);
    if (collector.relations.items.len == 0) return .{
        .regions = &.{},
        .storage = storage,
    };
    collector.phase = .ways;
    try source.forEach(gpa, deadline, &collector, Collector.visit);
    if (collector.nodes.count() != 0) {
        collector.phase = .nodes;
        try source.forEach(gpa, deadline, &collector, Collector.visit);
    }
    try collector.resolveWays();

    var regions: std.ArrayList(Boundary) = .empty;
    errdefer for (regions.items) |*region| region.geometry.deinit();
    var fragments: std.ArrayList(polygon.Fragment) = .empty;
    defer fragments.deinit(gpa);
    next_relation: for (collector.relations.items) |relation| {
        if (deadline.expired()) return error.DeadlineExceeded;
        fragments.clearRetainingCapacity();
        for (relation.members, 0..) |member, i| {
            try checkAt(deadline, i);
            const line = collector.ways.get(member.way_id).?.points orelse continue :next_relation;
            try fragments.append(gpa, .{ .points = line, .role = member.role });
        }
        var geometry = try polygon.assemble(gpa, fragments.items, deadline);
        errdefer geometry.deinit();
        if (geometry.polygons.len == 0) {
            geometry.deinit();
            continue;
        }
        try regions.append(owned, .{ .osm_id = relation.id, .attrs = relation.attrs, .geometry = geometry });
    }
    return .{ .regions = regions.items, .storage = storage };
}

const Member = struct { way_id: i64, role: polygon.Role };
const Relation = struct { id: i64, attrs: tags.Attributes, members: []const Member };
const Way = struct { nodes: ?[]const i64 = null, points: ?[]const point.PointLL = null };

const Collector = struct {
    a: Allocator,
    owned: Allocator,
    gpa: Allocator,
    deadline: io.Deadline,
    boundaries: bool,
    restrictions: ?*turns.Catalog,
    connections: ?*lanes.Catalog,
    phase: enum { relations, ways, nodes } = .relations,
    block: pbf.block.Scratch = .{},
    relations: std.ArrayList(Relation) = .empty,
    relation_ids: std.AutoHashMapUnmanaged(i64, void) = .empty,
    ways: std.AutoHashMapUnmanaged(i64, Way) = .empty,
    nodes: std.AutoHashMapUnmanaged(i64, ?point.FixedLL) = .empty,

    fn visit(self: *Collector, _: usize, bytes: []const u8) !void {
        const block = try self.block.decode(self.gpa, bytes, self.deadline);
        return switch (self.phase) {
            .relations => self.readRelations(block),
            .ways => self.readWays(block),
            .nodes => self.readNodes(block),
        };
    }

    fn readRelations(self: *Collector, block: pbf.block.Block) !void {
        var entries = block.relations();
        while (try entries.next()) |relation| {
            if (self.restrictions) |present| try present.add(relation);
            if (self.connections) |present| try present.addRelation(relation);
            if (!self.boundaries) continue;
            if (self.relation_ids.contains(relation.id)) continue;
            var attrs = try tags.transform(relation.tags, self.deadline) orelse continue;
            var members: std.ArrayList(Member) = .empty;
            var refs = relation.members;
            while (try refs.next()) |member| {
                if (member.type != .way) continue;
                const way = try self.ways.getOrPut(self.a, member.ref);
                if (!way.found_existing) way.value_ptr.* = .{};
                try members.append(self.a, .{
                    .way_id = member.ref,
                    .role = if (std.mem.eql(u8, member.role, "inner")) .inner else .outer,
                });
            }
            if (members.items.len == 0) continue;
            try self.relation_ids.put(self.a, relation.id, {});
            attrs.name = try self.owned.dupe(u8, attrs.name);
            attrs.english_name = try self.owned.dupe(u8, attrs.english_name);
            attrs.iso_code = try self.owned.dupe(u8, attrs.iso_code);
            attrs.default_language = try self.owned.dupe(u8, attrs.default_language);
            try self.relations.append(self.a, .{ .id = relation.id, .attrs = attrs, .members = members.items });
        }
    }

    fn readWays(self: *Collector, block: pbf.block.Block) !void {
        var entries = block.ways();
        while (try entries.next()) |way| {
            const target = self.ways.getPtr(way.id) orelse continue;
            if (target.nodes != null) continue;
            var nodes: std.ArrayList(i64) = .empty;
            var refs = way.refs;
            while (try refs.next()) |id| {
                const node = try self.nodes.getOrPut(self.a, id);
                if (!node.found_existing) node.value_ptr.* = null;
                try nodes.append(self.a, id);
            }
            target.nodes = nodes.items;
        }
    }

    fn readNodes(self: *Collector, block: pbf.block.Block) !void {
        var entries = block.nodes();
        while (try entries.next()) |node| {
            const target = self.nodes.getPtr(node.id) orelse continue;
            if (target.* == null) target.* = .{ .lng = node.lon, .lat = node.lat };
        }
    }

    fn resolveWays(self: *Collector) !void {
        var ways = self.ways.valueIterator();
        var i: usize = 0;
        next_way: while (ways.next()) |way| : (i += 1) {
            try checkAt(self.deadline, i);
            const nodes = way.nodes orelse continue;
            const points = try self.a.alloc(point.PointLL, nodes.len);
            for (nodes, points, 0..) |id, *out, j| {
                try checkAt(self.deadline, j);
                const fixed = self.nodes.get(id).? orelse {
                    self.a.free(points);
                    continue :next_way;
                };
                out.* = fixed.toPoint();
            }
            way.points = points;
        }
    }
};

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}
