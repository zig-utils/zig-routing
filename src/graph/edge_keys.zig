//! Stable directed identities and their cold, memory-mapped lookup tables.
const std = @import("std");
const Deadline = @import("../infra/io.zig").Deadline;
const EdgeId = @import("format.zig").EdgeId;

pub const Kind = enum(u2) { osm, node_connector, transit, _ };
pub const Direction = enum { forward, reverse };

pub const Key = extern struct {
    way_id: i64,
    begin_node: i64,
    end_node: i64,
    flags: packed struct(u64) {
        occurrence: u32 = 0,
        reversed: bool = false,
        kind: Kind = .osm,
        reserved: u29 = 0,
    } = .{},

    pub fn parse(text: []const u8) error{InvalidEdgeKey}!Key {
        var parts = std.mem.splitScalar(u8, text, ',');
        var key: Key = .{
            .way_id = try parsePart(i64, parts.next()),
            .begin_node = try parsePart(i64, parts.next()),
            .end_node = try parsePart(i64, parts.next()),
        };
        const direction = std.meta.stringToEnum(Direction, parts.next() orelse return error.InvalidEdgeKey) orelse
            return error.InvalidEdgeKey;
        key.flags.reversed = direction == .reverse;
        if (parts.next()) |occurrence| key.flags.occurrence = try parsePart(u32, occurrence);
        if (parts.next()) |kind| key.flags.kind = std.meta.stringToEnum(Kind, kind) orelse return error.InvalidEdgeKey;
        if (!key.valid() or parts.next() != null) return error.InvalidEdgeKey;
        return key;
    }

    fn parsePart(comptime T: type, part: ?[]const u8) error{InvalidEdgeKey}!T {
        return std.fmt.parseInt(T, part orelse return error.InvalidEdgeKey, 10) catch error.InvalidEdgeKey;
    }

    pub fn order(left: Key, right: Key) std.math.Order {
        inline for (.{ "way_id", "begin_node", "end_node" }) |field| {
            const comparison = std.math.order(@field(left, field), @field(right, field));
            if (comparison != .eq) return comparison;
        }
        return std.math.order(@as(u64, @bitCast(left.flags)), @as(u64, @bitCast(right.flags)));
    }

    pub fn valid(self: Key) bool {
        return self.flags.reserved == 0 and switch (self.flags.kind) {
            .osm, .node_connector, .transit => true,
            _ => false,
        };
    }

    pub fn hash(self: Key, seed: u64) u64 {
        return std.hash.Wyhash.hash(seed, std.mem.asBytes(&self));
    }
};

pub const Record = extern struct {
    key: Key,
    edge: u32,
    reserved: u32 = 0,
};

pub const HashHeader = extern struct {
    seed: u64,
    version: u32 = 1,
    reserved: u32 = 0,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Key) == 32 and @offsetOf(Key, "way_id") == 0);
    std.debug.assert(@offsetOf(Key, "begin_node") == 8 and @offsetOf(Key, "end_node") == 16 and @offsetOf(Key, "flags") == 24);
    std.debug.assert(@sizeOf(Record) == 40 and @offsetOf(Record, "key") == 0 and @offsetOf(Record, "edge") == 32 and @offsetOf(Record, "reserved") == 36);
    std.debug.assert(@sizeOf(HashHeader) == 16 and @offsetOf(HashHeader, "seed") == 0 and @offsetOf(HashHeader, "version") == 8 and @offsetOf(HashHeader, "reserved") == 12);
}

pub const empty_bucket = std.math.maxInt(u64);
pub const singleton_bucket: u64 = 1 << 63;

