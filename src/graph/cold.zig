// Ported from src/baldr/edgeinfo.cc and src/mjolnir/graphtilebuilder.cc
// (Valhalla 3.9.3). The v1 bundle uses dense records and a shared string table.
const std = @import("std");
const io = @import("../infra/io.zig");
const point = @import("../geo/point.zig");
const polyline = @import("../geo/polyline.zig");
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

pub const LevelRange = extern struct {
    bounds: packed struct(u64) {
        first: f32,
        last: f32,
    },

    pub fn init(first: f32, last: f32) LevelRange {
        return .{ .bounds = .{ .first = first, .last = last } };
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
        return Record.parse(data, index & high_bit != 0);
    }

    fn name(self: View, reference: u32) !Name {
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
};

pub const Names = struct {
    table: View,
    references: []const u8,

    pub fn count(self: Names) usize {
        return self.references.len / @sizeOf(u32);
    }

    pub fn at(self: Names, i: usize) !Name {
        if (i >= self.count()) return error.InvalidNameIndex;
        return self.table.name(readInt(u32, self.references, i * @sizeOf(u32)));
    }
};

pub const Record = struct {
    header: RecordHeader,
    reverse: bool,
    encoded: []const u8,
    references: []const u8,
    reverse_references: ?[]const u8 = null,
    indoor: Indoor,

    fn parse(bytes: []const u8, reverse: bool) !Record {
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
        const indoor: Indoor = if (trailer.len == 0) .{} else blk: {
            if (trailer.len < @sizeOf(IndoorHeader)) return error.InvalidColdIndoorData;
            const info = std.mem.bytesToValue(IndoorHeader, trailer[0..@sizeOf(IndoorHeader)]).attributes;
            const payload = trailer[@sizeOf(IndoorHeader)..];
            const size = @as(usize, info.count) * @sizeOf(LevelRange);
            if (size > payload.len) return error.InvalidColdIndoorData;
            const reverse_names = payload[size..];
            if (reverse_names.len != 0) {
                if (reverse_names.len < @sizeOf(u32)) return error.InvalidColdReverseNames;
                const count = readInt(u32, reverse_names, 0);
                if (count > max_names or reverse_names.len != (@as(usize, count) + 1) * @sizeOf(u32)) return error.InvalidColdReverseNames;
                reverse_references = reverse_names[@sizeOf(u32)..];
            }
            break :blk .{ .layer = info.layer, .levels = std.mem.bytesAsSlice(LevelRange, payload[0..size]) };
        };
        return .{
            .header = header,
            .reverse = reverse,
            .encoded = data[0..header.shape_bytes],
            .references = data[header.shape_bytes..end],
            .reverse_references = reverse_references,
            .indoor = indoor,
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

    pub fn names(self: Record, table: View) Names {
        return .{ .table = table, .references = if (self.reverse) self.reverse_references orelse self.references else self.references };
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
    if (vertices.len < 2) return error.IncompleteShape;
    const point_count = std.math.cast(u32, vertices.len) orelse return error.ShapeTooLarge;
    const name_count = std.math.cast(u8, refs.len) orelse return error.TooManyEdgeNames;
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
    if (indoor.layer != 0 or indoor.levels.len != 0 or reverse_refs != null) {
        const count = std.math.cast(u24, indoor.levels.len) orelse return error.TooManyLevels;
        const indoor_header: IndoorHeader = .{ .attributes = .{ .layer = indoor.layer, .count = count } };
        try out.appendSlice(allocator, std.mem.asBytes(&indoor_header));
        for (indoor.levels, 0..) |*range, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            try out.appendSlice(allocator, std.mem.asBytes(range));
        }
    }
    if (reverse_refs) |names| {
        if (names.len > max_names) return error.TooManyEdgeNames;
        const count: u32 = @intCast(names.len);
        try out.appendSlice(allocator, std.mem.asBytes(&count));
        try out.appendSlice(allocator, std.mem.sliceAsBytes(names));
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
    try appendRecord(&bytes, arena, 0x0123_4567_89ab_cdef, 255, no_elevation, vertices, &refs, .{}, .none);
    const forward = try Record.parse(bytes.items, false);
    const backward = try Record.parse(bytes.items, true);
    try testing.expect(forward.encoded.len > std.math.maxInt(u16));
    try testing.expectEqual(0x0123_4567_89ab_cdef, forward.wayId());
    try testing.expectEqual(255, forward.speedLimit());
    try testing.expectEqual(no_elevation, forward.meanElevation());
    try testing.expectEqual(max_names, forward.header.attributes.name_count);
    const decoded = try forward.shape(arena, .none);
    defer arena.free(decoded);
    try testing.expectEqualSlices(point.FixedLL, vertices, decoded);
    const reversed = try backward.shape(arena, .none);
    defer arena.free(reversed);
    std.mem.reverse(point.FixedLL, reversed);
    try testing.expectEqualSlices(point.FixedLL, vertices, reversed);
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
    const record = try Record.parse(bytes.items, true);
    try testing.expectEqual(-1, record.indoor.layer);
    try testing.expect(try record.indoor.includes(5, .none));
    try testing.expect(try record.indoor.includes(-1, .none));
    try testing.expect(!try record.indoor.includes(0, .none));
    try testing.expectError(error.InvalidColdIndoorData, Record.parse(bytes.items[0 .. bytes.items.len - 1], false));
    const old = try Record.parse(bytes.items[0 .. bytes.items.len - @sizeOf(IndoorHeader) - @sizeOf(@TypeOf(ranges))], false);
    try testing.expectEqual(0, old.indoor.layer);
    try testing.expectEqual(0, old.indoor.levels.len);
}
