//! Uncompressed OSM PBF fixture writer. Field numbers follow the OSM-binary
//! fileformat.proto and osmformat.proto wire definitions at 9f01ad3.

const std = @import("std");
const protobuf = @import("protobuf");
const schema = @import("routing").build.pbf.schema;
const gurka = @import("gurka.zig");
const Allocator = std.mem.Allocator;
const none = protobuf.no_deadline;

const BlobHeader = schema.BlobHeader;
const Blob = schema.Blob;
const HeaderBlock = schema.HeaderBlock;
const Node = schema.Node;
const Way = schema.Way;
const Relation = schema.Relation;
const PrimitiveGroup = schema.PrimitiveGroup;
const PrimitiveBlock = schema.PrimitiveBlock;

const Strings = struct {
    arena: Allocator,
    ids: std.StringHashMapUnmanaged(u32) = .empty,
    bytes: std.ArrayList([]const u8) = .empty,

    fn intern(self: *Strings, bytes: []const u8) !u32 {
        const entry = try self.ids.getOrPut(self.arena, bytes);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.math.cast(u32, self.bytes.items.len) orelse return error.TooManyStrings;
            try self.bytes.append(self.arena, bytes);
        }
        return entry.value_ptr.*;
    }

    fn encodeTags(self: *Strings, tags: gurka.Tags) !struct { keys: []u32, values: []u32 } {
        const keys = try self.arena.alloc(u32, tags.len);
        const values = try self.arena.alloc(u32, tags.len);
        for (tags, keys, values) |tag, *key, *value| {
            if (tag.key.len == 0) return error.EmptyTagKey;
            key.* = try self.intern(tag.key);
            value.* = try self.intern(tag.value);
        }
        return .{ .keys = keys, .values = values };
    }
};

fn encodePosition(value: f64, limit: f64) !i64 {
    if (!std.math.isFinite(value) or @abs(value) > limit) return error.InvalidCoordinate;
    return @intFromFloat(@round(value * 10_000_000)); // 100 nanodegrees, the block default.
}

fn encodeWay(arena: Allocator, strings: *Strings, way: gurka.OsmWay) !Way.Values {
    const tags = try strings.encodeTags(way.tags);
    const refs = try arena.alloc(i64, way.refs.len);
    var previous: i64 = 0;
    for (way.refs, refs) |id, *delta| {
        delta.* = try std.math.sub(i64, id, previous);
        previous = id;
    }
    return .{ .id = way.id, .keys = tags.keys, .vals = tags.values, .info = .{ .version = 1, .changeset = 1001 }, .refs = refs };
}

fn encodeRelation(arena: Allocator, strings: *Strings, relation: gurka.OsmRelation) !Relation.Values {
    const tags = try strings.encodeTags(relation.tags);
    const roles = try arena.alloc(i32, relation.members.len);
    const ids = try arena.alloc(i64, relation.members.len);
    const types = try arena.alloc(i32, relation.members.len);
    var previous: i64 = 0;
    for (relation.members, roles, ids, types) |member, *role, *id, *kind| {
        role.* = std.math.cast(i32, try strings.intern(member.role)) orelse return error.TooManyStrings;
        id.* = try std.math.sub(i64, member.id, previous);
        previous = member.id;
        kind.* = @backingInt(member.kind);
    }
    return .{ .id = relation.id, .keys = tags.keys, .vals = tags.values, .info = .{ .version = 1 }, .roles_sid = roles, .memids = ids, .types = types };
}

fn appendBlock(arena: Allocator, out: *std.ArrayList(u8), kind: []const u8, raw: []const u8) !void {
    const blob: Blob.Values = .{ .raw = raw };
    const blob_size = try Blob.encodedSize(blob, none);
    if (blob_size >= 32 * 1024 * 1024) return error.BlobTooLarge;
    const header: BlobHeader.Values = .{ .type = kind, .datasize = @intCast(blob_size) };
    const header_size = try BlobHeader.encodedSize(header, none);
    const bytes = try out.addManyAsSlice(arena, 4 + header_size + blob_size);
    std.mem.writeInt(u32, bytes[0..4], @intCast(header_size), .big);
    _ = try BlobHeader.encode(bytes[4..][0..header_size], header, none);
    _ = try Blob.encode(bytes[4 + header_size ..], blob, none);
}

