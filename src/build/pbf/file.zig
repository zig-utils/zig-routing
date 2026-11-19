// Ported from third_party/libosmium/include/osmium/io/detail/pbf_input_format.hpp
// and pbf_decoder.hpp in Valhalla 3.9.3's pinned libosmium.

const std = @import("std");
const protobuf = @import("protobuf");
const lz4 = @import("lz4");
const io = @import("../../infra/io.zig");
const schema = @import("schema.zig");
const Allocator = std.mem.Allocator;

pub const max_header_bytes = 64 * 1024;
pub const max_blob_bytes = 32 * 1024 * 1024;

pub const Error = protobuf.Error || io.InflateError || error{
    InvalidBlobHeaderSize,
    InvalidBlobSize,
    InvalidBlobIndex,
    InvalidBlobOffset,
    MissingHeader,
    RepeatedHeader,
    HeaderAfterData,
    MissingBlobPayload,
    MultipleBlobPayloads,
    InvalidBlobField,
    UnsupportedCompression,
    MissingRawSize,
    InvalidRawSize,
    MissingSchemaFeature,
    UnsupportedRequiredFeature,
    InvalidHeaderBounds,
    InflateBufferTooSmall,
    CorruptLz4,
};

pub const Bounds = struct {
    /// Signed nanodegrees.
    left: i64,
    right: i64,
    top: i64,
    bottom: i64,
};

pub const Header = struct {
    bounds: ?Bounds,
    required_features: []const []const u8,
    optional_features: []const []const u8,
    sorted_by_type_and_id: bool,
    replication_timestamp: ?i64,
    writing_program: ?[]const u8,
};

pub const Compression = enum { raw, zlib, lz4 };

/// Offsets are relative to the start of the file. `size` includes the length
/// prefix, BlobHeader and Blob. The payload points into the Blob.
pub const BlobIndex = struct {
    offset: usize,
    size: u32,
    payload_offset: usize,
    payload_size: u32,
    raw_size: u32,
    compression: Compression,
};

pub const File = struct {
    mapping: io.Mapping,
    index: Index,

    pub fn open(gpa: Allocator, path: []const u8, deadline: io.Deadline) !File {
        const file = try io.File.open(path, .read_only);
        defer file.close();
        return openFd(gpa, file, deadline);
    }

    pub fn openFd(gpa: Allocator, file: io.File, deadline: io.Deadline) !File {
        const mapping = try io.Mapping.mapFd(file, .read_only);
        errdefer mapping.unmap();
        mapping.adviseAll(.sequential) catch {};
        return .{ .mapping = mapping, .index = try Index.init(gpa, mapping.bytes, deadline) };
    }

    pub fn close(self: *File) void {
        self.index.deinit();
        self.mapping.unmap();
    }
};

pub const DecodeOptions = struct {
    workers: usize = 0,
    buffer_bytes: usize = std.math.maxInt(usize),
};

