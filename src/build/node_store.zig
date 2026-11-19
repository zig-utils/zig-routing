//! Build-time node ID index. Only way-referenced nodes reach the store.
//! Sorted input streams straight into short delta blocks. Unsorted input
//! uses sparse positional scratch pages and emits them in ID order.

const std = @import("std");
const wire = @import("protobuf").wire;
const io = @import("../infra/io.zig");
const osm = @import("osm.zig");
const pbf = @import("pbf/root.zig");
const usage = @import("node_store/usage.zig");

const Coordinates = usage.Coordinates;
const keyFor = usage.keyFor;
const block_capacity = 256;
const flags_capacity = block_capacity / 4;
const payload_capacity = @sizeOf(Coordinates) + (block_capacity - 1) * 20;
const magic = "ZRNODE01".*;

const Header = extern struct {
    magic: [8]u8,
    directory: u64,
    nodes: u64,
    blocks: u64,
};

const Entry = extern struct {
    first: u64,
    last: u64,
    offset: u64,
    bytes: u32,
    count: u16,
    reserved: u16 = 0,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 32);
    std.debug.assert(@offsetOf(Header, "directory") == 8 and @offsetOf(Header, "nodes") == 16 and @offsetOf(Header, "blocks") == 24);
    std.debug.assert(@sizeOf(Entry) == 32);
    std.debug.assert(@offsetOf(Entry, "last") == 8 and @offsetOf(Entry, "offset") == 16);
    std.debug.assert(@offsetOf(Entry, "bytes") == 24 and @offsetOf(Entry, "count") == 28 and @offsetOf(Entry, "reserved") == 30);
}

pub const Location = struct {
    lat: i32,
    lon: i32,
    /// Saturated at three references, including repeated refs in a way.
    uses: u2,
};

pub const Store = struct {
    file: io.File,
    header: Header,

    /// The caller owns the file and keeps it immutable while reading.
    pub fn open(file: io.File) !Store {
        const size = try file.size();
        if (size < @sizeOf(Header)) return error.InvalidStore;
        var header: Header = undefined;
        try file.preadAll(std.mem.asBytes(&header), 0);
        if (!std.mem.eql(u8, &header.magic, &magic)) return error.InvalidStore;
        if (header.directory < @sizeOf(Header) or header.directory > size or
            (header.blocks == 0) != (header.nodes == 0) or header.blocks > header.nodes or
            header.nodes > header.blocks *| block_capacity or
            header.blocks != (size - header.directory) / @sizeOf(Entry) or
            (size - header.directory) % @sizeOf(Entry) != 0)
            return error.InvalidStore;
        return .{ .file = file, .header = header };
    }

    pub fn nodeCount(self: Store) u64 {
        return self.header.nodes;
    }

    pub fn lookup(self: Store, id: i64, deadline: io.Deadline) !?Location {
        var cursor: Cursor = .{};
        return cursor.lookup(self, id, deadline);
    }

    /// Resolve consecutive way refs in input order into caller-owned storage.
    /// Workers handle disjoint contiguous ranges. A zero worker count uses
    /// the host CPU count, capped by batch size and the worker limit.
    pub fn lookupBatch(self: Store, ids: []const i64, out: []?Location, workers: usize, deadline: io.Deadline) !void {
        if (out.len != ids.len) return error.InvalidOutputLength;
        if (ids.len == 0) return;
        const requested = if (workers == 0) std.Thread.getCpuCount() catch 1 else workers;
        const count = @min(worker_limit, requested, 1 + (ids.len - 1) / refs_per_worker);
        if (count == 1) {
            var cursor: Cursor = .{};
            return cursor.lookupBatch(self, ids, out, deadline);
        }

        var jobs: [worker_limit]LookupJob = undefined;
        var threads: [worker_limit - 1]std.Thread = undefined;
        var started: usize = 0;
        errdefer for (threads[0..started]) |thread| thread.join();
        var start: usize = 0;
        for (jobs[0..count], 0..) |*job, i| {
            const end = start + ids.len / count + @intFromBool(i < ids.len % count);
            job.* = .{ .store = self, .ids = ids[start..end], .out = out[start..end], .deadline = deadline };
            start = end;
            if (i < count - 1) {
                threads[i] = try std.Thread.spawn(.{}, LookupJob.run, .{job});
                started += 1;
            }
        }
        jobs[count - 1].run();
        for (threads[0..started]) |thread| thread.join();
        started = 0;
        for (jobs[0..count]) |job| try job.result;
    }
};

const worker_limit = 16;
const refs_per_worker = 1024;

