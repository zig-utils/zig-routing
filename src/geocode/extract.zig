//! Build a geocoder bundle from OSM primitives and administrative polygons.
const std = @import("std");
const io = @import("../infra/io.zig");
const pbf = @import("../build/pbf/root.zig");
const geo = @import("../geo/point.zig");
const polygon = @import("../geo/polygon.zig");
const model = @import("model.zig");
const bundle = @import("bundle.zig");
const admin = @import("admin.zig");
const tags = @import("tags.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const Counts = struct {
    places: usize = 0,
    street_ways: usize = 0,
    addresses: usize = 0,
    pois: usize = 0,
};

pub const Report = struct {
    tagged: Counts = .{},
    located: Counts = .{},
    streets: usize = 0,
    admins: usize = 0,
    country: usize = 0,
    city: usize = 0,
    country_and_city: usize = 0,
    attribution: []const u8 = model.attribution,
    attribution_url: []const u8 = model.attribution_url,
    license: []const u8 = model.license,
};

pub const Options = struct {
    workers: usize = 0,
    admin_sources: []const []const u8 = &.{},
};

pub fn build(a: Allocator, input: []const u8, output: []const u8, options: Options, deadline: io.Deadline) !Report {
    const files = try a.alloc(pbf.file.File, 1 + options.admin_sources.len);
    defer a.free(files);
    var opened: usize = 0;
    defer for (files[0..opened]) |*file| file.close();
    files[0] = try pbf.file.File.open(a, input, deadline);
    opened = 1;
    for (options.admin_sources, files[1..]) |path, *file| {
        file.* = try pbf.file.File.open(a, path, deadline);
        opened += 1;
    }
    const source: pbf.file.IndexedStreams = .{
        .files = files,
        .decode = .{ .workers = options.workers, .buffer_bytes = 512 * 1024 * 1024 },
    };
    var owned: std.heap.ArenaAllocator = .init(a);
    defer owned.deinit();
    var extractor: Extractor = .{
        .a = a,
        .owned = owned.allocator(),
        .deadline = deadline,
        .pool = .{ .a = a, .owned = owned.allocator() },
    };
    defer extractor.deinit();
    var index = try admin.Index.build(a, owned.allocator(), &extractor.pool, source, deadline);
    defer index.deinit();
    extractor.admins = &index;
    try extractor.run(.{ .files = source.files[0..1], .decode = source.decode });
    const data = extractor.data();
    const coverage = try data.coverage(deadline);
    extractor.report.country = coverage.country;
    extractor.report.city = coverage.city;
    extractor.report.country_and_city = coverage.country_and_city;
    try bundle.write(output, try identity(files, deadline), data, deadline);
    return extractor.report;
}

fn identity(files: []const pbf.file.File, deadline: io.Deadline) !model.DatasetUuid {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(if (files.len == 1) "zr-geocode-v1" else "zr-geocode-admin-v1");
    for (files) |*file| {
        const bytes = file.mapping.bytes;
        if (files.len > 1) {
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, bytes.len, .little);
            hash.update(&size);
        }
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const chunk = bytes[offset..@min(offset +| (1 << 20), bytes.len)];
            hash.update(chunk);
            offset += chunk.len;
        }
    }
    const digest = hash.finalResult();
    return digest[0..16].*;
}

const Feature = struct {
    record: model.Record,
    place: model.Span = .{},
    population: u32 = 0,
    street: model.Span = .{},
    primary_name: model.Span = .{},
    number: model.Span = .{},
    house_name: model.Span = .{},
    addr_street: model.Span = .{},
    addr_place: model.Span = .{},
    unit: model.Span = .{},
    category: model.Span = .{},
    kind: model.Span = .{},
};

const WayGeometry = struct {
    refs: []const i64 = &.{},
    anchor: ?model.Coordinate = null,
};

const RelationMember = struct {
    id: i64,
    role: enum { label, node, outer, inner, way, relation },
};

const Relation = struct {
    members: []const RelationMember,
    needed: bool = false,
    coordinate: ?model.Coordinate = null,
};

