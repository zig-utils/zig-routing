// Ported from third_party/libosmium/include/osmium/io/detail/pbf_decoder.hpp
// in Valhalla 3.9.3's pinned libosmium.

const std = @import("std");
const protobuf = @import("protobuf");
const Deadline = @import("../../infra/io.zig").Deadline;
const osm = @import("../osm.zig");
const schema = @import("schema.zig");

pub const Error = protobuf.Error || error{
    InvalidStringTable,
    InvalidStringIndex,
    InvalidGranularity,
    InvalidCoordinate,
    InvalidDenseColumns,
    InvalidDenseTags,
    InvalidTags,
    InvalidMembers,
    InvalidMemberType,
    DeltaOverflow,
};

/// Owns the reusable table of string slices. Keep the inflated input and this
/// scratch alive until all views and iterators are finished. Decoding another
/// block with this scratch invalidates the old views, even on error.
pub const Scratch = struct {
    strings: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        self.strings.deinit(gpa);
        self.* = .{};
    }

    pub fn decode(self: *Scratch, gpa: std.mem.Allocator, bytes: []const u8, deadline: Deadline) (Error || std.mem.Allocator.Error)!Block {
        self.strings.clearRetainingCapacity();
        const view = try schema.PrimitiveBlock.decode(bytes, deadline);
        const table = try view.get("stringtable", deadline);
        var strings = try table.get("s", deadline);
        while (try strings.next(deadline)) |item| try self.strings.append(gpa, item);
        if (self.strings.items.len == 0 or self.strings.items[0].len != 0)
            return error.InvalidStringTable;
        const granularity = try view.getOrDefault("granularity", deadline);
        const date_granularity = try view.getOrDefault("date_granularity", deadline);
        if (granularity <= 0 or date_granularity <= 0) return error.InvalidGranularity;
        return .{
            .view = view,
            .strings = self.strings.items,
            .granularity = granularity,
            .date_granularity = date_granularity,
            .lat_offset = try view.getOrDefault("lat_offset", deadline),
            .lon_offset = try view.getOrDefault("lon_offset", deadline),
            .deadline = deadline,
        };
    }
};

pub const Block = struct {
    view: schema.PrimitiveBlock.View,
    strings: []const []const u8,
    /// Nanodegrees per stored coordinate increment.
    granularity: i32,
    /// Milliseconds per stored timestamp increment.
    date_granularity: i32,
    lat_offset: i64,
    lon_offset: i64,
    deadline: Deadline,

    pub fn nodes(self: Block) NodeIterator {
        return NodeIterator.init(self);
    }

    pub fn ways(self: Block) WayIterator {
        return WayIterator.init(self);
    }

    pub fn relations(self: Block) RelationIterator {
        return RelationIterator.init(self);
    }

    fn coordinate(self: Block, raw: i64, offset: i64, comptime limit: i32) Error!i32 {
        const nanodegrees = @as(i128, raw) * self.granularity + offset;
        const units = @divTrunc(nanodegrees, 100);
        const bound = limit * osm.coordinate_scale;
        if (units < -bound or units > bound) return error.InvalidCoordinate;
        return @intCast(units);
    }
};

fn Repeated(comptime Message: type, comptime field: []const u8) type {
    return @typeInfo(@TypeOf(@as(Message.View, undefined).get(field, protobuf.no_deadline))).error_union.payload;
}

fn check(deadline: Deadline) Error!void {
    if (deadline.expired()) return error.DeadlineExceeded;
}

fn stringAt(strings: []const []const u8, id: anytype) Error![]const u8 {
    const index = std.math.cast(usize, id) orelse return error.InvalidStringIndex;
    if (index >= strings.len) return error.InvalidStringIndex;
    return strings[index];
}

fn addDelta(previous: *i64, delta: i64) Error!i64 {
    previous.* = std.math.add(i64, previous.*, delta) catch return error.DeltaOverflow;
    return previous.*;
}

pub const Node = struct {
    id: i64,
    lat: i32,
    lon: i32,
    tags: TagIterator,
};

pub const Way = struct {
    id: i64,
    refs: RefIterator,
    tags: TagIterator,
};

