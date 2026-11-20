// Ported from src/baldr/edgeinfo.cc and src/mjolnir/graphtilebuilder.cc
// (Valhalla 3.9.3). The v1 bundle uses dense records and a shared string table.
const std = @import("std");
const io = @import("../infra/io.zig");
const point = @import("../geo/point.zig");
const polyline = @import("../geo/polyline.zig");
const linguistics = @import("linguistics.zig");
pub const access_restriction = @import("access_restriction.zig");
const Allocator = std.mem.Allocator;

pub const chunk_size = 256;
pub const max_names = std.math.maxInt(u8);
pub const no_elevation: i16 = -500;
const high_bit: u32 = 1 << 31;

/// The header precedes the chunk directory, the chunks, the name directory,
/// and the string bytes. Each directory has a trailing end offset. Chunk
/// offsets are relative to the first chunk, record offsets to their chunk's
/// record data, and name offsets to the first string byte.
pub const Header = extern struct {
    record_count: u32,
    name_count: u32,
    names_offset: u64,
};

const RecordHeader = extern struct {
    way_low: u32,
    way_high: u32,
    shape_bytes: u32,
    point_count: u32,
    attributes: packed struct(u32) {
        mean_elevation: i16,
        speed_limit: u8,
        name_count: u8,
    },
};

/// Optional trailer after name references. The signed layer and range count
/// share one little-endian word. Each level range stores two f32 endpoints.
const IndoorHeader = extern struct {
    attributes: packed struct(u32) {
        layer: i8,
        count: u24,
    },
};

/// A legacy reverse-name header is a bare u32 count in 0..255. The
/// high bits allow a restriction trailer with either kind of name list.
const ReverseHeader = extern struct {
    attr: packed struct(u32) {
        name_count: u8,
        reserved: u21 = 0,
        name_details: bool = false,
        inherit_names: bool = false,
        restrictions: bool = false,
    },
};

const NameDetailsHeader = extern struct {
    linguistic: packed struct(u32) {
        forward: u16,
        reverse: u16,
    },
    tagged: packed struct(u32) {
        forward: u8,
        reverse: u8,
        separate_reverse: bool,
        reserved: u15 = 0,
    },
};

pub const LevelRange = extern struct {
    bounds: packed struct(u64) {
        first: f32,
        last: f32,
    },

    pub fn init(first: f32, last: f32) LevelRange {
        return .{ .bounds = .{ .first = first, .last = last } };
    }
};

/// Decoder for the length-prefixed kLevels value in EdgeInfo. The native
/// string table stores the bytes without the tile text's trailing NUL.
pub const EncodedLevels = struct {
    const Decoder = polyline.IntDecoder(i32);

    values: Decoder,
    precision: u32,

    pub fn parse(bytes: []const u8) !EncodedLevels {
        var prefix = Decoder.init(bytes);
        const tagged_size = (try prefix.nextDelta()) orelse return error.InvalidLevels;
        const size = std.math.cast(usize, tagged_size) orelse return error.InvalidLevels;
        const rest = bytes[prefix.pos..];
        if (size != rest.len) return error.InvalidLevels;
        var values = Decoder.init(rest);
        const precision = (try values.nextDelta()) orelse return error.InvalidLevels;
        // Valhalla 3.9.3 uses a factor of ten for any positive precision.
        return .{ .values = values, .precision = if (precision > 0) 10 else 0 };
    }

    pub noinline fn next(self: *EncodedLevels, deadline: io.Deadline) !?LevelRange {
        const factor: f32 = @floatFromInt(@max(1, self.precision));
        var range: ?LevelRange = null;
        var i: usize = 0;
        while (try self.values.nextDelta()) |value| : (i += 1) {
            if (i % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (value == 1_048_575) {
                if (range != null) break;
                continue;
            }
            const level = @as(f32, @floatFromInt(value)) / factor;
            if (range) |*parsed| parsed.bounds.last = level else range = .init(level, level);
        }
        return range;
    }
};

pub const Indoor = struct {
    layer: i8 = 0,
    levels: []align(1) const LevelRange = &.{},

    pub fn includes(self: Indoor, level: f32, deadline: io.Deadline) !bool {
        for (self.levels, 0..) |range, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (range.bounds.first <= level and level <= range.bounds.last) return true;
        }
        return false;
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(IndoorHeader) == 4);
    std.debug.assert(@offsetOf(IndoorHeader, "attributes") == 0);
    std.debug.assert(@sizeOf(ReverseHeader) == 4 and @offsetOf(ReverseHeader, "attr") == 0);
    std.debug.assert(@sizeOf(NameDetailsHeader) == 8);
    std.debug.assert(@offsetOf(NameDetailsHeader, "linguistic") == 0 and @offsetOf(NameDetailsHeader, "tagged") == 4);
    std.debug.assert(@sizeOf(LevelRange) == 8);
    std.debug.assert(@offsetOf(LevelRange, "bounds") == 0);
    std.debug.assert(@sizeOf(Header) == 16);
    std.debug.assert(@offsetOf(Header, "record_count") == 0);
    std.debug.assert(@offsetOf(Header, "name_count") == 4);
    std.debug.assert(@offsetOf(Header, "names_offset") == 8);
    std.debug.assert(@sizeOf(RecordHeader) == 20);
    std.debug.assert(@offsetOf(RecordHeader, "way_low") == 0);
    std.debug.assert(@offsetOf(RecordHeader, "way_high") == 4);
    std.debug.assert(@offsetOf(RecordHeader, "shape_bytes") == 8);
    std.debug.assert(@offsetOf(RecordHeader, "point_count") == 12);
    std.debug.assert(@offsetOf(RecordHeader, "attributes") == 16);
}

