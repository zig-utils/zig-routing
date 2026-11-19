//! Optional turn geometry. A node block's occupancy mask and prefix offset
//! locate its word-aligned matrix without widening the core turn rows.
const std = @import("std");

pub const block_nodes = 32;
pub const entries_per_word = 16;

pub const Sides = packed struct(u2) {
    left: bool = false,
    right: bool = false,
};

pub fn directoryEnd(nodes: usize) usize {
    return 1 + ((nodes + block_nodes - 1) / block_nodes) * 2;
}

pub const View = struct {
    words: []const u32,
    directory_end: usize,
    matrices_start: usize,
    node_count: usize,

    pub fn parse(words: []const u32, node_count: usize) !View {
        const end = directoryEnd(node_count);
        if (words.len < end) return error.TruncatedTurnSideDirectory;
        const matrices_start = words[0];
        if (matrices_start < end or matrices_start > words.len or matrices_start - end > node_count)
            return error.InvalidTurnSideDirectory;
        return .{ .words = words, .directory_end = end, .matrices_start = matrices_start, .node_count = node_count };
    }

    pub fn at(self: View, node: u32, degree: u32, from: u5, to: u5) !Sides {
        if (node >= self.node_count or degree > 32 or from >= degree or to >= degree) return error.InvalidLocalEdge;
        const block = 1 + @as(usize, node / block_nodes) * 2;
        const mask = self.words[block];
        const bit = @as(u32, 1) << @as(u5, @truncate(node));
        if (mask & bit == 0) return .{};
        const first = self.words[block + 1];
        const rank = @popCount(mask & (bit - 1));
        const reference = @as(usize, first) + rank;
        if (first < self.directory_end or reference >= self.matrices_start) return error.InvalidTurnSideReference;
        const index = @as(u32, from) * degree + to;
        const start = self.words[reference];
        const size = (degree * degree + entries_per_word - 1) / entries_per_word;
        if (start < self.matrices_start or @as(usize, start) + size > self.words.len) return error.InvalidTurnSideOffset;
        const shift: u5 = @intCast(index % entries_per_word * 2);
        return @bitCast(@as(u2, @truncate(self.words[@as(usize, start) + index / entries_per_word] >> shift)));
    }
};

test "sparse matrices validate references and select ranked bits" {
    const test_case = std.testing;
    var words = [_]u32{ 7, 0b1001, 5, 0, 7, 7, 8, 0b0011, 0b0110 };
    const view = try View.parse(&words, 33);
    try test_case.expectEqual(Sides{ .left = true, .right = true }, try view.at(0, 3, 0, 0));
    try test_case.expectEqual(Sides{ .left = true }, try view.at(3, 3, 0, 1));
    try test_case.expectEqual(Sides{}, try view.at(32, 3, 0, 0));
    try test_case.expectError(error.InvalidLocalEdge, view.at(33, 3, 0, 0));
    words[6] = 1;
    try test_case.expectError(error.InvalidTurnSideOffset, view.at(3, 3, 0, 1));
    words[2] = 7;
    try test_case.expectError(error.InvalidTurnSideReference, view.at(0, 3, 0, 0));
}