/// An immutable index of the OSMData blocks in file order. The input bytes
/// must outlive the index, including all reads from its workers.
pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    input: []const u8,
    header: Header,
    blobs: []const BlobIndex,
    ignored_blocks: usize,
    /// Largest output buffer needed for any compressed data blob.
    inflate_capacity: usize,

    pub fn init(gpa: Allocator, input: []const u8, deadline: io.Deadline) (Error || Allocator.Error)!Index {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var header: ?Header = null;
        var blobs: std.ArrayList(BlobIndex) = .empty;
        var ignored: usize = 0;
        var max_size: usize = 0;
        var offset: usize = 0;
        while (offset < input.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const start = offset;
            const frame = try nextFrame(input, &offset, deadline);
            if (std.mem.eql(u8, frame.kind, "OSMHeader")) {
                if (header != null) return error.RepeatedHeader;
                const desc = try describeBlob(input, start, offset - start, frame.blob, deadline);
                const scratch: []u8 = if (desc.compression == .raw) &.{} else try a.alloc(u8, desc.raw_size);
                header = try parseHeader(a, try inflate(input, desc, scratch, deadline), deadline);
            } else if (std.mem.eql(u8, frame.kind, "OSMData")) {
                if (header == null) return error.HeaderAfterData;
                const desc = try describeBlob(input, start, offset - start, frame.blob, deadline);
                try blobs.append(a, desc);
                if (desc.compression != .raw) max_size = @max(max_size, desc.raw_size);
            } else {
                ignored += 1;
            }
        }
        return .{
            .arena = arena,
            .input = input,
            .header = header orelse return error.MissingHeader,
            .blobs = blobs.items,
            .ignored_blocks = ignored,
            .inflate_capacity = max_size,
        };
    }

    pub fn deinit(self: *Index) void {
        self.arena.deinit();
    }

    /// Raw blocks borrow the input. Compressed blocks borrow `scratch`.
    pub fn inflateInto(self: *const Index, i: usize, scratch: []u8, deadline: io.Deadline) Error![]const u8 {
        if (i >= self.blobs.len) return error.InvalidBlobIndex;
        return inflate(self.input, self.blobs[i], scratch, deadline);
    }

    /// Decode with a bounded pool and call the consumer in file order. Every
    /// block view is valid until its callback returns. Zero workers chooses
    /// the host CPU count. Each buffer is allocated once for the whole pass.
    pub fn forEach(self: *const Index, gpa: Allocator, workers: usize, deadline: io.Deadline, context: anytype, comptime consume: anytype) !void {
        return self.forEachBounded(gpa, .{ .workers = workers }, deadline, context, consume);
    }

    pub fn forEachBounded(self: *const Index, gpa: Allocator, options: DecodeOptions, deadline: io.Deadline, context: anytype, comptime consume: anytype) !void {
        if (self.blobs.len == 0) return;
        const requested = if (options.workers == 0) std.Thread.getCpuCount() catch 1 else options.workers;
        const slots_available = if (self.inflate_capacity == 0) self.blobs.len else @min(self.blobs.len, options.buffer_bytes / self.inflate_capacity);
        if (slots_available == 0) return error.PbfDecodeBudgetExceeded;
        const thread_count = @min(requested, slots_available);
        if (thread_count == 1) {
            const scratch = try gpa.alloc(u8, self.inflate_capacity);
            defer gpa.free(scratch);
            for (0..self.blobs.len) |i| try consume(context, i, try self.inflateInto(i, scratch, deadline));
            return;
        }

        const slot_count = @min(slots_available, thread_count *| 2);
        const scratch = try gpa.alloc(u8, std.math.mul(usize, slot_count, self.inflate_capacity) catch return error.OutOfMemory);
        defer gpa.free(scratch);
        const slots = try gpa.alloc(Slot, slot_count);
        defer gpa.free(slots);
        for (slots, 0..) |*slot, i| {
            slot.* = .{ .scratch = scratch[i * self.inflate_capacity ..][0..self.inflate_capacity] };
        }
        const threads = try gpa.alloc(std.Thread, thread_count);
        defer gpa.free(threads);
        var pool: Pool = .{ .index = self, .slots = slots, .deadline = deadline };
        var started: usize = 0;
        defer {
            pool.stop();
            for (threads[0..started]) |thread| thread.join();
        }
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Pool.work, .{&pool});
            started += 1;
        }
        for (0..self.blobs.len) |i| {
            try consume(context, i, try pool.result(i));
            pool.release(i);
        }
    }
};

fn OrderedConsumer(comptime Target: type, comptime consume: anytype) type {
    return struct {
        target: Target,
        next: usize = 0,

        fn emit(forward: *@This(), _: usize, bytes: []const u8) !void {
            try consume(forward.target, forward.next, bytes);
            forward.next += 1;
        }
    };
}

/// Reuse mapped indexes across the build passes while keeping their callbacks
/// in input order. Only one input's decode buffers are live at a time.
pub const IndexedStreams = struct {
    files: []const File,
    decode: DecodeOptions,

    pub fn forEach(self: IndexedStreams, gpa: Allocator, deadline: io.Deadline, context: anytype, comptime consume: anytype) !void {
        var forward: OrderedConsumer(@TypeOf(context), consume) = .{ .target = context };
        for (self.files) |*file| {
            if (deadline.expired()) return error.DeadlineExceeded;
            try file.index.forEachBounded(gpa, self.decode, deadline, &forward, @TypeOf(forward).emit);
        }
    }
};