const LookupJob = struct {
    store: Store,
    ids: []const i64,
    out: []?Location,
    deadline: io.Deadline,
    result: anyerror!void = {},

    fn run(self: *LookupJob) void {
        var cursor: Cursor = .{};
        self.result = cursor.lookupBatch(self.store, self.ids, self.out, self.deadline);
    }
};

const directory_page = 128;
const directory_cache = 8;
const decoded_cache = 8;
const read_ahead = 8;

const DirectoryPage = struct {
    number: u64 = std.math.maxInt(u64),
    entries: [directory_page]Entry = undefined,
};

const Decoded = struct {
    entry: Entry,
    keys: [block_capacity]u64,
    coordinates: [block_capacity]Coordinates,
    flags: [flags_capacity]u8,

    fn lookup(self: *const Decoded, key: u64) ?Location {
        const keys = self.keys[0..self.entry.count];
        const index = std.sort.lowerBound(u64, keys, key, compareKeys);
        if (index == keys.len or keys[index] != key) return null;
        return .{
            .lat = self.coordinates[index].lat,
            .lon = self.coordinates[index].lon,
            .uses = @truncate(self.flags[index / 4] >> @as(u3, @intCast((index % 4) * 2))),
        };
    }
};

fn compareKeys(key: u64, entry: u64) std.math.Order {
    return std.math.order(key, entry);
}

/// Per-reader bounded block and directory caches. A cursor is single-threaded
/// and belongs to one store. Reset it before using a different store.
pub const Cursor = struct {
    directory: [directory_cache]DirectoryPage = @splat(.{}),
    blocks: [decoded_cache]Decoded = undefined,
    used: [decoded_cache]bool = @splat(false),
    replace: usize = 0,

    pub fn lookup(self: *Cursor, store: Store, id: i64, deadline: io.Deadline) !?Location {
        if (deadline.expired()) return error.DeadlineExceeded;
        const key = keyFor(id);
        return if (try self.prepare(store, key)) |entry| try self.resolve(store, entry, key) else null;
    }

    /// Probe a bounded window first and hint uncached blocks in way order.
    pub fn lookupBatch(self: *Cursor, store: Store, ids: []const i64, out: []?Location, deadline: io.Deadline) !void {
        if (out.len != ids.len) return error.InvalidOutputLength;
        var start: usize = 0;
        while (start < ids.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const count = @min(read_ahead, ids.len - start);
            var entries: [read_ahead]?Entry = undefined;
            var last_hint: ?u64 = null;
            for (ids[start..][0..count], entries[0..count]) |id, *prepared| {
                prepared.* = try self.prepare(store, keyFor(id));
                if (prepared.*) |entry| {
                    if (entry.offset != last_hint and self.cached(entry.first) == null) {
                        store.file.prefetch(entry.offset, entry.bytes);
                        last_hint = entry.offset;
                    }
                }
            }
            for (ids[start..][0..count], entries[0..count], out[start..][0..count]) |id, entry, *location| {
                location.* = if (entry) |found| try self.resolve(store, found, keyFor(id)) else null;
            }
            start += count;
        }
    }

    fn cached(self: *Cursor, key: u64) ?*Decoded {
        for (&self.blocks, self.used) |*block, used| {
            if (used and key >= block.entry.first and key <= block.entry.last) return block;
        }
        return null;
    }

    fn prepare(self: *Cursor, store: Store, key: u64) !?Entry {
        if (self.cached(key)) |block| return block.entry;
        var lo: u64 = 0;
        var hi = store.header.blocks;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = try self.readEntry(store, mid);
            if (key < entry.first) {
                hi = mid;
            } else if (key > entry.last) {
                lo = mid + 1;
            } else {
                return entry;
            }
        }
        return null;
    }

    fn readEntry(self: *Cursor, store: Store, index: u64) !Entry {
        const number = index / directory_page;
        const page = &self.directory[number % directory_cache];
        if (page.number != number) {
            const first = number * directory_page;
            const count: usize = @intCast(@min(directory_page, store.header.blocks - first));
            page.number = std.math.maxInt(u64);
            try store.file.preadAll(std.mem.sliceAsBytes(page.entries[0..count]), store.header.directory + first * @sizeOf(Entry));
            page.number = number;
        }
        const entry = page.entries[index % directory_page];
        const min_size = @sizeOf(Coordinates) + (@as(usize, entry.count) + 3) / 4;
        if (entry.first > entry.last or entry.count == 0 or entry.count > block_capacity or entry.reserved != 0 or
            entry.bytes < min_size or entry.bytes > payload_capacity + flags_capacity or
            entry.offset < @sizeOf(Header) or entry.offset > store.header.directory or
            entry.bytes > store.header.directory - entry.offset)
            return error.InvalidStore;
        return entry;
    }

    fn resolve(self: *Cursor, store: Store, entry: Entry, key: u64) !?Location {
        if (self.cached(key)) |block| return block.lookup(key);
        const slot = self.replace;
        self.used[slot] = false;
        try decodeBlock(store.file, entry, &self.blocks[slot]);
        self.used[slot] = true;
        self.replace = (slot + 1) % decoded_cache;
        return self.blocks[slot].lookup(key);
    }
};