/// The directed edge count fits u32, so the undirected index fits u31.
pub fn directedIndex(record: u31, reverse: bool) u32 {
    return record | (if (reverse) high_bit else @as(u32, 0));
}

pub fn nameRef(id: u31, route: bool) u32 {
    return id | (if (route) high_bit else @as(u32, 0));
}

pub fn chunkCount(records: u32) usize {
    return (@as(usize, records) + chunk_size - 1) / chunk_size;
}

pub const View = struct {
    bytes: []const u8,
    header: Header,
    chunks_start: usize,
    names_start: usize,
    strings_start: usize,

    /// Validate directory bounds and sentinels without paging in the records.
    pub fn parse(bytes: []const u8) !View {
        if (bytes.len < @sizeOf(Header)) return error.TruncatedColdHeader;
        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (header.record_count > high_bit or header.name_count > high_bit) return error.InvalidColdHeader;
        const chunks = chunkCount(header.record_count);
        const chunks_start = @sizeOf(Header) + (chunks + 1) * @sizeOf(u64);
        const names_start = std.math.cast(usize, header.names_offset) orelse return error.InvalidColdDirectory;
        if (chunks_start > names_start or names_start > bytes.len) return error.InvalidColdDirectory;

        const name_entries = @as(u64, header.name_count) + 1;
        if (name_entries > (bytes.len - names_start) / @sizeOf(u64)) return error.InvalidNameDirectory;
        const strings_start = names_start + @as(usize, @intCast(name_entries)) * @sizeOf(u64);
        if (readInt(u64, bytes, @sizeOf(Header)) != 0 or
            readInt(u64, bytes, chunks_start - @sizeOf(u64)) != names_start - chunks_start)
            return error.InvalidColdDirectory;
        if (readInt(u64, bytes, names_start) != 0 or
            readInt(u64, bytes, strings_start - @sizeOf(u64)) != bytes.len - strings_start)
            return error.InvalidNameDirectory;
        return .{
            .bytes = bytes,
            .header = header,
            .chunks_start = chunks_start,
            .names_start = names_start,
            .strings_start = strings_start,
        };
    }

    pub fn record(self: View, index: u32) !Record {
        return self.recordWithDeadline(index, .none);
    }

    pub fn recordWithDeadline(self: View, index: u32, deadline: io.Deadline) !Record {
        const id: usize = @as(u31, @truncate(index));
        if (id >= self.header.record_count) return error.InvalidColdIndex;
        const chunk = id / chunk_size;
        const count: usize = @min(chunk_size, self.header.record_count - chunk * chunk_size);
        const directory = @sizeOf(Header) + chunk * @sizeOf(u64);
        const chunk_bytes = try bounds(self.bytes[self.chunks_start..self.names_start], readInt(u64, self.bytes, directory), readInt(u64, self.bytes, directory + @sizeOf(u64)));
        const records_start = (count + 1) * @sizeOf(u64);
        if (records_start > chunk_bytes.len) return error.InvalidColdChunk;
        if (readInt(u64, chunk_bytes, 0) != 0 or
            readInt(u64, chunk_bytes, records_start - @sizeOf(u64)) != chunk_bytes.len - records_start)
            return error.InvalidColdChunk;
        const local = (id % chunk_size) * @sizeOf(u64);
        const data = try bounds(chunk_bytes[records_start..], readInt(u64, chunk_bytes, local), readInt(u64, chunk_bytes, local + @sizeOf(u64)));
        return Record.parse(data, index & high_bit != 0, deadline);
    }

    pub fn name(self: View, reference: u32) !Name {
        const id: usize = @as(u31, @truncate(reference));
        if (id >= self.header.name_count) return error.InvalidNameReference;
        const index = self.names_start + id * @sizeOf(u64);
        const text = try bounds(self.bytes[self.strings_start..], readInt(u64, self.bytes, index), readInt(u64, self.bytes, index + @sizeOf(u64)));
        return .{ .text = text, .route = reference & high_bit != 0 };
    }
};

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn bounds(bytes: []const u8, start: u64, end: u64) ![]const u8 {
    if (start > end or end > bytes.len) return error.InvalidColdOffset;
    return bytes[@intCast(start)..@intCast(end)];
}