/// Emit an OSMHeader and one OSMData block with a shared string table.
pub fn encode(arena: Allocator, dataset: gurka.Dataset) ![]const u8 {
    var strings: Strings = .{ .arena = arena };
    try strings.bytes.append(arena, "");
    const nodes = try arena.alloc(Node.Values, dataset.nodes.len);
    for (dataset.nodes, nodes) |node, *record| {
        const tags = try strings.encodeTags(node.tags);
        record.* = .{
            .id = node.id,
            .keys = tags.keys,
            .vals = tags.values,
            .info = .{ .version = 1 },
            .lat = try encodePosition(node.location.lat, 90),
            .lon = try encodePosition(node.location.lng, 180),
        };
    }
    const ways = try arena.alloc(Way.Values, dataset.ways.len);
    for (dataset.ways, ways) |way, *record| record.* = try encodeWay(arena, &strings, way);
    const relations = try arena.alloc(Relation.Values, dataset.relations.len);
    for (dataset.relations, relations) |relation, *record| record.* = try encodeRelation(arena, &strings, relation);

    var groups: std.ArrayList(PrimitiveGroup.Values) = .empty;
    if (nodes.len != 0) try groups.append(arena, .{ .nodes = nodes });
    if (ways.len != 0) try groups.append(arena, .{ .ways = ways });
    if (relations.len != 0) try groups.append(arena, .{ .relations = relations });
    const header: HeaderBlock.Values = .{
        .required_features = &.{"OsmSchema-V0.6"},
        .optional_features = &.{"Sort.Type_then_ID"},
        .writingprogram = "zig-routing-gurka",
    };
    const block: PrimitiveBlock.Values = .{
        .stringtable = .{ .s = strings.bytes.items },
        .primitivegroup = groups.items,
    };
    var out: std.ArrayList(u8) = .empty;
    const header_buf = try arena.alloc(u8, try HeaderBlock.encodedSize(header, none));
    try appendBlock(arena, &out, "OSMHeader", try HeaderBlock.encode(header_buf, header, none));
    const block_buf = try arena.alloc(u8, try PrimitiveBlock.encodedSize(block, none));
    try appendBlock(arena, &out, "OSMData", try PrimitiveBlock.encode(block_buf, block, none));
    return out.items;
}

fn expectBlock(file: *[]const u8, kind: []const u8) ![]const u8 {
    const header_size = std.mem.readInt(u32, file.*[0..4], .big);
    const header = try BlobHeader.decode(file.*[4..][0..header_size], none);
    try std.testing.expectEqualStrings(kind, try header.get("type", none));
    const blob_size: usize = @intCast(try header.get("datasize", none));
    const blob = try Blob.decode(file.*[4 + header_size ..][0..blob_size], none);
    file.* = file.*[4 + header_size + blob_size ..];
    return (try blob.get("raw", none)).?;
}

test "PBF fixture writes deterministic framing, string IDs and negative way deltas" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const fixture = try gurka.Map.init(arena, try gurka.mapToCoordinates("A-B", 10), &.{
        .{ .label = "BA", .tags = &.{.{ .key = "highway", .value = "residential" }} },
    }, &.{}, &.{});
    const bytes = try encode(arena, fixture.osm);
    try std.testing.expectEqualSlices(u8, bytes, try encode(arena, fixture.osm));
    var file = bytes;
    const header = try HeaderBlock.decode(try expectBlock(&file, "OSMHeader"), none);
    var features = try header.get("required_features", none);
    try std.testing.expectEqualStrings("OsmSchema-V0.6", (try features.next(none)).?);
    const block = try PrimitiveBlock.decode(try expectBlock(&file, "OSMData"), none);
    try std.testing.expectEqual(0, file.len);
    const table = try block.get("stringtable", none);
    var strings = try table.get("s", none);
    try std.testing.expectEqualStrings("", (try strings.next(none)).?);
    try std.testing.expectEqualStrings("name", (try strings.next(none)).?);
    var groups = try block.get("primitivegroup", none);
    const node_group = (try groups.next(none)).?;
    var nodes = try node_group.get("nodes", none);
    const a = (try nodes.next(none)).?;
    const b = (try nodes.next(none)).?;
    try std.testing.expectEqual(1, try a.get("id", none));
    try std.testing.expectEqual(0, try a.get("lon", none));
    try std.testing.expectEqual(1797, try b.get("lon", none));
    const way_group = (try groups.next(none)).?;
    var ways = try way_group.get("ways", none);
    const way = (try ways.next(none)).?;
    var refs = try way.get("refs", none);
    try std.testing.expectEqual(2, (try refs.next(none)).?);
    try std.testing.expectEqual(-1, (try refs.next(none)).?);
    try std.testing.expectEqual(null, try refs.next(none));
}

