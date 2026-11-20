//! Stream posting data before the dictionary and its sparse block directory.
const std = @import("std");
const io = @import("../infra/io.zig");
const wire = @import("protobuf").wire;
const format = @import("index_model.zig");
const postings = @import("index_postings.zig");
const Span = @import("model.zig").Span;
const Allocator = std.mem.Allocator;

pub const Writer = struct {
    a: Allocator,
    file: io.File,
    uuid: format.DatasetUuid,
    records: format.RecordCounts,
    deadline: io.Deadline,
    dictionary: std.ArrayList(u8) = .empty,
    blocks: std.ArrayList(format.Block) = .empty,
    previous: std.ArrayList(u8) = .empty,
    block_counts: [format.fields.len]u32 = @splat(0),
    offset: u64 = @sizeOf(format.Header),
    hash: std.hash.XxHash3 = .init(0),
    current: ?format.Field = null,
    longest: usize = 0,
    terms: u64 = 0,
    records_indexed: u64 = 0,
    sealed: bool = false,

    pub fn deinit(self: *Writer) void {
        self.dictionary.deinit(self.a);
        self.blocks.deinit(self.a);
        self.previous.deinit(self.a);
    }

    pub fn add(self: *Writer, field: format.Field, term: []const u8, list: postings.List) !void {
        if (self.sealed) return error.GeocodeIndexSealed;
        if (self.deadline.expired()) return error.DeadlineExceeded;
        if (term.len == 0 or term.len > format.max_term_bytes or !std.unicode.utf8ValidateSlice(term))
            return error.InvalidGeocodeTerm;
        if (list.count == 0 or list.bytes.len == 0) return error.InvalidGeocodePostings;
        if (self.current) |prior| {
            if (@backingInt(field) < @backingInt(prior) or
                (prior == field and !std.mem.lessThan(u8, self.previous.items, term)))
                return error.InvalidGeocodeTermOrder;
        }
        const start_block = self.current != field or self.blocks.items[self.blocks.items.len - 1].attr.terms == format.terms_per_block;
        if (start_block) {
            if (self.blocks.items.len == std.math.maxInt(u32)) return error.GeocodeIndexTooLarge;
            try self.blocks.append(self.a, .{
                .dictionary = self.dictionary.items.len,
                .postings = self.offset - @sizeOf(format.Header),
                .attr = .{ .terms = 0 },
            });
            self.block_counts[@backingInt(field)] += 1;
        }
        const shared = if (start_block) 0 else commonPrefix(self.previous.items, term);
        try wire.writeVarint(self, shared);
        try wire.writeVarint(self, term.len - shared);
        try self.writeAll(term[shared..]);
        try wire.writeVarint(self, list.count);
        if (list.count == 1) {
            try self.writeAll(list.bytes);
        } else {
            try wire.writeVarint(self, list.bytes.len);
            try self.appendBytes(list.bytes);
        }
        self.previous.clearRetainingCapacity();
        try self.previous.appendSlice(self.a, term);
        self.blocks.items[self.blocks.items.len - 1].attr.terms += 1;
        self.current = field;
        self.terms += 1;
        self.records_indexed = std.math.add(u64, self.records_indexed, list.count) catch return error.GeocodeIndexTooLarge;
        self.longest = @max(self.longest, term.len);
    }

    pub fn finish(self: *Writer, analyzed_bytes: u64) !format.Header {
        if (self.sealed) return error.GeocodeIndexSealed;
        if (self.records.total() > std.math.maxInt(u32)) return error.GeocodeIndexTooLarge;
        if (self.deadline.expired()) return error.DeadlineExceeded;
        self.sealed = true;
        const posting_bytes = self.offset - @sizeOf(format.Header);
        try self.appendBytes(self.dictionary.items);
        const padding: [@alignOf(format.Block) - 1]u8 = @splat(0);
        const pad = (0 -% self.offset) % @alignOf(format.Block);
        try self.appendBytes(padding[0..pad]);
        try self.appendBytes(std.mem.sliceAsBytes(self.blocks.items));
        var field_blocks: [format.fields.len]Span = undefined;
        var first: u32 = 0;
        for (self.block_counts, &field_blocks) |count, *span| {
            span.* = .{ .first = first, .len = count };
            first += count;
        }
        const header: format.Header = .{
            .dataset_uuid = self.uuid,
            .longest_term = @intCast(self.longest),
            .terms = self.terms,
            .postings = self.records_indexed,
            .analyzed_bytes = analyzed_bytes,
            .postings_bytes = posting_bytes,
            .dictionary_bytes = self.dictionary.items.len,
            .blocks = self.blocks.items.len,
            .payload_hash = self.hash.final(),
            .records = self.records,
            .field_blocks = field_blocks,
        };
        try self.file.pwriteAll(std.mem.asBytes(&header), 0);
        try self.file.truncate(self.offset);
        try self.file.sync();
        return header;
    }

    pub fn writeAll(self: *Writer, bytes: []const u8) !void {
        try self.dictionary.appendSlice(self.a, bytes);
    }

    fn appendBytes(self: *Writer, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const chunk = bytes[offset..@min(offset +| (1 << 20), bytes.len)];
            const end = std.math.add(u64, self.offset, chunk.len) catch return error.GeocodeIndexTooLarge;
            if (end > std.math.maxInt(i64)) return error.GeocodeIndexTooLarge;
            io.updateFileHash(&self.hash, chunk);
            try self.file.pwriteAll(chunk, self.offset);
            self.offset = end;
            offset += chunk.len;
        }
    }
};

fn commonPrefix(a: []const u8, b: []const u8) usize {
    const length = @min(a.len, b.len);
    return std.mem.indexOfDiff(u8, a[0..length], b[0..length]) orelse length;
}
