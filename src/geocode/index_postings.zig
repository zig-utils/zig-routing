//! Importance-ordered record IDs with signed deltas and periodic skip offsets.
const std = @import("std");
const wire = @import("protobuf").wire;
const io = @import("../infra/io.zig");
const RecordId = @import("index_model.zig").RecordId;
const Allocator = std.mem.Allocator;

pub const checkpoint_stride = 64;

pub const List = struct {
    bytes: []const u8,
    count: u32,

    pub fn init(bytes: []const u8, count: u32) !List {
        if (count == 0 or directoryBytes(count) >= bytes.len) return error.InvalidGeocodePostings;
        return .{ .bytes = bytes, .count = count };
    }

    pub fn iterator(self: List) Iterator {
        return .{ .list = self, .body = self.bytes[directoryBytes(self.count)..] };
    }

    pub fn validate(self: List, total_records: u64, deadline: io.Deadline) !void {
        var cursor = self.iterator();
        while (cursor.ordinal < self.count) {
            if (cursor.ordinal % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const record = (try cursor.next()).?;
            if (record >= total_records) return error.InvalidGeocodeRecordId;
        }
        if (cursor.offset != cursor.body.len) return error.InvalidGeocodePostings;
    }
};

fn directoryBytes(count: u32) usize {
    return @as(usize, (count -| 1) / checkpoint_stride) * @sizeOf(u32);
}

pub const Iterator = struct {
    list: List,
    body: []const u8,
    ordinal: u32 = 0,
    offset: usize = 0,
    previous: ?RecordId = null,

    pub fn next(self: *Iterator) !?RecordId {
        if (self.ordinal == self.list.count) return null;
        const start_group = self.ordinal % checkpoint_stride == 0;
        if (start_group and self.ordinal != 0 and self.offset != self.checkpoint(self.ordinal / checkpoint_stride))
            return error.InvalidGeocodePostings;
        if (self.offset >= self.body.len) return error.InvalidGeocodePostings;
        var reader = wire.Reader.init(self.body[self.offset..]);
        const raw = try reader.readVarint();
        const used = self.body.len - self.offset - reader.remaining.len;
        if (used != wire.varintSize(raw)) return error.InvalidGeocodePostings;
        const id = if (start_group)
            std.math.cast(RecordId, raw) orelse return error.InvalidGeocodeRecordId
        else blk: {
            const delta = wire.zigzagDecode(i64, raw);
            const previous = self.previous orelse return error.InvalidGeocodePostings;
            const next_id = std.math.add(i64, previous, delta) catch return error.InvalidGeocodeRecordId;
            break :blk std.math.cast(RecordId, next_id) orelse return error.InvalidGeocodeRecordId;
        };
        if (self.previous == id) return error.InvalidGeocodePostings;
        self.offset += used;
        self.ordinal += 1;
        self.previous = id;
        return id;
    }

    /// Position by rank in the importance ordering. At most 63 deltas
    /// are decoded after jumping to the corresponding checkpoint.
    pub fn seek(self: *Iterator, ordinal: u32) !void {
        if (ordinal >= self.list.count) return error.InvalidGeocodePostingOrdinal;
        const group = ordinal / checkpoint_stride;
        self.ordinal = group * checkpoint_stride;
        self.offset = if (group == 0) 0 else self.checkpoint(group);
        self.previous = null;
        while (self.ordinal < ordinal) _ = try self.next();
    }

    fn checkpoint(self: Iterator, group: u32) usize {
        const offset = @as(usize, group - 1) * @sizeOf(u32);
        return std.mem.readInt(u32, self.list.bytes[offset..][0..4], .little);
    }
};

pub const Writer = struct {
    a: Allocator,
    output: *std.ArrayList(u8),
    count: u32,
    start: usize,
    body: usize,
    ordinal: u32 = 0,
    previous: RecordId = 0,

    pub fn init(a: Allocator, output: *std.ArrayList(u8), count: u32) !Writer {
        if (count == 0) return error.InvalidGeocodePostings;
        const start = output.items.len;
        @memset(try output.addManyAsSlice(a, directoryBytes(count)), 0);
        return .{ .a = a, .output = output, .count = count, .start = start, .body = output.items.len };
    }

    pub fn append(self: *Writer, id: RecordId) !void {
        if (self.ordinal >= self.count or (self.ordinal != 0 and self.previous == id)) return error.InvalidGeocodePostings;
        const start_group = self.ordinal % checkpoint_stride == 0;
        if (start_group and self.ordinal != 0) {
            const offset = std.math.cast(u32, self.output.items.len - self.body) orelse return error.GeocodePostingListTooLarge;
            const index = self.start + (@as(usize, self.ordinal / checkpoint_stride) - 1) * @sizeOf(u32);
            std.mem.writeInt(u32, self.output.items[index..][0..4], offset, .little);
        }
        const raw = if (start_group) id else wire.zigzagEncode(i64, @as(i64, id) - self.previous);
        try wire.writeVarint(self, raw);
        self.ordinal += 1;
        self.previous = id;
    }

    pub fn finish(self: Writer) ![]const u8 {
        if (self.ordinal != self.count) return error.InvalidGeocodePostings;
        return self.output.items[self.start..];
    }

    pub fn writeAll(self: *Writer, bytes: []const u8) !void {
        try self.output.appendSlice(self.a, bytes);
    }
};

test "importance-ordered IDs round trip and seek across signed deltas" {
    const t = std.testing;
    const a = t.allocator;
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(a);
    var ids: [193]RecordId = undefined;
    for (&ids, 0..) |*id, i| id.* = @intCast(if (i % 2 == 0) 500 + i else 44_000 - i);
    var writer = try Writer.init(a, &encoded, ids.len);
    for (ids) |id| try writer.append(id);
    const list = try List.init(try writer.finish(), ids.len);
    try list.validate(45_000, .none);
    var it = list.iterator();
    for (ids) |id| try t.expectEqual(id, (try it.next()).?);
    try t.expectEqual(null, try it.next());
    for ([_]u32{ 0, 5, 63, 64, 109, 127, 128, 192 }) |ordinal| {
        try it.seek(ordinal);
        try t.expectEqual(ids[ordinal], (try it.next()).?);
    }
    try t.expectError(error.InvalidGeocodePostingOrdinal, it.seek(ids.len));
    encoded.items[0] ^= 1;
    try t.expectError(error.InvalidGeocodePostings, list.validate(45_000, .none));
}
