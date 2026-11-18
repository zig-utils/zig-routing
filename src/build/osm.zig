//! The OSM element model every input reader produces: the XML reader here
//! (P3.03) and the PBF block reader (P3.01, P3.02). Build stages consume
//! `Element`s and never see the input format.
//!
//! Coordinates are fixed-point integers in units of 1e-7 degrees, which is
//! what OSM stores, what a PBF holds at its default granularity, and what
//! osmium (upstream's reader) uses, so the same node read from XML or PBF is
//! the same integer and nothing depends on float parsing.
//!
//! A reader yields elements in osmium's sorted order: all nodes, then all
//! ways, then all relations, each by id (negative ids first by absolute
//! value). Slices in an element (tags, refs, members, strings) belong to the
//! reader and stay valid until its next call.

const std = @import("std");

/// Degrees to fixed-point units.
pub const coordinate_scale = 10_000_000;

pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

pub const Node = struct {
    id: i64,
    /// Latitude and longitude in 1e-7 degrees.
    lat: i32,
    lon: i32,
    tags: []const Tag,

    pub fn latDegrees(self: Node) f64 {
        return @as(f64, @floatFromInt(self.lat)) / coordinate_scale;
    }

    pub fn lonDegrees(self: Node) f64 {
        return @as(f64, @floatFromInt(self.lon)) / coordinate_scale;
    }
};

pub const Way = struct {
    id: i64,
    refs: []const i64,
    tags: []const Tag,
};

pub const MemberType = enum(u2) { node = 0, way = 1, relation = 2 };

pub const Member = struct {
    type: MemberType,
    ref: i64,
    role: []const u8,
};

pub const Relation = struct {
    id: i64,
    members: []const Member,
    tags: []const Tag,
};

pub const Kind = enum(u2) { node = 0, way = 1, relation = 2 };

pub const Element = union(Kind) {
    node: Node,
    way: Way,
    relation: Relation,

    pub fn id(self: Element) i64 {
        return switch (self) {
            inline else => |e| e.id,
        };
    }

    /// Value of the first tag with `key`, if any.
    pub fn tag(self: Element, key: []const u8) ?[]const u8 {
        const tags = switch (self) {
            inline else => |e| e.tags,
        };
        for (tags) |t| if (std.mem.eql(u8, t.key, key)) return t.value;
        return null;
    }
};

/// osmium's sort key (`object_order_type_id_version`): type, then ids that
/// are not positive (negative ones and 0) before positive ones, each by
/// absolute value.
pub fn orderKey(kind: Kind, element_id: i64) struct { u2, u1, u64 } {
    return .{ @backingInt(kind), @intFromBool(element_id > 0), @abs(element_id) };
}

/// True when `b` may follow `a` in a sorted file (strictly after it).
pub fn inOrder(a_kind: Kind, a_id: i64, b_kind: Kind, b_id: i64) bool {
    const a = orderKey(a_kind, a_id);
    const b = orderKey(b_kind, b_id);
    if (a[0] != b[0]) return a[0] < b[0];
    if (a[1] != b[1]) return a[1] < b[1];
    return a[2] < b[2];
}

/// Parses a decimal coordinate ("47.1234567", "-9.5", "8") into 1e-7
/// degrees exactly: up to seven decimals taken as they are, further digits
/// rounded half away from zero, as osmium does. Null when it is not a plain
/// decimal number or lies outside [-limit, limit] degrees.
pub fn parseCoordinate(s: []const u8, limit_degrees: i64) ?i32 {
    var i: usize = 0;
    const neg = s.len > 0 and (s[0] == '-' or s[0] == '+');
    const sign_minus = s.len > 0 and s[0] == '-';
    if (neg) i = 1;
    var int_part: i64 = 0;
    var int_digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        if (int_digits >= 4) return null;
        int_part = int_part * 10 + (s[i] - '0');
        int_digits += 1;
    }
    var frac: i64 = 0;
    var frac_digits: usize = 0;
    var round_up = false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            if (frac_digits < 7) {
                frac = frac * 10 + (s[i] - '0');
                frac_digits += 1;
            } else if (i == start + 7) {
                round_up = s[i] >= '5';
            }
        }
        if (i == start and int_digits == 0) return null;
    }
    if (int_digits == 0 and frac_digits == 0) return null;
    if (i != s.len) return null;
    while (frac_digits < 7) : (frac_digits += 1) frac *= 10;
    var units = int_part * coordinate_scale + frac + @intFromBool(round_up);
    if (units > limit_degrees * coordinate_scale) return null;
    if (sign_minus) units = -units;
    return @intCast(units);
}

const testing = std.testing;

test "coordinates parse exactly to 1e-7 degrees" {
    try testing.expectEqual(@as(?i32, 471234567), parseCoordinate("47.1234567", 90));
    try testing.expectEqual(@as(?i32, -95000000), parseCoordinate("-9.5", 180));
    try testing.expectEqual(@as(?i32, 80000000), parseCoordinate("8", 180));
    try testing.expectEqual(@as(?i32, 5000000), parseCoordinate(".5", 180));
    try testing.expectEqual(@as(?i32, 471234568), parseCoordinate("47.12345675", 90)); // rounds half up
    try testing.expectEqual(@as(?i32, -471234568), parseCoordinate("-47.123456751", 90));
    try testing.expectEqual(@as(?i32, 471234567), parseCoordinate("47.12345674999", 90));
    try testing.expectEqual(@as(?i32, 1800000000), parseCoordinate("180", 180));
    try testing.expectEqual(@as(?i32, null), parseCoordinate("180.0000001", 180));
    try testing.expectEqual(@as(?i32, null), parseCoordinate("90.1", 90));
    try testing.expectEqual(@as(?i32, null), parseCoordinate("1e5", 180));
    try testing.expectEqual(@as(?i32, null), parseCoordinate("", 180));
    try testing.expectEqual(@as(?i32, null), parseCoordinate("-", 180));
    try testing.expectEqual(@as(?i32, null), parseCoordinate("1.2.3", 180));
}

test "osmium sort order" {
    try testing.expect(inOrder(.node, 1, .node, 2));
    try testing.expect(!inOrder(.node, 2, .node, 2));
    try testing.expect(inOrder(.node, -1, .node, -2)); // negatives by absolute value
    try testing.expect(inOrder(.node, -5, .node, 1)); // negatives first
    try testing.expect(inOrder(.node, 0, .node, -1)); // 0 sorts with the negatives, first
    try testing.expect(inOrder(.node, -1, .node, 1));
    try testing.expect(inOrder(.node, 99, .way, 1));
    try testing.expect(!inOrder(.relation, 1, .way, 5));
}