const Frame = struct { kind: []const u8, blob: []const u8 };

fn frameHeaderSize(prefix: *const [4]u8) Error!u32 {
    const size = std.mem.readInt(u32, prefix, .big);
    if (size == 0 or size >= max_header_bytes) return error.InvalidBlobHeaderSize;
    return size;
}

fn frameHeader(bytes: []const u8, deadline: io.Deadline) Error!struct { kind: []const u8, size: usize } {
    const header = try schema.BlobHeader.decode(bytes, deadline);
    const size = try header.get("datasize", deadline);
    if (size <= 0 or size >= max_blob_bytes) return error.InvalidBlobSize;
    return .{ .kind = try header.get("type", deadline), .size = @intCast(size) };
}

fn nextFrame(input: []const u8, offset: *usize, deadline: io.Deadline) Error!Frame {
    var rest = input[offset.*..];
    if (rest.len < 4) return error.Truncated;
    const header_size = try frameHeaderSize(rest[0..4]);
    rest = rest[4..];
    if (header_size > rest.len) return error.Truncated;
    const header = try frameHeader(rest[0..header_size], deadline);
    rest = rest[header_size..];
    if (header.size > rest.len) return error.Truncated;
    offset.* += 4 + @as(usize, header_size) + header.size;
    return .{ .kind = header.kind, .blob = rest[0..header.size] };
}

/// Ordered sequential scans with memory bounded by the largest blob, for
/// build passes that can repeat from the beginning. The caller owns the
/// immutable input file. Callback bytes are valid only during that call.
pub const Stream = struct {
    file: io.File,
    size: u64,

    pub fn init(file: io.File) io.Error!Stream {
        return .{ .file = file, .size = try file.size() };
    }

    pub fn validateHeader(self: Stream, gpa: Allocator, deadline: io.Deadline) !void {
        return self.read(gpa, deadline, {}, null);
    }

    pub fn forEach(self: Stream, gpa: Allocator, deadline: io.Deadline, context: anytype, comptime consume: anytype) !void {
        return self.read(gpa, deadline, context, consume);
    }

    fn read(self: Stream, gpa: Allocator, deadline: io.Deadline, context: anytype, comptime consume: anytype) !void {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(gpa);
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(gpa);
        var header_bytes: [max_header_bytes]u8 = undefined;
        var seen_header = false;
        var offset: u64 = 0;
        var index: usize = 0;
        while (offset < self.size) {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (self.size - offset < 4) return error.Truncated;
            try self.file.preadAll(header_bytes[0..4], offset);
            const header_size = try frameHeaderSize(header_bytes[0..4]);
            offset += 4;
            if (self.size - offset < header_size) return error.Truncated;
            const raw_header = header_bytes[0..header_size];
            try self.file.preadAll(raw_header, offset);
            const header = try frameHeader(raw_header, deadline);
            offset += header_size;
            if (self.size - offset < header.size) return error.Truncated;
            const start = offset;
            offset += header.size;

            const is_header = std.mem.eql(u8, header.kind, "OSMHeader");
            const is_data = std.mem.eql(u8, header.kind, "OSMData");
            if (!is_header and !is_data) continue;
            if (is_header and seen_header) return error.RepeatedHeader;
            if (is_data and !seen_header) return error.HeaderAfterData;
            try encoded.resize(gpa, header.size);
            try self.file.preadAll(encoded.items, start);
            const desc = try describeBlob(encoded.items, 0, header.size, encoded.items, deadline);
            if (desc.compression != .raw) try decoded.resize(gpa, desc.raw_size);
            const bytes = try inflate(encoded.items, desc, decoded.items, deadline);
            if (is_header) {
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                _ = try parseHeader(arena.allocator(), bytes, deadline);
                if (@TypeOf(consume) == @TypeOf(null)) return;
                seen_header = true;
            } else {
                if (@TypeOf(consume) != @TypeOf(null)) try consume(context, index, bytes);
                index += 1;
            }
        }
        if (!seen_header) return error.MissingHeader;
    }
};

