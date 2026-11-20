// Ported from valhalla/baldr/turnlanes.h and src/baldr/laneconnectivity.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const format = @import("format.zig");
const View = @import("reader.zig").View;

pub const Mask = u16;
pub const none: Mask = 1 << 0;
pub const through: Mask = 1 << 1;
pub const sharp_left: Mask = 1 << 2;
pub const left: Mask = 1 << 3;
pub const slight_left: Mask = 1 << 4;
pub const slight_right: Mask = 1 << 5;
pub const right: Mask = 1 << 6;
pub const sharp_right: Mask = 1 << 7;
pub const reverse: Mask = 1 << 8;
pub const merge_to_left: Mask = 1 << 9;
pub const merge_to_right: Mask = 1 << 10;
const known_masks: Mask = (merge_to_right << 1) - 1;

pub const Entry = extern struct {
    edge: u32,
    offset: u32,
};

/// The high nibble is unused. Bits 0-3 store the first lane number.
pub const Connection = extern struct {
    from_way: u64,
    to_lanes: u64,
    from_lanes: u64,
    edge: u32,
    reserved: u32 = 0,

    pub const max_lanes = 15;

    pub fn lane(mask: u64, position: u4) u4 {
        return @truncate(mask >> (@as(u6, position) * 4));
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Entry) == 8 and @alignOf(Entry) == 4);
    std.debug.assert(@offsetOf(Entry, "edge") == 0 and @offsetOf(Entry, "offset") == 4);
    std.debug.assert(@sizeOf(Connection) == 32 and @alignOf(Connection) == 8);
    std.debug.assert(@offsetOf(Connection, "from_way") == 0 and @offsetOf(Connection, "to_lanes") == 8);
    std.debug.assert(@offsetOf(Connection, "from_lanes") == 16 and @offsetOf(Connection, "edge") == 24);
    std.debug.assert(@offsetOf(Connection, "reserved") == 28);
}

/// Payload layout is a u32 entry count, the sorted index, and contiguous u16 masks.
pub const Table = struct {
    entries: []const Entry,
    masks: []const Mask,

    pub fn parse(words: []const u16) !Table {
        if (words.len < 2 or !std.mem.isAligned(@intFromPtr(words.ptr), @alignOf(Entry))) return error.InvalidTurnLanes;
        const count = std.mem.readInt(u32, std.mem.sliceAsBytes(words[0..2])[0..4], .little);
        const stride = @sizeOf(Entry) / @sizeOf(u16);
        if (count > (words.len - 2) / stride) return error.InvalidTurnLanes;
        const end = 2 + @as(usize, count) * stride;
        const index: []align(@alignOf(Entry)) const u8 = @alignCast(std.mem.sliceAsBytes(words[2..end]));
        return .{ .entries = std.mem.bytesAsSlice(Entry, index), .masks = words[end..] };
    }

    fn at(self: Table, index: usize) ![]const Mask {
        const start = self.entries[index].offset;
        const end = if (index + 1 == self.entries.len) self.masks.len else self.entries[index + 1].offset;
        if (start >= end or end > self.masks.len) return error.InvalidTurnLanes;
        return self.masks[start..end];
    }
};

pub fn turnLanes(view: *const View, edge: format.EdgeId) ![]const Mask {
    const id = @backingInt(edge);
    const directed = try view.edge(edge);
    const table = view.turn_lane_index orelse return &.{};
    if (!(try view.class(directed.cls.class_id)).flags.turnlanes) return &.{};
    const index = std.sort.lowerBound(Entry, table.entries, id, compareEdge(Entry));
    if (index == table.entries.len or table.entries[index].edge != id) return error.InvalidTurnLanes;
    return table.at(index);
}

pub fn laneConnectivity(view: *const View, edge: format.EdgeId) ![]const Connection {
    const directed = try view.edge(edge);
    const rows = view.lane_connectivity orelse return &.{};
    if (!(try view.class(directed.cls.class_id)).flags.lane_conn) return &.{};
    const id = @backingInt(edge);
    const first = std.sort.lowerBound(Connection, rows, id, compareEdge(Connection));
    if (first == rows.len or rows[first].edge != id) return error.InvalidLaneConnectivity;
    return rows[first .. first + std.sort.upperBound(Connection, rows[first..], id, compareEdge(Connection))];
}

fn compareEdge(comptime T: type) fn (u32, T) std.math.Order {
    return struct {
        fn compare(id: u32, row: T) std.math.Order {
            return std.math.order(id, row.edge);
        }
    }.compare;
}

pub fn verifyTurns(view: *const View, deadline: io.Deadline) !void {
    const table = view.turn_lane_index orelse return;
    if (table.entries.len == 0) {
        if (table.masks.len != 0) return error.InvalidTurnLanes;
        return;
    }
    if (table.entries[0].offset != 0) return error.InvalidTurnLanes;
    for (table.entries, 0..) |row, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (i != 0 and table.entries[i - 1].edge >= row.edge) return error.InvalidTurnLanes;
        const class = try view.class((try view.edge(@fromBackingInt(row.edge))).cls.class_id);
        if (!class.flags.turnlanes) return error.InvalidTurnLanes;
        _ = try table.at(i);
    }
    for (table.masks, 0..) |mask, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (mask & ~known_masks != 0) return error.InvalidTurnLanes;
    }
}

pub fn verifyConnectivity(view: *const View, deadline: io.Deadline) !void {
    const rows = view.lane_connectivity orelse return;
    for (rows, 0..) |row, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (row.reserved != 0 or row.from_way == 0 or (row.to_lanes | row.from_lanes) >> 60 != 0 or
            (i != 0 and rows[i - 1].edge > row.edge)) return error.InvalidLaneConnectivity;
        const class = try view.class((try view.edge(@fromBackingInt(row.edge))).cls.class_id);
        if (!class.flags.lane_conn) return error.InvalidLaneConnectivity;
    }
}