pub const Relation = struct {
    id: i64,
    members: MemberIterator,
    tags: TagIterator,
};

pub const TagIterator = struct {
    strings: []const []const u8,
    deadline: Deadline,
    fields: union(enum) {
        separate: struct {
            keys: Repeated(schema.Node, "keys"),
            vals: Repeated(schema.Node, "vals"),
        },
        dense: struct {
            values: Repeated(schema.DenseNodes, "keys_vals"),
            pairs: usize,
        },
    },

    fn separate(block: Block, view: anytype) Error!TagIterator {
        return .{
            .strings = block.strings,
            .deadline = block.deadline,
            .fields = .{ .separate = .{
                .keys = try view.get("keys", block.deadline),
                .vals = try view.get("vals", block.deadline),
            } },
        };
    }

    pub fn next(self: *TagIterator) Error!?osm.Tag {
        try check(self.deadline);
        return switch (self.fields) {
            .separate => |*fields| blk: {
                const key = try fields.keys.next(self.deadline);
                const value = try fields.vals.next(self.deadline);
                if ((key == null) != (value == null)) return error.InvalidTags;
                break :blk if (key) |id| try self.tag(id, value.?) else null;
            },
            .dense => |*fields| blk: {
                if (fields.pairs == 0) return null;
                const key = try fields.values.next(self.deadline) orelse return error.InvalidDenseTags;
                const value = try fields.values.next(self.deadline) orelse return error.InvalidDenseTags;
                fields.pairs -= 1;
                break :blk try self.tag(key, value);
            },
        };
    }

    fn tag(self: *const TagIterator, key: anytype, value: anytype) Error!osm.Tag {
        if (key == 0) return error.InvalidStringIndex;
        return .{ .key = try stringAt(self.strings, key), .value = try stringAt(self.strings, value) };
    }
};

pub const RefIterator = struct {
    deltas: Repeated(schema.Way, "refs"),
    deadline: Deadline,
    previous: i64 = 0,

    pub fn next(self: *RefIterator) Error!?i64 {
        try check(self.deadline);
        const delta = try self.deltas.next(self.deadline) orelse return null;
        return try addDelta(&self.previous, delta);
    }
};

pub const MemberIterator = struct {
    roles: Repeated(schema.Relation, "roles_sid"),
    deltas: Repeated(schema.Relation, "memids"),
    types: Repeated(schema.Relation, "types"),
    strings: []const []const u8,
    deadline: Deadline,
    previous: i64 = 0,

    pub fn next(self: *MemberIterator) Error!?osm.Member {
        try check(self.deadline);
        const delta = try self.deltas.next(self.deadline);
        const role = try self.roles.next(self.deadline);
        const kind = try self.types.next(self.deadline);
        if (delta == null and role == null and kind == null) return null;
        if (delta == null or role == null or kind == null) return error.InvalidMembers;
        return .{
            .type = switch (kind.?) {
                0 => .node,
                1 => .way,
                2 => .relation,
                else => return error.InvalidMemberType,
            },
            .ref = try addDelta(&self.previous, delta.?),
            .role = try stringAt(self.strings, role.?),
        };
    }
};