/// Read each source in input order while presenting one block sequence.
pub const Streams = struct {
    files: []const Stream,

    pub fn forEach(self: Streams, gpa: Allocator, deadline: io.Deadline, context: anytype, comptime consume: anytype) !void {
        var forward: OrderedConsumer(@TypeOf(context), consume) = .{ .target = context };
        for (self.files) |file| {
            if (deadline.expired()) return error.DeadlineExceeded;
            try file.forEach(gpa, deadline, &forward, @TypeOf(forward).emit);
        }
    }
};

fn describeBlob(input: []const u8, offset: usize, size: usize, blob: []const u8, deadline: io.Deadline) Error!BlobIndex {
    var reader = protobuf.wire.Reader.init(blob);
    var payload: ?[]const u8 = null;
    var raw_size: ?u32 = null;
    var compression: Compression = .raw;
    while (try reader.next(deadline)) |field| {
        switch (field.number) {
            2 => {
                if (field.value != .varint or raw_size != null) return error.InvalidBlobField;
                const value = field.value.varint;
                if (value >= max_blob_bytes) return error.InvalidRawSize;
                raw_size = @intCast(value);
            },
            1, 3...7 => {
                if (field.value != .length_delimited) return error.InvalidBlobField;
                if (payload != null) return error.MultipleBlobPayloads;
                compression = switch (field.number) {
                    1 => .raw,
                    3 => .zlib,
                    6 => .lz4,
                    else => return error.UnsupportedCompression,
                };
                payload = field.value.length_delimited;
            },
            else => {},
        }
    }
    const bytes = payload orelse return error.MissingBlobPayload;
    return .{
        .offset = offset,
        .size = @intCast(size),
        .payload_offset = @intFromPtr(bytes.ptr) - @intFromPtr(input.ptr),
        .payload_size = @intCast(bytes.len),
        .raw_size = if (compression == .raw) @intCast(bytes.len) else raw_size orelse return error.MissingRawSize,
        .compression = compression,
    };
}

fn inflate(input: []const u8, blob: BlobIndex, scratch: []u8, deadline: io.Deadline) Error![]const u8 {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (blob.payload_offset > input.len or blob.payload_size > input.len - blob.payload_offset) return error.InvalidBlobOffset;
    const bytes = input[blob.payload_offset..][0..blob.payload_size];
    if (blob.compression == .raw) return bytes;
    if (scratch.len < blob.raw_size) return error.InflateBufferTooSmall;
    const dst = scratch[0..blob.raw_size];
    switch (blob.compression) {
        .raw => unreachable,
        .zlib => try io.inflateZlibExact(bytes, dst, deadline),
        .lz4 => {
            const written = lz4.decompressBlock(bytes, dst) catch |err| switch (err) {
                error.OutputTooSmall => return error.InflateSizeMismatch,
                else => return error.CorruptLz4,
            };
            if (written.len != dst.len) return error.InflateSizeMismatch;
            if (deadline.expired()) return error.DeadlineExceeded;
        },
    }
    return dst;
}

fn collectStrings(a: Allocator, input: anytype, deadline: io.Deadline) (Error || Allocator.Error)![]const []const u8 {
    var it = input;
    var strings: std.ArrayList([]const u8) = .empty;
    while (try it.next(deadline)) |name| try strings.append(a, name);
    return strings.items;
}

