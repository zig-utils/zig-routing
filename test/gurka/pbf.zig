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
const StringTable = protobuf.Message(&.{
    .{ .name = "s", .number = 1, .kind = .bytes, .presence = .repeated },
});
const Info = protobuf.Message(&.{
    .{ .name = "version", .number = 1, .kind = .int32, .presence = .optional },
    .{ .name = "changeset", .number = 3, .kind = .int64, .presence = .optional },
});
const entity_fields = [_]protobuf.Field{
    .{ .name = "keys", .number = 2, .kind = .uint32, .presence = .repeated, .packed_encoding = true },
    .{ .name = "vals", .number = 3, .kind = .uint32, .presence = .repeated, .packed_encoding = true },
    .{ .name = "info", .number = 4, .kind = .message, .presence = .optional, .message = Info },
};
const Node = protobuf.Message(&([_]protobuf.Field{
    .{ .name = "id", .number = 1, .kind = .sint64, .presence = .required },
} ++ entity_fields ++ [_]protobuf.Field{
    .{ .name = "lat", .number = 8, .kind = .sint64, .presence = .required },
    .{ .name = "lon", .number = 9, .kind = .sint64, .presence = .required },
}));
const Way = protobuf.Message(&([_]protobuf.Field{
    .{ .name = "id", .number = 1, .kind = .int64, .presence = .required },
} ++ entity_fields ++ [_]protobuf.Field{
    .{ .name = "refs", .number = 8, .kind = .sint64, .presence = .repeated, .packed_encoding = true },
}));
const Relation = protobuf.Message(&([_]protobuf.Field{
    .{ .name = "id", .number = 1, .kind = .int64, .presence = .required },
} ++ entity_fields ++ [_]protobuf.Field{
    .{ .name = "roles_sid", .number = 8, .kind = .int32, .presence = .repeated, .packed_encoding = true },
    .{ .name = "memids", .number = 9, .kind = .sint64, .presence = .repeated, .packed_encoding = true },
    .{ .name = "types", .number = 10, .kind = .enumeration, .presence = .repeated, .packed_encoding = true },
}));
const PrimitiveGroup = protobuf.Message(&.{
    .{ .name = "nodes", .number = 1, .kind = .message, .presence = .repeated, .message = Node },
    .{ .name = "ways", .number = 3, .kind = .message, .presence = .repeated, .message = Way },
    .{ .name = "relations", .number = 4, .kind = .message, .presence = .repeated, .message = Relation },
});
const PrimitiveBlock = protobuf.Message(&.{
    .{ .name = "stringtable", .number = 1, .kind = .message, .presence = .required, .message = StringTable },
    .{ .name = "primitivegroup", .number = 2, .kind = .message, .presence = .repeated, .message = PrimitiveGroup },
});

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
