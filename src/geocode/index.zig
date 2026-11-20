//! Checked mmap view of the front-coded geocoder dictionary and posting lists.
const std = @import("std");
const io = @import("../infra/io.zig");
const wire = @import("protobuf").wire;
const model = @import("model.zig");
const format = @import("index_model.zig");
const postings = @import("index_postings.zig");

pub const Field = format.Field;
pub const Document = format.Document;
pub const RecordId = format.RecordId;
pub const filename = format.filename;
const Allocator = std.mem.Allocator;

pub const Term = struct {
    /// Borrowed until the next call on the same iterator.
    text: []const u8,
    list: postings.List,
};

pub const TopTerm = struct { field: Field, term: []const u8, records: u32 };
pub const FieldStats = struct { field: Field, terms: u64 = 0, postings: u64 = 0 };

pub const Summary = struct {
    terms: u64,
    postings: u64,
    analyzed_bytes: u64,
    dictionary_bytes: u64,
    postings_bytes: u64,
    fields: [format.fields.len]FieldStats,
    top_terms: []TopTerm,

    pub fn deinit(self: *Summary, a: Allocator) void {
        for (self.top_terms) |row| a.free(row.term);
        a.free(self.top_terms);
    }
};

pub const View = struct {
    header: format.Header,
    dictionary: []const u8,
    postings_bytes: []const u8,
    blocks: []const format.Block,

    pub fn decode(input: []const u8, uuid: ?format.DatasetUuid, deadline: io.Deadline) !View {
        if (deadline.expired()) return error.DeadlineExceeded;
        const header = (try io.typedSlice(format.Header, input, 0, 1))[0];
        if (!std.mem.eql(u8, &header.magic_tag, &format.magic) or header.format_version != format.version or
            header.reserved != 0 or header.longest_term > format.max_term_bytes or
            header.records.total() > std.math.maxInt(u32) or header.blocks > std.math.maxInt(u32))
            return error.InvalidGeocodeIndexHeader;
        if (uuid) |expected| {
            if (!std.mem.eql(u8, &header.dataset_uuid, &expected)) return error.GeocodeDatasetUuidMismatch;
        }
        const posting_size = std.math.cast(usize, header.postings_bytes) orelse return error.InvalidGeocodeIndexLength;
        const dict_size = std.math.cast(usize, header.dictionary_bytes) orelse return error.InvalidGeocodeIndexLength;
        const posting_start = @sizeOf(format.Header);
        const dict_start = try addOffset(posting_start, posting_size);
        const dict_end = try addOffset(dict_start, dict_size);
        const aligned = (try addOffset(dict_end, @alignOf(format.Block) - 1)) & ~@as(usize, @alignOf(format.Block) - 1);
        const block_count: usize = @intCast(header.blocks);
        const block_bytes = std.math.mul(usize, block_count, @sizeOf(format.Block)) catch return error.InvalidGeocodeIndexLength;
        if (try addOffset(aligned, block_bytes) != input.len) return error.InvalidGeocodeIndexLength;
        if (!std.mem.allEqual(u8, input[dict_end..aligned], 0)) return error.InvalidGeocodeIndexHeader;
        if (try model.checksum(input[posting_start..], deadline) != header.payload_hash) return error.GeocodeHashMismatch;
        const view: View = .{
            .header = header,
            .dictionary = input[dict_start..dict_end],
            .postings_bytes = input[posting_start..dict_start],
            .blocks = try io.typedSlice(format.Block, input, aligned, block_count),
        };
        try view.validate(deadline);
        return view;
    }

    pub fn scratchBytes(self: View) usize {
        return self.header.longest_term;
    }

    pub fn summarize(self: View, a: Allocator, top_count: usize, deadline: io.Deadline) !Summary {
        const scratch = try a.alloc(u8, self.scratchBytes());
        defer a.free(scratch);
        var top: std.ArrayList(TopTerm) = .empty;
        defer top.deinit(a);
        errdefer for (top.items) |item| a.free(item.term);
        try top.ensureTotalCapacity(a, @min(top_count, std.math.cast(usize, self.header.terms) orelse top_count));
        var by_field: [format.fields.len]FieldStats = undefined;
        for (format.fields, &by_field) |field, *stats| {
            stats.* = .{ .field = field };
            var found = try self.prefix(field, "", scratch, deadline);
            while (try found.next(deadline)) |term| {
                stats.terms += 1;
                stats.postings += term.list.count;
                var position: usize = 0;
                while (position < top.items.len and top.items[position].records >= term.list.count) : (position += 1) {
                    if (deadline.expired()) return error.DeadlineExceeded;
                }
                if (position >= top_count) continue;
                const owned_term = try a.dupe(u8, term.text);
                errdefer a.free(owned_term);
                if (top.items.len == top_count) a.free(top.pop().?.term);
                try top.insert(a, position, .{ .field = field, .term = owned_term, .records = term.list.count });
            }
        }
        return .{
            .terms = self.header.terms,
            .postings = self.header.postings,
            .analyzed_bytes = self.header.analyzed_bytes,
            .dictionary_bytes = self.header.dictionary_bytes,
            .postings_bytes = self.header.postings_bytes,
            .fields = by_field,
            .top_terms = try top.toOwnedSlice(a),
        };
    }

    /// Prefix may be empty to enumerate the field. Scratch is caller-owned
    /// and must hold at least scratchBytes() bytes.
    pub fn prefix(self: View, field: Field, prefix_text: []const u8, scratch: []u8, deadline: io.Deadline) !PrefixIterator {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (scratch.len < self.scratchBytes()) return error.GeocodeTermBufferTooSmall;
        const span = self.header.field_blocks[@backingInt(field)];
        const field_blocks = try span.get(self.blocks);
        var low: usize = 0;
        var high = field_blocks.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const term = try self.firstTerm(field_blocks[middle]);
            if (std.mem.order(u8, term, prefix_text) != .gt) low = middle + 1 else high = middle;
        }
        const start = low -| 1;
        const selected = field_blocks[start..];
        return .{
            .blocks = selected,
            .query = prefix_text,
            .cursor = .{
                .dictionary = self.dictionary,
                .postings_bytes = self.postings_bytes,
                .buffer = scratch,
                .dictionary_offset = if (selected.len == 0) 0 else @intCast(selected[0].dictionary),
                .postings_offset = if (selected.len == 0) 0 else @intCast(selected[0].postings),
            },
        };
    }

    fn firstTerm(self: View, block: format.Block) ![]const u8 {
        var reader = wire.Reader.init(self.dictionary[@intCast(block.dictionary)..]);
        if (try readInteger(&reader) != 0) return error.InvalidGeocodeTerm;
        return readBytes(&reader, try readInteger(&reader));
    }

    fn validate(self: View, deadline: io.Deadline) !void {
        var scratch: [format.max_term_bytes]u8 = undefined;
        var cursor: Decoder = .{
            .dictionary = self.dictionary,
            .postings_bytes = self.postings_bytes,
            .buffer = scratch[0..self.header.longest_term],
        };
        var block_count: usize = 0;
        var term_count: u64 = 0;
        var posting_count: u64 = 0;
        var longest: usize = 0;
        for (self.header.field_blocks) |span| {
            if (span.first != block_count) return error.InvalidGeocodeIndexDirectory;
            const field_blocks = try span.get(self.blocks);
            cursor.term_len = 0;
            for (field_blocks, 0..) |block, i| {
                if (deadline.expired()) return error.DeadlineExceeded;
                if (block.dictionary != cursor.dictionary_offset or block.postings != cursor.postings_offset or
                    block.attr.terms == 0 or block.attr.terms > format.terms_per_block or block.attr.reserved != 0 or
                    (i + 1 < field_blocks.len and block.attr.terms != format.terms_per_block))
                    return error.InvalidGeocodeIndexDirectory;
                for (0..block.attr.terms) |j| {
                    const term = try cursor.next(j == 0, true);
                    if (!std.unicode.utf8ValidateSlice(term.text)) return error.InvalidGeocodeTerm;
                    try term.list.validate(self.header.records.total(), deadline);
                    term_count += 1;
                    posting_count = std.math.add(u64, posting_count, term.list.count) catch return error.InvalidGeocodeIndexLength;
                    longest = @max(longest, term.text.len);
                }
            }
            block_count += field_blocks.len;
        }
        if (block_count != self.blocks.len or cursor.dictionary_offset != self.dictionary.len or
            cursor.postings_offset != self.postings_bytes.len or term_count != self.header.terms or
            posting_count != self.header.postings or longest != self.header.longest_term)
            return error.InvalidGeocodeIndexLength;
    }
};

