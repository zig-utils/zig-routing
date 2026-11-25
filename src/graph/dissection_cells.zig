//! The nested-dissection cell tree of a bundle whose node IDs follow that order.
//!
//! Each record is one cell, in preorder. A cell owns the node IDs [begin, end):
//! its children tile [begin, separator_begin) left to right, and its separator
//! is [separator_begin, end). A leaf has no children and an empty separator.
//! The cold records of those nodes follow the same layout in
//! [cold_begin, cold_end). `subtree_end` is one past the last record of the
//! cell's subtree, so every invariant is local to a cell and its children and
//! the table is checked in one pass, without recursion.
const std = @import("std");
const io = @import("../infra/io.zig");

pub const no_cell = std.math.maxInt(u32);

pub const Cell = extern struct {
    begin: u32,
    separator_begin: u32,
    end: u32,
    left: u32 = no_cell,
    right: u32 = no_cell,
    subtree_end: u32,
    cold_begin: u32 = 0,
    cold_separator: u32 = 0,
    cold_end: u32 = 0,
    reserved: u32 = 0,

    pub fn isLeaf(self: Cell) bool {
        return self.left == no_cell and self.right == no_cell;
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Cell) == 40 and @alignOf(Cell) == 4);
    std.debug.assert(@offsetOf(Cell, "begin") == 0 and @offsetOf(Cell, "separator_begin") == 4);
    std.debug.assert(@offsetOf(Cell, "end") == 8 and @offsetOf(Cell, "left") == 12);
    std.debug.assert(@offsetOf(Cell, "right") == 16 and @offsetOf(Cell, "subtree_end") == 20);
    std.debug.assert(@offsetOf(Cell, "cold_begin") == 24 and @offsetOf(Cell, "cold_separator") == 28);
    std.debug.assert(@offsetOf(Cell, "cold_end") == 32 and @offsetOf(Cell, "reserved") == 36);
}