pub const Name = struct {
    text: []const u8,
    route: bool,
    language: linguistics.Language = .none,
    pronunciation: ?linguistics.Pronunciation = null,
    tagged: ?linguistics.Tag = null,
};

pub const NameDetails = struct {
    linguistic: []align(1) const linguistics.Entry = &.{},
    tagged: []align(1) const linguistics.Tagged = &.{},

    fn empty(self: NameDetails) bool {
        return self.linguistic.len == 0 and self.tagged.len == 0;
    }

    fn validate(self: NameDetails, names: usize, deadline: io.Deadline) !void {
        if (self.tagged.len > max_names - names or self.linguistic.len > (names + self.tagged.len) * 5)
            return error.InvalidColdNameDetails;
        var previous: u8 = 0;
        for (self.linguistic, 0..) |entry, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (!entry.valid(names + self.tagged.len) or entry.attr.name_index < previous) return error.InvalidColdNameDetails;
            previous = entry.attr.name_index;
        }
        for (self.tagged) |tag| if (!tag.valid()) return error.InvalidColdNameDetails;
    }
};

pub const Names = struct {
    table: View,
    references: []const u8,
    details: NameDetails = .{},
    options: Options = .{},

    pub const Options = struct {
        include_tagged: bool = false,
        deadline: io.Deadline = .none,
    };

    pub fn count(self: Names) usize {
        return self.ordinaryCount() + (if (self.options.include_tagged) self.details.tagged.len else 0);
    }

    pub fn ordinaryCount(self: Names) usize {
        return self.references.len / @sizeOf(u32);
    }

    pub fn tagKind(self: Names, i: usize) !?linguistics.Tag {
        if (i >= self.count()) return error.InvalidNameIndex;
        const ordinary = self.ordinaryCount();
        return if (i < ordinary) null else self.details.tagged[i - ordinary].attr.kind;
    }

    /// Read the spelling and its flags without looking up linguistic records.
    pub fn valueAt(self: Names, i: usize) !Name {
        if (i >= self.count()) return error.InvalidNameIndex;
        const ordinary = self.ordinaryCount();
        return if (i < ordinary)
            try self.table.name(readInt(u32, self.references, i * @sizeOf(u32)))
        else tagged: {
            const tag = self.details.tagged[i - ordinary];
            var name = try self.table.name(tag.text_ref);
            name.tagged = tag.attr.kind;
            break :tagged name;
        };
    }

    pub fn at(self: Names, i: usize) !Name {
        var result = try self.valueAt(i);
        if (try self.preferred(i)) |entry| {
            result.language = entry.attr.language;
            if (entry.attr.alphabet != .none) result.pronunciation = .{
                .alphabet = entry.attr.alphabet,
                .text = (try self.table.name(entry.text_ref)).text,
            };
        }
        return result;
    }

    fn preferred(self: Names, i: usize) !?linguistics.Entry {
        const rows = self.details.linguistic;
        var low: usize = 0;
        var high = rows.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (rows[mid].attr.name_index < i) low = mid + 1 else high = mid;
        }
        var best: ?linguistics.Entry = null;
        for (rows[low..], 0..) |entry, step| {
            if (entry.attr.name_index != i) break;
            if (step % 256 == 0 and self.options.deadline.expired()) return error.DeadlineExceeded;
            if (best == null or entry.replaces(best.?)) best = entry;
        }
        return best;
    }
};