pub const PrefixIterator = struct {
    blocks: []const format.Block,
    query: []const u8,
    cursor: Decoder,
    block: usize = 0,
    relative: u8 = 0,
    done: bool = false,

    pub fn next(self: *PrefixIterator, deadline: io.Deadline) !?Term {
        if (self.done) return null;
        while (self.block < self.blocks.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const entry = try self.cursor.next(self.relative == 0, false);
            self.relative += 1;
            if (self.relative == self.blocks[self.block].attr.terms) {
                self.relative = 0;
                self.block += 1;
            }
            if (std.mem.startsWith(u8, entry.text, self.query)) return entry;
            if (std.mem.order(u8, entry.text, self.query) == .gt) break;
        }
        self.done = true;
        return null;
    }
};

const Decoder = struct {
    dictionary: []const u8,
    postings_bytes: []const u8,
    buffer: []u8,
    dictionary_offset: usize = 0,
    postings_offset: usize = 0,
    term_len: usize = 0,

    fn next(self: *Decoder, first: bool, check_order: bool) !Term {
        const input = self.dictionary[self.dictionary_offset..];
        var reader = wire.Reader.init(input);
        const shared = std.math.cast(usize, try readInteger(&reader)) orelse return error.InvalidGeocodeTerm;
        const suffix = try readBytes(&reader, try readInteger(&reader));
        if (shared > self.term_len or (first and shared != 0) or suffix.len == 0 or suffix.len > self.buffer.len - shared)
            return error.InvalidGeocodeTerm;
        if (check_order and self.term_len != 0 and std.mem.order(u8, self.buffer[shared..self.term_len], suffix) != .lt)
            return error.InvalidGeocodeTermOrder;
        const count = std.math.cast(u32, try readInteger(&reader)) orelse return error.InvalidGeocodePostings;
        const list = if (count == 1) blk: {
            // Inline singleton IDs avoid a separate posting-stream length.
            const encoded = reader.remaining;
            _ = try readInteger(&reader);
            break :blk try postings.List.init(encoded[0 .. encoded.len - reader.remaining.len], count);
        } else blk: {
            const size = std.math.cast(usize, try readInteger(&reader)) orelse return error.InvalidGeocodePostings;
            if (size > self.postings_bytes.len - self.postings_offset) return error.InvalidGeocodePostings;
            const bytes = self.postings_bytes[self.postings_offset..][0..size];
            self.postings_offset += size;
            break :blk try postings.List.init(bytes, count);
        };
        @memcpy(self.buffer[shared..][0..suffix.len], suffix);
        self.term_len = shared + suffix.len;
        self.dictionary_offset += input.len - reader.remaining.len;
        return .{ .text = self.buffer[0..self.term_len], .list = list };
    }
};