fn parseHeader(a: Allocator, bytes: []const u8, deadline: io.Deadline) (Error || Allocator.Error)!Header {
    const view = try schema.HeaderBlock.decode(bytes, deadline);
    const required = try collectStrings(a, try view.get("required_features", deadline), deadline);
    const optional = try collectStrings(a, try view.get("optional_features", deadline), deadline);
    const sort_feature = "Sort.Type_then_ID";
    var schema_supported = false;
    var sorted = false;
    for (required, 0..) |name, i| {
        try protobuf.wire.checkAt(deadline, i);
        if (std.mem.eql(u8, name, "OsmSchema-V0.6")) {
            schema_supported = true;
        } else if (std.mem.eql(u8, name, sort_feature)) {
            sorted = true;
        } else if (!std.mem.eql(u8, name, "DenseNodes") and !std.mem.eql(u8, name, "HistoricalInformation")) {
            return error.UnsupportedRequiredFeature;
        }
    }
    if (!schema_supported) return error.MissingSchemaFeature;
    for (optional, 0..) |name, i| {
        try protobuf.wire.checkAt(deadline, i);
        if (std.mem.eql(u8, name, sort_feature)) sorted = true;
    }
    const bbox = try view.get("bbox", deadline);
    const bounds: ?Bounds = if (bbox) |v| .{
        .left = try v.get("left", deadline),
        .right = try v.get("right", deadline),
        .top = try v.get("top", deadline),
        .bottom = try v.get("bottom", deadline),
    } else null;
    if (bounds) |b| {
        if (b.left < -180_000_000_000 or b.right > 180_000_000_000 or b.left > b.right or
            b.bottom < -90_000_000_000 or b.top > 90_000_000_000 or b.bottom > b.top)
            return error.InvalidHeaderBounds;
    }
    return .{
        .bounds = bounds,
        .required_features = required,
        .optional_features = optional,
        .sorted_by_type_and_id = sorted,
        .replication_timestamp = try view.get("osmosis_replication_timestamp", deadline),
        .writing_program = try view.get("writingprogram", deadline),
    };
}

const Slot = struct {
    scratch: []u8,
    ready: bool = false,
    result: Error![]const u8 = undefined,
};

const Pool = struct {
    index: *const Index,
    slots: []Slot,
    deadline: io.Deadline,
    mutex: io.Mutex = .{},
    changed: io.Condition = .{},
    stopping: bool = false,
    next_job: usize = 0,
    consumed: usize = 0,

    fn claim(self: *Pool) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.stopping and self.next_job < self.index.blobs.len and self.next_job - self.consumed == self.slots.len) {
            self.changed.wait(&self.mutex);
        }
        if (self.stopping or self.next_job == self.index.blobs.len) return null;
        const job = self.next_job;
        self.next_job += 1;
        return job;
    }

    fn work(self: *Pool) void {
        while (self.claim()) |i| {
            const slot = &self.slots[i % self.slots.len];
            const decoded = self.index.inflateInto(i, slot.scratch, self.deadline);
            self.mutex.lock();
            slot.result = decoded;
            slot.ready = true;
            self.changed.broadcast();
            self.mutex.unlock();
        }
    }

    fn result(self: *Pool, i: usize) Error![]const u8 {
        const slot = &self.slots[i % self.slots.len];
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!slot.ready) self.changed.wait(&self.mutex);
        return slot.result;
    }

    fn release(self: *Pool, i: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.slots[i % self.slots.len].ready = false;
        self.consumed += 1;
        self.changed.broadcast();
    }

    fn stop(self: *Pool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopping = true;
        self.changed.broadcast();
    }
};

const testing = std.testing;
const fixture_header: schema.HeaderBlock.Values = .{
    .bbox = .{ .left = -1_000_000_001, .right = 2_000_000_002, .bottom = -3_000_000_003, .top = 4_000_000_004 },
    .required_features = &.{ "OsmSchema-V0.6", "DenseNodes" },
    .optional_features = &.{ "Sort.Type_then_ID", "OtherOptionalFeature" },
    .writingprogram = "zig-routing tests",
    .osmosis_replication_timestamp = 1_700_000_000,
};

fn testFrame(a: Allocator, out: *std.ArrayList(u8), kind: []const u8, blob: schema.Blob.Values) !void {
    const deadline = protobuf.no_deadline;
    const size = try schema.Blob.encodedSize(blob, deadline);
    const header: schema.BlobHeader.Values = .{ .type = kind, .datasize = @intCast(size) };
    const header_size = try schema.BlobHeader.encodedSize(header, deadline);
    const bytes = try out.addManyAsSlice(a, 4 + header_size + size);
    std.mem.writeInt(u32, bytes[0..4], @intCast(header_size), .big);
    _ = try schema.BlobHeader.encode(bytes[4..][0..header_size], header, deadline);
    _ = try schema.Blob.encode(bytes[4 + header_size ..], blob, deadline);
}

fn testHeader(a: Allocator, out: *std.ArrayList(u8), value: schema.HeaderBlock.Values) !void {
    const deadline = protobuf.no_deadline;
    const bytes = try a.alloc(u8, try schema.HeaderBlock.encodedSize(value, deadline));
    defer a.free(bytes);
    try testFrame(a, out, "OSMHeader", .{ .raw = try schema.HeaderBlock.encode(bytes, value, deadline) });
}

