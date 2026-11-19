// Ported from src/mjolnir/pbfgraphparser.cc (Valhalla 3.9.3).

const std = @import("std");

pub const Shape = enum { short, open, closed };

pub fn inspect(refs: anytype) !Shape {
    var iter = refs;
    const first = try iter.next() orelse return .short;
    var last = try iter.next() orelse return .short;
    while (try iter.next()) |id| last = id;
    return if (first == last) .closed else .open;
}

pub fn accepts(shape: Shape, source: anytype) !bool {
    if (shape != .closed) return shape == .open;
    var iter = source;
    while (try iter.next()) |tag| {
        for ([_][]const u8{ "building", "landuse", "leisure", "natural" }) |key| {
            if (std.mem.eql(u8, tag.key, key)) return false;
        }
    }
    return true;
}