const DenseIterator = struct {
    ids: Repeated(schema.DenseNodes, "id"),
    lats: Repeated(schema.DenseNodes, "lat"),
    lons: Repeated(schema.DenseNodes, "lon"),
    keys_vals: Repeated(schema.DenseNodes, "keys_vals"),
    has_tags: bool,
    id: i64 = 0,
    lat: i64 = 0,
    lon: i64 = 0,

    fn init(dense: schema.DenseNodes.View, deadline: Deadline) Error!DenseIterator {
        const keys_vals = try dense.get("keys_vals", deadline);
        var probe = keys_vals;
        return .{
            .ids = try dense.get("id", deadline),
            .lats = try dense.get("lat", deadline),
            .lons = try dense.get("lon", deadline),
            .keys_vals = keys_vals,
            .has_tags = try probe.next(deadline) != null,
        };
    }

    fn next(self: *DenseIterator, block: Block) Error!?Node {
        const deadline = block.deadline;
        const id = try self.ids.next(deadline);
        const lat = try self.lats.next(deadline);
        const lon = try self.lons.next(deadline);
        if (id == null and lat == null and lon == null) {
            if (try self.keys_vals.next(deadline) != null) return error.InvalidDenseTags;
            return null;
        }
        if (id == null or lat == null or lon == null) return error.InvalidDenseColumns;

        const start = self.keys_vals;
        var pairs: usize = 0;
        if (self.has_tags) {
            while (true) : (pairs += 1) {
                try check(deadline);
                const key = try self.keys_vals.next(deadline) orelse return error.InvalidDenseTags;
                if (key == 0) break;
                _ = try self.keys_vals.next(deadline) orelse return error.InvalidDenseTags;
            }
        }
        return .{
            .id = try addDelta(&self.id, id.?),
            .lat = try block.coordinate(try addDelta(&self.lat, lat.?), block.lat_offset, 90),
            .lon = try block.coordinate(try addDelta(&self.lon, lon.?), block.lon_offset, 180),
            .tags = .{
                .strings = block.strings,
                .deadline = deadline,
                .fields = .{ .dense = .{ .values = start, .pairs = pairs } },
            },
        };
    }
};

pub const NodeIterator = PrimitiveIterator(.node);
pub const WayIterator = PrimitiveIterator(.way);
pub const RelationIterator = PrimitiveIterator(.relation);

fn PrimitiveIterator(comptime kind: osm.Kind) type {
    const field = switch (kind) {
        .node => "nodes",
        .way => "ways",
        .relation => "relations",
    };
    const Item = switch (kind) {
        .node => Node,
        .way => Way,
        .relation => Relation,
    };

    return struct {
        const Self = @This();
        block: Block,
        groups: Repeated(schema.PrimitiveBlock, "primitivegroup"),
        records: ?Repeated(schema.PrimitiveGroup, field) = null,
        dense: if (kind == .node) ?DenseIterator else void = if (kind == .node) null else {},

        fn init(block: Block) Self {
            return .{
                .block = block,
                .groups = block.view.get("primitivegroup", block.deadline) catch unreachable,
            };
        }

        pub fn next(self: *Self) Error!?Item {
            const block = self.block;
            const deadline = block.deadline;
            while (true) {
                try check(deadline);
                if (self.records) |*records| {
                    if (try records.next(deadline)) |view| {
                        const id = try view.get("id", deadline);
                        const tags = try TagIterator.separate(block, view);
                        return switch (kind) {
                            .node => .{
                                .id = id,
                                .tags = tags,
                                .lat = try block.coordinate(try view.get("lat", deadline), block.lat_offset, 90),
                                .lon = try block.coordinate(try view.get("lon", deadline), block.lon_offset, 180),
                            },
                            .way => .{
                                .id = id,
                                .tags = tags,
                                .refs = .{ .deltas = try view.get("refs", deadline), .deadline = deadline },
                            },
                            .relation => .{
                                .id = id,
                                .tags = tags,
                                .members = .{
                                    .roles = try view.get("roles_sid", deadline),
                                    .deltas = try view.get("memids", deadline),
                                    .types = try view.get("types", deadline),
                                    .strings = block.strings,
                                    .deadline = deadline,
                                },
                            },
                        };
                    }
                    self.records = null;
                }
                if (kind == .node) {
                    if (self.dense) |*dense| {
                        if (try dense.next(block)) |node| return node;
                        self.dense = null;
                    }
                }
                const group = try self.groups.next(deadline) orelse return null;
                self.records = try group.get(field, deadline);
                if (kind == .node) {
                    if (try group.get("dense", deadline)) |dense|
                        self.dense = try DenseIterator.init(dense, deadline);
                }
            }
        }
    };
}

fn decodeFixture(scratch: *Scratch, buffer: []u8, input: schema.PrimitiveBlock.Values) !Block {
    const bytes = try schema.PrimitiveBlock.encode(buffer, input, protobuf.no_deadline);
    return scratch.decode(std.testing.allocator, bytes, .none);
}