fn decodeBlock(file: io.File, entry: Entry, out: *Decoded) !void {
    var buf: [payload_capacity + flags_capacity]u8 = undefined;
    const bytes = buf[0..entry.bytes];
    try file.preadAll(bytes, entry.offset);
    const flag_len = (@as(usize, entry.count) + 3) / 4;
    const data_len = bytes.len - flag_len;
    @memcpy(out.flags[0..flag_len], bytes[data_len..]);
    out.entry = entry;
    out.keys[0] = entry.first;
    out.coordinates[0] = .{
        .lat = std.mem.readInt(i32, bytes[0..4], .little),
        .lon = std.mem.readInt(i32, bytes[4..8], .little),
    };
    var reader = wire.Reader.init(bytes[@sizeOf(Coordinates)..data_len]);
    for (1..entry.count) |i| {
        const delta = try reader.readVarint();
        if (delta == 0) return error.InvalidStore;
        out.keys[i] = std.math.add(u64, out.keys[i - 1], delta) catch return error.InvalidStore;
        const previous = out.coordinates[i - 1];
        out.coordinates[i] = .{
            .lat = try decodeCoordinate(&reader, previous.lat),
            .lon = try decodeCoordinate(&reader, previous.lon),
        };
    }
    if (reader.remaining.len != 0 or out.keys[entry.count - 1] != entry.last) return error.InvalidStore;
    for (0..entry.count) |i| {
        const coords = out.coordinates[i];
        if (out.flags[i / 4] >> @as(u3, @intCast((i % 4) * 2)) & 3 == 0 or
            @abs(coords.lat) > 90 * osm.coordinate_scale or @abs(coords.lon) > 180 * osm.coordinate_scale)
            return error.InvalidStore;
    }
}

fn decodeCoordinate(reader: *wire.Reader, previous: i32) !i32 {
    const delta = wire.zigzagDecode(i64, try reader.readVarint());
    const absolute = std.math.add(i64, previous, delta) catch return error.InvalidStore;
    return std.math.cast(i32, absolute) orelse error.InvalidStore;
}

const Writer = struct {
    output: io.File,
    directory: io.File,
    offset: u64 = @sizeOf(Header),
    blocks: u64 = 0,
    nodes: u64 = 0,
    first: u64 = 0,
    last: u64 = 0,
    previous: Coordinates = undefined,
    count: u16 = 0,
    bytes: usize = 0,
    buffer: [payload_capacity + flags_capacity]u8 = undefined,
    flags: [flags_capacity]u8 = @splat(0),

    fn init(file: io.File, scratch_dir: []const u8) !Writer {
        const dir = try io.File.temporary(scratch_dir);
        errdefer dir.close();
        try file.truncate(0);
        return .{ .output = file, .directory = dir };
    }

    fn restart(self: *Writer) !void {
        try self.output.truncate(0);
        try self.directory.truncate(0);
        self.* = .{ .output = self.output, .directory = self.directory };
    }

    fn append(self: *Writer, key: u64, coords: Coordinates, uses: u2) !void {
        if (self.nodes != 0 and key <= self.last) return error.OutOfOrder;
        if (self.count == block_capacity) try self.flush();
        var payload: wire.BufferWriter = .{ .buffer = self.buffer[0..payload_capacity], .written = self.bytes };
        if (self.count == 0) {
            self.first = key;
            try payload.writeAll(std.mem.asBytes(&coords));
        } else {
            try wire.writeVarint(&payload, key - self.last);
            try wire.writeVarint(&payload, wire.zigzagEncode(i64, @as(i64, coords.lat) - self.previous.lat));
            try wire.writeVarint(&payload, wire.zigzagEncode(i64, @as(i64, coords.lon) - self.previous.lon));
        }
        self.bytes = payload.written;
        self.last = key;
        self.previous = coords;
        self.flags[self.count / 4] |= @as(u8, uses) << @as(u3, @intCast((self.count % 4) * 2));
        self.count += 1;
        self.nodes += 1;
    }

    fn flush(self: *Writer) !void {
        if (self.count == 0) return;
        const flag_len = (@as(usize, self.count) + 3) / 4;
        const len = self.bytes + flag_len;
        if (self.offset > std.math.maxInt(i64) - len or
            self.blocks >= std.math.maxInt(i64) / @sizeOf(Entry)) return error.StoreTooLarge;
        @memcpy(self.buffer[self.bytes..][0..flag_len], self.flags[0..flag_len]);
        const entry: Entry = .{ .first = self.first, .last = self.last, .offset = self.offset, .bytes = @intCast(len), .count = self.count };
        try self.output.pwriteAll(self.buffer[0..len], self.offset);
        try self.directory.pwriteAll(std.mem.asBytes(&entry), self.blocks * @sizeOf(Entry));
        self.offset += len;
        self.blocks += 1;
        self.count = 0;
        self.bytes = 0;
        self.flags = @splat(0);
    }

    fn finish(self: *Writer, deadline: io.Deadline) !Store {
        if (deadline.expired()) return error.DeadlineExceeded;
        try self.flush();
        const dir_size = self.blocks * @sizeOf(Entry);
        if (dir_size > std.math.maxInt(i64) - self.offset) return error.StoreTooLarge;
        var buffer: [64 * 1024]u8 = undefined;
        var copied: u64 = 0;
        while (copied < dir_size) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const bytes = buffer[0..@intCast(@min(buffer.len, dir_size - copied))];
            try self.directory.preadAll(bytes, copied);
            try self.output.pwriteAll(bytes, self.offset + copied);
            copied += bytes.len;
        }
        const header: Header = .{ .magic = magic, .directory = self.offset, .nodes = self.nodes, .blocks = self.blocks };
        try self.output.pwriteAll(std.mem.asBytes(&header), 0);
        return .{ .file = self.output, .header = header };
    }
};