fn readInteger(reader: *wire.Reader) !u64 {
    const before = reader.remaining.len;
    const value = try reader.readVarint();
    if (before - reader.remaining.len != wire.varintSize(value)) return error.InvalidGeocodeIndexVarint;
    return value;
}

fn readBytes(reader: *wire.Reader, count: u64) ![]const u8 {
    if (count > reader.remaining.len) return error.InvalidGeocodeIndexLength;
    const size: usize = @intCast(count);
    const result = reader.remaining[0..size];
    reader.remaining = reader.remaining[size..];
    return result;
}

fn addOffset(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.InvalidGeocodeIndexLength;
}

pub const Index = struct {
    mapping: io.Mapping,
    view: View,

    pub fn open(dir: io.Directory, uuid: format.DatasetUuid, deadline: io.Deadline) !Index {
        const file = try dir.readFile(filename);
        defer file.close();
        const mapping = try io.Mapping.mapFd(file, .read_only);
        errdefer mapping.unmap();
        return .{ .mapping = mapping, .view = try View.decode(mapping.bytes, uuid, deadline) };
    }

    pub fn close(self: *Index) void {
        self.mapping.unmap();
        self.* = undefined;
    }
};

test "prefix enumeration crosses blocks and respects field boundaries" {
    const testing = std.testing;
    const a = testing.allocator;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temp.sub_path});
    defer a.free(path);
    const dir = try io.Directory.open(path);
    defer dir.close();
    const file = try dir.createFile(filename);
    defer file.close();
    const uuid: format.DatasetUuid = @splat(5);
    const Writer = @import("index_writer.zig").Writer;
    var writer: Writer = .{ .a = a, .file = file, .uuid = uuid, .records = .{ .place = 64 }, .deadline = .none };
    defer writer.deinit();
    for (0..40) |i| {
        var key: [16]u8 = undefined;
        const word = try std.fmt.bufPrint(&key, "oak{d:0>3}", .{i});
        const id: u8 = @intCast(i);
        try writer.add(.name, word, try postings.List.init(&.{id}, 1));
    }
    try writer.add(.street, "oak010", try postings.List.init(&.{ 5, 3 }, 2));
    const header = try writer.finish(200);
    try testing.expectEqual(4, header.blocks);
    try testing.expectError(error.GeocodeDatasetUuidMismatch, Index.open(dir, @splat(1), .none));
    {
        var opened = try Index.open(dir, uuid, .none);
        defer opened.close();
        var scratch: [16]u8 = undefined;
        var found = try opened.view.prefix(.name, "oak01", &scratch, .none);
        for (10..20) |i| {
            const term = (try found.next(.none)).?;
            var posted = term.list.iterator();
            const record = (try posted.next()).?;
            try testing.expectEqual(i, record);
        }
        try testing.expectEqual(null, try found.next(.none));
        var street = try opened.view.prefix(.street, "oak01", &scratch, .none);
        const selected = (try street.next(.none)).?;
        try testing.expectEqualStrings("oak010", selected.text);
        var streets = selected.list.iterator();
        try testing.expectEqual(@as(?u32, 5), try streets.next());
        try testing.expectEqual(@as(?u32, 3), try streets.next());
        try testing.expectEqual(null, try street.next(.none));
        var summary = try opened.view.summarize(a, 3, .none);
        defer summary.deinit(a);
        try testing.expectEqual(40, summary.fields[0].terms);
        try testing.expectEqual(.street, summary.top_terms[0].field);
        try testing.expectEqualStrings("oak010", summary.top_terms[0].term);
    }
    try file.pwriteAll(&.{0}, @sizeOf(format.Header));
    try testing.expectError(error.GeocodeHashMismatch, Index.open(dir, uuid, .none));
}