test "dense deltas, offsets and tags remain valid after advancing across groups" {
    const testing = std.testing;
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    var bytes: [1024]u8 = undefined;
    const block = try decodeFixture(&scratch, &bytes, .{
        .stringtable = .{ .s = &.{ "", "name", "point", "group" } },
        .granularity = 30,
        .date_granularity = 2000,
        .lat_offset = -50,
        .lon_offset = 125,
        .primitivegroup = &.{
            .{ .dense = .{
                .id = &.{ -2, -4, 12 },
                .lat = &.{ -6, 10, -6 },
                .lon = &.{ 9, -15, 8 },
                .keys_vals = &.{ 1, 2, 3, 0, 0, 0, 1, 2, 0 },
            } },
            .{},
            .{ .ways = &.{.{ .id = 6, .refs = &.{ -2, -4, 12 } }} },
            .{ .nodes = &.{.{ .id = 12, .lat = 100, .lon = -100 }} },
            .{ .dense = .{ .id = &.{20}, .lat = &.{0}, .lon = &.{0} } },
            .{ .relations = &.{.{
                .id = 24,
                .roles_sid = &.{ 3, 0, 3 },
                .memids = &.{ 6, -12, 36 },
                .types = &.{ 1, 0, 2 },
            }} },
        },
    });
    try testing.expectEqual(30, block.granularity);
    try testing.expectEqual(2000, block.date_granularity);
    try testing.expectEqual(-50, block.lat_offset);
    try testing.expectEqual(125, block.lon_offset);

    var nodes = block.nodes();
    var a = (try nodes.next()).?;
    var b = (try nodes.next()).?;
    var c = (try nodes.next()).?;
    const d = (try nodes.next()).?;
    var e = (try nodes.next()).?;
    try testing.expectEqualSlices(i64, &.{ -2, -6, 6, 12, 20 }, &.{ a.id, b.id, c.id, d.id, e.id });
    try testing.expectEqualSlices(i32, &.{ -2, 0, -1, 29, 0 }, &.{ a.lat, b.lat, c.lat, d.lat, e.lat });
    try testing.expectEqualSlices(i32, &.{ 3, 0, 1, -28, 1 }, &.{ a.lon, b.lon, c.lon, d.lon, e.lon });
    try testing.expectEqual(null, try nodes.next());
    const a_first = (try a.tags.next()).?;
    try testing.expectEqualStrings("name", a_first.key);
    try testing.expectEqualStrings("point", a_first.value);
    const a_second = (try a.tags.next()).?;
    try testing.expectEqualStrings("group", a_second.key);
    try testing.expectEqualStrings("", a_second.value);
    try testing.expectEqual(null, try a.tags.next());
    try testing.expectEqual(null, try b.tags.next());
    try testing.expectEqualStrings("point", (try c.tags.next()).?.value);
    try testing.expectEqual(null, try e.tags.next());
    const string_start = @intFromPtr(a_first.key.ptr);
    try testing.expect(string_start >= @intFromPtr(&bytes));
    try testing.expect(string_start + a_first.key.len <= @intFromPtr(&bytes) + bytes.len);

    var ways = block.ways();
    var way = (try ways.next()).?;
    try testing.expectEqual(6, way.id);
    try testing.expectEqual(-2, (try way.refs.next()).?);
    try testing.expectEqual(-6, (try way.refs.next()).?);
    try testing.expectEqual(6, (try way.refs.next()).?);
    try testing.expectEqual(null, try way.refs.next());
    try testing.expectEqual(null, try ways.next());

    var relations = block.relations();
    var relation = (try relations.next()).?;
    try testing.expectEqual(24, relation.id);
    const first = (try relation.members.next()).?;
    try testing.expectEqual(.way, first.type);
    try testing.expectEqual(6, first.ref);
    try testing.expectEqualStrings("group", first.role);
    const second = (try relation.members.next()).?;
    try testing.expectEqual(.node, second.type);
    try testing.expectEqual(-6, second.ref);
    try testing.expectEqualStrings("", second.role);
    const third = (try relation.members.next()).?;
    try testing.expectEqual(.relation, third.type);
    try testing.expectEqual(30, third.ref);
    try testing.expectEqual(null, try relation.members.next());
    try testing.expectEqual(null, try relations.next());
}