pub const BuildOptions = struct {
    scratch_dir: []const u8,
    deadline: io.Deadline = .none,
};

/// Mark refs from qualifying ways, then stream just those nodes to output.
/// The caller provides the way selection policy. On failure the output may
/// be incomplete. It has no valid header until the directory is complete.
pub fn build(
    gpa: std.mem.Allocator,
    source: pbf.file.Stream,
    output: io.File,
    options: BuildOptions,
    context: anytype,
    comptime includeWay: anytype,
) !Store {
    return buildObserving(gpa, source, output, options, context, includeWay, null);
}

/// The observer receives just the way-referenced nodes. When the input is
/// out of order, some nodes can be observed again during the replay.
pub fn buildObserving(
    gpa: std.mem.Allocator,
    source: pbf.file.Stream,
    output: io.File,
    options: BuildOptions,
    context: anytype,
    comptime includeWay: anytype,
    comptime observeNode: ?fn (@TypeOf(context), pbf.block.Node) anyerror!void,
) !Store {
    var used = try usage.Usage.init(options.scratch_dir);
    defer used.deinit();
    var writer = try Writer.init(output, options.scratch_dir);
    defer writer.directory.close();

    const Pass = struct {
        const Self = @This();
        const Mode = union(enum) { usage, sorted_nodes, unsorted_nodes: io.File };
        gpa: std.mem.Allocator,
        deadline: io.Deadline,
        selection: @TypeOf(context),
        used: *usage.Usage,
        writer: *Writer,
        scratch: pbf.block.Scratch = .{},
        mode: Mode = .usage,
        out_of_order: bool = false,

        fn consume(self: *Self, _: usize, bytes: []const u8) !void {
            const block = try self.scratch.decode(self.gpa, bytes, self.deadline);
            switch (self.mode) {
                .usage => {
                    var ways = block.ways();
                    while (try ways.next()) |item| {
                        var way = item;
                        if (try includeWay(self.selection, &way)) {
                            while (try way.refs.next()) |id| try self.used.mark(keyFor(id));
                        }
                    }
                },
                .sorted_nodes => {
                    var nodes = block.nodes();
                    while (try nodes.next()) |node| {
                        const key = keyFor(node.id);
                        const uses = try self.used.count(key);
                        if (uses == 0) continue;
                        self.writer.append(key, .{ .lat = node.lat, .lon = node.lon }, uses) catch |err| {
                            if (err == error.OutOfOrder) self.out_of_order = true;
                            return err;
                        };
                        if (observeNode) |observe| try observe(self.selection, node);
                    }
                },
                .unsorted_nodes => |positions| {
                    var nodes = block.nodes();
                    while (try nodes.next()) |node| {
                        const located = try self.used.locate(positions, keyFor(node.id), .{ .lat = node.lat, .lon = node.lon });
                        if (observeNode) |observe| {
                            if (located) try observe(self.selection, node);
                        }
                    }
                },
            }
        }
    };
    var pass: Pass = .{
        .gpa = gpa,
        .deadline = options.deadline,
        .selection = context,
        .used = &used,
        .writer = &writer,
    };
    defer pass.scratch.deinit(gpa);
    try source.forEach(gpa, options.deadline, &pass, Pass.consume);
    pass.mode = .sorted_nodes;
    source.forEach(gpa, options.deadline, &pass, Pass.consume) catch |err| {
        if (!pass.out_of_order) return err;
        try writer.restart();
        const positions = try io.File.temporary(options.scratch_dir);
        defer positions.close();
        pass.mode = .{ .unsorted_nodes = positions };
        try source.forEach(gpa, options.deadline, &pass, Pass.consume);
        try used.emitLocated(positions, options.deadline, &writer, Writer.append);
    };
    return writer.finish(options.deadline);
}