pub const Record = struct {
    header: RecordHeader,
    reverse: bool,
    encoded: []const u8,
    references: []const u8,
    reverse_references: ?[]const u8 = null,
    name_details: []const u8 = &.{},
    indoor: Indoor,
    access_limits: []align(1) const access_restriction.Entry = &.{},

    fn parse(bytes: []const u8, reverse: bool, deadline: io.Deadline) !Record {
        if (bytes.len < @sizeOf(RecordHeader)) return error.TruncatedColdRecord;
        const header = std.mem.bytesToValue(RecordHeader, bytes[0..@sizeOf(RecordHeader)]);
        const data = bytes[@sizeOf(RecordHeader)..];
        const ref_bytes = @as(usize, header.attributes.name_count) * @sizeOf(u32);
        if (header.shape_bytes > data.len or ref_bytes > data.len - header.shape_bytes or
            header.point_count < 2 or header.point_count > header.shape_bytes / 2)
            return error.InvalidColdRecord;
        const end = @as(usize, header.shape_bytes) + ref_bytes;
        const trailer = data[end..];
        var reverse_references: ?[]const u8 = null;
        var name_details: []const u8 = &.{};
        var access_limits: []align(1) const access_restriction.Entry = &.{};
        const indoor: Indoor = if (trailer.len == 0) .{} else blk: {
            if (trailer.len < @sizeOf(IndoorHeader)) return error.InvalidColdIndoorData;
            const info = std.mem.bytesToValue(IndoorHeader, trailer[0..@sizeOf(IndoorHeader)]).attributes;
            const payload = trailer[@sizeOf(IndoorHeader)..];
            const size = @as(usize, info.count) * @sizeOf(LevelRange);
            if (size > payload.len) return error.InvalidColdIndoorData;
            const extra = payload[size..];
            if (extra.len != 0) {
                if (extra.len < @sizeOf(ReverseHeader)) return error.InvalidColdReverseNames;
                const rev = std.mem.bytesToValue(ReverseHeader, extra[0..@sizeOf(ReverseHeader)]).attr;
                const refs_end = @sizeOf(ReverseHeader) + @as(usize, rev.name_count) * @sizeOf(u32);
                if (rev.reserved != 0 or refs_end > extra.len or
                    (rev.inherit_names and ((!rev.restrictions and !rev.name_details) or rev.name_count != 0)))
                    return error.InvalidColdReverseNames;
                if (!rev.inherit_names) reverse_references = extra[@sizeOf(ReverseHeader)..refs_end];
                var limit_bytes = extra[refs_end..];
                if (rev.name_details) {
                    if (limit_bytes.len < @sizeOf(u32)) return error.InvalidColdNameDetails;
                    const details_len = readInt(u32, limit_bytes, 0);
                    limit_bytes = limit_bytes[@sizeOf(u32)..];
                    if (details_len < @sizeOf(NameDetailsHeader) or details_len > limit_bytes.len) return error.InvalidColdNameDetails;
                    name_details = limit_bytes[0..details_len];
                    limit_bytes = limit_bytes[details_len..];
                }
                if (rev.restrictions) {
                    const size_of_entry = @sizeOf(access_restriction.Entry);
                    if (limit_bytes.len == 0 or limit_bytes.len % size_of_entry != 0) return error.InvalidColdAccessLimits;
                    access_limits = std.mem.bytesAsSlice(access_restriction.Entry, limit_bytes);
                    for (access_limits, 0..) |entry, i| {
                        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                        if (!entry.valid()) return error.InvalidColdAccessLimits;
                    }
                } else if (limit_bytes.len != 0) return error.InvalidColdReverseNames;
            }
            break :blk .{ .layer = info.layer, .levels = std.mem.bytesAsSlice(LevelRange, payload[0..size]) };
        };
        return .{
            .header = header,
            .reverse = reverse,
            .encoded = data[0..header.shape_bytes],
            .references = data[header.shape_bytes..end],
            .reverse_references = reverse_references,
            .name_details = name_details,
            .indoor = indoor,
            .access_limits = access_limits,
        };
    }

    pub fn wayId(self: Record) u64 {
        return (@as(u64, self.header.way_high) << 32) | self.header.way_low;
    }

    pub fn speedLimit(self: Record) u8 {
        return self.header.attributes.speed_limit;
    }

    pub fn meanElevation(self: Record) i16 {
        return self.header.attributes.mean_elevation;
    }

    pub fn names(self: Record, table: View, options: Names.Options) !Names {
        const references = if (self.reverse) self.reverse_references orelse self.references else self.references;
        return .{
            .table = table,
            .references = references,
            .details = try readNameDetails(self.name_details, references.len / @sizeOf(u32), self.reverse, options.deadline),
            .options = options,
        };
    }

    pub const Limits = struct {
        remaining: []align(1) const access_restriction.Entry,
        forward: bool,

        pub fn next(self: *Limits) ?access_restriction.Entry {
            while (self.remaining.len != 0) {
                const entry = self.remaining[0];
                self.remaining = self.remaining[1..];
                if (entry.applies(self.forward)) return entry;
            }
            return null;
        }
    };

    pub fn restrictions(self: Record) Limits {
        return .{ .remaining = self.access_limits, .forward = !self.reverse };
    }

    pub fn shape(self: Record, arena: Allocator, deadline: io.Deadline) ![]point.FixedLL {
        const vertices = try arena.alloc(point.FixedLL, self.header.point_count);
        errdefer arena.free(vertices);
        try self.decodeShape(vertices, deadline);
        return vertices;
    }

    pub fn decodeShape(self: Record, vertices: []point.FixedLL, deadline: io.Deadline) !void {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (vertices.len != self.header.point_count) return error.InvalidShapeBuffer;
        var decoder = polyline.Decoder(.varint).init(self.encoded, 7);
        for (0..vertices.len) |i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const vertex = (try decoder.nextFixed()) orelse return error.IncompleteShape;
            if (!vertex.inRange()) return error.InvalidColdCoordinate;
            vertices[if (self.reverse) vertices.len - 1 - i else i] = vertex;
        }
        if (!decoder.empty()) return error.TrailingShapeBytes;
    }
};