pub const Hash = struct {
    seed: u64,
    buckets: []const u64,
    slots: []const u32,

    pub fn bucketFor(self: Hash, key: Key) usize {
        return @intCast(key.hash(self.seed) % self.buckets.len);
    }

    pub fn slotFor(key: Key, displacement: u64, count: usize) usize {
        return @intCast(key.hash(displacement) % count);
    }

    fn candidate(self: Hash, key: Key) !?u32 {
        if (self.slots.len == 0 or self.buckets.len == 0) return error.InvalidEdgeKeyHash;
        const displacement = self.buckets[self.bucketFor(key)];
        if (displacement == empty_bucket) return null;
        const slot = if (displacement & singleton_bucket != 0) displacement & ~singleton_bucket else slotFor(key, displacement, self.slots.len);
        if (slot >= self.slots.len) return error.InvalidEdgeKeyHash;
        return self.slots[@intCast(slot)];
    }
};

pub const View = struct {
    records: []const Record,
    inverse: []const u32,
    hash: ?Hash = null,

    pub fn find(self: View, wanted: Key) !?EdgeId {
        if (!wanted.valid()) return error.InvalidEdgeKey;
        const index = if (self.hash) |table| (try table.candidate(wanted)) orelse return null else self.lowerBound(wanted);
        if (index >= self.records.len) {
            if (self.hash != null) return error.InvalidEdgeKeyHash;
            return null;
        }
        const row = self.records[index];
        if (row.key.order(wanted) != .eq) return null;
        if (row.edge >= self.inverse.len) return error.InvalidEdgeKeyIndex;
        return @fromBackingInt(row.edge);
    }

    pub fn key(self: View, edge: EdgeId) !Key {
        const id = @backingInt(edge);
        if (id >= self.inverse.len) return error.InvalidEdgeId;
        const row = self.inverse[id];
        if (row >= self.records.len or self.records[row].edge != id) return error.InvalidEdgeKeyIndex;
        const result = self.records[row].key;
        if (!result.valid()) return error.InvalidEdgeKey;
        return result;
    }

    pub fn verify(self: View, edge_count: usize, deadline: Deadline) !void {
        if (self.records.len != edge_count or self.inverse.len != edge_count) return error.InvalidEdgeKeyIndex;
        if (self.hash) |table| {
            if (table.slots.len != edge_count or table.buckets.len == 0 or table.buckets.len > edge_count)
                return error.InvalidEdgeKeyHash;
            for (table.buckets, 0..) |bucket, i| {
                if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (bucket != empty_bucket and bucket & singleton_bucket != 0 and bucket & ~singleton_bucket >= edge_count)
                    return error.InvalidEdgeKeyHash;
            }
        }
        var previous: ?Key = null;
        for (self.records, 0..) |record, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (record.reserved != 0 or !record.key.valid()) return error.InvalidEdgeKey;
            if (previous) |prev| if (prev.order(record.key) != .lt) return error.UnsortedEdgeKeys;
            if (record.edge >= self.inverse.len or self.inverse[record.edge] != i) return error.InvalidEdgeKeyIndex;
            if (self.hash) |table| if (try table.candidate(record.key) != @as(u32, @intCast(i))) return error.InvalidEdgeKeyHash;
            previous = record.key;
        }
    }

    fn lowerBound(self: View, wanted: Key) usize {
        var low: usize = 0;
        var high = self.records.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.records[mid].key.order(wanted) == .lt) low = mid + 1 else high = mid;
        }
        return low;
    }
};

test "edge keys distinguish source occurrences and reverse dense ids" {
    const testing = std.testing;
    const forward: Key = .{ .way_id = 71, .begin_node = 8, .end_node = 9 };
    var repeated = forward;
    repeated.flags.occurrence = 1;
    const entries = [_]Record{ .{ .key = forward, .edge = 1 }, .{ .key = repeated, .edge = 0 } };
    const view: View = .{ .records = &entries, .inverse = &.{ 1, 0 } };
    try view.verify(2, .none);
    const first: EdgeId = @fromBackingInt(@as(u32, 1));
    try testing.expectEqual(@as(?EdgeId, first), try view.find(forward));
    try testing.expectEqualDeep(repeated, try view.key(@fromBackingInt(@as(u32, 0))));
    try testing.expectEqual(null, try view.find(.{ .way_id = 71, .begin_node = 9, .end_node = 8 }));
    try testing.expectError(error.InvalidEdgeId, view.key(@fromBackingInt(@as(u32, 2))));
}