test "node store directory, signed gaps, counts, and parallel batched reads" {
    const testing = std.testing;
    const output = try io.File.temporary(".");
    defer output.close();
    var writer = try Writer.init(output, ".");
    defer writer.directory.close();
    try writer.append(keyFor(-1), .{ .lat = -900000000, .lon = 1800000000 }, 1);
    try writer.append(keyFor(-std.math.maxInt(i64)), .{ .lat = 900000000, .lon = -1800000000 }, 2);
    try writer.append(keyFor(std.math.minInt(i64)), .{ .lat = 1, .lon = -1 }, 3);
    for (1..701) |i| try writer.append(keyFor(@intCast(i * 13)), .{ .lat = @intCast(i), .lon = -@as(i32, @intCast(i)) }, 1);
    try writer.append(keyFor(std.math.maxInt(i64)), .{ .lat = 0, .lon = 0 }, 2);
    _ = try writer.finish(.none);

    const store = try Store.open(output);
    try testing.expectEqual(704, store.nodeCount());
    var cursor: Cursor = .{};
    try testing.expectEqual(Location{ .lat = -900000000, .lon = 1800000000, .uses = 1 }, (try cursor.lookup(store, -1, .none)).?);
    try testing.expectEqual(Location{ .lat = 900000000, .lon = -1800000000, .uses = 2 }, (try cursor.lookup(store, -std.math.maxInt(i64), .none)).?);
    try testing.expectEqual(Location{ .lat = 1, .lon = -1, .uses = 3 }, (try cursor.lookup(store, std.math.minInt(i64), .none)).?);
    try testing.expectEqual(Location{ .lat = 0, .lon = 0, .uses = 2 }, (try cursor.lookup(store, std.math.maxInt(i64), .none)).?);
    try testing.expectEqual(null, try cursor.lookup(store, -2, .none));
    try testing.expectEqual(null, try cursor.lookup(store, 0, .none));
    try testing.expectError(error.DeadlineExceeded, cursor.lookup(store, 0, .{ .at_ns = 0 }));

    var ids: [3100]i64 = undefined;
    var locations: [ids.len]?Location = undefined;
    for (&ids, 0..) |*id, i| id.* = @intCast((1 + ((i * 83) % 700)) * 13 + @intFromBool(i % 2 == 0));
    try store.lookupBatch(&ids, &locations, 3, .none);
    for (ids, locations) |id, location| {
        if (@mod(id, 13) != 0) {
            try testing.expectEqual(null, location);
        } else {
            const lat: i32 = @intCast(@divTrunc(id, 13));
            try testing.expectEqual(Location{ .lat = lat, .lon = -lat, .uses = 1 }, location.?);
        }
    }
}

test "corrupt node store payload length and header return errors" {
    const testing = std.testing;
    const output = try io.File.temporary(".");
    defer output.close();
    try testing.expectError(error.InvalidStore, Store.open(output));
    var writer = try Writer.init(output, ".");
    defer writer.directory.close();
    try writer.append(keyFor(1), .{ .lat = 0, .lon = 0 }, 1);
    const store = try writer.finish(.none);
    var entry: Entry = undefined;
    try output.preadAll(std.mem.asBytes(&entry), store.header.directory);
    entry.bytes = std.math.maxInt(u32);
    try output.pwriteAll(std.mem.asBytes(&entry), store.header.directory);
    try testing.expectError(error.InvalidStore, store.lookup(1, .none));
    try output.truncate(store.header.directory);
    try testing.expectError(error.InvalidStore, Store.open(output));
}