/// Check the tree shape against the node count and, when the bundle has cold
/// data, its record count. Without cold data every cold field must be zero.
pub fn verify(cells: []const Cell, node_count: usize, cold_records: ?usize, deadline: io.Deadline) !void {
    if (node_count == 0) {
        if (cells.len != 0) return error.InvalidDissectionCells;
        return;
    }
    if (cells.len == 0 or cells.len >= no_cell or node_count >= no_cell) return error.InvalidDissectionCells;
    const records = cold_records orelse 0;
    if (records >= no_cell) return error.InvalidDissectionCells;
    const root = cells[0];
    if (root.begin != 0 or root.end != node_count or root.subtree_end != cells.len or
        root.cold_begin != 0 or root.cold_end != records) return error.InvalidDissectionCells;

    for (cells, 0..) |cell, index| {
        if (index % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (cell.reserved != 0 or cell.begin >= cell.end or
            cell.separator_begin < cell.begin or cell.separator_begin > cell.end or
            cell.subtree_end <= index or cell.subtree_end > cells.len or
            cell.cold_begin > cell.cold_separator or cell.cold_separator > cell.cold_end or cell.cold_end > records)
            return error.InvalidDissectionCells;
        if (cell.isLeaf()) {
            if (cell.separator_begin != cell.end or cell.subtree_end != index + 1 or
                cell.cold_separator != cell.cold_end) return error.InvalidDissectionCells;
            continue;
        }
        // The children's subtrees follow the cell in preorder and tile its
        // interior, both in node IDs and in cold records.
        var next: usize = index + 1;
        var nodes: u32 = cell.begin;
        var cold: u32 = cell.cold_begin;
        for ([_]u32{ cell.left, cell.right }) |child_index| {
            if (child_index == no_cell) continue;
            if (child_index != next or child_index >= cells.len) return error.InvalidDissectionCells;
            const child = cells[child_index];
            if (child.begin != nodes or child.cold_begin != cold) return error.InvalidDissectionCells;
            nodes = child.end;
            cold = child.cold_end;
            next = child.subtree_end;
        }
        if (next != cell.subtree_end or nodes != cell.separator_begin or cold != cell.cold_separator)
            return error.InvalidDissectionCells;
    }
}

const testing = std.testing;

/// Seven nodes and six cold records. The root's separator is node 6, its left
/// leaf holds [0, 2) and its right cell [2, 6) has leaves [2, 3) and [3, 5)
/// with separator node 5.
fn sample() [5]Cell {
    return .{
        .{ .begin = 0, .separator_begin = 6, .end = 7, .left = 1, .right = 2, .subtree_end = 5, .cold_begin = 0, .cold_separator = 5, .cold_end = 6 },
        .{ .begin = 0, .separator_begin = 2, .end = 2, .subtree_end = 2, .cold_begin = 0, .cold_separator = 1, .cold_end = 1 },
        .{ .begin = 2, .separator_begin = 5, .end = 6, .left = 3, .right = 4, .subtree_end = 5, .cold_begin = 1, .cold_separator = 4, .cold_end = 5 },
        .{ .begin = 2, .separator_begin = 3, .end = 3, .subtree_end = 4, .cold_begin = 1, .cold_separator = 2, .cold_end = 2 },
        .{ .begin = 3, .separator_begin = 5, .end = 5, .subtree_end = 5, .cold_begin = 2, .cold_separator = 4, .cold_end = 4 },
    };
}

test "a well-formed cell table verifies, with and without cold records" {
    const cells = sample();
    try verify(&cells, 7, 6, .none);
    var no_cold = cells;
    for (&no_cold) |*cell| {
        cell.cold_begin = 0;
        cell.cold_separator = 0;
        cell.cold_end = 0;
    }
    try verify(&no_cold, 7, null, .none);
    try verify(&.{}, 0, null, .none);
    // One leaf holding every node.
    try verify(&.{.{ .begin = 0, .separator_begin = 3, .end = 3, .subtree_end = 1 }}, 3, null, .none);
    // A cell with one child, and a zero-node separator between two children.
    try verify(&.{
        .{ .begin = 0, .separator_begin = 2, .end = 3, .left = 1, .subtree_end = 2 },
        .{ .begin = 0, .separator_begin = 2, .end = 2, .subtree_end = 2 },
    }, 3, null, .none);
    try verify(&.{
        .{ .begin = 0, .separator_begin = 3, .end = 3, .left = 1, .right = 2, .subtree_end = 3 },
        .{ .begin = 0, .separator_begin = 1, .end = 1, .subtree_end = 2 },
        .{ .begin = 1, .separator_begin = 3, .end = 3, .subtree_end = 3 },
    }, 3, null, .none);
    try testing.expectError(error.DeadlineExceeded, verify(&cells, 7, 6, .{ .at_ns = 0 }));
}

test "each violated cell table invariant is rejected" {
    const Mutation = struct { index: usize, field: []const u8, value: u32 };
    const mutations = [_]Mutation{
        // The root must cover every node and every cold record.
        .{ .index = 0, .field = "begin", .value = 1 },
        .{ .index = 0, .field = "end", .value = 6 },
        .{ .index = 0, .field = "subtree_end", .value = 4 },
        .{ .index = 0, .field = "cold_end", .value = 5 },
        // Separators must be a suffix of the cell, after its children.
        .{ .index = 0, .field = "separator_begin", .value = 5 },
        .{ .index = 2, .field = "separator_begin", .value = 7 },
        // Children must follow in preorder and tile the interior.
        .{ .index = 0, .field = "right", .value = 3 },
        .{ .index = 0, .field = "left", .value = 2 },
        .{ .index = 2, .field = "left", .value = 9 },
        .{ .index = 4, .field = "begin", .value = 4 },
        .{ .index = 3, .field = "end", .value = 4 },
        .{ .index = 2, .field = "subtree_end", .value = 4 },
        // A leaf has no separator and a one-record subtree.
        .{ .index = 1, .field = "separator_begin", .value = 1 },
        .{ .index = 1, .field = "subtree_end", .value = 3 },
        // Cells are nonempty and the reserved word is zero.
        .{ .index = 3, .field = "begin", .value = 3 },
        .{ .index = 4, .field = "reserved", .value = 1 },
        // Cold records follow the node layout.
        .{ .index = 1, .field = "cold_end", .value = 2 },
        .{ .index = 4, .field = "cold_begin", .value = 3 },
        .{ .index = 2, .field = "cold_separator", .value = 3 },
    };
    for (mutations) |mutation| {
        var cells = sample();
        inline for (@typeInfo(Cell).@"struct".field_names) |name| {
            if (std.mem.eql(u8, name, mutation.field)) @field(cells[mutation.index], name) = mutation.value;
        }
        verify(&cells, 7, 6, .none) catch continue;
        std.debug.print("accepted {s} = {d} on cell {d}\n", .{ mutation.field, mutation.value, mutation.index });
        return error.TestUnexpectedResult;
    }
    const cells = sample();
    try testing.expectError(error.InvalidDissectionCells, verify(&cells, 8, 6, .none));
    try testing.expectError(error.InvalidDissectionCells, verify(&cells, 7, null, .none));
    try testing.expectError(error.InvalidDissectionCells, verify(&cells, 0, null, .none));
    try testing.expectError(error.InvalidDissectionCells, verify(&.{}, 7, null, .none));
    try testing.expectError(error.InvalidDissectionCells, verify(cells[0..4], 7, 6, .none));
}