test "malformed primitive columns, indices and deltas fail safely" {
    const testing = std.testing;
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    var bytes: [1024]u8 = undefined;
    const table: schema.StringTable.Values = .{ .s = &.{ "", "name" } };
    try testing.expectError(error.InvalidStringTable, decodeFixture(&scratch, &bytes, .{
        .stringtable = .{ .s = &.{"wrong"} },
    }));
    try testing.expectError(error.InvalidGranularity, decodeFixture(&scratch, &bytes, .{
        .stringtable = table,
        .granularity = 0,
    }));
    const block = try decodeFixture(&scratch, &bytes, .{
        .stringtable = table,
        .primitivegroup = &.{.{
            .nodes = &.{
                .{ .id = 1, .lat = 0, .lon = 0, .keys = &.{1} },
                .{ .id = 2, .lat = 0, .lon = 0, .keys = &.{1}, .vals = &.{42} },
                .{ .id = 3, .lat = std.math.maxInt(i64), .lon = 0 },
            },
            .ways = &.{.{ .id = 1, .refs = &.{ std.math.maxInt(i64), 1 } }},
            .relations = &.{
                .{ .id = 1, .memids = &.{1}, .roles_sid = &.{0} },
                .{ .id = 2, .memids = &.{1}, .roles_sid = &.{0}, .types = &.{3} },
                .{ .id = 3, .memids = &.{1}, .roles_sid = &.{-1}, .types = &.{0} },
            },
        }},
    });
    var nodes = block.nodes();
    var short_tags = (try nodes.next()).?;
    try testing.expectError(error.InvalidTags, short_tags.tags.next());
    var bad_tag = (try nodes.next()).?;
    try testing.expectError(error.InvalidStringIndex, bad_tag.tags.next());
    try testing.expectError(error.InvalidCoordinate, nodes.next());

    var ways = block.ways();
    var way = (try ways.next()).?;
    try testing.expectEqual(std.math.maxInt(i64), (try way.refs.next()).?);
    try testing.expectError(error.DeltaOverflow, way.refs.next());

    var relations = block.relations();
    var short_members = (try relations.next()).?;
    try testing.expectError(error.InvalidMembers, short_members.members.next());
    var bad_type = (try relations.next()).?;
    try testing.expectError(error.InvalidMemberType, bad_type.members.next());
    var bad_role = (try relations.next()).?;
    try testing.expectError(error.InvalidStringIndex, bad_role.members.next());
}

test "short and surplus dense streams return errors" {
    const testing = std.testing;
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    var bytes: [128]u8 = undefined;
    const table: schema.StringTable.Values = .{ .s = &.{ "", "name" } };
    const cases = [_]struct { dense: schema.DenseNodes.Values, valid_nodes: usize, err: Error }{
        .{ .dense = .{ .id = &.{1}, .lat = &.{0} }, .valid_nodes = 0, .err = error.InvalidDenseColumns },
        .{ .dense = .{ .id = &.{1}, .lat = &.{0}, .lon = &.{ 0, 0 } }, .valid_nodes = 1, .err = error.InvalidDenseColumns },
        .{ .dense = .{ .id = &.{1}, .lat = &.{0}, .lon = &.{0}, .keys_vals = &.{ 1, 1 } }, .valid_nodes = 0, .err = error.InvalidDenseTags },
        .{ .dense = .{ .id = &.{1}, .lat = &.{0}, .lon = &.{0}, .keys_vals = &.{ 0, 0 } }, .valid_nodes = 1, .err = error.InvalidDenseTags },
        .{ .dense = .{ .id = &.{ std.math.maxInt(i64), 1 }, .lat = &.{ 0, 0 }, .lon = &.{ 0, 0 } }, .valid_nodes = 1, .err = error.DeltaOverflow },
    };
    for (cases) |case| {
        const block = try decodeFixture(&scratch, &bytes, .{
            .stringtable = table,
            .primitivegroup = &.{.{ .dense = case.dense }},
        });
        var nodes = block.nodes();
        for (0..case.valid_nodes) |_| try testing.expect((try nodes.next()) != null);
        try testing.expectError(case.err, nodes.next());
    }
}
