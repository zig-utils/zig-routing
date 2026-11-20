//! Search folding data derived from Unicode Character Database 18.0.0.
const std = @import("std");

const data = @embedFile("unicode-data.bin");
const header_size = 32;
const entry_size = 8;
const scalar_count = 0x110000;
const page_size = 256;
const page_count = scalar_count / page_size;
const map_count = read32(8);
const payload_size = read32(12);
const class_page_count = read32(16);
const payload_start = header_size + map_count * entry_size;
const class_index_start = payload_start + payload_size;
const class_pages_start = class_index_start + page_count * @sizeOf(u16);
const page_offsets = mappingPages();

pub const version = .{ .major = read32(20), .minor = read32(24), .patch = read32(28) };
pub const Class = enum(u8) { separator, word, greek, cyrillic, han, kana, hangul };
pub const Scalar = struct { cp: u21, len: usize };

comptime {
    @setEvalBranchQuota(1_000_000);
    std.debug.assert(std.mem.eql(u8, data[0..8], "ZRUTABLE"));
    std.debug.assert(data.len == class_pages_start + class_page_count * page_size);
    std.debug.assert(version.major == 18 and version.minor == 0 and version.patch == 0);
    std.debug.assert(map_count <= std.math.maxInt(u16));
    for (0..map_count) |index| {
        const cp = entryCode(index);
        std.debug.assert(cp < scalar_count and (index == 0 or cp > entryCode(index - 1)));
        const shape = read32(header_size + index * entry_size + 4);
        std.debug.assert((shape & 0x00ff_ffff) + (shape >> 24) <= payload_size);
    }
    for (0..page_count) |page| std.debug.assert(classPage(page) < class_page_count);
    for (data[class_pages_start..]) |value| std.debug.assert(value <= @backingInt(Class.hangul));
}

fn read32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn entryCode(index: usize) u32 {
    return read32(header_size + index * entry_size);
}

fn classPage(page: usize) usize {
    return std.mem.readInt(u16, data[class_index_start + page * @sizeOf(u16) ..][0..2], .little);
}

fn mappingPages() [page_count + 1]u16 {
    @setEvalBranchQuota(1_000_000);
    var offsets: [page_count + 1]u16 = undefined;
    var entry: usize = 0;
    for (&offsets, 0..) |*offset, page| {
        while (entry < map_count and entryCode(entry) < page * page_size) : (entry += 1) {}
        offset.* = @intCast(entry);
    }
    return offsets;
}

/// Null means an unchanged scalar. An empty slice means the scalar is removed.
pub fn fold(cp: u21) ?[]const u8 {
    if (cp >= scalar_count) return null;
    const page = cp / page_size;
    var low: usize = page_offsets[page];
    var high: usize = page_offsets[@as(usize, page) + 1];
    while (low < high) {
        const middle = low + (high - low) / 2;
        const scalar = entryCode(middle);
        if (cp == scalar) {
            const value = read32(header_size + middle * entry_size + 4);
            return data[payload_start + (value & 0x00ff_ffff) ..][0 .. value >> 24];
        }
        if (cp < scalar) high = middle else low = middle + 1;
    }
    return null;
}

pub fn class(cp: u21) Class {
    if (cp >= scalar_count) return .separator;
    const ordinal = classPage(cp / page_size);
    return @fromBackingInt(@intCast(data[class_pages_start + ordinal * page_size + cp % page_size]));
}

pub inline fn decode(input: []const u8) error{InvalidUtf8}!Scalar {
    if (input.len == 0) return error.InvalidUtf8;
    const byte = input[0];
    if (byte < 0x80) return .{ .cp = byte, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUtf8;
    if (len > input.len) return error.InvalidUtf8;
    const cp = std.unicode.utf8Decode(input[0..len]) catch return error.InvalidUtf8;
    return .{ .cp = cp, .len = len };
}

/// The algorithmic Hangul decomposition from UAX #15.
pub fn decomposeHangul(cp: u21, out: *[3]u21) []const u21 {
    if (cp < 0xac00 or cp > 0xd7a3) return &.{};
    const offset = cp - 0xac00;
    const tail = offset % 28;
    out[0] = 0x1100 + offset / (21 * 28);
    out[1] = 0x1161 + (offset % (21 * 28)) / 28;
    if (tail == 0) return out[0..2];
    out[2] = 0x11a7 + tail;
    return out;
}

test "shipped Unicode data folds expansions marks and decimal digits" {
    const t = std.testing;
    try t.expectEqualStrings("ss", fold(0x00df).?);
    try t.expectEqualStrings("α", fold(0x0386).?);
    try t.expectEqualStrings("σ", fold(0x03c2).?);
    try t.expectEqualStrings("е", fold(0x0401).?);
    try t.expectEqualStrings("2", fold(0xff12).?);
    try t.expectEqualStrings("6", fold(0x0666).?);
    try t.expectEqualStrings("", fold(0x0301).?);
    try t.expectEqualStrings("", fold(0xfe0f).?);
    try t.expectEqual(null, fold(0x6771));
    try t.expectEqual(.han, class(0x6771));
    try t.expectEqual(.kana, class(0x30fc));
    try t.expectEqual(.greek, class(0x03b1));
    try t.expectEqual(.cyrillic, class(0x0435));
    var hangul: [3]u21 = undefined;
    try t.expectEqualSlices(u21, &.{ 0x1100, 0x1161, 0x11a8 }, decomposeHangul(0xac01, &hangul));
}