fn expectTags(expected: gurka.Tags, actual: *const @import("routing").build.pbf.block.TagIterator) !void {
    var tags = actual.*;
    for (expected) |tag| {
        const decoded = (try tags.next()) orelse return error.MissingTag;
        try std.testing.expectEqualStrings(tag.key, decoded.key);
        try std.testing.expectEqualStrings(tag.value, decoded.value);
    }
    try std.testing.expectEqual(null, try tags.next());
}

test "primitive decoder round trips the Gurka dataset without allocating while iterating" {
    const testing = std.testing;
    const routing = @import("routing");
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const fixture = try gurka.Map.init(arena, try gurka.mapToCoordinates("A-B-C", 10), &.{
        .{ .label = "BA", .tags = &.{.{ .key = "highway", .value = "residential" }} },
        .{ .label = "BC", .tags = &.{.{ .key = "name", .value = "" }} },
    }, &.{}, &.{.{
        .tags = &.{.{ .key = "type", .value = "restriction" }},
        .members = &.{
            .{ .kind = .way, .ref = "BA", .role = "from" },
            .{ .kind = .node, .ref = "B", .role = "via" },
            .{ .kind = .way, .ref = "BC", .role = "to" },
        },
    }});
    const bytes = try encode(arena, fixture.osm);
    var index = try routing.build.pbf.file.Index.init(arena, bytes, .none);
    defer index.deinit();
    try testing.expectEqual(1, index.blobs.len);
    const inflated = try index.inflateInto(0, &.{}, .none);
    var counting = routing.infra.arena.CountingAllocator.init(testing.allocator);
    const gpa = counting.allocator();
    var scratch: routing.build.pbf.block.Scratch = .{};
    defer scratch.deinit(gpa);
    _ = try scratch.decode(gpa, inflated, .none);
    counting.resetCounts();
    const block = try scratch.decode(gpa, inflated, .none);
    try testing.expectEqual(100, block.granularity);
    try testing.expectEqual(1000, block.date_granularity);

    var nodes = block.nodes();
    for (fixture.osm.nodes) |expected| {
        const node = (try nodes.next()) orelse return error.MissingNode;
        try testing.expectEqual(expected.id, node.id);
        try testing.expectEqual(try encodePosition(expected.location.lat, 90), node.lat);
        try testing.expectEqual(try encodePosition(expected.location.lng, 180), node.lon);
        try expectTags(expected.tags, &node.tags);
    }
    try testing.expectEqual(null, try nodes.next());
    var ways = block.ways();
    for (fixture.osm.ways) |expected| {
        var way = (try ways.next()) orelse return error.MissingWay;
        try testing.expectEqual(expected.id, way.id);
        try expectTags(expected.tags, &way.tags);
        for (expected.refs) |ref| try testing.expectEqual(@as(?i64, ref), try way.refs.next());
        try testing.expectEqual(null, try way.refs.next());
    }
    try testing.expectEqual(null, try ways.next());
    var relations = block.relations();
    for (fixture.osm.relations) |expected| {
        var relation = (try relations.next()) orelse return error.MissingRelation;
        try testing.expectEqual(expected.id, relation.id);
        try expectTags(expected.tags, &relation.tags);
        for (expected.members) |expected_member| {
            const member = (try relation.members.next()) orelse return error.MissingMember;
            try testing.expectEqual(@backingInt(expected_member.kind), @backingInt(member.type));
            try testing.expectEqual(expected_member.id, member.ref);
            try testing.expectEqualStrings(expected_member.role, member.role);
        }
        try testing.expectEqual(null, try relation.members.next());
    }
    try testing.expectEqual(null, try relations.next());
    try testing.expectEqual(0, counting.calls());
}