pub fn appendRecord(out: *std.ArrayList(u8), allocator: Allocator, way_id: u64, speed_limit: u8, mean_elevation: i16, vertices: []const point.FixedLL, refs: []const u32, indoor: Indoor, deadline: io.Deadline) !void {
    return appendDirectionalRecord(out, allocator, way_id, speed_limit, mean_elevation, vertices, refs, null, indoor, deadline);
}

/// A record can override the name list used when traversing against the
/// encoded shape. Such records store a count and references after the
/// indoor data, including an indoor header when there are no levels.
pub fn appendDirectionalRecord(out: *std.ArrayList(u8), allocator: Allocator, way_id: u64, speed_limit: u8, mean_elevation: i16, vertices: []const point.FixedLL, refs: []const u32, reverse_refs: ?[]const u32, indoor: Indoor, deadline: io.Deadline) !void {
    return appendFullRecord(out, allocator, way_id, speed_limit, mean_elevation, vertices, refs, .{
        .reverse_refs = reverse_refs,
        .indoor = indoor,
    }, deadline);
}

pub const Trailer = struct {
    reverse_refs: ?[]const u32 = null,
    name_details: NameDetails = .{},
    reverse_name_details: ?NameDetails = null,
    indoor: Indoor = .{},
    access_limits: []const access_restriction.Entry = &.{},
};

fn readNameDetails(bytes: []const u8, names: usize, reverse: bool, deadline: io.Deadline) !NameDetails {
    if (bytes.len == 0) return .{};
    if (bytes.len < @sizeOf(NameDetailsHeader)) return error.InvalidColdNameDetails;
    const header = std.mem.bytesToValue(NameDetailsHeader, bytes[0..@sizeOf(NameDetailsHeader)]);
    if (header.tagged.reserved != 0 or (!header.tagged.separate_reverse and
        (header.tagged.reverse != 0 or header.linguistic.reverse != 0))) return error.InvalidColdNameDetails;
    var remaining = bytes[@sizeOf(NameDetailsHeader)..];
    const forward: NameDetails = .{
        .linguistic = try detailRecords(linguistics.Entry, header.linguistic.forward, &remaining),
        .tagged = try detailRecords(linguistics.Tagged, header.tagged.forward, &remaining),
    };
    const backward: NameDetails = .{
        .linguistic = try detailRecords(linguistics.Entry, header.linguistic.reverse, &remaining),
        .tagged = try detailRecords(linguistics.Tagged, header.tagged.reverse, &remaining),
    };
    if (remaining.len != 0) return error.InvalidColdNameDetails;
    const result = if (reverse and header.tagged.separate_reverse) backward else forward;
    try result.validate(names, deadline);
    return result;
}

fn detailRecords(comptime T: type, count: usize, remaining: *[]const u8) ![]align(1) const T {
    const size = count * @sizeOf(T);
    if (size > remaining.*.len) return error.InvalidColdNameDetails;
    const records = std.mem.bytesAsSlice(T, remaining.*[0..size]);
    remaining.* = remaining.*[size..];
    return records;
}

noinline fn appendNameDetails(out: *std.ArrayList(u8), allocator: Allocator, forward: NameDetails, reverse: ?NameDetails) !void {
    const backward = reverse orelse NameDetails{};
    const header: NameDetailsHeader = .{
        .linguistic = .{ .forward = @intCast(forward.linguistic.len), .reverse = @intCast(backward.linguistic.len) },
        .tagged = .{ .forward = @intCast(forward.tagged.len), .reverse = @intCast(backward.tagged.len), .separate_reverse = reverse != null },
    };
    const size: u32 = @intCast(@sizeOf(NameDetailsHeader) +
        (forward.linguistic.len + backward.linguistic.len) * @sizeOf(linguistics.Entry) +
        (forward.tagged.len + backward.tagged.len) * @sizeOf(linguistics.Tagged));
    try out.appendSlice(allocator, std.mem.asBytes(&size));
    try out.appendSlice(allocator, std.mem.asBytes(&header));
    for ([_]NameDetails{ forward, backward }) |details| {
        try out.appendSlice(allocator, std.mem.sliceAsBytes(details.linguistic));
        try out.appendSlice(allocator, std.mem.sliceAsBytes(details.tagged));
    }
}