const StreetPiece = struct {
    record: model.Record,
    primary_name: model.Span,
    kind: model.Span,

    fn less(_: void, a: StreetPiece, b: StreetPiece) bool {
        const city_a = @backingInt(a.record.hierarchy.city);
        const city_b = @backingInt(b.record.hierarchy.city);
        if (city_a != city_b) return city_a < city_b;
        if (a.primary_name.first != b.primary_name.first) return a.primary_name.first < b.primary_name.first;
        return a.record.osm_id < b.record.osm_id;
    }

    fn sameStreet(a: StreetPiece, b: StreetPiece) bool {
        return a.record.hierarchy.city != .unknown and a.record.hierarchy.city == b.record.hierarchy.city and
            a.primary_name.first == b.primary_name.first;
    }
};

const Extractor = struct {
    a: Allocator,
    owned: Allocator,
    deadline: io.Deadline,
    pool: tags.Pool,
    admins: *admin.Index = undefined,
    scratch: pbf.block.Scratch = .{},
    ways: std.AutoHashMapUnmanaged(i64, WayGeometry) = .empty,
    nodes: std.AutoHashMapUnmanaged(i64, ?model.Coordinate) = .empty,
    relations: std.ArrayList(Relation) = .empty,
    relation_ids: std.AutoHashMapUnmanaged(i64, usize) = .empty,
    relation_features: std.ArrayList(Feature) = .empty,
    way_features: std.ArrayList(Feature) = .empty,
    points: std.ArrayList(geo.PointLL) = .empty,
    fragments: std.ArrayList(polygon.Fragment) = .empty,
    street_pieces: std.ArrayList(StreetPiece) = .empty,
    places: std.ArrayList(model.Place) = .empty,
    streets: std.ArrayList(model.Street) = .empty,
    addresses: std.ArrayList(model.Address) = .empty,
    pois: std.ArrayList(model.Poi) = .empty,
    street_ways: std.ArrayList(i64) = .empty,
    report: Report = .{},
    phase: enum { relations, ways, nodes } = .relations,

    fn deinit(self: *Extractor) void {
        self.scratch.deinit(self.a);
        self.pool.deinit();
        self.ways.deinit(self.a);
        self.nodes.deinit(self.a);
        self.relations.deinit(self.a);
        self.relation_ids.deinit(self.a);
        self.relation_features.deinit(self.a);
        self.way_features.deinit(self.a);
        self.points.deinit(self.a);
        self.fragments.deinit(self.a);
        self.street_pieces.deinit(self.a);
        self.places.deinit(self.a);
        self.streets.deinit(self.a);
        self.addresses.deinit(self.a);
        self.pois.deinit(self.a);
        self.street_ways.deinit(self.a);
    }

    fn data(self: *const Extractor) bundle.Data {
        return .{
            .places = self.places.items,
            .streets = self.streets.items,
            .addresses = self.addresses.items,
            .pois = self.pois.items,
            .admins = self.admins.records,
            .names = self.pool.names.items,
            .text = self.pool.bytes.items,
            .street_ways = self.street_ways.items,
        };
    }

    fn run(self: *Extractor, source: pbf.file.IndexedStreams) !void {
        try source.forEach(self.a, self.deadline, self, consume);
        try self.selectRelationGeometry();
        self.phase = .ways;
        try source.forEach(self.a, self.deadline, self, consume);
        self.phase = .nodes;
        try source.forEach(self.a, self.deadline, self, consume);

        var ways = self.ways.valueIterator();
        while (ways.next()) |geometry| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            geometry.anchor = try self.wayAnchor(geometry.refs);
        }
        for (self.way_features.items) |feature| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const anchor = self.ways.get(feature.record.osm_id).?.anchor orelse continue;
            try self.emit(feature, anchor);
        }
        try self.resolveRelations();
        try self.mergeStreets();
        self.report.streets = self.streets.items.len;
        self.report.admins = self.admins.records.len;
    }

    fn consume(self: *Extractor, _: usize, bytes: []const u8) !void {
        const block = try self.scratch.decode(self.a, bytes, self.deadline);
        switch (self.phase) {
            .relations => try self.readRelations(block),
            .ways => try self.readWays(block),
            .nodes => try self.readNodes(block),
        }
    }

    fn readRelations(self: *Extractor, block: pbf.block.Block) !void {
        var entries = block.relations();
        while (try entries.next()) |entry| {
            const labels = try tags.Labels.read(entry.tags);
            if (self.relation_ids.contains(entry.id)) return error.DuplicateGeocodeRelation;
            var out: std.ArrayList(RelationMember) = .empty;
            var members = entry.members;
            while (try members.next()) |member| {
                const role: @FieldType(RelationMember, "role") = switch (member.type) {
                    .node => if (eql(u8, member.role, "admin_centre") or eql(u8, member.role, "label")) .label else .node,
                    .way => blk: {
                        if (eql(u8, member.role, "inner")) break :blk .inner;
                        if (member.role.len == 0 or eql(u8, member.role, "outer")) break :blk .outer;
                        break :blk .way;
                    },
                    .relation => .relation,
                };
                try out.append(self.owned, .{ .id = member.ref, .role = role });
            }
            try self.relation_ids.put(self.a, entry.id, self.relations.items.len);
            try self.relations.append(self.a, .{ .members = out.items });
            if (try self.parseFeature(entry.id, .relation, labels, entry.tags)) |feature|
                try self.relation_features.append(self.a, feature);
        }
    }

    fn selectRelationGeometry(self: *Extractor) !void {
        var queue: std.ArrayList(usize) = .empty;
        defer queue.deinit(self.a);
        for (self.relation_features.items) |feature| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const index = self.relation_ids.get(feature.record.osm_id).?;
            self.relations.items[index].needed = true;
            try queue.append(self.a, index);
        }
        var next: usize = 0;
        while (next < queue.items.len) : (next += 1) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const relation = self.relations.items[queue.items[next]];
            for (relation.members) |member| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                switch (member.role) {
                    .label, .node => try self.nodes.put(self.a, member.id, null),
                    .outer, .inner, .way => try self.ways.put(self.a, member.id, .{}),
                    .relation => {
                        const child = self.relation_ids.get(member.id) orelse continue;
                        if (self.relations.items[child].needed) continue;
                        self.relations.items[child].needed = true;
                        try queue.append(self.a, child);
                    },
                }
            }
        }
    }

    fn readWays(self: *Extractor, block: pbf.block.Block) !void {
        var entries = block.ways();
        while (try entries.next()) |entry| {
            const labels = try tags.Labels.read(entry.tags);
            const feature = try self.parseFeature(entry.id, .way, labels, entry.tags);
            if (feature == null and !self.ways.contains(entry.id)) continue;
            var out: std.ArrayList(i64) = .empty;
            var refs = entry.refs;
            while (try refs.next()) |id| {
                try self.nodes.put(self.a, id, null);
                try out.append(self.owned, id);
            }
            try self.ways.put(self.a, entry.id, .{ .refs = out.items });
            if (feature) |present| try self.way_features.append(self.a, present);
        }
    }

    fn readNodes(self: *Extractor, block: pbf.block.Block) !void {
        var entries = block.nodes();
        while (try entries.next()) |entry| {
            const coordinate: model.Coordinate = .{ .lat = entry.lat, .lng = entry.lon };
            if (self.nodes.getPtr(entry.id)) |slot| slot.* = coordinate;
            const labels = try tags.Labels.read(entry.tags);
            if (try self.parseFeature(entry.id, .node, labels, entry.tags)) |present| try self.emit(present, coordinate);
        }
    }

    fn parseFeature(self: *Extractor, id: i64, source: model.Source, labels: tags.Labels, input: pbf.block.TagIterator) !?Feature {
        if (!labels.feature(source)) return null;
        const street = labels.isStreet(source);
        const place = tags.validKind(labels.place);
        const poi = labels.poi;
        const result: Feature = .{
            .record = .{
                .osm_id = id,
                .coordinate = undefined,
                .names = try self.pool.labels(input),
                .hierarchy = .{ .postcode = try self.pool.text(labels.postcode) },
                .attr = .{ .source = source, .importance = labels.importance() },
            },
            .place = if (place) try self.pool.text(labels.place) else .{},
            .population = labels.population,
            .street = if (street) try self.pool.text(labels.highway) else .{},
            .primary_name = if (street) try self.pool.text(labels.name) else .{},
            .number = try self.pool.text(labels.number),
            .house_name = try self.pool.text(labels.house_name),
            .addr_street = try self.pool.text(labels.street),
            .addr_place = try self.pool.text(labels.locality),
            .unit = try self.pool.text(labels.unit),
            .category = if (poi) |value| try self.pool.text(value.category) else .{},
            .kind = if (poi) |value| try self.pool.text(value.kind) else .{},
        };
        count(&self.report.tagged, result);
        return result;
    }

    fn emit(self: *Extractor, present: Feature, coordinate: model.Coordinate) !void {
        var record = present.record;
        record.coordinate = coordinate;
        record.hierarchy = try self.admins.lookup(coordinate);
        record.hierarchy.postcode = present.record.hierarchy.postcode;
        if (present.place.len != 0) {
            try self.places.append(self.a, .{ .record = record, .kind = present.place, .population = present.population });
        }
        if (present.street.len != 0) {
            try self.street_pieces.append(self.a, .{ .record = record, .kind = present.street, .primary_name = present.primary_name });
        }
        if (present.number.len != 0 or present.house_name.len != 0) {
            try self.addresses.append(self.a, .{
                .record = record,
                .number = present.number,
                .house_name = present.house_name,
                .street = present.addr_street,
                .place = present.addr_place,
                .unit = present.unit,
            });
        }
        if (present.category.len != 0) {
            try self.pois.append(self.a, .{ .record = record, .category = present.category, .kind = present.kind });
        }
        count(&self.report.located, present);
    }

    fn readPoints(self: *Extractor, refs: []const i64) !bool {
        self.points.clearRetainingCapacity();
        for (refs, 0..) |id, i| {
            if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            const fixed = self.nodes.get(id).? orelse continue;
            try self.points.append(self.a, fixed.toPoint());
        }
        return self.points.items.len == refs.len;
    }

    fn wayAnchor(self: *Extractor, refs: []const i64) !?model.Coordinate {
        const complete = try self.readPoints(refs);
        const points = self.points.items;
        if (points.len == 0) return null;
        if (!complete) return points[points.len / 2].toFixed();
        if (points.len >= 4 and refs[0] == refs[refs.len - 1]) {
            const shape: polygon.Polygon = .{ .outer = points };
            if (try shape.representative(self.deadline)) |anchor| return anchor.toFixed();
        }
        const a = points[(points.len - 1) / 2];
        const b = points[points.len / 2];
        const longitude = a.lng + geo.wrappedLongitudeDelta(b.lng, a.lng) * 0.5;
        const wrapped = if (longitude > 180) longitude - 360 else if (longitude < -180) longitude + 360 else longitude;
        return geo.PointLL.init(wrapped, (a.lat + b.lat) * 0.5).toFixed();
    }

    fn relationAnchor(self: *Extractor, members: []const RelationMember) !?model.Coordinate {
        var fallback_node: ?model.Coordinate = null;
        var fallback_way: ?model.Coordinate = null;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const temp = arena.allocator();
        self.fragments.clearRetainingCapacity();
        for (members) |member| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            switch (member.role) {
                .label, .node => if (self.nodes.get(member.id).?) |location| {
                    if (member.role == .label) return location;
                    if (fallback_node == null) fallback_node = location;
                },
                .outer, .inner, .way => {
                    const way = self.ways.get(member.id).?;
                    if (member.role != .inner and fallback_way == null) fallback_way = way.anchor;
                    if (member.role == .way or way.refs.len < 2 or !try self.readPoints(way.refs)) continue;
                    try self.fragments.append(self.a, .{
                        .points = try temp.dupe(geo.PointLL, self.points.items),
                        .role = if (member.role == .inner) .inner else .outer,
                    });
                },
                .relation => {},
            }
        }
        if (self.fragments.items.len != 0) {
            var geometry = try polygon.assemble(self.a, self.fragments.items, self.deadline);
            defer geometry.deinit();
            var best: ?model.Coordinate = null;
            var largest: f64 = -1;
            for (geometry.polygons) |shape| {
                const area = @abs(try polygon.signedArea(shape.outer, self.deadline));
                if (area <= largest) continue;
                if (try shape.representative(self.deadline)) |anchor| {
                    best = anchor.toFixed();
                    largest = area;
                }
            }
            if (best != null) return best;
        }
        return fallback_node orelse fallback_way;
    }

    fn resolveRelations(self: *Extractor) !void {
        for (self.relations.items) |*relation| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (!relation.needed) continue;
            relation.coordinate = try self.relationAnchor(relation.members);
        }
        // Propagate resolved members through the relation graph. A work
        // queue visits each parent when the first usable child is found,
        // including when other members form cycles or are absent.
        const ChildLinks = std.ArrayList(usize);
        const parents = try self.owned.alloc(ChildLinks, self.relations.items.len);
        @memset(parents, .empty);
        var queue: std.ArrayList(usize) = .empty;
        defer queue.deinit(self.a);
        for (self.relations.items, 0..) |relation, i| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (!relation.needed) continue;
            if (relation.coordinate != null) {
                try queue.append(self.a, i);
                continue;
            }
            for (relation.members) |member| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                if (member.role != .relation) continue;
                const child = self.relation_ids.get(member.id) orelse continue;
                try parents[child].append(self.owned, i);
            }
        }
        var next: usize = 0;
        while (next < queue.items.len) : (next += 1) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const index = queue.items[next];
            const location = self.relations.items[index].coordinate.?;
            for (parents[index].items) |parent| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                const relation = &self.relations.items[parent];
                if (relation.coordinate != null) continue;
                relation.coordinate = location;
                try queue.append(self.a, parent);
            }
        }
        for (self.relation_features.items) |feature| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const relation = self.relations.items[self.relation_ids.get(feature.record.osm_id).?];
            if (relation.coordinate) |location| try self.emit(feature, location);
        }
    }

    fn mergeStreets(self: *Extractor) !void {
        const all = self.street_pieces.items;
        std.mem.sortUnstable(StreetPiece, all, {}, StreetPiece.less);
        var offset: usize = 0;
        var names: std.ArrayList(model.Name) = .empty;
        defer names.deinit(self.a);
        var seen: std.AutoHashMapUnmanaged(model.Name, void) = .empty;
        defer seen.deinit(self.a);
        while (offset < all.len) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const first = all[offset];
            const begin = self.street_ways.items.len;
            names.clearRetainingCapacity();
            seen.clearRetainingCapacity();
            while (true) {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                const piece = all[offset];
                try self.street_ways.append(self.a, piece.record.osm_id);
                const labels = try piece.record.names.get(@as([]const model.Name, self.pool.names.items));
                for (labels) |label| {
                    if (self.deadline.expired()) return error.DeadlineExceeded;
                    const entry = try seen.getOrPut(self.a, label);
                    if (!entry.found_existing) try names.append(self.a, label);
                }
                offset += 1;
                if (offset == all.len or !first.sameStreet(all[offset])) break;
            }
            const ways = try model.Span.init(begin, self.street_ways.items.len - begin);
            var record = first.record;
            if (ways.len > 1) {
                record.names = try model.Span.init(self.pool.names.items.len, names.items.len);
                try self.pool.names.appendSlice(self.a, names.items);
            }
            try self.streets.append(self.a, .{ .record = record, .kind = first.kind, .ways = ways });
        }
    }
};

fn count(counts: *Counts, feature: Feature) void {
    counts.places += @intFromBool(feature.place.len != 0);
    counts.street_ways += @intFromBool(feature.street.len != 0);
    counts.addresses += @intFromBool(feature.number.len != 0 or feature.house_name.len != 0);
    counts.pois += @intFromBool(feature.category.len != 0);
}