test "way usage filters, saturates and resolves nodes from sorted and unsorted PBFs" {
    const testing = std.testing;
    const routing = @import("routing");
    const io = routing.infra.io;
    const pbf = routing.build.pbf;
    const node_store = routing.build.node_store;
    const Classifier = struct {
        fn include(_: void, way: *const pbf.block.Way) !bool {
            var tags = way.tags;
            while (try tags.next()) |tag| {
                if (std.mem.eql(u8, tag.key, "highway")) return true;
            }
            return false;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const min_id = std.math.minInt(i64);
    const max_id = std.math.maxInt(i64);
    const signed_nodes: [6]gurka.OsmNode = .{
        .{ .id = -75, .label = "A", .location = .{ .lat = 1.23, .lng = -4.56 }, .tags = &.{} },
        .{ .id = min_id, .label = "B", .location = .{ .lat = 0, .lng = 1 }, .tags = &.{} },
        .{ .id = 1, .label = "C", .location = .{ .lat = -3, .lng = 7 }, .tags = &.{} },
        .{ .id = 2, .label = "D", .location = .{ .lat = 4, .lng = 5 }, .tags = &.{} },
        .{ .id = 3, .label = "E", .location = .{ .lat = 8, .lng = 9 }, .tags = &.{} },
        .{ .id = max_id, .label = "F", .location = .{ .lat = 1, .lng = -1 }, .tags = &.{} },
    };
    const highway: gurka.Tags = &.{.{ .key = "highway", .value = "residential" }};
    const ways: []const gurka.OsmWay = &.{
        .{ .id = 10, .label = "AAABA", .refs = &.{ -75, -75, -75, min_id, -75 }, .tags = highway },
        .{ .id = 11, .label = "CD", .refs = &.{ 1, 2 }, .tags = highway },
        .{ .id = 12, .label = "CF", .refs = &.{ 1, max_id }, .tags = highway },
        .{ .id = 13, .label = "CE", .refs = &.{ 1, 3 }, .tags = &.{} },
        .{ .id = 14, .label = "D?", .refs = &.{ 2, 4 }, .tags = highway },
    };
    const expected = [_]?node_store.Location{
        .{ .lat = 12300000, .lon = -45600000, .uses = 3 },
        .{ .lat = 0, .lon = 10000000, .uses = 1 },
        .{ .lat = -30000000, .lon = 70000000, .uses = 2 },
        .{ .lat = 40000000, .lon = 50000000, .uses = 2 },
        null,
        .{ .lat = 10000000, .lon = -10000000, .uses = 1 },
        null,
    };

    const sorted = signed_nodes;
    const unsorted = [_]gurka.OsmNode{ sorted[3], sorted[2], sorted[0], sorted[5], sorted[4], sorted[1] };
    const duplicate = sorted ++ .{sorted[0]};
    for ([_][]const gurka.OsmNode{ &sorted, &unsorted, &duplicate }, 0..) |nodes, i| {
        const bytes = try encode(gpa, .{ .nodes = nodes, .ways = ways, .relations = &.{} });
        const input = try io.File.temporary(".");
        defer input.close();
        try input.writeAll(bytes);
        const source = try pbf.file.Stream.init(input);
        const file = try io.File.temporary(".");
        defer file.close();
        const options: node_store.BuildOptions = .{ .scratch_dir = "." };
        if (i == 2) {
            try testing.expectError(error.DuplicateNode, node_store.build(gpa, source, file, options, {}, Classifier.include));
            try testing.expectError(error.InvalidStore, node_store.Store.open(file));
            continue;
        }
        const store = try node_store.build(gpa, source, file, options, {}, Classifier.include);
        try testing.expectEqual(5, store.nodeCount());
        var found: [expected.len]?node_store.Location = undefined;
        try store.lookupBatch(&.{ -75, min_id, 1, 2, 3, max_id, 4 }, &found, 1, .none);
        try testing.expectEqualSlices(?node_store.Location, &expected, &found);
    }
}
