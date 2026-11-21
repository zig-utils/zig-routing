//! Banded edit distance over consecutive UTF-8 dictionary keys.
const std = @import("std");
const unicode = @import("unicode.zig");

const max_scalars = 64;

pub const Matcher = struct {
    query: [max_scalars]u21 = undefined,
    query_len: usize = 0,
    previous: [max_scalars]u21 = undefined,
    computed: usize = 0,
    rows: [max_scalars + 1][max_scalars + 1]u8 = undefined,
    bound: u8 = 0,

    pub fn init(text: []const u8) ?Matcher {
        var self: Matcher = .{};
        self.query_len = points(text, &self.query) orelse return null;
        // Short keys and numeric identifiers require exact matching.
        if (self.query_len < 4 or std.ascii.isDigit(text[0])) return null;
        self.bound = if (self.query_len >= 9) 2 else 1;
        for (self.rows[0][0 .. self.query_len + 1], 0..) |*cell, i| cell.* = @intCast(i);
        return self;
    }

    pub fn distance(self: *Matcher, text: []const u8) ?u8 {
        var current: [max_scalars]u21 = undefined;
        const len = points(text, &current) orelse return null;
        if (len + self.bound < self.query_len or len > self.query_len + self.bound) return null;
        const prefix = @min(len, self.computed);
        const shared = std.mem.indexOfDiff(u21, self.previous[0..prefix], current[0..prefix]) orelse prefix;
        const outside: u8 = self.bound + 1;
        // A row whose band already exceeded the bound cannot match any
        // continuation. Reuse that conclusion for the next key's shared stem.
        if (shared != 0) {
            const first = @max(1, shared -| self.bound);
            const last = @min(self.query_len, shared + self.bound);
            if (minimum(self.rows[shared][first .. last + 1]) > self.bound) return null;
        }
        for (shared + 1..len + 1) |i| {
            const first = @max(1, i -| self.bound);
            const last = @min(self.query_len, i + self.bound);
            const row = &self.rows[i];
            const prior = &self.rows[i - 1];
            row[first - 1] = if (first == 1) @intCast(i) else outside;
            if (last < self.query_len) row[last + 1] = outside;
            for (first..last + 1) |j| {
                const substitute = prior[j - 1] + @intFromBool(current[i - 1] != self.query[j - 1]);
                var cost = @min(substitute, prior[j] + 1, row[j - 1] + 1);
                if (i > 1 and j > 1 and current[i - 1] == self.query[j - 2] and current[i - 2] == self.query[j - 1])
                    cost = @min(cost, self.rows[i - 2][j - 2] + 1);
                row[j] = cost;
            }
            if (minimum(row[first .. last + 1]) > self.bound) {
                self.remember(current[0..i]);
                return null;
            }
        }
        self.remember(current[0..len]);
        const result = self.rows[len][self.query_len];
        return if (result <= self.bound) result else null;
    }

    fn remember(self: *Matcher, points_read: []const u21) void {
        @memcpy(self.previous[0..points_read.len], points_read);
        self.computed = points_read.len;
    }
};

fn minimum(values: []const u8) u8 {
    var least: u8 = std.math.maxInt(u8);
    for (values) |value| least = @min(least, value);
    return least;
}

fn points(text: []const u8, buffer: *[max_scalars]u21) ?usize {
    var len: usize = 0;
    var offset: usize = 0;
    while (offset < text.len and len < buffer.len) : (len += 1) {
        const scalar = unicode.decode(text[offset..]) catch return null;
        buffer[len] = scalar.cp;
        offset += scalar.len;
    }
    return if (offset == text.len) len else null;
}

test "bounded edits reuse prefixes and handle adjacent transpositions and Unicode" {
    const t = std.testing;
    var letters = Matcher.init("garden").?;
    for ([_]struct { text: []const u8, expected: ?u8 }{
        .{ .text = "galaxy", .expected = null },
        .{ .text = "gannet", .expected = null },
        .{ .text = "gadren", .expected = 1 },
        .{ .text = "gard", .expected = null },
        .{ .text = "garden", .expected = 0 },
        .{ .text = "gardens", .expected = 1 },
        .{ .text = "garding", .expected = null },
        .{ .text = "warden", .expected = 1 },
    }) |pair| try t.expectEqual(pair.expected, letters.distance(pair.text));
    var cyrillic = Matcher.init("тверская").?;
    try t.expectEqual(@as(?u8, 1), cyrillic.distance("твреская"));
    try t.expectEqual(@as(?u8, 1), cyrillic.distance("тверска"));
    try t.expectEqual(null, cyrillic.distance("минская"));
}