/// The zlib envelope for a final, uncompressed three-byte DEFLATE block.
fn storedZlib(value: [3]u8) [14]u8 {
    var bytes: [14]u8 = .{ 0x78, 0x01, 0x01, 0x03, 0x00, 0xfc, 0xff, 0, 0, 0, 0, 0, 0, 0 };
    bytes[7..10].* = value;
    std.mem.writeInt(u32, bytes[10..14], std.hash.Adler32.hash(&value), .big);
    return bytes;
}

test "OSM PBF header, formats and ordered pool reuse" {
    const a = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try testHeader(a, &bytes, fixture_header);
    try testFrame(a, &bytes, "IgnoredExtension", .{ .raw = "skipped" });
    for (0..23) |i| {
        const value: [3]u8 = .{ 'A' + @as(u8, @intCast(i)), 'b', 'c' };
        switch (i % 3) {
            0 => try testFrame(a, &bytes, "OSMData", .{ .raw = &value }),
            1 => try testFrame(a, &bytes, "OSMData", .{ .zlib_data = &storedZlib(value), .raw_size = value.len }),
            else => try testFrame(a, &bytes, "OSMData", .{ .lz4_data = &([_]u8{0x30} ++ value), .raw_size = value.len }),
        }
    }
    var index = try Index.init(a, bytes.items, .none);
    defer index.deinit();
    try testing.expectEqual(1, index.ignored_blocks);
    try testing.expectEqual(23, index.blobs.len);
    try testing.expectEqual(3, index.inflate_capacity);
    try testing.expectEqual(Compression.lz4, index.blobs[2].compression);
    try testing.expect(index.blobs[22].offset > index.blobs[21].offset);
    try testing.expectEqual(-1_000_000_001, index.header.bounds.?.left);
    try testing.expectEqual(4_000_000_004, index.header.bounds.?.top);
    try testing.expectEqual(@as(?i64, 1_700_000_000), index.header.replication_timestamp);
    try testing.expect(index.header.sorted_by_type_and_id);
    try testing.expectEqualStrings("zig-routing tests", index.header.writing_program.?);
    try testing.expectEqualStrings("DenseNodes", index.header.required_features[1]);
    try testing.expectEqualStrings("OtherOptionalFeature", index.header.optional_features[1]);

    const CountingAllocator = @import("../../infra/arena.zig").CountingAllocator;
    const Check = struct {
        allocator: ?*CountingAllocator = null,
        previous_calls: usize = 0,
        next: usize = 0,

        fn consume(self: *@This(), i: usize, data: []const u8) !void {
            try testing.expectEqual(self.next, i);
            try testing.expectEqualStrings(&.{ 'A' + @as(u8, @intCast(i)), 'b', 'c' }, data);
            if (self.allocator) |allocator| {
                if (i == 0) self.previous_calls = allocator.calls();
                try testing.expectEqual(self.previous_calls, allocator.calls());
            }
            self.next += 1;
        }
    };
    var count = CountingAllocator.init(a);
    for ([_]usize{ 1, 4 }) |workers| {
        var check: Check = .{ .allocator = &count };
        try index.forEach(count.allocator(), workers, .none, &check, Check.consume);
        try testing.expectEqual(index.blobs.len, check.next);
    }
    for ([_]usize{ 3, 6 }) |bytes_limit| {
        var check: Check = .{ .allocator = &count };
        try index.forEachBounded(count.allocator(), .{ .workers = 4, .buffer_bytes = bytes_limit }, .none, &check, Check.consume);
        try testing.expectEqual(index.blobs.len, check.next);
    }
    var too_small: Check = .{};
    try testing.expectError(error.PbfDecodeBudgetExceeded, index.forEachBounded(a, .{ .workers = 4, .buffer_bytes = 2 }, .none, &too_small, Check.consume));
    try testing.expectEqual(@as(usize, 0), too_small.next);
    const input = try io.File.temporary(".");
    defer input.close();
    try input.writeAll(bytes.items);
    var stream_check: Check = .{};
    const stream = try Stream.init(input);
    try stream.forEach(a, .none, &stream_check, Check.consume);
    try testing.expectEqual(index.blobs.len, stream_check.next);

    const Abort = struct {
        fn consume(_: void, _: usize, _: []const u8) error{ConsumerStopped}!void {
            return error.ConsumerStopped;
        }
    };
    try testing.expectError(error.ConsumerStopped, index.forEach(a, 4, .none, {}, Abort.consume));
    try testing.expectError(error.DeadlineExceeded, index.forEach(a, 4, .{ .at_ns = 0 }, {}, Abort.consume));
    try testing.expectError(error.ConsumerStopped, stream.forEach(a, .none, {}, Abort.consume));
    try testing.expectError(error.DeadlineExceeded, stream.forEach(a, .{ .at_ns = 0 }, {}, Abort.consume));
}