pub fn appendFullRecord(out: *std.ArrayList(u8), allocator: Allocator, way_id: u64, speed_limit: u8, mean_elevation: i16, vertices: []const point.FixedLL, refs: []const u32, trailer: Trailer, deadline: io.Deadline) !void {
    if (vertices.len < 2) return error.IncompleteShape;
    for (trailer.access_limits, 0..) |entry, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!entry.valid()) return error.InvalidColdAccessLimits;
    }
    const point_count = std.math.cast(u32, vertices.len) orelse return error.ShapeTooLarge;
    const name_count = std.math.cast(u8, refs.len) orelse return error.TooManyEdgeNames;
    const reverse_count = std.math.cast(u8, (trailer.reverse_refs orelse refs).len) orelse return error.TooManyEdgeNames;
    const has_details = !trailer.name_details.empty() or trailer.reverse_name_details != null;
    if (has_details) {
        try trailer.name_details.validate(name_count, deadline);
        try (trailer.reverse_name_details orelse trailer.name_details).validate(reverse_count, deadline);
    }
    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    try out.appendNTimes(allocator, 0, @sizeOf(RecordHeader));
    var previous: point.FixedLL = .{ .lat = 0, .lng = 0 };
    var encoded: [10]u8 = undefined;
    for (vertices, 0..) |vertex, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        try out.appendSlice(allocator, polyline.encodeFixedVarint(vertex, previous, &encoded));
        previous = vertex;
    }
    const shape_bytes = std.math.cast(u32, out.items.len - start - @sizeOf(RecordHeader)) orelse return error.ShapeTooLarge;
    try out.appendSlice(allocator, std.mem.sliceAsBytes(refs));
    const indoor = trailer.indoor;
    const has_limits = trailer.access_limits.len != 0;
    const has_reverse_header = trailer.reverse_refs != null or has_limits or has_details;
    if (indoor.layer != 0 or indoor.levels.len != 0 or has_reverse_header) {
        const count = std.math.cast(u24, indoor.levels.len) orelse return error.TooManyLevels;
        const indoor_header: IndoorHeader = .{ .attributes = .{ .layer = indoor.layer, .count = count } };
        try out.appendSlice(allocator, std.mem.asBytes(&indoor_header));
        for (indoor.levels, 0..) |*range, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            try out.appendSlice(allocator, std.mem.asBytes(range));
        }
    }
    if (has_reverse_header) {
        const names = trailer.reverse_refs orelse &.{};
        const reverse_header: ReverseHeader = .{ .attr = .{
            .name_count = std.math.cast(u8, names.len) orelse return error.TooManyEdgeNames,
            .name_details = has_details,
            .inherit_names = trailer.reverse_refs == null,
            .restrictions = has_limits,
        } };
        try out.appendSlice(allocator, std.mem.asBytes(&reverse_header));
        try out.appendSlice(allocator, std.mem.sliceAsBytes(names));
        if (has_details) try appendNameDetails(out, allocator, trailer.name_details, trailer.reverse_name_details);
        try out.appendSlice(allocator, std.mem.sliceAsBytes(trailer.access_limits));
    }
    const header: RecordHeader = .{
        .way_low = @truncate(way_id),
        .way_high = @intCast(way_id >> 32),
        .shape_bytes = shape_bytes,
        .point_count = point_count,
        .attributes = .{ .mean_elevation = mean_elevation, .speed_limit = speed_limit, .name_count = name_count },
    };
    @memcpy(out.items[start..][0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
}

test "cold record preserves an E7 shape over 64 KiB and 255 name references" {
    const testing = std.testing;
    const arena = testing.allocator;
    const vertices = try arena.alloc(point.FixedLL, 14_000);
    defer arena.free(vertices);
    for (vertices, 0..) |*vertex, i| {
        // Alternate across the antimeridian so a signed mathematical delta
        // needs more than i32, then verify the modulo-32-bit round trip.
        vertex.* = .{ .lat = 105, .lng = if (i % 2 == 0) 1_799_998_777 else -1_798_182_997 };
    }
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(arena);
    const refs: [max_names]u32 = @splat(0);
    try testing.expectError(error.DeadlineExceeded, appendRecord(&bytes, arena, 0, 0, no_elevation, vertices, &.{}, .{}, .{ .at_ns = 0 }));
    try testing.expectEqual(0, bytes.items.len);
    const last: linguistics.Entry = .{ .attr = .{ .name_index = 254, .language = .fr } };
    try appendFullRecord(&bytes, arena, 0x0123_4567_89ab_cdef, 255, no_elevation, vertices, &refs, .{
        .name_details = .{ .linguistic = &.{last} },
    }, .none);
    const forward = try Record.parse(bytes.items, false, .none);
    const backward = try Record.parse(bytes.items, true, .none);
    try testing.expect(forward.encoded.len > std.math.maxInt(u16));
    try testing.expectEqual(0x0123_4567_89ab_cdef, forward.wayId());
    try testing.expectEqual(255, forward.speedLimit());
    try testing.expectEqual(no_elevation, forward.meanElevation());
    try testing.expectEqual(max_names, forward.header.attributes.name_count);
    const table: View = .{
        .bytes = "\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00Road",
        .header = .{ .record_count = 0, .name_count = 1, .names_offset = 0 },
        .chunks_start = 0,
        .names_start = 0,
        .strings_start = 16,
    };
    const names = try forward.names(table, .{});
    try testing.expectEqual(max_names, names.count());
    try testing.expectEqual(linguistics.Language.none, (try names.at(0)).language);
    try testing.expectEqual(linguistics.Language.fr, (try names.at(254)).language);
    try testing.expectError(error.InvalidNameIndex, names.at(255));
    const decoded = try forward.shape(arena, .none);
    defer arena.free(decoded);
    try testing.expectEqualSlices(point.FixedLL, vertices, decoded);
    const reversed = try backward.shape(arena, .none);
    defer arena.free(reversed);
    std.mem.reverse(point.FixedLL, reversed);
    try testing.expectEqualSlices(point.FixedLL, vertices, reversed);
}

test "motor limits share a cold record with independent reverse names" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    const vertices: [2]point.FixedLL = .{ .{ .lat = 3, .lng = 4 }, .{ .lat = 5, .lng = 6 } };
    const entries: [2]access_restriction.Entry = .{
        .{ .value = 380, .attr = .{ .kind = .maxheight, .direction = .both } },
        .{ .value = 0, .attr = .{ .kind = .hazmat, .direction = .backward } },
    };
    try appendFullRecord(&bytes, allocator, 1, 0, no_elevation, &vertices, &.{17}, .{
        .reverse_refs = &.{23},
        .access_limits = &entries,
    }, .none);
    const forward = try Record.parse(bytes.items, false, .none);
    const backward = try Record.parse(bytes.items, true, .none);
    try testing.expectEqual(17, readInt(u32, forward.references, 0));
    try testing.expectEqual(23, readInt(u32, backward.reverse_references.?, 0));
    var f = forward.restrictions();
    var r = backward.restrictions();
    try testing.expectEqual(entries[0], f.next().?);
    try testing.expectEqual(null, f.next());
    try testing.expectEqual(entries[0], r.next().?);
    try testing.expectEqual(entries[1], r.next().?);
    try testing.expectEqual(null, r.next());
    try testing.expectError(error.InvalidColdAccessLimits, Record.parse(bytes.items[0 .. bytes.items.len - 1], false, .none));
    bytes.items[bytes.items.len - 1] = 0x80;
    try testing.expectError(error.InvalidColdAccessLimits, Record.parse(bytes.items, false, .none));
}

