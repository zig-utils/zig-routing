//! Little-endian layout of the geocoder's immutable term index.
const std = @import("std");
const model = @import("model.zig");

pub const filename = "geocode-index.bin";
pub const magic = "ZRGIDX01".*;
pub const version: u32 = 1;
pub const terms_per_block = 16;
pub const max_term_bytes = std.math.maxInt(u16);
pub const DatasetUuid = model.DatasetUuid;
pub const RecordId = u32;
pub const Field = enum(u3) { name, street, city, postcode, house_number };
pub const fields = std.enums.values(Field);
pub const Kind = enum(u2) { place, street, address, poi };

pub const Document = struct { kind: Kind, row: u32 };

/// IDs concatenate the bundle row numbers by record kind. This keeps
/// deltas small within each source table and needs no inverse ID section.
pub const RecordCounts = extern struct {
    place: u32 = 0,
    street: u32 = 0,
    address: u32 = 0,
    poi: u32 = 0,

    pub fn total(self: RecordCounts) u64 {
        return @as(u64, self.place) + self.street + self.address + self.poi;
    }

    pub fn id(self: RecordCounts, key: Document) ?RecordId {
        var offset: u64 = 0;
        inline for (std.enums.values(Kind)) |kind| {
            const count = @field(self, @tagName(kind));
            if (kind == key.kind) {
                if (key.row >= count) return null;
                return std.math.cast(RecordId, offset + key.row);
            }
            offset += count;
        }
        return null;
    }

    pub fn document(self: RecordCounts, record: RecordId) ?Document {
        var row = record;
        inline for (std.enums.values(Kind)) |kind| {
            const count = @field(self, @tagName(kind));
            if (row < count) return .{ .kind = kind, .row = row };
            row -= count;
        }
        return null;
    }
};

pub const Header = extern struct {
    magic_tag: [8]u8 = magic,
    dataset_uuid: DatasetUuid,
    format_version: u32 = version,
    longest_term: u32,
    terms: u64,
    postings: u64,
    analyzed_bytes: u64,
    postings_bytes: u64,
    dictionary_bytes: u64,
    blocks: u64,
    payload_hash: u64,
    records: RecordCounts,
    field_blocks: [fields.len]model.Span,
    reserved: u64 = 0,
};

/// Offsets are relative to the starts of the two byte streams.
pub const Block = extern struct {
    dictionary: u64,
    postings: u64,
    attr: packed struct(u64) {
        terms: u8,
        reserved: u56 = 0,
    },
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(RecordCounts) == 16 and @offsetOf(RecordCounts, "place") == 0 and
        @offsetOf(RecordCounts, "street") == 4 and @offsetOf(RecordCounts, "address") == 8 and @offsetOf(RecordCounts, "poi") == 12);
    std.debug.assert(@sizeOf(Header) == 152 and @offsetOf(Header, "magic_tag") == 0 and @offsetOf(Header, "dataset_uuid") == 8 and
        @offsetOf(Header, "format_version") == 24 and @offsetOf(Header, "longest_term") == 28 and @offsetOf(Header, "terms") == 32 and
        @offsetOf(Header, "postings") == 40 and @offsetOf(Header, "analyzed_bytes") == 48 and @offsetOf(Header, "postings_bytes") == 56 and
        @offsetOf(Header, "dictionary_bytes") == 64 and @offsetOf(Header, "blocks") == 72 and @offsetOf(Header, "payload_hash") == 80 and
        @offsetOf(Header, "records") == 88 and @offsetOf(Header, "field_blocks") == 104 and @offsetOf(Header, "reserved") == 144);
    std.debug.assert(@sizeOf(Block) == 24 and @offsetOf(Block, "dictionary") == 0 and @offsetOf(Block, "postings") == 8 and
        @offsetOf(Block, "attr") == 16);
}

test "geocode index IDs round trip without an inverse table" {
    const counts: RecordCounts = .{ .place = 4, .address = 70, .poi = 12 };
    for (0..counts.total()) |i| {
        const record: u32 = @intCast(i);
        try std.testing.expectEqual(record, counts.id(counts.document(record).?).?);
    }
    try std.testing.expectEqual(null, counts.document(86));
    try std.testing.expectEqual(null, counts.id(.{ .kind = .street, .row = 0 }));
}