test "truncated framing, unknown required features and unsupported compression fail" {
    const a = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try testHeader(a, &bytes, fixture_header);
    const data_offset = bytes.items.len;
    try testFrame(a, &bytes, "OSMData", .{ .raw = "abc" });
    for (data_offset + 1..bytes.items.len) |end| {
        try testing.expectError(error.Truncated, Index.init(a, bytes.items[0..end], .none));
    }
    try testing.expectError(error.InvalidBlobHeaderSize, Index.init(a, &.{ 0, 1, 0, 0 }, .none));
    try testing.expectError(error.MissingHeader, Index.init(a, &.{}, .none));
    try testing.expectError(error.HeaderAfterData, Index.init(a, bytes.items[data_offset..], .none));

    bytes.items.len = data_offset;
    try testFrame(a, &bytes, "OSMData", .{ .zstd_data = "abc", .raw_size = 3 });
    try testing.expectError(error.UnsupportedCompression, Index.init(a, bytes.items, .none));
    bytes.items.len = data_offset;
    try testFrame(a, &bytes, "OSMData", .{ .zlib_data = "abc" });
    try testing.expectError(error.MissingRawSize, Index.init(a, bytes.items, .none));
    bytes.clearRetainingCapacity();
    try testHeader(a, &bytes, .{ .required_features = &.{ "OsmSchema-V0.6", "UnknownRequiredFeature" } });
    try testing.expectError(error.UnsupportedRequiredFeature, Index.init(a, bytes.items, .none));
}

test "compressed block checks length, checksum and complete consumption" {
    const a = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try testHeader(a, &bytes, fixture_header);
    const good = storedZlib("abc".*);
    var wrong_checksum = good;
    wrong_checksum[wrong_checksum.len - 1] ^= 1;
    try testFrame(a, &bytes, "OSMData", .{ .zlib_data = &wrong_checksum, .raw_size = 3 });
    try testFrame(a, &bytes, "OSMData", .{ .zlib_data = &good, .raw_size = 4 });
    try testFrame(a, &bytes, "OSMData", .{ .zlib_data = &good, .raw_size = 2 });
    try testFrame(a, &bytes, "OSMData", .{ .zlib_data = &(good ++ [_]u8{0}), .raw_size = 3 });
    try testFrame(a, &bytes, "OSMData", .{ .zlib_data = good[0 .. good.len - 1], .raw_size = 3 });
    try testFrame(a, &bytes, "OSMData", .{ .lz4_data = &.{ 0x30, 'a', 'b' }, .raw_size = 3 });
    var index = try Index.init(a, bytes.items, .none);
    defer index.deinit();
    var scratch: [4]u8 = undefined;
    try testing.expectError(error.CorruptZlib, index.inflateInto(0, &scratch, .none));
    try testing.expectError(error.InflateSizeMismatch, index.inflateInto(1, &scratch, .none));
    try testing.expectError(error.InflateSizeMismatch, index.inflateInto(2, &scratch, .none));
    try testing.expectError(error.CorruptZlib, index.inflateInto(3, &scratch, .none));
    try testing.expectError(error.CorruptZlib, index.inflateInto(4, &scratch, .none));
    try testing.expectError(error.CorruptLz4, index.inflateInto(5, &scratch, .none));
    try testing.expectError(error.InflateBufferTooSmall, index.inflateInto(0, scratch[0..2], .none));
}