// Ported from the tagged and linguistic records in test/edgeinfo.cc.
// Ported from test/edgeinfo.cc TaggedValueSize tests. Each native tagged
// value borrows its exact byte range from the shared string table.
test "directional cold names retain languages, phonemes and tagged values" {
    const testing = std.testing;
    const a = testing.allocator;
    const vertices: [2]point.FixedLL = .{ .{ .lat = 3, .lng = 4 }, .{ .lat = 5, .lng = 6 } };
    const offsets = [_]u64{ 0, 5, 8, 11, 17, 21, 22, 28, 31, 32 };
    const text = "NorthipaSAMTunnelZuid\x01Bridge1.5G";
    var table_bytes: [@sizeOf(@TypeOf(offsets)) + text.len]u8 = undefined;
    @memcpy(table_bytes[0..@sizeOf(@TypeOf(offsets))], std.mem.asBytes(&offsets));
    @memcpy(table_bytes[@sizeOf(@TypeOf(offsets))..], text);
    const table: View = .{
        .bytes = &table_bytes,
        .header = .{ .record_count = 0, .name_count = offsets.len - 1, .names_offset = 0 },
        .chunks_start = 0,
        .names_start = 0,
        .strings_start = @sizeOf(@TypeOf(offsets)),
    };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try appendFullRecord(&bytes, a, 7, 80, no_elevation, &vertices, &.{nameRef(0, true)}, .{
        .reverse_refs = &.{nameRef(4, false)},
        .indoor = .{ .layer = 1, .levels = &.{.init(2, 4)} },
        .name_details = .{
            .linguistic = &.{
                .{ .text_ref = 1, .attr = .{ .name_index = 0, .language = .en, .alphabet = .ipa } },
                .{ .text_ref = 2, .attr = .{ .name_index = 0, .language = .en, .alphabet = .nt_sampa } },
                .{ .attr = .{ .name_index = 1, .language = .en } },
            },
            .tagged = &.{
                .{ .text_ref = 3, .attr = .{ .kind = .tunnel } },
                .{ .text_ref = 5, .attr = .{ .kind = .layer } },
                .{ .text_ref = 6, .attr = .{ .kind = .bridge } },
                .{ .text_ref = 7, .attr = .{ .kind = .level } },
                .{ .text_ref = 8, .attr = .{ .kind = .level_ref } },
            },
        },
        .reverse_name_details = .{ .linguistic = &.{.{ .attr = .{ .name_index = 0, .language = .nl } }} },
        .access_limits = &.{.{ .value = 380, .attr = .{ .kind = .maxheight, .direction = .both } }},
    }, .none);
    const forward = try Record.parse(bytes.items, false, .none);
    const ordinary = try forward.names(table, .{});
    try testing.expectEqual(1, ordinary.count());
    const name = try ordinary.at(0);
    try testing.expectEqualStrings("North", name.text);
    try testing.expect(name.route);
    try testing.expectEqual(linguistics.Language.en, name.language);
    try testing.expectEqual(linguistics.Alphabet.nt_sampa, name.pronunciation.?.alphabet);
    try testing.expectEqualStrings("SAM", name.pronunciation.?.text);
    const all = try forward.names(table, .{ .include_tagged = true });
    try testing.expectEqual(6, all.count());
    const tunnel = try all.at(1);
    try testing.expectEqual(linguistics.Tag.tunnel, tunnel.tagged.?);
    try testing.expectEqualStrings("Tunnel", tunnel.text);
    try testing.expect(!tunnel.route);
    try testing.expectEqual(linguistics.Language.en, tunnel.language);
    try testing.expectEqualStrings("\x01", (try all.at(2)).text);
    try testing.expectEqual(linguistics.Tag.bridge, (try all.at(3)).tagged.?);
    try testing.expectEqualStrings("Bridge", (try all.at(3)).text);
    try testing.expectEqual(linguistics.Tag.level, (try all.at(4)).tagged.?);
    try testing.expectEqualStrings("1.5", (try all.at(4)).text);
    try testing.expectEqual(linguistics.Tag.level_ref, (try all.at(5)).tagged.?);
    try testing.expectEqualStrings("G", (try all.at(5)).text);
    try testing.expect(try forward.indoor.includes(3, .none));
    try testing.expectEqual(1, forward.access_limits.len);
    const backward = try (try Record.parse(bytes.items, true, .none)).names(table, .{ .include_tagged = true });
    try testing.expectEqual(1, backward.count());
    const reversed = try backward.at(0);
    try testing.expectEqualStrings("Zuid", reversed.text);
    try testing.expectEqual(linguistics.Language.nl, reversed.language);
    try testing.expectEqual(null, reversed.pronunciation);
    try testing.expectError(error.InvalidColdNameDetails, readNameDetails(forward.name_details[0 .. forward.name_details.len - 1], 1, false, .none));
}

