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

pub const Boundary = BoundaryFor(RoutingPolicy);
pub const Catalog = CatalogFor(RoutingPolicy);

fn BoundaryFor(comptime Policy: type) type {
    return struct {
        osm_id: i64,
        attrs: Policy.Attributes,
        geometry: polygon.MultiPolygon,
    };
}

pub fn CatalogFor(comptime Policy: type) type {
    return struct {
        regions: []BoundaryFor(Policy),
        max_relation_changeset: u64,
        storage: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            for (self.regions) |*region| region.geometry.deinit();
            self.storage.deinit();
        }
    };
}

const RoutingPolicy = struct {
    const Attributes = tags.Attributes;

    fn read(owned: Allocator, relation: pbf.block.Relation, deadline: io.Deadline) !?Attributes {
        var attrs = try tags.transform(relation.tags, deadline) orelse return null;
        attrs.name = try owned.dupe(u8, attrs.name);
        attrs.english_name = try owned.dupe(u8, attrs.english_name);
        attrs.iso_code = try owned.dupe(u8, attrs.iso_code);
        attrs.default_language = try owned.dupe(u8, attrs.default_language);
        return attrs;
    }

    fn wayRole(role: []const u8) ?polygon.Role {
        return if (std.mem.eql(u8, role, "inner")) .inner else .outer;
    }
};

/// Read relations, resolve their way members, then acquire only the nodes
/// referenced by those ways. The stream can represent multiple extracts.
pub fn collect(gpa: Allocator, source: anytype, deadline: io.Deadline) !Catalog {
    return collectRelations(gpa, source, deadline, true, null, null);
}

pub fn collectRelations(gpa: Allocator, source: anytype, deadline: io.Deadline, boundaries: bool, restrictions: ?*turns.Catalog, connections: ?*lanes.Catalog) !Catalog {
    return collectWith(RoutingPolicy, gpa, source, deadline, boundaries, restrictions, connections);
}

pub fn collectBoundaries(comptime Policy: type, gpa: Allocator, source: anytype, deadline: io.Deadline) !CatalogFor(Policy) {
    return collectWith(Policy, gpa, source, deadline, true, null, null);
}

pub fn polygonRole(value: []const u8) ?polygon.Role {
    if (std.mem.eql(u8, value, "inner")) return .inner;
    if (value.len == 0 or std.mem.eql(u8, value, "outer")) return .outer;
    return null;
}

fn collectWith(comptime Policy: type, gpa: Allocator, source: anytype, deadline: io.Deadline, boundaries: bool, restrictions: ?*turns.Catalog, connections: ?*lanes.Catalog) !CatalogFor(Policy) {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var storage: std.heap.ArenaAllocator = .init(gpa);
    errdefer storage.deinit();
    const owned = storage.allocator();
    const Collector = CollectorFor(Policy);
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
        .max_relation_changeset = collector.max_relation_changeset,
        .storage = storage,
    };
    collector.phase = .ways;
    try source.forEach(gpa, deadline, &collector, Collector.visit);
    if (collector.nodes.count() != 0) {
        collector.phase = .nodes;
        try source.forEach(gpa, deadline, &collector, Collector.visit);
    }
    try collector.resolveWays();

    var regions: std.ArrayList(BoundaryFor(Policy)) = .empty;
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
    return .{ .regions = regions.items, .max_relation_changeset = collector.max_relation_changeset, .storage = storage };
}

const Member = struct { way_id: i64, role: polygon.Role };
const Way = struct { nodes: ?[]const i64 = null, points: ?[]const point.PointLL = null };

fn CollectorFor(comptime Policy: type) type {
    return struct {
        const Collector = @This();
        const Relation = struct { id: i64, attrs: Policy.Attributes, members: []const Member };
        a: Allocator,
        owned: Allocator,
        gpa: Allocator,
        deadline: io.Deadline,
        boundaries: bool,
        restrictions: ?*turns.Catalog,
        connections: ?*lanes.Catalog,
        max_relation_changeset: u64 = 0,
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
                self.max_relation_changeset = @max(self.max_relation_changeset, relation.changeset);
                if (self.restrictions) |present| try present.add(relation);
                if (self.connections) |present| try present.addRelation(relation);
                if (!self.boundaries) continue;
                if (self.relation_ids.contains(relation.id)) continue;
                const attrs = try Policy.read(self.owned, relation, self.deadline) orelse continue;
                var members: std.ArrayList(Member) = .empty;
                var refs = relation.members;
                while (try refs.next()) |member| {
                    if (member.type != .way) continue;
                    const role = Policy.wayRole(member.role) orelse continue;
                    const way = try self.ways.getOrPut(self.a, member.ref);
                    if (!way.found_existing) way.value_ptr.* = .{};
                    try members.append(self.a, .{ .way_id = member.ref, .role = role });
                }
                if (members.items.len == 0) continue;
                try self.relation_ids.put(self.a, relation.id, {});
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
}

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}
