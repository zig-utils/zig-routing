// Ported from valhalla/baldr/sign.h and src/baldr/graphtile.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const grid = @import("../geo/grid.zig");
const cold = @import("cold.zig");
const reader = @import("reader.zig");
const format = @import("format.zig");

pub const Type = enum(u8) {
    exit_number = 0,
    exit_branch = 1,
    exit_toward = 2,
    exit_name = 3,
    guide_branch = 4,
    guide_toward = 5,
    junction_name = 6,
    guidance_view_junction = 7,
    guidance_view_signboard = 8,
    toll_name = 9,
    _,

    fn onNode(self: Type) bool {
        return self == .junction_name or self == .toll_name;
    }
};

/// Sorted by geographic cell, owner ID, owner kind, then sign type. Texts
/// of equal type stay in tag order. The cold name table owns the text.
pub const Entry = extern struct {
    cell: u32,
    owner: u32,
    text_ref: u32,
    attr: packed struct(u32) {
        sign_type: Type,
        route_number: bool = false,
        tagged: bool = false,
        reserved: u22 = 0,
    },

    pub fn key(self: Entry) u64 {
        return ownerKey(self.cell, self.owner);
    }

    pub fn text(self: Entry, names: cold.View) ![]const u8 {
        return (try names.name(self.text_ref)).text;
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Entry) == 16 and @alignOf(Entry) == 4);
    std.debug.assert(@offsetOf(Entry, "cell") == 0 and @offsetOf(Entry, "owner") == 4);
    std.debug.assert(@offsetOf(Entry, "text_ref") == 8 and @offsetOf(Entry, "attr") == 12);
}

fn ownerKey(cell: u32, id: u32) u64 {
    return (@as(u64, cell) << 32) | id;
}

pub fn hasSigns(graph: *const reader.View, id: format.EdgeId) !bool {
    return (try graph.class((try graph.edge(id)).cls.class_id)).flags.sign;
}

pub fn signsForEdge(graph: *const reader.View, id: format.EdgeId) ![]const Entry {
    const rows = graph.signs orelse return &.{};
    if (!try hasSigns(graph, id)) return &.{};
    const point = try edgeTail(graph, id);
    return find(rows, grid.snapCell(point.toPoint()), false, @backingInt(id));
}

pub fn signsForNode(graph: *const reader.View, id: format.NodeId) ![]const Entry {
    const rows = graph.signs orelse return &.{};
    const point = try graph.coordinate(id);
    return find(rows, grid.snapCell(point.toPoint()), true, @backingInt(id));
}

fn edgeTail(graph: *const reader.View, id: format.EdgeId) !format.Coordinate {
    const opposite = try graph.edge(try graph.oppEdge(id));
    return graph.coordinate(@fromBackingInt(opposite.head));
}

fn find(rows: []const Entry, cell: u32, node: bool, id: u32) []const Entry {
    const key = ownerKey(cell, id);
    const start = bound(rows, key, node, false);
    return rows[start .. bound(rows[start..], key, node, true) + start];
}

fn bound(rows: []const Entry, key: u64, node: bool, inclusive: bool) usize {
    var low: usize = 0;
    var high = rows.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const row = rows[mid];
        const rank = row.key();
        const on_node = row.attr.sign_type.onNode();
        if (rank < key or (rank == key and (if (on_node == node) inclusive else !on_node))) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

pub fn verify(graph: *const reader.View, deadline: io.Deadline) !void {
    const rows = graph.signs orelse return;
    if (rows.len == 0) return;
    const names = graph.cold_data orelse return error.MissingSection;
    var previous: ?Entry = null;
    for (rows, 0..) |row, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const sign_type = row.attr.sign_type;
        if (@backingInt(sign_type) > @backingInt(Type.toll_name) or row.attr.reserved != 0 or
            row.text_ref > std.math.maxInt(u31)) return error.InvalidSign;
        if (previous) |last| {
            if (last.key() > row.key() or (last.key() == row.key() and
                ((last.attr.sign_type.onNode() and !sign_type.onNode()) or
                    (last.attr.sign_type.onNode() == sign_type.onNode() and @backingInt(last.attr.sign_type) > @backingInt(sign_type)))))
                return error.UnsortedSigns;
        }
        const point = if (sign_type.onNode())
            try graph.coordinate(@fromBackingInt(row.owner))
        else edge: {
            const id: format.EdgeId = @fromBackingInt(row.owner);
            if (!try hasSigns(graph, id)) return error.InvalidSign;
            break :edge try edgeTail(graph, id);
        };
        if (row.cell != grid.snapCell(point.toPoint()) or (try row.text(names)).len == 0) return error.InvalidSign;
        previous = row;
    }
}