test "cold directory locates the last record in a full chunk and the following chunk" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const vertices: [2]point.FixedLL = @splat(.{ .lat = 0, .lng = 0 });
    const record_bytes = @sizeOf(RecordHeader) + 4;
    const full_chunk_bytes = (chunk_size + 1) * @sizeOf(u64) + chunk_size * record_bytes;
    const last_chunk_bytes = 2 * @sizeOf(u64) + record_bytes;
    const directory = [_]u64{ 0, full_chunk_bytes, full_chunk_bytes + last_chunk_bytes };
    const header: Header = .{
        .record_count = chunk_size + 1,
        .name_count = 0,
        .names_offset = @sizeOf(Header) + @sizeOf(@TypeOf(directory)) + directory[2],
    };
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.appendSlice(gpa, std.mem.asBytes(&header));
    try data.appendSlice(gpa, std.mem.sliceAsBytes(&directory));
    var records: [chunk_size + 1]u64 = undefined;
    for (&records, 0..) |*offset, i| offset.* = i * record_bytes;
    try data.appendSlice(gpa, std.mem.sliceAsBytes(&records));
    for (0..chunk_size) |i| try appendRecord(&data, gpa, i + 1, 0, no_elevation, &vertices, &.{}, .{}, .none);
    try data.appendSlice(gpa, std.mem.asBytes(&[2]u64{ 0, record_bytes }));
    try appendRecord(&data, gpa, chunk_size + 1, 0, no_elevation, &vertices, &.{}, .{}, .none);
    try data.appendSlice(gpa, std.mem.asBytes(&@as(u64, 0)));

    const view = try View.parse(data.items);
    try testing.expectEqual(chunk_size, (try view.record(directedIndex(chunk_size - 1, false))).wayId());
    try testing.expectEqual(chunk_size + 1, (try view.record(directedIndex(chunk_size, true))).wayId());
}

test "cold indoor metadata is optional and validates its range count" {
    const testing = std.testing;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    const shape = [_]point.FixedLL{ .{ .lng = 0, .lat = 0 }, .{ .lng = 100, .lat = 200 } };
    const ranges = [_]LevelRange{ .init(-2, -1), .init(1.5, 1.5), .init(3, 6) };
    try appendRecord(&bytes, testing.allocator, 42, 10, no_elevation, &shape, &.{}, .{ .layer = -1, .levels = &ranges }, .none);
    const record = try Record.parse(bytes.items, true, .none);
    try testing.expectEqual(-1, record.indoor.layer);
    try testing.expect(try record.indoor.includes(5, .none));
    try testing.expect(try record.indoor.includes(-1, .none));
    try testing.expect(!try record.indoor.includes(0, .none));
    try testing.expectError(error.InvalidColdIndoorData, Record.parse(bytes.items[0 .. bytes.items.len - 1], false, .none));
    const old = try Record.parse(bytes.items[0 .. bytes.items.len - @sizeOf(IndoorHeader) - @sizeOf(@TypeOf(ranges))], false, .none);
    try testing.expectEqual(0, old.indoor.layer);
    try testing.expectEqual(0, old.indoor.levels.len);
}
